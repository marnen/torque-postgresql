require_relative 'auxiliary_statement/settings'

module Torque
  module PostgreSQL
    class AuxiliaryStatement
      TABLE_COLUMN_AS_STRING = /\A(?:"?(\w+)"?\.)?"?(\w+)"?\z/.freeze

      class << self
        attr_reader :config

        # Find or create the class that will handle statement
        def lookup(name, base)
          const = name.to_s.camelize << '_' << self.name.demodulize
          return base.const_get(const, false) if base.const_defined?(const, false)
          base.const_set(const, Class.new(AuxiliaryStatement))
        end

        # Create a new instance of an auxiliary statement
        def instantiate(statement, base, options = nil)
          klass = while base < ActiveRecord::Base
            list = base.auxiliary_statements_list
            break list[statement] if list.present? && list.key?(statement)

            base = base.superclass
          end

          return klass.new(options) unless klass.nil?
          raise ArgumentError, <<-MSG.squish
            There's no '#{statement}' auxiliary statement defined for #{base.class.name}.
          MSG
        end

        # Fast access to statement build
        def build(statement, base, options = nil, bound_attributes = [])
          klass = instantiate(statement, base, options)
          result = klass.build(base)

          bound_attributes.concat(klass.bound_attributes)
          result
        end

        # Identify if the query set may be used as a relation
        def relation_query?(obj)
          !obj.nil? && obj.respond_to?(:ancestors) && \
            obj.ancestors.include?(ActiveRecord::Base)
        end

        # Identify if the query set may be used as arel
        def arel_query?(obj)
          !obj.nil? && obj.is_a?(::Arel::SelectManager)
        end

        # A way to create auxiliary statements outside of models configurations,
        # being able to use on extensions
        def create(table_or_settings, &block)
          klass = Class.new(AuxiliaryStatement)

          if block_given?
            klass.instance_variable_set(:@table_name, table_or_settings)
            klass.configurator(block)
          elsif relation_query?(table_or_settings)
            klass.configurator(query: table_or_settings)
          else
            klass.configurator(table_or_settings)
          end

          klass
        end

        # Set a configuration block or static hash
        def configurator(config)
          if config.is_a?(Hash)
            # Map the aliases
            config[:attributes] = config.delete(:select) if config.key?(:select)

            # Create the struct that mocks a configuration result
            config = OpenStruct.new(config)
            table_name = config[:query]&.klass&.name&.underscore
            instance_variable_set(:@table_name, table_name)
          end

          @config = config
        end

        # Run a configuration block or get the static configuration
        def configure(base, instance)
          return @config unless @config.respond_to?(:call)

          settings = Settings.new(base, instance)
          settings.instance_exec(settings, &@config)
          settings
        end

        # Get the arel version of the statement table
        def table
          @table ||= ::Arel::Table.new(table_name)
        end

        # Get the name of the table of the configurated statement
        def table_name
          @table_name ||= self.name.demodulize.split('_').first.underscore
        end
      end

      delegate :config, :table, :table_name, :relation, :configure, :relation_query?,
        to: :class

      attr_reader :bound_attributes

      # Start a new auxiliary statement giving extra options
      def initialize(*args)
        options = args.extract_options!
        args_key = Torque::PostgreSQL.config.auxiliary_statement.send_arguments_key

        @join = options.fetch(:join, {})
        @args = options.fetch(args_key, {})
        @where = options.fetch(:where, {})
        @select = options.fetch(:select, {})
        @join_type = options.fetch(:join_type, nil)
        @bound_attributes = []
      end

      # Build the statement on the given arel and return the WITH statement
      def build(base)
        prepare(base)

        # Add the join condition to the list
        base.joins_values += [build_join(base)]

        # Return the statement with its dependencies
        [@dependencies, ::Arel::Nodes::As.new(table, build_query(base))]
      end

      private
        # Setup the statement using the class configuration
        def prepare(base)
          settings = configure(base, self)
          requires = Array.wrap(settings.requires).flatten.compact
          @dependencies = ensure_dependencies(requires, base).flatten.compact

          @join_type ||= settings.join_type || :inner
          @query = settings.query

          # Call a proc to get the real query
          if @query.methods.include?(:call)
            call_args = @query.try(:arity) === 0 ? [] : [OpenStruct.new(@args)]
            @query = @query.call(*call_args)
            @args = []
          end

          # Manually set the query table when it's not an relation query
          @query_table = settings.query_table unless relation_query?(@query)
          @select = settings.attributes.merge(@select) if settings.attributes.present?

          # Merge join settings
          if settings.join.present?
            @join = settings.join.merge(@join)
          elsif settings.through.present?
            @association = settings.through.to_s
          elsif relation_query?(@query)
            @association = base.reflections.find do |name, reflection|
              break name if @query.klass.eql? reflection.klass
            end
          end
        end

        # Build the string or arel query
        def build_query(base)
          # Expose columns and get the list of the ones for select
          columns = expose_columns(base, @query.try(:arel_table))

          # Prepare the query depending on its type
          if @query.is_a?(String)
            args = @args.map{ |k, v| [k, base.connection.quote(v)] }.to_h
            ::Arel.sql("(#{@query})" % args)
          elsif relation_query?(@query)
            @query = @query.where(@where) if @where.present?
            @bound_attributes.concat(@query.send(:bound_attributes))
            @query.select(*columns).arel
          else
            raise ArgumentError, <<-MSG.squish
              Only String and ActiveRecord::Base objects are accepted as query objects,
              #{@query.class.name} given for #{self.class.name}.
            MSG
          end
        end

        # Build the join statement that will be sent to the main arel
        def build_join(base)
          conditions = table.create_and([])
          builder = base.predicate_builder
          foreign_table = base.arel_table

          # Check if it's necessary to load the join from an association
          if @association.present?
            association = base.reflections[@association]

            # Require source of a through reflection
            if association.through_reflection?
              base.joins(association.source_reflection_name)

              # Changes the base of the connection to the reflection table
              builder = association.klass.predicate_builder
              foreign_table = ::Arel::Table.new(association.plural_name)
            end

            # Add the scopes defined by the reflection
            if association.respond_to?(:join_scope)
              args = [@query.arel_table]
              args << base if association.method(:join_scope).arity.eql?(2)
              @query.merge(association.join_scope(*args))
            end

            # Add the join constraints
            constraint = association.build_join_constraint(table, foreign_table)
            constraint = constraint.children if constraint.is_a?(::Arel::Nodes::And)
            conditions.children.concat(Array.wrap(constraint))
          end

          # Build all conditions for the join on statement
          @join.inject(conditions.children) do |arr, (left, right)|
            left = project(left, foreign_table)
            item = right.is_a?(Symbol) ? project(right).eq(left) : builder.build(left, right)
            arr.push(item)
          end

          # Raise an error when there's no join conditions
          raise ArgumentError, <<-MSG.squish if conditions.children.empty?
            You must provide the join columns when using '#{@query.class.name}'
            as a query object on #{self.class.name}.
          MSG

          # Expose join columns
          if relation_query?(@query)
            query_table = @query.arel_table
            conditions.children.each do |item|
              @query.select_values += [query_table[item.left.name]] \
                if item.left.relation.eql?(table)
            end
          end

          # Build the join based on the join type
          arel_join.new(table, table.create_on(conditions))
        end

        # Get the class of the join on arel
        def arel_join
          case @join_type
          when :inner then ::Arel::Nodes::InnerJoin
          when :left  then ::Arel::Nodes::OuterJoin
          when :right then ::Arel::Nodes::RightOuterJoin
          when :full  then ::Arel::Nodes::FullOuterJoin
          else
            raise ArgumentError, <<-MSG.squish
              The '#{@join_type}' is not implemented as a join type.
            MSG
          end
        end

        # Mount the list of selected attributes
        def expose_columns(base, query_table = nil)
          # Add select columns to the query and get exposed columns
          @select.map do |left, right|
            base.select_extra_values += [table[right.to_s]]
            project(left, query_table).as(right.to_s) if query_table
          end
        end

        # Ensure that all the dependencies are loaded in the base relation
        def ensure_dependencies(list, base)
          with_options = list.extract_options!.to_a
          (list + with_options).map do |dependent, options|
            dependent_klass = base.model.auxiliary_statements_list[dependent]

            raise ArgumentError, <<-MSG.squish if dependent_klass.nil?
              The '#{dependent}' auxiliary statement dependency can't found on
              #{self.class.name}.
            MSG

            next if base.auxiliary_statements_values.any? do |cte|
              cte.is_a?(dependent_klass)
            end

            AuxiliaryStatement.build(dependent, base, options, bound_attributes)
          end
        end

        # Project a column on a given table, or use the column table
        def project(column, arel_table = nil)
          if column.respond_to?(:as)
            return column
          elsif (as_string = TABLE_COLUMN_AS_STRING.match(column.to_s))
            column = as_string[2]
            arel_table = ::Arel::Table.new(as_string[1]) unless as_string[1].nil?
          end

          arel_table ||= table
          arel_table[column.to_s]
        end
    end
  end
end

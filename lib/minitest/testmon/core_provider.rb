# frozen_string_literal: true

module Minitest
  module Testmon
    # The MRI provider uses the same declarations as an application provider.
    # Its only privileged primitive is Coverage, which emits ordinary
    # +coverage_lines+ observations into these claims.
    class CoreProvider
      EXCLUDES = RubyPathPolicy::DEFAULT_EXCLUDES
      INSTANCE_READS = %i[read readpartial sysread each_line gets readline readlines].freeze
      DIRECT_READS = %i[read binread readlines foreach].freeze

      def initialize(configuration)
        @configuration = configuration
        @ruby_path_policy = RubyPathPolicy.new(configuration)
      end

      def define(builder)
        ruby_facets = define_ruby_inventories(builder)
        define_claims(builder, ruby_facets)
        observe_project_inputs = default_project_inputs?
        define_default_project_inputs(builder) if observe_project_inputs
        define_observers(builder, observe_project_inputs: observe_project_inputs)
      end

      private

      def define_ruby_inventories(builder)
        facets = []
        @configuration.ruby_patterns.group_by(&:first).sort_by { |root, _| root.to_s }.each do |root, _entries|
          inventory_name = :"ruby_#{root}"
          source_name = :"ruby_#{root}_source"
          paths_name = :"ruby_#{root}_paths"
          builder.inventory inventory_name,
            root: root,
            include: @ruby_path_policy.include_patterns(root),
            exclude: inventory_excludes(root)
          builder.facet source_name,
            inventory: inventory_name,
            digest: :ruby_source,
            granularity: :file,
            scope: :test
          builder.facet paths_name,
            inventory: inventory_name,
            digest: :paths,
            granularity: :set,
            scope: :suite
          facets << [inventory_name, source_name]
        end

        if @configuration.roots.key?(:project)
          builder.inventory :test_definitions,
            root: :project,
            include: "test/**/*.rb",
            exclude: EXCLUDES
          builder.facet :test_definitions,
            inventory: :test_definitions,
            digest: :content,
            granularity: :file,
            scope: :test
          builder.__send__(
            :__observe_builtin_test_start,
            :test_definition,
            details: ->(test) {
              location = test.__send__(:__source_location)
              {"path" => location.first} if location&.first
            }
          )
          builder.claim :test_definition,
            to: %i[test_definitions test_definitions],
            path: ->(observation) { observation.details["path"] || observation.details[:path] }
        end
        facets
      end

      def define_claims(builder, ruby_facets)
        ruby_facets.each do |target|
          builder.claim :coverage_lines, to: target, path: :path
          builder.claim :ruby_script, to: target, path: :path
          builder.claim :ruby_require, to: target, path: :path
          builder.claim :file_read, to: target, path: :path
          builder.claim :test_definition,
            to: target,
            path: ->(observation) { observation.details["path"] || observation.details[:path] }
        end
      end

      def inventory_excludes(root)
        @ruby_path_policy.exclude_patterns(root)
      end

      def default_project_inputs?
        @configuration.providers.none? { |provider| provider.name != :ruby }
      end

      def define_default_project_inputs(builder)
        builder.inventory :project_inputs,
          root: :project,
          include: "**/*",
          exclude: [*inventory_excludes(:project), "**/*.rb"]
        builder.facet :project_input_content,
          inventory: :project_inputs,
          digest: :content,
          granularity: :file,
          scope: :test
        builder.claim :file_open,
          to: %i[project_inputs project_input_content],
          path: :path
        builder.claim :file_read,
          to: %i[project_inputs project_input_content],
          path: :path
      end

      def define_observers(builder, observe_project_inputs:)
        builder.observe_tracepoint :ruby_script,
          target: :any,
          event: :script_compiled,
          path: ->(trace) { ruby_path(trace.path) }

        if observe_project_inputs
          builder.observe_tracepoint :file_open,
            target: [File, :initialize],
            event: :c_return,
            path: ->(trace) { input_path(trace.path) }
          INSTANCE_READS.each do |method_name|
            builder.observe_tracepoint :file_read,
              target: [IO, method_name],
              event: :c_call,
              path: ->(trace) { input_path(trace.path) }
          end
          DIRECT_READS.each do |method_name|
            builder.observe_tracepoint :file_read,
              target: [File, method_name],
              event: :c_call
          end
          %i[file_open file_read].each do |kind|
            builder.ignore kind,
              reason: "file operation originated outside configured roots",
              predicate: ->(observation) { !project_path(observation.callsite && observation.callsite[:path]) }
          end
        end
        [:ruby_script].each do |kind|
          builder.ignore kind,
            reason: "input is outside configured roots",
            predicate: ->(observation) { observation.path.nil? }
        end
        %i[ruby_script ruby_require].each do |kind|
          builder.ignore kind,
            reason: "Ruby loaded outside a test boundary",
            predicate: ->(observation) { observation.test_id.nil? }
        end
      end

      def input_path(path)
        return unless path.respond_to?(:to_path) || path.respond_to?(:to_str)
        value = path.respond_to?(:to_path) ? path.to_path : path.to_str
        return if nested_testmon_path?(value)
        expanded = File.expand_path(value)
        canonical = File.exist?(expanded) ? File.realpath(expanded) : expanded
        return if nested_testmon_path?(canonical)
        @configuration.roots.each_value do |root|
          return canonical if canonical == root || canonical.start_with?("#{root}#{File::SEPARATOR}")
        end
        nil
      rescue SystemCallError, ArgumentError, TypeError
        nil
      end

      def ruby_path(path)
        @ruby_path_policy.locator(path)&.absolute_path
      end

      def project_path(path)
        @ruby_path_policy.project_locator(path)&.absolute_path
      end

      def contained_by_root?(path, root)
        path && root && (path == root || path.start_with?("#{root}#{File::SEPARATOR}"))
      end

      def nested_testmon_path?(path)
        project_root = @configuration.roots[:project]
        return false unless contained_by_root?(Testmon::GEM_ROOT, project_root)
        return false if project_root == Testmon::GEM_ROOT

        relative = Pathname(Testmon::GEM_ROOT).relative_path_from(Pathname(project_root)).to_s
        logical = "project:#{relative}"
        path == logical ||
          path.start_with?("#{logical}#{File::SEPARATOR}") ||
          contained_by_root?(path, Testmon::GEM_ROOT)
      end
    end
  end
end

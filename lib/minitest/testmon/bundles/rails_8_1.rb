# frozen_string_literal: true

module Minitest
  module Testmon
    module Bundles
      module Rails81
        PROVIDERS = %i[rails.boot rails.schema rails.views rails.locales rails.fixtures].freeze
        TEMPLATE_EVENTS = %w[
          render_template.action_view
          render_partial.action_view
          render_collection.action_view
          render_layout.action_view
          process_action.action_controller
        ].freeze
        FIXTURE_EXTENSIONS = %w[yml yaml csv].freeze

        module_function

        def compatible?
          rails_version = defined?(Rails::VERSION::STRING) && Gem::Version.new(Rails::VERSION::STRING)
          railties_version = Gem.loaded_specs["railties"]&.version
          rails_version && railties_version &&
            rails_version.segments.first(2) == [8, 1] &&
            railties_version.segments.first(2) == [8, 1]
        end

        def activate!(configuration, _registry)
          return false unless compatible?
          return false if configuration.bundle_disabled?(:rails_8_1)

          prepare_configuration(configuration)
          definitions = {
            "rails.boot": BootDefinition.new,
            "rails.schema": SchemaDefinition.new,
            "rails.views": ViewsDefinition.new(configuration),
            "rails.locales": LocalesDefinition.new(configuration),
            "rails.fixtures": FixturesDefinition.new(configuration)
          }
          definitions.each do |name, implementation|
            next if configuration.providers.any? { |provider| provider.name == name }
            configuration.provider(name, implementation, version: 1)
          end
          true
        end

        def prepare_configuration(configuration)
          configuration.ruby_files("app/**/*.rb", root: :project)
          external_runtime_paths.each { |path| add_gem_root(configuration, path) }
        end

        def external_runtime_paths
          paths = view_roots
          paths.concat(Array(I18n.load_path)) if defined?(I18n)
          if defined?(ActiveSupport::TestCase) && ActiveSupport::TestCase.respond_to?(:fixture_paths)
            paths.concat(Array(ActiveSupport::TestCase.fixture_paths))
          end
          paths.map(&:to_s).reject(&:empty?).uniq
        end

        def view_roots
          paths = if defined?(ActionController::Base) && ActionController::Base.respond_to?(:view_paths)
            value = ActionController::Base.view_paths
            value.respond_to?(:paths) ? value.paths : value
          else
            []
          end
          roots = Array(paths).filter_map do |resolver|
            value = resolver.path if resolver.respond_to?(:path)
            value ||= resolver.to_path if resolver.respond_to?(:to_path)
            value&.to_s
          end
          roots.concat(debug_view_roots)
          roots.reject(&:empty?).uniq
        end

        def debug_view_roots
          spec = Gem.loaded_specs["actionpack"]
          return [] unless spec

          path = File.join(spec.full_gem_path, "lib/action_dispatch/middleware/templates")
          File.directory?(path) ? [path] : []
        end

        def fixture_roots
          return [] unless defined?(ActiveSupport::TestCase) && ActiveSupport::TestCase.respond_to?(:fixture_paths)
          Array(ActiveSupport::TestCase.fixture_paths).map(&:to_s).reject(&:empty?).uniq
        end

        def add_gem_root(configuration, path)
          expanded = File.expand_path(path)
          project = configuration.project_root
          return if contained?(expanded, project)

          spec = Gem.loaded_specs.values.select(&:full_gem_path).find do |candidate|
            contained?(expanded, File.expand_path(candidate.full_gem_path))
          end
          return unless spec

          name = :"gem_#{spec.name.gsub(/[^a-zA-Z0-9]+/, "_")}_#{spec.version.to_s.gsub(/[^a-zA-Z0-9]+/, "_")}"
          configuration.root(name, spec.full_gem_path) unless configuration.roots.key?(name)
        end

        def fixture_content_keys(observation, facet, directory: nil)
          return [] unless fixture_directory_selected?(observation, directory)

          names = Array(
            fixture_detail(observation, :fixture_table_names) || fixture_detail(observation, :names)
          ).map { |name| name.to_s.delete_prefix(":") }
          return facet.artifact_keys if names.include?("all")

          facet.artifact_keys.select do |key|
            names.any? do |name|
              FIXTURE_EXTENSIONS.any? { |extension| key.end_with?("/#{name}.#{extension}") }
            end
          end
        end

        def fixture_membership_keys(observation, facet, directory: nil)
          fixture_directory_selected?(observation, directory) ? facet.artifact_keys : []
        end

        def fixture_directory_selected?(observation, directory)
          return true unless directory
          return true unless fixture_detail?(observation, :directories)

          expected = File.realpath(File.expand_path(directory))
          Array(fixture_detail(observation, :directories)).any? do |candidate|
            File.realpath(File.expand_path(candidate.to_s)) == expected
          rescue SystemCallError, ArgumentError, TypeError
            false
          end
        rescue SystemCallError, ArgumentError, TypeError
          false
        end

        def fixture_detail(observation, name)
          return observation.details[name.to_s] if observation.details.key?(name.to_s)

          observation.details[name.to_sym]
        end

        def fixture_detail?(observation, name)
          observation.details.key?(name.to_s) || observation.details.key?(name.to_sym)
        end

        def inventory_specs(configuration, paths, prefix:, files: false)
          Array(paths).map(&:to_s).reject(&:empty?).each_with_index.filter_map do |path, index|
            expanded = File.expand_path(path)
            canonical = File.realpath(expanded)
            root_name, root_path = configuration.roots
              .sort_by { |_name, candidate| -candidate.bytesize }
              .find { |_name, candidate| contained?(canonical, candidate) }
            next unless root_name

            if files
              relative = Pathname(canonical).relative_path_from(Pathname(root_path)).to_s
              {name: :"#{prefix}_#{index}", root: root_name, base: ".", include: [relative], path: canonical}
            else
              base = Pathname(canonical).relative_path_from(Pathname(root_path)).to_s
              {name: :"#{prefix}_#{index}", root: root_name, base: base, include: ["**/*"], path: canonical}
            end
          rescue SystemCallError, ArgumentError
            nil
          end
        end

        def contained?(path, root)
          path == root || path.start_with?("#{root}#{File::SEPARATOR}")
        end

        class BootDefinition
          def define(builder)
            builder.inventory :boot,
              root: :project,
              base: "config",
              include: ["**/*.rb", "*.yml", "*.yaml"],
              exclude: []
            builder.facet :content, inventory: :boot, digest: :content, granularity: :file, scope: :suite
            builder.facet :membership, inventory: :boot, digest: :paths, granularity: :set, scope: :suite
          end
        end

        class SchemaDefinition
          def define(builder)
            builder.inventory :schema,
              root: :project,
              base: "db",
              include: ["schema.rb", "structure.sql", "*_schema.rb", "*_structure.sql", "migrate/**/*"],
              exclude: []
            builder.facet :content, inventory: :schema, digest: :content, granularity: :file, scope: :suite
            builder.facet :membership, inventory: :schema, digest: :paths, granularity: :set, scope: :suite
          end
        end

        class ViewsDefinition
          def initialize(configuration)
            @specs = Rails81.inventory_specs(configuration, Rails81.view_roots, prefix: :views)
          end

          def define(builder)
            targets = @specs.each_with_index.map do |spec, index|
              content = index.zero? ? :content : :"content_#{index}"
              membership = index.zero? ? :membership : :"membership_#{index}"
              builder.inventory spec.fetch(:name),
                root: spec.fetch(:root), base: spec.fetch(:base), include: spec.fetch(:include), exclude: []
              builder.facet content,
                inventory: spec.fetch(:name), digest: :content, granularity: :file, scope: :test
              builder.facet membership,
                inventory: spec.fetch(:name), digest: :paths, granularity: :set, scope: :test
              [spec.fetch(:name), content, membership]
            end

            TEMPLATE_EVENTS.each do |event_name|
              builder.observe_notification :rails_view,
                event_name,
                path: ->(notification) {
                  notification.payload[:identifier] || notification.payload["identifier"]
                }
            end
            targets.each do |inventory, content, membership|
              builder.claim :rails_view, to: [inventory, content], path: :path
              builder.claim :rails_view, to: [inventory, membership]
            end

            if defined?(ActionView::LookupContext)
              builder.observe_tracepoint :rails_view_lookup,
                target: [ActionView::LookupContext, :exists?], event: :call, path: ->(_trace) {}
              targets.each do |inventory, _content, membership|
                builder.claim :rails_view_lookup, to: [inventory, membership]
              end
            end
          end
        end

        class LocalesDefinition
          METHODS = %i[translate t localize l].freeze

          def initialize(configuration)
            paths = defined?(I18n) ? Array(I18n.load_path).select { |path| File.file?(path.to_s) } : []
            @specs = Rails81.inventory_specs(configuration, paths, prefix: :locales, files: true)
          end

          def define(builder)
            targets = @specs.each_with_index.map do |spec, index|
              content = index.zero? ? :content : :"content_#{index}"
              membership = index.zero? ? :membership : :"membership_#{index}"
              builder.inventory spec.fetch(:name),
                root: spec.fetch(:root), base: spec.fetch(:base), include: spec.fetch(:include), exclude: []
              builder.facet content,
                inventory: spec.fetch(:name), digest: :content, granularity: :file, scope: :test
              builder.facet membership,
                inventory: spec.fetch(:name), digest: :paths, granularity: :set, scope: :test
              [spec.fetch(:name), content, membership]
            end

            METHODS.each do |method_name|
              next unless defined?(I18n) && I18n.respond_to?(method_name)
              builder.observe_tracepoint :rails_locale,
                target: [I18n, method_name], event: :call, path: ->(_trace) {}
            end
            targets.each do |inventory, content, membership|
              builder.claim :rails_locale,
                to: [inventory, content],
                using: ->(_observation, facet) { facet.artifact_keys }
              builder.claim :rails_locale, to: [inventory, membership]
            end
          end
        end

        class FixturesDefinition
          def initialize(configuration)
            @specs = Rails81.inventory_specs(configuration, Rails81.fixture_roots, prefix: :fixtures)
          end

          def define(builder)
            targets = @specs.each_with_index.map do |spec, index|
              content = index.zero? ? :content : :"content_#{index}"
              membership = index.zero? ? :membership : :"membership_#{index}"
              builder.inventory spec.fetch(:name),
                root: spec.fetch(:root),
                base: spec.fetch(:base),
                include: FIXTURE_EXTENSIONS.map { |extension| "**/*.#{extension}" },
                exclude: []
              builder.facet content,
                inventory: spec.fetch(:name), digest: :content, granularity: :file, scope: :test
              builder.facet membership,
                inventory: spec.fetch(:name), digest: :paths, granularity: :set, scope: :test
              [spec.fetch(:name), content, membership]
            end

            builder.__send__(
              :__observe_builtin_test_start,
              :rails_declared_fixtures,
              details: ->(test) {
                fixture_table_names = Array(test.class_value(:fixture_table_names))
                {"fixture_table_names" => fixture_table_names} unless fixture_table_names.empty?
              }
            )
            targets.each do |inventory, content, membership|
              builder.claim :rails_declared_fixtures,
                to: [inventory, content],
                using: Rails81.method(:fixture_content_keys)
              builder.claim :rails_declared_fixtures,
                to: [inventory, membership],
                using: Rails81.method(:fixture_membership_keys)
            end

            if defined?(ActiveRecord::FixtureSet)
              builder.observe_tracepoint :rails_fixture,
                target: [ActiveRecord::FixtureSet, :create_fixtures],
                event: :call,
                path: ->(_trace) {},
                details: ->(trace) {
                  {
                    "directories" => Array(trace.local(:fixtures_directories)).map(&:to_s),
                    "names" => Array(trace.local(:fixture_set_names)).map(&:to_s)
                  }
                }
              builder.ignore :rails_fixture,
                reason: "fixture load without named fixtures",
                predicate: ->(observation) { Array(Rails81.fixture_detail(observation, :names)).empty? }
              targets.each do |inventory, content, membership|
                spec = @specs.find { |item| item.fetch(:name) == inventory }
                builder.claim :rails_fixture,
                  to: [inventory, content],
                  using: ->(observation, facet) {
                    Rails81.fixture_content_keys(observation, facet, directory: spec.fetch(:path))
                  }
                builder.claim :rails_fixture,
                  to: [inventory, membership],
                  using: ->(observation, facet) {
                    Rails81.fixture_membership_keys(observation, facet, directory: spec.fetch(:path))
                  }
              end
            end
          end
        end
      end
    end
  end
end

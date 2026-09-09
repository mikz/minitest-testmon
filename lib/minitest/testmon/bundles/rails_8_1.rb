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
          definitions[:"rails.assets"] = AssetsDefinition.new(configuration) if defined?(Propshaft::LoadPath)
          definitions.each do |name, implementation|
            next if configuration.providers.any? { |provider| provider.name == name }
            configuration.provider(name, implementation, version: (name == :"rails.fixtures") ? 2 : 1)
          end
          true
        end

        # The file list Rails' TestCommand#all passes to Minitest; the exact
        # set that still denotes a complete suite for this profile.
        COMPLETE_SUITE_GLOBS = ["test/**/*_test.rb"].freeze

        def prepare_configuration(configuration)
          configuration.default_complete_suite_globs(*COMPLETE_SUITE_GLOBS)
          configuration.ruby_files("app/**/*.rb", root: :project)
          external_runtime_paths.each { |path| add_gem_root(configuration, path) }
        end

        def external_runtime_paths
          paths = view_roots
          paths.concat(Array(I18n.load_path)) if defined?(I18n)
          paths.concat(fixture_roots)
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

        def fixture_test_cases
          return [] unless defined?(ActiveSupport::TestCase) && ActiveSupport::TestCase.respond_to?(:fixture_paths)
          test_cases = [ActiveSupport::TestCase]
          test_cases.concat(ActiveSupport::TestCase.descendants) if ActiveSupport::TestCase.respond_to?(:descendants)
          test_cases.uniq
        end

        def fixture_roots
          fixture_test_cases.flat_map { |test_case| Array(test_case.fixture_paths) }.map(&:to_s).reject(&:empty?).uniq.sort
        end

        def fixture_layout_digest(configuration)
          resolver = PathResolver.new(configuration.roots)
          layout = fixture_test_cases.map do |test_case|
            paths = Array(test_case.fixture_paths).map do |path|
              resolver.resolve(path.to_s).key
            rescue PathError
              # Unowned roots cannot contribute publishable fixture evidence.
              "unavailable"
            end
            # Anonymous classes have no stable identity across processes. Keep
            # their layouts (including duplicates), never their object addresses.
            [test_case.name || "<anonymous>", paths]
          end
          Digest::SHA256.hexdigest(CanonicalJSON.generate(layout.sort_by { |item| CanonicalJSON.generate(item) }))
        end

        def asset_roots
          return [] unless defined?(Rails) && Rails.respond_to?(:application) && Rails.application
          config = Rails.application.config
          return [] unless config.respond_to?(:assets) && config.assets.respond_to?(:paths)
          Array(config.assets.paths).map(&:to_s).reject(&:empty?).uniq
        rescue NoMethodError
          []
        end

        ASSET_INPUT_FILES = %w[
          config/importmap.rb
          package.json
          package-lock.json
          yarn.lock
          pnpm-lock.yaml
          bun.lock
          bun.lockb
          postcss.config.js
          postcss.config.mjs
          tailwind.config.js
          tailwind.config.ts
        ].freeze
        ASSET_INPUT_DIRECTORIES = %w[app/javascript vendor/javascript].freeze

        def asset_input_files(configuration)
          ASSET_INPUT_FILES
            .map { |path| File.join(configuration.project_root, path) }
            .select { |path| File.file?(path) }
        end

        def asset_input_directories(configuration)
          ASSET_INPUT_DIRECTORIES
            .map { |path| File.join(configuration.project_root, path) }
            .select { |path| File.directory?(path) }
        end

        def asset_detail(observation)
          fixture_detail(observation, :logical_path).to_s
        end

        def asset_content_keys(observation, facet)
          logical = asset_detail(observation)
          return [] if logical.empty?
          facet.artifact_keys.select { |key| key.end_with?("/#{logical}") }
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

        def overlapping?(left, right)
          left = File.realpath(File.expand_path(left))
          right = File.realpath(File.expand_path(right))
          contained?(left, right) || contained?(right, left)
        rescue SystemCallError, ArgumentError, TypeError
          false
        end

        def external_gem_path?(path, configured_roots)
          return false unless path

          canonical = File.realpath(File.expand_path(path.to_s))
          roots = Array(configured_roots).map { |root| File.realpath(File.expand_path(root.to_s)) }
          return false if roots.any? { |root| contained?(canonical, root) }

          Gem.loaded_specs.values.any? do |spec|
            gem_root = spec.full_gem_path
            gem_root && contained?(canonical, File.realpath(File.expand_path(gem_root)))
          rescue SystemCallError, ArgumentError, TypeError
            false
          end
        rescue SystemCallError, ArgumentError, TypeError
          false
        end

        def physical_view_path(identifier)
          return identifier unless identifier.is_a?(String) || identifier.is_a?(Pathname)

          original = identifier.to_s
          return nil if original.empty?
          candidate = original
          until File.file?(candidate)
            shortened = candidate.sub(/\.[^\/.]+\z/, "")
            return original if shortened == candidate
            candidate = shortened
          end
          File.realpath(candidate)
        rescue SystemCallError, ArgumentError, TypeError
          original
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
            @configured_roots = configuration.roots.values.freeze
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
                  identifier = notification.payload[:identifier] || notification.payload["identifier"]
                  Rails81.physical_view_path(identifier)
                }
            end
            builder.ignore :rails_view,
              reason: "view source belongs to a loaded gem outside configured roots",
              predicate: ->(observation) {
                Rails81.external_gem_path?(observation.path, @configured_roots)
              }
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

        # Assets are runtime inputs of any test that resolves an asset URL —
        # system tests through Capybara page loads and Propshaft::Server, but
        # equally controller/integration tests rendering stylesheet_link_tag.
        # Every resolution funnels through Propshaft::LoadPath#find with the
        # logical path, so served/linked asset content is claimed per test.
        # Build inputs (importmap, package manifests, lockfiles, bundler
        # configs, app/javascript sources) cannot be tied to a single logical
        # path; any asset-resolving test conservatively claims them all, the
        # same way locale lookups claim every locale file.
        class AssetsDefinition
          def initialize(configuration)
            asset_roots = Rails81.asset_roots
            input_directories = Rails81.asset_input_directories(configuration).reject do |directory|
              asset_roots.any? { |root| Rails81.overlapping?(directory, root) }
            end
            @asset_specs = Rails81.inventory_specs(configuration, asset_roots, prefix: :assets)
            @input_specs = Rails81.inventory_specs(
              configuration, input_directories, prefix: :asset_input_trees
            )
            @input_specs += Rails81.inventory_specs(
              configuration, Rails81.asset_input_files(configuration), prefix: :asset_input_files, files: true
            )
          end

          def define(builder)
            asset_targets = declare(builder, @asset_specs, label: nil)
            input_targets = declare(builder, @input_specs, label: :inputs)
            return if asset_targets.empty? && input_targets.empty?

            builder.observe_tracepoint :rails_asset,
              target: [Propshaft::LoadPath, :find],
              event: :call,
              path: ->(_trace) {},
              details: ->(trace) { {"logical_path" => trace.local(:asset_name).to_s} }
            builder.ignore :rails_asset,
              reason: "asset lookup without a logical path",
              predicate: ->(observation) { Rails81.asset_detail(observation).empty? }

            asset_targets.each do |inventory, content, membership|
              builder.claim :rails_asset,
                to: [inventory, content],
                using: Rails81.method(:asset_content_keys)
              builder.claim :rails_asset, to: [inventory, membership]
            end
            input_targets.each do |inventory, content, membership|
              builder.claim :rails_asset,
                to: [inventory, content],
                using: ->(_observation, facet) { facet.artifact_keys }
              builder.claim :rails_asset, to: [inventory, membership]
            end
          end

          private

          def declare(builder, specs, label:)
            specs.each_with_index.map do |spec, index|
              suffix = [label, index.zero? ? nil : index].compact.join("_")
              content = suffix.empty? ? :content : :"content_#{suffix}"
              membership = suffix.empty? ? :membership : :"membership_#{suffix}"
              builder.inventory spec.fetch(:name),
                root: spec.fetch(:root), base: spec.fetch(:base), include: spec.fetch(:include), exclude: []
              builder.facet content,
                inventory: spec.fetch(:name), digest: :content, granularity: :file, scope: :test
              builder.facet membership,
                inventory: spec.fetch(:name), digest: :paths, granularity: :set, scope: :test
              [spec.fetch(:name), content, membership]
            end
          end
        end

        class FixturesDefinition
          def initialize(configuration)
            # Physical roots are a set, but each class's lookup order affects
            # duplicate fixture labels. Include that ordered layout in identity.
            prefix = "fixtures_#{Rails81.fixture_layout_digest(configuration)}"
            @specs = Rails81.inventory_specs(configuration, Rails81.fixture_roots, prefix: prefix)
              .sort_by { |spec| [spec.fetch(:root).to_s, spec.fetch(:base)] }
              .each_with_index.map { |spec, index| spec.merge(name: :"#{prefix}_#{index}") }
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
                unless fixture_table_names.empty?
                  details = {"fixture_table_names" => fixture_table_names}
                  paths = test.class_value(:fixture_paths)
                  details["directories"] = Array(paths).map(&:to_s) if paths
                  details
                end
              }
            )
            targets.each do |inventory, content, membership|
              spec = @specs.find { |item| item.fetch(:name) == inventory }
              builder.claim :rails_declared_fixtures,
                to: [inventory, content],
                using: ->(observation, facet) {
                  Rails81.fixture_content_keys(observation, facet, directory: spec.fetch(:path))
                }
              builder.claim :rails_declared_fixtures,
                to: [inventory, membership],
                using: ->(observation, facet) {
                  Rails81.fixture_membership_keys(observation, facet, directory: spec.fetch(:path))
                }
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

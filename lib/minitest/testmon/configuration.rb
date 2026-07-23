# frozen_string_literal: true

require "digest"

module Minitest
  module Testmon
    class Configuration
      FORMAT_VERSION = 1
      DEFAULT_DATABASE = ".minitest-testmon.sqlite3"
      DEFAULT_REPORT = "tmp/minitest-testmon/discovery.json"

      FileSetDefinition = Data.define(:name, :root, :base, :include_patterns, :exclude_patterns, :mode, :scope) do
        def signature
          {
            name: name.to_s,
            root: root.to_s,
            base: base,
            include: include_patterns,
            exclude: exclude_patterns,
            mode: mode.to_s,
            scope: scope.to_s
          }
        end
      end

      attr_reader :database_path, :report_path, :roots, :ruby_patterns, :filesets, :disabled_bundles

      def initialize(cwd: Dir.pwd)
        @version = FORMAT_VERSION
        @database_path = File.join(cwd, DEFAULT_DATABASE)
        @report_path = File.join(cwd, DEFAULT_REPORT)
        @roots = {}
        @ruby_patterns = [[:project, "lib/**/*.rb"], [:project, "test/**/*.rb"]]
        @filesets = []
        @disabled_bundles = []
        @providers = []
        @config_source_digests = []
        @config_sources = []
        @frozen_snapshot = false
        root(:project, cwd)
      end

      def version(value = nil)
        return @version unless value
        mutable!
        integer = Integer(value)
        raise ConfigurationError, "configuration version #{integer} is unsupported" unless integer == FORMAT_VERSION
        @version = integer
      end

      def root(name, path)
        mutable!
        key = name.to_sym
        @roots[key] = File.realpath(path)
      rescue Errno::ENOENT
        raise ConfigurationError, "root does not exist: #{path}"
      end

      def database(path)
        mutable!
        @database_path = File.expand_path(path, project_root)
      end

      def report(path)
        mutable!
        @report_path = File.expand_path(path, project_root)
      end

      def ruby_files(*patterns, root: :project)
        mutable!
        validate_root!(root)
        patterns.flatten.each do |pattern|
          @ruby_patterns << [root.to_sym, String(pattern)]
        end
      end

      def fileset(name, include:, root: :project, base: ".", exclude: [], mode: :paths, scope: :test)
        mutable!
        validate_root!(root)
        mode = mode.to_sym
        scope = scope.to_sym
        raise ConfigurationError, "fileset mode must be :paths or :contents" unless %i[paths contents].include?(mode)
        raise ConfigurationError, "fileset scope must be :test or :suite" unless %i[test suite].include?(scope)
        raise ConfigurationError, "fileset #{name} is already configured" if @filesets.any? { |item| item.name == name.to_sym }

        definition = FileSetDefinition.new(
          name: name.to_sym,
          root: root.to_sym,
          base: String(base),
          include_patterns: Array(include).map(&:to_s).sort.freeze,
          exclude_patterns: Array(exclude).map(&:to_s).sort.freeze,
          mode: mode,
          scope: scope
        )
        @filesets << definition
        provider("fileset.#{definition.name}", version: 1) do
          inventory definition.name,
            root: definition.root,
            base: definition.base,
            include: definition.include_patterns,
            exclude: definition.exclude_patterns
          facet definition.name,
            inventory: definition.name,
            digest: (definition.mode == :paths) ? :paths : :contents,
            granularity: :set,
            scope: definition.scope
        end
      end

      def provider(name, implementation = nil, version:, &block)
        mutable!
        key = name.to_sym
        raise ConfigurationError, "provider #{key} is already configured" if @providers.any? { |item| item.name == key }
        if implementation && block
          raise ConfigurationError, "provider #{key} cannot use both an implementation and block"
        end
        if implementation && !implementation.respond_to?(:define)
          raise ConfigurationError, "provider implementation must respond to define(builder)"
        end
        raise ConfigurationError, "provider #{key} needs an implementation or block" unless implementation || block

        builder = ProviderDefinitionBuilder.new(key, version)
        implementation&.define(builder)
        builder.instance_eval(&block) if block
        definition = builder.build
        @providers << definition
        definition
      rescue ConfigurationError
        raise
      rescue => error
        raise ConfigurationError, "invalid provider #{name}: #{error.message}"
      end

      def replace_provider(name, implementation, version:)
        mutable!
        @providers.reject! { |provider| provider.name == name.to_sym }
        provider(name, implementation, version: version)
      end

      def record_config_source(path)
        mutable!
        lexical_path = File.expand_path(path)
        real_path = File.realpath(lexical_path)
        digest = Digest::SHA256.file(real_path).hexdigest
        @config_source_digests << digest unless @config_source_digests.include?(digest)
        source = {
          path: lexical_path,
          realpath: real_path,
          symlink: File.symlink?(lexical_path) ? File.readlink(lexical_path) : nil,
          digest: digest
        }.freeze
        @config_sources << source unless @config_sources.any? { |item| item[:path] == lexical_path }
        digest
      rescue SystemCallError => error
        raise ConfigurationError, "cannot read configuration source #{path}: #{error.message}"
      end

      def disable_bundle(name)
        mutable!
        bundle = name.to_sym
        raise ConfigurationError, "unknown bundle: #{bundle}" unless bundle == :rails_8_1
        @disabled_bundles << bundle unless @disabled_bundles.include?(bundle)
      end

      def bundle_disabled?(name)
        @disabled_bundles.include?(name.to_sym)
      end

      def snapshot?
        @frozen_snapshot
      end

      def providers
        @frozen_snapshot ? @providers : @providers.dup.freeze
      end

      def snapshot
        return self if @frozen_snapshot
        raise ConfigurationError, "at least one root is required" if @roots.empty?

        @roots = @roots.sort_by { |name, _| name.to_s }.to_h.freeze
        @ruby_patterns = @ruby_patterns.uniq.sort_by { |root, pattern| [root.to_s, pattern] }.freeze
        @filesets = @filesets.sort_by { |item| item.name.to_s }.freeze
        @providers = @providers.sort_by { |item| item.name.to_s }.freeze
        @providers.each do |provider|
          provider.inventories.each { |inventory| validate_root!(inventory.root) }
        end
        @config_source_digests = @config_source_digests.uniq.sort.freeze
        @config_sources = @config_sources.sort_by { |item| item[:path] }.freeze
        @disabled_bundles = @disabled_bundles.map(&:to_sym).uniq.sort.freeze
        @database_path = File.expand_path(@database_path)
        @report_path = File.expand_path(@report_path)
        @frozen_snapshot = true
        freeze
      end

      def signature
        payload = {
          version: @version,
          roots: @roots.keys.map(&:to_s).sort,
          ruby_patterns: @ruby_patterns.map { |root, pattern| [root.to_s, pattern] },
          filesets: @filesets.map(&:signature),
          providers: @providers.map(&:signature),
          config_sources: @config_source_digests,
          disabled_bundles: @disabled_bundles.map(&:to_s),
          engine: Engine.signature
        }
        Digest::SHA256.hexdigest(CanonicalJSON.generate(payload))
      end

      def project_root
        @roots.fetch(:project)
      end

      def current_config_source_manifest
        @config_sources.map do |source|
          path = source.fetch(:path)
          real_path = File.realpath(path)
          {
            path: path,
            realpath: real_path,
            symlink: File.symlink?(path) ? File.readlink(path) : nil,
            digest: Digest::SHA256.file(real_path).hexdigest
          }
        rescue SystemCallError => error
          {path: path, error: error.class.name}
        end
      end

      private

      def mutable!
        raise ConfigurationError, "configuration snapshot is frozen" if @frozen_snapshot
      end

      def validate_root!(name)
        raise ConfigurationError, "unknown root: #{name}" unless @roots.key?(name.to_sym)
      end
    end
  end
end

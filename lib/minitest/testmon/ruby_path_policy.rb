# frozen_string_literal: true

module Minitest
  module Testmon
    class RubyPathPolicy
      DEFAULT_EXCLUDES = %w[
        .git/**/*
        tmp/**/*
        vendor/**/*
        coverage/**/*
        node_modules/**/*
        log/**/*
        .minitest-testmon.sqlite3*
      ].freeze
      GLOB_FLAGS = File::FNM_PATHNAME | File::FNM_EXTGLOB | File::FNM_DOTMATCH

      def initialize(configuration)
        @configuration = configuration
        @resolver = PathResolver.new(configuration.roots)
        @patterns = configuration.ruby_patterns.group_by(&:first).transform_values do |entries|
          entries.map(&:last).uniq.sort.freeze
        end.freeze
      end

      def include_patterns(root)
        patterns = @patterns.fetch(root.to_sym, [])
        patterns = [*patterns, "**/*.rb"] if root.to_sym == :project
        patterns.uniq.sort.freeze
      end

      def exclude_patterns(root)
        return DEFAULT_EXCLUDES unless root.to_sym == :project

        project_root = @configuration.roots.fetch(:project)
        return DEFAULT_EXCLUDES unless nested_testmon_root?(project_root)

        relative = Pathname(Testmon::GEM_ROOT).relative_path_from(Pathname(project_root))
        [*DEFAULT_EXCLUDES, "#{relative}/**/*"].freeze
      end

      def locator(path)
        locator = @resolver.resolve(path)
        return unless included?(locator)
        return if excluded?(locator)

        locator
      rescue PathError, SystemCallError, ArgumentError, TypeError
        nil
      end

      def project_locator(path)
        if @resolver.logical?(path)
          root, relative = path.to_s.split(":", 2)
          path = File.join(@resolver.root(root.to_sym), relative)
        end
        locator = @resolver.resolve(path)
        return unless locator.root == :project
        return if excluded?(locator)

        locator
      rescue PathError, SystemCallError, ArgumentError, TypeError
        nil
      end

      private

      def included?(locator)
        include_patterns(locator.root).any? do |pattern|
          File.fnmatch?(pattern, locator.relative_path, GLOB_FLAGS)
        end
      end

      def excluded?(locator)
        exclude_patterns(locator.root).any? do |pattern|
          File.fnmatch?(pattern, locator.relative_path, GLOB_FLAGS)
        end
      end

      def nested_testmon_root?(project_root)
        project_root != Testmon::GEM_ROOT &&
          Testmon::GEM_ROOT.start_with?("#{project_root}#{File::SEPARATOR}")
      end
    end
  end
end

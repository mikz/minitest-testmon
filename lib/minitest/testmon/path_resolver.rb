# frozen_string_literal: true

module Minitest
  module Testmon
    Locator = Data.define(:root, :relative_path, :absolute_path) do
      def key
        "#{root}:#{relative_path}"
      end
    end

    class PathResolver
      def initialize(roots)
        @roots = roots.map do |name, path|
          [name.to_sym, Pathname(File.realpath(path)).cleanpath.to_s]
        end.sort_by { |_name, path| -path.bytesize }
      end

      def resolve(path, allow_missing: true)
        expanded = File.expand_path(path)
        existing = File.exist?(expanded) || File.symlink?(expanded)
        canonical = if existing
          File.realpath(expanded)
        elsif allow_missing
          canonical_missing_path(expanded)
        else
          raise PathError, "path does not exist: #{path}"
        end

        name, root = @roots.find { |_root_name, root_path| contained?(canonical, root_path) }
        raise PathError, "path is outside configured roots: #{path}" unless name

        relative = Pathname(canonical).relative_path_from(Pathname(root)).cleanpath.to_s
        Locator.new(root: name, relative_path: relative, absolute_path: canonical)
      rescue Errno::ENOENT, Errno::EACCES, ArgumentError => error
        raise PathError, error.message
      end

      def root(name)
        pair = @roots.find { |root_name, _| root_name == name.to_sym }
        raise PathError, "unknown root: #{name}" unless pair
        pair.last
      end

      def logical?(path)
        value = path.to_s
        @roots.any? { |name, _root| value.start_with?("#{name}:") }
      end

      private

      def canonical_missing_path(path)
        ancestor = path
        suffix = []

        until File.exist?(ancestor) || File.symlink?(ancestor)
          parent = File.dirname(ancestor)
          raise PathError, "cannot resolve existing ancestor for path: #{path}" if parent == ancestor

          suffix.unshift(File.basename(ancestor))
          ancestor = parent
        end

        Pathname(File.join(File.realpath(ancestor), *suffix)).cleanpath.to_s
      end

      def contained?(path, root)
        path == root || path.start_with?("#{root}#{File::SEPARATOR}")
      end
    end
  end
end

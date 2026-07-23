# frozen_string_literal: true

require "digest"

module Minitest
  module Testmon
    FileSetResult = Data.define(:definition, :fingerprint, :members)

    class FileSetFingerprint
      def initialize(resolver)
        @resolver = resolver
      end

      def call(definition)
        root = @resolver.root(definition.root)
        base = File.expand_path(definition.base, root)
        @resolver.resolve(base)
        included = definition.include_patterns.flat_map do |pattern|
          Dir.glob(File.join(base, pattern), File::FNM_DOTMATCH)
        end
        excluded = definition.exclude_patterns.flat_map do |pattern|
          Dir.glob(File.join(base, pattern), File::FNM_DOTMATCH)
        end.to_h { |path| [File.expand_path(path), true] }

        members = included.uniq.filter_map do |path|
          expanded = File.expand_path(path)
          next if excluded.key?(expanded)
          next unless File.file?(expanded)

          locator = @resolver.resolve(expanded)
          next unless locator.root == definition.root
          locator
        rescue PathError
          nil
        end.sort_by(&:relative_path)

        payload = members.map do |locator|
          if definition.mode == :contents
            fingerprint = ContentFingerprint.call(locator.absolute_path)
            return FileSetResult.new(definition: definition, fingerprint: Fingerprint.unknown(fingerprint.reason), members: members) if fingerprint.unknown?
            [locator.relative_path, fingerprint.state.to_s, fingerprint.digest]
          else
            [locator.relative_path]
          end
        end
        digest = Digest::SHA256.hexdigest(CanonicalJSON.generate(payload))
        FileSetResult.new(definition: definition, fingerprint: Fingerprint.known(digest), members: members.freeze)
      rescue PathError, SystemCallError
        FileSetResult.new(definition: definition, fingerprint: Fingerprint.unknown(:outside_root), members: [].freeze)
      end
    end
  end
end

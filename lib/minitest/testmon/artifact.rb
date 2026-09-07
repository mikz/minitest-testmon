# frozen_string_literal: true

require_relative "input"

module Minitest
  module Testmon
    Artifact = Data.define(:key, :provider, :root, :relative_path, :facet, :fingerprint, :members, :scope, :test_ids, :reason, :identity) do
      def path
        "#{root}:#{relative_path}"
      end

      def known?
        !!fingerprint&.known?
      end

      def suite?
        scope == :suite
      end

      def whole_file?
        %i[content whole_file].include?(identity)
      end

      def source_identity
        [root, relative_path, fingerprint]
      end

      def inventory_item
        {
          key: key,
          provider: provider.to_s,
          facet: facet.to_s,
          path: path,
          members: Array(members).sort,
          scope: scope.to_s,
          test_ids: Array(test_ids).compact.sort,
          fingerprint: fingerprint&.digest,
          reason: (reason || fingerprint&.reason)&.to_s
        }
      end

      def to_input
        Input.new(
          key: key,
          provider: provider,
          facet: facet,
          root: root,
          relative_path: relative_path,
          fingerprint: fingerprint,
          members: members,
          scope: scope
        )
      end
    end

    Dependency = Data.define(:test_id, :artifact_key, :provider, :complete)
  end
end

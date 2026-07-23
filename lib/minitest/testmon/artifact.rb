# frozen_string_literal: true

module Minitest
  module Testmon
    Artifact = Data.define(:key, :provider, :root, :relative_path, :facet, :fingerprint, :members, :scope, :test_ids, :reason) do
      def path
        "#{root}:#{relative_path}"
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
    end

    Dependency = Data.define(:test_id, :artifact_key, :provider, :complete)
  end
end

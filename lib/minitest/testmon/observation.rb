# frozen_string_literal: true

require "digest"

module Minitest
  module Testmon
    Observation = Data.define(
      :key,
      :kind,
      :provider,
      :path,
      :operation,
      :scope,
      :test_id,
      :callsite,
      :exists_at_observation,
      :reason,
      :details
    ) do
      def self.build(kind:, provider: :core, path: nil, operation: nil, scope: nil, test_id: nil, callsite: nil, exists_at_observation: nil, reason: nil, details: {})
        scope ||= test_id ? :test : :suite
        stable = [kind, provider, path, operation, scope, test_id, callsite, reason, details]
        new(
          key: Digest::SHA256.hexdigest(CanonicalJSON.fingerprint(stable)),
          kind: kind.to_sym,
          provider: provider.to_sym,
          path: path,
          operation: operation&.to_sym,
          scope: scope.to_sym,
          test_id: test_id,
          callsite: callsite,
          exists_at_observation: exists_at_observation,
          reason: reason&.to_sym,
          details: details.freeze
        )
      end

      def report_item
        {
          key: key,
          kind: kind.to_s,
          provider: provider.to_s,
          path: path,
          operation: operation&.to_s,
          scope: scope.to_s,
          test_id: test_id,
          callsite: callsite,
          exists_at_observation: exists_at_observation,
          reason: reason&.to_s
        }
      end

      def unresolved?
        self.class::UNRESOLVED_REASONS.include?(reason)
      end
    end

    Observation::UNRESOLVED_REASONS = %i[
      nonexistent outside_root non_regular opaque_c_call
      source_race ambiguous_context late_activation provider_incomplete
      worker_incomplete invalid_configuration uncovered_file uncovered_event
      observer_unavailable observer_error extractor_error noncanonical_observation
      claim_path_missing
    ].freeze
  end
end

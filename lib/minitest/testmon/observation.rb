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
      :details,
      :provenance
    ) do
      def self.build(
        kind:, provider: :core, path: nil, operation: nil, scope: nil, test_id: nil,
        callsite: nil, exists_at_observation: nil, reason: nil, details: {}, provenance: nil
      )
        kind = kind.to_sym
        provider = provider.to_sym
        operation = operation&.to_sym
        scope = (scope || (test_id ? :test : :suite)).to_sym
        reason = reason&.to_sym
        provenance = provenance&.to_sym
        stable = [kind, provider, path, operation, scope, test_id, callsite, reason, details, provenance]
        new(
          key: Digest::SHA256.hexdigest(CanonicalJSON.fingerprint(stable)),
          kind: kind,
          provider: provider,
          path: path,
          operation: operation,
          scope: scope,
          test_id: test_id,
          callsite: callsite,
          exists_at_observation: exists_at_observation,
          reason: reason,
          details: details.freeze,
          provenance: provenance
        )
      end

      def as_suite_evidence
        return self if explicit_suite_evidence? && suite? && test_id.nil?

        self.class.build(**to_h.except(:key, :scope, :test_id, :provenance).merge(
          scope: :suite,
          test_id: nil,
          provenance: :explicit_suite
        ))
      end

      def explicit_suite_evidence?
        provenance == :explicit_suite
      end

      def suite?
        scope == :suite
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

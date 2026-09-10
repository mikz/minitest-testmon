# frozen_string_literal: true

module Minitest
  module Testmon
    RUN_OUTCOMES = %i[passed failed skipped].freeze

    RunEvidence = Data.define(
      :run_id,
      :base_revision,
      :report,
      :selection,
      :outcomes,
      :snapshots,
      :complete,
      :source_stable,
      :publication_reason,
      :final_suite_inputs
    ) do
      def initialize(run_id:, base_revision:, report:, selection:, outcomes:, snapshots:, complete:, source_stable:, publication_reason: nil, final_suite_inputs: [])
        normalized_outcomes = outcomes.to_h.transform_keys(&:to_s).transform_values(&:to_sym).sort.to_h.freeze
        invalid = normalized_outcomes.values - RUN_OUTCOMES
        raise ArgumentError, "invalid outcomes: #{invalid.uniq.join(", ")}" unless invalid.empty?
        normalized_snapshots = snapshots.to_h.transform_keys(&:to_s).sort.to_h.freeze

        super(
          run_id: run_id.to_s.freeze,
          base_revision: base_revision && Integer(base_revision),
          report: report,
          selection: selection,
          outcomes: normalized_outcomes,
          snapshots: normalized_snapshots,
          final_suite_inputs: Array(final_suite_inputs).dup.freeze,
          complete: !!complete,
          source_stable: !!source_stable,
          publication_reason: publication_reason&.to_s&.freeze
        )
      end

      def failed?
        outcomes.value?(:failed)
      end

      def passed_ids
        outcomes.filter_map { |test_id, outcome| test_id if outcome == :passed }.freeze
      end

      def valid_ledger?
        selected = selection.selected
        executed = report.executed_tests
        selected == executed && outcomes.keys == executed
      end

      def publishable_snapshots?(accepted_ids: [])
        passed = passed_ids
        supplied = snapshots.keys
        (supplied - passed).empty? && (passed - supplied - accepted_ids).empty?
      end
    end
  end
end

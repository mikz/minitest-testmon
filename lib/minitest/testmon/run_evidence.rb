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
      :publication_reason
    ) do
      def initialize(run_id:, base_revision:, report:, selection:, outcomes:, snapshots:, complete:, source_stable:, publication_reason: nil)
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

      def publishable_snapshots?
        snapshots.keys.sort == passed_ids.sort
      end
    end
  end
end

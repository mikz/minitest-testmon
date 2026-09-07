# frozen_string_literal: true

module Minitest
  module Testmon
    class Selector
      def call(discovered:, current_inputs:, snapshots:, retries:, base_revision:, force: false, suite_input_ids: [])
        catalog = index_inputs(current_inputs)
        snapshots = snapshots.to_h.transform_keys(&:to_s)
        retries = retries.to_h.transform_keys(&:to_s)
        suite_input_ids = Array(suite_input_ids).uniq.freeze
        reasons = {}

        Array(discovered).map(&:to_s).uniq.sort.each do |test_id|
          test_reasons = if force
            ["forced"]
          elsif retries.key?(test_id)
            ["#{retry_outcome(retries.fetch(test_id))}_test"]
          elsif !snapshots.key?(test_id)
            ["no_trace"]
          else
            changed_inputs(snapshots.fetch(test_id), catalog, suite_input_ids: suite_input_ids)
          end
          reasons[test_id] = test_reasons unless test_reasons.empty?
        end

        Selection.new(
          discovered: discovered,
          selected: reasons.keys,
          reasons_by_test: reasons,
          base_revision: base_revision
        )
      end

      private

      def index_inputs(inputs)
        values = inputs.respond_to?(:values) ? inputs.values : Array(inputs)
        values.to_h { |input| [input.id, input] }
      end

      def retry_outcome(value)
        value.respond_to?(:outcome) ? value.outcome : value
      end

      def changed_inputs(snapshot, catalog, suite_input_ids: [])
        inputs = snapshot.inputs.filter_map do |learned|
          current = catalog[learned.id]
          if current.nil?
            "input_missing:#{learned.id}"
          elsif !current.known?
            "input_unknown:#{learned.id}"
          elsif current.fingerprint.state != learned.fingerprint.state || current.fingerprint.digest != learned.fingerprint.digest
            "input_changed:#{learned.id}"
          end
        end
        learned_ids = snapshot.inputs.map(&:id).to_h { |id| [id, true] }
        suite_input_ids.each do |id|
          next if learned_ids.key?(id)

          inputs << "suite_input_missing:#{id}"
        end
        inputs.uniq.sort
      end
    end
  end
end

# frozen_string_literal: true

module Minitest
  module Testmon
    class SnapshotBuilder
      def call(test_id:, current_inputs:, claimed_input_ids:, test_definition_input:, recorded_at:, run_id:)
        catalog = index_inputs(current_inputs)
        claimed = Array(claimed_input_ids).map { |value| normalize_id(value) }
        missing = claimed.uniq.reject { |id| catalog.key?(id) }
        unless missing.empty?
          raise ArgumentError, "claimed inputs are absent from the current catalog: #{missing.map(&:to_s).sort.join(", ")}"
        end
        inputs = catalog.values.select { |input| input.scope == :suite }
        inputs.concat(claimed.map { |id| catalog.fetch(id) })
        inputs << test_definition_input if test_definition_input
        inputs = inputs.to_h { |input| [input.id, input] }.values
        unknown = inputs.reject(&:known?)
        raise ArgumentError, "cannot publish unknown inputs: #{unknown.map { |input| input.id.to_s }.join(", ")}" unless unknown.empty?

        TestSnapshot.new(test_id: test_id, inputs: inputs, recorded_at: recorded_at, run_id: run_id)
      end

      private

      def index_inputs(inputs)
        values = inputs.respond_to?(:values) ? inputs.values : Array(inputs)
        duplicates = values.group_by(&:id).select { |_id, matches| matches.length > 1 }.keys
        unless duplicates.empty?
          raise ArgumentError, "duplicate input identities: #{duplicates.map(&:to_s).sort.join(", ")}"
        end
        values.to_h { |input| [input.id, input] }
      end

      def normalize_id(value)
        return value if value.is_a?(InputId)
        if value.respond_to?(:provider) && value.respond_to?(:key)
          return InputId.new(provider: value.provider, key: value.key)
        end
        provider, key = Array(value)
        InputId.new(provider: provider, key: key)
      end
    end
  end
end

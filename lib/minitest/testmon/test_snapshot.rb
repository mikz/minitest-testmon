# frozen_string_literal: true

module Minitest
  module Testmon
    TestSnapshot = Data.define(:test_id, :inputs, :recorded_at, :run_id) do
      def initialize(test_id:, inputs:, recorded_at:, run_id:)
        normalized = Array(inputs).sort_by { |input| [input.provider, input.key] }.freeze
        duplicate = normalized.map(&:id).tally.find { |_id, count| count > 1 }
        raise ArgumentError, "duplicate snapshot input: #{duplicate.first}" if duplicate

        super(
          test_id: test_id.to_s.freeze,
          inputs: normalized,
          recorded_at: recorded_at.to_s.freeze,
          run_id: run_id.to_s.freeze
        )
      end
    end
  end
end

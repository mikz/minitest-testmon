# frozen_string_literal: true

module Minitest
  module Testmon
    Selection = Data.define(:discovered, :selected, :reasons_by_test, :base_revision) do
      def initialize(discovered:, selected:, reasons_by_test:, base_revision:)
        known = Array(discovered).map(&:to_s).uniq.sort.freeze
        chosen = Array(selected).map(&:to_s).uniq.sort.freeze
        unknown = chosen - known
        raise ArgumentError, "selected tests were not discovered: #{unknown.join(", ")}" unless unknown.empty?

        reasons = reasons_by_test.to_h.each_with_object({}) do |(test_id, values), result|
          id = test_id.to_s
          next unless chosen.include?(id)
          result[id.freeze] = Array(values).map(&:to_s).uniq.sort.freeze
        end.sort.to_h.freeze
        super(discovered: known, selected: chosen, reasons_by_test: reasons, base_revision: base_revision && Integer(base_revision))
      end
    end
  end
end

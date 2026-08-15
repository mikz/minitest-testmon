# frozen_string_literal: true

module Minitest
  module Testmon
    module Environment
      BYPASS_VARIABLE = "MINITEST_TESTMON_BYPASS"
      TRUTHY_VALUES = %w[1 true yes on].freeze

      module_function

      def enabled?(value = ENV["MINITEST_TESTMON"])
        TRUTHY_VALUES.include?(value.to_s.strip.downcase)
      end

      def bypassed?(value = ENV[BYPASS_VARIABLE])
        TRUTHY_VALUES.include?(value.to_s.strip.downcase)
      end

      def active?
        enabled? && !bypassed?
      end
    end
  end
end

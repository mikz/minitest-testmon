# frozen_string_literal: true

module Minitest
  module Testmon
    module Environment
      TRUTHY_VALUES = %w[1 true yes on].freeze

      module_function

      def enabled?(value = ENV["MINITEST_TESTMON"])
        TRUTHY_VALUES.include?(value.to_s.strip.downcase)
      end
    end
  end
end

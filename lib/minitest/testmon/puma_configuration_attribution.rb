# frozen_string_literal: true

require_relative "execution_context"

module Minitest
  module Testmon
    # Capybara loads Puma configuration on its persistent server thread before
    # serving requests. Borrow only for synchronous configuration, never for
    # the server's lifetime. Nested load inside clamp reuses the same borrow.
    module PumaConfigurationAttribution
      def load(...)
        ExecutionContext.with_boundary_attribution { super }
      end

      def clamp(...)
        ExecutionContext.with_boundary_attribution { super }
      end
    end
  end
end

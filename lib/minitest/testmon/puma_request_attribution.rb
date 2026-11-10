# frozen_string_literal: true

require_relative "execution_context"

module Minitest
  module Testmon
    # Include streamed bodies and standalone test gateways in the request boundary.
    module PumaRequestAttribution
      def handle_request(...)
        ExecutionContext.with_boundary_attribution { super }
      end
    end
  end
end

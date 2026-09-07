# frozen_string_literal: true

require_relative "execution_context"

module Minitest
  module Testmon
    # Rack middleware attributing in-process HTTP requests to the running
    # test. Under the supported isolated-server assumption, Capybara drains
    # its requests inside the sole active test boundary, so a Puma thread may
    # borrow that boundary's revocable token for the duration of the call.
    # The borrow is tracked as a child: a request still running when the
    # boundary closes is a thread leak. Unrelated inbound traffic violates
    # that assumption; threads outside a request remain unattributed.
    class RequestAttribution
      def initialize(app)
        @app = app
      end

      def call(env)
        ExecutionContext.with_boundary_attribution { @app.call(env) }
      end
    end
  end
end

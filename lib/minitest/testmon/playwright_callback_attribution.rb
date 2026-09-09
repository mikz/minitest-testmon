# frozen_string_literal: true

require_relative "execution_context"

module Minitest
  module Testmon
    # A Capybara browser belongs to the sole active test, but Playwright invokes
    # routes and event listeners on persistent dispatcher/pool threads. Borrow
    # only while the callback runs. Persistent registrations are suite evidence,
    # just like server configuration; never attach a test token to the pool.
    module PlaywrightCallbackAttribution
      def on(event, callback)
        super(event, testmon_callback(callback))
      end

      def once(event, callback)
        super(event, testmon_callback(callback))
      end

      def off(event, callback)
        super(event, testmon_callback(callback))
      end

      def route(url, handler, **options)
        super(url, testmon_callback(handler), **options)
      end

      def unroute(url, handler: nil)
        super(url, handler: handler && testmon_callback(handler))
      end

      private

      def testmon_callback(callback)
        return callback unless callback.respond_to?(:call)

        @testmon_callbacks ||= {}.compare_by_identity
        @testmon_callbacks[callback] ||= ->(*args, **kwargs, &block) do
          ExecutionContext.with_boundary_attribution(evidence_scope: :suite) do
            callback.call(*args, **kwargs, &block)
          end
        end
      end
    end
  end
end

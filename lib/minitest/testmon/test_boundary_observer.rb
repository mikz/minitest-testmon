# frozen_string_literal: true

module Minitest
  module Testmon
    class TestBoundaryObserver
      def initialize(session, collector)
        @session = session
        @collector = collector
        @active = {}
      end

      def start
        @collector.reset_for_fork!
        ExecutionContext.clear
        @trace = TracePointFactory.build([:call, :return], call: {run: Minitest::Test}, return: {run: Minitest::Test}) { |event| observe(event) }
        @trace.enable
        self
      end

      def close
        @trace&.disable
      end

      private

      def observe(event)
        return unless event.method_id == :run && event.self.is_a?(Minitest::Test)
        key = Thread.current.object_id
        case event.event
        when :call
          active = @active[key]
          if active
            active[:depth] += 1 if active[:test].equal?(event.self)
          else
            test = event.self
            test_id = "#{test.class}##{test.name}"
            @active[key] = {test: test, test_id: test_id, depth: 1}
            @collector.begin_test(test_id)
            @session.test_started(test)
          end
        when :return
          active = @active[key]
          return unless active && active[:test].equal?(event.self)
          active[:depth] -= 1
          return unless active[:depth].zero?
          @active.delete(key)
          @collector.finish_test(active[:test_id])
          @session.executed(active[:test_id])
          test = active[:test]
          outcome = if test.passed? && !test.skipped?
            :passed
          else
            test.skipped? ? :skipped : :failed
          end
          @session.seal_completion(active[:test_id], outcome)
        end
      rescue => error
        @session.record(Observation.build(
          kind: :provider_error,
          operation: :test_boundary,
          test_id: ExecutionContext.current_test,
          reason: :worker_incomplete,
          details: {error: error.class.name}
        ))
      end
    end
  end
end

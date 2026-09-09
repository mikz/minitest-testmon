# frozen_string_literal: true

module Minitest
  module Testmon
    class TestBoundaryObserver
      METHOD_LOOKUP = Object.instance_method(:method)

      class << self
        attr_accessor :worker_observer
      end

      module WorkerBridge
        def perform_job(...)
          observer = TestBoundaryObserver.worker_observer
          observer ? observer.around_job { super } : super
        end

        def safe_record(...)
          TestBoundaryObserver.worker_observer&.before_record
          super
        end
      end

      def initialize(session, collector)
        @session = session
        @collector = collector
        @active = {}
        @job_depth = 0
        @closed = false
      end

      def start
        @collector.reset_for_fork!
        ExecutionContext.clear
        self.class.worker_observer = self
        self
      end

      def around_job
        entered = false
        return yield if @closed
        entered = true
        @job_depth += 1
        return yield if @job_depth > 1

        @finished = false
        @acquired = false
        @job_thread = Thread.current
        # Both callbacks are direct Ruby TracePoints so their stack depths
        # have the same shape, independently of native extension availability.
        @acquisition = TracePoint.new(:call) { |event| acquire(event) }
        @acquisition.enable
        result = yield
        completed = true
        result
      ensure
        if entered
          if @job_depth == 1
            boundary_failure(:missing_test_boundary) unless @finished
            boundary_failure(:job_exception) unless completed
            cleanup_job
          end
          @job_depth -= 1
        end
      end

      def before_record
        return unless @job_depth == 1
        @acquisition&.disable
        boundary_failure(:missing_test_boundary) unless @finished
      end

      def close
        @closed = true
        cleanup_job
        self.class.worker_observer = nil if self.class.worker_observer.equal?(self)
      end

      private

      def acquire(event)
        return if @acquired
        return unless event.method_id == :run && event.self.is_a?(Minitest::Test)
        unless Thread.current.equal?(@job_thread)
          boundary_failure(:unexpected_boundary_thread)
          return
        end
        @acquired = true
        @outer_depth = caller_locations.length
        @finished = false
        begin
          install_target(event.self)
        rescue ArgumentError, RuntimeError, TypeError
          # A rejected target must not be disabled: MRI can then suppress
          # unrelated future targets. Keep the existing conservative observer.
          @target = nil
          @fallback = TracePointFactory.build([:call, :return], call: {run: Minitest::Test}, return: {run: Minitest::Test}) { |fallback_event| observe(fallback_event) }
          @fallback.enable
        end
        @acquisition.disable
        observe(event)
      rescue => error
        boundary_failure(error.class.name)
      end

      def install_target(test)
        method = METHOD_LOOKUP.bind_call(test, :run)
        # Adding :call while another targeted observer is active can replay
        # the current entry. Return-only tracing avoids counting that replay.
        @target = TracePoint.new(:return) { |event| observe(event) }
        @target.enable(target: method)
        @target_enabled = true
      end

      def observe(event)
        return unless event.method_id == :run && event.self.is_a?(Minitest::Test)
        unless Thread.current.equal?(@job_thread)
          boundary_failure(:unexpected_boundary_thread)
          return
        end
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
          if @target_enabled
            return unless caller_locations.length == @outer_depth
          else
            active[:depth] -= 1
            return unless active[:depth].zero?
          end
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
          @finished = true
          @target.disable if @target_enabled
          @target_enabled = false
          @fallback&.disable
          @acquired = false
          @acquisition.enable
        end
      rescue => error
        boundary_failure(error.class.name)
      end

      def boundary_failure(reason)
        @session.incomplete(:worker_incomplete)
        @session.record(Observation.build(
          kind: :provider_error,
          operation: :test_boundary,
          test_id: ExecutionContext.current_test,
          reason: :worker_incomplete,
          details: {error: reason.to_s}
        ))
      end

      def cleanup_job
        @acquisition&.disable
        @target.disable if @target_enabled
        @target_enabled = false
        @fallback&.disable
        @active.each_value { |active| @collector.finish_test(active[:test_id]) }
        @active.clear
      end
    end
  end
end

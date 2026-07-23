# frozen_string_literal: true

module Minitest
  module Testmon
    module ExecutionContext
      KEY = :__minitest_testmon_test_id

      module_function

      def current_test
        Thread.current.thread_variable_get(KEY)
      end

      def with_test(test_id)
        previous = current_test
        Thread.current.thread_variable_set(KEY, test_id)
        yield
      ensure
        Thread.current.thread_variable_set(KEY, previous)
      end

      def set(test_id)
        Thread.current.thread_variable_set(KEY, test_id)
      end

      def clear
        Thread.current.thread_variable_set(KEY, nil)
      end

      def begin_boundary
        @active_boundaries = @active_boundaries.to_i + 1
      end

      def end_boundary
        @active_boundaries = [@active_boundaries.to_i - 1, 0].max
      end

      def boundary_active?
        @active_boundaries.to_i.positive?
      end

      def reset_boundaries!
        @active_boundaries = 0
      end
    end
  end
end

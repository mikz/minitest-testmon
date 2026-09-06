# frozen_string_literal: true

module Minitest
  module Testmon
    module ExecutionContext
      KEY = :__minitest_testmon_test_id

      class AttributionToken
        def initialize(test_id, thread_sources: nil)
          @test_id = test_id.to_s.freeze
          @thread_sources = thread_sources
          @live = true
          @threads = {}
          @mutex = Mutex.new
        end

        def test_id
          @test_id if @live
        end

        def live?
          @live
        end

        def owns_thread_block?(block)
          return true unless @thread_sources

          path = block.source_location&.first
          path && @thread_sources.key?(File.realpath(path))
        rescue Errno::ENOENT, Errno::EACCES, Errno::ENOTDIR, Errno::ELOOP
          false
        end

        def register(thread)
          @mutex.synchronize { @threads[thread.object_id] = thread if @live }
        end

        def borrow(thread)
          @mutex.synchronize do
            return false unless @live

            @threads[thread.object_id] = thread
            true
          end
        end

        def unregister(thread)
          @mutex.synchronize { @threads.delete(thread.object_id) }
        end

        def revoke
          @mutex.synchronize do
            @live = false
            leaked = @threads.values.select(&:alive?)
            @threads.clear
            leaked
          end
        end
      end

      module_function

      def current_test
        attribution_token&.test_id
      end

      def attribution_token
        token = Thread.current.thread_variable_get(KEY)
        token if token&.live?
      end

      # Request attribution borrows this token only under the documented
      # isolated in-process server assumption. It is nil outside a sole
      # boundary and while test boundaries overlap.
      def sole_active_attribution
        token = @sole_active_attribution
        token if token&.live?
      end

      def with_test(test_id)
        previous = Thread.current.thread_variable_get(KEY)
        token = AttributionToken.new(test_id)
        Thread.current.thread_variable_set(KEY, token)
        yield
      ensure
        token&.revoke
        Thread.current.thread_variable_set(KEY, previous)
      end

      def with_attribution(token)
        previous = Thread.current.thread_variable_get(KEY)
        Thread.current.thread_variable_set(KEY, token)
        yield
      ensure
        Thread.current.thread_variable_set(KEY, previous)
      end

      def with_borrowed_attribution(token)
        thread = Thread.current
        borrowed = token.borrow(thread)
        return yield unless borrowed

        with_attribution(token) { yield }
      ensure
        token.unregister(thread) if borrowed
      end

      def with_boundary_attribution
        token = sole_active_attribution
        if token && current_test.nil?
          with_borrowed_attribution(token) { yield }
        else
          yield
        end
      end

      def set(test_id, thread_sources: nil)
        clear
        token = AttributionToken.new(test_id, thread_sources:)
        Thread.current.thread_variable_set(KEY, token)
        token
      end

      def clear
        token = Thread.current.thread_variable_get(KEY)
        Thread.current.thread_variable_set(KEY, nil)
        token ? token.revoke : []
      end

      def begin_boundary(attribution: attribution_token)
        @active_boundaries = @active_boundaries.to_i + 1
        @sole_active_attribution = (@active_boundaries == 1) ? attribution : nil
      end

      def end_boundary
        @active_boundaries = [@active_boundaries.to_i - 1, 0].max
        @sole_active_attribution = nil
      end

      def boundary_active?
        @active_boundaries.to_i.positive?
      end

      def reset_boundaries!
        @active_boundaries = 0
        @sole_active_attribution = nil
      end
    end
  end
end

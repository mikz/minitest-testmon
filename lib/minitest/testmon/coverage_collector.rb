# frozen_string_literal: true

require "coverage"

module Minitest
  module Testmon
    class CoverageCollector
      def initialize(session, resolver:, allowed_roots: [:project], allowed_paths: nil)
        @session = session
        @resolver = resolver
        @allowed_roots = Array(allowed_roots).map(&:to_sym).freeze
        @allowed_paths = allowed_paths && Array(allowed_paths).to_h { |path| [File.expand_path(path), true] }.freeze
        @snapshots = {}
        @mutex = Mutex.new
        @active = 0
        ensure_started
      end

      def begin_test(test_id)
        ambiguous = @mutex.synchronize do
          @active += 1
          @active > 1
        end
        if ambiguous
          @session.record(Observation.build(kind: :coverage_lines, operation: :begin_test, test_id: test_id, reason: :ambiguous_context))
          @snapshots[test_id] = nil
        else
          @snapshots[test_id] = snapshot
        end
        token = ExecutionContext.set(test_id, thread_sources: @allowed_paths)
        ExecutionContext.begin_boundary(attribution: token)
      end

      def finish_test(test_id)
        before = @snapshots.delete(test_id)
        after = snapshot if before
        if before && after
          coverage_delta(before, after).each do |path, lines|
            @session.record(Observation.build(
              kind: :coverage_lines,
              provider: :"ruby@1",
              path: path,
              operation: :coverage_delta,
              test_id: test_id,
              exists_at_observation: File.exist?(path),
              details: {lines: lines}
            ))
          end
        end
      ensure
        leaked_threads = ExecutionContext.clear
        @session.incomplete(:thread_leak) unless leaked_threads.empty?
        ExecutionContext.end_boundary
        @mutex.synchronize { @active -= 1 }
      end

      def reset_for_fork!
        @snapshots = {}
        @mutex = Mutex.new
        @active = 0
        ExecutionContext.clear
        ExecutionContext.reset_boundaries!
        ensure_started
      end

      def boundary_active?
        # TracePoint can ask while begin_test/finish_test already owns @mutex.
        # MRI executes this integer read under the GVL, so taking the same
        # non-reentrant mutex here would create a false provider failure.
        @active.positive?
      end

      private

      def ensure_started
        Coverage.start(lines: true, eval: true) unless Coverage.running?
      rescue RuntimeError
        @session.record(Observation.build(kind: :coverage_lines, provider: :"ruby@1", operation: :start, reason: :late_activation))
      end

      def snapshot
        # MRI returns independent counter arrays. Retain this snapshot directly;
        # resolving every loaded source here costs two filesystem walks per test.
        Coverage.peek_result
      end

      def coverage_delta(before, after)
        after.each_with_object({}) do |(path, entry), output|
          counters = coverage_lines(entry)
          previous = coverage_lines(before[path])
          next if counters == previous

          lines = counters.each_index.filter_map do |index|
            current = counters[index]
            prior = previous[index]
            next unless current.is_a?(Integer) && current > prior.to_i
            index + 1
          end
          # Resolve live paths only when execution changed their counters. In
          # particular, retargeting a symlink must not invent historical hits.
          next if lines.empty? || !project_path?(path)
          output[File.expand_path(path)] = lines
        end
      end

      def coverage_lines(entry)
        Array(entry.is_a?(Hash) ? entry[:lines] : entry)
      end

      def project_path?(path)
        locator = @resolver.resolve(path)
        return false unless @allowed_roots.include?(locator.root)
        !@allowed_paths || @allowed_paths.key?(locator.absolute_path)
      rescue PathError, ArgumentError
        false
      end
    end
  end
end

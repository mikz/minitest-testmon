# frozen_string_literal: true

require "fileutils"
require "minitest"
require "securerandom"

module Minitest
  module Testmon
    class Runtime
      attr_reader :selection

      def initialize(configuration:, registry:)
        @parent_pid = Process.pid
        @configuration = configuration.snapshot
        @snapshot = registry.snapshot(@configuration)
        @store = Store.new(@configuration.database_path)
        @mode = ENV.fetch("MINITEST_TESTMON_MODE", "run").to_sym
        @run_id = ENV["MINITEST_TESTMON_RUN_ID"] || SecureRandom.uuid
        @store.begin_run(run_id: @run_id, mode: @mode, context_signature: @snapshot.signature)
        @process_parallel = false
        @exit_state = nil
      end

      def install(options)
        @exit_state = options.fetch(:minitest_testmon_exit_state)
        discovered = discovered_tests
        @session = @snapshot.observe(tests: {discovered: discovered}, selected: [], mode: @mode)
        Testmon.take_early_observations.each { |observation| @session.record(observation) }
        core_roots = @snapshot.ruby_inventory_roots
        core_paths = @snapshot.ruby_inventory_paths
        @collector = CoverageCollector.new(
          @session,
          resolver: @snapshot.context.resolver,
          allowed_roots: core_roots,
          allowed_paths: core_paths
        )
        @session.attach_observer(CoreObserver.new(
          @session,
          resolver: @snapshot.context.resolver,
          allowed_roots: core_roots,
          ruby_paths: core_paths,
          unhookable_ruby_paths: @snapshot.ruby_unhookable_paths,
          test_only: true,
          observe_files: @mode == :discover || @snapshot.claims_event?(:file_open, :file_read),
          boundary_tracker: @collector
        ).start)
        reject_thread_parallelism!(discovered)

        @process_parallel = rails_process_parallel?(discovered)
        prepare_process_run if @process_parallel
        @store.acquire_lease!(run_id: @run_id)
        discard_recovered_worker_spools!
        @selection = choose_selection
        unless @session.startup_complete?
          @selection = Selection.new(mode: :full, tests: [], reasons: ["provider_incomplete"], generation: @store.generation)
        end
        selected = selected_tests(discovered, @selection)
        @selected_tests = selected
        @session.selected!(selected)
        @session.selection_mode!(@selection.mode)
        apply_selection(options, selected, @selection)

        install_process_worker_hooks if @process_parallel

        reporter = RuntimeReporter.new(self, @collector, @session, @store, @configuration, mode: @mode)
        Minitest.reporter << reporter
        reporter
      rescue LeaseUnavailable
        write_rejected_report("cache_lease_unavailable", discovered || discovered_tests)
        @store.close
        raise
      end

      def process_parallel?
        @process_parallel
      end

      def infrastructure_failure!(reason)
        @exit_state[:status] = 4
        reason
      end

      def merge_worker_spools!
        return unless process_parallel?
        raise PhaseError, "only the original parent may merge worker evidence" unless Process.pid == @parent_pid
        @store.reconnect!
        merged = WorkerSpool.merge(
          directory: worker_spool_root,
          run_id: @run_id,
          worker_count: @worker_count,
          context_signature: @snapshot.signature,
          generation: @selection.generation,
          expected_tests: @selected_tests
        )
        merged.observations.each { |observation| @session.import_observation(observation) }
        merged.executed.each { |test_id| @session.import_executed(test_id) }
        if merged.complete
          @session.incomplete(:worker_incomplete) unless discard_validated_worker_run!
        else
          @session.incomplete(:worker_incomplete)
        end
      end

      private

      def choose_selection
        return Selection.new(mode: :full, tests: [], reasons: ["discovery"], generation: @store.generation) if @mode == :discover
        selection_from_environment || @store.select(
          @snapshot.context.artifacts,
          context_signature: @snapshot.signature,
          roots: @configuration.roots
        )
      end

      def discovered_tests
        Minitest::Runnable.runnables.flat_map do |klass|
          klass.runnable_methods.map { |method| "#{klass}##{method}" }
        end.uniq.sort
      end

      def selected_tests(discovered, selection)
        case selection.mode
        when :full then discovered
        when :subset then discovered & selection.tests
        when :none then []
        else discovered
        end
      end

      def selection_from_environment
        payload = ENV["MINITEST_TESTMON_SELECTION"]
        return unless payload
        parsed = CanonicalJSON.parse(payload)
        return unless parsed["context_signature"] == @snapshot.signature
        return unless parsed["generation"] == @store.generation
        unless parsed["snapshot_digest"] == @snapshot.snapshot_digest
          @session.incomplete(:source_drift)
          return Selection.new(
            mode: :full,
            tests: [],
            reasons: ["source_drift"],
            generation: @store.generation
          )
        end
        mode = parsed.fetch("mode").to_sym
        return unless %i[full subset none].include?(mode)
        Selection.new(
          mode: mode,
          tests: Array(parsed["tests"]).map(&:to_s).uniq.sort,
          reasons: Array(parsed["reasons"]).map(&:to_s).uniq.sort,
          generation: parsed["generation"]
        )
      rescue JSON::ParserError, KeyError
        nil
      end

      def apply_selection(options, selected, selection)
        case selection.mode
        when :subset
          exact = selected.map { |test_id| Regexp.escape(test_id) }
          options[:include] = Regexp.new("\\A(?:#{exact.join("|")})\\z")
        when :none
          options[:include] = nil
          options[:exclude] = /.*/
        end
      end

      def rails_executor
        executor = Minitest.parallel_executor
        return unless executor.respond_to?(:parallelize_with) && executor.respond_to?(:size)
        executor
      end

      def reject_thread_parallelism!(discovered)
        native_parallel = Minitest::Runnable.runnables.any? do |runnable|
          runnable.respond_to?(:run_order) && runnable.run_order == :parallel
        end
        executor = rails_executor
        rails_threads = executor && executor.parallelize_with == :threads && parallel_executor_will_run?(executor, discovered)
        return unless native_parallel || rails_threads
        message = "unsupported_parallelism: minitest-testmon supports serial tests and Rails process parallelization; test threads are unsupported"
        write_rejected_report("unsupported_parallelism", discovered)
        @store.close
        raise UnsupportedParallelism, message
      end

      def rails_process_parallel?(discovered)
        executor = rails_executor
        executor && executor.parallelize_with == :processes && parallel_executor_will_run?(executor, discovered)
      end

      def parallel_executor_will_run?(executor, discovered)
        return false unless executor.size.to_i > 1
        ENV.key?("PARALLEL_WORKERS") || discovered.length > executor.threshold.to_i
      end

      def install_process_worker_hooks
        parallelization = ActiveSupport::Testing::Parallelization
        parallelization.before_fork_hook { before_worker_fork! }
        parallelization.after_fork_hook { |worker_number| after_worker_fork!(worker_number) }
        parallelization.run_cleanup_hook { |_worker_number| complete_worker! }
      end

      def prepare_process_run
        @worker_count = rails_executor.size.to_i
      end

      def discard_recovered_worker_spools!
        return unless @store.recovery_reason == "worker_incomplete"
        WorkerSpool.discard_incomplete_run(
          project_root: @configuration.project_root,
          run_id: @store.recovered_run_id
        )
      end

      def discard_validated_worker_run!
        WorkerSpool.discard_validated_run(
          project_root: @configuration.project_root,
          run_id: @run_id
        )
      rescue
        false
      end

      def before_worker_fork!
        raise PhaseError, "worker fork must originate in the lease-owning parent" unless Process.pid == @parent_pid
        @store.disconnect_for_fork!
      end

      def after_worker_fork!(worker_number)
        raise PhaseError, "worker inherited an open SQLite connection" if @store.connected?
        @worker_spool = WorkerSpool.new(
          directory: worker_spool_root,
          run_id: @run_id,
          worker_number: worker_number,
          context_signature: @snapshot.signature,
          generation: @selection.generation
        )
        @session.attach_spool(@worker_spool)
        @boundary_observer = TestBoundaryObserver.new(@session, @collector).start
      end

      # standard:disable Lint/RescueException
      def complete_worker!
        complete = true
        begin
          @boundary_observer&.close
        rescue
          complete = false
        end
        begin
          complete = false unless @session.close_observers_for_worker!
        rescue
          complete = false
        end
        @session.seal_worker!
        complete = !!@worker_spool&.complete! if complete
        safely_abort_worker_spool unless complete
        nil
      rescue Exception # Rails must always reach stop_worker after a cleanup failure.
        safely_seal_worker_session
        safely_abort_worker_spool
        nil
      end

      def safely_seal_worker_session
        @session&.seal_worker!
      rescue Exception
        nil
      end

      def safely_abort_worker_spool
        @worker_spool&.abort
      rescue Exception
        nil
      end
      # standard:enable Lint/RescueException

      def worker_spool_root
        File.join(@configuration.project_root, "tmp/minitest-testmon/workers")
      end

      def write_rejected_report(reason, discovered)
        selected = if @selection
          selected_tests(discovered, @selection)
        else
          []
        end
        if @session
          @session.selected!(selected)
          report = @session.finalize.with_generation(@store.generation).unpublished(reason)
        else
          report = DiscoveryReport.new(
            generation: @store.generation,
            context_signature: @snapshot.signature,
            mode: @mode,
            bundles: @snapshot.registrations.map { |item| "#{item.name}@#{item.version}" },
            tests: {discovered: discovered, selected: selected, executed: []},
            artifacts: @snapshot.context.artifacts,
            dependencies: @snapshot.context.dependencies,
            diagnostics: @snapshot.context.diagnostics,
            publication: {published: false, reason: reason},
            resolver: @snapshot.context.resolver
          )
        end
        @store.record_report(@run_id, report)
      rescue Error, SQLite3::Exception, SystemCallError
        nil
      end
    end

    class RuntimeReporter < Minitest::AbstractReporter
      def initialize(runtime, collector, session, store, configuration, mode:)
        super()
        @runtime = runtime
        @collector = collector
        @session = session
        @store = store
        @configuration = configuration
        @mode = mode
        @outcomes = {}
        @outcome_counts = Hash.new(0)
      end

      def prerecord(klass, name)
        test_id = "#{klass}##{name}"
        runnable = Minitest::Runnable.runnables.find { |candidate| candidate.to_s == klass.to_s }
        unless @runtime.process_parallel?
          @collector.begin_test(test_id)
          test = runnable&.new(name)
          @session.test_started(test) if test
        end
      end

      def record(result)
        test_id = "#{result.klass}##{result.name}"
        unless @runtime.process_parallel?
          @collector.finish_test(test_id)
          @session.executed(test_id)
        end
        @outcome_counts[test_id] += 1
        @session.incomplete(:duplicate_test_outcome) if @outcome_counts[test_id] > 1
        @outcomes[test_id] = if result.passed? && !result.skipped?
          :passed
        else
          (result.skipped? ? :skipped : :failed)
        end
      end

      def report
        @runtime.merge_worker_spools!
        report = @session.finalize
        published = if @mode == :discover
          @store.publish(report, outcomes: @outcomes, run_id: @runtime.instance_variable_get(:@run_id))
        elsif @runtime.selection.none?
          generation = @store.generation
          if report.complete?
            certified = report.certified(generation)
            @store.certify(certified, run_id: @runtime.instance_variable_get(:@run_id))
          else
            @store.publish(report, outcomes: @outcomes, run_id: @runtime.instance_variable_get(:@run_id))
          end
        else
          publication_reason = @runtime.selection.reasons.find do |reason|
            %w[cache_corrupt_rebuilt context_changed].include?(reason)
          end
          @store.publish(
            report,
            outcomes: @outcomes,
            publication_reason: publication_reason,
            run_id: @runtime.instance_variable_get(:@run_id)
          )
        end
        @runtime.infrastructure_failure!(published.publication[:reason]) if !published.publication[:published] &&
          published.publication[:reason] != "test_failure"
      rescue => error
        @runtime.infrastructure_failure!(:provider_incomplete)
        warn error.message
        rejected = report&.with_generation(@store.generation)&.unpublished("provider_incomplete")
        @store.record_report(@runtime.instance_variable_get(:@run_id), rejected) if rejected && @store.connected?
      ensure
        @store.reconnect! if @runtime.process_parallel? && !@store.connected? && Process.pid == @runtime.instance_variable_get(:@parent_pid)
        @store.release_lease! if @store.connected?
        @store.close
      end
    end
  end
end

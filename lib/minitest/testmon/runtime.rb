# frozen_string_literal: true

require "fileutils"
require "minitest"
require "securerandom"
require "time"

module Minitest
  module Testmon
    class Runtime
      attr_reader :selection

      def initialize(configuration:, registry:)
        @parent_pid = Process.pid
        @configuration = configuration.snapshot
        @snapshot = registry.snapshot(@configuration)
        @store = Store.new(
          @configuration.database_path,
          retained_reports: @configuration.retained_reports
        )
        @force_full = ENV["MINITEST_TESTMON_FULL"] == "1"
        @run_id = ENV["MINITEST_TESTMON_RUN_ID"] || SecureRandom.uuid
        @snapshots = {}.freeze
        @suite_input_ids = [].freeze
        @process_parallel = false
        @exit_state = nil
      end

      def install(options)
        installed = false
        ThreadContextPropagation.install!
        @exit_state = options.fetch(:minitest_testmon_exit_state)
        discovered = discovered_tests(options)
        @discovered = discovered
        @store.acquire_lease!(run_id: @run_id)
        @snapshots = @store.snapshots_for(discovered)
        @suite_input_ids = retained_suite_input_ids(@snapshots)
        @session = @snapshot.observe(
          tests: {discovered: discovered},
          selected: [],
          suite_input_ids: @suite_input_ids
        )
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
          observe_files: @force_full || @snapshot.claims_event?(:file_open, :file_read),
          boundary_tracker: @collector
        ).start)
        @process_parallel = rails_process_parallel?
        reject_unsupported_parallelism!(discovered)

        prepare_process_run if @process_parallel
        @current_inputs = current_inputs
        @selection = choose_selection
        unless @session.startup_complete?
          @selection = Selection.new(
            discovered: discovered,
            selected: discovered,
            reasons_by_test: discovered.to_h { |test_id| [test_id, ["provider_incomplete"]] },
            base_revision: @store.revision
          )
        end
        @session.retain_suite_input_ids!((@selection.selected == discovered) ? [] : @suite_input_ids)
        @store.start_execution(run_id: @run_id, selection: @selection)
        @selected_tests = @selection.selected
        @session.selected!(@selected_tests)
        apply_selection(options, @selected_tests)

        install_process_worker_hooks if @process_parallel

        reporter = RuntimeReporter.new(self, @collector, @session, @store, @configuration)
        Minitest.reporter << reporter
        installed = true
        reporter
      ensure
        @store.close unless installed
      end

      def process_parallel?
        @process_parallel
      end

      def infrastructure_failure!(reason)
        if reason.to_s == "unsupported_parallelism"
          @exit_state[:status] = 4
        elsif !supervised?
          warn "Testmon cache unchanged: evidence could not be safely published (#{reason})."
        end
        reason
      end

      def evidence(report, outcomes, publication_reason: nil)
        recorded_at = Time.now.utc.iso8601(6)
        builder = SnapshotBuilder.new
        snapshots = outcomes.filter_map do |test_id, outcome|
          next unless outcome == :passed

          snapshot = builder.call(
            test_id: test_id,
            current_inputs: @session.current_inputs,
            claimed_input_ids: @session.claimed_input_ids(test_id),
            test_definition_input: @snapshot.test_definition_input(test_id),
            recorded_at: recorded_at,
            run_id: @run_id
          )
          [test_id, snapshot]
        end.to_h
        source_stable = @snapshot.source_stable?
        RunEvidence.new(
          run_id: @run_id,
          base_revision: @selection.base_revision,
          report: report,
          selection: @selection,
          outcomes: outcomes,
          snapshots: snapshots,
          complete: report.complete?,
          source_stable: source_stable,
          publication_reason: publication_reason
        )
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
          base_revision: @selection.base_revision,
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

      def supervised?
        ENV.key?("MINITEST_TESTMON_RUN_ID")
      end

      def choose_selection
        Selector.new.call(
          discovered: @discovered,
          current_inputs: @current_inputs,
          snapshots: @snapshots,
          retries: @store.retries_for(@discovered),
          force: @force_full,
          base_revision: @store.revision,
          suite_input_ids: @suite_input_ids
        )
      end

      def retained_suite_input_ids(snapshots)
        context_input = @snapshot.current_inputs.find { |input| input.key == "$context" }
        return [].freeze unless context_input&.known?

        snapshots.values.filter_map do |snapshot|
          next unless snapshot.inputs.any? do |input|
            input.id == context_input.id && input.fingerprint == context_input.fingerprint
          end

          snapshot.inputs.select(&:suite?).map(&:id)
        end.flatten.uniq.sort_by(&:to_s).freeze
      end

      def discovered_tests(options)
        Minitest::Runnable.runnables.flat_map do |klass|
          klass.filter_runnable_methods(options).map { |method| "#{klass}##{method}" }
        end.uniq.sort
      end

      def apply_selection(options, selected)
        exact = selected.map { |test_id| Regexp.escape(test_id) }
        if exact.empty?
          # Minitest treats an empty positive filter as a usage failure. A
          # universal exclusion represents the same empty intersection while
          # retaining a successful zero-test run.
          options[:include] = nil
          options[:exclude] = /.*/
        else
          options[:include] = Regexp.new("\\A(?:#{exact.join("|")})\\z")
        end
      end

      def current_inputs
        return @snapshot.current_inputs if @snapshot.respond_to?(:current_inputs)

        @snapshot.context.artifacts.map do |artifact|
          Input.new(
            key: artifact.key,
            provider: artifact.provider,
            facet: artifact.facet,
            root: artifact.root,
            relative_path: artifact.relative_path,
            fingerprint: artifact.fingerprint,
            members: artifact.members,
            scope: artifact.scope
          )
        end
      end

      def rails_executor
        return unless defined?(ActiveSupport::Testing::ParallelizeExecutor)

        executor = Minitest.parallel_executor
        executor if executor.is_a?(ActiveSupport::Testing::ParallelizeExecutor)
      end

      def reject_unsupported_parallelism!(discovered)
        return unless unsupported_parallelism?

        reject_parallelism!(discovered)
      end

      def reject_parallelism!(discovered)
        @selection = Selection.new(
          discovered: discovered,
          selected: [],
          reasons_by_test: {},
          base_revision: @store.revision
        )
        @store.start_execution(run_id: @run_id, selection: @selection)
        infrastructure_failure!(:unsupported_parallelism)
        write_rejected_report("unsupported_parallelism", discovered)
        @store.close
        raise UnsupportedParallelism,
          "unsupported_parallelism: parallel tests require active Rails process parallelization"
      end

      def unsupported_parallelism?
        return false if process_parallel?

        executor = rails_executor
        active_non_process_executor = executor &&
          executor.parallelize_with != :processes &&
          parallel_executor_will_run?(executor)
        active_non_process_executor || parallel_runnables?
      end

      def parallel_runnables?
        Minitest::Runnable.runnables.any? do |runnable|
          runnable.respond_to?(:run_order) && runnable.run_order == :parallel
        end
      end

      def rails_process_parallel?
        executor = rails_executor
        executor && executor.parallelize_with == :processes && parallel_executor_will_run?(executor)
      end

      def parallel_executor_will_run?(executor)
        return false unless executor.size.to_i > 1

        ENV["PARALLEL_WORKERS"] || rails_tests_count > executor.threshold.to_i
      end

      def rails_tests_count
        Minitest::Runnable.runnables.sum { |runnable| runnable.runnable_methods.size }
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
          base_revision: @selection.base_revision
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
        selected = @selection ? @selection.selected : []
        if @session
          @session.selected!(selected)
          report = @session.finalize.with_generation(@store.revision).unpublished(reason)
        else
          report = DiscoveryReport.new(
            generation: @store.revision,
            context_signature: @snapshot.signature,
            mode: :run,
            bundles: @snapshot.registrations.map { |item| "#{item.name}@#{item.version}" },
            tests: {discovered: discovered, selected: selected, executed: []},
            artifacts: @snapshot.context.artifacts,
            dependencies: @snapshot.context.dependencies,
            diagnostics: @snapshot.context.diagnostics,
            publication: {published: false, reason: reason},
            resolver: @snapshot.context.resolver
          )
        end
        @store.publish(RunEvidence.new(
          run_id: @run_id,
          base_revision: @selection&.base_revision,
          report: report,
          selection: @selection,
          outcomes: {},
          snapshots: {},
          complete: false,
          source_stable: false,
          publication_reason: reason
        ))
      rescue Error, SQLite3::Exception, SystemCallError
        nil
      end
    end

    class RuntimeReporter < Minitest::AbstractReporter
      def initialize(runtime, collector, session, store, configuration)
        super()
        @runtime = runtime
        @collector = collector
        @session = session
        @store = store
        @configuration = configuration
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
        evidence = @runtime.evidence(report, @outcomes)
        published = @store.publish(evidence)
        @runtime.infrastructure_failure!(published.publication[:reason]) if !published.publication[:published] &&
          published.publication[:reason] != "test_failure"
      rescue => error
        @runtime.infrastructure_failure!(:provider_incomplete)
        warn error.message
      ensure
        close_store(preserving: $!)
      end

      private

      # standard:disable Lint/RescueException
      def close_store(preserving:)
        cleanup_error = nil
        begin
          @store.reconnect! if @runtime.process_parallel? && !@store.connected? && Process.pid == @runtime.instance_variable_get(:@parent_pid)
          @store.release_lease! if @store.connected?
        rescue Exception => error
          cleanup_error = error
        ensure
          begin
            @store.close
          rescue Exception => error
            cleanup_error ||= error
          end
        end
        raise cleanup_error if cleanup_error && !preserving
      end
      # standard:enable Lint/RescueException
    end
  end
end

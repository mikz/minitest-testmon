# frozen_string_literal: true

require_relative "test_helper"

class WorkerSpoolTest < TestmonTestCase
  RUN_ID = "11111111-1111-4111-8111-111111111111"

  def test_streams_high_observation_volume_and_merges_after_one_terminal_flush
    with_project do |project|
      spool = build_spool(project)
      1_000.times do |index|
        spool.record_observation(observation(index))
      end
      spool.record_executed("ExampleTest#test_many")

      assert_operator File.size(spool.temporary_path), :>, 0
      refute spool.instance_variable_defined?(:@records)
      assert spool.complete!
      refute File.exist?(spool.temporary_path)
      assert File.file?(spool.final_path)

      merged = merge(project)
      assert merged.complete
      assert_equal 1_000, merged.observations.length
      assert_equal ["ExampleTest#test_many"], merged.executed
    end
  end

  def test_round_trip_preserves_provider_owned_detail_key_shape
    with_project do |project|
      spool = build_spool(project)
      item = Minitest::Testmon::Observation.build(
        kind: :custom_lookup,
        provider: :custom,
        test_id: "ExampleTest#test_value",
        details: {"path" => "config/value.yml", "nested" => {"value" => 1}}
      )
      spool.record_observation(item)
      assert spool.complete!

      round_trip = merge(project).observations.fetch(0)

      assert_equal item.details, round_trip.details
      assert_equal "config/value.yml", round_trip.details.fetch("path")
    end
  end

  def test_round_trip_preserves_explicit_suite_evidence_provenance
    with_project do |project|
      spool = build_spool(project)
      item = Minitest::Testmon::Observation.build(
        kind: :ruby_require,
        path: "/project/lib/boot_helper.rb"
      ).as_suite_evidence
      spool.record_observation(item)
      assert spool.complete!

      round_trip = merge(project).observations.fetch(0)

      assert round_trip.explicit_suite_evidence?
      assert_equal :suite, round_trip.scope
      assert_nil round_trip.test_id
    end
  end

  def test_completion_failure_leaves_an_incomplete_spool_and_does_not_raise
    with_project do |project|
      spool = build_spool(project)
      spool.record_observation(observation(1))
      spool.define_singleton_method(:fsync_directory) { raise IOError, "forced" }

      refute spool.complete!
      assert File.file?(spool.temporary_path)
      refute File.exist?(spool.final_path)
      refute merge(project).complete
    end
  end

  def test_sealed_worker_session_drops_post_close_writes
    with_project do |project|
      configuration = Minitest::Testmon::Configuration.new(cwd: project).snapshot
      registry = Minitest::Testmon::ProviderRegistry.new
      session = registry.snapshot(configuration).observe
      spool = build_spool(project)
      session.attach_spool(spool)
      session.seal_worker!

      session.record(observation(1))
      session.executed("ExampleTest#test_late")
      assert spool.complete!

      merged = merge(project)
      assert merged.complete
      assert_empty merged.observations
      assert_empty merged.executed
    end
  end

  def test_worker_completion_failure_never_raises_into_rails_and_preserves_close_order
    events = []
    boundary = Object.new
    boundary.define_singleton_method(:close) { events << :boundary }
    session = Object.new
    session.define_singleton_method(:close_observers_for_worker!) {
      events << :providers
      true
    }
    session.define_singleton_method(:seal_worker!) { events << :seal }
    spool = Object.new
    spool.define_singleton_method(:complete!) {
      events << :terminal
      raise IOError, "forced"
    }
    spool.define_singleton_method(:abort) {
      events << :abort
      raise IOError, "forced abort"
    }
    runtime = Minitest::Testmon::Runtime.allocate
    runtime.instance_variable_set(:@boundary_observer, boundary)
    runtime.instance_variable_set(:@session, session)
    runtime.instance_variable_set(:@worker_spool, spool)

    assert_nil runtime.send(:complete_worker!)
    assert_equal %i[boundary providers seal terminal seal abort], events
  end

  def test_reporter_surfaces_cleanup_failure_after_successful_publication
    runtime = Object.new
    runtime.define_singleton_method(:merge_worker_spools!) { true }
    runtime.define_singleton_method(:process_parallel?) { false }
    runtime.define_singleton_method(:infrastructure_failure!) { |_reason| true }
    runtime.define_singleton_method(:evidence) { |_report, _outcomes| :evidence }
    runtime.define_singleton_method(:selection) do
      Minitest::Testmon::Selection.new(
        discovered: [], selected: [], reasons_by_test: {}, base_revision: nil
      )
    end
    published = Struct.new(:publication).new({published: true, reason: nil})
    session = Object.new
    session.define_singleton_method(:finalize) { published }
    store = Object.new
    store.define_singleton_method(:publish) { |_report, **_options| published }
    store.define_singleton_method(:connected?) { true }
    store.define_singleton_method(:release_lease!) { raise Minitest::Testmon::LeaseUnavailable, "forced cleanup failure" }
    closed = false
    store.define_singleton_method(:close) { closed = true }
    reporter = Minitest::Testmon::RuntimeReporter.new(runtime, nil, session, store, nil)

    error = assert_raises(Minitest::Testmon::LeaseUnavailable) do
      reporter.report
    end
    assert_equal "forced cleanup failure", error.message
    assert closed
  end

  def test_merge_rejects_a_sealed_spool_missing_an_expected_test
    with_project do |project|
      spool = build_spool(project)
      spool.record_executed("ExampleTest#test_one")
      assert spool.complete!

      merged = merge(project, expected_tests: %w[ExampleTest#test_one ExampleTest#test_two])
      refute merged.complete
      assert_equal ["ExampleTest#test_one"], merged.executed
    end
  end

  def test_merge_rejects_duplicate_terminal_execution_records
    with_project do |project|
      spool = build_spool(project)
      2.times { spool.record_executed("ExampleTest#test_one") }
      assert spool.complete!

      merged = merge(project, expected_tests: ["ExampleTest#test_one"])
      refute merged.complete
      assert_equal ["ExampleTest#test_one"], merged.executed
    end
  end

  def test_runtime_imports_a_complete_run_then_removes_exactly_its_uuid_directory
    with_project do |project|
      spool = build_runtime_spool(project)
      item = observation(1)
      spool.record_observation(item)
      spool.record_executed("ExampleTest#test_many")
      assert spool.complete!
      session = ImportSession.new
      runtime = build_runtime(project, session)

      runtime.merge_worker_spools!

      assert_equal [item.with(details: {"lines" => [2]})], session.observations
      assert_equal ["ExampleTest#test_many"], session.executed
      assert_empty session.diagnostics
      refute File.exist?(File.dirname(spool.final_path))
    end
  end

  def test_runtime_preserves_an_incomplete_run_directory_for_recovery
    with_project do |project|
      spool = build_runtime_spool(project)
      spool.record_observation(observation(1))
      session = ImportSession.new
      runtime = build_runtime(project, session)

      runtime.merge_worker_spools!

      assert File.directory?(File.dirname(spool.temporary_path))
      assert_equal ["worker_incomplete"], session.diagnostics
    ensure
      spool&.abort
    end
  end

  def test_runtime_fails_closed_when_a_validated_run_cannot_be_removed
    with_project do |project|
      spool = build_runtime_spool(project)
      spool.record_executed("ExampleTest#test_many")
      assert spool.complete!
      session = ImportSession.new
      runtime = build_runtime(project, session)
      runtime.define_singleton_method(:discard_validated_worker_run!) { false }

      runtime.merge_worker_spools!

      assert File.directory?(File.dirname(spool.final_path))
      assert_equal ["worker_incomplete"], session.diagnostics
    end
  end

  def test_validated_cleanup_refuses_a_workers_symlink_to_an_outside_uuid
    with_project do |project|
      Dir.mktmpdir("minitest-testmon-outside-workers") do |outside|
        target = File.join(outside, RUN_ID)
        sentinel = write_file(File.join(target, "sentinel"), "keep")
        base = File.join(project, "tmp/minitest-testmon")
        FileUtils.mkdir_p(base)
        File.symlink(outside, File.join(base, "workers"))

        refute Minitest::Testmon::WorkerSpool.discard_validated_run(
          project_root: project,
          run_id: RUN_ID
        )
        assert File.file?(sentinel)
        assert File.directory?(target)
      end
    end
  end

  def test_validated_cleanup_refuses_a_symlinked_tmp_ancestor
    with_project do |project|
      Dir.mktmpdir("minitest-testmon-outside-tmp") do |outside|
        target = File.join(outside, "minitest-testmon", "workers", RUN_ID)
        sentinel = write_file(File.join(target, "sentinel"), "keep")
        File.symlink(outside, File.join(project, "tmp"))

        refute Minitest::Testmon::WorkerSpool.discard_validated_run(
          project_root: project,
          run_id: RUN_ID
        )
        assert File.file?(sentinel)
        assert File.directory?(target)
      end
    end
  end

  def test_validated_cleanup_removes_a_normal_direct_uuid_child_only
    with_project do |project|
      workers = File.join(project, "tmp/minitest-testmon/workers")
      target = File.join(workers, RUN_ID)
      write_file(File.join(target, "nested", "spool.jsonl"), "sealed")

      assert Minitest::Testmon::WorkerSpool.discard_validated_run(
        project_root: project,
        run_id: RUN_ID
      )
      refute File.exist?(target)
      assert File.directory?(workers)
      assert File.directory?(File.join(project, "tmp/minitest-testmon"))
    end
  end

  private

  def build_spool(project)
    Minitest::Testmon::WorkerSpool.new(
      directory: File.join(project, "workers"),
      run_id: RUN_ID,
      worker_number: 0,
      context_signature: "context",
      base_revision: 1
    )
  end

  def build_runtime_spool(project)
    Minitest::Testmon::WorkerSpool.new(
      directory: File.join(project, "tmp/minitest-testmon/workers"),
      run_id: RUN_ID,
      worker_number: 0,
      context_signature: "context",
      base_revision: 1
    )
  end

  def build_runtime(project, session)
    runtime = Minitest::Testmon::Runtime.allocate
    runtime.instance_variable_set(:@process_parallel, true)
    runtime.instance_variable_set(:@parent_pid, Process.pid)
    runtime.instance_variable_set(:@run_id, RUN_ID)
    runtime.instance_variable_set(:@worker_count, 1)
    runtime.instance_variable_set(:@snapshot, Struct.new(:signature).new("context"))
    runtime.instance_variable_set(:@selection, Struct.new(:base_revision).new(1))
    runtime.instance_variable_set(:@selected_tests, ["ExampleTest#test_many"])
    runtime.instance_variable_set(:@session, session)
    runtime.instance_variable_set(:@store, Struct.new(:reconnect!).new(true))
    runtime.instance_variable_set(:@configuration, Struct.new(:project_root).new(project))
    runtime
  end

  def merge(project, expected_tests: nil)
    Minitest::Testmon::WorkerSpool.merge(
      directory: File.join(project, "workers"),
      run_id: RUN_ID,
      worker_count: 1,
      context_signature: "context",
      base_revision: 1,
      expected_tests: expected_tests
    )
  end

  def observation(index)
    Minitest::Testmon::Observation.build(
      kind: :coverage_lines,
      path: "/project/lib/example.rb",
      operation: :coverage_delta,
      test_id: "ExampleTest#test_many",
      details: {lines: [index + 1]}
    )
  end

  class ImportSession
    attr_reader :observations, :executed, :diagnostics

    def initialize
      @observations = []
      @executed = []
      @diagnostics = []
    end

    def import_observation(observation)
      @observations << observation
    end

    def import_executed(test_id)
      @executed << test_id
    end

    def incomplete(reason)
      @diagnostics << reason.to_s
    end
  end
end

# frozen_string_literal: true

require_relative "test_helper"

class RuntimeTest < TestmonTestCase
  def test_snapshot_builder_reuses_catalog_until_immutable_inputs_change
    fingerprint = Minitest::Testmon::Fingerprint.known("digest")
    definition = Minitest::Testmon::Input.new(key: "test", provider: "test", facet: "content", fingerprint: fingerprint)
    inputs = [definition].freeze
    session = Struct.new(:current_inputs) do
      def claimed_input_ids(_test_id) = []
    end.new(inputs)
    snapshot = Object.new
    snapshot.define_singleton_method(:test_definition_input) { |_test_id| definition }
    builder_class = Class.new(Minitest::Testmon::SnapshotBuilder) do
      attr_reader :index_builds

      private

      def index_inputs(inputs)
        @index_builds = @index_builds.to_i + 1 unless inputs.frozen? && inputs.equal?(@indexed_inputs)
        super
      end
    end
    builder = builder_class.new
    runtime = Minitest::Testmon::Runtime.allocate
    runtime.instance_variable_set(:@snapshot, snapshot)
    runtime.instance_variable_set(:@session, session)
    runtime.instance_variable_set(:@run_id, "run")
    runtime.instance_variable_set(:@snapshot_builder, builder)
    outcomes = {"Example#test" => :passed}
    first = runtime.build_snapshots(outcomes)
    second = runtime.build_snapshots(outcomes)
    assert_equal 1, builder.index_builds
    assert_equal first.fetch("Example#test").inputs, second.fetch("Example#test").inputs

    shared = definition.with(key: "shared", scope: :suite)
    session.current_inputs = [definition, shared].freeze
    updated = runtime.build_snapshots(outcomes)
    assert_equal 2, builder.index_builds
    assert_includes updated.fetch("Example#test").inputs, shared
  end

  def test_checkpoint_cadence_preserves_initial_progress_and_amortizes_expensive_batches
    runtime = Minitest::Testmon::Runtime.allocate
    runtime.instance_variable_set(:@last_checkpoint_at, 0.0)
    runtime.instance_variable_set(:@pending_checkpoints, 25.times.to_h { |id| [id, :passed] })
    runtime.instance_variable_set(:@checkpoint_cost, 0.0)
    assert runtime.checkpoint_due?(0.1), "first batch must remain available promptly"

    runtime.instance_variable_set(:@checkpoint_cost, 0.5)
    refute runtime.checkpoint_due?(5.0), "another batch must not spend 10% of elapsed time checkpointing"
    assert runtime.checkpoint_due?(9.5)

    runtime.instance_variable_set(:@checkpoint_cost, 10.0)
    refute runtime.checkpoint_due?(29.0)
    assert runtime.checkpoint_due?(30.0), "slow validation must not postpone progress indefinitely"
  end

  def test_sparse_results_checkpoint_at_the_time_boundary
    runtime = Minitest::Testmon::Runtime.allocate
    runtime.instance_variable_set(:@last_checkpoint_at, 10.0)
    runtime.instance_variable_set(:@checkpoint_cost, 0.01)
    runtime.instance_variable_set(:@pending_checkpoints, {"one" => :passed})
    refute runtime.checkpoint_due?(14.9)
    assert runtime.checkpoint_due?(15.0)
  end

  def test_setup_failure_closes_the_store_so_the_next_run_can_acquire_the_lease
    with_project do |project|
      configuration = Minitest::Testmon::Configuration.new(cwd: project)
      runtime = Minitest::Testmon::Runtime.new(
        configuration: configuration,
        registry: Minitest::Testmon::ProviderRegistry.new
      )
      test_id = "ExampleTest#test_value"
      runtime.define_singleton_method(:discovered_tests) { |_options| [test_id] }
      runtime.define_singleton_method(:apply_selection) { |_options, _selected| raise "setup failure" }

      error = assert_raises(RuntimeError) do
        runtime.install(minitest_testmon_exit_state: {status: 0})
      end
      assert_equal "setup failure", error.message

      replacement = Minitest::Testmon::Store.new(configuration.database_path)
      assert replacement.acquire_lease!(run_id: "after-failure")
      receipt = replacement.runs(limit: 1).fetch(0)
      assert_equal "abandoned", receipt.fetch("state")
      assert_equal "worker_incomplete", receipt.fetch("publication_reason")
      assert_equal :running, replacement.retries_for([test_id]).fetch(test_id).outcome
    ensure
      runtime&.instance_variable_get(:@session)&.close_observers_for_worker!
      replacement&.close
      runtime&.instance_variable_get(:@store)&.close
    end
  end
end

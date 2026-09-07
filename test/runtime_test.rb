# frozen_string_literal: true

require_relative "test_helper"

class RuntimeTest < TestmonTestCase
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

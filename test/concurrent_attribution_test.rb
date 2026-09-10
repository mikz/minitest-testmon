# frozen_string_literal: true

require_relative "test_helper"
require "concurrent-ruby"
require "open3"
require "rbconfig"

class ConcurrentAttributionTest < TestmonTestCase
  Context = Minitest::Testmon::ExecutionContext

  def setup
    Minitest::Testmon::ConcurrentContextPropagation.install!
  end

  def teardown
    Context.clear
    Context.reset_boundaries!
  end

  def test_reused_pool_restores_context_after_success_and_failure
    pool = Concurrent::SingleThreadExecutor.new
    Context.clear
    Concurrent::Promises.future_on(pool) { nil }.value!
    %w[first second].each do |id|
      Context.set(id)
      assert_equal id, Concurrent::Promises.future_on(pool) { Context.current_test }.value!
      assert_raises(RuntimeError) { Concurrent::Promises.future_on(pool) { raise "failed task" }.value! }
      assert_empty Context.clear
      assert_nil Concurrent::Promises.future_on(pool) { Context.current_test }.value!
    end
  ensure
    pool&.shutdown
    pool&.wait_for_termination
  end

  def test_continuation_uses_registration_token_during_overlapping_resolution
    Context.set("registered")
    registered = Context.attribution_token
    Context.begin_boundary
    pending = Concurrent::Promises.resolvable_future
    future = pending.then_on(:immediate) { [Context.current_test, Context.evidence_scope] }
    Context.with_test("resolver") do
      Context.begin_boundary
      assert_nil Context.sole_active_attribution
      pending.fulfill(true)
      assert_equal "resolver", Context.current_test
      Context.end_boundary
    end
    assert_equal ["registered", :test], future.value!
    assert_same registered, Context.attribution_token
  end

  def test_revoked_and_unattributed_continuations_do_not_borrow_resolver_context
    Context.clear
    outside = Concurrent::Promises.resolvable_future
    outside_task = outside.then_on(:immediate) { Context.current_test }
    Context.set("old")
    pending = Concurrent::Promises.resolvable_future
    future = pending.then_on(:immediate) { Context.current_test }
    Context.clear
    Context.set("new")
    pending.fulfill(true)
    outside.fulfill(true)
    assert_nil future.value!
    assert_nil outside_task.value!
    assert_equal "new", Context.current_test
  end

  def test_queued_task_loses_revoked_token_and_running_task_is_tracked
    Context.clear
    pool = Concurrent::SingleThreadExecutor.new
    entered = Queue.new
    release = Queue.new
    blocker = Concurrent::Promises.future_on(pool) do
      entered << true
      release.pop
    end
    entered.pop
    Context.set("queued")
    queued = Concurrent::Promises.future_on(pool) { Context.current_test }
    Context.clear
    Context.set("next")
    release << true
    blocker.value!
    assert_nil queued.value!
    task = Concurrent::Promises.future_on(pool) do
      entered << Thread.current
      release.pop
      Context.current_test
    end
    worker = entered.pop
    assert_includes Context.clear, worker
    release << true
    assert_nil task.value!
  ensure
    release << true if release
    pool&.shutdown
    pool&.wait_for_termination
  end

  def test_rescue_and_chain_capture_scope_and_preserve_arguments
    Context.set("registration")
    failed = Concurrent::Promises.resolvable_future
    recovered = Context.with_evidence_scope(:suite) do
      failed.rescue_on(:immediate, "argument") { |error, argument| [error.message, argument, Context.current_test, Context.evidence_scope] }
    end
    failed.reject(RuntimeError.new("reason"))
    assert_equal ["reason", "argument", "registration", :suite], recovered.value!
    chained = recovered.chain_on(:immediate, "tail") { |success, value, error, tail| [success, value.first, error, tail, Context.current_test] }
    assert_equal [true, "reason", nil, "tail", "registration"], chained.value!
  end

  def test_nested_immediate_task_does_not_unregister_running_outer_task
    Context.clear
    pool = Concurrent::SingleThreadExecutor.new
    Concurrent::Promises.future_on(pool) { nil }.value!
    Context.set("outer")
    entered = Queue.new
    release = Queue.new
    outer = Concurrent::Promises.future_on(pool) do
      nested = Concurrent::Promises.future_on(:immediate) { Context.current_test }.value!
      entered << [Thread.current, nested]
      release.pop
    end
    worker, nested = entered.pop
    assert_equal "outer", nested
    assert_includes Context.clear, worker
    release << true
    outer.value!
  ensure
    release << true if release
    pool&.shutdown
    pool&.wait_for_termination
  end

  def test_real_plugin_publishes_and_reuses_future_evidence
    with_project do |project|
      write_file(File.join(project, "lib/value.rb"), "module FutureValue; def self.call; 42; end; end\n")
      script = write_file(File.join(project, "test/future_test.rb"), <<~RUBY)
        require "minitest/autorun"
        require "concurrent-ruby"
        require_relative "../lib/value"
        POOL = Concurrent::SingleThreadExecutor.new
        Concurrent::Promises.future_on(POOL) { true }.value!
        Minitest.after_run { POOL.shutdown; POOL.wait_for_termination }
        class FutureTest < Minitest::Test
          def test_first
            assert_equal 42, Concurrent::Promises.future_on(POOL) { FutureValue.call }.value!
          end
          def test_second
            assert_equal 42, Concurrent::Promises.future_on(POOL) { FutureValue.call }.value!
          end
        end
      RUBY
      env = {"MINITEST_TESTMON" => "1", "MINITEST_TESTMON_DB" => File.join(project, ".minitest-testmon.sqlite3"), "MINITEST_TESTMON_PROJECT_ROOT" => project}
      2.times do |iteration|
        out, err, status = Open3.capture3(env, RbConfig.ruby, "-I#{File.expand_path("../lib", __dir__)}", "-rminitest/testmon_plugin", script, chdir: project)
        assert status.success?, "#{out}\n#{err}"
        store = Minitest::Testmon::Store.new(env.fetch("MINITEST_TESTMON_DB"))
        report = store.report
        assert report.dig("publication", "published"), report.fetch("diagnostics").inspect
        assert_empty report.fetch("diagnostics")
        assert_equal iteration.zero? ? 2 : 0, report.fetch("tests").fetch("selected").length
      ensure
        store&.close
      end
    end
  end

  def test_future_on_a_reused_pool_preserves_submission_attribution
    Minitest::Testmon::ThreadContextPropagation.install!
    Context.clear
    pool = Concurrent::SingleThreadExecutor.new
    worker = Concurrent::Promises.future_on(pool) { Thread.current }.value!
    with_project do |project|
      path = write_file(File.join(project, "task.rb"), "Thread.current[:testmon_task] = proc { [Thread.current, Minitest::Testmon::ExecutionContext.current_test] }")
      load path, true
      task = Thread.current[:testmon_task]
      Thread.current[:testmon_task] = nil
      Context.set("FutureTest#test_first", thread_sources: {File.realpath(path) => true}.freeze)
      Context.begin_boundary
      observed_worker, observed_test = Concurrent::Promises.future_on(pool, &task).value!
      assert_same worker, observed_worker
      assert_equal "FutureTest#test_first", observed_test
    end
  ensure
    Context.clear
    Context.reset_boundaries!
    pool&.shutdown
    pool&.wait_for_termination
  end
end

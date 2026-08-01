# frozen_string_literal: true

require_relative "test_helper"
require "minitest/testmon/request_attribution"

class ExecutionContextTest < TestmonTestCase
  Context = Minitest::Testmon::ExecutionContext

  def setup
    Minitest::Testmon::ThreadContextPropagation.install!
    Context.reset_boundaries!
    Context.clear
  end

  def teardown
    Context.reset_boundaries!
    Context.clear
  end

  def test_new_start_and_fork_propagate_a_live_test_attribution
    Context.set("GreetingsSystemTest#test_index")

    %i[new start fork].each do |constructor|
      assert_equal "GreetingsSystemTest#test_index", Thread.public_send(constructor) { Context.current_test }.value
    end
  end

  def test_install_is_idempotent
    Minitest::Testmon::ThreadContextPropagation.install!
    Minitest::Testmon::ThreadContextPropagation.install!

    assert_equal 1, Thread.singleton_class.ancestors.count(Minitest::Testmon::ThreadContextPropagation)
  end

  def test_nested_threads_share_the_live_attribution
    Context.set("NestedTest#test_child")

    assert_equal "NestedTest#test_child", Thread.new { Thread.new { Context.current_test }.value }.value
  end

  def test_nested_with_test_restores_the_live_outer_token
    Context.with_test("OuterTest#test_value") do
      Context.with_test("InnerTest#test_value") do
        assert_equal "InnerTest#test_value", Context.current_test
      end
      assert_equal "OuterTest#test_value", Context.current_test
      assert_equal "OuterTest#test_value", Thread.new { Context.current_test }.value
    end

    assert_nil Context.current_test
  end

  def test_threads_created_outside_a_test_remain_unattributed
    assert_nil Thread.new { Context.current_test }.value
  end

  def test_clear_revokes_attribution_in_a_leaked_child
    ready = Queue.new
    release = Queue.new
    observed = Queue.new
    Context.set("LeakyTest#test_child")
    child = Thread.new do
      ready << true
      release.pop
      observed << Context.current_test
    end
    ready.pop

    assert_equal [child], Context.clear
    release << true
    child.join

    assert_nil observed.pop
  end

  def test_collector_marks_a_live_child_as_a_thread_leak
    with_project do |project|
      session = RecordingSession.new
      collector = Minitest::Testmon::CoverageCollector.new(
        session,
        resolver: Minitest::Testmon::PathResolver.new(project: project),
        allowed_paths: []
      )
      ready = Queue.new
      release = Queue.new
      collector.begin_test("LeakyTest#test_child")
      child = Thread.new do
        ready << true
        release.pop
      end
      ready.pop

      collector.finish_test("LeakyTest#test_child")

      assert_equal ["thread_leak"], session.diagnostics
      release << true
      child.join
    ensure
      release << true if child&.alive?
      child&.join
    end
  end

  def test_blocking_borrowed_request_is_a_leak_and_loses_attribution
    with_project do |project|
      session = RecordingSession.new
      collector = Minitest::Testmon::CoverageCollector.new(
        session,
        resolver: Minitest::Testmon::PathResolver.new(project: project),
        allowed_paths: []
      )
      entered = Queue.new
      release = Queue.new
      observed = Queue.new
      app = ->(_env) do
        entered << Context.current_test
        release.pop
        observed << Context.current_test
        [200, {}, []]
      end
      middleware = Minitest::Testmon::RequestAttribution.new(app)
      request = Queue.new
      server = Thread.new do
        request.pop
        middleware.call({})
      end

      collector.begin_test("RequestTest#test_blocking")
      request << true
      assert_equal "RequestTest#test_blocking", entered.pop
      collector.finish_test("RequestTest#test_blocking")

      assert_equal ["thread_leak"], session.diagnostics
      release << true
      server.join
      assert_nil observed.pop
    ensure
      release << true if server&.alive?
      server&.join
    end
  end

  def test_overlapping_boundaries_clear_the_sole_active_attribution
    Context.set("FirstTest#test_a")
    Context.begin_boundary
    Context.begin_boundary

    assert_nil Context.sole_active_attribution

    Context.end_boundary
    # A survivor of an overlap stays ambiguous; it is not repaired
    # retroactively.
    assert_nil Context.sole_active_attribution
  ensure
    Context.reset_boundaries!
  end

  def test_ending_or_resetting_the_boundary_clears_the_sole_active_attribution
    Context.set("OnlyTest#test_a")
    Context.begin_boundary
    assert_equal "OnlyTest#test_a", Context.sole_active_attribution.test_id

    Context.end_boundary
    assert_nil Context.sole_active_attribution

    Context.set("OnlyTest#test_a")
    Context.begin_boundary
    Context.reset_boundaries!
    assert_nil Context.sole_active_attribution
  end

  def test_request_attribution_stamps_server_threads_for_the_request_duration
    observed = nil
    after_request = nil
    app = ->(_env) {
      observed = Context.current_test
      [200, {}, []]
    }
    middleware = Minitest::Testmon::RequestAttribution.new(app)
    ready = Queue.new
    request = Queue.new
    server = Thread.new do
      ready << true
      request.pop
      middleware.call({})
      after_request = Context.current_test
    end
    ready.pop

    Context.set("DashboardSystemTest#test_dashboard")
    Context.begin_boundary
    request << true
    server.join

    assert_equal "DashboardSystemTest#test_dashboard", observed
    assert_nil after_request
  ensure
    Context.clear
    Context.end_boundary
  end

  def test_request_attribution_is_inert_outside_boundaries_and_under_overlap
    observed = []
    app = ->(_env) {
      observed << Context.current_test
      [200, {}, []]
    }
    middleware = Minitest::Testmon::RequestAttribution.new(app)

    Thread.new { middleware.call({}) }.join

    ready = Queue.new
    release = Queue.new
    worker = Thread.new do
      ready << true
      release.pop
      middleware.call({})
    end
    ready.pop
    Context.set("FirstTest#test_a")
    Context.begin_boundary
    Context.begin_boundary
    release << true
    worker.join
    Context.reset_boundaries!

    assert_equal [nil, nil], observed
  end

  def test_request_attribution_keeps_an_existing_thread_local
    observed = nil
    app = ->(_env) {
      observed = Context.current_test
      [200, {}, []]
    }
    middleware = Minitest::Testmon::RequestAttribution.new(app)

    Context.set("ActiveTest#test_a")
    Context.begin_boundary
    Thread.new {
      Context.set("IntegrationTest#test_direct")
      middleware.call({})
    }.join

    assert_equal "IntegrationTest#test_direct", observed
  ensure
    Context.end_boundary
  end

  class RecordingSession
    attr_reader :diagnostics

    def initialize
      @diagnostics = []
    end

    def record(_observation)
    end

    def incomplete(reason)
      @diagnostics << reason.to_s
    end
  end
end

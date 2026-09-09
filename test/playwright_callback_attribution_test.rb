# frozen_string_literal: true

require_relative "test_helper"
require "playwright"
require "minitest/testmon/playwright_callback_attribution"

class PlaywrightCallbackAttributionTest < TestmonTestCase
  Context = Minitest::Testmon::ExecutionContext

  def setup
    Context.clear
    Context.reset_boundaries!
    # Use Playwright's real event source and public Page listener API without
    # starting a browser; the acceptance fixture covers transport and routes.
    @source = Object.new.extend(Playwright::EventEmitter)
    @page = Playwright::Page.new(@source)
    @page.extend(Minitest::Testmon::PlaywrightCallbackAttribution)
  end

  def teardown
    Context.clear
    Context.reset_boundaries!
  end

  def test_persistent_listener_borrows_each_boundary_and_off_removes_it
    received = Queue.new
    callback = ->(value) { received << [value, Context.current_test, Context.evidence_scope] }
    @page.on("response", callback)
    %w[first second].each do |id|
      Context.set(id, thread_sources: {})
      Context.begin_boundary
      Thread.new { @source.emit("response", id) }.value
      assert_equal [id, id, :suite], received.pop
      assert_empty Context.clear
      Context.end_boundary
    end
    @page.off("response", callback)
    @source.emit("response", "removed")
    assert received.empty?
  end

  def test_once_and_callbacks_outside_or_overlapping_boundaries
    received = Queue.new
    @page.once("response", -> { received << Context.current_test })
    @source.emit("response")
    @source.emit("response")
    assert_nil received.pop
    assert received.empty?

    @page.on("response", -> { received << Context.current_test })
    Context.set("first", thread_sources: {})
    Context.begin_boundary
    Context.begin_boundary
    Thread.new { @source.emit("response") }.value
    assert_nil received.pop
  end

  def test_in_flight_callback_is_revoked_and_dispatcher_does_not_keep_token
    entered = Queue.new
    release = Queue.new
    received = Queue.new
    @page.on("response", -> {
      entered << Context.current_test
      release.pop
      received << Context.current_test
    })
    Context.set("first", thread_sources: {})
    Context.begin_boundary
    dispatcher = Thread.new do
      @source.emit("response")
      received << Context.current_test
    end
    assert_equal "first", entered.pop
    assert_includes Context.clear, dispatcher
    Context.end_boundary
    release << true
    dispatcher.value
    assert_nil received.pop
    assert_nil received.pop
  ensure
    release << true if dispatcher&.alive?
    dispatcher&.join
  end
end

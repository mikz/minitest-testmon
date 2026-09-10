# frozen_string_literal: true

require_relative "../test_helper"
require "action_cable"
require "action_cable/subscription_adapter/async"

class ActionCableContextPropagationTest < TestmonTestCase
  Context = Minitest::Testmon::ExecutionContext
  Server = Struct.new(:logger, :mutex, :event_loop)

  class EventLoop
    def initialize
      @jobs = []
    end

    def post(&block)
      @jobs << block
    end

    def drain
      @jobs.shift.call until @jobs.empty?
    end
  end

  def setup
    Minitest::Testmon::ActionCableContextPropagation.install!
    Context.clear
  end

  def teardown
    Context.clear
    Context.reset_boundaries!
  end

  def test_array_delete_uses_wrapper_equality_and_keeps_frozen_original_untouched
    callback = proc {}.freeze
    wrapper = Minitest::Testmon::ActionCableContextPropagation::Callback.new(callback)
    duplicate = Minitest::Testmon::ActionCableContextPropagation::Callback.new(callback)
    other = Minitest::Testmon::ActionCableContextPropagation::Callback.new(proc {})
    entries = [wrapper, duplicate, other]
    assert_same duplicate, entries.delete(callback)
    assert_equal [other], entries
    assert_equal wrapper, duplicate
    assert callback.frozen?
  end

  def test_async_registration_and_success_capture_token_and_original_unsubscribes_duplicates
    event_loop = EventLoop.new
    adapter = ActionCable::SubscriptionAdapter::Async.new(Server.new(nil, Mutex.new, event_loop))
    observations = []
    callback = proc { |message| observations << [message, Context.current_test] }.freeze
    Context.set("subscriber")
    adapter.subscribe("channel", callback, proc { observations << [:success, Context.current_test] })
    adapter.subscribe("channel", callback)
    Context.with_test("event_loop") do
      event_loop.drain
      adapter.broadcast("channel", "message")
      event_loop.drain
      assert_equal "event_loop", Context.current_test
      adapter.unsubscribe("channel", callback)
      adapter.broadcast("channel", "removed")
      event_loop.drain
    end
    assert_equal [[:success, "subscriber"], ["message", "subscriber"], ["message", "subscriber"]], observations
    assert_empty adapter.send(:subscriber_map).instance_variable_get(:@subscribers)
    assert_empty Context.clear
  end

  def test_queued_delivery_after_revocation_cannot_borrow_next_boundary
    event_loop = EventLoop.new
    adapter = ActionCable::SubscriptionAdapter::Async.new(Server.new(nil, Mutex.new, event_loop))
    observations = []
    Context.set("old")
    callback = proc { observations << Context.current_test }
    adapter.subscribe("channel", callback)
    event_loop.drain
    adapter.broadcast("channel", "message")
    adapter.unsubscribe("channel", callback)
    Context.clear
    Context.set("next")
    event_loop.drain
    assert_equal [nil], observations
    assert_equal "next", Context.current_test
    assert_empty adapter.send(:subscriber_map).instance_variable_get(:@subscribers)
  end
end

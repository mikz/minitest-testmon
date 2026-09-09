# frozen_string_literal: true

require_relative "test_helper"

class GlobalTraceRouterTest < TestmonTestCase
  class Probe
    def value = :value
    def other = :other
  end

  def each_router
    [true, false].each do |native|
      router = Minitest::Testmon::GlobalTraceRouter.new(events: [:call], native:)
      yield router
    ensure
      router&.close
    end
  end

  def test_method_candidates_and_wildcards_keep_newest_first_order
    each_router do |router|
      seen = []
      router.subscribe(:call, :value) { seen << :first }
      router.subscribe(:call) { |event| seen << :wildcard if event.self.is_a?(Probe) }
      router.subscribe(:call, :value) { seen << :last }
      Probe.new.value
      Probe.new.other
      assert_equal [:last, :wildcard, :first, :wildcard], seen
    end
  end

  def test_disabling_and_reenabling_pending_subscription_waits_for_next_event
    each_router do |router|
      seen = []
      first = router.subscribe(:call, :value) { seen << :first }
      second = router.subscribe(:call, :value) do
        seen << :second
        first.disable
        first.enable
      end
      Probe.new.value
      assert_equal [:second], seen
      second.disable
      Probe.new.value
      assert_equal [:second, :first], seen
    end
  end

  def test_additions_wait_for_next_event_and_self_disable_takes_effect
    each_router do |router|
      seen = []
      subscription = router.subscribe(:call, :value) do
        seen << :original
        subscription.disable
        router.subscribe(:call, :value) { seen << :added }
      end
      Probe.new.value
      assert_equal [:original], seen
      Probe.new.value
      assert_equal [:original, :added], seen
    end
  end

  def test_first_subscription_is_active_immediately_and_sessions_are_isolated
    each_router do |router|
      seen = []
      first = router.subscribe(:call, :value) { seen << :first }
      Probe.new.value
      assert_equal [:first], seen
      other = Minitest::Testmon::GlobalTraceRouter.new(events: [:call])
      other.subscribe(:call, :value) { seen << :other }
      first.close
      Probe.new.value
      assert_equal [:first, :other], seen
      first.enable
      Probe.new.value
      assert_equal [:first, :other, :first, :other], seen
    ensure
      other&.close
    end
  end

  def test_exception_stops_current_event_and_later_events_still_work
    each_router do |router|
      seen = []
      router.subscribe(:call, :value) { seen << :older }
      failing = router.subscribe(:call, :value) { raise "observer failure" }
      assert_equal "observer failure", assert_raises(RuntimeError) { Probe.new.value }.message
      assert_empty seen
      failing.disable
      Probe.new.value
      assert_equal [:older], seen
    end
  end

  def test_callback_mutation_and_compaction_keep_current_candidate_snapshot_alive
    each_router do |router|
      seen = []
      router.subscribe(:call, :value) { seen << :older }
      newest = router.subscribe(:call, :value) do
        seen << :newest
        newest.disable
        GC.verify_compaction_references
      end
      Probe.new.value
      assert_equal [:newest, :older], seen
    end
  end
end

# frozen_string_literal: true

require_relative "test_helper"
require "minitest/testmon/input"
require "minitest/testmon/test_snapshot"
require "minitest/testmon/selection"
require "minitest/testmon/selector"

class SelectorTest < TestmonTestCase
  def setup
    @selector = Minitest::Testmon::Selector.new
  end

  def test_selects_only_entities_whose_own_input_changed
    one_v1 = input("one", "v1")
    two_v1 = input("two", "v1")
    snapshots = {
      "OneTest#test_one" => snapshot("OneTest#test_one", one_v1),
      "TwoTest#test_two" => snapshot("TwoTest#test_two", two_v1)
    }

    selection = @selector.call(
      discovered: snapshots.keys,
      current_inputs: {one_v1.id => input("one", "v2"), two_v1.id => two_v1},
      snapshots: snapshots,
      retries: {},
      base_revision: 3
    )

    assert_equal ["OneTest#test_one"], selection.selected
    assert_match(/input_changed/, selection.reasons_by_test.fetch("OneTest#test_one").first)
  end

  def test_new_and_retryable_entities_run_without_affecting_clean_entities
    clean_input = input("clean", "v1")
    selection = @selector.call(
      discovered: %w[CleanTest#test_clean NewTest#test_new RetryTest#test_retry],
      current_inputs: [clean_input],
      snapshots: {"CleanTest#test_clean" => snapshot("CleanTest#test_clean", clean_input)},
      retries: {"RetryTest#test_retry" => :skipped},
      base_revision: 4
    )

    assert_equal %w[NewTest#test_new RetryTest#test_retry], selection.selected
    assert_equal ["no_trace"], selection.reasons_by_test.fetch("NewTest#test_new")
    assert_equal ["skipped_test"], selection.reasons_by_test.fetch("RetryTest#test_retry")
  end

  def test_missing_is_a_resolved_fingerprint_and_compares_by_state_and_digest
    learned = Minitest::Testmon::Input.new(
      key: "optional", provider: "core@1", facet: "existence",
      fingerprint: Minitest::Testmon::Fingerprint.missing
    )
    selection = @selector.call(
      discovered: ["OptionalTest#test_lookup"],
      current_inputs: [learned],
      snapshots: {"OptionalTest#test_lookup" => snapshot("OptionalTest#test_lookup", learned)},
      retries: {},
      base_revision: 1
    )

    assert_empty selection.selected
  end

  def test_selects_when_a_stored_input_is_absent_from_the_current_catalog
    learned = input("removed", "v1")
    selection = @selector.call(
      discovered: ["ExampleTest#test_value"],
      current_inputs: [],
      snapshots: {"ExampleTest#test_value" => snapshot("ExampleTest#test_value", learned)},
      retries: {},
      base_revision: 1
    )

    assert_equal ["ExampleTest#test_value"], selection.selected
    assert_equal ["input_missing:core@1:removed"], selection.reasons_by_test.fetch("ExampleTest#test_value")
  end

  def test_selects_when_the_current_fingerprint_is_unknown
    learned = input("racing", "v1")
    unknown = learned.with(fingerprint: Minitest::Testmon::Fingerprint.unknown(:source_race))
    selection = @selector.call(
      discovered: ["ExampleTest#test_value"],
      current_inputs: [unknown],
      snapshots: {"ExampleTest#test_value" => snapshot("ExampleTest#test_value", learned)},
      retries: {},
      base_revision: 1
    )

    assert_equal ["ExampleTest#test_value"], selection.selected
    assert_equal ["input_unknown:core@1:racing"], selection.reasons_by_test.fetch("ExampleTest#test_value")
  end

  def test_selects_every_snapshot_that_has_not_learned_a_retained_suite_input
    suite = input("shared", "v1", scope: :suite)
    learned = input("other", "v1")
    snapshots = {
      "LearnedTest#test_shared" => snapshot("LearnedTest#test_shared", suite),
      "UnlearnedTest#test_shared" => snapshot("UnlearnedTest#test_shared", learned)
    }

    selection = @selector.call(
      discovered: snapshots.keys,
      current_inputs: [suite, learned],
      snapshots: snapshots,
      retries: {},
      base_revision: 3,
      suite_input_ids: [suite.id]
    )

    assert_equal ["UnlearnedTest#test_shared"], selection.selected
    assert_equal ["suite_input_missing:core@1:shared"],
      selection.reasons_by_test.fetch("UnlearnedTest#test_shared")
  end

  private

  def input(key, digest, scope: :test)
    Minitest::Testmon::Input.new(
      key: key, provider: "core@1", facet: "content",
      fingerprint: Minitest::Testmon::Fingerprint.known(digest), scope: scope
    )
  end

  def snapshot(test_id, value)
    Minitest::Testmon::TestSnapshot.new(
      test_id: test_id, inputs: [value], recorded_at: "now", run_id: "run"
    )
  end
end

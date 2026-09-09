# frozen_string_literal: true

require_relative "test_helper"
require "minitest/testmon/input"
require "minitest/testmon/test_snapshot"
require "minitest/testmon/snapshot_builder"

class SnapshotBuilderTest < TestmonTestCase
  def test_builds_one_snapshot_from_suite_claimed_and_definition_inputs
    suite = input("$context", "context", scope: :suite)
    claimed = input("view", "view")
    unclaimed = input("other", "other")
    definition = input("test-file", "test")

    snapshot = Minitest::Testmon::SnapshotBuilder.new.call(
      test_id: "ExampleTest#test_value",
      current_inputs: [suite, claimed, unclaimed],
      claimed_input_ids: [claimed.id],
      test_definition_input: definition,
      recorded_at: "2026-08-01T00:00:00Z",
      run_id: "run-1"
    )

    assert_equal "ExampleTest#test_value", snapshot.test_id
    assert_equal %w[$context test-file view], snapshot.inputs.map(&:key).sort
    assert_equal "run-1", snapshot.run_id
  end

  def test_rejects_a_claim_that_is_absent_from_the_current_catalog
    missing = input("missing", "v1")

    error = assert_raises(ArgumentError) do
      Minitest::Testmon::SnapshotBuilder.new.call(
        test_id: "ExampleTest#test_value",
        current_inputs: [],
        claimed_input_ids: [missing.id],
        test_definition_input: nil,
        recorded_at: "2026-08-01T00:00:00Z",
        run_id: "run-1"
      )
    end

    assert_match(/claimed inputs are absent/, error.message)
  end

  def test_rejects_duplicate_current_input_identities
    duplicate = input("same", "v1")

    error = assert_raises(ArgumentError) do
      Minitest::Testmon::SnapshotBuilder.new.call(
        test_id: "ExampleTest#test_value",
        current_inputs: [duplicate, duplicate],
        claimed_input_ids: [],
        test_definition_input: nil,
        recorded_at: "2026-08-01T00:00:00Z",
        run_id: "run-1"
      )
    end

    assert_match(/duplicate input identities/, error.message)
  end

  def test_rejects_an_unknown_input_in_the_snapshot
    unknown = input("racing", "ignored").with(
      fingerprint: Minitest::Testmon::Fingerprint.unknown(:source_race)
    )

    error = assert_raises(ArgumentError) do
      Minitest::Testmon::SnapshotBuilder.new.call(
        test_id: "ExampleTest#test_value",
        current_inputs: [unknown],
        claimed_input_ids: [unknown.id],
        test_definition_input: nil,
        recorded_at: "2026-08-01T00:00:00Z",
        run_id: "run-1"
      )
    end

    assert_match(/cannot publish unknown inputs/, error.message)
  end

  def test_reused_builder_revalidates_replaced_and_mutated_catalogs
    builder = Minitest::Testmon::SnapshotBuilder.new
    known = input("value", "v1")
    arguments = {
      test_id: "ExampleTest#test_value", claimed_input_ids: [known.id],
      test_definition_input: nil, recorded_at: "2026-08-01T00:00:00Z", run_id: "run-1"
    }
    catalog = [known].freeze
    assert_equal [known], builder.call(**arguments, current_inputs: catalog).inputs
    assert_equal [known], builder.call(**arguments, current_inputs: catalog).inputs
    assert_raises(ArgumentError) { builder.call(**arguments, current_inputs: [].freeze) }

    mutable = [known]
    assert_equal [known], builder.call(**arguments, current_inputs: mutable).inputs
    mutable << known
    assert_raises(ArgumentError) { builder.call(**arguments, current_inputs: mutable) }
    unknown = known.with(fingerprint: Minitest::Testmon::Fingerprint.unknown(:source_race))
    assert_raises(ArgumentError) { builder.call(**arguments, current_inputs: [unknown].freeze) }
  end

  private

  def input(key, digest, scope: :test)
    Minitest::Testmon::Input.new(
      key: key, provider: "core@1", facet: "content", scope: scope,
      fingerprint: Minitest::Testmon::Fingerprint.known(digest)
    )
  end
end

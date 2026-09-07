# frozen_string_literal: true

require_relative "test_helper"
require "minitest/testmon/input"
require "minitest/testmon/test_snapshot"
require "minitest/testmon/selection"
require "minitest/testmon/run_evidence"

class StoreTest < TestmonTestCase
  Report = Data.define(:generation, :context_signature, :mode, :tests, :publication) do
    def self.build(discovered:, selected:, executed:)
      new(
        generation: nil,
        context_signature: "context",
        mode: "run",
        tests: {discovered: discovered.sort, selected: selected.sort, executed: executed.sort}.freeze,
        publication: {published: false, reason: "not_published"}.freeze
      )
    end

    def executed_tests = tests.fetch(:executed)
    def published(value, reason: nil) = with(generation: value, publication: {published: true, reason: reason}.freeze)
    def with_generation(value) = with(generation: value)
    def unpublished(reason) = with(publication: {published: false, reason: reason}.freeze)

    def to_h
      {
        schema_version: 2,
        mode: mode,
        ready: publication[:published],
        generation: generation,
        context_signature: context_signature,
        bundles: [],
        tests: tests,
        observations: {},
        inventory: {},
        suggestions: [],
        publication: publication
      }
    end
  end

  def test_start_execution_durably_marks_exact_selected_tests_running
    with_store do |store|
      selection = selection_for(%w[OneTest#test_one TwoTest#test_two], ["TwoTest#test_two"], store.revision)
      store.acquire_lease!(run_id: "run-1")
      store.start_execution(run_id: "run-1", selection: selection)

      assert_equal({"TwoTest#test_two" => :running}, outcomes(store.retries_for(selection.discovered)))
      assert_empty store.snapshots_for(selection.discovered)
    end
  end

  def test_success_replaces_only_passing_selected_snapshots_with_literal_inputs
    with_store do |store|
      discovered = %w[OneTest#test_one TwoTest#test_two]
      selection = selection_for(discovered, discovered, store.revision)
      snapshots = {
        "OneTest#test_one" => snapshot("OneTest#test_one", input("one", "v1"), "run-1"),
        "TwoTest#test_two" => snapshot("TwoTest#test_two", input("two", "v1"), "run-1")
      }
      report = Report.build(discovered: discovered, selected: discovered, executed: discovered)

      store.acquire_lease!(run_id: "run-1")
      store.start_execution(run_id: "run-1", selection: selection)
      published = store.publish(evidence("run-1", selection, report, snapshots:, outcomes: discovered.to_h { |id| [id, :passed] }))

      assert_equal 1, store.revision
      assert_equal true, published.publication.fetch(:published)
      assert_empty store.retries_for(discovered)
      persisted = store.snapshots_for(discovered)
      assert_equal %w[one two], persisted.values.flat_map { |item| item.inputs.map(&:key) }.sort
      assert_equal %w[v1 v1], persisted.values.flat_map { |item| item.inputs.map { |value| value.fingerprint.digest } }.sort
    end
  end

  def test_round_trips_literal_suite_claimed_and_definition_inputs_for_one_test
    with_store do |store|
      test_id = "ExampleTest#test_value"
      values = [
        input("$context", "context", scope: :suite),
        input("view", "view"),
        input("test-file", "definition")
      ]
      selection = selection_for([test_id], [test_id], store.revision)
      report = Report.build(discovered: [test_id], selected: [test_id], executed: [test_id])
      stored = Minitest::Testmon::TestSnapshot.new(
        test_id: test_id, inputs: values, recorded_at: "2026-08-01T00:00:00Z", run_id: "run-1"
      )

      store.acquire_lease!(run_id: "run-1")
      store.start_execution(run_id: "run-1", selection: selection)
      store.publish(evidence("run-1", selection, report, snapshots: {test_id => stored}, outcomes: {test_id => :passed}))

      restored = store.snapshots_for([test_id]).fetch(test_id)
      assert_equal %w[$context test-file view], restored.inputs.map(&:key).sort
      assert_equal %w[context definition view], restored.inputs.map { |item| item.fingerprint.digest }.sort
      assert_equal :suite, restored.inputs.find { |item| item.key == "$context" }.scope
    end
  end

  def test_incomplete_source_drift_and_invalid_ledger_reject_publication
    cases = [
      [{complete: false}, "provider_incomplete"],
      [{source_stable: false}, "source_drift"],
      [{executed: []}, "provider_incomplete"]
    ]
    cases.each_with_index do |(override, expected_reason), index|
      with_store do |store|
        test_id = "ExampleTest#test_value"
        selection = selection_for([test_id], [test_id], store.revision)
        executed = override.fetch(:executed, [test_id])
        report = Report.build(discovered: [test_id], selected: [test_id], executed: executed)
        snapshot_value = snapshot(test_id, input("source", "v1"), "run-#{index}")
        store.acquire_lease!(run_id: "run-#{index}")
        store.start_execution(run_id: "run-#{index}", selection: selection)
        result = store.publish(evidence(
          "run-#{index}", selection, report,
          snapshots: {test_id => snapshot_value}, outcomes: {test_id => :passed}, **override.slice(:complete, :source_stable)
        ))

        assert_equal false, result.publication.fetch(:published)
        assert_equal expected_reason, result.publication.fetch(:reason)
        assert_empty store.snapshots_for([test_id])
      end
    end
  end

  def test_stale_revision_is_rejected_before_publication
    with_store do |store|
      selection = selection_for(["ExampleTest#test_value"], [], 99)
      store.acquire_lease!(run_id: "stale")
      assert_raises(Minitest::Testmon::PhaseError) do
        store.start_execution(run_id: "stale", selection: selection)
      end
    end
  end

  def test_zero_selection_writes_a_published_receipt_without_advancing_revision
    with_store do |store|
      selection = selection_for(["ExampleTest#test_value"], [], store.revision)
      report = Report.build(discovered: selection.discovered, selected: [], executed: [])
      store.acquire_lease!(run_id: "warm")
      store.start_execution(run_id: "warm", selection: selection)
      published = store.publish(evidence("warm", selection, report, snapshots: {}, outcomes: {}))

      assert_equal true, published.publication.fetch(:published)
      assert_nil store.revision
      assert_equal [], store.report("warm").dig("tests", "selected")
    end
  end

  def test_any_test_failure_preserves_every_previous_snapshot_atomically
    with_store do |store|
      seed(store, {"OneTest#test_one" => input("one", "v1"), "TwoTest#test_two" => input("two", "v1")})
      discovered = %w[OneTest#test_one TwoTest#test_two]
      selection = selection_for(discovered, discovered, store.revision)
      replacements = {
        "OneTest#test_one" => snapshot("OneTest#test_one", input("one", "v2"), "run-2")
      }
      report = Report.build(discovered: discovered, selected: discovered, executed: discovered)

      store.acquire_lease!(run_id: "run-2")
      store.start_execution(run_id: "run-2", selection: selection)
      rejected = store.publish(evidence(
        "run-2", selection, report,
        snapshots: replacements,
        outcomes: {"OneTest#test_one" => :passed, "TwoTest#test_two" => :failed}
      ))

      assert_equal false, rejected.publication.fetch(:published)
      assert_equal "test_failure", rejected.publication.fetch(:reason)
      assert_equal 1, store.revision
      persisted = store.snapshots_for(discovered)
      assert_equal "v1", persisted.fetch("OneTest#test_one").inputs.first.fingerprint.digest
      assert_equal "v1", persisted.fetch("TwoTest#test_two").inputs.first.fingerprint.digest
      assert_equal({"OneTest#test_one" => :running, "TwoTest#test_two" => :failed}, outcomes(store.retries_for(discovered)))
    end
  end

  def test_successful_subset_does_not_write_an_omitted_test
    with_store do |store|
      seed(store, {"OneTest#test_one" => input("one", "v1"), "TwoTest#test_two" => input("two", "v1")})
      discovered = %w[OneTest#test_one TwoTest#test_two]
      selection = selection_for(discovered, ["OneTest#test_one"], store.revision)
      replacement = snapshot("OneTest#test_one", input("one", "v2"), "run-2")
      report = Report.build(discovered: discovered, selected: selection.selected, executed: selection.selected)

      store.acquire_lease!(run_id: "run-2")
      store.start_execution(run_id: "run-2", selection: selection)
      store.publish(evidence(
        "run-2", selection, report,
        snapshots: {replacement.test_id => replacement},
        outcomes: {replacement.test_id => :passed}
      ))

      persisted = store.snapshots_for(discovered)
      assert_equal "v2", persisted.fetch("OneTest#test_one").inputs.first.fingerprint.digest
      assert_equal "v1", persisted.fetch("TwoTest#test_two").inputs.first.fingerprint.digest
    end
  end

  def test_schema_mismatch_is_quarantined_as_incompatible
    with_project do |project|
      path = File.join(project, "state.sqlite3")
      database = SQLite3::Database.new(path)
      database.execute("CREATE TABLE metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
      database.execute("INSERT INTO metadata(key, value) VALUES ('schema_version', '1')")
      database.close

      store = Minitest::Testmon::Store.new(path)
      assert_nil store.revision
      store.close
      assert_equal 1, Dir["#{path}.incompatible-*"].length
    end
  end

  private

  def with_store
    with_project do |project|
      store = Minitest::Testmon::Store.new(File.join(project, "state.sqlite3"))
      yield store
    ensure
      store&.close
    end
  end

  def selection_for(discovered, selected, revision)
    Minitest::Testmon::Selection.new(
      discovered: discovered,
      selected: selected,
      reasons_by_test: selected.to_h { |test_id| [test_id, ["test"]] },
      base_revision: revision
    )
  end

  def input(key, digest, scope: :test)
    Minitest::Testmon::Input.new(
      key: key,
      provider: "core@1",
      facet: "content",
      root: "project",
      relative_path: "lib/#{key}.rb",
      fingerprint: Minitest::Testmon::Fingerprint.known(digest),
      scope: scope
    )
  end

  def snapshot(test_id, value, run_id)
    Minitest::Testmon::TestSnapshot.new(
      test_id: test_id,
      inputs: [value],
      recorded_at: "2026-08-01T00:00:00Z",
      run_id: run_id
    )
  end

  def evidence(run_id, selection, report, snapshots:, outcomes:, complete: true, source_stable: true)
    Minitest::Testmon::RunEvidence.new(
      run_id: run_id,
      base_revision: selection.base_revision,
      report: report,
      selection: selection,
      outcomes: outcomes,
      snapshots: snapshots,
      complete: complete,
      source_stable: source_stable
    )
  end

  def seed(store, values)
    selected = values.keys.sort
    selection = selection_for(selected, selected, store.revision)
    report = Report.build(discovered: selected, selected: selected, executed: selected)
    snapshots = values.to_h { |test_id, value| [test_id, snapshot(test_id, value, "seed")] }
    store.acquire_lease!(run_id: "seed")
    store.start_execution(run_id: "seed", selection: selection)
    store.publish(evidence("seed", selection, report, snapshots: snapshots, outcomes: selected.to_h { |id| [id, :passed] }))
    store.release_lease!
  end

  def outcomes(retries)
    retries.transform_values(&:outcome)
  end
end

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

  def test_publication_reuses_one_input_statement_across_snapshots_and_closes_it
    with_store do |store|
      ids = %w[OneTest#test_one TwoTest#test_two]
      selection = selection_for(ids, ids, store.revision)
      store.acquire_lease!(run_id: "prepared")
      store.start_execution(run_id: "prepared", selection: selection)
      statements = track_input_statements(store)
      snapshots = ids.to_h do |id|
        [id, snapshot(id, input("one", "v1"), "prepared").with(inputs: [input("one", "v1"), input("two", "v2")])]
      end
      report = Report.build(discovered: ids, selected: ids, executed: ids)
      store.publish(evidence("prepared", selection, report, snapshots: snapshots, outcomes: ids.to_h { |id| [id, :passed] }))

      assert_equal 1, statements.length
      assert statements.first.closed?
      assert_equal [2, 2], store.snapshots_for(ids).values.map { |value| value.inputs.length }
      assert_empty store.retries_for(ids)
    end
  end

  def test_failed_checkpoint_closes_statement_and_next_transaction_prepares_again
    with_store do |store|
      ids = %w[OneTest#test_one TwoTest#test_two]
      selection = selection_for(ids, ids, store.revision)
      store.acquire_lease!(run_id: "prepared")
      store.start_execution(run_id: "prepared", selection: selection)
      statements = track_input_statements(store)
      first = snapshot(ids.first, input("one", "v1"), "prepared")
      unknown = input("other", "v1").with(fingerprint: Minitest::Testmon::Fingerprint.unknown(:source_race))
      second = snapshot(ids.last, unknown, "prepared")
      assert_raises(Minitest::Testmon::PhaseError) do
        store.checkpoint(run_id: "prepared", base_revision: nil, snapshots: [first, second])
      end
      assert_equal 1, statements.length
      assert statements.first.closed?
      assert_empty store.snapshots_for(ids)
      assert_nil store.revision
      assert_equal ids, store.retries_for(ids).keys
      assert_empty store.checkpoint_progress("prepared").fetch("accepted_ids")

      store.checkpoint(run_id: "prepared", base_revision: nil, snapshots: [first])
      assert_equal 2, statements.length
      assert statements.last.closed?
      assert_equal [ids.first], store.snapshots_for(ids).keys
      assert_equal [ids.last], store.retries_for(ids).keys
      assert_equal 1, store.revision
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

  def test_checkpoint_is_durable_before_completion_and_rejects_foreign_tests_atomically
    with_store do |store|
      ids = %w[OneTest#test_one TwoTest#test_two]
      selection = selection_for(ids, ids, store.revision)
      store.acquire_lease!(run_id: "partial")
      store.start_execution(run_id: "partial", selection: selection)
      first = snapshot(ids.first, input("one", "v1"), "partial")
      foreign = snapshot("ForeignTest#test_value", input("other", "v1"), "partial")
      assert_raises(Minitest::Testmon::PhaseError) do
        store.checkpoint(run_id: "partial", base_revision: nil, snapshots: [first, foreign])
      end
      assert_empty store.snapshots_for(ids)
      assert_nil store.revision
      store.checkpoint(run_id: "partial", base_revision: nil, snapshots: [first])
      assert_equal 1, store.revision
      assert_equal [ids.first], store.checkpoint_progress("partial").fetch("accepted_ids")
      assert_equal [ids.last], store.retries_for(ids).keys
      store.release_lease!
      assert_equal "abandoned", store.runs.first.fetch("state")
      assert_equal [ids.first], store.snapshots_for(ids).keys
    end
  end

  def test_contradictory_completion_revokes_checkpoint_and_forces_retry
    with_store do |store|
      id = "OneTest#test_one"
      selection = selection_for([id], [id], nil)
      store.acquire_lease!(run_id: "partial")
      store.start_execution(run_id: "partial", selection: selection)
      store.checkpoint(run_id: "partial", base_revision: nil,
        snapshots: [snapshot(id, input("one", "v1"), "partial")])
      store.invalidate_checkpoint("partial", id)
      assert_empty store.snapshots_for([id])
      assert_equal :running, store.retries_for([id]).fetch(id).outcome
      assert_empty store.checkpoint_progress("partial").fetch("accepted_ids")
      assert_equal 2, store.revision
    end
  end

  def test_supported_schema_migrations_preserve_snapshots_and_retry_state
    %w[6 7 8].each do |version|
      with_project do |project|
        path = File.join(project, "state.sqlite3")
        id = "OneTest#test_one"
        store = Minitest::Testmon::Store.new(path)
        seed(store, {id => input("one", "v1")})
        store.acquire_lease!(run_id: "unfinished")
        store.start_execution(run_id: "unfinished", selection: selection_for([id], [id], store.revision))
        store.close
        database = SQLite3::Database.new(path)
        database.execute("DROP VIEW expanded_test_inputs")
        database.execute("DROP INDEX test_snapshots_suite_set")
        database.execute("ALTER TABLE test_snapshots DROP COLUMN suite_input_set_id")
        database.execute("DROP TABLE suite_input_set_members")
        database.execute("DROP TABLE suite_input_sets")
        database.execute("ALTER TABLE run_receipts DROP COLUMN checkpoint_json") unless version == "8"
        database.execute("ALTER TABLE test_inputs DROP COLUMN scope") if version == "6"
        database.execute("UPDATE metadata SET value=? WHERE key='schema_version'", [version])
        database.close
        migrated = Minitest::Testmon::Store.new(path)
        assert_equal 1, migrated.revision
        assert_equal [id], migrated.snapshots_for([id]).keys
        expected_scope = (version == "6") ? :suite : :test
        assert_equal expected_scope, migrated.snapshots_for([id]).fetch(id).inputs.first.scope
        assert_equal :running, migrated.retries_for([id]).fetch(id).outcome
        assert_equal 0, migrated.checkpoint_progress("seed").fetch("count")
        assert_empty Dir["#{path}.incompatible-*"]
      ensure
        migrated&.close
      end
    end
  end

  def test_suite_inputs_are_stored_once_and_reconstructed_for_every_snapshot
    with_store do |store|
      shared = 113.times.map { |number| input("shared#{number}", "v1", scope: :suite) }
      snapshots = 872.times.map do |number|
        Minitest::Testmon::TestSnapshot.new(test_id: "SharedTest#test_#{number}",
          inputs: [*shared, input("own#{number}", "v1")], recorded_at: "now", run_id: "shared")
      end
      store.acquire_lease!(run_id: "shared")
      selection = selection_for(snapshots.map(&:test_id), snapshots.map(&:test_id), nil)
      store.start_execution(run_id: "shared", selection: selection)
      store.checkpoint(run_id: "shared", base_revision: nil, snapshots: snapshots)
      database = store.instance_variable_get(:@database)
      assert_equal 1, database.get_first_value("SELECT count(*) FROM suite_input_sets")
      assert_equal 113, database.get_first_value("SELECT count(*) FROM suite_input_set_members")
      assert_equal 872, database.get_first_value("SELECT count(*) FROM test_inputs")
      actual = store.snapshots_for(snapshots.map(&:test_id))
      assert_equal snapshots.to_h { |snapshot| [snapshot.test_id, snapshot] }, actual
      assert_same actual.fetch(snapshots[0].test_id).inputs.find(&:suite?), actual.fetch(snapshots[1].test_id).inputs.find(&:suite?)
      assert_equal 872, store.explain(["lib/shared0.rb"]).length
    end
  end

  def test_shared_sets_preserve_omitted_snapshots_and_empty_replacements
    with_store do |store|
      seed(store, {"One#test" => input("shared", "old", scope: :suite), "Two#test" => input("shared", "old", scope: :suite)})
      seed(store, {"One#test" => input("shared", "new", scope: :suite)})
      values = store.snapshots_for(["One#test", "Two#test"])
      assert_equal "new", values.fetch("One#test").inputs.first.fingerprint.digest
      assert_equal "old", values.fetch("Two#test").inputs.first.fingerprint.digest
      seed(store, {"One#test" => input("only_test", "v1")})
      assert_equal ["only_test"], store.snapshots_for(["One#test"]).fetch("One#test").inputs.map(&:key)
      assert_equal ["Two#test"], store.explain(["lib/shared.rb"]).map { |row| row.fetch(:test_id) }
    end
  end

  def test_rolled_back_shared_set_is_reinserted_on_next_transaction
    with_store do |store|
      value = snapshot("One#test", input("shared", "v1", scope: :suite), "run")
      assert_raises(RuntimeError) do
        store.send(:transaction) do
          store.send(:replace_snapshot, value)
          raise "abort after set insertion"
        end
      end
      assert_empty store.snapshots_for([value.test_id])
      database = store.instance_variable_get(:@database)
      assert_equal 0, database.get_first_value("SELECT count(*) FROM suite_input_sets")
      store.send(:transaction) { store.send(:replace_snapshot, value) }
      assert_equal value, store.snapshots_for([value.test_id]).fetch(value.test_id)
      assert_nil store.instance_variable_get(:@persisted_suite_sets)
    end
  end

  def test_schema_eight_suite_rows_migrate_lazily_with_identical_selection
    with_project do |project|
      path = File.join(project, "state.sqlite3")
      store = Minitest::Testmon::Store.new(path)
      old = input("shared", "old", scope: :suite)
      seed(store, {"One#test" => old, "Two#test" => old})
      store.close
      database = SQLite3::Database.new(path)
      database.execute("INSERT INTO test_inputs SELECT * FROM expanded_test_inputs")
      database.execute("DROP VIEW expanded_test_inputs")
      database.execute("DROP INDEX test_snapshots_suite_set")
      database.execute("ALTER TABLE test_snapshots DROP COLUMN suite_input_set_id")
      database.execute("DROP TABLE suite_input_set_members")
      database.execute("DROP TABLE suite_input_sets")
      database.execute("UPDATE metadata SET value='8' WHERE key='schema_version'")
      database.close
      store = Minitest::Testmon::Store.new(path)
      database = store.instance_variable_get(:@database)
      assert_equal 2, database.get_first_value("SELECT count(*) FROM test_inputs")
      assert_equal 0, database.get_first_value("SELECT count(*) FROM suite_input_sets")
      before = store.snapshots_for(["One#test", "Two#test"])
      seed(store, {"One#test" => old})
      assert_equal before, store.snapshots_for(before.keys)
      assert_equal 1, database.get_first_value("SELECT count(*) FROM test_inputs")
      assert_equal 1, database.get_first_value("SELECT count(*) FROM suite_input_set_members")
      seed(store, {"One#test" => input("shared", "new", scope: :suite)})
      values = store.snapshots_for(before.keys)
      selection = Minitest::Testmon::Selector.new.call(discovered: before.keys,
        current_inputs: [input("shared", "new", scope: :suite)], snapshots: values,
        retries: {}, base_revision: store.revision, suite_input_ids: [old.id])
      assert_equal ["Two#test"], selection.selected
      assert_equal 2, store.explain(["lib/shared.rb"]).length
      assert_empty Dir["#{path}.incompatible-*"]
    ensure
      store&.close
    end
  end

  def test_consecutive_equal_suite_sets_encode_once_without_caching_mutable_digest_values
    with_store do |store|
      calls = 0
      trace = TracePoint.new(:call) do |event|
        calls += 1 if event.defined_class == Minitest::Testmon::PersistedInputSet && event.method_id == :initialize
      end
      digest = +"v1"
      value = input("shared", digest, scope: :suite)
      trace.enable do
        store.send(:transaction) { store.send(:replace_snapshot, snapshot("One#test", value, "run")) }
        store.send(:transaction) { store.send(:replace_snapshot, snapshot("Two#test", input("shared", +"v1", scope: :suite), "run")) }
        assert_equal 1, calls
        digest.replace("v2")
        store.send(:transaction) { store.send(:replace_snapshot, snapshot("Three#test", value, "run")) }
        assert_equal 2, calls
      end
      values = store.snapshots_for(["One#test", "Two#test", "Three#test"])
      assert_equal %w[v1 v1 v2], values.values.map { |entry| entry.inputs.first.fingerprint.digest }.sort
    ensure
      trace&.disable
    end
  end

  def test_active_legacy_lease_prevents_every_migration_step_without_quarantine
    %w[6 7 8].each do |version|
      with_project do |project|
        path = File.join(project, "state.sqlite3")
        store = Minitest::Testmon::Store.new(path)
        seed(store, {"One#test" => input("one", "v1")})
        store.close
        database = SQLite3::Database.new(path)
        database.execute("DROP VIEW expanded_test_inputs")
        database.execute("DROP INDEX test_snapshots_suite_set")
        database.execute("ALTER TABLE test_snapshots DROP COLUMN suite_input_set_id")
        database.execute("DROP TABLE suite_input_set_members")
        database.execute("DROP TABLE suite_input_sets")
        database.execute("ALTER TABLE run_receipts DROP COLUMN checkpoint_json") unless version == "8"
        database.execute("ALTER TABLE test_inputs DROP COLUMN scope") if version == "6"
        database.execute("UPDATE metadata SET value=? WHERE key='schema_version'", [version])
        database.execute("INSERT INTO leases(name, token, owner_pid, run_id, created_at) VALUES ('cache', 'live', ?, 'owner', 'now')", [Process.pid])
        schema = database.execute("SELECT type, name, sql FROM sqlite_master ORDER BY type, name")
        assert_raises(Minitest::Testmon::LeaseUnavailable) { Minitest::Testmon::Store.new(path) }
        assert_equal version, database.get_first_value("SELECT value FROM metadata WHERE key='schema_version'")
        assert_equal schema, database.execute("SELECT type, name, sql FROM sqlite_master ORDER BY type, name")
        assert_equal 1, database.get_first_value("SELECT count(*) FROM test_inputs")
        assert_equal "live", database.get_first_value("SELECT token FROM leases")
        assert_empty Dir["#{path}.incompatible-*"]
      ensure
        database&.close
      end
    end
  end

  def test_cold_schema_is_not_visible_until_its_metadata_is_complete
    with_project do |project|
      visible = []
      klass = Class.new(Minitest::Testmon::Store) do
        define_method(:create_suite_input_schema!) do
          reader = SQLite3::Database.new(path, readonly: true)
          visible << reader.get_first_value("SELECT name FROM sqlite_master WHERE name='metadata'")
          reader.close
          super()
        end
      end
      store = klass.new(File.join(project, "state.sqlite3"))
      assert_equal [nil], visible
      reopened = Minitest::Testmon::Store.new(store.path)
      assert_empty Dir["#{store.path}.incompatible-*"]
    ensure
      reopened&.close
      store&.close
    end
  end

  def test_brief_external_reader_does_not_reject_lease_acquisition
    with_store do |store|
      script = <<~RUBY_CHILD
        require "sqlite3"
        database = SQLite3::Database.new(ARGV.fetch(0), readonly: true)
        database.execute("BEGIN")
        database.execute("SELECT * FROM metadata")
        STDOUT.sync = true
        puts "locked"
        sleep 0.05
        database.execute("COMMIT")
        database.close
      RUBY_CHILD
      IO.popen([RbConfig.ruby, "-e", script, store.path], "r") do |reader|
        assert_equal "locked\n", reader.gets
        assert store.acquire_lease!(run_id: "reader-contention")
      end
      contender = Minitest::Testmon::Store.new(store.path)
      assert_raises(Minitest::Testmon::LeaseUnavailable) { contender.acquire_lease!(run_id: "contender") }
    ensure
      contender&.close
    end
  end

  def test_competing_initializer_is_revalidated_without_quarantine
    with_project do |project|
      klass = Class.new(Minitest::Testmon::Store) do
        define_method(:create_schema!) do
          # The first absence check has already happened. Model another opener
          # finishing its atomic initialization before this opener gets the lock.
          other = Minitest::Testmon::Store.new(path)
          other.close
          super()
        end
      end
      store = klass.new(File.join(project, "state.sqlite3"))
      assert_equal Minitest::Testmon::Store::SCHEMA_VERSION.to_s, store.send(:metadata, "schema_version")
      assert_empty Dir["#{store.path}.incompatible-*"]
    ensure
      store&.close
    end
  end

  private

  def track_input_statements(store)
    database = store.instance_variable_get(:@database)
    original = database.method(:prepare)
    statements = []
    database.define_singleton_method(:prepare) do |sql, *arguments, &block|
      statement = original.call(sql, *arguments, &block)
      statements << statement if sql.include?("INSERT INTO test_inputs(")
      statement
    end
    statements
  end

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

# frozen_string_literal: true

require_relative "test_helper"

class StoreTest < TestmonTestCase
  def test_publish_select_explain_and_failure_rollback
    with_project do |project|
      path = File.join(project, "state.sqlite3")
      store = Minitest::Testmon::Store.new(path)
      artifact = artifact_for("one")
      assert store.select([artifact], context_signature: "context").full?

      store.acquire_lease!
      published = store.publish(report_for(artifact), outcomes: {"ExampleTest#test_value" => :passed})
      assert published.ready?
      assert_equal 1, store.generation
      assert store.select([artifact], context_signature: "context").none?

      changed = artifact_for("two")
      selection = store.select([changed], context_signature: "context")
      assert_equal :subset, selection.mode
      assert_equal ["ExampleTest#test_value"], selection.tests
      assert_equal "ExampleTest#test_value", store.explain("example.rb").first[:test_id]

      store.acquire_lease!
      rejected = store.publish(report_for(changed), outcomes: {"ExampleTest#test_value" => :failed})
      refute rejected.ready?
      assert_equal "test_failure", rejected.publication[:reason]
      assert_equal 1, rejected.generation
      assert_equal 1, store.generation
      assert_equal :subset, store.select([changed], context_signature: "context").mode
      store.close
    end
  end

  def test_exclusive_lease_fails_fast
    with_project do |project|
      path = File.join(project, "state.sqlite3")
      first = Minitest::Testmon::Store.new(path)
      second = Minitest::Testmon::Store.new(path)
      first.acquire_lease!

      error = assert_raises(Minitest::Testmon::LeaseUnavailable) { second.acquire_lease! }
      assert_equal "cache_lease_unavailable", error.message
      first.release_lease!
      first.close
      second.close
    end
  end

  def test_corrupt_cache_is_quarantined_before_rebuild
    with_project do |project|
      path = write_file(File.join(project, "state.sqlite3"), "not sqlite")
      store = Minitest::Testmon::Store.new(path)

      assert_equal "cache_corrupt_rebuilt", store.recovery_reason
      assert_equal 1, Dir["#{path}.corrupt-*"].length
      assert store.select([], context_signature: "context").full?
      store.close
    end
  end

  def test_busy_database_is_not_quarantined
    with_project do |project|
      path = File.join(project, "state.sqlite3")
      Minitest::Testmon::Store.new(path).close
      owner = SQLite3::Database.new(path)
      owner.busy_timeout = 0
      owner.execute("BEGIN EXCLUSIVE")

      error = assert_raises(Minitest::Testmon::LeaseUnavailable) do
        Minitest::Testmon::Store.new(path)
      end
      assert_equal "cache_lease_unavailable", error.message
      assert_empty Dir["#{path}.corrupt-*"]
    ensure
      begin
        owner&.execute("ROLLBACK")
      rescue
        nil
      end
      begin
        owner&.close
      rescue
        nil
      end
    end
  end

  def test_membership_artifact_selects_consumers_for_covered_file_addition
    with_project do |project|
      path = File.join(project, "state.sqlite3")
      original = artifact_for("one")
      membership = membership_artifact("members-v1", ["project:lib/example.rb"])
      store = Minitest::Testmon::Store.new(path)
      store.acquire_lease!
      store.publish(
        report_for_membership([original, membership], membership),
        outcomes: {"ExampleTest#test_value" => :passed}
      )

      added = Minitest::Testmon::Artifact.new(
        key: "added", provider: :core, root: :project, relative_path: "lib/added.rb",
        facet: "content", fingerprint: Minitest::Testmon::Fingerprint.known("added"),
        members: [], scope: :test, test_ids: [], reason: nil
      )
      changed_membership = membership_artifact(
        "members-v2",
        ["project:lib/example.rb", "project:lib/added.rb"]
      )
      selection = store.select([original, added, changed_membership], context_signature: "context")
      assert_equal :subset, selection.mode
      assert_equal ["ExampleTest#test_value"], selection.tests
      store.close
    end
  end

  def test_dead_lease_owner_forces_full_recovery_and_discards_only_its_spools
    skip "fork is required" unless Process.respond_to?(:fork)
    owner = nil
    reader = nil

    with_project do |project|
      path = File.join(project, "state.sqlite3")
      artifact = artifact_for("one")
      baseline = Minitest::Testmon::Store.new(path)
      baseline.acquire_lease!
      baseline.publish(report_for(artifact), outcomes: {"ExampleTest#test_value" => :passed})
      baseline.close

      stale_run_id = "11111111-1111-4111-8111-111111111111"
      other_run_id = "22222222-2222-4222-8222-222222222222"
      spool_root = File.join(project, "tmp/minitest-testmon/workers")
      stale_directory = File.join(spool_root, stale_run_id)
      other_directory = File.join(spool_root, other_run_id)
      FileUtils.mkdir_p([stale_directory, other_directory])
      write_file(File.join(stale_directory, "000-dead.jsonl.tmp"), "partial\n")
      write_file(File.join(other_directory, "000-live.jsonl.tmp"), "unrelated\n")

      reader, writer = IO.pipe
      owner = fork do
        reader.close
        store = Minitest::Testmon::Store.new(path)
        store.acquire_lease!(run_id: stale_run_id)
        writer.write("ready")
        writer.close
        sleep
      end
      writer.close
      assert_equal "ready", reader.read(5)
      Process.kill("KILL", owner)
      Process.wait(owner)

      recovered = Minitest::Testmon::Store.new(path)
      recovered.acquire_lease!(run_id: "33333333-3333-4333-8333-333333333333")
      assert_equal "worker_incomplete", recovered.recovery_reason
      assert_equal stale_run_id, recovered.recovered_run_id
      selection = recovered.select([artifact], context_signature: "context")
      assert selection.full?
      assert_equal ["worker_incomplete"], selection.reasons

      assert Minitest::Testmon::WorkerSpool.discard_incomplete_run(
        project_root: project,
        run_id: recovered.recovered_run_id
      )
      refute File.exist?(stale_directory)
      assert File.directory?(other_directory)
      recovered.release_lease!
      recovered.close

      retry_store = Minitest::Testmon::Store.new(path)
      assert_equal "worker_incomplete", retry_store.recovery_reason
      retry_store.acquire_lease!(run_id: "44444444-4444-4444-8444-444444444444")
      assert retry_store.select([artifact], context_signature: "context").full?
      retry_store.publish(report_for(artifact), outcomes: {"ExampleTest#test_value" => :passed})
      retry_store.close

      verified = Minitest::Testmon::Store.new(path)
      assert_nil verified.recovery_reason
      assert verified.select([artifact], context_signature: "context").none?
      verified.close
    ensure
      reader&.close unless reader&.closed?
      if owner
        begin
          Process.kill("KILL", owner)
        rescue
          nil
        end
        begin
          Process.wait(owner)
        rescue
          nil
        end
      end
    end
  end

  def test_skipped_test_preserves_edges_and_forces_full_recovery
    with_project do |project|
      store = Minitest::Testmon::Store.new(File.join(project, "state.sqlite3"))
      original = artifact_for("one")
      store.acquire_lease!
      store.publish(report_for(original), outcomes: {"ExampleTest#test_value" => :passed})

      changed = artifact_for("two")
      store.acquire_lease!
      rejected = store.publish(report_for(changed), outcomes: {"ExampleTest#test_value" => :skipped})

      assert_equal "test_skip", rejected.publication[:reason]
      assert_equal 1, rejected.generation
      assert_equal "ExampleTest#test_value", store.explain("example.rb").first.fetch(:test_id)
      selection = store.select([changed], context_signature: "context")
      assert selection.full?
      assert_equal ["test_skip"], selection.reasons

      recovery = custom_report(
        artifacts: [changed],
        discovered: ["ExampleTest#test_value"],
        selected: ["ExampleTest#test_value"],
        executed: ["ExampleTest#test_value"],
        dependencies: [["ExampleTest#test_value", changed]],
        selection_mode: :full
      )
      store.acquire_lease!
      recovered = store.publish(
        recovery,
        outcomes: {"ExampleTest#test_value" => :skipped}
      )

      assert recovered.ready?
      assert_equal 2, recovered.generation
      assert_nil store.explain("example.rb").first.fetch(:test_id)
      selection = store.select([changed], context_signature: "context")
      assert_equal :subset, selection.mode
      assert_equal ["ExampleTest#test_value"], selection.tests
      assert_equal ["skipped_test"], selection.reasons
      store.close
    end
  end

  def test_new_permanent_skips_publish_without_edges_and_certify_in_place_regardless_of_outcome_order
    with_project do |project|
      store = Minitest::Testmon::Store.new(File.join(project, "state.sqlite3"))
      passed = named_artifact("passed", "lib/passed.rb", "passed-v1")
      skipped_alpha = named_artifact("skipped-alpha", "lib/skipped_alpha.rb", "skipped-alpha-v1")
      skipped_zulu = named_artifact("skipped-zulu", "lib/skipped_zulu.rb", "skipped-zulu-v1")
      skipped_tests = %w[SkippedAlphaTest#test_skipped SkippedZuluTest#test_skipped]
      discovered = ["PassedTest#test_passed", *skipped_tests]
      baseline = custom_report(
        artifacts: [passed, skipped_alpha, skipped_zulu],
        discovered: discovered,
        selected: discovered,
        executed: discovered,
        dependencies: [
          ["PassedTest#test_passed", passed],
          ["SkippedAlphaTest#test_skipped", skipped_alpha],
          ["SkippedZuluTest#test_skipped", skipped_zulu]
        ],
        selection_mode: :full
      )

      store.acquire_lease!
      published = store.publish(
        baseline,
        outcomes: {
          "PassedTest#test_passed" => :passed,
          "SkippedAlphaTest#test_skipped" => :skipped,
          "SkippedZuluTest#test_skipped" => :skipped
        }
      )

      assert published.ready?
      assert_equal 1, published.generation
      published_inventory = store.published_inventory
      passed_edges = store.explain("passed.rb")
      assert_equal "PassedTest#test_passed", passed_edges.first.fetch(:test_id)
      assert_nil store.explain("skipped_alpha.rb").first.fetch(:test_id)
      assert_nil store.explain("skipped_zulu.rb").first.fetch(:test_id)
      selection = store.select([passed, skipped_alpha, skipped_zulu], context_signature: "context")
      assert_equal :subset, selection.mode
      assert_equal skipped_tests, selection.tests
      assert_equal ["skipped_test"], selection.reasons

      retry_report = custom_report(
        artifacts: [passed, skipped_alpha, skipped_zulu],
        discovered: discovered,
        selected: skipped_tests,
        executed: skipped_tests,
        dependencies: [
          ["SkippedAlphaTest#test_skipped", skipped_alpha],
          ["SkippedZuluTest#test_skipped", skipped_zulu]
        ],
        selection_mode: :subset
      )
      store.acquire_lease!
      certified = store.publish(
        retry_report,
        outcomes: {
          "SkippedZuluTest#test_skipped" => :skipped,
          "SkippedAlphaTest#test_skipped" => :skipped
        }
      )

      assert certified.ready?
      assert_equal 1, certified.generation
      assert_equal 1, store.generation
      assert_equal published_inventory, store.published_inventory
      assert_equal passed_edges, store.explain("passed.rb")
      assert_nil store.explain("skipped_alpha.rb").first.fetch(:test_id)
      assert_nil store.explain("skipped_zulu.rb").first.fetch(:test_id)
      assert_equal skipped_tests,
        store.select([passed, skipped_alpha, skipped_zulu], context_signature: "context").tests
      store.close
    end
  end

  def test_known_permanent_skip_can_coexist_with_changed_passing_test_publication
    with_project do |project|
      store = Minitest::Testmon::Store.new(File.join(project, "state.sqlite3"))
      passed = named_artifact("passed", "lib/passed.rb", "passed-v1")
      skipped = named_artifact("skipped", "lib/skipped.rb", "skipped-v1")
      discovered = %w[PassedTest#test_passed SkippedTest#test_skipped]
      baseline = custom_report(
        artifacts: [passed, skipped],
        discovered: discovered,
        selected: discovered,
        executed: discovered,
        dependencies: [
          ["PassedTest#test_passed", passed],
          ["SkippedTest#test_skipped", skipped]
        ],
        selection_mode: :full
      )
      store.acquire_lease!
      store.publish(
        baseline,
        outcomes: {
          "PassedTest#test_passed" => :passed,
          "SkippedTest#test_skipped" => :skipped
        }
      )

      changed = named_artifact("passed", "lib/passed.rb", "passed-v2")
      selection = store.select([changed, skipped], context_signature: "context")
      assert_equal :subset, selection.mode
      assert_equal discovered, selection.tests

      changed_report = custom_report(
        artifacts: [changed, skipped],
        discovered: discovered,
        selected: discovered,
        executed: discovered,
        dependencies: [
          ["PassedTest#test_passed", changed],
          ["SkippedTest#test_skipped", skipped]
        ],
        selection_mode: :subset
      )
      store.acquire_lease!
      published = store.publish(
        changed_report,
        outcomes: {
          "PassedTest#test_passed" => :passed,
          "SkippedTest#test_skipped" => :skipped
        }
      )

      assert published.ready?
      assert_equal 2, published.generation
      assert_equal "PassedTest#test_passed", store.explain("passed.rb").first.fetch(:test_id)
      assert_nil store.explain("skipped.rb").first.fetch(:test_id)
      next_selection = store.select([changed, skipped], context_signature: "context")
      assert_equal :subset, next_selection.mode
      assert_equal ["SkippedTest#test_skipped"], next_selection.tests
      assert_equal ["skipped_test"], next_selection.reasons
      store.close
    end
  end

  def test_removed_artifact_is_deleted_after_its_consumer_executes
    with_project do |project|
      store = Minitest::Testmon::Store.new(File.join(project, "state.sqlite3"))
      original = artifact_for("one")
      membership = membership_artifact("members-v1", ["project:lib/example.rb"])
      store.acquire_lease!
      store.publish(
        report_for_membership([original, membership], membership),
        outcomes: {"ExampleTest#test_value" => :passed}
      )

      empty_membership = membership_artifact("members-v2", [])
      store.acquire_lease!
      published = store.publish(
        report_for_membership([empty_membership], empty_membership),
        outcomes: {"ExampleTest#test_value" => :passed}
      )

      assert published.ready?
      assert store.select([empty_membership], context_signature: "context").none?
      assert_empty store.explain("example.rb")
      store.close
    end
  end

  def test_obsolete_artifact_with_an_unexecuted_consumer_rejects_promotion
    with_project do |project|
      store = Minitest::Testmon::Store.new(File.join(project, "state.sqlite3"))
      first = named_artifact("first", "data/first.txt", "one")
      second = named_artifact("second", "data/second.txt", "two")
      baseline = custom_report(
        artifacts: [first, second],
        discovered: %w[OneTest#test_one TwoTest#test_two],
        selected: %w[OneTest#test_one TwoTest#test_two],
        executed: %w[OneTest#test_one TwoTest#test_two],
        dependencies: [["OneTest#test_one", first], ["TwoTest#test_two", second]],
        selection_mode: :full
      )
      store.acquire_lease!
      store.publish(baseline, outcomes: {"OneTest#test_one" => :passed, "TwoTest#test_two" => :passed})

      subset = custom_report(
        artifacts: [first],
        discovered: %w[OneTest#test_one TwoTest#test_two],
        selected: ["OneTest#test_one"],
        executed: ["OneTest#test_one"],
        dependencies: [["OneTest#test_one", first]],
        selection_mode: :subset
      )
      store.acquire_lease!
      rejected = store.publish(subset, outcomes: {"OneTest#test_one" => :passed})

      refute rejected.ready?
      assert_equal "provider_incomplete", rejected.publication[:reason]
      assert_equal 1, rejected.generation
      assert_equal 2, store.explain([]).length
      store.close
    end
  end

  def test_full_discovery_prunes_an_absent_failed_test_and_its_artifact
    with_project do |project|
      store = Minitest::Testmon::Store.new(File.join(project, "state.sqlite3"))
      kept = named_artifact("kept", "data/kept.txt", "one")
      removed = named_artifact("removed", "data/removed.txt", "two")
      baseline = custom_report(
        artifacts: [kept, removed],
        discovered: %w[KeptTest#test_kept RemovedTest#test_removed],
        selected: %w[KeptTest#test_kept RemovedTest#test_removed],
        executed: %w[KeptTest#test_kept RemovedTest#test_removed],
        dependencies: [["KeptTest#test_kept", kept], ["RemovedTest#test_removed", removed]],
        selection_mode: :full
      )
      store.acquire_lease!
      store.publish(baseline, outcomes: {"KeptTest#test_kept" => :passed, "RemovedTest#test_removed" => :passed})
      store.acquire_lease!
      store.publish(baseline, outcomes: {"KeptTest#test_kept" => :passed, "RemovedTest#test_removed" => :failed})

      discovery = custom_report(
        artifacts: [kept],
        discovered: ["KeptTest#test_kept"],
        selected: ["KeptTest#test_kept"],
        executed: ["KeptTest#test_kept"],
        dependencies: [["KeptTest#test_kept", kept]],
        mode: :discover,
        selection_mode: :full
      )
      store.acquire_lease!
      published = store.publish(discovery, outcomes: {"KeptTest#test_kept" => :passed})

      assert published.ready?
      assert store.select([kept], context_signature: "context").none?
      assert_empty store.explain("removed")
      store.close
    end
  end

  def test_hydration_rejects_a_stored_path_replaced_by_an_outside_symlink
    with_project do |project|
      source = write_file(File.join(project, "data", "input.txt"), "inside")
      artifact = named_artifact("input", "data/input.txt", Digest::SHA256.hexdigest("inside"))
      store = Minitest::Testmon::Store.new(File.join(project, "state.sqlite3"))
      store.acquire_lease!
      store.publish(
        custom_report(
          artifacts: [artifact], discovered: ["InputTest#test_input"],
          selected: ["InputTest#test_input"], executed: ["InputTest#test_input"],
          dependencies: [["InputTest#test_input", artifact]], selection_mode: :full
        ),
        outcomes: {"InputTest#test_input" => :passed}
      )
      with_project do |outside|
        secret = write_file(File.join(outside, "secret.txt"), "secret")
        File.delete(source)
        File.symlink(secret, source)

        selection = store.select([], context_signature: "context", roots: {project: project})
        assert selection.full?
        assert_equal ["path_unresolved"], selection.reasons
      end
      store.close
    end
  end

  def test_promotion_rejects_an_incomplete_result_ledger
    with_project do |project|
      store = Minitest::Testmon::Store.new(File.join(project, "state.sqlite3"))
      artifact = artifact_for("one")
      report = custom_report(
        artifacts: [artifact], discovered: ["ExampleTest#test_value"],
        selected: ["ExampleTest#test_value"], executed: [],
        dependencies: [], selection_mode: :full
      )
      store.acquire_lease!
      rejected = store.publish(report, outcomes: {})

      refute rejected.ready?
      assert_equal "provider_incomplete", rejected.publication[:reason]
      assert_nil store.generation
      assert_equal "provider_incomplete", store.recovery_reason
      store.close
    end
  end

  private

  def artifact_for(digest)
    Minitest::Testmon::Artifact.new(
      key: "artifact", provider: :core, root: :project, relative_path: "lib/example.rb",
      facet: "content", fingerprint: Minitest::Testmon::Fingerprint.known(digest),
      members: [], scope: :test, test_ids: ["ExampleTest#test_value"], reason: nil
    )
  end

  def report_for(artifact)
    observation = Minitest::Testmon::Observation.build(kind: :file_read, path: artifact.relative_path, operation: :read, test_id: "ExampleTest#test_value")
    Minitest::Testmon::DiscoveryReport.new(
      context_signature: "context",
      mode: :run,
      tests: {discovered: ["ExampleTest#test_value"], selected: ["ExampleTest#test_value"], executed: ["ExampleTest#test_value"]},
      observations: [observation],
      artifacts: [artifact],
      dependencies: [Minitest::Testmon::Dependency.new(test_id: "ExampleTest#test_value", artifact_key: artifact.key, provider: :core, complete: true)],
      observation_claims: {observation.key => [artifact.key]}
    )
  end

  def membership_artifact(digest, members)
    Minitest::Testmon::Artifact.new(
      key: "membership", provider: :core, root: :project, relative_path: "lib",
      facet: "membership", fingerprint: Minitest::Testmon::Fingerprint.known(digest),
      members: members, scope: :test, test_ids: [], reason: nil
    )
  end

  def report_for_membership(artifacts, membership)
    observation = Minitest::Testmon::Observation.build(
      kind: :file_read,
      path: "lib",
      operation: :membership,
      test_id: "ExampleTest#test_value"
    )
    Minitest::Testmon::DiscoveryReport.new(
      context_signature: "context",
      mode: :run,
      tests: {
        discovered: ["ExampleTest#test_value"],
        selected: ["ExampleTest#test_value"],
        executed: ["ExampleTest#test_value"]
      },
      observations: [observation],
      artifacts: artifacts,
      dependencies: artifacts.map do |artifact|
        Minitest::Testmon::Dependency.new(
          test_id: "ExampleTest#test_value",
          artifact_key: artifact.key,
          provider: :core,
          complete: true
        )
      end,
      observation_claims: {observation.key => artifacts.map(&:key)}
    )
  end

  def named_artifact(key, relative_path, digest)
    Minitest::Testmon::Artifact.new(
      key: key, provider: :core, root: :project, relative_path: relative_path,
      facet: "content", fingerprint: Minitest::Testmon::Fingerprint.known(digest),
      members: [], scope: :test, test_ids: [], reason: nil
    )
  end

  def custom_report(
    artifacts:, discovered:, selected:, executed:, dependencies:, mode: :run,
    selection_mode: nil
  )
    Minitest::Testmon::DiscoveryReport.new(
      context_signature: "context",
      mode: mode,
      tests: {discovered: discovered, selected: selected, executed: executed},
      artifacts: artifacts,
      dependencies: dependencies.map do |test_id, artifact|
        Minitest::Testmon::Dependency.new(
          test_id: test_id,
          artifact_key: artifact.key,
          provider: artifact.provider,
          complete: true
        )
      end,
      selection_mode: selection_mode
    )
  end
end

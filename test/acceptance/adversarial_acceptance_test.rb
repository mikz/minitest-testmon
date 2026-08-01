# frozen_string_literal: true

require_relative "test_helper"

class AdversarialAcceptanceTest < Minitest::Test
  include ProductAcceptance

  RUN_DEADLINE = 30
  SpawnedRun = Data.define(:status, :stdout, :stderr, :timed_out) do
    def success?
      !timed_out && status&.success?
    end

    def exitstatus
      status&.exitstatus
    end
  end

  def test_content_mutation_during_selected_test_rejects_publication_and_retries_the_test
    assert_during_test_mutation("content")
  end

  def test_membership_mutation_during_selected_test_rejects_publication_and_rechecks_suite_membership
    assert_during_test_mutation("membership")
  end

  def test_symlink_mutation_during_selected_test_rejects_publication_and_retries_the_test
    assert_during_test_mutation("symlink")
  end

  def test_content_mutation_after_selection_before_read_rejects_publication
    assert_selection_gap_mutation("content")
  end

  def test_membership_mutation_after_selection_before_read_rejects_publication
    assert_selection_gap_mutation("membership")
  end

  def test_symlink_mutation_after_selection_before_read_rejects_publication
    assert_selection_gap_mutation("symlink")
  end

  def test_delayed_background_thread_crossing_test_boundaries_is_never_attached_to_a_test
    with_adversarial_project do |project|
      baseline = learn_baseline(project)
      project.write("data/background_trigger.txt", "trigger-v2\n")

      result, report = run_adversarial(project, env: {
        "ADVERSARIAL_BACKGROUND_BOUNDARY" => "1",
        "EXPECTED_BACKGROUND_TRIGGER" => "trigger-v2\n"
      })
      refute result.success?, "unattributed background execution unexpectedly published"
      assert MinitestTestmonAcceptance::AdversarialOracle.assert_preserved_unpublished!(
        baseline,
        report,
        reason: "provider_incomplete"
      )
      assert MinitestTestmonAcceptance::AdversarialOracle.assert_late_background_observation!(
        report,
        path_suffix: "data/background.txt"
      )
    end
  end

  def test_membership_deletion_stabilizes_after_one_selected_run
    with_adversarial_project do |project|
      learn_baseline(project)
      project.remove("catalog/one.txt")

      changed, changed_report = run_adversarial(project, env: {"EXPECTED_CATALOG" => ""})
      assert changed.success?, changed.stderr
      assert MinitestTestmonAcceptance::AdversarialOracle.assert_full_recovery!(changed_report)

      warm, warm_report = run_adversarial(project, env: {"EXPECTED_CATALOG" => ""})
      assert warm.success?, warm.stderr
      assert MinitestTestmonAcceptance::AdversarialOracle.assert_warm_zero!(warm_report)
    end
  end

  def test_membership_rename_stabilizes_after_one_selected_run
    with_adversarial_project do |project|
      learn_baseline(project)
      FileUtils.mv(project.path.join("catalog/one.txt"), project.path.join("catalog/renamed.txt"))

      changed, changed_report = run_adversarial(project, env: {"EXPECTED_CATALOG" => "renamed.txt"})
      assert changed.success?, changed.stderr
      assert MinitestTestmonAcceptance::AdversarialOracle.assert_full_recovery!(changed_report)

      warm, warm_report = run_adversarial(project, env: {"EXPECTED_CATALOG" => "renamed.txt"})
      assert warm.success?, warm.stderr
      assert MinitestTestmonAcceptance::AdversarialOracle.assert_warm_zero!(warm_report)
    end
  end

  def test_skipped_selected_test_retains_its_snapshot_and_retry_state
    with_adversarial_project do |project|
      baseline = learn_baseline(project)
      selected_id = find_test_id(baseline, "SkipSelectedTest#test_selected_input")
      project.write("data/skip.txt", "skip-v2\n")

      skipped, skipped_report = run_adversarial(project, env: {"ADVERSARIAL_SKIP_SELECTED" => "1"})
      assert skipped.success?, skipped.stderr
      assert_includes skipped_report.dig("tests", "selected"), selected_id
      assert_includes skipped_report.dig("tests", "executed"), selected_id
      assert_equal true, skipped_report.dig("publication", "published")
      assert_equal baseline.fetch("generation"), skipped_report.fetch("generation")

      recovery, recovery_report = run_adversarial(project, env: {"EXPECTED_SKIP" => "skip-v2\n"})
      assert recovery.success?, recovery.stderr
      assert_equal [selected_id], recovery_report.dig("tests", "selected")
      assert_equal [selected_id], recovery_report.dig("tests", "executed")

      project.write("data/skip.txt", "skip-v3\n")
      selected, selected_report = run_adversarial(project, env: {"EXPECTED_SKIP" => "skip-v3\n"})
      assert selected.success?, selected.stderr
      assert_equal [selected_id], selected_report.dig("tests", "selected")
    end
  end

  def test_failed_test_removed_by_complete_discovery_is_pruned_from_edges
    with_adversarial_project do |project|
      baseline = learn_baseline(project)
      removed_id = find_test_id(baseline, "RemovedTest#test_removed_input")
      project.write("data/removed.txt", "removed-v2\n")

      failed, failed_report = run_adversarial(project, env: {
        "EXPECTED_REMOVED" => "removed-v2\n",
        "ADVERSARIAL_FAIL_REMOVED" => "1"
      })
      refute failed.success?, "planted removed-test failure exited zero"
      assert MinitestTestmonAcceptance::AdversarialOracle.assert_preserved_unpublished!(baseline, failed_report)

      project.remove("test/removed_test.rb")
      discovered = driver.run(project, full: true)
      assert discovered.success?, discovered.stderr
      discovery_report = driver.report(project)
      assert_report_contract discovery_report
      assert_equal true, discovery_report.dig("publication", "published")
      assert MinitestTestmonAcceptance::AdversarialOracle.assert_pruned!(discovery_report, removed_id)

      warm, warm_report = run_adversarial(project)
      assert warm.success?, warm.stderr
      assert MinitestTestmonAcceptance::AdversarialOracle.assert_warm_zero!(warm_report)
    end
  end

  def test_complete_discovery_publishes_a_warm_baseline
    with_adversarial_project do |project|
      discovered = driver.run(project, full: true)
      assert discovered.success?, discovered.stderr
      report = driver.report(project)
      assert_report_contract report
      assert_equal true, report.fetch("ready")
      assert_equal true, report.dig("publication", "published")
      assert_kind_of Integer, report.fetch("generation")
      assert_equal report.dig("tests", "discovered"), report.dig("tests", "executed")

      warm, warm_report = run_adversarial(project)
      assert warm.success?, warm.stderr
      assert MinitestTestmonAcceptance::AdversarialOracle.assert_warm_zero!(warm_report)
    end
  end

  def test_incomplete_discovery_is_nonzero_unpublished_and_actionable
    with_adversarial_project do |project|
      baseline = learn_baseline(project)
      result = driver.run(project, full: true, env: {"ADVERSARIAL_INCOMPLETE_DISCOVERY" => "1"})
      refute result.success?, "planted incomplete discovery exited zero"
      report = driver.report(project)
      assert_report_contract report
      assert MinitestTestmonAcceptance::AdversarialOracle.assert_preserved_unpublished!(baseline, report)
      refute_empty report.fetch("suggestions")
      assert report.fetch("suggestions").any? { |suggestion| suggestion.fetch("code") == "uncovered_file" }
    end
  end

  def test_stored_path_replaced_by_outside_root_fifo_is_rejected_without_publishing
    skip "FIFO support is required" unless File.respond_to?(:mkfifo)

    with_adversarial_project do |project|
      baseline = learn_baseline(project)
      Dir.mktmpdir("minitest-testmon-escape-") do |directory|
        fifo = Pathname(directory).join("secret.txt")
        marker = Pathname(directory).join("fifo-opened")
        File.mkfifo(fifo)
        project.remove("data/symlink.txt")
        File.symlink(fifo, project.path.join("data/symlink.txt"))
        writer_pid = Process.fork do
          File.open(fifo, "w") do |file|
            marker.write("read")
            file.write("escaped\n")
          end
          exit! 0
        end

        begin
          result = supervise_driver(project, timeout: RUN_DEADLINE)
          refute result.timed_out, "symlink escape run hung while opening an outside-root FIFO"
          refute result.success?, "symlink escape unexpectedly succeeded"
          report = driver.report(project)
          assert_report_contract report
          assert MinitestTestmonAcceptance::AdversarialOracle.assert_preserved_unpublished!(baseline, report)
          assert_equal report.dig("tests", "discovered"), report.dig("tests", "selected")
          assert_equal report.dig("tests", "discovered"), report.dig("tests", "executed")
          assert marker.exist?, "application fixture did not exercise the outside-root FIFO"
        ensure
          terminate_child(writer_pid)
        end
      end
    end
  end

  def test_provider_version_change_invalidates_context_and_forces_full_run
    with_adversarial_project do |project|
      baseline = learn_baseline(project)
      source = project.read(".minitest-testmon.rb")
      changed = source.sub("config.provider :race_inputs, version: 1", "config.provider :race_inputs, version: 2")
      refute_equal source, changed
      project.write(".minitest-testmon.rb", changed)

      result, report = run_adversarial(project)
      assert result.success?, result.stderr
      refute_equal baseline.fetch("context_signature"), report.fetch("context_signature")
      assert_equal baseline.fetch("generation") + 1, report.fetch("generation")
      assert MinitestTestmonAcceptance::AdversarialOracle.assert_full_recovery!(report)
    end
  end

  def test_native_minitest_parallelize_me_is_rejected_before_test_marker
    with_adversarial_project do |project|
      baseline = learn_baseline(project)
      marker = project.path.join("tmp/native-parallel-marker")
      result, report = run_adversarial(project, env: {
        "ADVERSARIAL_NATIVE_PARALLEL" => "1",
        "ADVERSARIAL_NATIVE_PARALLEL_MARKER" => marker.to_s
      })
      refute result.success?, "native Minitest parallelization exited zero"
      assert_equal "unsupported_parallelism", report.dig("publication", "reason")
      assert MinitestTestmonAcceptance::AdversarialOracle.assert_preserved_unpublished!(baseline, report)
      assert_empty report.dig("tests", "executed")
      refute marker.exist?, "parallel test body ran before rejection"
    end
  end

  def test_suite_scoped_provider_is_explicit_in_report_and_selects_every_test
    with_adversarial_project do |project|
      baseline = learn_baseline(project)
      assert MinitestTestmonAcceptance::AdversarialOracle.assert_suite_scoped!(
        baseline,
        provider: "suite_inputs@1",
        path_suffix: "data/suite.txt"
      )
      project.write("data/suite.txt", "suite-v2\n")

      result, report = run_adversarial(project, env: {"EXPECTED_SUITE" => "suite-v2\n"})
      assert result.success?, result.stderr
      assert_equal report.dig("tests", "discovered"), report.dig("tests", "selected")
      assert_equal report.dig("tests", "discovered"), report.dig("tests", "executed")
      assert MinitestTestmonAcceptance::AdversarialOracle.assert_suite_scoped!(
        report,
        provider: "suite_inputs@1",
        path_suffix: "data/suite.txt"
      )
    end
  end

  def test_overlapping_providers_share_one_canonical_physical_artifact
    with_adversarial_project do |project|
      report = learn_baseline(project)
      assert MinitestTestmonAcceptance::AdversarialOracle.assert_one_physical_artifact!(
        report,
        path_suffix: "data/overlap.txt",
        providers: %w[overlap_a@1 overlap_b@1]
      )
    end
  end

  def test_report_replacement_is_atomic_when_selected_test_process_is_killed
    with_adversarial_project do |project|
      baseline = learn_baseline(project)
      project.write("data/atomic.txt", "atomic-v2\n")
      ready = project.path.join("tmp/atomic-ready")
      release = project.path.join("tmp/atomic-release")

      run = spawn_driver(project, env: {
        "EXPECTED_ATOMIC" => "atomic-v2\n",
        "ADVERSARIAL_ATOMIC_READY" => ready.to_s,
        "ADVERSARIAL_ATOMIC_RELEASE" => release.to_s
      })
      begin
        wait_until("selected test never reached atomic-report barrier") { ready.file? }
        terminate_process_group(run.fetch(:pid))
        run[:pid] = nil
        report = driver.report(project)
        assert_report_contract report
        assert_equal baseline.fetch("generation"), report.fetch("generation")
      ensure
        release.write("release") unless release.exist?
        terminate_process_group(run[:pid])
      end
    end
  end

  private

  def with_adversarial_project
    require_product!
    with_project("adversarial") do |project|
      File.symlink("symlink_target_a.txt", project.path.join("data/symlink.txt"))
      yield project
    end
  end

  def learn_baseline(project)
    result, report = run_adversarial(project)
    assert result.success?, result.stderr
    assert_equal report.dig("tests", "discovered"), report.dig("tests", "executed")
    assert_equal true, report.dig("publication", "published")
    report
  end

  def run_adversarial(project, env: {})
    result = driver.run(project, env: env)
    report = driver.report(project)
    assert_report_contract report
    [result, report]
  end

  def assert_only_test(report, fragment)
    test_id = find_test_id(report, fragment)
    assert_equal [test_id], report.dig("tests", "selected")
    assert_equal [test_id], report.dig("tests", "executed")
  end

  def assert_during_test_mutation(kind)
    with_adversarial_project do |project|
      baseline = learn_baseline(project)
      mutate_trigger(project, kind)
      result, report = run_adversarial(project, env: mutation_env(kind).merge(
        "ADVERSARIAL_MUTATE_DURING" => kind
      ))
      refute result.success?, "#{kind} mutation during test exited zero"
      assert MinitestTestmonAcceptance::AdversarialOracle.assert_preserved_unpublished!(
        baseline,
        report,
        reason: "provider_incomplete"
      )

      recovery, recovery_report = run_adversarial(project, env: recovered_env(kind))
      assert recovery.success?, recovery.stderr
      assert_recovery_selection(kind, recovery_report)
    end
  end

  def assert_selection_gap_mutation(kind)
    with_adversarial_project do |project|
      baseline = learn_baseline(project)
      mutate_trigger(project, kind)
      ready = project.path.join("tmp/#{kind}-gap-ready")
      release = project.path.join("tmp/#{kind}-gap-release")
      run = spawn_driver(project, env: recovered_env(kind).merge(
        "ADVERSARIAL_SELECTION_GAP" => kind,
        "ADVERSARIAL_GAP_READY" => ready.to_s,
        "ADVERSARIAL_GAP_RELEASE" => release.to_s
      ))
      begin
        wait_until("#{kind} test never entered selection gap") { ready.file? }
        mutate_input(project, kind)
        release.write("release")
        result = finish_spawned(run, timeout: RUN_DEADLINE)
        run[:pid] = nil
        refute result.timed_out, "#{kind} selection-gap run timed out"
        refute result.success?, "#{kind} selection-gap mutation exited zero"
        report = driver.report(project)
        assert_report_contract report
        assert MinitestTestmonAcceptance::AdversarialOracle.assert_preserved_unpublished!(
          baseline,
          report,
          reason: "provider_incomplete"
        )
      ensure
        release.write("release") unless release.exist?
        terminate_process_group(run[:pid])
      end
    end
  end

  def mutate_trigger(project, kind)
    project.write("data/#{kind}_trigger.txt", "trigger-v2\n")
  end

  def assert_recovery_selection(kind, report)
    if %w[membership symlink].include?(kind)
      assert MinitestTestmonAcceptance::AdversarialOracle.assert_full_recovery!(report)
    else
      assert_only_test report, "RaceInputTest#test_#{kind}_input"
    end
  end

  def mutate_input(project, kind)
    case kind
    when "content"
      project.write("data/content.txt", "content-v2\n")
    when "membership"
      project.write("catalog/two.txt", "two\n")
    when "symlink"
      project.remove("data/symlink.txt")
      File.symlink("symlink_target_b.txt", project.path.join("data/symlink.txt"))
    else
      raise ArgumentError, "unknown mutation kind #{kind.inspect}"
    end
  end

  def mutation_env(kind)
    {"EXPECTED_#{kind.upcase}_TRIGGER" => "trigger-v2\n"}
  end

  def recovered_env(kind)
    mutation_env(kind).merge(
      case kind
      when "content" then {"EXPECTED_CONTENT" => "content-v2\n"}
      when "membership" then {"EXPECTED_CATALOG" => "one.txt,two.txt"}
      when "symlink" then {"EXPECTED_SYMLINK" => "symlink-v2\n"}
      end
    )
  end

  def spawn_driver(project, env: {})
    stdout = project.path.join("tmp/run-#{Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)}.stdout")
    stderr = Pathname(stdout.to_s.sub(/\.stdout\z/, ".stderr"))
    FileUtils.mkdir_p(stdout.dirname)
    pid = Process.spawn(
      env,
      *driver.bin,
      "run",
      "--",
      *project.test_command,
      chdir: project.path.to_s,
      out: stdout.to_s,
      err: stderr.to_s,
      pgroup: true
    )
    {pid:, stdout:, stderr:}
  end

  def finish_spawned(run, timeout:)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    status = nil
    until status
      status = Process.waitpid2(run.fetch(:pid), Process::WNOHANG)&.last
      break if status || Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      sleep 0.01
    end
    timed_out = status.nil?
    terminate_process_group(run.fetch(:pid)) if timed_out
    SpawnedRun.new(
      status:,
      stdout: run.fetch(:stdout).read,
      stderr: run.fetch(:stderr).read,
      timed_out:
    )
  rescue Errno::ECHILD
    SpawnedRun.new(status: nil, stdout: run.fetch(:stdout).read, stderr: run.fetch(:stderr).read, timed_out: false)
  end

  def supervise_driver(project, timeout:, env: {})
    run = spawn_driver(project, env:)
    finish_spawned(run, timeout:)
  ensure
    terminate_process_group(run&.[](:pid))
  end

  def wait_until(message, timeout: 20)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until yield
      flunk message if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      sleep 0.01
    end
  end

  def terminate_process_group(pid)
    return unless pid
    Process.kill("KILL", -pid)
    Process.wait(pid)
  rescue Errno::ESRCH, Errno::ECHILD
    nil
  end

  def terminate_child(pid)
    return unless pid
    Process.kill("KILL", pid)
    Process.wait(pid)
  rescue Errno::ESRCH, Errno::ECHILD
    nil
  end
end

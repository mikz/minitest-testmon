# frozen_string_literal: true

require_relative "test_helper"

class StorageAcceptanceTest < Minitest::Test
  include ProductAcceptance

  def test_successful_publication_generation_and_failed_run_guard
    require_product!
    require_sqlite!

    with_project("selection") do |project|
      baseline = learn_baseline(project)
      generation = baseline.fetch("generation")
      assert_kind_of Integer, generation
      assert_sqlite_integrity driver.state_path(project)

      original = project.read("lib/subject.rb")
      project.write("lib/subject.rb", original.sub("1 + 1", "1 + 2"))
      failed = driver.run(project)
      refute failed.success?, "known failing semantic mutant exited zero"
      failed_report = driver.report(project)
      assert_report_contract failed_report
      assert_equal false, failed_report.dig("publication", "published")
      assert_equal generation, failed_report.fetch("generation")

      project.write("lib/subject.rb", original)
      repaired = driver.run(project)
      assert repaired.success?, repaired.stderr
      repaired_report = driver.report(project)
      assert_report_contract repaired_report
      alpha_id = find_test_id(repaired_report, "test_alpha")
      assert_includes repaired_report.dig("tests", "executed"), alpha_id,
        "failed test was not retained dirty for the recovery run"
      assert_equal generation + 1, repaired_report.fetch("generation")
      assert_sqlite_integrity driver.state_path(project)
    end
  end

  def test_corrupt_state_is_quarantined_and_never_used_for_selection
    require_product!
    require_sqlite!

    with_project("selection") do |project|
      learn_baseline(project)
      corrupt_bytes = "not-a-sqlite-database\x00acceptance"
      project.write(".minitest-testmon.sqlite3", corrupt_bytes)

      result = driver.run(project)
      assert result.success?, "safe rebuild failed: #{result.stdout}\n#{result.stderr}"
      report = driver.report(project)
      assert_report_contract report
      assert_equal report.dig("tests", "discovered"), report.dig("tests", "selected")
      assert_equal report.dig("tests", "discovered"), report.dig("tests", "executed")
      assert_equal true, report.dig("publication", "published")
      assert_equal "cache_corrupt_rebuilt", report.dig("publication", "reason")

      quarantined = Dir[project.path.join(".minitest-testmon.sqlite3.corrupt-*-*")]
      assert_equal 1, quarantined.length,
        "corrupt DB must be preserved under the frozen quarantine filename"
      assert_equal corrupt_bytes, File.binread(quarantined.fetch(0))
      assert_sqlite_integrity driver.state_path(project)
    end
  end

  def test_concurrent_parent_lease_fails_fast_and_stale_generation_cannot_publish
    require_product!
    require_sqlite!

    with_project("selection") do |project|
      first_pid = nil
      begin
        baseline = learn_baseline(project)
        generation = baseline.fetch("generation")
        project.write("lib/subject.rb", project.read("lib/subject.rb").sub("1 + 1", "2 + 0"))

        ready = project.path.join("tmp/lease-ready")
        release = project.path.join("tmp/lease-release")
        FileUtils.mkdir_p(ready.dirname)
        first_stdout = project.path.join("tmp/first.stdout")
        first_stderr = project.path.join("tmp/first.stderr")
        argv = [*driver.bin, "run", "--", *project.test_command]
        first_pid = Process.spawn(
          {"ACCEPTANCE_LEASE_READY" => ready.to_s, "ACCEPTANCE_LEASE_RELEASE" => release.to_s},
          *argv,
          chdir: project.path.to_s,
          out: first_stdout.to_s,
          err: first_stderr.to_s
        )

        wait_until("first runner did not enter lease barrier") { ready.file? }
        loser = driver.run(project)
        refute loser.success?, "concurrent lease loser waited or exited zero"
        loser_report = driver.report(project)
        assert_report_contract loser_report
        assert_equal false, loser_report.dig("publication", "published")
        assert_equal "cache_lease_unavailable", loser_report.dig("publication", "reason")
        assert_empty loser_report.dig("tests", "executed")
        assert_equal generation, loser_report.fetch("generation")

        release.write("release")
        _, first_status = Process.wait2(first_pid)
        first_pid = nil
        assert first_status.success?, "lease owner failed: #{first_stdout.read}\n#{first_stderr.read}"
        owner_report = driver.report(project)
        assert_report_contract owner_report
        assert_equal true, owner_report.dig("publication", "published")
        assert_equal generation + 1, owner_report.fetch("generation")
        assert_sqlite_integrity driver.state_path(project)
      ensure
        terminate_child(first_pid)
      end
    end
  end

  def test_active_sqlite_owner_makes_second_runner_busy_without_corrupt_quarantine
    require_product!
    require_sqlite!

    with_project("selection") do |project|
      owner_pid = nil
      begin
        baseline = learn_baseline(project)
        generation = baseline.fetch("generation")
        project.write("lib/subject.rb", project.read("lib/subject.rb").sub("1 + 1", "2 + 0"))
        ready = project.path.join("tmp/busy-owner-ready")
        release = project.path.join("tmp/busy-owner-release")
        stdout = project.path.join("tmp/busy-owner.stdout")
        stderr = project.path.join("tmp/busy-owner.stderr")
        FileUtils.mkdir_p(ready.dirname)
        before_quarantine = Dir[project.path.join(".minitest-testmon.sqlite3.corrupt-*-*")]

        owner_pid = Process.spawn(
          {"ACCEPTANCE_LEASE_READY" => ready.to_s, "ACCEPTANCE_LEASE_RELEASE" => release.to_s},
          *driver.bin,
          "run",
          "--",
          *project.test_command,
          chdir: project.path.to_s,
          out: stdout.to_s,
          err: stderr.to_s
        )
        wait_until("active SQLite owner never reached test barrier") { ready.file? }

        busy = driver.run(project)
        refute busy.success?, "second runner waited for or stole the active SQLite owner"
        assert_includes busy.stderr, "cache_lease_unavailable"
        busy_report = driver.report(project)
        assert_report_contract busy_report
        assert_equal false, busy_report.dig("publication", "published")
        assert_equal "cache_lease_unavailable", busy_report.dig("publication", "reason")
        assert_equal generation, busy_report.fetch("generation")
        assert_empty busy_report.dig("tests", "executed")
        assert_equal before_quarantine,
          Dir[project.path.join(".minitest-testmon.sqlite3.corrupt-*-*")],
          "ordinary SQLite busy state was mislabeled and quarantined as corruption"
        assert_sqlite_integrity driver.state_path(project)

        release.write("release")
        _, owner_status = Process.wait2(owner_pid)
        owner_pid = nil
        assert owner_status.success?, "SQLite owner failed: #{stdout.read}\n#{stderr.read}"
        assert_empty Dir[project.path.join(".minitest-testmon.sqlite3.corrupt-*-*")]
      ensure
        release&.write("release") unless release&.exist?
        terminate_child(owner_pid)
      end
    end
  end

  private

  def learn_baseline(project)
    result = driver.run(project)
    assert result.success?, result.stderr
    report = driver.report(project)
    assert_report_contract report
    assert_equal true, report.dig("publication", "published")
    report
  end

  def require_sqlite!
    return if system("sqlite3", "--version", out: File::NULL, err: File::NULL)
    skip "sqlite3 executable is required for black-box integrity checks"
  end

  def assert_sqlite_integrity(path)
    integrity, error, status = Open3.capture3("sqlite3", path.to_s, "PRAGMA integrity_check;")
    assert status.success?, error
    assert_equal "ok\n", integrity

    foreign_keys, foreign_key_error, foreign_key_status = Open3.capture3(
      "sqlite3", path.to_s, "PRAGMA foreign_key_check;"
    )
    assert foreign_key_status.success?, foreign_key_error
    assert_empty foreign_keys
  end

  def wait_until(message, timeout: 10)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until yield
      flunk message if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      sleep 0.01
    end
  end

  def terminate_child(pid)
    return unless pid
    Process.kill("KILL", pid)
    Process.wait(pid)
  rescue Errno::ESRCH, Errno::ECHILD
    nil
  end
end

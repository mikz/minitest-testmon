# frozen_string_literal: true

require_relative "rails_test_helper"

class RailsAdversarialAcceptanceTest < Minitest::Test
  include RailsProductAcceptance

  ITERATIONS = 20_000
  HIGH_VOLUME_BARRIER_TIMEOUT = 90
  MAX_SPOOL_BYTES = 32 * 1024 * 1024
  MAX_PROCESS_RSS_KIB = 384 * 1024

  def test_high_volume_worker_observations_stream_to_bounded_jsonl_before_test_exit
    skip "ps is required for the external memory bound" unless executable_on_path?("ps")

    with_rails_project(workers: 2) do |project, runtime|
      learn_rails_baseline(project, runtime)
      policy = project.read("config/policies/rules.yml")
      project.write("config/policies/rules.yml", policy.sub("v1", "v2"))
      barrier = project.path.join("tmp/high-volume-spool")
      stdout = project.path.join("tmp/high-volume.stdout")
      stderr = project.path.join("tmp/high-volume.stderr")
      release = barrier.join("release")
      runner_pid = nil

      begin
        runner_pid = Process.spawn(
          runtime.env.merge(
            "EXPECTED_POLICY_MODE" => "v2",
            "RAILS_ACCEPTANCE_HIGH_VOLUME_ITERATIONS" => ITERATIONS.to_s,
            "RAILS_ACCEPTANCE_HIGH_VOLUME_BARRIER" => barrier.to_s
          ),
          *driver.bin,
          "run",
          "--",
          *project.test_command,
          chdir: project.path.to_s,
          out: stdout.to_s,
          err: stderr.to_s,
          pgroup: true
        )
        diagnostic = ->(message) do
          "#{message}\nstdout:\n#{stdout.read}\nstderr:\n#{stderr.read}"
        end
        wait_for(
          -> { diagnostic.call("high-volume worker never reached post-observation barrier after #{HIGH_VOLUME_BARRIER_TIMEOUT}s") },
          timeout: HIGH_VOLUME_BARRIER_TIMEOUT
        ) do
          next true if barrier.glob("ready-*").any?
          if (waited = Process.waitpid2(runner_pid, Process::WNOHANG))
            flunk diagnostic.call("high-volume Rails runner exited before reaching the post-observation barrier (#{waited.last.inspect})")
          end
          false
        end
        wait_for("worker spool was not externally visible before test exit", timeout: 10) do
          jsonl_spools(project).any? { |path| path.size.positive? }
        end

        spools = jsonl_spools(project)
        refute_empty spools
        total_bytes = spools.sum(&:size)
        assert_operator total_bytes, :<=, MAX_SPOOL_BYTES,
          "#{ITERATIONS} duplicate observations produced #{total_bytes} spool bytes"

        worker_pids = barrier.glob("ready-*").map { |path| path.basename.to_s.delete_prefix("ready-").to_i }
        ([runner_pid] + worker_pids).each do |pid|
          rss = process_rss_kib(pid)
          assert_operator rss, :<=, MAX_PROCESS_RSS_KIB,
            "process #{pid} used #{rss} KiB during bounded spool run"
        end

        release.write("release")
        _, status = Process.wait2(runner_pid)
        runner_pid = nil
        assert status.success?, "high-volume Rails run failed: #{stdout.read}\n#{stderr.read}"
        report = driver.report(project)
        assert_report_contract report
        assert_selected_includes report,
          "HighVolumeSpoolTest#test_repeated_provider_observations_stream_to_worker_spool"
        assert_equal true, report.dig("publication", "published")
      ensure
        FileUtils.mkdir_p(release.dirname)
        release.write("release") unless release.exist?
        terminate_process_group(runner_pid)
      end
    end
  end

  private

  def executable_on_path?(name)
    ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? do |directory|
      File.executable?(File.join(directory, name))
    end
  end

  def jsonl_spools(project)
    project.path.glob("tmp/minitest-testmon/**/*.jsonl").select(&:file?)
  end

  def process_rss_kib(pid)
    output, error, status = Open3.capture3("ps", "-o", "rss=", "-p", pid.to_s)
    assert status.success?, "ps failed for #{pid}: #{error}"
    Integer(output.strip)
  end

  def terminate_process_group(pid)
    return unless pid
    Process.kill("KILL", -pid)
    Process.wait(pid)
  rescue Errno::ESRCH, Errno::ECHILD
    nil
  end
end

# frozen_string_literal: true

require_relative "test_helper"
require "open3"
require "rbconfig"
require "timeout"

class CheckpointRuntimeTest < TestmonTestCase
  EXECUTABLE = File.expand_path("../exe/minitest-testmon", __dir__)

  def test_killed_cold_run_keeps_checkpoints_and_retries_only_unfinished_tests
    with_checkpoint_project do |project|
      pid = start_run(project, "PAUSE" => "1")
      wait_for_checkpoint(project)
      Process.kill("KILL", -pid)
      Process.wait(pid)
      pid = nil
      report = finish_run(project)
      assert_equal 5, report.dig("tests", "selected").length
      assert report.dig("tests", "selected").all? { |id| id.split("_").last.to_i >= 25 }
      assert_equal 30, snapshots_count(project)
    ensure
      stop_run(pid)
    end
  end

  def test_interrupted_forced_warm_run_reuses_accepted_tests_and_retries_unfinished_tests
    with_checkpoint_project do |project|
      finish_run(project)
      pid = start_run(project, "PAUSE" => "1", "MINITEST_TESTMON_FULL" => "1")
      Timeout.timeout(30) do
        sleep 0.02 until File.exist?(File.join(project, "tmp/ready"))
      end
      Process.kill("KILL", -pid)
      Process.wait(pid)
      pid = nil
      assert_equal 30, snapshots_count(project)
      report = finish_run(project)
      assert_equal 5, report.dig("tests", "selected").length
      assert report.dig("tests", "selected").all? { |id| id.split("_").last.to_i >= 25 }
    ensure
      stop_run(pid)
    end
  end

  def test_late_failure_keeps_passing_tests_and_retries_failure
    with_checkpoint_project do |project|
      _out, stderr, status = Open3.capture3({"FAIL_LAST" => "1"}, *command, chdir: project)
      refute status.success?, stderr
      assert_equal 29, snapshots_count(project)
      report = finish_run(project)
      assert_equal ["CheckpointExample#test_29"], report.dig("tests", "selected")
    end
  end

  def test_drift_pauses_learning_but_keeps_earlier_progress
    [false, true].each do |strict|
      with_checkpoint_project do |project|
        write_file(File.join(project, ".minitest-testmon.rb"), "Minitest::Testmon.configure { |config| config.require_complete_cache #{strict} }\n")
        pid = start_run(project, "PAUSE" => "1")
        wait_for_checkpoint(project)
        File.write(File.join(project, "lib/unused.rb"), "UNUSED = 2\n")
        File.write(File.join(project, "tmp/release"), "go")
        _, status = Process.wait2(pid)
        pid = nil
        assert_equal(strict ? 4 : 0, status.exitstatus, File.read(File.join(project, "tmp/stderr")))
        assert_equal 25, snapshots_count(project)
        report = read_report(project)
        assert_equal "source_drift", report.dig("publication", "reason")
        assert_equal "source_drift", report.dig("checkpoints", "stop_reason")
        assert_equal 25, report.dig("checkpoints", "accepted_ids").length
        assert_equal 30, report.dig("tests", "executed").length
        # An unused source edit does not change the saved tests' learned inputs.
        assert_equal 5, finish_run(project).dig("tests", "selected").length
      ensure
        stop_run(pid)
      end
    end
  end

  def test_unresolvable_test_definition_does_not_block_other_checkpoints
    with_checkpoint_project do |project|
      File.open(File.join(project, "test/example_test.rb"), "a") do |file|
        file.puts <<~RUBY_TEST
          CheckpointExample.define_method(:test_10, Kernel.instance_method(:itself))
        RUBY_TEST
      end
      report = finish_run(project)
      assert_equal 29, snapshots_count(project)
      assert_nil report.dig("checkpoints", "stop_reason")
      assert_equal "provider_incomplete", report.dig("publication", "reason")
      assert_equal ["CheckpointExample#test_10"], finish_run(project).dig("tests", "selected")
    end
  end

  def test_method_names_containing_hash_are_checkpointed_and_reused
    with_checkpoint_project do |project|
      File.open(File.join(project, "test/example_test.rb"), "a") do |file|
        file.puts 'CheckpointExample.define_method("test_Mailer#action_has_a_named_preview") { assert_equal 2, 1 + 1 }'
      end
      id = "CheckpointExample#test_Mailer#action_has_a_named_preview"
      cold = finish_run(project)
      assert cold.dig("publication", "published"), cold.fetch("publication").inspect
      assert_includes cold.dig("checkpoints", "accepted_ids"), id
      assert_equal 31, snapshots_count(project)
      warm = finish_run(project)
      assert_empty warm.dig("tests", "selected")
      assert warm.dig("publication", "published")
    end
  end

  def test_strict_publication_finishes_every_test_and_preserves_checkpoints
    [command, [RbConfig.ruby, "-I#{File.expand_path("../lib", __dir__)}", "-rminitest/testmon_plugin", "-Itest", "test/example_test.rb", "--testmon"]].each do |invocation|
      with_checkpoint_project do |project|
        write_file(File.join(project, ".minitest-testmon.rb"), "Minitest::Testmon.configure { |config| config.require_complete_cache true }\n")
        File.open(File.join(project, "test/example_test.rb"), "a") do |file|
          file.puts "CheckpointExample.define_method(:test_10, Kernel.instance_method(:itself))"
        end

        environment = {"MINITEST_TESTMON_CONFIG" => File.join(project, ".minitest-testmon.rb")}
        stdout, stderr, status = Open3.capture3(environment, *invocation, chdir: project)
        assert_equal 4, status.exitstatus, [stdout, stderr].join("\n")
        assert_match(/30 runs,/, stdout)
        report = read_report(project)
        assert_equal 30, report.dig("tests", "executed").length
        assert_equal "provider_incomplete", report.dig("publication", "reason")
        assert_equal 29, snapshots_count(project)

        _stdout, stderr, status = Open3.capture3(environment, *invocation, chdir: project)
        assert_equal 4, status.exitstatus, stderr
        assert_equal ["CheckpointExample#test_10"], read_report(project).dig("tests", "selected")
      end
    end
  end

  def test_strict_complete_and_zero_selection_runs_succeed
    with_checkpoint_project do |project|
      write_file(File.join(project, ".minitest-testmon.rb"), "Minitest::Testmon.configure { |config| config.require_complete_cache true }\n")
      assert_equal 30, finish_run(project).dig("tests", "executed").length
      assert_empty finish_run(project).dig("tests", "selected")
    end
  end

  private

  def with_checkpoint_project
    with_project do |project|
      FileUtils.mkdir_p(File.join(project, "tmp"))
      write_file(File.join(project, "lib/unused.rb"), "UNUSED = 1\n")
      methods = 30.times.map do |number|
        <<~RUBY_METHOD
          def test_#{format("%02d", number)}
            if #{number} == 25 && ENV["PAUSE"]
              File.write("tmp/ready", "ready")
              sleep 0.01 until File.exist?("tmp/release")
            end
            flunk "planted failure" if #{number} == 29 && ENV["FAIL_LAST"]
            assert_equal 2, 1 + 1
          end
        RUBY_METHOD
      end.join("\n")
      write_file(File.join(project, "test/example_test.rb"), <<~RUBY_TEST)
        require "minitest/autorun"
        class CheckpointExample < Minitest::Test
          def self.run_order = :alpha
          #{methods}
        end
      RUBY_TEST
      yield project
    end
  end

  def command
    [RbConfig.ruby, EXECUTABLE, "run", "--", RbConfig.ruby, "-Itest", "test/example_test.rb"]
  end

  def start_run(project, env)
    Process.spawn(env, *command, chdir: project, pgroup: true,
      out: File.join(project, "tmp/stdout"), err: File.join(project, "tmp/stderr"))
  end

  def wait_for_checkpoint(project)
    Timeout.timeout(30) do
      until File.exist?(File.join(project, "tmp/ready"))
        sleep 0.02
      end
    end
    assert_equal 25, snapshots_count(project), File.read(File.join(project, "tmp/stderr"))
  end

  def snapshots_count(project)
    database = SQLite3::Database.new(File.join(project, ".minitest-testmon.sqlite3"), readonly: true)
    database.get_first_value("SELECT count(*) FROM test_snapshots")
  ensure
    database&.close
  end

  def finish_run(project)
    _out, stderr, status = Open3.capture3(*command, chdir: project)
    assert status.success?, stderr
    read_report(project)
  end

  def read_report(project)
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, EXECUTABLE, "report", chdir: project)
    assert status.success?, stderr
    JSON.parse(stdout)
  end

  def stop_run(pid)
    return unless pid
    Process.kill("KILL", -pid)
    Process.wait(pid)
  rescue Errno::ESRCH, Errno::ECHILD
    nil
  end
end

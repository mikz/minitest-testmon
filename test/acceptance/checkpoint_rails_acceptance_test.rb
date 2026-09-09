# frozen_string_literal: true

require_relative "rails_cli_test_helper"
require "sqlite3"

class CheckpointRailsAcceptanceTest < Minitest::Test
  include RailsCliProductAcceptance

  def test_process_worker_checkpoints_survive_parent_termination
    with_rails_cli_project(workers: 2) do |project, runtime, cli|
      methods = 80.times.map do |number|
        "def test_checkpoint_#{number}; sleep 0.05; assert_equal 2, 1 + 1; end"
      end.join("\n")
      project.write("test/checkpoint_test.rb", <<~RUBY_TEST)
        require "test_helper"
        class CheckpointRailsExample < ActiveSupport::TestCase
          #{methods}
        end
      RUBY_TEST
      process = cli.start_flagged(env: runtime.env)
      accepted = []
      begin
        wait_for("Rails workers did not commit a checkpoint", timeout: 40) do
          if cli.state_path.file?
            database = SQLite3::Database.new(cli.state_path.to_s, readonly: true)
            begin
              if database.get_first_value("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'test_snapshots'")
                accepted = database.execute("SELECT test_id FROM test_snapshots").flatten
              end
            rescue SQLite3::BusyException
              # Still check for an exited child when the database is busy.
            ensure
              database.close
            end
          end
          next true if accepted.length >= 25
          if (exited = Process.waitpid2(process.pid, Process::WNOHANG))
            flunk "Rails exited before committing a checkpoint: #{exited.last.inspect}"
          end
          false
        end
      rescue Minitest::Assertion => error
        flunk "#{error.message}\n#{checkpoint_diagnostics(cli, process)}"
      end
      Process.kill("KILL", -process.pid)
      cli.finish(process)
      process = nil
      # Read after termination: another atomic batch may have committed between
      # the polling read and delivery of SIGKILL.
      database = SQLite3::Database.new(cli.state_path.to_s, readonly: true)
      accepted = database.execute("SELECT test_id FROM test_snapshots").flatten
      database.close
      recovered, report = run_cli(runtime, cli, timeout: 45)
      assert recovered.success?, cli_failure("checkpoint recovery", recovered)
      assert_operator accepted.length, :>=, 25
      assert_empty accepted & report.dig("tests", "selected")
      assert_operator report.dig("tests", "selected").length, :<, report.dig("tests", "discovered").length
      assert report.dig("publication", "published")
    ensure
      cli.finish(process, timeout: 1) if process
    end
  end

  private

  def checkpoint_diagnostics(cli, process)
    diagnostics = ["stdout:\n#{process.stdout_path.read}", "stderr:\n#{process.stderr_path.read}"]
    if cli.state_path.file?
      database = SQLite3::Database.new(cli.state_path.to_s, readonly: true)
      database.results_as_hash = true
      diagnostics << "receipts: #{database.execute("SELECT id, state, publication_reason, checkpoint_json FROM run_receipts").inspect}"
      diagnostics << "snapshots: #{database.get_first_value("SELECT count(*) FROM test_snapshots")}"
      diagnostics << "retries: #{database.execute("SELECT outcome, count(*) AS count FROM retry_tests GROUP BY outcome").inspect}"
    end
    diagnostics.join("\n")
  rescue SQLite3::Exception => error
    [*diagnostics, "SQLite diagnostics unavailable: #{error.message}"].join("\n")
  ensure
    database&.close
  end
end

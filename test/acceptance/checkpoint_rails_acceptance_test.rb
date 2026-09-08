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
      wait_for("Rails workers did not commit a checkpoint", timeout: 40) do
        if cli.state_path.file?
          database = SQLite3::Database.new(cli.state_path.to_s, readonly: true)
          begin
            accepted = database.execute("SELECT test_id FROM test_snapshots").flatten
          rescue SQLite3::BusyException
            next false
          ensure
            database.close
          end
        end
        accepted.length >= 25
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
end

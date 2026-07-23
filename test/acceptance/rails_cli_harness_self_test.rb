# frozen_string_literal: true

require_relative "test_helper"

class RailsCliHarnessSelfTest < Minitest::Test
  def test_driver_uses_the_exact_fixture_command_and_builds_only_the_activation_flag
    project = MinitestTestmonAcceptance::Project.copy_fixture("rails_app")
    driver = MinitestTestmonAcceptance::RailsCliDriver.new(project)
    fixture = MinitestTestmonAcceptance::FIXTURES.join("rails_app/bin/rails")
    stock_command = <<~RUBY
      #!/usr/bin/env ruby
      APP_PATH = File.expand_path("../config/application", __dir__)
      require_relative "../config/boot"
      require "rails/commands"
    RUBY

    assert_equal stock_command, fixture.read, "fixture bin/rails contains Testmon-specific bootstrap code"
    assert_equal fixture.binread, Pathname(driver.rails_bin).binread
    assert File.executable?(driver.rails_bin)
    assert_equal [
      driver.rails_bin,
      "test",
      "--testmon"
    ], driver.flagged_argv
  ensure
    project&.cleanup
  end

  def test_fixture_autorequires_gems_before_the_application_class_body
    fixture = MinitestTestmonAcceptance::FIXTURES.join("rails_app")
    application = fixture.join("config/application.rb").read
    bundler = application.index("Bundler.require(*Rails.groups)")
    inheritance = application.index("class Application < Rails::Application")
    observed_read = application.index("APP_BODY_POLICY = RailsPolicyLoader.load")

    refute_nil bundler
    refute_nil inheritance
    refute_nil observed_read
    assert_operator bundler, :<, inheritance
    assert_operator inheritance, :<, observed_read
  end

  def test_dynamic_rails_paths_are_registered_after_environment_initialization
    helper = MinitestTestmonAcceptance::FIXTURES.join("rails_app/test/test_helper.rb").read
    initialized = helper.index('require_relative "../config/environment"')
    view_path = helper.index("ActionController::Base.prepend_view_path")
    locale_path = helper.index("I18n.load_path <<")
    fixture_paths = helper.index("ActiveSupport::TestCase.fixture_paths")

    [view_path, locale_path, fixture_paths].each do |registration|
      assert_operator registration, :>, initialized
    end
  end

  def test_state_snapshot_includes_every_sqlite_sidecar_and_report_bytes
    project = MinitestTestmonAcceptance::Project.copy_fixture("rails_app")
    driver = MinitestTestmonAcceptance::RailsCliDriver.new(project)
    driver.state_path.dirname.mkpath
    driver.state_path.binwrite("database")
    Pathname("#{driver.state_path}-wal").binwrite("wal")
    driver.report_path.binwrite("report")

    snapshot = driver.snapshot

    assert_equal(
      {"state.sqlite3" => "database", "state.sqlite3-wal" => "wal"},
      snapshot.database_files
    )
    assert_equal "report", snapshot.report_bytes
  ensure
    project&.cleanup
  end

  def test_rejection_oracle_detects_one_changed_database_byte
    status = Struct.new(:exitstatus).new(2)
    result = MinitestTestmonAcceptance::CommandResult.new(
      argv: [],
      status:,
      stdout: "",
      stderr: ""
    )
    marker = Struct.new(:exist?).new(false)
    before = MinitestTestmonAcceptance::RailsCliState.new(
      database_files: {"state.sqlite3" => "before"},
      report_bytes: "same"
    )
    after = MinitestTestmonAcceptance::RailsCliState.new(
      database_files: {"state.sqlite3" => "after"},
      report_bytes: "same"
    )

    error = assert_raises(MinitestTestmonAcceptance::RailsCliOracle::Mismatch) do
      MinitestTestmonAcceptance::RailsCliOracle.assert_rejected_unchanged!(
        result,
        before:,
        after:,
        marker:
      )
    end
    assert_match "database bytes changed", error.message
  end

  def test_rejection_oracle_kills_cross_environment_warm_zero_mutant
    status = Struct.new(:exitstatus).new(0)
    result = MinitestTestmonAcceptance::CommandResult.new(
      argv: [],
      status:,
      stdout: "",
      stderr: ""
    )
    marker = Struct.new(:exist?).new(false)
    state = MinitestTestmonAcceptance::RailsCliState.new(
      database_files: {"state.sqlite3" => "unchanged"},
      report_bytes: "unchanged"
    )

    error = assert_raises(MinitestTestmonAcceptance::RailsCliOracle::Mismatch) do
      MinitestTestmonAcceptance::RailsCliOracle.assert_rejected_unchanged!(
        result,
        before: state,
        after: state,
        marker:
      )
    end
    assert_match "exited 0", error.message
  end

  def test_help_oracle_detects_one_missing_flag
    status = Struct.new(:exitstatus).new(0)
    result = MinitestTestmonAcceptance::CommandResult.new(
      argv: [],
      status:,
      stdout: "--testmon --testmon-db",
      stderr: ""
    )

    error = assert_raises(MinitestTestmonAcceptance::RailsCliOracle::Mismatch) do
      MinitestTestmonAcceptance::RailsCliOracle.assert_help!(
        result,
        state_files: [],
        report_exists: false
      )
    end
    assert_match "--testmon-report", error.message
  end

  def test_plain_help_oracle_detects_one_advertised_testmon_flag
    status = Struct.new(:exitstatus).new(0)
    result = MinitestTestmonAcceptance::CommandResult.new(
      argv: [],
      status:,
      stdout: "rails test help --testmon",
      stderr: ""
    )

    error = assert_raises(MinitestTestmonAcceptance::RailsCliOracle::Mismatch) do
      MinitestTestmonAcceptance::RailsCliOracle.assert_plain_help!(
        result,
        state_files: [],
        report_exists: false
      )
    end
    assert_match "advertised --testmon", error.message
  end

  def test_native_partial_oracle_rejects_a_zero_exit
    status = Struct.new(:exitstatus).new(0)
    result = MinitestTestmonAcceptance::CommandResult.new(
      argv: [],
      status:,
      stdout: "",
      stderr: ""
    )
    marker = Struct.new(:exist?).new(false)

    error = assert_raises(MinitestTestmonAcceptance::RailsCliOracle::Mismatch) do
      MinitestTestmonAcceptance::RailsCliOracle.assert_native_partial_rejection!(
        result,
        marker:,
        state_files: [],
        report_exists: false
      )
    end
    assert_match "exited 0", error.message
  end

  def test_cold_oracle_detects_partial_execution
    report = {
      "ready" => true,
      "generation" => 1,
      "publication" => {"published" => true},
      "tests" => {
        "discovered" => %w[one two],
        "selected" => %w[one two],
        "executed" => ["one"]
      }
    }

    assert_raises(MinitestTestmonAcceptance::RailsCliOracle::Mismatch) do
      MinitestTestmonAcceptance::RailsCliOracle.assert_full_cold!(report)
    end
  end

  def test_warm_oracle_detects_generation_drift
    cold = {"generation" => 1, "tests" => {"discovered" => ["one"]}}
    warm = {
      "generation" => 2,
      "tests" => {"discovered" => ["one"], "selected" => [], "executed" => []}
    }

    error = assert_raises(MinitestTestmonAcceptance::RailsCliOracle::Mismatch) do
      MinitestTestmonAcceptance::RailsCliOracle.assert_warm!(cold, warm, selected: [])
    end
    assert_match "generation", error.message
  end

  def test_warm_oracle_detects_generation_advance_after_reversed_skip_outcomes
    skip_ids = %w[
      CliContractTest#test_permanent_skip_alpha
      CliContractTest#test_permanent_skip_omega
    ]
    outcome_order = skip_ids.reverse
    cold = {"generation" => 1, "tests" => {"discovered" => skip_ids}}
    warm = {
      "generation" => 2,
      "tests" => {
        "discovered" => skip_ids,
        "selected" => skip_ids,
        "executed" => skip_ids
      }
    }

    assert_equal skip_ids.reverse, outcome_order
    error = assert_raises(MinitestTestmonAcceptance::RailsCliOracle::Mismatch) do
      MinitestTestmonAcceptance::RailsCliOracle.assert_warm!(cold, warm, selected: skip_ids)
    end
    assert_match "generation", error.message
  end

  def test_direct_cli_acceptance_source_compiles
    source = MinitestTestmonAcceptance::ROOT.join("rails_cli_acceptance_test.rb")

    assert RubyVM::InstructionSequence.compile_file(source.to_s)
  end
end

# frozen_string_literal: true

require_relative "test_helper"

class RailsHarnessSelfTest < Minitest::Test
  def test_bundle_oracle_detects_one_missing_bundle
    report = {"bundles" => MinitestTestmonAcceptance::RailsOracle::BUNDLES.drop(1)}

    error = assert_raises(MinitestTestmonAcceptance::RailsOracle::Mismatch) do
      MinitestTestmonAcceptance::RailsOracle.assert_auto_bundles!(report)
    end
    assert_match "rails.boot@1", error.message
  end

  def test_bundle_oracle_rejects_the_umbrella_as_a_provider
    report = {"bundles" => [*MinitestTestmonAcceptance::RailsOracle::BUNDLES, "rails_8_1"]}

    error = assert_raises(MinitestTestmonAcceptance::RailsOracle::Mismatch) do
      MinitestTestmonAcceptance::RailsOracle.assert_auto_bundles!(report)
    end
    assert_match "umbrella", error.message
  end

  def test_provider_claim_oracle_detects_a_missing_path
    report = {
      "inventory" => {
        "claimed" => {"items" => []},
        "suite_scoped" => {"items" => []},
        "verified_empty" => {"items" => []},
        "unresolved" => {"items" => []}
      }
    }

    error = assert_raises(MinitestTestmonAcceptance::RailsOracle::Mismatch) do
      MinitestTestmonAcceptance::RailsOracle.assert_provider_claim!(
        report,
        provider: "rails.views@1",
        path_suffix: "app/views/greetings/show.html.erb",
        facet: "content"
      )
    end
    assert_match "rails.views@1", error.message
  end

  def test_warm_oracle_detects_one_selected_test
    report = {"tests" => {"selected" => ["Example#test_one"], "executed" => ["Example#test_one"]}}

    assert_raises(MinitestTestmonAcceptance::RailsOracle::Mismatch) do
      MinitestTestmonAcceptance::RailsOracle.assert_warm_zero!(report)
    end
  end

  def test_worker_equivalence_oracle_detects_selection_drift
    reports = [1, 2].map do |worker|
      {
        "context_signature" => "same",
        "bundles" => MinitestTestmonAcceptance::RailsOracle::BUNDLES,
        "tests" => {"selected" => ["test-#{worker}"]},
        "inventory" => {"claimed" => worker}
      }
    end

    assert_raises(MinitestTestmonAcceptance::RailsOracle::Mismatch) do
      MinitestTestmonAcceptance::RailsOracle.assert_equivalent!(reports)
    end
  end

  def test_thread_rejection_oracle_detects_a_marker
    marker = Struct.new(:exist?).new(true)
    status = Struct.new(:success?).new(false)
    result = MinitestTestmonAcceptance::CommandResult.new(
      argv: [], status:, stdout: "", stderr: "Rails process parallelization required"
    )
    report = {"publication" => {"published" => false, "reason" => "unsupported_parallelism"}}

    error = assert_raises(MinitestTestmonAcceptance::RailsOracle::Mismatch) do
      MinitestTestmonAcceptance::RailsOracle.assert_rejected_before_marker!(result:, report:, marker:)
    end
    assert_match "marker", error.message
  end

  def test_rails_fixture_forces_native_parallel_workers_and_lets_rails_suffix_databases
    fixture = MinitestTestmonAcceptance::FIXTURES.join("rails_app")
    helper = fixture.join("test/test_helper.rb").read
    database = fixture.join("config/database.yml").read

    assert_includes helper, "with: parallel_mode, threshold: 0"
    assert_includes database, "ENV.fetch(\"RAILS_ACCEPTANCE_DATABASE\")"
    refute_includes database, "TEST_ENV_NUMBER"
  end

  def test_rails_runtime_disables_libpq_gss_only_in_its_child_environment
    global_database = ENV["RAILS_ACCEPTANCE_DATABASE"]
    project = MinitestTestmonAcceptance::Project.copy_fixture("rails_app")
    runtime = MinitestTestmonAcceptance::RailsRuntime.new(project, workers: 4)

    assert_equal "disable", runtime.env.fetch("PGGSSENCMODE")
    assert ENV["RAILS_ACCEPTANCE_DATABASE"] == global_database,
      "runtime leaked fixture database settings globally"
  ensure
    project&.cleanup
  end

  def test_rails_runtime_exports_a_stable_playwright_cli_path_for_copied_fixtures
    project = MinitestTestmonAcceptance::Project.copy_fixture("rails_app")
    runtime = MinitestTestmonAcceptance::RailsRuntime.new(project, workers: 1)

    assert_equal(
      MinitestTestmonAcceptance::PLAYWRIGHT_CLI_EXECUTABLE,
      runtime.env.fetch("PLAYWRIGHT_CLI_EXECUTABLE_PATH")
    )
    assert_predicate MinitestTestmonAcceptance::PLAYWRIGHT_CLI, :absolute?
    assert_predicate Pathname(Bundlebun::Runner.binary_path), :absolute?
  ensure
    project&.cleanup
  end

  def test_locked_playwright_core_version_matches_the_ruby_client
    require "playwright"
    package = JSON.parse(MinitestTestmonAcceptance::REPOSITORY_ROOT.join("package.json").read)
    compatible_version = Playwright::COMPATIBLE_PLAYWRIGHT_VERSION

    assert_equal compatible_version, package.dig("devDependencies", "playwright-core")
  end

  def test_rails_acceptance_source_compiles_on_the_supported_ruby
    source = MinitestTestmonAcceptance::ROOT.join("rails_acceptance_test.rb")

    assert RubyVM::InstructionSequence.compile_file(source.to_s)
  end

  def test_project_command_uses_stock_rails_and_fixture_contains_every_test_file
    project = MinitestTestmonAcceptance::Project.copy_fixture("rails_app")
    command = project.test_command
    expected_files = Dir[project.path.join("test/**/*_test.rb")].sort.map do |file|
      Pathname(file).relative_path_from(project.path).to_s
    end

    assert_equal [project.path.join("bin/rails").to_s, "test"], command
    assert expected_files.any? { |file| file.end_with?("test/high_volume_spool_test.rb") },
      "Rails full-suite ledger omitted HighVolumeSpoolTest"
  ensure
    project&.cleanup
  end

  def test_rails_project_command_uses_the_installed_stock_launcher
    project = MinitestTestmonAcceptance::Project.copy_fixture("rails_app")
    cli = MinitestTestmonAcceptance::RailsCliDriver.new(project)

    assert_equal [cli.rails_bin, "test"], project.test_command
  ensure
    project&.cleanup
  end
end

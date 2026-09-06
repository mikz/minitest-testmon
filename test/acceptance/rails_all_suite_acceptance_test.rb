# frozen_string_literal: true

require_relative "rails_cli_test_helper"

# bin/rails test:all is the complete suite including test/system; it runs as
# one Minitest execution whose only difference from bin/rails test is the
# test/**/*_test.rb file list. These tests cover its activation, the assets
# provider, and per-test attribution of system-test inputs. Both command shapes
# share one store safely because each test owns its literal input snapshot;
# running the default suite never rewrites snapshots belonging to system tests.
class RailsAllSuiteAcceptanceTest < Minitest::Test
  include RailsCliProductAcceptance

  DASHBOARD_TEST = "DashboardSystemTest#test_dashboard_lists_tracked_widgets"
  GREETING_SYSTEM_TEST = "DashboardSystemTest#test_greeting_page_renders_for_visitors"

  def test_real_browser_all_suite_publishes_warms_and_selects_changed_view
    assert_real_browser_suite(workers: 1)
  end

  def test_process_parallel_real_browser_all_suite_publishes_warms_and_selects_changed_view
    assert_real_browser_suite(workers: 2)
  end

  def assert_real_browser_suite(workers:)
    with_rails_cli_project(workers:) do |project, runtime, cli|
      replace_cli_fixture(project, "test/system/dashboard_system_test.rb",
        "greeting page renders for visitors", "Potkáme greeting page renders for visitors")
      browser_env = {"RAILS_ACCEPTANCE_BROWSER" => "1"}
      cold, cold_report = run_cli(runtime, cli, command: "test:all", extra_env: browser_env, timeout: 90)

      assert_equal 0, cold.exitstatus, cli_failure("browser cold test:all", cold)
      assert_equal [], cold_report.fetch("diagnostics"), cli_failure("browser diagnostics", cold)
      assert_cli_oracle { MinitestTestmonAcceptance::RailsCliOracle.assert_full_cold!(cold_report) }
      assert_includes cold_report.dig("tests", "executed"), DASHBOARD_TEST
      assert_includes cold_report.dig("tests", "executed"), "DashboardSystemTest#test_Potkáme_greeting_page_renders_for_visitors"

      warm, warm_report = run_cli(runtime, cli, command: "test:all", extra_env: browser_env)
      assert_equal 0, warm.exitstatus, cli_failure("browser warm test:all", warm)
      assert_cli_oracle { MinitestTestmonAcceptance::RailsCliOracle.assert_warm!(cold_report, warm_report, selected: []) }

      replace_cli_fixture(project, "app/views/greetings/dashboard.html.erb", "Dashboard</h1>", "Dashboard v2</h1>")
      changed, changed_report = run_cli(runtime, cli, command: "test:all", extra_env: browser_env)
      assert_equal 0, changed.exitstatus, cli_failure("browser changed view", changed)
      assert_equal [DASHBOARD_TEST], changed_report.dig("tests", "selected")
      assert_equal [DASHBOARD_TEST], changed_report.dig("tests", "executed")
      assert_equal true, changed_report.dig("publication", "published")
    end
  end

  def test_all_suite_learns_publishes_and_certifies_including_system_tests
    with_rails_cli_project do |_project, runtime, cli|
      cold, cold_report = run_cli(runtime, cli, command: "test:all")

      assert_equal 0, cold.exitstatus, cli_failure("cold test:all", cold)
      assert_cli_oracle { MinitestTestmonAcceptance::RailsCliOracle.assert_full_cold!(cold_report) }
      assert_includes cold_report.dig("tests", "executed"), DASHBOARD_TEST
      assert_includes cold_report.dig("tests", "executed"), GREETING_SYSTEM_TEST
      assert_includes cold_report.fetch("bundles"), "rails.assets@1"
      assert_cli_oracle do
        MinitestTestmonAcceptance::RailsOracle.assert_provider_claim!(
          cold_report,
          provider: "rails.assets@1",
          path_suffix: "app/assets/stylesheets/dashboard.css",
          facet: "content"
        )
      end
      assert_equal [DASHBOARD_TEST], asset_claim_owners(cold_report, "dashboard.css")

      warm, warm_report = run_cli(runtime, cli, command: "test:all")
      assert_equal 0, warm.exitstatus, cli_failure("warm test:all", warm)
      assert_cli_oracle { MinitestTestmonAcceptance::RailsCliOracle.assert_warm!(cold_report, warm_report, selected: []) }
    end
  end

  def test_real_browser_configuration_cannot_assign_shared_helpers_to_its_first_test
    with_rails_cli_project do |project, runtime, cli|
      project.write("lib/puma_boot_input.rb", <<~RUBY)
        module PumaBootInput
          def self.value
            4
          end
        end
      RUBY
      project.write("config/puma.rb", <<~RUBY)
        require_relative "../lib/puma_boot_input"
        threads 0, PumaBootInput.value
      RUBY
      replace_cli_fixture(project, "test/system/dashboard_system_test.rb",
        "class DashboardSystemTest < ApplicationSystemTestCase", <<~RUBY.chomp)
          class DashboardSystemTest < ApplicationSystemTestCase
            setup do
              require Rails.root.join("lib/puma_boot_input")
              PumaBootInput.value
            end
        RUBY
      browser_env = {"RAILS_ACCEPTANCE_BROWSER" => "1"}
      result, report = run_cli(runtime, cli, command: "test:all", extra_env: browser_env)

      assert_equal 0, result.exitstatus, cli_failure("shared Puma configuration", result)
      assert_includes report.dig("tests", "executed"), DASHBOARD_TEST
      assert_includes report.dig("tests", "executed"), GREETING_SYSTEM_TEST
      assert_equal false, report.dig("publication", "published")
      assert_includes report.fetch("diagnostics"), "ambiguous_context"

      replace_cli_fixture(project, "lib/puma_boot_input.rb", "    4", "    3")
      changed, changed_report = run_cli(runtime, cli, command: "test:all", extra_env: browser_env)
      assert_equal 0, changed.exitstatus, cli_failure("changed shared Puma configuration", changed)
      assert_includes changed_report.dig("tests", "executed"), DASHBOARD_TEST
      assert_includes changed_report.dig("tests", "executed"), GREETING_SYSTEM_TEST
      assert_equal false, changed_report.dig("publication", "published")
      assert_includes changed_report.fetch("diagnostics"), "ambiguous_context"
    end
  end

  def test_asset_edit_selects_exactly_its_consuming_system_test
    with_rails_cli_project do |project, runtime, cli|
      _, cold_report = run_cli(runtime, cli, command: "test:all")
      assert_cli_oracle { MinitestTestmonAcceptance::RailsCliOracle.assert_full_cold!(cold_report) }

      replace_cli_fixture(
        project,
        "app/assets/stylesheets/dashboard.css",
        "#113355",
        "#224466"
      )
      changed, changed_report = run_cli(runtime, cli, command: "test:all")

      assert_equal 0, changed.exitstatus, cli_failure("test:all after asset edit", changed)
      assert_equal [DASHBOARD_TEST], changed_report.dig("tests", "selected")
      assert_equal [DASHBOARD_TEST], changed_report.dig("tests", "executed")
      assert_equal true, changed_report.dig("publication", "published")
    end
  end

  def test_system_only_view_edit_selects_its_rendering_system_test
    with_rails_cli_project do |project, runtime, cli|
      _, cold_report = run_cli(runtime, cli, command: "test:all")
      assert_cli_oracle { MinitestTestmonAcceptance::RailsCliOracle.assert_full_cold!(cold_report) }

      replace_cli_fixture(
        project,
        "app/views/greetings/dashboard.html.erb",
        "Dashboard</h1>",
        "Dashboard v2</h1>"
      )
      changed, changed_report = run_cli(runtime, cli, command: "test:all")

      assert_equal 0, changed.exitstatus, cli_failure("test:all after view edit", changed)
      assert_equal [DASHBOARD_TEST], changed_report.dig("tests", "selected")
      assert_equal true, changed_report.dig("publication", "published")
    end
  end

  def test_partial_test_tasks_remain_rejected
    with_rails_cli_project do |project, runtime, cli|
      marker = project.path.join("tmp/partial-task-marker")
      result = cli.flagged(
        env: runtime.env.merge("RAILS_ACCEPTANCE_TEST_MARKER" => marker.to_s),
        command: "test:models"
      )

      assert_equal 2, result.exitstatus, cli_failure("test:models rejection", result)
      assert_match(/remove test paths/, result.stderr)
      refute marker.exist?, "rejected test:models executed a test body"
    end
  end

  def test_wrapper_supports_the_all_suite_command_and_rejects_partial_shapes
    with_rails_cli_project do |_project, runtime, cli|
      result = cli.wrapped(env: runtime.env, command: "test:all")
      assert_equal 0, result.exitstatus, cli_failure("wrapped test:all", result)
      report = cli.report
      assert_report_contract report
      assert_cli_oracle { MinitestTestmonAcceptance::RailsCliOracle.assert_full_cold!(report) }
      assert_includes report.dig("tests", "executed"), DASHBOARD_TEST

      rejected = cli.wrapped(env: runtime.env, command: "test:system")
      assert_equal 2, rejected.exitstatus, cli_failure("wrapped test:system rejection", rejected)
      assert_match(/bin\/rails test or bin\/rails test:all/, rejected.stderr)
    end
  end

  def test_rejected_system_task_cannot_disturb_the_default_suite_baseline
    with_rails_cli_project do |project, runtime, cli|
      cold, cold_report = run_cli(runtime, cli)
      assert_equal 0, cold.exitstatus, cli_failure("default-suite baseline", cold)
      assert_cli_oracle { MinitestTestmonAcceptance::RailsCliOracle.assert_full_cold!(cold_report) }
      baseline_state = cli.snapshot
      marker = project.path.join("tmp/rejected-system-task-marker")

      rejected = cli.wrapped(
        env: runtime.env.merge("RAILS_ACCEPTANCE_TEST_MARKER" => marker.to_s),
        command: "test:system"
      )

      assert_equal 2, rejected.exitstatus, cli_failure("wrapped test:system rejection", rejected)
      assert_match(/bin\/rails test or bin\/rails test:all/, rejected.stderr)
      refute marker.exist?, "rejected test:system executed a test body"
      assert_equal baseline_state, cli.snapshot, "rejected test:system mutated Testmon state"

      warm, warm_report = run_cli(runtime, cli)
      assert_equal 0, warm.exitstatus, cli_failure("default-suite warm after rejection", warm)
      assert_empty warm_report.dig("tests", "selected")
      assert_empty warm_report.dig("tests", "executed")
      assert_equal cold_report.fetch("generation"), warm_report.fetch("generation")
      assert_equal(
        inventory_fingerprints(cold_report.fetch("inventory")),
        inventory_fingerprints(warm_report.fetch("inventory"))
      )
    end
  end

  def test_process_parallel_workers_run_the_all_suite
    with_rails_cli_project(workers: 2) do |project, runtime, cli|
      cold, cold_report = run_cli(runtime, cli, command: "test:all", timeout: 90)

      assert_equal 0, cold.exitstatus, cli_failure("parallel cold test:all", cold)
      assert_cli_oracle { MinitestTestmonAcceptance::RailsCliOracle.assert_full_cold!(cold_report) }
      assert_includes cold_report.dig("tests", "executed"), DASHBOARD_TEST
      assert_equal [DASHBOARD_TEST], asset_claim_owners(cold_report, "dashboard.css")
      assert_no_worker_spools project

      warm, warm_report = run_cli(runtime, cli, command: "test:all", timeout: 90)
      assert_equal 0, warm.exitstatus, cli_failure("parallel warm test:all", warm)
      assert_cli_oracle { MinitestTestmonAcceptance::RailsCliOracle.assert_warm!(cold_report, warm_report, selected: []) }
    end
  end

  private

  def asset_claim_owners(report, path_suffix)
    items = report.dig("inventory", "claimed", "items")
    items
      .select { |item| item.fetch("provider") == "rails.assets@1" && item.fetch("facet") == "content" }
      .select { |item| item.fetch("path").end_with?(path_suffix) }
      .flat_map { |item| item.fetch("test_ids") }
      .uniq
      .sort
  end
end

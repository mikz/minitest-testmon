# frozen_string_literal: true

require_relative "rails_cli_test_helper"

class RailsCliAcceptanceTest < Minitest::Test
  include RailsCliProductAcceptance

  def test_canonical_flagged_help_advertises_flags_without_creating_state
    with_rails_cli_project do |_project, runtime, cli|
      result = cli.flagged(env: runtime.env, arguments: ["--help"])

      assert_cli_oracle do
        MinitestTestmonAcceptance::RailsCliOracle.assert_help!(
          result,
          state_files: cli.state_files,
          report_exists: false
        )
      end
    end
  end

  def test_plain_help_cannot_advertise_testmon_and_is_inert
    with_rails_cli_project do |_project, runtime, cli|
      result = cli.plain(env: runtime.env, arguments: ["--help"])

      assert_cli_oracle do
        MinitestTestmonAcceptance::RailsCliOracle.assert_plain_help!(
          result,
          state_files: cli.state_files,
          report_exists: false
        )
      end
    end
  end

  def test_plain_rails_command_is_inert
    with_rails_cli_project do |project, runtime, cli|
      marker = project.path.join("tmp/plain-marker")
      features = project.path.join("tmp/plain-features.json")
      result = cli.plain(
        env: runtime.env.merge(
          "MINITEST_TESTMON_DB" => cli.state_path.to_s,
          "RAILS_ACCEPTANCE_TEST_MARKER" => marker.to_s,
          "RAILS_ACCEPTANCE_LOADED_FEATURES" => features.to_s
        )
      )

      assert_cli_oracle do
        MinitestTestmonAcceptance::RailsCliOracle.assert_inert!(
          result,
          state_files: cli.state_files,
          report_exists: false
        )
      end
      refute_empty marker_test_ids(marker), "plain Rails command did not execute its suite"
      loaded_testmon = JSON.parse(features.read)
      assert loaded_testmon.any? { |path| path.end_with?("/minitest-testmon.rb") },
        "Bundler.require did not conventionally autorequire the gem entrypoint"
      active_testmon = loaded_testmon.reject do |path|
        [
          "/minitest-testmon.rb",
          "/minitest/testmon/environment.rb",
          "/minitest/testmon/rails_bootstrap.rb",
          "/minitest/testmon/railtie.rb",
          "/minitest/testmon/version.rb"
        ].any? { |suffix| path.end_with?(suffix) }
      end
      assert_empty active_testmon, "plain Rails command loaded active Testmon code"
    end
  end

  def test_truthy_environment_value_activates_plain_rails_command
    with_rails_cli_project do |_project, runtime, cli|
      result = cli.plain(
        env: runtime.env.merge(
          "MINITEST_TESTMON" => "yes",
          "MINITEST_TESTMON_DB" => cli.state_path.to_s
        )
      )

      assert_equal 0, result.exitstatus, cli_failure("environment-activated Rails command", result)
      report = cli.report
      assert_report_contract report
      assert_cli_oracle { MinitestTestmonAcceptance::RailsCliOracle.assert_full_cold!(report) }
    end
  end

  def test_plain_database_environment_does_not_mutate_existing_state
    with_rails_cli_project do |project, runtime, cli|
      learn_cli_baseline(project, runtime, cli)
      baseline = cli.snapshot
      marker = project.path.join("tmp/plain-existing-state-marker")

      result = cli.plain(
        env: runtime.env.merge(
          "MINITEST_TESTMON_DB" => cli.state_path.to_s,
          "RAILS_ACCEPTANCE_TEST_MARKER" => marker.to_s
        )
      )

      assert_equal 0, result.exitstatus, cli_failure("plain command with Testmon paths", result)
      assert_equal baseline, cli.snapshot, "plain command changed existing Testmon state"
      refute_empty marker_test_ids(marker), "plain command did not execute its suite"
    end
  end

  def test_attached_database_option_overrides_environment_path
    with_rails_cli_project do |project, runtime, cli|
      env_database = project.path.join("tmp/rails-cli/env-trap.sqlite3")
      result = cli.flagged(
        env: runtime.env.merge("MINITEST_TESTMON_DB" => env_database.to_s),
        arguments: ["--testmon-db=#{cli.state_path}"]
      )

      assert_equal 0, result.exitstatus, cli_failure("attached state/report options", result)
      report = cli.report
      assert_report_contract report
      assert_cli_oracle { MinitestTestmonAcceptance::RailsCliOracle.assert_full_cold!(report) }
      refute env_database.exist?, "environment database won over attached --testmon-db=PATH"
      assert_no_worker_spools project
      assert_equal 0, cli.lease_count
    end
  end

  def test_wrapper_discover_and_run_activate_the_stock_rails_command_from_environment
    with_rails_cli_project do |_project, runtime, cli|
      discovered = cli.wrapped(env: runtime.env, full: true)
      assert_equal 0, discovered.exitstatus, cli_failure("wrapped Rails discovery", discovered)
      cold = cli.report
      assert_report_contract cold
      assert_cli_oracle { MinitestTestmonAcceptance::RailsCliOracle.assert_full_cold!(cold) }
      app_body_claims = cold.dig("inventory", "suite_scoped", "items").select do |item|
        item.fetch("provider") == "rails_custom_inputs@1" &&
          item.fetch("path", "").end_with?("custom_inputs/application.yml")
      end
      assert_equal 1, app_body_claims.length,
        "wrapper preloaded observers before the custom target was available"

      run = cli.wrapped(env: runtime.env)
      assert_equal 0, run.exitstatus, cli_failure("wrapped Rails warm run", run)
      warm = cli.report
      assert_report_contract warm
      assert_cli_oracle do
        MinitestTestmonAcceptance::RailsCliOracle.assert_warm!(cold, warm, selected: [])
      end
    end
  end

  def test_wrapper_from_outside_app_resolves_app_root_configuration_and_default_state
    outside = Pathname(Dir.mktmpdir("minitest-testmon-outside-rails-"))
    with_rails_cli_project do |project, runtime, cli|
      default_database = project.path.join(".minitest-testmon.sqlite3")

      discovered = cli.wrapped(
        env: runtime.env,
        full: true,
        explicit_paths: false,
        chdir: outside
      )
      assert_equal 0, discovered.exitstatus, cli_failure("outside-cwd wrapped discovery", discovered)
      cold = MinitestTestmonAcceptance::Driver.new.report(project)
      assert_report_contract cold
      assert_cli_oracle { MinitestTestmonAcceptance::RailsCliOracle.assert_full_cold!(cold) }
      assert default_database.file?, "wrapper created no default database under the Rails app root"
      assert_includes cold.fetch("bundles"), "rails_custom_inputs@1"
      app_body_claims = cold.dig("inventory", "suite_scoped", "items").select do |item|
        item.fetch("provider") == "rails_custom_inputs@1" &&
          item.fetch("path", "").end_with?("custom_inputs/application.yml")
      end
      assert_equal 1, app_body_claims.length,
        "outside-cwd wrapper missed the first Application class-body observation"
      refute outside.join(".minitest-testmon.sqlite3").exist?,
        "wrapper rooted default state in the caller directory"
      refute outside.join("tmp/minitest-testmon/discovery.json").exist?,
        "wrapper rooted the default report in the caller directory"

      run = cli.wrapped(env: runtime.env, explicit_paths: false, chdir: outside)
      assert_equal 0, run.exitstatus, cli_failure("outside-cwd wrapped warm run", run)
      warm = MinitestTestmonAcceptance::Driver.new.report(project)
      assert_report_contract warm
      assert_cli_oracle do
        MinitestTestmonAcceptance::RailsCliOracle.assert_warm!(cold, warm, selected: [])
      end
    end
  ensure
    FileUtils.remove_entry(outside) if outside&.exist?
  end

  def test_wrapper_rejects_default_test_filters_without_publication_or_state_changes
    with_rails_cli_project do |project, runtime, cli|
      discovered = cli.wrapped(env: runtime.env, full: true)
      assert_equal 0, discovered.exitstatus, cli_failure("wrapper filter baseline", discovered)
      baseline_report = cli.report
      assert_report_contract baseline_report
      assert_cli_oracle do
        MinitestTestmonAcceptance::RailsCliOracle.assert_full_cold!(baseline_report)
      end
      baseline_state = cli.snapshot

      {
        "DEFAULT_TEST" => "test/unrelated_test.rb",
        "DEFAULT_TEST_EXCLUDE" => "test/unrelated_test.rb"
      }.each do |name, value|
        marker = project.path.join("tmp/wrapper-#{name.downcase}-marker")
        result = cli.wrapped(
          env: runtime.env.merge(
            name => value,
            "RAILS_ACCEPTANCE_TEST_MARKER" => marker.to_s
          )
        )

        refute_equal 0, result.exitstatus, cli_failure("wrapper #{name}", result)
        refute marker.exist?, "wrapper #{name} reached a test body"
        assert_equal baseline_state, cli.snapshot,
          "wrapper #{name} changed the last published database/report"
        assert_no_worker_spools project
        assert_equal 0, cli.lease_count
      rescue Minitest::Assertion => error
        flunk "#{name}: #{error.message}"
      end
    end
  end

  def test_full_suite_cold_and_warm_auto_load_default_config_and_custom_provider
    with_rails_cli_project do |project, runtime, cli|
      cold = learn_cli_baseline(project, runtime, cli)
      assert_includes cold.fetch("bundles"), "rails_custom_inputs@1"
      assert MinitestTestmonAcceptance::RailsOracle.assert_provider_claim!(
        cold,
        provider: "rails_custom_inputs@1",
        path_suffix: "config/policies/rules.yml",
        facet: "content"
      )
      app_body_claims = cold.dig("inventory", "suite_scoped", "items").select do |item|
        item.fetch("provider") == "rails_custom_inputs@1" &&
          item.fetch("path", "").end_with?("custom_inputs/application.yml")
      end
      assert_equal 1, app_body_claims.length,
        "custom configuration did not observe the first Application class-body statement"

      result, warm = run_cli(runtime, cli)
      assert_equal 0, result.exitstatus, cli_failure("Rails CLI warm run", result)
      assert_cli_oracle do
        MinitestTestmonAcceptance::RailsCliOracle.assert_warm!(cold, warm, selected: [])
      end
      assert_certified_inventory cold, warm, cli
      assert_equal true, warm.fetch("ready")
      assert_equal true, warm.dig("publication", "published")
    end
  end

  def test_rails_providers_resolve_paths_registered_after_application_initialization
    with_rails_cli_project do |project, runtime, cli|
      cold = learn_cli_baseline(project, runtime, cli)
      {
        "rails.views@1" => "runtime_views/greetings/runtime.html.erb",
        "rails.locales@1" => "runtime_locales/en.yml",
        "rails.fixtures@2" => "test/manual_fixtures/manual_widgets.yml"
      }.each do |provider, path|
        assert MinitestTestmonAcceptance::RailsOracle.assert_provider_claim!(
          cold,
          provider:,
          path_suffix: path,
          facet: "content"
        )
      end

      replace_cli_fixture(
        project,
        "runtime_views/greetings/runtime.html.erb",
        "runtime template v1",
        "runtime template v2"
      )
      replace_cli_fixture(
        project,
        "runtime_locales/en.yml",
        "runtime locale v1",
        "runtime locale v2"
      )
      replace_cli_fixture(
        project,
        "test/manual_fixtures/manual_widgets.yml",
        "widget v1",
        "widget v2"
      )

      result, changed = run_cli(
        runtime,
        cli,
        extra_env: {
          "EXPECTED_RUNTIME_TEMPLATE" => "Hello from runtime template v2",
          "EXPECTED_RUNTIME_LOCALE" => "Hello from runtime locale v2",
          "EXPECTED_MANUAL_FIXTURE" => "Manual fixture widget v2"
        }
      )
      assert_equal 0, result.exitstatus, cli_failure("post-init Rails paths", result)
      expected = [
        find_test_id(changed, "GreetingsControllerTest#test_show"),
        find_test_id(changed, "LocaleTest#test_locale"),
        find_test_id(changed, "ManualFixtureTest#test_manual_fixture_load")
      ].sort
      assert_equal expected, changed.dig("tests", "selected")
      assert_equal expected, changed.dig("tests", "executed")
    end
  end

  def test_focused_paths_and_names_publish_without_claiming_omitted_tests
    with_rails_cli_project do |_project, runtime, cli|
      id = "WidgetTest#test_declared_fixture"
      env = runtime.env.merge("MINITEST_TESTMON" => "1", "MINITEST_TESTMON_DB" => cli.state_path.to_s)
      cold = cli.plain(env:, arguments: ["test/models/widget_test.rb"])
      report = cli.report if cli.state_path.file?
      assert cold.success?, cli_failure("focused path", cold)
      assert_equal [id], report.dig("tests", "discovered")
      assert_equal [id], report.dig("tests", "executed")
      assert report.dig("publication", "published")
      warm = cli.plain(env:, arguments: ["--name", "test_declared_fixture"])
      report = cli.report if cli.state_path.file?
      assert warm.success?, cli_failure("focused name", warm)
      assert_equal [id], report.dig("tests", "discovered")
      assert_empty report.dig("tests", "selected")
      remaining, report = run_cli(runtime, cli)
      assert remaining.success?, cli_failure("remaining suite", remaining)
      refute_includes report.dig("tests", "selected"), id
      assert_operator report.dig("tests", "selected").length, :>, 1
      assert report.dig("publication", "published")
    end
  end

  def test_focused_reporter_runs_finalize_and_reuse_cache
    [1, 2].each do |workers|
      with_rails_cli_project(workers:) do |_project, runtime, cli|
        env = runtime.env.merge(
          "MINITEST_TESTMON" => "1", "MINITEST_TESTMON_DB" => cli.state_path.to_s,
          "RAILS_ACCEPTANCE_REPORTERS" => "1"
        )
        cold = cli.plain(env:, arguments: ["test/models/widget_test.rb"])
        assert cold.success?, cli_failure("focused reporter run", cold)
        report = cli.report
        assert report.dig("publication", "published"), "focused reporter did not finalize its receipt"
        assert_equal ["WidgetTest#test_declared_fixture"], report.dig("tests", "executed")
        warm = cli.plain(env:, arguments: ["test/models/widget_test.rb"])
        assert warm.success?, cli_failure("focused reporter warm run", warm)
        report = cli.report
        assert report.dig("publication", "published")
        assert_empty report.dig("tests", "selected")
      end
    end
  end

  def test_line_filters_do_not_readd_cached_tests
    with_rails_cli_project do |project, runtime, cli|
      path = "test/models/line_filter_test.rb"
      source = <<~RUBY
        require "test_helper"
        class LineFilterTest < ActiveSupport::TestCase
          test "first case" do
            assert_equal 2, 1 + 1
          end
          test "second case" do
            assert_equal 4, 2 + 2
          end
        end
      RUBY
      project.write(path, source)
      env = runtime.env.merge("MINITEST_TESTMON" => "1", "MINITEST_TESTMON_DB" => cli.state_path.to_s)
      first = source.lines.find_index { |line| line.include?("first case") } + 1
      last = source.lines.find_index { |line| line.include?("second case") } + 1
      cold = cli.plain(env:, arguments: ["#{path}:#{first}"])
      assert cold.success?, cli_failure("single line", cold)
      assert_equal ["LineFilterTest#test_first_case"], cli.report.dig("tests", "executed")
      partial = cli.plain(env:, arguments: ["#{path}:#{first}-#{last}"])
      assert partial.success?, cli_failure("line range with cached test", partial)
      assert_equal ["LineFilterTest#test_second_case"], cli.report.dig("tests", "selected")
      assert_equal ["LineFilterTest#test_second_case"], cli.report.dig("tests", "executed")
      assert cli.report.dig("publication", "published")
      warm = cli.plain(env:, arguments: [path, "--name", "first case"])
      assert warm.success?, cli_failure("declarative name", warm)
      assert_equal ["LineFilterTest#test_first_case"], cli.report.dig("tests", "discovered")
      assert_empty cli.report.dig("tests", "selected")
    end
  end

  def test_database_prepare_followed_by_system_task_publishes_and_warms
    with_rails_cli_project do |_project, runtime, cli|
      env = runtime.env.merge("MINITEST_TESTMON" => "1", "MINITEST_TESTMON_DB" => cli.state_path.to_s)
      cold = cli.plain(env:, command: "db:test:prepare", arguments: ["test:system"])
      assert cold.success?, cli_failure("prepare and system task", cold)
      report = cli.report
      assert report.dig("publication", "published")
      ids = report.dig("tests", "selected")
      assert_equal 2, ids.length
      assert ids.all? { |id| id.start_with?("DashboardSystemTest#") }
      warm = cli.plain(env:, command: "db:test:prepare", arguments: ["test:system"])
      assert warm.success?, cli_failure("warm system task", warm)
      assert_empty cli.report.dig("tests", "selected")
      remaining, report = run_cli(runtime, cli, command: "test:all")
      assert remaining.success?, cli_failure("remaining all suite", remaining)
      assert_empty ids & report.dig("tests", "selected")
      assert report.dig("publication", "published")
    end
  end

  def test_invalid_or_auxiliary_testmon_options_reject_before_tests_or_state
    with_rails_cli_project do |project, runtime, cli|
      cases = {
        "database without activation" => "--testmon-db=#{cli.state_path}",
        "value-bearing activation" => "--testmon=value"
      }

      cases.each do |label, argument|
        marker = project.path.join("tmp/invalid-option-#{label.tr(" ", "-")}-marker")
        result = cli.plain(
          env: runtime.env.merge("RAILS_ACCEPTANCE_TEST_MARKER" => marker.to_s),
          arguments: [argument]
        )

        assert_equal 2, result.exitstatus, cli_failure(label, result)
        refute marker.exist?, "#{label} reached a test body"
        assert_empty cli.state_files, "#{label} created Testmon state"
        assert_no_worker_spools project
      rescue Minitest::Assertion => error
        flunk "#{label}: #{error.message}"
      end
    end
  end

  def test_malformed_default_configuration_exits_two_before_creating_evidence
    with_rails_cli_project do |project, runtime, cli|
      cases = {
        "SyntaxError" => "Minitest::Testmon.configure do |config|\n",
        "NameError" => "MissingAcceptanceConfigurationConstant\n"
      }

      cases.each do |error_class, source|
        project.write(".minitest-testmon.rb", source)
        marker = project.path.join("tmp/config-#{error_class.downcase}-marker")
        result = cli.flagged(
          env: runtime.env.merge("RAILS_ACCEPTANCE_TEST_MARKER" => marker.to_s)
        )

        assert_configuration_rejected_before_evidence(
          result,
          error_class:,
          project:,
          cli:,
          marker:
        )
      rescue Minitest::Assertion => error
        flunk "#{error_class}: #{error.message}"
      end
    end
  end

  def test_custom_configuration_cannot_replace_the_canonical_rails_project_root
    alternate_root = Pathname(Dir.mktmpdir("minitest-testmon-alternate-root-"))
    with_rails_cli_project do |project, runtime, cli|
      project.write(".minitest-testmon.rb", <<~RUBY)
        # frozen_string_literal: true

        require "minitest/testmon"

        Minitest::Testmon.configure do |config|
          config.root :project, ENV.fetch("RAILS_ACCEPTANCE_ALTERNATE_ROOT")
        end
      RUBY

      [
        ["direct", ->(env) { cli.flagged(env:) }],
        ["wrapper", ->(env) { cli.wrapped(env:, full: true) }]
      ].each do |label, invoke|
        marker = project.path.join("tmp/#{label}-root-replacement-marker")
        env = runtime.env.merge(
          "RAILS_ACCEPTANCE_ALTERNATE_ROOT" => alternate_root.to_s,
          "RAILS_ACCEPTANCE_TEST_MARKER" => marker.to_s
        )
        result = invoke.call(env)

        refute_equal 0, result.exitstatus, cli_failure("#{label} root replacement", result)
        refute marker.exist?, "#{label} root replacement reached a test body"
        assert_empty cli.state_files, "#{label} root replacement created direct state"
        refute project.path.join(".minitest-testmon.sqlite3").exist?,
          "#{label} root replacement created default app state"
        refute project.path.join("tmp/minitest-testmon/discovery.json").exist?,
          "#{label} root replacement created a default app report"
        refute alternate_root.join(".minitest-testmon.sqlite3").exist?,
          "#{label} root replacement created state under the alternate root"
        refute alternate_root.join("tmp/minitest-testmon/discovery.json").exist?,
          "#{label} root replacement created a report under the alternate root"
        assert_empty alternate_root.children,
          "#{label} root replacement created artifacts under the alternate root"
        assert_no_worker_spools project
      rescue Minitest::Assertion => error
        flunk "#{label}: #{error.message}"
      end
    end
  ensure
    FileUtils.remove_entry(alternate_root) if alternate_root&.exist?
  end

  def test_thor_test_subcommand_selects_only_its_requested_tests
    with_rails_cli_project do |_project, runtime, cli|
      result, report = run_cli(runtime, cli, command: "test:models")
      assert result.success?, cli_failure("test:models", result)
      assert report.dig("publication", "published")
      assert_equal ["ManualFixtureTest#test_manual_fixture_load", "WidgetTest#test_declared_fixture"], report.dig("tests", "selected")
    end
  end

  def test_explicit_test_prepare_with_testmon_never_runs_the_task_or_touches_state
    with_rails_cli_project do |project, runtime, cli|
      learn_cli_baseline(project, runtime, cli)
      baseline = cli.snapshot
      test_marker = project.path.join("tmp/explicit-test-prepare-test-marker")
      task_marker = project.path.join("tmp/explicit-test-prepare-task-marker")
      result = cli.flagged(
        env: runtime.env.merge(
          "RAILS_ACCEPTANCE_TEST_MARKER" => test_marker.to_s,
          "RAILS_ACCEPTANCE_TASK_MARKER" => task_marker.to_s
        ),
        command: "test:prepare"
      )

      refute_equal 0, result.exitstatus, cli_failure("explicit test:prepare", result)
      refute test_marker.exist?, "explicit test:prepare reached a test body"
      refute task_marker.exist?, "explicit test:prepare ran its Rake task body"
      assert_equal baseline, cli.snapshot, "explicit test:prepare changed Testmon state"
    end
  end

  def test_explicit_environment_options_reject_without_cross_environment_warm_selection
    with_rails_cli_project do |project, runtime, cli|
      learn_cli_baseline(project, runtime, cli)
      baseline = cli.snapshot
      cases = [
        ["long split before", %w[--environment alternate], []],
        ["long attached after", [], ["--environment=alternate"]],
        ["short split after", [], %w[-e alternate]],
        ["short attached before", ["-ealternate"], []]
      ]

      cases.each do |label, leading_arguments, arguments|
        marker = project.path.join("tmp/environment-#{label.tr(" ", "-")}-marker")
        result = cli.flagged(
          env: runtime.env.merge("RAILS_ACCEPTANCE_TEST_MARKER" => marker.to_s),
          leading_arguments:,
          arguments:
        )

        assert_cli_oracle do
          MinitestTestmonAcceptance::RailsCliOracle.assert_rejected_unchanged!(
            result,
            before: baseline,
            after: cli.snapshot,
            marker:,
            exitstatus: [1, 2]
          )
        end
      rescue Minitest::Assertion => error
        flunk "#{label}: #{error.message}"
      end
    end
  end

  def test_native_failure_exits_one_preserves_passing_checkpoints_and_releases_lease
    with_rails_cli_project do |project, runtime, cli|
      baseline = learn_cli_baseline(project, runtime, cli)
      project.write(
        "config/initializers/acceptance_boot.rb",
        "#{project.read("config/initializers/acceptance_boot.rb")}\n# CLI failure selection\n"
      )

      failed, rejected = run_cli(
        runtime,
        cli,
        extra_env: {"RAILS_ACCEPTANCE_FAIL_TEST" => "1"}
      )
      assert_equal 1, failed.exitstatus, cli_failure("native failure", failed)
      assert_equal false, rejected.dig("publication", "published")
      assert_equal "test_failure", rejected.dig("publication", "reason")
      assert_operator rejected.fetch("generation"), :>, baseline.fetch("generation")
      accepted = rejected.dig("checkpoints", "accepted_ids")
      refute_empty accepted
      refute_includes accepted, "CliContractTest#test_controlled_failure"

      recovered, recovery_report = run_cli(runtime, cli)
      assert_equal 0, recovered.exitstatus, cli_failure("failure recovery", recovered)
      assert_equal ["CliContractTest#test_controlled_failure"], recovery_report.dig("tests", "selected")
      assert_equal recovery_report.dig("tests", "selected"), recovery_report.dig("tests", "executed")
      assert_equal rejected.fetch("generation") + 1, recovery_report.fetch("generation")
    end
  end

  def test_unsupported_threads_exit_four_before_tests_and_release_lease
    with_rails_cli_project do |project, runtime, cli|
      baseline = learn_cli_baseline(project, runtime, cli)
      marker = project.path.join("tmp/thread-rejection-marker")
      rejected_result, rejected = run_cli(
        runtime,
        cli,
        extra_env: {
          "PARALLEL_WORKERS" => "2",
          "PARALLEL_MODE" => "threads",
          "RAILS_ACCEPTANCE_TEST_MARKER" => marker.to_s
        }
      )

      assert_equal 4, rejected_result.exitstatus, cli_failure("thread rejection", rejected_result)
      refute marker.exist?, "unsupported thread run reached a test body"
      assert_cli_oracle do
        MinitestTestmonAcceptance::RailsCliOracle.assert_retained_generation!(
          baseline,
          rejected,
          reason: "unsupported_parallelism"
        )
      end

      warm, warm_report = run_cli(runtime, cli)
      assert_equal 0, warm.exitstatus, cli_failure("post-thread warm run", warm)
      assert_cli_oracle do
        MinitestTestmonAcceptance::RailsCliOracle.assert_warm!(baseline, warm_report, selected: [])
      end
    end
  end

  def test_externally_interrupted_worker_does_not_publish_and_retries_its_dirty_test
    with_rails_cli_project(workers: 2) do |project, runtime, cli|
      baseline = learn_cli_baseline(project, runtime, cli)
      replace_cli_fixture(project, "app/views/greetings/_message.html.erb", "template v1", "template v2")

      interrupted, rejected = run_cli(
        runtime,
        cli,
        extra_env: {
          "EXPECTED_TEMPLATE" => "Hello from template v2",
          "RAILS_ACCEPTANCE_KILL_TEST" => "test_show"
        },
        timeout: 15
      )
      refute interrupted.success?, "worker-kill run unexpectedly passed"
      assert_equal baseline.fetch("generation"), rejected.fetch("generation")
      assert_equal baseline.fetch("inventory"), rejected.fetch("inventory")
      if rejected.dig("publication", "published") == false
        assert_equal "worker_incomplete", rejected.dig("publication", "reason")
      end

      recovered, recovery_report = run_cli(
        runtime,
        cli,
        extra_env: {"EXPECTED_TEMPLATE" => "Hello from template v2"}
      )
      assert_equal 0, recovered.exitstatus, cli_failure("worker recovery", recovered)
      assert_equal ["GreetingsControllerTest#test_show"], recovery_report.dig("tests", "selected")
      assert_equal ["GreetingsControllerTest#test_show"], recovery_report.dig("tests", "executed")
      assert_equal baseline.fetch("generation") + 1, recovery_report.fetch("generation")
    end
  end

  def test_lease_contention_exits_four_and_owner_releases_cleanly
    with_rails_cli_project do |project, runtime, cli|
      baseline = learn_cli_baseline(project, runtime, cli)
      project.write(
        "config/initializers/acceptance_boot.rb",
        "#{project.read("config/initializers/acceptance_boot.rb")}\n# lease owner selection\n"
      )
      barrier = project.path.join("tmp/lease-barrier")
      release = barrier.join("release")
      owner = cli.start_flagged(
        env: runtime.env.merge("RAILS_ACCEPTANCE_BARRIER" => barrier.to_s)
      )

      wait_for_cli("lease owner never reached a test body") do
        barrier.glob("worker-*").any?
      end
      marker = project.path.join("tmp/lease-contender-marker")
      contender, rejected = run_cli(
        runtime,
        cli,
        extra_env: {"RAILS_ACCEPTANCE_TEST_MARKER" => marker.to_s}
      )
      assert_equal 4, contender.exitstatus, cli_failure("lease contender", contender)
      refute marker.exist?, "lease contender reached a test body"
      assert_equal baseline, rejected,
        "lease contention should leave the last completed report untouched"

      release.dirname.mkpath
      release.write("release")
      owner_result = cli.finish(owner)
      owner = nil
      assert_equal 0, owner_result.exitstatus, cli_failure("lease owner", owner_result)

      warm, warm_report = run_cli(runtime, cli)
      assert_equal 0, warm.exitstatus, cli_failure("post-lease warm run", warm)
      assert_empty warm_report.dig("tests", "selected")
      assert_empty warm_report.dig("tests", "executed")
    ensure
      release&.dirname&.mkpath
      release&.write("release") if release && !release.exist?
      cli&.finish(owner, timeout: 2) if owner
    end
  end

  def test_workers_one_two_and_four_have_equivalent_cold_and_warm_evidence
    reports = [1, 2, 4].map do |workers|
      with_rails_cli_project(workers:) do |project, runtime, cli|
        cold = learn_cli_baseline(project, runtime, cli)
        warm, warm_report = run_cli(runtime, cli)
        assert_equal 0, warm.exitstatus, cli_failure("workers=#{workers} warm", warm)
        assert_cli_oracle do
          MinitestTestmonAcceptance::RailsCliOracle.assert_warm!(cold, warm_report, selected: [])
        end
        assert_no_worker_spools project
        assert_equal 0, cli.lease_count
        cold
      end
    end

    assert_cli_oracle do
      MinitestTestmonAcceptance::RailsCliOracle.assert_worker_equivalence!(reports)
    end
  end

  def test_repeated_flag_is_idempotent_with_reporters_and_simplecov
    with_rails_cli_project(workers: 2) do |project, runtime, cli|
      marker = project.path.join("tmp/reporter-marker")
      coverage = project.path.join("tmp/direct-simplecov")
      env = {
        "RAILS_ACCEPTANCE_REPORTERS" => "1",
        "SIMPLECOV_ORDER" => "after",
        "RAILS_ACCEPTANCE_COVERAGE_DIR" => coverage.to_s,
        "RAILS_ACCEPTANCE_TEST_MARKER" => marker.to_s
      }
      result = cli.flagged(env: runtime.env.merge(env), repeated: true)
      assert_equal 0, result.exitstatus, cli_failure("reporters/SimpleCov cold", result)
      cold = cli.report
      assert_report_contract cold
      assert_cli_oracle { MinitestTestmonAcceptance::RailsCliOracle.assert_full_cold!(cold) }
      assert_equal cold.dig("tests", "executed"), marker_test_ids(marker).uniq
      assert_equal marker_test_ids(marker).uniq, marker_test_ids(marker), "a test body ran more than once"
      assert_includes result.stdout, "CliContractTest"

      resultset = coverage.join(".resultset.json")
      assert resultset.file?, "direct Rails SimpleCov run did not write #{resultset}"
      refute_empty JSON.parse(resultset.read)

      warm_marker = project.path.join("tmp/reporter-warm-marker")
      warm_result, warm = run_cli(
        runtime,
        cli,
        extra_env: env.merge("RAILS_ACCEPTANCE_TEST_MARKER" => warm_marker.to_s),
        repeated: true
      )
      assert_equal 0, warm_result.exitstatus, cli_failure("reporters/SimpleCov warm", warm_result)
      assert_cli_oracle do
        MinitestTestmonAcceptance::RailsCliOracle.assert_warm!(cold, warm, selected: [])
      end
      refute warm_marker.exist?, "reporter-compatible warm run executed a test"
    end
  end

  def test_permanent_skip_publishes_cold_and_remains_the_only_warm_selection
    with_rails_cli_project(workers: 4) do |project, runtime, cli|
      cold_order = project.path.join("tmp/permanent-cold-order")
      env = {
        "RAILS_ACCEPTANCE_PERMANENT_SKIP" => "1",
        "RAILS_ACCEPTANCE_SKIP_ORDER_DIR" => cold_order.to_s,
        "RAILS_ACCEPTANCE_TEST_MARKER" => project.path.join("tmp/permanent-cold-marker").to_s
      }
      cold = learn_cli_baseline(project, runtime, cli, extra_env: env)
      skip_ids = cold.dig("tests", "discovered").grep(/CliContractTest#test_permanent_skip/)
      assert_equal 2, skip_ids.length
      assert_equal skip_ids.sort, skip_ids
      assert_equal 1, cold.fetch("generation")
      assert_equal skip_ids.reverse, cold_order.join("outcomes").readlines(chomp: true)
      assert_no_worker_spools project
      assert_equal 0, cli.lease_count

      warm_marker = project.path.join("tmp/permanent-warm-marker")
      warm_order = project.path.join("tmp/permanent-warm-order")
      warm_result, warm = run_cli(
        runtime,
        cli,
        extra_env: env.merge(
          "RAILS_ACCEPTANCE_SKIP_ORDER_DIR" => warm_order.to_s,
          "RAILS_ACCEPTANCE_TEST_MARKER" => warm_marker.to_s
        )
      )
      assert_equal 0, warm_result.exitstatus, cli_failure("permanent skip warm", warm_result)
      assert_cli_oracle do
        MinitestTestmonAcceptance::RailsCliOracle.assert_warm!(cold, warm, selected: skip_ids)
      end
      assert_equal skip_ids, warm.dig("tests", "selected")
      assert_equal skip_ids, warm.dig("tests", "executed")
      assert_equal skip_ids.reverse, warm_order.join("outcomes").readlines(chomp: true)
      assert_equal cold.fetch("context_signature"), warm.fetch("context_signature")
      assert_certified_inventory cold, warm, cli
      assert_equal true, warm.dig("publication", "published")
      assert_equal skip_ids, marker_test_ids(warm_marker)
      assert_no_worker_spools project
      assert_equal 0, cli.lease_count
    end
  end

  def test_newly_skipped_dependency_test_publishes_passing_tests_and_retries_the_skip
    with_rails_cli_project do |project, runtime, cli|
      baseline = learn_cli_baseline(project, runtime, cli)
      replace_cli_fixture(project, "config/policies/rules.yml", "mode: v1", "mode: v2")

      rejected_result, rejected = run_cli(
        runtime,
        cli,
        extra_env: {
          "EXPECTED_POLICY_MODE" => "v2",
          "RAILS_ACCEPTANCE_SKIP_POLICY_TEST" => "1"
        }
      )
      assert_equal 0, rejected_result.exitstatus, cli_failure("new skip run", rejected_result)
      assert_equal true, rejected.dig("publication", "published")
      assert_equal baseline.fetch("generation") + 1, rejected.fetch("generation")
      assert_includes rejected.dig("tests", "selected"), "CustomProviderTest#test_tracepoint_policy_loader"
      assert_includes rejected.dig("tests", "executed"), "CustomProviderTest#test_tracepoint_policy_loader"

      recovered, recovery = run_cli(
        runtime,
        cli,
        extra_env: {"EXPECTED_POLICY_MODE" => "v2"}
      )
      assert_equal 0, recovered.exitstatus, cli_failure("new skip recovery", recovered)
      assert_equal ["CustomProviderTest#test_tracepoint_policy_loader"], recovery.dig("tests", "selected")
      assert_equal ["CustomProviderTest#test_tracepoint_policy_loader"], recovery.dig("tests", "executed")
      assert_equal baseline.fetch("generation") + 2, recovery.fetch("generation")
    end
  end

  def test_direct_command_does_not_replace_public_ruby_minitest_or_rails_apis
    with_rails_cli_project do |project, runtime, cli|
      plain_snapshot = project.path.join("tmp/plain-api.json")
      active_snapshot = project.path.join("tmp/active-api.json")
      env = {"RAILS_ACCEPTANCE_REPORTERS" => "1"}
      plain = cli.plain(
        env: runtime.env.merge(env).merge("RAILS_ACCEPTANCE_API_SNAPSHOT" => plain_snapshot.to_s)
      )
      assert_equal 0, plain.exitstatus, cli_failure("plain API snapshot", plain)

      active = cli.flagged(
        env: runtime.env.merge(env).merge("RAILS_ACCEPTANCE_API_SNAPSHOT" => active_snapshot.to_s)
      )
      assert_equal 0, active.exitstatus, cli_failure("active API snapshot", active)
      assert_equal JSON.parse(plain_snapshot.read), JSON.parse(active_snapshot.read),
        "direct Testmon command changed method owners, signatures, source locations, or ancestors"
    end
  end
end

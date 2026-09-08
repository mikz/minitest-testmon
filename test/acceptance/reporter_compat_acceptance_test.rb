# frozen_string_literal: true

require_relative "rails_test_helper"

class ReporterCompatAcceptanceTest < Minitest::Test
  include RailsProductAcceptance

  TEST_FRAGMENT = "ReporterCompatibilityTest#test_custom_yaml_dependency_through_parallel_worker"
  PROVIDER = "rails_custom_inputs@1"
  POLICY_PATH = "config/policies/rules.yml"

  def test_testmon_preloaded_then_reporters_then_rails
    assert_reporter_compatibility("testmon_then_reporters_then_rails")
  end

  def test_reporters_preloaded_before_testmon
    assert_reporter_compatibility("reporters_before_testmon")
  end

  def test_duplicate_testmon_plugin_require_is_idempotent
    assert_reporter_compatibility("duplicate_plugin_require")
  end

  def test_custom_reporter_is_delegated_without_duplicate_lifecycle
    assert_reporter_compatibility("custom_delegate_reporter")
  end

  def test_cli_help_and_invalid_subcommand_exit_contract
    require_product!

    help_stdout, help_stderr, help_status = Open3.capture3(*driver.bin, "--help")
    assert_equal 0, help_status.exitstatus, "--help failed: #{help_stdout}\n#{help_stderr}"
    assert_match(/usage/i, "#{help_stdout}\n#{help_stderr}")

    invalid_stdout, invalid_stderr, invalid_status = Open3.capture3(
      *driver.bin,
      "not-a-real-testmon-command"
    )
    assert_equal 2, invalid_status.exitstatus,
      "invalid subcommand did not exit 2: #{invalid_stdout}\n#{invalid_stderr}"
  end

  private

  def assert_reporter_compatibility(load_order)
    with_reporter_project do |project, runtime|
      paths = marker_paths(project, load_order, "baseline")
      clean_path = project.path.join("tmp/#{load_order}-clean-api.json")
      active_path = project.path.join("tmp/#{load_order}-active-api.json")
      capture_clean_api(project, runtime, load_order, clean_path)

      env = reporter_env(project, runtime, load_order, paths).merge(
        "REPORTER_API_SNAPSHOT_PATH" => active_path.to_s
      )
      result = driver.run(project, env:)
      assert result.success?, failure_message(load_order, "baseline", result)
      report = driver.report(project)
      assert_report_contract report
      assert_equal 3, report.fetch("schema_version")
      assert_equal true, report.dig("publication", "published")
      MinitestTestmonAcceptance::RailsOracle.assert_auto_bundles!(report)

      marker_lines = read_lines(paths.fetch(:app))
      test_id = reporter_oracle do
        MinitestTestmonAcceptance::ReporterOracle.assert_single_execution!(
          report:,
          marker_lines:,
          test_fragment: TEST_FRAGMENT
        )
      end
      reporters = (load_order == "custom_delegate_reporter") ?
        %w[lifecycle custom_delegate_target] :
        %w[lifecycle]
      reporter_oracle do
        MinitestTestmonAcceptance::ReporterOracle.assert_callbacks_once!(
          events: read_json_lines(paths.fetch(:callback)),
          reporters:,
          records: 1
        )
      end
      reporter_oracle do
        MinitestTestmonAcceptance::ReporterOracle.assert_worker_evidence!(
          report:,
          provider: PROVIDER,
          path_suffix: POLICY_PATH,
          test_id:
        )
      end
      reporter_oracle do
        MinitestTestmonAcceptance::ReporterOracle.assert_api_unchanged!(
          clean: JSON.parse(clean_path.read),
          active: JSON.parse(active_path.read)
        )
      end
      assert_boot_order(load_order, read_json_lines(paths.fetch(:boot)))

      warm_paths = marker_paths(project, load_order, "warm").merge(app: paths.fetch(:app))
      warm_env = reporter_env(project, runtime, load_order, warm_paths).merge(
        "REPORTER_API_SNAPSHOT_PATH" => active_path.to_s
      )
      warm_result = driver.run(project, env: warm_env)
      assert warm_result.success?, failure_message(load_order, "warm follow-up", warm_result)
      warm_report = driver.report(project)
      assert_report_contract warm_report
      reporter_oracle do
        MinitestTestmonAcceptance::ReporterOracle.assert_followup_finalized_once!(
          before: report,
          after: warm_report,
          marker_lines: read_lines(paths.fetch(:app))
        )
      end
      reporter_oracle do
        MinitestTestmonAcceptance::ReporterOracle.assert_callbacks_once!(
          events: read_json_lines(warm_paths.fetch(:callback)),
          reporters:,
          records: 0
        )
      end
      assert_boot_order(load_order, read_json_lines(warm_paths.fetch(:boot)))
    end
  end

  def with_reporter_project
    require_product!
    project = MinitestTestmonAcceptance::Project.copy_fixture("rails_app")
    FileUtils.rm_rf(project.path.join("test"))
    overlay = MinitestTestmonAcceptance::FIXTURES.join("reporter_compat")
    FileUtils.cp_r("#{overlay}/.", project.path)
    runtime = MinitestTestmonAcceptance::RailsRuntime.new(project, workers: 2)
    require_rails_dependencies!(runtime)
    runtime.prepare
    MinitestTestmonAcceptance::RailsCliDriver.new(project)
    yield project, runtime
  ensure
    runtime&.cleanup
    project&.cleanup
  end

  def marker_paths(project, load_order, phase)
    prefix = project.path.join("tmp/#{load_order}-#{phase}")
    {
      app: Pathname("#{prefix}-app.log"),
      boot: Pathname("#{prefix}-boot.jsonl"),
      callback: Pathname("#{prefix}-callbacks.jsonl")
    }
  end

  def reporter_env(project, runtime, load_order, paths)
    env = runtime.env.merge(
      "EXPECTED_POLICY_MODE" => "v1",
      "REPORTER_LOAD_ORDER" => load_order,
      "REPORTER_APP_MARKER" => paths.fetch(:app).to_s,
      "REPORTER_BOOT_MARKER" => paths.fetch(:boot).to_s,
      "REPORTER_CALLBACK_MARKER" => paths.fetch(:callback).to_s
    )
    if load_order == "reporters_before_testmon"
      preload = "-r#{project.path.join("test/support/reporters_before_testmon.rb")}"
      env["RUBYOPT"] = [ENV["RUBYOPT"], preload].compact.reject(&:empty?).join(" ")
    end
    env
  end

  def capture_clean_api(project, runtime, load_order, path)
    paths = marker_paths(project, "clean", path.basename(".json").to_s)
    env = reporter_env(project, runtime, load_order, paths).merge(
      "REPORTER_LOAD_ORDER" => "clean",
      "REPORTER_API_SNAPSHOT_PATH" => path.to_s
    )
    result = MinitestTestmonAcceptance::RailsCliDriver.new(project).plain(env:)
    assert result.success?,
      "clean reporter API probe failed: #{result.stdout}\n#{result.stderr}"
  end

  def assert_boot_order(load_order, events)
    case load_order
    when "testmon_then_reporters_then_rails"
      assert_equal 1, events.length
      assert_equal "testmon_before_reporters", events.first.fetch("event")
      assert_plugin_state events.first, expected: true
      assert_kind_of Integer, events.first.fetch("pid")
    when "reporters_before_testmon"
      reporter_oracle do
        MinitestTestmonAcceptance::ReporterOracle.assert_reporters_before_processes!(events:)
      end
    when "duplicate_plugin_require"
      assert_equal 1, events.length
      event = events.first
      assert_equal "duplicate_plugin_require", event.fetch("event")
      assert_equal false, event.fetch("second_require")
      assert_kind_of Integer, event.fetch("pid")
    when "custom_delegate_reporter"
      assert_equal 1, events.length
      assert_equal "custom_delegate_reporter", events.first.fetch("event")
      assert_plugin_state events.first, expected: true
      assert_kind_of Integer, events.first.fetch("pid")
    else
      flunk "unasserted reporter load order: #{load_order}"
    end
  end

  def assert_plugin_state(event, expected:)
    assert_equal expected, event.fetch("testmon_plugin_loaded")
    assert_equal expected, event.fetch("testmon_extension_registered")
  end

  def read_lines(path)
    path.file? ? path.readlines(chomp: true) : []
  end

  def read_json_lines(path)
    read_lines(path).map { |line| JSON.parse(line) }
  end

  def reporter_oracle
    yield
  rescue MinitestTestmonAcceptance::ReporterOracle::Mismatch => error
    flunk error.message
  end

  def failure_message(load_order, phase, result)
    "#{load_order} #{phase} failed (#{result.exitstatus}):\n#{result.stdout}\n#{result.stderr}"
  end
end

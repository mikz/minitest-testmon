# frozen_string_literal: true

require_relative "test_helper"

class ReporterHarnessSelfTest < Minitest::Test
  def test_reporter_oracle_accepts_one_publication_and_one_followup
    baseline = report(
      generation: 7,
      discovered: ["ReporterCompatibilityTest#test_one"],
      selected: ["ReporterCompatibilityTest#test_one"],
      executed: ["ReporterCompatibilityTest#test_one"]
    )
    followup = report(generation: 7)

    assert_equal "ReporterCompatibilityTest#test_one",
      MinitestTestmonAcceptance::ReporterOracle.assert_single_execution!(
        report: baseline,
        marker_lines: ["123:ReporterCompatibilityTest#test_one"],
        test_fragment: "ReporterCompatibilityTest#test_one"
      )
    assert MinitestTestmonAcceptance::ReporterOracle.assert_callbacks_once!(
      events: [
        {"reporter" => "lifecycle", "event" => "start"},
        {"reporter" => "lifecycle", "event" => "record"},
        {"reporter" => "lifecycle", "event" => "report"}
      ],
      reporters: ["lifecycle"],
      records: 1
    )
    assert MinitestTestmonAcceptance::ReporterOracle.assert_followup_finalized_once!(
      before: baseline,
      after: followup,
      marker_lines: ["123:ReporterCompatibilityTest#test_one"]
    )
  end

  def test_reporter_oracle_rejects_duplicate_reporter_finalization
    error = assert_raises(MinitestTestmonAcceptance::ReporterOracle::Mismatch) do
      MinitestTestmonAcceptance::ReporterOracle.assert_callbacks_once!(
        events: [
          {"reporter" => "lifecycle", "event" => "start"},
          {"reporter" => "lifecycle", "event" => "report"},
          {"reporter" => "lifecycle", "event" => "report"}
        ],
        reporters: ["lifecycle"],
        records: 0
      )
    end

    assert_match "report=2", error.message
  end

  def test_reporter_oracle_rejects_warm_generation_change_and_retained_lease
    baseline = report(generation: 7)
    followup = report(
      generation: 8,
      published: false,
      reason: "cache_lease_unavailable"
    )

    error = assert_raises(MinitestTestmonAcceptance::ReporterOracle::Mismatch) do
      MinitestTestmonAcceptance::ReporterOracle.assert_followup_finalized_once!(
        before: baseline,
        after: followup,
        marker_lines: ["one"]
      )
    end

    assert_match "generation", error.message
    assert_match "cache lease", error.message
  end

  def test_reporter_oracle_requires_worker_attributed_custom_file_evidence
    evidence = report(generation: 1)
    evidence["inventory"] = {
      "claimed" => {
        "items" => [
          {
            "provider" => "rails_custom_inputs@1",
            "path" => "/app/config/policies/rules.yml",
            "test_ids" => ["ReporterCompatibilityTest#test_one"]
          }
        ]
      }
    }

    assert MinitestTestmonAcceptance::ReporterOracle.assert_worker_evidence!(
      report: evidence,
      provider: "rails_custom_inputs@1",
      path_suffix: "config/policies/rules.yml",
      test_id: "ReporterCompatibilityTest#test_one"
    )

    assert_raises(MinitestTestmonAcceptance::ReporterOracle::Mismatch) do
      MinitestTestmonAcceptance::ReporterOracle.assert_worker_evidence!(
        report: evidence,
        provider: "rails_custom_inputs@1",
        path_suffix: "config/policies/rules.yml",
        test_id: "missing"
      )
    end
  end

  def test_reporters_before_oracle_accepts_one_preload_per_cli_and_test_process
    events = [
      {
        "event" => "reporters_before_testmon",
        "pid" => 101,
        "testmon_plugin_loaded" => false,
        "testmon_extension_registered" => false
      },
      {
        "event" => "reporters_before_testmon",
        "pid" => 202,
        "testmon_plugin_loaded" => false,
        "testmon_extension_registered" => false
      },
      {
        "event" => "testmon_after_reporters",
        "pid" => 202,
        "testmon_plugin_loaded" => true,
        "testmon_extension_registered" => true
      }
    ]

    assert MinitestTestmonAcceptance::ReporterOracle.assert_reporters_before_processes!(
      events:
    )
  end

  def test_reporters_before_oracle_rejects_duplicate_preload_in_one_process
    events = [
      {
        "event" => "reporters_before_testmon",
        "pid" => 101,
        "testmon_plugin_loaded" => false,
        "testmon_extension_registered" => false
      },
      {
        "event" => "reporters_before_testmon",
        "pid" => 101,
        "testmon_plugin_loaded" => false,
        "testmon_extension_registered" => false
      },
      {
        "event" => "testmon_after_reporters",
        "pid" => 101,
        "testmon_plugin_loaded" => true,
        "testmon_extension_registered" => true
      }
    ]

    error = assert_raises(MinitestTestmonAcceptance::ReporterOracle::Mismatch) do
      MinitestTestmonAcceptance::ReporterOracle.assert_reporters_before_processes!(
        events:
      )
    end

    assert_match "more than once", error.message
  end

  def test_fixture_freezes_reporter_version_load_orders_and_process_workers
    fixture = MinitestTestmonAcceptance::FIXTURES.join("reporter_compat")
    support = fixture.join("test/support/reporter_compat.rb").read
    helper = fixture.join("test/test_helper.rb").read
    preload = fixture.join("test/support/reporters_before_testmon.rb").read
    plugin_state = fixture.join("test/support/testmon_plugin_state.rb").read
    tests = fixture.glob("test/**/*_test.rb")

    assert_includes support, 'Gem::Version.new("1.7.1")'
    assert_includes support, "Minitest::Reporters.use!"
    assert_includes support, '"pid" => Process.pid'
    assert_includes helper, 'require "minitest/testmon_plugin"'
    assert_includes helper, "second_require"
    assert_includes helper, "custom_delegate_target: true"
    assert_includes helper, "with: :processes, threshold: 0"
    assert_includes preload, "ReporterTestmonPluginState.feature_loaded?"
    assert_includes preload, "ReporterTestmonPluginState.extension_registered?"
    refute_includes preload, "defined?(Minitest::Testmon)"
    assert_includes plugin_state, "$LOADED_FEATURES.any?"
    assert_includes plugin_state, "Minitest.extensions.any?"
    assert_equal ["reporter_compatibility_test.rb"], tests.map { |path| path.basename.to_s }
  end

  def test_reporter_acceptance_source_has_cli_status_gates
    source = MinitestTestmonAcceptance::ROOT.join("reporter_compat_acceptance_test.rb").read

    assert_includes source, '*driver.bin, "--help"'
    assert_includes source, "assert_equal 0, help_status.exitstatus"
    assert_includes source, "assert_equal 2, invalid_status.exitstatus"
  end

  private

  def report(generation:, discovered: [], selected: [], executed: [], published: true, reason: nil)
    {
      "generation" => generation,
      "tests" => {
        "discovered" => discovered,
        "selected" => selected,
        "executed" => executed
      },
      "inventory" => {},
      "publication" => {
        "published" => published,
        "reason" => reason
      }
    }
  end
end

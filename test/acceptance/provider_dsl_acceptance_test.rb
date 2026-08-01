# frozen_string_literal: true

require_relative "provider_test_helper"
require_relative "rails_test_helper"

class ProviderDslAcceptanceTest < Minitest::Test
  include ProviderProductAcceptance
  include RailsProductAcceptance

  def test_valid_dsl_introspection_builtin_ids_fileset_sugar_and_deep_immutability
    with_provider_project do |project|
      report = learn_provider_baseline(project)
      assert_equal 2, report.fetch("schema_version")

      snapshot = provider_definition_snapshot(project)
      expected = ["ruby@1", *ProviderProductAcceptance::CUSTOM_PROVIDER_IDS]
      assert MinitestTestmonAcceptance::ProviderOracle.assert_definition_snapshot!(
        snapshot,
        expected_ids: expected
      )
      fileset = snapshot.fetch("providers").find { |provider| provider.fetch("id") == "fileset.compat_templates@1" }
      assert_equal "fileset.compat_templates", fileset.fetch("name")
      assert_equal 1, fileset.fetch("version")
    end
  end

  def test_invalid_provider_inventory_facet_claim_and_observer_combinations_fail_before_tests
    invalid_configurations.each do |label, body|
      with_provider_project do |project|
        marker = project.path.join("tmp/invalid-config-marker")
        project.write(".minitest-testmon.rb", configuration_source(body))

        result = driver.run(project, env: {"PROVIDER_TEST_MARKER" => marker.to_s})
        refute result.success?, "#{label} unexpectedly succeeded"
        refute marker.exist?, "#{label} reached a test before configuration rejection"
        refute driver.state_path(project).exist?, "#{label} created a state database"
        refute_empty result.stderr, "#{label} emitted no configuration diagnostic"
      end
    end
  end

  def test_invalid_configuration_preserves_the_published_database_generation_and_edges
    with_provider_project do |project|
      baseline = learn_provider_baseline(project)
      state_digest = Digest::SHA256.file(driver.state_path(project)).hexdigest
      marker = project.path.join("tmp/invalid-after-baseline-marker")
      project.write(".minitest-testmon.rb", configuration_source(<<~RUBY))
        config.provider :broken, version: 0 do |_provider|
        end
      RUBY

      result = driver.run(project, env: {"PROVIDER_TEST_MARKER" => marker.to_s})
      refute result.success?
      refute marker.exist?
      report = driver.report(project)
      assert_equal baseline, report
      assert_equal state_digest, Digest::SHA256.file(driver.state_path(project)).hexdigest
    end
  end

  def test_config_source_change_selects_all_through_context_input_and_full_run_edits_no_config
    with_provider_project do |project|
      ruby_config = project.path.join(".minitest-testmon.rb")
      yaml_decoy = project.path.join(".minitest-testmon.yml")
      ruby_before = ruby_config.read
      yaml_digest = Digest::SHA256.file(yaml_decoy).hexdigest
      baseline = learn_provider_baseline(project)

      ruby_config.write("#{ruby_before}\n# context digest acceptance change\n")
      result, report = run_provider(project)
      assert result.success?, result.stderr
      assert MinitestTestmonAcceptance::ProviderOracle.assert_full_run!(report)
      refute_equal baseline.fetch("context_signature"), report.fetch("context_signature")
      assert_nil report.dig("publication", "reason")
      assert_equal baseline.fetch("generation") + 1, report.fetch("generation")
      assert_equal "#{ruby_before}\n# context digest acceptance change\n", ruby_config.read
      assert_equal yaml_digest, Digest::SHA256.file(yaml_decoy).hexdigest,
        "YAML decoy was parsed or rewritten as Testmon configuration"

      config_digest = Digest::SHA256.file(ruby_config).hexdigest
      discovery = driver.run(project, full: true)
      assert discovery.success?, discovery.stderr
      assert_report_contract driver.report(project)
      assert_equal config_digest, Digest::SHA256.file(ruby_config).hexdigest,
        "discovery edited .minitest-testmon.rb"
      assert_equal yaml_digest, Digest::SHA256.file(yaml_decoy).hexdigest,
        "discovery edited or loaded .minitest-testmon.yml"
    end
  end

  def test_yaml_content_change_selects_exactly_its_consumer
    with_provider_project do |project|
      learn_provider_baseline(project)
      project.write("config/pricing/basic.yml", "price: 11\n")

      result, report = run_provider(project, extra_env: {"EXPECTED_BASIC_PRICE" => "11"})
      assert result.success?, result.stderr
      assert_only_provider_test report, "PricingRulesTest#test_basic_rule"
      premium = find_test_id(report, "PricingRulesTest#test_premium_rule")
      refute_includes report.dig("tests", "selected"), premium
      claim = inventory_items(report, :claimed).find do |item|
        item.fetch("provider") == "pricing_rules@1" && item.fetch("path", "").to_s.end_with?("config/pricing/basic.yml")
      end
      refute_nil claim
      assert_equal "content", claim.fetch("facet")
    end
  end

  def test_membership_add_delete_and_rename_select_every_discovered_test
    with_provider_project do |project|
      learn_provider_baseline(project)
      project.write("templates/gamma.txt", "gamma\n")

      added, added_report = run_provider(project, extra_env: {
        "EXPECTED_TEMPLATES" => "alpha.txt,beta.txt,gamma.txt"
      })
      assert added.success?, added.stderr
      assert MinitestTestmonAcceptance::ProviderOracle.assert_full_run!(added_report)

      project.remove("templates/gamma.txt")
      deleted, deleted_report = run_provider(project)
      assert deleted.success?, deleted.stderr
      assert MinitestTestmonAcceptance::ProviderOracle.assert_full_run!(deleted_report)

      FileUtils.mv(project.path.join("templates/alpha.txt"), project.path.join("templates/renamed.txt"))
      renamed, renamed_report = run_provider(project, extra_env: {
        "EXPECTED_TEMPLATES" => "beta.txt,renamed.txt"
      })
      assert renamed.success?, renamed.stderr
      assert MinitestTestmonAcceptance::ProviderOracle.assert_full_run!(renamed_report)
    end
  end

  def test_trace_notification_and_resolver_wrappers_are_frozen_bounded_public_values
    with_provider_project do |project|
      trace_marker = project.path.join("tmp/trace-wrapper.json")
      notification_marker = project.path.join("tmp/notification-wrapper.json")
      resolver_marker = project.path.join("tmp/resolver-wrapper.json")
      FileUtils.mkdir_p(trace_marker.dirname)
      result = driver.run(project, full: true, env: {
        "TRACE_WRAPPER_MARKER" => trace_marker.to_s,
        "NOTIFICATION_WRAPPER_MARKER" => notification_marker.to_s,
        "RESOLVER_WRAPPER_MARKER" => resolver_marker.to_s
      })
      assert result.success?, result.stderr
      report = driver.report(project)
      assert_report_contract report

      trace = JSON.parse(trace_marker.read)
      assert_equal "call", trace.fetch("event").to_s
      assert_equal "load", trace.fetch("method_id").to_s
      assert_match %r{/lib/policy_loader\.rb\z}, trace.fetch("path")
      assert_kind_of Integer, trace.fetch("lineno")
      assert_match %r{/config/pricing/(basic\.yml|premium\.yaml)\z}, trace.fetch("local_path")

      notification = JSON.parse(notification_marker.read)
      assert_equal "render.document", notification.fetch("name")
      assert_equal true, notification.fetch("payload_frozen")
      assert_equal true, notification.fetch("nested_frozen")
      assert_equal true, notification.fetch("tags_frozen")

      resolver = JSON.parse(resolver_marker.read)
      assert_equal "content", resolver.fetch("name").to_s
      assert_equal "content", resolver.fetch("digest").to_s
      assert_equal "file", resolver.fetch("granularity").to_s
      assert_equal "test", resolver.fetch("scope").to_s
      assert_equal true, resolver.fetch("wrapper_frozen")
      assert_equal true, resolver.fetch("keys_frozen")
      assert_equal true, resolver.fetch("keys_sorted")
    end
  end

  def test_ignore_predicate_reports_user_ignored_and_creates_no_dependency
    with_provider_project do |project|
      baseline = learn_provider_baseline(project)
      ignored = observation_items(baseline, :ignored).select do |item|
        item.fetch("path", "").to_s.end_with?("config/pricing/skipped.generated")
      end
      refute_empty ignored
      assert ignored.any? { |item| item.fetch("reason") == "user_ignored" },
        "provider ignore evidence was lost among core exclusion observations"

      project.write("config/pricing/skipped.generated", "changed generated input\n")
      result, report = run_provider(project)
      assert result.success?, result.stderr
      MinitestTestmonAcceptance::RailsOracle.assert_warm_zero!(report)
    end
  end

  def test_resolver_nil_is_unclaimed_and_undeclared_key_fails_closed
    with_provider_project do |project|
      learn_provider_baseline(project)
      project.write("config/resolver/input.yml", "value: resolver-v2\n")

      empty_result, empty_report = run_provider(project, extra_env: {
        "EXPECTED_RESOLVER" => "resolver-v2",
        "RESOLVER_EMPTY" => "1"
      })
      refute empty_result.success?, "unclaimed resolver event unexpectedly published"
      assert observation_items(empty_report, :uncovered).any? { |item| item.fetch("kind") == "resolver_loaded" }

      missing_result, missing_report = run_provider(project, extra_env: {
        "EXPECTED_RESOLVER" => "resolver-v2",
        "RESOLVER_MISSING_KEY" => "1"
      })
      refute missing_result.success?, "undeclared resolver key unexpectedly published"
      assert_equal "provider_incomplete", missing_report.dig("publication", "reason")
      assert_observation_reason missing_report, "claim_path_missing"
    end
  end

  def test_extractor_error_marks_next_invocation_full_and_blocks_until_clean_recovery
    assert_runtime_failure_recovery(
      mutation_path: "config/documents/invoice.yml",
      mutation: "title: Invoice v2\n",
      expected_env: {"EXPECTED_DOCUMENT" => "Invoice v2"},
      failure_env: {"FAIL_NOTIFICATION_EXTRACTOR" => "1"},
      reason: "extractor_error"
    )
  end

  def test_noncanonical_details_mark_next_invocation_full_and_block_until_clean_recovery
    assert_runtime_failure_recovery(
      mutation_path: "config/pricing/basic.yml",
      mutation: "price: 11\n",
      expected_env: {"EXPECTED_BASIC_PRICE" => "11"},
      failure_env: {"NONCANONICAL_DETAILS" => "1"},
      reason: "noncanonical_observation"
    )
  end

  def test_missing_startup_observer_forces_full_before_filter_and_preserves_publication
    with_provider_project do |project|
      baseline = learn_provider_baseline(project)
      result, report = run_provider(project, extra_env: {"MISSING_STARTUP_OBSERVER" => "1"})
      refute result.success?, "missing observer target unexpectedly succeeded"
      assert MinitestTestmonAcceptance::ProviderOracle.assert_full_run!(report)
      assert_equal "provider_incomplete", report.dig("publication", "reason")
      assert_observation_reason report, "observer_unavailable"
      assert MinitestTestmonAcceptance::ProviderOracle.assert_preserved_publication!(baseline, report)

      recovery, recovery_report = run_provider(project)
      assert recovery.success?, recovery.stderr
      assert MinitestTestmonAcceptance::ProviderOracle.assert_full_run!(recovery_report)
      assert_equal true, recovery_report.dig("publication", "published")
    end
  end

  def test_runtime_created_matching_file_never_joins_frozen_inventory
    with_provider_project do |project|
      result = driver.run(project, full: true, env: {"PROBE_RUNTIME_ARTIFACT" => "1"})
      assert result.success?, result.stderr
      report = driver.report(project)
      assert_report_contract report
      assert MinitestTestmonAcceptance::ProviderOracle.assert_inventory_excludes!(report, "config/pricing/runtime.yml")
      claimed = observation_items(report, :claimed).any? do |item|
        item.fetch("path", "").to_s.end_with?("config/pricing/runtime.yml")
      end
      refute claimed, "runtime-created file resolved against a post-snapshot inventory"
    end
  end

  def test_outside_root_access_is_excluded_and_suggests_an_explicit_root
    with_provider_project do |project|
      result = driver.run(project, full: true, env: {"PROBE_SUGGESTIONS" => "1"})
      refute result.success?, "outside-root/opaque discovery unexpectedly exited zero"
      report = driver.report(project)
      assert_report_contract report
      assert_equal false, report.dig("publication", "published")
      outside = report.fetch("suggestions").select { |suggestion| suggestion.fetch("code") == "outside_root" }
      refute_empty outside
      assert outside.all? { |suggestion| suggestion.fetch("path").nil? },
        "outside-root suggestion leaked a nondeterministic absolute path"
      assert outside.all? { |suggestion| suggestion.fetch("ruby").start_with?("config.root ") }

      inventory_paths = inventory_items(report).filter_map { |item| item.fetch("path") }
      assert inventory_paths.all? { |path| path.start_with?("project:", "shared:") },
        "outside-root access entered the frozen provider inventory"
    end
  end

  def test_structured_suggestions_are_complete_exact_and_cross_root_deterministic
    reports = 2.times.map do
      project = MinitestTestmonAcceptance::Project.copy_fixture("provider_dsl")
      result = driver.run(project, full: true, env: {"PROBE_SUGGESTIONS" => "1"})
      refute result.success?, "suggestion discovery unexpectedly exited zero"
      report = driver.report(project)
      assert_report_contract report
      assert_equal false, report.dig("publication", "published")
      assert MinitestTestmonAcceptance::ProviderOracle.assert_suggestion_codes!(
        report,
        MinitestTestmonAcceptance::ReportContract::SUGGESTION_CODES
      )
      report
    ensure
      project&.cleanup
    end

    assert_equal reports.first.fetch("suggestions"), reports.last.fetch("suggestions")
    reports.each do |report|
      report.fetch("suggestions").each do |suggestion|
        assert_equal MinitestTestmonAcceptance::ReportContract::SUGGESTION_KEYS, suggestion.keys
      end
    end
  end

  def test_notification_subscription_is_removed_before_after_run_callbacks
    with_provider_project do |project|
      during = project.path.join("tmp/notification-during")
      after = project.path.join("tmp/notification-after")
      FileUtils.mkdir_p(during.dirname)
      result = driver.run(project, full: true, env: {
        "NOTIFICATION_DURING_MARKER" => during.to_s,
        "NOTIFICATION_AFTER_MARKER" => after.to_s
      })
      assert result.success?, result.stderr
      assert_operator Integer(during.read), :>, 0
      assert_equal 0, Integer(after.read), "notification observer subscription leaked past teardown"
    end
  end

  def test_custom_observers_publish_equivalent_rails_evidence_with_workers_one_two_and_four
    reports = [1, 2, 4].map do |workers|
      with_rails_project(workers:) do |project, runtime|
        learn_rails_baseline(project, runtime)
        project.write("config/policies/rules.yml", "mode: v2\n")
        result = driver.run(project, env: runtime.env.merge("EXPECTED_POLICY_MODE" => "v2"))
        assert result.success?, result.stderr
        report = driver.report(project)
        assert_report_contract report
        assert_includes report.fetch("bundles"), "rails_custom_inputs@1"
        expected = %w[
          CustomProviderTest#test_notification_policy_loader
          CustomProviderTest#test_tracepoint_policy_loader
          HighVolumeSpoolTest#test_repeated_provider_observations_stream_to_worker_spool
        ].map { |fragment| find_test_id(report, fragment) }.sort
        assert_equal expected, report.dig("tests", "selected")
        assert_equal expected, report.dig("tests", "executed")
        report
      end
    end

    assert MinitestTestmonAcceptance::RailsOracle.assert_equivalent!(reports)
  end

  def test_plain_and_rails_builtin_definition_ids_are_exact
    with_provider_project do |project|
      plain = provider_definition_snapshot(project)
      plain_ids = plain.fetch("providers").map { |provider| provider.fetch("id") }
      assert_includes plain_ids, "ruby@1"
      assert_empty MinitestTestmonAcceptance::ProviderOracle::RAILS_BUILTIN_IDS & plain_ids
    end

    with_rails_project do |project, runtime|
      probe = MinitestTestmonAcceptance::ROOT.join("probes/provider_definition_snapshot.rb")
      project.write("provider_definition_snapshot.rb", probe.read)
      output = project.path.join("tmp/rails-provider-definitions.json")
      FileUtils.mkdir_p(output.dirname)
      result = driver.run(
        project,
        full: true,
        env: runtime.env.merge("PROVIDER_DEFINITION_SNAPSHOT" => output.to_s)
      )
      assert result.success?, result.stderr
      snapshot = JSON.parse(output.read)
      expected = ["ruby@1", "rails_custom_inputs@1", *MinitestTestmonAcceptance::ProviderOracle::RAILS_BUILTIN_IDS]
      assert MinitestTestmonAcceptance::ProviderOracle.assert_definition_snapshot!(snapshot, expected_ids: expected)
    end
  end

  def test_tracepoint_notification_and_yaml_public_apis_are_not_replaced
    with_provider_project do |project|
      probe = MinitestTestmonAcceptance::ROOT.join("probes/provider_observer_api_snapshot.rb")
      project.write("provider_observer_api_snapshot.rb", probe.read)
      clean = project.path.join("tmp/provider-api-clean.json")
      active = project.path.join("tmp/provider-api-active.json")
      FileUtils.mkdir_p(clean.dirname)

      clean_stdout, clean_stderr, clean_status = Open3.capture3(
        {"PROVIDER_API_SNAPSHOT_PATH" => clean.to_s},
        RbConfig.ruby,
        "provider_observer_api_snapshot.rb",
        chdir: project.path.to_s
      )
      assert clean_status.success?, "clean provider API probe failed: #{clean_stdout}\n#{clean_stderr}"
      active_stdout, active_stderr, active_status = Open3.capture3(
        {
          "BUNDLE_GEMFILE" => MinitestTestmonAcceptance::GEMFILE.to_s,
          "MINITEST_TESTMON" => "1",
          "MINITEST_TESTMON_CONFIG" => project.path.join(".minitest-testmon.rb").to_s,
          "MINITEST_TESTMON_PROJECT_ROOT" => project.path.to_s,
          "PROVIDER_API_SNAPSHOT_PATH" => active.to_s
        },
        RbConfig.ruby,
        "-rbundler/setup",
        "-Itest",
        "-rtest_helper",
        "-rminitest/testmon",
        "provider_observer_api_snapshot.rb",
        chdir: project.path.to_s
      )
      assert active_status.success?, "#{active_stdout}\n#{active_stderr}"
      assert MinitestTestmonAcceptance::ProviderOracle.assert_api_unchanged!(
        JSON.parse(clean.read),
        JSON.parse(active.read)
      )
    end
  end

  private

  def provider_definition_snapshot(project)
    probe = MinitestTestmonAcceptance::ROOT.join("probes/provider_definition_snapshot.rb")
    project.write("provider_definition_snapshot.rb", probe.read)
    output = project.path.join("tmp/provider-definitions.json")
    FileUtils.mkdir_p(output.dirname)
    stdout, stderr, status = Open3.capture3(
      {
        "BUNDLE_GEMFILE" => MinitestTestmonAcceptance::GEMFILE.to_s,
        "MINITEST_TESTMON_CONFIG" => project.path.join(".minitest-testmon.rb").to_s,
        "MINITEST_TESTMON_PROJECT_ROOT" => project.path.to_s,
        "PROVIDER_DEFINITION_SNAPSHOT" => output.to_s
      },
      RbConfig.ruby,
      "-rbundler/setup",
      "provider_definition_snapshot.rb",
      chdir: project.path.to_s
    )
    assert status.success?, "#{stdout}\n#{stderr}"
    JSON.parse(output.read)
  end

  def assert_runtime_failure_recovery(mutation_path:, mutation:, expected_env:, failure_env:, reason:)
    with_provider_project do |project|
      baseline = learn_provider_baseline(project)
      project.write(mutation_path, mutation)

      first_result, first_report = run_provider(project, extra_env: expected_env.merge(failure_env))
      refute first_result.success?, "#{reason} unexpectedly published"
      assert_equal "provider_incomplete", first_report.dig("publication", "reason")
      assert_observation_reason first_report, reason
      assert MinitestTestmonAcceptance::ProviderOracle.assert_preserved_publication!(baseline, first_report)

      selected = first_report.dig("tests", "selected")
      repeated_result, repeated_report = run_provider(project, extra_env: expected_env.merge(failure_env))
      refute repeated_result.success?, "repeated #{reason} unexpectedly published"
      assert_equal selected, repeated_report.dig("tests", "selected")
      assert_equal selected, repeated_report.dig("tests", "executed")
      assert_observation_reason repeated_report, reason

      recovery, recovery_report = run_provider(project, extra_env: expected_env)
      assert recovery.success?, recovery.stderr
      assert_equal selected, recovery_report.dig("tests", "selected")
      assert_equal selected, recovery_report.dig("tests", "executed")
      assert_equal true, recovery_report.dig("publication", "published")
      assert_equal baseline.fetch("generation") + 1, recovery_report.fetch("generation")
    end
  end

  def invalid_configurations
    inventory = <<~RUBY
      provider.inventory :files, root: :project, base: ".", include: ["config/**/*.yml"], exclude: []
    RUBY
    facet = <<~RUBY
      provider.facet :content, inventory: :files, digest: :content, granularity: :file, scope: :test
    RUBY
    {
      "provider without implementation or block" => "config.provider :missing, version: 1\n",
      "provider with implementation and block" => "config.provider :both, Object.new, version: 1 do |_provider|\nend\n",
      "nonpositive version" => "config.provider :zero, version: 0 do |_provider|\nend\n",
      "duplicate canonical provider name" => <<~RUBY,
        config.provider :duplicate, version: 1 do |_provider|
        end
        config.provider "duplicate", version: 2 do |_provider|
        end
      RUBY
      "empty inventory include" => <<~RUBY,
        config.provider :empty_inventory, version: 1 do |provider|
          provider.inventory :files, root: :project, base: ".", include: [], exclude: []
        end
      RUBY
      "duplicate inventory name" => <<~RUBY,
        config.provider :duplicate_inventory, version: 1 do |provider|
          #{inventory}#{inventory}
        end
      RUBY
      "content set facet" => facet_configuration(:content, :set),
      "existence set facet" => facet_configuration(:existence, :set),
      "paths file facet" => facet_configuration(:paths, :file),
      "contents file facet" => facet_configuration(:contents, :file),
      "ruby source set facet" => facet_configuration(:ruby_source, :set),
      "invalid facet scope" => facet_configuration(:content, :file, scope: :global),
      "facet missing inventory" => <<~RUBY,
        config.provider :missing_inventory, version: 1 do |provider|
          provider.facet :content, inventory: :unknown, digest: :content, granularity: :file, scope: :test
        end
      RUBY
      "claim target missing" => <<~RUBY,
        config.provider :missing_target, version: 1 do |provider|
          #{inventory}#{facet}provider.claim :file_read, to: [:files, :unknown], path: :path
        end
      RUBY
      "claim path and using" => <<~RUBY,
        config.provider :ambiguous_claim, version: 1 do |provider|
          #{inventory}#{facet}provider.claim :file_read, to: [:files, :content], path: :path, using: ->(*) { nil }
        end
      RUBY
      "file claim without resolver" => <<~RUBY,
        config.provider :resolver_missing, version: 1 do |provider|
          #{inventory}#{facet}provider.claim :file_read, to: [:files, :content]
        end
      RUBY
      "invalid TracePoint target" => <<~RUBY,
        config.provider :bad_trace, version: 1 do |provider|
          provider.observe_tracepoint :bad, target: "not a target", event: :call, path: ->(trace) { trace.path }
        end
      RUBY
      "invalid TracePoint event" => <<~RUBY
        config.provider :bad_event, version: 1 do |provider|
          provider.observe_tracepoint :bad, target: "PolicyLoader.load", event: :line, path: ->(trace) { trace.path }
        end
      RUBY
    }
  end

  def facet_configuration(digest, granularity, scope: :test)
    <<~RUBY
      config.provider :invalid_facet, version: 1 do |provider|
        provider.inventory :files, root: :project, base: ".", include: ["config/**/*.yml"], exclude: []
        provider.facet :facet, inventory: :files, digest: :#{digest}, granularity: :#{granularity}, scope: :#{scope}
      end
    RUBY
  end
end

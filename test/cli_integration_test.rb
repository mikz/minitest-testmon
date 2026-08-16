# frozen_string_literal: true

require_relative "test_helper"
require "json"
require "open3"
require "rbconfig"

class CLIIntegrationTest < TestmonTestCase
  GEM_ROOT = File.expand_path("..", __dir__)
  EXECUTABLE = File.join(GEM_ROOT, "exe/minitest-testmon")

  def test_help_is_successful_and_invalid_usage_is_not
    stdout, stderr, help = Open3.capture3(RbConfig.ruby, EXECUTABLE, "--help")
    assert help.success?, stderr
    assert_equal "usage: minitest-testmon run [--full]|report|runs|explain\n", stdout
    assert_empty stderr

    stdout, stderr, invalid = Open3.capture3(RbConfig.ruby, EXECUTABLE, "unknown")
    refute invalid.success?
    assert_equal 2, invalid.exitstatus
    assert_empty stdout
    assert_equal "usage: minitest-testmon run [--full]|report|runs|explain\n", stderr
  end

  def test_forced_run_preloads_the_plugin_runs_every_discovered_test_and_preserves_failure_status
    with_cli_project do |directory, marker|
      _stdout, stderr, status = invoke(directory, marker, "run", {"PLANT_FAILURE" => "1"}, full: true)

      refute status.success?, stderr
      report = read_report(directory)
      assert_equal "run", report.fetch("mode")
      assert_equal report.dig("tests", "discovered"), report.dig("tests", "selected")
      assert_equal report.dig("tests", "discovered"), report.dig("tests", "executed")
      assert_equal 2, report.dig("tests", "executed").length
      assert_equal({"published" => false, "reason" => "test_failure"}, report.fetch("publication"))
    end
  end

  def test_successful_forced_run_publishes_a_warm_baseline
    with_cli_project do |directory, marker|
      _stdout, stderr, forced = invoke(directory, marker, "run", full: true)
      assert forced.success?, stderr
      run_report = read_report(directory)
      assert_equal true, run_report.dig("publication", "published")
      assert_equal run_report.dig("tests", "discovered"), run_report.dig("tests", "executed")

      _stdout, stderr, warm = invoke(directory, marker, "run")
      assert warm.success?, stderr
      warm_report = read_report(directory)
      assert_empty warm_report.dig("tests", "selected")
      assert_empty warm_report.dig("tests", "executed")
      assert_equal 2, File.readlines(marker).length
    end
  end

  def test_run_publishes_then_skips_the_unchanged_command_with_default_config
    with_cli_project do |directory, marker|
      _stdout, stderr, cold = invoke(directory, marker, "run")
      assert cold.success?, stderr
      cold_report = read_report(directory)
      assert_equal true, cold_report.dig("publication", "published")
      assert_equal 1, File.readlines(marker).length

      _stdout, stderr, warm = invoke(directory, marker, "run")
      assert warm.success?, stderr
      warm_report = read_report(directory)
      assert_empty warm_report.dig("tests", "selected")
      assert_empty warm_report.dig("tests", "executed")
      assert_equal cold_report.fetch("generation"), warm_report.fetch("generation")
      assert_equal 2, File.readlines(marker).length
    end
  end

  def test_selection_is_computed_after_minitest_applies_the_original_name_filter
    with_cli_project do |directory, marker|
      _stdout, stderr, filtered = invoke(
        directory,
        marker,
        "run",
        {},
        test_arguments: ["--name", "/test_failure_status/"]
      )
      assert filtered.success?, stderr
      filtered_report = read_report(directory)
      assert_equal ["ValueTest#test_failure_status"], filtered_report.dig("tests", "discovered")
      assert_equal ["ValueTest#test_failure_status"], filtered_report.dig("tests", "selected")
      assert_equal ["ValueTest#test_failure_status"], filtered_report.dig("tests", "executed")

      _stdout, stderr, wider = invoke(directory, marker, "run")
      assert wider.success?, stderr
      wider_report = read_report(directory)
      assert_equal 2, wider_report.dig("tests", "discovered").length
      assert_equal ["ValueTest#test_plugin_is_registered_once"], wider_report.dig("tests", "selected")
      assert_equal ["ValueTest#test_plugin_is_registered_once"], wider_report.dig("tests", "executed")
    end
  end

  def test_narrow_then_wide_run_preserves_suite_membership_checksums_per_test
    with_cli_project do |directory, marker|
      _stdout, stderr, narrow = invoke(
        directory, marker, "run", {}, test_arguments: ["--name", "/test_failure_status/"]
      )
      assert narrow.success?, stderr
      write_file(File.join(directory, "templates/added.txt"), "added\n")

      _stdout, stderr, wide = invoke(directory, marker, "run")
      assert wide.success?, stderr
      report = read_report(directory)
      assert_equal report.dig("tests", "discovered"), report.dig("tests", "selected")
      assert_equal report.dig("tests", "selected"), report.dig("tests", "executed")
    end
  end

  def test_narrow_then_wide_run_preserves_context_checksums_per_test
    with_cli_project do |directory, marker|
      _stdout, stderr, narrow = invoke(
        directory, marker, "run", {}, test_arguments: ["--name", "/test_failure_status/"]
      )
      assert narrow.success?, stderr
      configuration = File.join(directory, ".minitest-testmon.rb")
      File.binwrite(configuration, File.binread(configuration).sub("version: 1", "version: 2"))

      _stdout, stderr, wide = invoke(directory, marker, "run")
      assert wide.success?, stderr
      report = read_report(directory)
      assert_equal report.dig("tests", "discovered"), report.dig("tests", "selected")
      assert_equal report.dig("tests", "selected"), report.dig("tests", "executed")
    end
  end

  def test_a_new_generated_runnable_is_discovered_before_warm_cache_selection
    with_cli_project do |directory, marker|
      _stdout, stderr, cold = invoke(directory, marker, "run")
      assert cold.success?, stderr

      _stdout, stderr, generated = invoke(
        directory,
        marker,
        "run",
        {"GENERATED_CASES" => "late"}
      )
      assert generated.success?, stderr
      report = read_report(directory)
      generated_id = "ValueTest#test_generated_late"
      assert_includes report.dig("tests", "discovered"), generated_id
      assert_equal [generated_id], report.dig("tests", "selected")
      assert_equal [generated_id], report.dig("tests", "executed")
    end
  end

  def test_report_runs_and_historical_explain_read_sqlite_without_a_sidecar
    with_cli_project do |directory, marker|
      _stdout, stderr, cold = invoke(directory, marker, "run")
      assert cold.success?, stderr

      report_stdout, report_stderr, report_status = Open3.capture3(
        RbConfig.ruby, EXECUTABLE, "report", chdir: directory
      )
      assert report_status.success?, report_stderr
      report = JSON.parse(report_stdout)

      runs_stdout, runs_stderr, runs_status = Open3.capture3(
        RbConfig.ruby, EXECUTABLE, "runs", chdir: directory
      )
      assert runs_status.success?, runs_stderr
      run_id = JSON.parse(runs_stdout).fetch("runs").first.fetch("id")

      selected_stdout, selected_stderr, selected_status = Open3.capture3(
        RbConfig.ruby, EXECUTABLE, "report", run_id, chdir: directory
      )
      assert selected_status.success?, selected_stderr
      assert_equal report, JSON.parse(selected_stdout)

      explain_stdout, explain_stderr, explain_status = Open3.capture3(
        RbConfig.ruby,
        EXECUTABLE,
        "explain",
        "--generation",
        report.fetch("generation").to_s,
        "lib/value.rb",
        chdir: directory
      )
      assert explain_status.success?, explain_stderr
      assert_equal report.fetch("generation"), JSON.parse(explain_stdout).fetch("generation")
      refute File.exist?(File.join(directory, "tmp/minitest-testmon/discovery.json"))
    end
  end

  def test_configured_report_retention_applies_to_cli_runs
    with_cli_project(retained_reports: 2) do |directory, marker|
      4.times do
        _stdout, stderr, status = invoke(directory, marker, "run")
        assert status.success?, stderr
      end

      store = Minitest::Testmon::Store.new(File.join(directory, ".minitest-testmon.sqlite3"))
      assert_equal 2, store.runs(limit: 10).length
      store.close
    end
  end

  def test_custom_file_read_claim_is_learned_reselected_and_relearned_in_normal_runs
    with_cli_project do |directory, marker|
      _stdout, stderr, cold = invoke(directory, marker, "run")
      assert cold.success?, stderr
      assert_equal true, read_report(directory).dig("publication", "published")

      _stdout, stderr, warm = invoke(directory, marker, "run")
      assert warm.success?, stderr
      assert_empty read_report(directory).dig("tests", "selected")

      write_file(File.join(directory, "templates/example.txt"), "template-v2\n")
      _stdout, stderr, changed = invoke(
        directory,
        marker,
        "run",
        {"EXPECTED_TEMPLATE" => "template-v2"}
      )
      assert changed.success?, stderr
      changed_report = read_report(directory)
      assert_equal ["ValueTest#test_plugin_is_registered_once"], changed_report.dig("tests", "selected")
      assert_equal true, changed_report.dig("publication", "published")

      _stdout, stderr, relearned = invoke(
        directory,
        marker,
        "run",
        {"EXPECTED_TEMPLATE" => "template-v2"}
      )
      assert relearned.success?, stderr
      assert_empty read_report(directory).dig("tests", "selected")
      assert_equal 4, File.readlines(marker).length
    end
  end

  def test_incomplete_provider_evidence_runs_once_and_returns_native_status
    with_project do |directory|
      marker = "#{directory}-executions.txt"
      data = write_file(File.join(directory, "data.txt"), "value\n")
      test_file = write_file(File.join(directory, "value_test.rb"), <<~RUBY)
        require "minitest/autorun"

        class ValueTest < Minitest::Test
          def test_direct_file_read
            File.open(ENV.fetch("EXECUTION_MARKER"), "a") do |file|
              file.puts "test"
            end
            if ENV["INCOMPLETE_PROVIDER"] == "1"
              assert_equal "value\n", File.read(#{data.dump})
            else
              pass
            end
          end
        end
      RUBY

      invoke = lambda do |incomplete: false|
        environment = {"EXECUTION_MARKER" => marker}
        environment["INCOMPLETE_PROVIDER"] = "1" if incomplete
        Open3.capture3(
          environment,
          RbConfig.ruby,
          EXECUTABLE,
          "run", "--full", "--",
          RbConfig.ruby,
          test_file,
          "--testmon",
          chdir: directory
        )
      end

      baseline_stdout, baseline_stderr, baseline_status = invoke.call
      assert baseline_status.success?, [baseline_stdout, baseline_stderr].join("\n")
      baseline = read_report(directory)
      assert_equal true, baseline.dig("publication", "published")
      baseline_generation = baseline.fetch("generation")

      stdout, stderr, status = invoke.call(incomplete: true)

      assert status.success?, [stdout, stderr].join("\n")
      assert_match(/Testmon cache unchanged: evidence could not be safely published \(provider_incomplete\)/, stderr)
      report = read_report(directory)
      assert_equal false, report.dig("publication", "published")
      assert_equal "provider_incomplete", report.dig("publication", "reason")
      assert_equal baseline_generation, report.fetch("generation")
      assert report.dig("observations", "unresolved", "items").any? { |item| item["reason"] == "opaque_c_call" }

      recovery_stdout, recovery_stderr, recovery_status = invoke.call
      assert recovery_status.success?, [recovery_stdout, recovery_stderr].join("\n")
      recovery = read_report(directory)
      assert_equal true, recovery.dig("publication", "published")
      assert_equal baseline_generation + 1, recovery.fetch("generation")
      assert_equal ["test", "test", "test"], File.readlines(marker, chomp: true)
    ensure
      FileUtils.rm_f(marker) if marker
    end
  end

  def test_repo_local_vendor_bundle_ruby_does_not_poison_publication
    with_project do |directory|
      vendored_relative_path = "vendor/bundle/ruby/4.0.0/gems/example/lib/vendor_value.rb"
      vendored_payload = write_file(
        File.join(directory, "vendor/bundle/ruby/4.0.0/gems/example/data/value.txt"),
        "42\n"
      )
      vendored_path = write_file(File.join(directory, vendored_relative_path), <<~RUBY)
        module VendorValue
          module_function

          def call
            Integer(File.read(#{vendored_payload.dump}))
          end
        end
      RUBY
      dependency_link = File.join(directory, "lib/vendor_value.rb")
      FileUtils.mkdir_p(File.dirname(dependency_link))
      File.symlink(vendored_path, dependency_link)
      test_file = write_file(File.join(directory, "test/value_test.rb"), <<~RUBY)
        require "minitest/autorun"

        class ValueTest < Minitest::Test
          def test_vendored_value
            require #{dependency_link.dump}
            assert_equal 42, VendorValue.call
          end
        end
      RUBY

      stdout, stderr, status = Open3.capture3(
        RbConfig.ruby,
        EXECUTABLE,
        "run", "--full", "--",
        RbConfig.ruby,
        test_file,
        "--testmon",
        chdir: directory
      )

      report = read_report(directory)
      inventory_paths = report.fetch("inventory").values.flat_map { |category| category.fetch("items") }
        .filter_map { |item| item["path"] }
      fatal_observation_paths = %w[uncovered unresolved].flat_map do |category|
        report.dig("observations", category, "items")
      end
        .flat_map { |item| [item["path"], item.dig("callsite", "path")] }
        .compact
      ignored_observations = report.dig("observations", "ignored", "items")
      vendored_logical_path = "project:#{vendored_relative_path}"

      assert_equal({
        native_success: true,
        executed_tests: ["ValueTest#test_vendored_value"],
        present_in_inventory: false,
        present_in_fatal_observations: false,
        ignored_dependency_read: true,
        publication: {"published" => true, "reason" => nil}
      }, {
        native_success: status.success?,
        executed_tests: report.dig("tests", "executed"),
        present_in_inventory: inventory_paths.include?(vendored_logical_path),
        present_in_fatal_observations: fatal_observation_paths.include?(vendored_logical_path),
        ignored_dependency_read: ignored_observations.any? do |item|
          item.fetch("reason") == "user_ignored" &&
            item.dig("callsite", "path") == vendored_logical_path
        end,
        publication: report.fetch("publication")
      }, [stdout, stderr, JSON.pretty_generate(report)].join("\n"))
    end
  end

  def test_full_suite_rails_wrapper_defers_plugin_loading_to_bundler
    with_project do |directory|
      marker = File.join(directory, "environment.json")
      config_marker = File.join(directory, "config-root.txt")
      rails = write_file(File.join(directory, "bin/rails"), <<~RUBY)
        #!/usr/bin/env ruby
        require "json"

        File.binwrite(ENV.fetch("WRAPPER_MARKER"), JSON.generate({
          rubyopt: ENV.fetch("RUBYOPT", "<unset>"),
          database: ENV.fetch("MINITEST_TESTMON_DB"),
          run_id: ENV.fetch("MINITEST_TESTMON_RUN_ID"),
          config: ENV.fetch("MINITEST_TESTMON_CONFIG"),
          project_root: ENV.fetch("MINITEST_TESTMON_PROJECT_ROOT"),
          cwd: Dir.pwd
        }))
      RUBY
      FileUtils.chmod(0o755, rails)
      write_file(File.join(directory, "config/application.rb"), "# Rails application marker\n")
      config = write_file(File.join(directory, ".minitest-testmon.rb"), <<~RUBY)
        Minitest::Testmon.configure do |configuration|
          File.binwrite(ENV.fetch("CONFIG_MARKER"), configuration.project_root)
          configuration.database "tmp/wrapper-state.sqlite3"
        end
      RUBY

      Dir.mktmpdir("minitest-testmon-caller") do |caller|
        launchers = [
          rails,
          Pathname(rails).relative_path_from(Pathname(caller)).to_s
        ]
        launchers.each do |launcher|
          command = [
            RbConfig.ruby,
            EXECUTABLE,
            "run",
            "--full", "--",
            launcher,
            "test"
          ]
          stdout, stderr, status = Open3.capture3(
            {
              "RUBYOPT" => nil,
              "WRAPPER_MARKER" => marker,
              "CONFIG_MARKER" => config_marker
            },
            *command,
            chdir: caller
          )

          assert status.success?, [stdout, stderr].join("\n")
          assert_match(/Testmon cache unchanged: evidence could not be safely published/, stderr)
          refute File.exist?(File.join(caller, ".minitest-testmon.sqlite3"))
          refute File.exist?(File.join(caller, ".minitest-testmon.rb"))
          refute File.exist?(File.join(caller, "tmp/minitest-testmon/discovery.json"))
        end
      end

      environment = JSON.parse(File.binread(marker))
      canonical_root = File.realpath(directory)
      refute_includes environment.fetch("rubyopt"), "minitest/testmon_plugin"
      assert_equal canonical_root, File.binread(config_marker)
      assert_equal File.join(canonical_root, "tmp/wrapper-state.sqlite3"), environment.fetch("database")
      assert_match(/\A[0-9a-f-]{36}\z/, environment.fetch("run_id"))
      assert_equal File.join(canonical_root, File.basename(config)), environment.fetch("config")
      assert_equal canonical_root, environment.fetch("project_root")
      assert_equal canonical_root, environment.fetch("cwd")
    end
  end

  def test_zero_exit_with_a_malformed_run_receipt_runs_once_and_returns_zero
    with_project do |directory|
      marker = File.join(directory, "executions.txt")
      command = write_file(File.join(directory, "write_invalid_report.rb"), <<~RUBY)
        File.open(ENV.fetch("EXECUTION_MARKER"), "a") do |file|
          file.puts "test"
        end

        require "sqlite3"

        database = SQLite3::Database.new(ENV.fetch("MINITEST_TESTMON_DB"))
        database.execute(
          "UPDATE run_receipts SET state='complete', report_json=?, finished_at='now' WHERE id=?",
          [ENV.fetch("INVALID_REPORT"), ENV.fetch("MINITEST_TESTMON_RUN_ID")]
        )
      RUBY
      ["not json", JSON.generate({"valid_json" => "not a Testmon report"})].each do |payload|
        stdout, stderr, status = Open3.capture3(
          {"INVALID_REPORT" => payload, "EXECUTION_MARKER" => marker},
          RbConfig.ruby,
          EXECUTABLE,
          "run",
          "--full", "--",
          RbConfig.ruby,
          command,
          chdir: directory
        )

        assert status.success?, [stdout, stderr].join("\n")
        assert_empty stdout
        assert_match(/Testmon cache unchanged: evidence could not be safely published/, stderr)
        assert_equal ["test"], File.readlines(marker, chomp: true)
        FileUtils.rm_f(marker)
      end
    end
  end

  def test_report_validation_requires_complete_and_diagnostics
    cli = Minitest::Testmon::CLI.new([])
    report = valid_report(mode: "run")

    assert cli.send(:valid_testmon_report?, report)
    refute cli.send(:valid_testmon_report?, report.except("complete"))
    refute cli.send(:valid_testmon_report?, report.merge("diagnostics" => [1]))
    refute cli.send(:valid_testmon_report?, report.merge("diagnostics" => ["source_drift"]))
    refute cli.send(:valid_testmon_report?, report.merge("complete" => false))
    refute cli.send(:valid_testmon_report?, report.merge("publication" => {"published" => false, "reason" => nil}))

    incomplete = report.merge("complete" => false, "ready" => false, "diagnostics" => [])
    assert cli.send(:valid_testmon_report?, incomplete)
  end

  def test_missing_run_receipt_runs_once_and_returns_native_status
    with_project do |directory|
      marker = File.join(directory, "executions.txt")
      command = write_file(File.join(directory, "no_report.rb"), <<~RUBY)
        File.open(ENV.fetch("EXECUTION_MARKER"), "a") do |file|
          file.puts "test"
        end
        exit Integer(ENV.fetch("NATIVE_STATUS", "0"))
      RUBY

      stdout, stderr, status = Open3.capture3(
        {"EXECUTION_MARKER" => marker},
        RbConfig.ruby,
        EXECUTABLE,
        "run",
        "--full", "--",
        RbConfig.ruby,
        command,
        chdir: directory
      )

      assert status.success?, stderr
      assert_empty stdout
      assert_match(/Testmon cache unchanged: evidence could not be safely published/, stderr)
      assert_equal ["test"], File.readlines(marker, chomp: true)
      refute File.exist?(File.join(directory, "tmp/minitest-testmon/discovery.json"))

      FileUtils.rm_f(marker)
      _stdout, _stderr, failed = Open3.capture3(
        {"EXECUTION_MARKER" => marker, "NATIVE_STATUS" => "7"},
        RbConfig.ruby,
        EXECUTABLE,
        "run",
        "--full", "--",
        RbConfig.ruby,
        command,
        chdir: directory
      )
      assert_equal 7, failed.exitstatus
      assert_equal ["test"], File.readlines(marker, chomp: true)
    end
  end

  def test_noncanonical_rails_wrapper_shapes_exit_two_before_spawn
    with_project do |directory|
      marker = File.join(directory, "spawned.txt")
      rails = write_file(File.join(directory, "bin/rails"), <<~RUBY)
        #!/usr/bin/env ruby
        File.binwrite(ENV.fetch("SPAWN_MARKER"), "spawned")
      RUBY
      FileUtils.chmod(0o755, rails)
      write_file(File.join(directory, "config/application.rb"), "# Rails application marker\n")

      Dir.mktmpdir("minitest-testmon-caller") do |caller|
        invalid_commands = [
          [rails, "test", "test/example_test.rb"],
          [RbConfig.ruby, rails, "test"],
          ["bundle", "exec", rails, "test"]
        ]
        invalid_commands.each do |child_command|
          stdout, stderr, status = Open3.capture3(
            {"SPAWN_MARKER" => marker},
            RbConfig.ruby,
            EXECUTABLE,
            "run",
            "--full", "--",
            *child_command,
            chdir: caller
          )

          assert_equal 2, status.exitstatus, [stdout, stderr].join("\n")
          assert_match(/exact bin\/rails test or bin\/rails test:all command/, stderr)
          refute File.exist?(marker)
        end
      end

      stdout, stderr, status = Open3.capture3(
        {"SPAWN_MARKER" => marker},
        RbConfig.ruby,
        EXECUTABLE,
        "run",
        "--full", "--",
        RbConfig.ruby,
        "-e",
        'File.binwrite(ENV.fetch("SPAWN_MARKER"), "spawned")',
        chdir: directory
      )

      assert_equal 2, status.exitstatus, [stdout, stderr].join("\n")
      assert_match(/exact bin\/rails test or bin\/rails test:all command/, stderr)
      refute File.exist?(marker)
    end
  end

  def test_rails_wrapper_rejects_configuration_that_replaces_the_project_root
    with_project do |directory|
      marker = File.join(directory, "spawned.txt")
      rails = write_file(File.join(directory, "bin/rails"), <<~RUBY)
        #!/usr/bin/env ruby
        File.binwrite(ENV.fetch("SPAWN_MARKER"), "spawned")
      RUBY
      FileUtils.chmod(0o755, rails)
      write_file(File.join(directory, "config/application.rb"), "# Rails application marker\n")

      Dir.mktmpdir("minitest-testmon-wrong-root") do |wrong_root|
        write_file(File.join(directory, ".minitest-testmon.rb"), <<~RUBY)
          Minitest::Testmon.configure do |configuration|
            configuration.root :project, #{wrong_root.inspect}
          end
        RUBY
        stdout, stderr, status = Open3.capture3(
          {"SPAWN_MARKER" => marker},
          RbConfig.ruby,
          EXECUTABLE,
          "run",
          "--full", "--",
          rails,
          "test",
          chdir: directory
        )

        assert_equal 2, status.exitstatus, [stdout, stderr].join("\n")
        assert_match(/:project.*canonical Rails application root/, stderr)
        refute File.exist?(marker)
        refute File.exist?(File.join(directory, ".minitest-testmon.sqlite3"))
        refute File.exist?(File.join(wrong_root, ".minitest-testmon.sqlite3"))
      end
    end
  end

  def test_rails_wrapper_rejects_inherited_default_test_filters_before_spawn
    with_project do |directory|
      marker = File.join(directory, "spawned.txt")
      state = write_file(File.join(directory, ".minitest-testmon.sqlite3"), "existing state")
      rails = write_file(File.join(directory, "bin/rails"), <<~RUBY)
        #!/usr/bin/env ruby
        File.binwrite(ENV.fetch("SPAWN_MARKER"), "spawned")
      RUBY
      FileUtils.chmod(0o755, rails)
      write_file(File.join(directory, "config/application.rb"), "# Rails application marker\n")

      %w[DEFAULT_TEST DEFAULT_TEST_EXCLUDE].each do |filter|
        stdout, stderr, status = Open3.capture3(
          {"SPAWN_MARKER" => marker, filter => "test/example_test.rb"},
          RbConfig.ruby,
          EXECUTABLE,
          "run",
          "--full", "--",
          rails,
          "test",
          chdir: directory
        )

        assert_equal 2, status.exitstatus, [stdout, stderr].join("\n")
        assert_match(/remove #{filter}/, stderr)
        refute File.exist?(marker)
        assert_equal "existing state", File.binread(state)
      end
    end
  end

  private

  def valid_report(mode:)
    {
      "schema_version" => 2,
      "mode" => mode,
      "complete" => true,
      "ready" => true,
      "diagnostics" => [],
      "generation" => 1,
      "context_signature" => "test-context",
      "bundles" => ["ruby@1"],
      "tests" => {
        "discovered" => [],
        "selected" => [],
        "executed" => []
      },
      "observations" => {},
      "inventory" => {},
      "suggestions" => [],
      "publication" => {
        "published" => true,
        "reason" => nil
      }
    }
  end

  def with_cli_project(retained_reports: nil)
    with_project do |directory|
      marker = "#{directory}-executions"
      write_file(File.join(directory, ".minitest-testmon.rb"), <<~RUBY)
        require "minitest/testmon"

        Minitest::Testmon.configure do |config|
          #{"config.retained_reports #{retained_reports}" if retained_reports}
          config.provider :templates, version: 1 do |provider|
            provider.inventory :templates,
              root: :project,
              include: "templates/**/*.txt"
            provider.facet :content,
              inventory: :templates,
              digest: :content,
              granularity: :file,
              scope: :test
            provider.claim :file_read,
              to: %i[templates content],
              path: :path
          end
        end
      RUBY
      write_file(File.join(directory, "templates/example.txt"), "template-v1\n")
      write_file(File.join(directory, "lib/value.rb"), <<~RUBY)
        module Value
          module_function

          def call
            1
          end
        end
      RUBY
      write_file(File.join(directory, "test/value_test.rb"), <<~RUBY)
        require "minitest/autorun"
        require_relative "../lib/value"

        class ValueTest < Minitest::Test
          def test_plugin_is_registered_once
            assert_equal 1, Minitest.extensions.count { |extension| extension.to_s == "testmon" }
            assert_equal 1, Value.call
            template = File.expand_path("../templates/example.txt", __dir__)
            actual = File.open(template, &:read).chomp
            assert_equal ENV.fetch("EXPECTED_TEMPLATE", "template-v1"), actual
          end

          def test_failure_status
            flunk "planted failure" if ENV["PLANT_FAILURE"] == "1"
            pass
          end

          ENV.fetch("GENERATED_CASES", "").split(",").reject(&:empty?).each do |name|
            define_method("test_generated_\#{name}") { assert_equal name, name }
          end
        end
      RUBY
      write_file(File.join(directory, "run_tests.rb"), <<~RUBY)
        File.open(ENV.fetch("EXECUTION_MARKER"), "a") { |file| file.puts(Process.pid) }
        load File.expand_path("test/value_test.rb", __dir__)
      RUBY

      yield directory, marker
    ensure
      FileUtils.rm_f(marker) if marker
    end
  end

  def invoke(directory, marker, mode, environment = {}, test_arguments: [], full: false)
    verb = [mode, ("--full" if full)].compact
    command = [
      RbConfig.ruby,
      EXECUTABLE,
      *verb,
      "--",
      RbConfig.ruby,
      "run_tests.rb",
      *test_arguments
    ]
    Open3.capture3(
      {"EXECUTION_MARKER" => marker}.merge(environment),
      *command,
      chdir: directory
    )
  end

  def read_report(directory)
    store = Minitest::Testmon::Store.new(File.join(directory, ".minitest-testmon.sqlite3"))
    report = store.report
    store.close
    report
  end
end

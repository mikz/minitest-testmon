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
    assert_equal "usage: minitest-testmon discover|run|report|runs|explain\n", stdout
    assert_empty stderr

    stdout, stderr, invalid = Open3.capture3(RbConfig.ruby, EXECUTABLE, "unknown")
    refute invalid.success?
    assert_equal 2, invalid.exitstatus
    assert_empty stdout
    assert_equal "usage: minitest-testmon discover|run|report|runs|explain\n", stderr
  end

  def test_discover_preloads_the_plugin_runs_every_test_and_preserves_failure_status
    with_cli_project do |directory, marker|
      _stdout, stderr, status = invoke(directory, marker, "discover", {"PLANT_FAILURE" => "1"})

      refute status.success?, stderr
      report = read_report(directory)
      assert_equal "discover", report.fetch("mode")
      assert_equal report.dig("tests", "discovered"), report.dig("tests", "selected")
      assert_equal report.dig("tests", "discovered"), report.dig("tests", "executed")
      assert_equal 2, report.dig("tests", "executed").length
      assert_equal({"published" => false, "reason" => "test_failure"}, report.fetch("publication"))
    end
  end

  def test_successful_discover_publishes_a_warm_baseline
    with_cli_project do |directory, marker|
      _stdout, stderr, discovered = invoke(directory, marker, "discover")
      assert discovered.success?, stderr
      discovery_report = read_report(directory)
      assert_equal true, discovery_report.dig("publication", "published")
      assert_equal discovery_report.dig("tests", "discovered"), discovery_report.dig("tests", "executed")

      _stdout, stderr, warm = invoke(directory, marker, "run")
      assert warm.success?, stderr
      warm_report = read_report(directory)
      assert_empty warm_report.dig("tests", "selected")
      assert_empty warm_report.dig("tests", "executed")
      assert_equal 1, File.readlines(marker).length
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
      assert_equal 1, File.readlines(marker).length
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
      assert_equal 2, File.readlines(marker).length
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
            "discover",
            "--",
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

          assert_equal 4, status.exitstatus, [stdout, stderr].join("\n")
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

  def test_zero_exit_with_a_malformed_run_receipt_fails_closed
    with_project do |directory|
      command = write_file(File.join(directory, "write_invalid_report.rb"), <<~RUBY)
        require "sqlite3"

        database = SQLite3::Database.new(ENV.fetch("MINITEST_TESTMON_DB"))
        database.execute(
          "UPDATE run_receipts SET state='complete', report_json=?, finished_at='now' WHERE id=?",
          [ENV.fetch("INVALID_REPORT"), ENV.fetch("MINITEST_TESTMON_RUN_ID")]
        )
      RUBY
      ["not json", JSON.generate({"valid_json" => "not a Testmon report"})].each do |payload|
        stdout, stderr, status = Open3.capture3(
          {"INVALID_REPORT" => payload},
          RbConfig.ruby,
          EXECUTABLE,
          "discover",
          "--",
          RbConfig.ruby,
          command,
          chdir: directory
        )

        assert_equal 4, status.exitstatus, [stdout, stderr].join("\n")
        assert_empty stdout
      end
    end
  end

  def test_discover_requires_its_exact_run_receipt
    with_project do |directory|
      command = write_file(File.join(directory, "no_report.rb"), "# successful child without a report\n")

      stdout, stderr, status = Open3.capture3(
        RbConfig.ruby,
        EXECUTABLE,
        "discover",
        "--",
        RbConfig.ruby,
        command,
        chdir: directory
      )

      assert_equal 4, status.exitstatus, stderr
      assert_empty stdout
      refute File.exist?(File.join(directory, "tmp/minitest-testmon/discovery.json"))
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
            "discover",
            "--",
            *child_command,
            chdir: caller
          )

          assert_equal 2, status.exitstatus, [stdout, stderr].join("\n")
          assert_match(/exact bin\/rails test command/, stderr)
          refute File.exist?(marker)
        end
      end

      stdout, stderr, status = Open3.capture3(
        {"SPAWN_MARKER" => marker},
        RbConfig.ruby,
        EXECUTABLE,
        "discover",
        "--",
        RbConfig.ruby,
        "-e",
        'File.binwrite(ENV.fetch("SPAWN_MARKER"), "spawned")',
        chdir: directory
      )

      assert_equal 2, status.exitstatus, [stdout, stderr].join("\n")
      assert_match(/exact bin\/rails test command/, stderr)
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
          "discover",
          "--",
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
          "discover",
          "--",
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
      "ready" => true,
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

  def with_cli_project
    with_project do |directory|
      marker = "#{directory}-executions"
      write_file(File.join(directory, ".minitest-testmon.rb"), <<~RUBY)
        require "minitest/testmon"

        Minitest::Testmon.configure do |config|
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

  def invoke(directory, marker, mode, environment = {})
    command = [
      RbConfig.ruby,
      EXECUTABLE,
      mode,
      "--",
      RbConfig.ruby,
      "run_tests.rb"
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

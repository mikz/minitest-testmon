# frozen_string_literal: true

require_relative "test_helper"
require "json"
require "open3"
require "rbconfig"

class RailsBootstrapTest < TestmonTestCase
  GEM_ROOT = File.expand_path("..", __dir__)
  LIB_ROOT = File.join(GEM_ROOT, "lib")

  def test_conventional_entrypoint_is_inert_without_an_activation_request
    with_project do |project|
      script = <<~RUBY
        module Rails
          class Railtie
          end
        end

        ENV["MINITEST_TESTMON_DB"] = File.join(Dir.pwd, "state.sqlite3")
        ARGV.replace(["test"])
        require "minitest-testmon"

        puts $LOADED_FEATURES.any? { |feature| feature.end_with?("/minitest-testmon.rb") }
        puts $LOADED_FEATURES.any? { |feature| feature.end_with?("/minitest/testmon_plugin.rb") }
        puts defined?(Minitest::Testmon::Railtie).nil?
        puts defined?(Minitest::Testmon::Runtime).nil?
      RUBY
      stdout, stderr, status = invoke_bootstrap(project, script)

      assert status.success?, stderr
      assert_equal %w[true false true true], stdout.lines(chomp: true)
      refute File.exist?(File.join(project, "state.sqlite3"))
      refute File.exist?(File.join(project, "report.json"))
    end
  end

  def test_conventional_entrypoint_rejects_invalid_options_without_loading_core
    cases = [
      [%w[--testmon-db=state.sqlite3], /--testmon-db requires --testmon/],
      [%w[--testmon=value], /--testmon does not accept a value/]
    ]
    cases.each do |arguments, message|
      with_project do |project|
        feature_marker = File.join(project, "core-loaded")
        test_marker = File.join(project, "test-ran")
        script = <<~RUBY
          ARGV.replace(#{arguments.inspect})
          require "minitest-testmon"
          at_exit do
            loaded = $LOADED_FEATURES.any? { |feature| feature.end_with?("/minitest/testmon.rb") }
            File.binwrite(#{feature_marker.inspect}, loaded.to_s)
          end
          require "minitest/autorun"

          class InvalidOptionTestmonCase < Minitest::Test
            def test_result
              File.binwrite(#{test_marker.inspect}, "ran")
            end
          end
        RUBY
        _stdout, stderr, status = invoke_bootstrap(project, script)

        assert_equal 2, status.exitstatus, arguments.inspect
        assert_match message, stderr
        refute_match(/NameError|uninitialized constant|\n\s+from /, stderr)
        assert_equal "false", File.binread(feature_marker)
        refute File.exist?(test_marker)
        refute File.exist?(File.join(project, "state.sqlite3"))
        refute File.exist?(File.join(project, "report.json"))
        refute File.exist?(File.join(project, ".minitest-testmon.sqlite3"))
        refute File.exist?(File.join(project, "tmp/minitest-testmon/discovery.json"))
      end
    end
  end

  def test_railtie_auxiliary_option_rejects_without_loading_core
    with_project do |project|
      feature_marker = File.join(project, "core-loaded")
      test_marker = File.join(project, "test-ran")
      script = <<~RUBY
        module Rails
          class RailtieConfiguration
            attr_reader :callback

            def before_configuration(&block)
              @callback = block
            end
          end

          class Railtie
            def self.config
              @config ||= RailtieConfiguration.new
            end

            def self.initializer(name, &block)
              (@initializers ||= []) << [name, block]
            end
          end

          module Command
            TestCommand = Class.new

            def self.application_root
              Dir.pwd
            end
          end
        end

        module Rake
          Application = Struct.new(:top_level_tasks)

          def self.application
            @application ||= Application.new(["test:prepare"])
          end
        end

        ARGV.replace(["--testmon-db=state.sqlite3"])
        require "minitest-testmon"
        Minitest::Testmon::Railtie.config.callback.call
        at_exit do
          loaded = $LOADED_FEATURES.any? { |feature| feature.end_with?("/minitest/testmon.rb") }
          File.binwrite(#{feature_marker.inspect}, loaded.to_s)
        end
        require "minitest/autorun"

        class RailsAuxiliaryOptionTestmonCase < Minitest::Test
          def test_result
            File.binwrite(#{test_marker.inspect}, "ran")
          end
        end
      RUBY
      _stdout, stderr, status = invoke_bootstrap(project, script)

      assert_equal 2, status.exitstatus
      assert_match(/--testmon-db requires --testmon/, stderr)
      refute_match(/NameError|uninitialized constant|\n\s+from /, stderr)
      assert_equal "false", File.binread(feature_marker)
      refute File.exist?(test_marker)
      refute File.exist?(File.join(project, "state.sqlite3"))
      refute File.exist?(File.join(project, ".minitest-testmon.sqlite3"))
      refute File.exist?(File.join(project, "tmp/minitest-testmon/discovery.json"))
    end
  end

  def test_railtie_callback_owns_early_activation_and_uses_the_application_root
    with_project do |project|
      input = write_file(File.join(project, "inputs/application.yml"), "value: one\n")
      write_file(File.join(project, ".minitest-testmon.rb"), <<~RUBY)
        module ApplicationBodyLoader
          module_function

          def read(path)
            File.binread(path)
          end
        end

        Minitest::Testmon.configure do |config|
          config.provider :application_body, version: 1 do |provider|
            provider.inventory :inputs,
              root: :project,
              include: "inputs/**/*.yml"
            provider.facet :content,
              inventory: :inputs,
              digest: :content,
              granularity: :file,
              scope: :suite
            provider.observe_tracepoint :application_body_read,
              target: [ApplicationBodyLoader, :read],
              event: :call,
              path: ->(trace) { trace.local(:path) }
            provider.claim :application_body_read,
              to: %i[inputs content],
              path: :path
          end
        end
      RUBY
      script = <<~RUBY
        module Rails
          class RailtieConfiguration
            attr_reader :callback

            def before_configuration(&block)
              @callback = block
            end
          end

          class Railtie
            def self.config
              @config ||= RailtieConfiguration.new
            end

            def self.initializer(name, &block)
              (@initializers ||= []) << [name, block]
            end
          end

          module Command
            TestCommand = Class.new

            def self.application_root
              Dir.pwd
            end
          end
        end

        module Rake
          Application = Struct.new(:top_level_tasks)

          def self.application
            @application ||= Application.new(["test:prepare"])
          end
        end

        ARGV.replace(["--testmon"])
        require "minitest-testmon"
        railtie = Minitest::Testmon::Railtie

        puts $LOADED_FEATURES.any? { |feature| feature.end_with?("/minitest/testmon_plugin.rb") }
        puts defined?(Minitest::Testmon::Runtime).nil?
        railtie.config.callback.call
        ApplicationBodyLoader.read(#{input.inspect})
        observations = Minitest::Testmon.take_early_observations

        puts ENV.fetch("MINITEST_TESTMON_PROJECT_ROOT")
        puts ENV.fetch("MINITEST_TESTMON_CONFIG")
        puts Minitest.extensions.count { |extension| extension.to_s == "testmon" }
        puts observations.any? { |observation|
          observation.kind == :application_body_read &&
            observation.path == File.realpath(#{input.inspect})
        }
      RUBY
      stdout, stderr, status = invoke_bootstrap(project, script)

      assert status.success?, stderr
      assert_equal [
        "false",
        "true",
        File.realpath(project),
        File.join(File.realpath(project), ".minitest-testmon.rb"),
        "1",
        "true"
      ], stdout.lines(chomp: true)
      refute File.exist?(File.join(project, ".minitest-testmon.sqlite3"))
      refute File.exist?(File.join(project, "tmp/minitest-testmon/discovery.json"))
    end
  end

  def test_railtie_rejects_configuration_that_replaces_the_application_root
    with_project do |project|
      Dir.mktmpdir("minitest-testmon-wrong-root") do |wrong_root|
        write_file(File.join(project, ".minitest-testmon.rb"), <<~RUBY)
          Minitest::Testmon.configure do |configuration|
            configuration.root :project, #{wrong_root.inspect}
          end
        RUBY
        script = <<~RUBY
          module Rails
            class RailtieConfiguration
              attr_reader :callback

              def before_configuration(&block)
                @callback = block
              end
            end

            class Railtie
              def self.config
                @config ||= RailtieConfiguration.new
              end

              def self.initializer(name, &block)
                (@initializers ||= []) << [name, block]
              end
            end

            module Command
              TestCommand = Class.new

              def self.application_root
                Dir.pwd
              end
            end
          end

          module Rake
            Application = Struct.new(:top_level_tasks)

            def self.application
              @application ||= Application.new(["test:prepare"])
            end
          end

          ARGV.replace(["--testmon"])
          require "minitest-testmon"
          at_exit do
            puts $LOADED_FEATURES.any? { |feature| feature.end_with?("/minitest/testmon_plugin.rb") }
            puts Minitest::Testmon.instance_variable_get(:@early_observer).nil?
          end
          Minitest::Testmon::Railtie.config.callback.call
        RUBY
        stdout, stderr, status = invoke_bootstrap(project, script)

        assert_equal 2, status.exitstatus
        assert_equal %w[true true], stdout.lines(chomp: true)
        assert_match(/:project.*canonical Rails application root/, stderr)
        assert_equal 1, stderr.lines.length
        refute File.exist?(File.join(project, ".minitest-testmon.sqlite3"))
        refute File.exist?(File.join(project, "tmp/minitest-testmon/discovery.json"))
        refute File.exist?(File.join(wrong_root, ".minitest-testmon.sqlite3"))
      end
    end
  end

  def test_direct_flag_loads_project_configuration_before_early_custom_observers_start
    with_project do |project|
      input = write_file(File.join(project, "inputs/value.yml"), "value: one\n")
      write_file(File.join(project, ".minitest-testmon.rb"), <<~RUBY)
        module EarlyConfigLoader
          module_function

          def read(path)
            File.binread(path)
          end
        end

        Minitest::Testmon.configure do |config|
          config.provider :early_config, version: 1 do |provider|
            provider.inventory :inputs,
              root: :project,
              include: "inputs/**/*.yml"
            provider.facet :content,
              inventory: :inputs,
              digest: :content,
              granularity: :file,
              scope: :suite
            provider.observe_tracepoint :config_read,
              target: [EarlyConfigLoader, :read],
              event: :call,
              path: ->(trace) { trace.local(:path) }
            provider.claim :config_read,
              to: %i[inputs content],
              path: :path
          end
        end
      RUBY

      script = <<~RUBY
        require "minitest/testmon/rails_bootstrap"

        first = Minitest::Testmon::RailsBootstrap.call(
          %w[--testmon],
          application_root: Dir.pwd,
          test_command: true,
          rake_test_prepare: true
        )
        second = Minitest::Testmon::RailsBootstrap.call(
          %w[--testmon],
          application_root: Dir.pwd,
          test_command: true,
          rake_test_prepare: true
        )
        EarlyConfigLoader.read(#{input.inspect})
        observations = Minitest::Testmon.take_early_observations

        puts first
        puts second
        puts ENV.fetch("MINITEST_TESTMON_CONFIG")
        puts Minitest.extensions.count { |extension| extension.to_s == "testmon" }
        puts observations.any? { |observation| observation.kind == :config_read && observation.path == File.realpath(#{input.inspect}) }
      RUBY
      stdout, stderr, status = invoke_bootstrap(project, script)

      assert status.success?, stderr
      assert_equal [
        "true",
        "true",
        File.join(File.realpath(project), ".minitest-testmon.rb"),
        "1",
        "true"
      ], stdout.lines(chomp: true)
      refute File.exist?(File.join(project, ".minitest-testmon.sqlite3"))
      refute File.exist?(File.join(project, "tmp/minitest-testmon/discovery.json"))
    end
  end

  def test_plain_test_command_is_completely_inert
    with_project do |project|
      script = <<~RUBY
        require "minitest/testmon/rails_bootstrap"

        puts Minitest::Testmon::RailsBootstrap.call(
          [],
          application_root: Dir.pwd,
          test_command: true,
          rake_test_prepare: true
        )
        puts $LOADED_FEATURES.any? { |feature| feature.end_with?("/minitest/testmon_plugin.rb") }
        puts defined?(Minitest::Testmon::Runtime).nil?
        puts Minitest::Testmon.instance_variable_get(:@early_observer).nil?
        puts ENV.key?("MINITEST_TESTMON")
      RUBY
      stdout, stderr, status = invoke_bootstrap(project, script)

      assert status.success?, stderr
      assert_equal %w[false false true true false], stdout.lines(chomp: true)
      refute File.exist?(File.join(project, ".minitest-testmon.sqlite3"))
      refute File.exist?(File.join(project, "tmp/minitest-testmon/discovery.json"))
    end
  end

  def test_help_without_testmon_is_inert_at_the_bundler_boundary
    with_project do |project|
      script = <<~RUBY
        require "minitest/testmon/rails_bootstrap"

        $stdout.sync = false
        puts Minitest::Testmon::RailsBootstrap.call(
          %w[--help],
          application_root: Dir.pwd,
          test_command: true,
          rake_test_prepare: true
        )
        puts $LOADED_FEATURES.any? { |feature| feature.end_with?("/minitest/testmon_plugin.rb") }
        puts defined?(Minitest::Testmon::Runtime).nil?
        puts Minitest::Testmon.instance_variable_get(:@early_observer).nil?
        puts $stdout.sync
      RUBY
      stdout, stderr, status = invoke_bootstrap(project, script)

      assert status.success?, stderr
      assert_equal %w[false false true true false], stdout.lines(chomp: true)
    end
  end

  def test_testmon_help_is_flushed_before_minitest_exits_immediately
    with_project do |project|
      script = <<~RUBY
        require "minitest/testmon/rails_bootstrap"

        $stdout.sync = false
        Minitest::Testmon::RailsBootstrap.call(
          %w[--testmon --help],
          application_root: Dir.pwd,
          test_command: true,
          rake_test_prepare: true
        )
        Minitest.run(%w[--testmon --help])
      RUBY
      stdout, stderr, status = invoke_bootstrap(project, script)

      assert status.success?, stderr
      assert_includes stdout, "--testmon"
      assert_includes stdout, "--testmon-db"
      refute_includes stdout, "--testmon-report"
      assert_empty stderr
      refute File.exist?(File.join(project, ".minitest-testmon.sqlite3"))
      refute File.exist?(File.join(project, "tmp/minitest-testmon/discovery.json"))
    end
  end

  def test_non_help_testmon_run_preserves_stdout_buffering
    with_project do |project|
      script = <<~RUBY
        require "minitest/testmon/rails_bootstrap"

        $stdout.sync = false
        puts Minitest::Testmon::RailsBootstrap.call(
          %w[--testmon],
          application_root: Dir.pwd,
          test_command: true,
          rake_test_prepare: true
        )
        puts $stdout.sync
      RUBY
      stdout, stderr, status = invoke_bootstrap(project, script)

      assert status.success?, stderr
      assert_equal %w[true false], stdout.lines(chomp: true)
    end
  end

  def test_non_test_rails_command_does_not_load_the_plugin
    with_project do |project|
      script = <<~RUBY
        require "minitest/testmon/rails_bootstrap"

        puts Minitest::Testmon::RailsBootstrap.call(
          [],
          application_root: Dir.pwd,
          test_command: false,
          rake_test_prepare: false
        )
        puts $LOADED_FEATURES.any? { |feature| feature.end_with?("/minitest/testmon_plugin.rb") }
      RUBY
      stdout, stderr, status = invoke_bootstrap(project, script)

      assert status.success?, stderr
      assert_equal %w[false false], stdout.lines(chomp: true)
    end
  end

  def test_testmon_options_reject_non_default_rails_commands_before_activation
    [
      [%w[--testmon], false, false],
      [%w[--testmon-db=tmp/state.sqlite3], false, true],
      [%w[--testmon], true, false]
    ].each do |arguments, test_command, rake_test_prepare|
      with_project do |project|
        assert_early_usage_rejection(
          project,
          arguments,
          /--testmon requires a complete Rails test suite \(bin\/rails test or bin\/rails test:all\)/,
          test_command: test_command,
          rake_test_prepare: rake_test_prepare
        )
      end
    end
  end

  def test_testmon_rejects_explicit_rails_environment_options_before_activation
    [
      %w[--testmon --environment development],
      %w[--environment=test --testmon],
      %w[-e test --testmon],
      %w[--testmon -etest]
    ].each do |arguments|
      with_project do |project|
        assert_early_usage_rejection(
          project,
          arguments,
          /remove Rails environment options/
        )
      end
    end
  end

  def test_direct_flag_preserves_clean_and_native_failure_exit_statuses
    with_project do |project|
      write_file(File.join(project, "lib/value.rb"), <<~RUBY)
        module DirectTestmonValue
          VALUE = 1
        end
      RUBY
      body = <<~RUBY
        require File.expand_path("lib/value", Dir.pwd)
        assert_equal 1, DirectTestmonValue::VALUE
      RUBY
      _stdout, stderr, clean = invoke_direct_testmon(project, body)

      assert_equal 0, clean.exitstatus, stderr
      cold_report = read_report(project)
      assert_equal true, cold_report.dig("publication", "published")
      assert_operator cold_report.dig("inventory", "claimed", "count"), :>, 0

      _stdout, stderr, warm = invoke_direct_testmon(project, body)
      assert_equal 0, warm.exitstatus, stderr
      warm_report = read_report(project)
      assert_empty warm_report.dig("tests", "executed")
      assert_equal inventory_fingerprints(cold_report), inventory_fingerprints(warm_report)
    end

    with_project do |project|
      _stdout, stderr, failed = invoke_direct_testmon(project, 'flunk "planted failure"')

      assert_equal 1, failed.exitstatus, stderr
      assert_equal(
        {"published" => false, "reason" => "test_failure"},
        read_report(project).fetch("publication")
      )
    end
  end

  def test_environment_activated_rails_run_rejects_default_test_filters_in_the_child
    %w[DEFAULT_TEST DEFAULT_TEST_EXCLUDE].each do |filter|
      with_project do |project|
        marker = File.join(project, "test-body-ran")
        script = <<~RUBY
          ENV["MINITEST_TESTMON"] = "1"
          ENV[#{filter.inspect}] = "test/example_test.rb"
          require "minitest/testmon/rails_bootstrap"
          Minitest::Testmon::RailsBootstrap.call(
            [],
            application_root: Dir.pwd,
            test_command: true,
            rake_test_prepare: true
          )
          ARGV.clear
          require "minitest/autorun"

          class WrappedRailsTestmonCase < Minitest::Test
            def test_result
              File.binwrite(#{marker.inspect}, "ran")
              pass
            end
          end
        RUBY
        _stdout, stderr, status = invoke_bootstrap(project, script)

        assert_equal 2, status.exitstatus, filter
        assert_match(/remove #{filter}/, stderr)
        refute File.exist?(marker)
        refute File.exist?(File.join(project, ".minitest-testmon.sqlite3"))
        refute File.exist?(File.join(project, "tmp/minitest-testmon/discovery.json"))
      end
    end
  end

  def test_direct_flag_uses_exit_four_for_incomplete_provider_evidence
    with_project do |project|
      write_file(File.join(project, "inputs/value.yml"), "value: one\n")
      write_file(File.join(project, ".minitest-testmon.rb"), <<~RUBY)
        Minitest::Testmon.configure do |config|
          config.provider :unavailable_observer, version: 1 do |provider|
            provider.inventory :inputs,
              root: :project,
              include: "inputs/**/*.yml"
            provider.facet :content,
              inventory: :inputs,
              digest: :content,
              granularity: :file
            provider.observe_tracepoint :config_read,
              target: "MissingTracepointTarget.call"
            provider.claim :config_read,
              to: %i[inputs content],
              path: :path
          end
        end
      RUBY

      _stdout, stderr, status = invoke_direct_testmon(project, "pass")

      assert_equal 4, status.exitstatus, stderr
      report = read_report(project)
      assert_equal false, report.dig("publication", "published")
      assert_equal "provider_incomplete", report.dig("publication", "reason")
      assert_equal ["DirectTestmonCase#test_result"], report.dig("tests", "executed")
    end
  end

  def test_invalid_default_configuration_exits_two_without_creating_state
    with_project do |project|
      write_file(File.join(project, ".minitest-testmon.rb"), <<~RUBY)
        Minitest::Testmon.configure do |config|
          config.fileset :invalid, include: "config/**/*.yml", scope: :invalid
        end
      RUBY
      script = <<~RUBY
        require "minitest/testmon/rails_bootstrap"
        Minitest::Testmon::RailsBootstrap.call(
          %w[--testmon],
          application_root: Dir.pwd,
          test_command: true,
          rake_test_prepare: true
        )
      RUBY

      stdout, stderr, status = invoke_bootstrap(project, script)

      assert_equal 2, status.exitstatus
      assert_empty stdout
      assert_match(/filesets are always suite-scoped/, stderr)
      refute_match(/\n\\s+from /, stderr)
      refute File.exist?(File.join(project, ".minitest-testmon.sqlite3"))
      refute File.exist?(File.join(project, "tmp/minitest-testmon/discovery.json"))
    end
  end

  def test_syntax_error_in_default_configuration_exits_two_without_a_backtrace
    with_project do |project|
      assert_configuration_evaluation_error(
        project,
        "Minitest::Testmon.configure do |\n",
        "SyntaxError"
      )
    end
  end

  def test_name_error_in_default_configuration_exits_two_without_a_backtrace
    with_project do |project|
      assert_configuration_evaluation_error(
        project,
        "MissingTestmonConfigurationConstant.call\n",
        "NameError"
      )
    end
  end

  private

  def assert_early_usage_rejection(
    project,
    arguments,
    message,
    test_command: true,
    rake_test_prepare: true
  )
    script = <<~RUBY
      require "minitest/testmon/rails_bootstrap"

      at_exit do
        puts $LOADED_FEATURES.any? { |feature| feature.end_with?("/minitest/testmon_plugin.rb") }
        puts ENV.key?("MINITEST_TESTMON")
        puts ENV.key?("MINITEST_TESTMON_CONFIG")
        puts defined?(Minitest::Testmon::Runtime).nil?
      end

      Minitest::Testmon::RailsBootstrap.call(
        #{arguments.inspect},
        application_root: Dir.pwd,
        test_command: #{test_command},
        rake_test_prepare: #{rake_test_prepare}
      )
    RUBY
    stdout, stderr, status = invoke_bootstrap(project, script)

    assert_equal 2, status.exitstatus, arguments.inspect
    assert_equal %w[false false false true], stdout.lines(chomp: true), arguments.inspect
    assert_match message, stderr, arguments.inspect
    assert_equal 1, stderr.lines.length, arguments.inspect
    refute File.exist?(File.join(project, ".minitest-testmon.sqlite3")), arguments.inspect
    refute File.exist?(File.join(project, "tmp/minitest-testmon/discovery.json")), arguments.inspect
  end

  def assert_configuration_evaluation_error(project, source, error_class)
    write_file(File.join(project, ".minitest-testmon.rb"), source)
    script = <<~RUBY
      require "minitest/testmon/rails_bootstrap"
      Minitest::Testmon::RailsBootstrap.call(
        %w[--testmon],
        application_root: Dir.pwd,
        test_command: true,
        rake_test_prepare: true
      )
    RUBY
    stdout, stderr, status = invoke_bootstrap(project, script)

    assert_equal 2, status.exitstatus
    assert_empty stdout
    assert_match(
      /invalid Testmon configuration .*\.minitest-testmon\.rb.*: #{error_class}:/,
      stderr
    )
    assert_equal 1, stderr.lines.length
    refute File.exist?(File.join(project, ".minitest-testmon.sqlite3"))
    refute File.exist?(File.join(project, "tmp/minitest-testmon/discovery.json"))
  end

  def invoke_bootstrap(project, script)
    Open3.capture3(
      {
        "MINITEST_TESTMON" => nil,
        "MINITEST_TESTMON_CONFIG" => nil,
        "MINITEST_TESTMON_PROJECT_ROOT" => nil,
        "MINITEST_TESTMON_RAILS_COMMAND" => nil,
        "MINITEST_TESTMON_RAILS_FLAG" => nil,
        "MINITEST_TESTMON_DB" => nil,
        "DEFAULT_TEST" => nil,
        "DEFAULT_TEST_EXCLUDE" => nil
      },
      RbConfig.ruby,
      "-I#{LIB_ROOT}",
      "-e",
      script,
      chdir: project
    )
  end

  def invoke_direct_testmon(project, test_body)
    test_file = write_file(File.join(project, "test/direct_testmon_case_test.rb"), <<~RUBY)
      class DirectTestmonCase < Minitest::Test
        def test_result
          #{test_body}
        end
      end
    RUBY
    script = <<~RUBY
      require "minitest/testmon/rails_bootstrap"

      Minitest::Testmon::RailsBootstrap.call(
        %w[--testmon],
        application_root: Dir.pwd,
        test_command: true,
        rake_test_prepare: true
      )
      ARGV.replace(["--testmon"])
      require "minitest/autorun"
      require #{test_file.inspect}
    RUBY
    invoke_bootstrap(project, script)
  end

  def read_report(project)
    store = Minitest::Testmon::Store.new(File.join(project, ".minitest-testmon.sqlite3"))
    report = store.report
    store.close
    report
  end

  def inventory_fingerprints(report)
    report.fetch("inventory").values.flat_map { |category| category.fetch("items") }
      .to_h { |item| [item.fetch("key"), item.fetch("fingerprint")] }
  end
end

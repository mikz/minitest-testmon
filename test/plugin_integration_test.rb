# frozen_string_literal: true

require_relative "test_helper"
require "json"
require "open3"
require "rbconfig"

class PluginIntegrationTest < TestmonTestCase
  GEM_ROOT = File.expand_path("..", __dir__)
  LIB_ROOT = File.join(GEM_ROOT, "lib")
  MAX_NESTED_REPORT_BYTES = 256 * 1024

  def test_testmon_loaded_before_minitest_reporters_and_rails_initializes_last
    assert_reporter_compatibility(:testmon_first)
  end

  def test_testmon_loaded_after_minitest_reporters_and_rails_initializes_last
    assert_reporter_compatibility(:testmon_last)
  end

  def test_duplicate_minitest_load_is_normalized_and_finalizes_once
    assert_reporter_compatibility(:duplicate_testmon)
  end

  def test_nested_path_gem_excludes_only_its_own_canonical_root
    with_project do |directory|
      nested_gem = File.join(directory, "gems/minitest-testmon")
      FileUtils.mkdir_p(nested_gem)
      FileUtils.cp_r(File.join(GEM_ROOT, "lib"), nested_gem)
      FileUtils.cp_r(File.join(GEM_ROOT, "exe"), nested_gem)
      write_file(File.join(directory, "lib/value.rb"), <<~RUBY)
        module Value
          module_function

          def call
            Other.call
          end
        end
      RUBY
      write_file(File.join(directory, "gems/other/lib/other.rb"), <<~RUBY)
        module Other
          module_function

          def call
            1
          end
        end
      RUBY
      write_file(File.join(directory, "test/value_test.rb"), <<~RUBY)
        require "minitest/autorun"
        require_relative "../gems/other/lib/other"
        require_relative "../lib/value"

        class ValueTest < Minitest::Test
          def test_value
            assert_equal 1, Value.call
          end
        end
      RUBY

      stdout, stderr, status = Open3.capture3(
        {"BUNDLE_GEMFILE" => nil, "RUBYLIB" => nil, "RUBYOPT" => nil},
        RbConfig.ruby,
        File.join(nested_gem, "exe/minitest-testmon"),
        "run",
        "--full",
        "--",
        RbConfig.ruby,
        "-Itest",
        "test/value_test.rb",
        chdir: directory
      )
      assert status.success?, "nested path-gem discovery failed:\n#{stdout}\n#{stderr}"

      report = read_report(directory)
      assert_operator Minitest::Testmon::CanonicalJSON.generate(report).bytesize, :<, MAX_NESTED_REPORT_BYTES
      assert_equal true, report.dig("publication", "published")
      assert_empty report.dig("observations", "unresolved", "items")

      paths = report.fetch("inventory").values.flat_map { |category| category.fetch("items") }
        .filter_map { |item| item["path"] }
      observation_paths = report.fetch("observations").values.flat_map { |category| category.fetch("items") }
        .filter_map { |item| item["path"] }
      refute (paths + observation_paths).any? { |item| item.start_with?("project:gems/minitest-testmon/") },
        "nested minitest-testmon source leaked into its host inventory or observations"
      assert paths.any? { |item| item == "project:gems/other/lib/other.rb" },
        "the self-exclusion widened to another nested gem"
    end
  end

  def test_gem_root_is_not_excluded_when_it_is_the_project_root
    script = <<~RUBY
      require "minitest/testmon"

      configuration = Minitest::Testmon.configuration.snapshot
      snapshot = Minitest::Testmon.registry.snapshot(configuration)
      expected = File.expand_path("lib/minitest/testmon.rb")
      puts snapshot.ruby_inventory_paths.include?(expected)
    RUBY
    stdout, stderr, status = Open3.capture3(
      RbConfig.ruby,
      "-I#{LIB_ROOT}",
      "-e",
      script,
      chdir: GEM_ROOT
    )

    assert status.success?, stderr
    assert_equal "true\n", stdout
  end

  private

  def assert_reporter_compatibility(order)
    marker = nil
    with_project do |directory|
      marker = "#{directory}-executions"
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
          def test_value
            File.open(ENV.fetch("EXECUTION_MARKER"), "a") { |file| file.puts(Process.pid) }
            assert_equal 1, Minitest.extensions.count { |extension| extension.to_s == "testmon" }
            assert_equal "testmon", Minitest.extensions.last.to_s
            assert_equal 1, Value.call
          end
        end
      RUBY
      write_file(File.join(directory, "run_tests.rb"), runner(order))

      discovery = invoke(directory, marker, full: true)
      assert discovery.fetch(:status).success?,
        "#{order} discovery failed:\n#{discovery.fetch(:stdout)}\n#{discovery.fetch(:stderr)}"
      discovered = read_report(directory)
      assert_equal true, discovered.dig("publication", "published"),
        "#{order} did not publish:\n#{JSON.pretty_generate(discovered)}"
      assert_equal ["ValueTest#test_value"], discovered.dig("tests", "executed")
      assert_equal 1, discovered.fetch("generation")

      warm = invoke(directory, marker)
      assert warm.fetch(:status).success?,
        "#{order} warm run failed:\n#{warm.fetch(:stdout)}\n#{warm.fetch(:stderr)}"
      report = read_report(directory)
      assert_empty report.dig("tests", "selected"),
        "#{order} warm run selected tests:\n#{JSON.pretty_generate(report)}"
      assert_empty report.dig("tests", "executed"),
        "#{order} warm run executed tests:\n#{JSON.pretty_generate(report)}"
      assert_equal 1, File.readlines(marker).length
    end
  ensure
    FileUtils.rm_f(marker) if marker
  end

  def runner(order)
    setup = <<~RUBY
      require "minitest/reporters"
      Minitest.load :minitest_reporter
      Minitest::Reporters.use!

      module Minitest
        def self.plugin_rails_options(_parser, _options)
        end

        def self.plugin_rails_init(_options)
        end

        register_plugin :rails
      end
    RUBY

    requires = case order
    when :testmon_first
      <<~RUBY
        require "minitest/testmon_plugin"
        #{setup}
      RUBY
    when :testmon_last
      <<~RUBY
        #{setup}
        require "minitest/testmon_plugin"
      RUBY
    when :duplicate_testmon
      <<~RUBY
        require "minitest/testmon_plugin"
        Minitest.load :testmon
        #{setup}
      RUBY
    else
      raise "unknown order: #{order}"
    end

    <<~RUBY
      require "minitest"
      #{requires}
      load File.expand_path("test/value_test.rb", __dir__)
    RUBY
  end

  def invoke(directory, marker, full: false)
    stdout, stderr, status = Open3.capture3(
      {
        "EXECUTION_MARKER" => marker,
        "MINITEST_TESTMON" => "1",
        # A forced full relearn (the collapsed replacement for `discover`).
        "MINITEST_TESTMON_FULL" => full ? "1" : nil,
        "MINITEST_TESTMON_DB" => File.join(directory, ".minitest-testmon.sqlite3")
      },
      RbConfig.ruby,
      "-I#{LIB_ROOT}",
      "run_tests.rb",
      chdir: directory
    )
    {stdout: stdout, stderr: stderr, status: status}
  end

  def read_report(directory)
    store = Minitest::Testmon::Store.new(File.join(directory, ".minitest-testmon.sqlite3"))
    report = store.report
    store.close
    report
  end
end

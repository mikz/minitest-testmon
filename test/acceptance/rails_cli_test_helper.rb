# frozen_string_literal: true

require_relative "rails_test_helper"

module RailsCliProductAcceptance
  include RailsProductAcceptance

  def with_rails_cli_project(workers: 1)
    project = MinitestTestmonAcceptance::Project.copy_fixture("rails_app")
    runtime = MinitestTestmonAcceptance::RailsRuntime.new(project, workers:)
    require_rails_dependencies!(runtime)
    runtime.prepare
    yield project, runtime, MinitestTestmonAcceptance::RailsCliDriver.new(project)
  ensure
    runtime&.cleanup
    project&.cleanup
  end

  def learn_cli_baseline(project, runtime, cli, extra_env: {}, repeated: false)
    result = cli.flagged(env: runtime.env.merge(extra_env), repeated:)
    assert_equal 0, result.exitstatus, cli_failure("Rails CLI baseline", result)
    report = cli.report
    assert_report_contract report
    assert_cli_oracle { MinitestTestmonAcceptance::RailsCliOracle.assert_full_cold!(report) }
    report
  end

  def run_cli(
    runtime,
    cli,
    extra_env: {},
    arguments: [],
    command: "test",
    repeated: false,
    timeout: MinitestTestmonAcceptance::RailsCliDriver::DEFAULT_TIMEOUT
  )
    result = cli.flagged(
      env: runtime.env.merge(extra_env),
      arguments:,
      command:,
      repeated:,
      timeout:
    )
    report = cli.report if cli.state_path.file?
    assert_report_contract report if report
    [result, report]
  end

  def assert_cli_oracle
    assert yield
  rescue MinitestTestmonAcceptance::RailsCliOracle::Mismatch => error
    flunk error.message
  end

  def cli_failure(label, result)
    "#{label} failed (#{result.exitstatus.inspect}):\n#{result.stdout}\n#{result.stderr}"
  end

  def replace_cli_fixture(project, path, before, after)
    original = project.read(path)
    changed = original.sub(before, after)
    refute_equal original, changed, "fixture mutation did not find #{before.inspect} in #{path}"
    project.write(path, changed)
  end

  def assert_certified_inventory(cold, warm, cli)
    cold_inventory = cold.fetch("inventory")
    warm_inventory = warm.fetch("inventory")
    persisted_inventory = cli.published_inventory

    assert cold_inventory == warm_inventory,
      "certified warm report exposed run-local inventory instead of its cold published graph"
    assert cold_inventory == persisted_inventory,
      "cold report inventory differs from the persisted published graph"
    assert warm_inventory == persisted_inventory,
      "certified warm report inventory differs from the persisted published graph"
  end

  def assert_configuration_rejected_before_evidence(result, error_class:, project:, cli:, marker:)
    output = [result.stdout, result.stderr].join("\n")
    output_lines = output.lines(chomp: true).reject(&:empty?)
    worker_spool = project.path.join("tmp/minitest-testmon/workers")

    assert_equal 2, result.exitstatus, cli_failure("#{error_class} configuration", result)
    assert_includes output, error_class
    refute_match(/(?:\tfrom |:\d+:in [`'])/, output, "configuration error exposed a Ruby backtrace")
    assert_operator output_lines.length, :<=, 12, "configuration error was not concise"
    assert_empty cli.state_files, "configuration error created Testmon state"
    refute worker_spool.exist?, "configuration error created a worker spool"
    refute marker.exist?, "configuration error reached a test body"
  end

  def assert_no_worker_spools(project)
    worker_root = project.path.join("tmp/minitest-testmon/workers")
    assert_empty worker_root.children if worker_root.directory?
  end

  def marker_test_ids(path)
    return [] unless path.file?

    path.readlines(chomp: true).map { |line| line.split(":", 2).fetch(1) }.sort
  end

  def wait_for_cli(message, timeout: 15)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until yield
      flunk message if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      sleep 0.02
    end
  end
end

# frozen_string_literal: true

require_relative "rails_test_helper"

class RailsAcceptanceTest < Minitest::Test
  include RailsProductAcceptance

  KILLED_WORKER_DEADLINE = 15
  SupervisedRun = Data.define(:status, :stdout, :stderr, :timed_out) do
    def success?
      !timed_out && status&.success?
    end
  end

  def test_rails_bundles_auto_activate_claim_their_files_and_warm_run_executes_nothing
    with_rails_project(workers: 2) do |project, runtime|
      baseline = learn_rails_baseline(project, runtime)
      assert_provider_claim baseline,
        provider: "rails.boot@1",
        path_suffix: "config/initializers/acceptance_boot.rb"
      assert_provider_claim baseline,
        provider: "rails.schema@1",
        path_suffix: "db/schema.rb"
      assert_provider_claim baseline,
        provider: "rails.views@1",
        path_suffix: "app/views/greetings/_message.html.erb",
        facet: "content"
      assert_provider_claim baseline,
        provider: "rails.locales@1",
        path_suffix: "config/locales/en.yml"
      assert_provider_claim baseline,
        provider: "rails.fixtures@1",
        path_suffix: "test/fixtures/widgets.yml"

      marker = project.path.join("tmp/warm-test-marker")
      result, report = run_rails(project, runtime, extra_env: {
        "RAILS_ACCEPTANCE_TEST_MARKER" => marker.to_s
      })
      assert result.success?, rails_failure("unchanged warm run", result)
      assert_equal true, report.dig("publication", "published")
      MinitestTestmonAcceptance::RailsOracle.assert_warm_zero!(report)
      refute marker.exist?, "unchanged warm run reached an application test setup"
    end
  end

  def test_rails_umbrella_disable_turns_off_all_five_providers
    with_rails_project do |project, runtime|
      project.write(".minitest-testmon.rb", <<~RUBY)
        # frozen_string_literal: true

        require "minitest/testmon"

        Minitest::Testmon.configure { |config| config.disable_bundle :rails_8_1 }
      RUBY

      result = driver.discover(project, env: runtime.env)
      assert result.success?, rails_failure("Rails discovery with disabled umbrella", result)
      report = driver.report(project)
      assert_report_contract report
      assert_empty MinitestTestmonAcceptance::RailsOracle::BUNDLES & report.fetch("bundles")
      refute_includes report.fetch("bundles"), "rails_8_1"
    end
  end

  def test_process_workers_one_two_and_four_publish_equivalent_evidence
    reports = [1, 2, 4].map do |workers|
      with_rails_project(workers:) do |project, runtime|
        learn_rails_baseline(project, runtime)
        replace(project, "app/views/greetings/_message.html.erb", "template v1", "template v2")

        result, report = run_rails(project, runtime, extra_env: {
          "EXPECTED_TEMPLATE" => "Hello from template v2"
        })
        assert result.success?, rails_failure("Rails run with #{workers} workers", result)
        assert_only_selected report, "GreetingsControllerTest#test_show"
        report
      end
    end

    MinitestTestmonAcceptance::RailsOracle.assert_equivalent!(reports)
  end

  def test_thread_parallelization_is_rejected_before_tests_and_preserves_generation
    with_rails_project do |project, runtime|
      baseline = learn_rails_baseline(project, runtime)
      marker = project.path.join("tmp/thread-test-marker")
      result = driver.run(project, env: runtime.env.merge(
        "PARALLEL_WORKERS" => "2",
        "PARALLEL_MODE" => "threads",
        "RAILS_ACCEPTANCE_TEST_MARKER" => marker.to_s
      ))
      report = driver.report(project)
      assert_report_contract report

      MinitestTestmonAcceptance::RailsOracle.assert_rejected_before_marker!(
        result:,
        report:,
        marker:
      )
      assert_equal baseline.fetch("generation"), report.fetch("generation")
      assert_equal baseline.fetch("inventory"), report.fetch("inventory"),
        "thread rejection changed the last published dependency edges"
      assert_empty report.dig("tests", "executed")
    end
  end

  def test_template_content_change_selects_only_its_rendering_test
    with_rails_project do |project, runtime|
      learn_rails_baseline(project, runtime)
      replace(project, "app/views/greetings/_message.html.erb", "template v1", "template v2")

      result, report = run_rails(project, runtime, extra_env: {
        "EXPECTED_TEMPLATE" => "Hello from template v2"
      })
      assert result.success?, rails_failure("template content change", result)
      assert_only_selected report, "GreetingsControllerTest#test_show"
      assert_provider_claim report,
        provider: "rails.views@1",
        path_suffix: "app/views/greetings/_message.html.erb",
        facet: "content"
      assert_not_selected report, "UnrelatedTest#test_unrelated"
    end
  end

  def test_template_membership_add_delete_and_rename_select_view_consumers
    with_rails_project do |project, runtime|
      learn_rails_baseline(project, runtime)
      project.write("app/views/greetings/optional.html.erb", "<p>Optional</p>\n")

      added_result, added_report = run_rails(project, runtime, extra_env: {
        "EXPECT_OPTIONAL_TEMPLATE" => "1"
      })
      assert added_result.success?, rails_failure("template membership addition", added_result)
      assert_selected_includes added_report, "GreetingViewLookupTest#test_optional_template_membership"
      assert_not_selected added_report, "UnrelatedTest#test_unrelated"
      assert_provider_claim added_report, provider: "rails.views@1", facet: "membership"

      project.remove("app/views/greetings/optional.html.erb")
      deleted_result, deleted_report = run_rails(project, runtime)
      assert deleted_result.success?, rails_failure("template membership deletion", deleted_result)
      assert_selected_includes deleted_report, "GreetingViewLookupTest#test_optional_template_membership"
      assert_not_selected deleted_report, "UnrelatedTest#test_unrelated"
    end

    with_rails_project do |project, runtime|
      learn_rails_baseline(project, runtime)
      FileUtils.mv(
        project.path.join("app/views/greetings/show.html.erb"),
        project.path.join("app/views/greetings/show_moved.html.erb")
      )

      result, report = run_rails(project, runtime)
      refute result.success?, "renamed rendered template unexpectedly passed"
      assert_selected_includes report, "GreetingsControllerTest#test_show"
      assert_not_selected report, "UnrelatedTest#test_unrelated"
      assert_equal false, report.dig("publication", "published")
    end
  end

  def test_locale_change_selects_only_the_translation_consumer
    with_rails_project do |project, runtime|
      learn_rails_baseline(project, runtime)
      replace(project, "config/locales/en.yml", "locale v1", "locale v2")

      result, report = run_rails(project, runtime, extra_env: {
        "EXPECTED_LOCALE" => "Hello from locale v2"
      })
      assert result.success?, rails_failure("locale change", result)
      assert_only_selected report, "LocaleTest#test_locale"
      assert_provider_claim report,
        provider: "rails.locales@1",
        path_suffix: "config/locales/en.yml"
      assert_not_selected report, "UnrelatedTest#test_unrelated"
    end
  end

  def test_declared_and_manual_fixture_changes_select_their_consumers
    with_rails_project do |project, runtime|
      learn_rails_baseline(project, runtime)
      replace(project, "test/fixtures/widgets.yml", "widget v1", "widget v2")

      result, report = run_rails(project, runtime, extra_env: {
        "EXPECTED_FIXTURE" => "Fixture widget v2"
      })
      assert result.success?, rails_failure("declared fixture change", result)
      assert_only_selected report, "WidgetTest#test_declared_fixture"
      assert_provider_claim report,
        provider: "rails.fixtures@1",
        path_suffix: "test/fixtures/widgets.yml"
    end

    with_rails_project do |project, runtime|
      learn_rails_baseline(project, runtime)
      replace(project, "test/manual_fixtures/manual_widgets.yml", "widget v1", "widget v2")

      result, report = run_rails(project, runtime, extra_env: {
        "EXPECTED_MANUAL_FIXTURE" => "Manual fixture widget v2"
      })
      assert result.success?, rails_failure("manual FixtureSet change", result)
      assert_only_selected report, "ManualFixtureTest#test_manual_fixture_load"
      assert_provider_claim report,
        provider: "rails.fixtures@1",
        path_suffix: "test/manual_fixtures/manual_widgets.yml"
    end
  end

  def test_boot_and_schema_changes_each_select_the_full_suite
    assert_suite_scoped_change(
      "config/initializers/acceptance_boot.rb",
      provider: "rails.boot@1"
    )
    assert_suite_scoped_change(
      "db/schema.rb",
      provider: "rails.schema@1"
    )
  end

  def test_killed_worker_does_not_publish_and_recovery_keeps_its_tests_dirty
    with_rails_project(workers: 2) do |project, runtime|
      baseline = learn_rails_baseline(project, runtime)
      generation = baseline.fetch("generation")
      replace(project, "app/views/greetings/_message.html.erb", "template v1", "template v2")

      interrupted = supervise_rails(
        project,
        runtime,
        extra_env: {
          "EXPECTED_TEMPLATE" => "Hello from template v2",
          "RAILS_ACCEPTANCE_KILL_TEST" => "test_show"
        },
        timeout: KILLED_WORKER_DEADLINE
      )
      refute interrupted.success?,
        "worker-kill run unexpectedly passed: #{interrupted.stdout}\n#{interrupted.stderr}"
      interrupted_report = driver.report(project)
      assert_report_contract interrupted_report
      assert_equal generation, interrupted_report.fetch("generation")
      assert_equal baseline.fetch("inventory"), interrupted_report.fetch("inventory"),
        "externally interrupted worker run changed the last published dependency edges"
      if interrupted_report.dig("publication", "published") == false
        assert_equal "worker_incomplete", interrupted_report.dig("publication", "reason")
      end

      recovery = supervise_rails(
        project,
        runtime,
        extra_env: {"EXPECTED_TEMPLATE" => "Hello from template v2"},
        timeout: KILLED_WORKER_DEADLINE
      )
      assert recovery.success?,
        "bounded worker-kill recovery failed or timed out: #{recovery.stdout}\n#{recovery.stderr}"
      recovery_report = driver.report(project)
      assert_report_contract recovery_report
      assert_equal recovery_report.dig("tests", "discovered"), recovery_report.dig("tests", "selected"),
        "dead-lease recovery did not force a full clean selection"
      assert_equal recovery_report.dig("tests", "discovered"), recovery_report.dig("tests", "executed")
      assert_equal true, recovery_report.dig("publication", "published")
      assert_equal generation + 1, recovery_report.fetch("generation")
    end
  end

  def test_simplecov_loaded_before_testmon_preserves_selection_and_writes_coverage
    assert_simplecov_interoperation(:before)
  end

  def test_simplecov_loaded_after_testmon_preserves_selection_and_writes_coverage
    assert_simplecov_interoperation(:after)
  end

  def test_rails_observation_does_not_replace_public_framework_apis
    with_rails_project do |project, runtime|
      clean_path = project.path.join("tmp/clean-rails-api.json")
      active_path = project.path.join("tmp/active-rails-api.json")
      cli = MinitestTestmonAcceptance::RailsCliDriver.new(project)

      clean = cli.plain(
        env: runtime.env.merge("RAILS_ACCEPTANCE_API_SNAPSHOT" => clean_path.to_s)
      )
      assert clean.success?, rails_failure("plain stock Rails API probe", clean)

      active = driver.discover(
        project,
        env: runtime.env.merge("RAILS_ACCEPTANCE_API_SNAPSHOT" => active_path.to_s)
      )
      assert active.success?, rails_failure("active Rails API probe", active)
      refute_includes active.stderr, "ActiveSupport::Concurrency::LoadInterlockAwareMonitor"
      assert_equal JSON.parse(clean_path.read), JSON.parse(active_path.read),
        "observer changed Rails method owners, signatures, source locations, or ancestors"
    end
  end

  def test_process_workers_never_open_the_parent_sqlite_state
    skip "lsof is required to observe worker file descriptors" unless executable_on_path?("lsof")

    with_rails_project(workers: 2) do |project, runtime|
      learn_rails_baseline(project, runtime)
      project.write(
        "config/initializers/acceptance_boot.rb",
        "#{project.read("config/initializers/acceptance_boot.rb")}\n# force suite-scoped selection\n"
      )

      barrier = project.path.join("tmp/worker-barrier")
      release = barrier.join("release")
      stdout_path = project.path.join("tmp/sqlite-owner.stdout")
      stderr_path = project.path.join("tmp/sqlite-owner.stderr")
      FileUtils.mkdir_p(barrier)
      owner_pid = nil

      begin
        owner_pid = Process.spawn(
          runtime.env.merge("RAILS_ACCEPTANCE_BARRIER" => barrier.to_s),
          *driver.bin,
          "run",
          "--",
          *project.test_command,
          chdir: project.path.to_s,
          out: stdout_path.to_s,
          err: stderr_path.to_s,
          pgroup: true
        )
        wait_for("two Rails process workers did not reach the descriptor barrier") do
          barrier.glob("worker-*").length >= 2
        end

        worker_pids = barrier.glob("worker-*").map { |path| path.basename.to_s.delete_prefix("worker-").to_i }
        state_paths = Dir["#{driver.state_path(project)}*"].select { |path| File.file?(path) }
        refute_empty state_paths, "parent state files disappeared while the run was active"
        open_pids = state_paths.flat_map { |path| lsof_pids(path) }.uniq
        assert_empty worker_pids & open_pids,
          "Rails process workers opened parent-owned SQLite state: workers=#{worker_pids.inspect} open=#{open_pids.inspect}"

        release.write("release")
        _, status = Process.wait2(owner_pid)
        owner_pid = nil
        assert status.success?, "barrier run failed: #{stdout_path.read}\n#{stderr_path.read}"
        assert_report_contract driver.report(project)
      ensure
        release.write("release") unless release.exist?
        terminate_process_group(owner_pid)
      end
    end
  end

  private

  def run_rails(project, runtime, extra_env: {})
    result = driver.run(project, env: runtime.env.merge(extra_env))
    report = driver.report(project)
    assert_report_contract report
    [result, report]
  end

  def replace(project, path, before, after)
    original = project.read(path)
    changed = original.sub(before, after)
    refute_equal original, changed, "fixture mutation did not find #{before.inspect} in #{path}"
    project.write(path, changed)
  end

  def assert_only_selected(report, fragment)
    test_id = find_test_id(report, fragment)
    assert_equal [test_id], report.dig("tests", "selected")
    assert_equal [test_id], report.dig("tests", "executed")
    test_id
  end

  def assert_not_selected(report, fragment)
    test_id = find_test_id(report, fragment)
    refute_includes report.dig("tests", "selected"), test_id
  end

  def assert_provider_claim(report, provider:, path_suffix: nil, facet: nil)
    assert MinitestTestmonAcceptance::RailsOracle.assert_provider_claim!(
      report,
      provider:,
      path_suffix:,
      facet:
    )
  rescue MinitestTestmonAcceptance::RailsOracle::Mismatch => error
    flunk error.message
  end

  def assert_suite_scoped_change(path, provider:)
    with_rails_project do |project, runtime|
      learn_rails_baseline(project, runtime)
      project.write(path, "#{project.read(path)}\n# suite-scoped acceptance mutation\n")

      result, report = run_rails(project, runtime)
      assert result.success?, rails_failure("suite-scoped #{path} change", result)
      assert_equal report.dig("tests", "discovered"), report.dig("tests", "selected")
      assert_equal report.dig("tests", "discovered"), report.dig("tests", "executed")
      assert_equal true, report.dig("publication", "published")
      assert_provider_claim report, provider:, path_suffix: path
    end
  end

  def assert_simplecov_interoperation(order)
    with_rails_project(workers: 2) do |project, runtime|
      coverage = project.path.join("tmp/simplecov-#{order}")
      env = {"RAILS_ACCEPTANCE_COVERAGE_DIR" => coverage.to_s}
      if order == :before
        preload = "-r#{project.path.join("test/support/simplecov_before.rb")}"
        env["RUBYOPT"] = [ENV["RUBYOPT"], preload].compact.reject(&:empty?).join(" ")
      else
        env["SIMPLECOV_ORDER"] = "after"
      end

      learn_rails_baseline(project, runtime, extra_env: env)
      replace(project, "app/views/greetings/_message.html.erb", "template v1", "template v2")
      result, report = run_rails(project, runtime, extra_env: env.merge(
        "EXPECTED_TEMPLATE" => "Hello from template v2"
      ))
      assert result.success?, rails_failure("SimpleCov #{order} load order", result)
      assert_only_selected report, "GreetingsControllerTest#test_show"

      resultset = coverage.join(".resultset.json")
      assert resultset.file?, "SimpleCov #{order} did not write #{resultset}"
      parsed = JSON.parse(resultset.read)
      assert_kind_of Hash, parsed
      refute_empty parsed, "SimpleCov #{order} wrote an empty result set"
    end
  end

  def rails_failure(label, result)
    "#{label} failed (#{result.exitstatus}):\n#{result.stdout}\n#{result.stderr}"
  end

  def supervise_rails(project, runtime, extra_env:, timeout:)
    stdout_path = project.path.join("tmp/supervised-#{Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)}.stdout")
    stderr_path = Pathname("#{stdout_path.to_s.delete_suffix(".stdout")}.stderr")
    FileUtils.mkdir_p(stdout_path.dirname)
    pid = Process.spawn(
      runtime.env.merge(extra_env),
      *driver.bin,
      "run",
      "--",
      *project.test_command,
      chdir: project.path.to_s,
      out: stdout_path.to_s,
      err: stderr_path.to_s,
      pgroup: true
    )
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    status = nil

    until status
      waited = Process.waitpid2(pid, Process::WNOHANG)
      status = waited&.last
      break if status || Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      sleep 0.02
    end

    timed_out = status.nil?
    terminate_process_group(pid) if timed_out
    pid = nil
    SupervisedRun.new(
      status:,
      stdout: stdout_path.read,
      stderr: stderr_path.read,
      timed_out:
    )
  ensure
    terminate_process_group(pid)
  end

  def executable_on_path?(name)
    ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? do |directory|
      File.executable?(File.join(directory, name))
    end
  end

  def lsof_pids(path)
    stdout, _stderr, status = Open3.capture3("lsof", "-t", path)
    return [] unless status.success?

    stdout.lines.filter_map { |line| Integer(line, exception: false) }
  end

  def terminate_process_group(pid)
    return unless pid

    Process.kill("KILL", -pid)
    Process.wait(pid)
  rescue Errno::ESRCH, Errno::ECHILD
    nil
  end
end

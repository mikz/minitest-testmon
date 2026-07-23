# frozen_string_literal: true

module MinitestTestmonAcceptance
  RailsCliState = Data.define(:database_files, :report_bytes)
  RailsCliProcess = Data.define(:pid, :argv, :stdout_path, :stderr_path, :started_at)

  class RailsCliDriver
    DEFAULT_TIMEOUT = 45

    attr_reader :state_path, :report_path

    def initialize(project)
      @project = project
      @state_path = project.path.join("tmp/rails-cli/state.sqlite3")
      @report_path = project.path.join("tmp/rails-cli/report.json")
      verify_stock_command!
    end

    def flagged(
      env:,
      arguments: [],
      leading_arguments: [],
      command: "test",
      repeated: false,
      timeout: DEFAULT_TIMEOUT
    )
      invoke(
        flagged_argv(arguments:, leading_arguments:, command:, repeated:),
        env: activation_env.merge(env),
        timeout:
      )
    end

    def plain(env:, arguments: [], command: "test", timeout: DEFAULT_TIMEOUT)
      invoke([rails_bin, command, *arguments], env:, timeout:)
    end

    def wrapped(
      env:,
      mode: "run",
      explicit_paths: true,
      chdir: @project.path,
      timeout: DEFAULT_TIMEOUT
    )
      options = if explicit_paths
        ["--database", state_path.to_s, "--report", report_path.to_s]
      else
        []
      end
      invoke(
        [
          RbConfig.ruby,
          testmon_executable.to_s,
          mode,
          *options,
          "--",
          rails_bin,
          "test"
        ],
        env:,
        timeout:,
        chdir:
      )
    end

    def start_flagged(env:, arguments: [], leading_arguments: [], command: "test", repeated: false)
      start(
        flagged_argv(arguments:, leading_arguments:, command:, repeated:),
        env: activation_env.merge(env)
      )
    end

    def finish(process, timeout: DEFAULT_TIMEOUT)
      status = wait_for(process.pid, timeout:)
      timed_out = status.nil?
      status = terminate(process.pid) if timed_out
      stdout = process.stdout_path.read
      stderr = process.stderr_path.read
      stderr = "#{stderr}\nRails CLI command timed out after #{timeout}s" if timed_out
      CommandResult.new(argv: process.argv, status:, stdout:, stderr:)
    ensure
      terminate(process.pid) if process && process_alive?(process.pid)
    end

    def report
      raise "missing Rails CLI report: #{report_path}" unless report_path.file?

      JSON.parse(report_path.read)
    end

    def published_inventory
      script = <<~RUBY
        require "json"
        require "minitest/testmon"

        begin
          store = Minitest::Testmon::Store.new(ARGV.fetch(0))
          puts JSON.generate(store.published_inventory)
        ensure
          store&.close
        end
      RUBY
      env = {
        "BUNDLE_GEMFILE" => MinitestTestmonAcceptance::GEMFILE.to_s
      }
      stdout, stderr, status = Open3.capture3(
        env,
        RbConfig.ruby,
        "-rbundler/setup",
        "-e",
        script,
        state_path.to_s,
        chdir: @project.path.to_s
      )
      raise "failed to read published inventory: #{stderr}" unless status.success?

      JSON.parse(stdout)
    end

    def lease_count
      script = <<~RUBY
        require "sqlite3"

        begin
          database = SQLite3::Database.new(ARGV.fetch(0))
          puts database.get_first_value("SELECT COUNT(*) FROM leases")
        ensure
          database&.close
        end
      RUBY
      env = {
        "BUNDLE_GEMFILE" => MinitestTestmonAcceptance::GEMFILE.to_s
      }
      stdout, stderr, status = Open3.capture3(
        env,
        RbConfig.ruby,
        "-rbundler/setup",
        "-e",
        script,
        state_path.to_s,
        chdir: @project.path.to_s
      )
      raise "failed to read cache leases: #{stderr}" unless status.success?

      Integer(stdout)
    end

    def snapshot
      database_files = Dir["#{state_path}*"].sort.to_h do |path|
        [File.basename(path), File.binread(path)]
      end
      RailsCliState.new(
        database_files:,
        report_bytes: report_path.file? ? report_path.binread : nil
      )
    end

    def state_files
      Dir["#{state_path}*"].sort
    end

    def rails_bin
      @project.path.join("bin/rails").to_s
    end

    def flagged_argv(arguments: [], leading_arguments: [], command: "test", repeated: false)
      flags = ["--testmon"]
      flags.unshift("--testmon") if repeated
      [rails_bin, command, *leading_arguments, *flags, *arguments]
    end

    private

    def activation_env
      {
        "MINITEST_TESTMON_DB" => state_path.to_s,
        "MINITEST_TESTMON_REPORT" => report_path.to_s
      }
    end

    def testmon_executable
      MinitestTestmonAcceptance::EXECUTABLE
    end

    def verify_stock_command!
      command = Pathname(rails_bin)
      raise "missing fixture Rails command: #{command}" unless command.file?
      raise "fixture Rails command is not executable: #{command}" unless command.executable?
    end

    def invoke(argv, env:, timeout:, chdir: @project.path)
      process = start(argv, env:, chdir:)
      finish(process, timeout:)
    end

    def start(argv, env:, chdir: @project.path)
      output = @project.path.join("tmp/rails-cli/commands/#{SecureRandom.uuid}")
      FileUtils.mkdir_p(output.dirname)
      stdout_path = Pathname("#{output}.stdout")
      stderr_path = Pathname("#{output}.stderr")
      child_env = env.merge(
        "RAILS_ACCEPTANCE_BUNDLE_GEMFILE" => MinitestTestmonAcceptance::GEMFILE.to_s
      )
      pid = Process.spawn(
        child_env,
        *argv,
        chdir: chdir.to_s,
        out: stdout_path.to_s,
        err: stderr_path.to_s,
        pgroup: true
      )
      RailsCliProcess.new(
        pid:,
        argv:,
        stdout_path:,
        stderr_path:,
        started_at: Process.clock_gettime(Process::CLOCK_MONOTONIC)
      )
    end

    def wait_for(pid, timeout:)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      loop do
        waited = Process.waitpid2(pid, Process::WNOHANG)
        return waited.last if waited
        return if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

        sleep 0.02
      end
    rescue Errno::ECHILD
      nil
    end

    def terminate(pid)
      Process.kill("TERM", -pid)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
      loop do
        waited = Process.waitpid2(pid, Process::WNOHANG)
        return waited.last if waited
        break if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

        sleep 0.02
      end
      Process.kill("KILL", -pid)
      Process.waitpid2(pid).last
    rescue Errno::ESRCH, Errno::ECHILD
      nil
    end

    def process_alive?(pid)
      Process.kill(0, pid)
      true
    rescue Errno::ESRCH
      false
    end
  end
end

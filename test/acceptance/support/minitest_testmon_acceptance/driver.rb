# frozen_string_literal: true

module MinitestTestmonAcceptance
  CommandResult = Data.define(:argv, :status, :stdout, :stderr) do
    def success?
      status.success?
    end

    def exitstatus
      status.exitstatus
    end
  end

  class Driver
    STATE_PATH = Pathname(".minitest-testmon.sqlite3")

    attr_reader :bin

    def initialize(
      bin: ENV.fetch(
        "MINITEST_TESTMON_BIN",
        Shellwords.join([RbConfig.ruby, MinitestTestmonAcceptance::EXECUTABLE.to_s])
      )
    )
      @bin = Shellwords.split(bin)
      raise ArgumentError, "MINITEST_TESTMON_BIN must not be empty" if @bin.empty?
    end

    def available?
      executable = bin.first
      return File.executable?(executable) if executable.include?(File::SEPARATOR)

      ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? do |directory|
        File.executable?(File.join(directory, executable))
      end
    end

    def run(project, command: project.test_command, env: {}, full: false)
      flags = full ? ["--full"] : []
      invoke(project, "run", *flags, "--", *command, env: env)
    end

    def explain(project, test_id, env: {})
      invoke(project, "explain", test_id, env: env)
    end

    def report(project)
      result = invoke(project, "report")
      raise "missing public evidence report: #{result.stderr}" unless result.success?
      JSON.parse(result.stdout)
    end

    def state_path(project)
      project.path.join(STATE_PATH)
    end

    private

    def invoke(project, *arguments, env: {})
      argv = [*bin, *arguments]
      stdout, stderr, status = Open3.capture3(env, *argv, chdir: project.path.to_s)
      CommandResult.new(argv:, status:, stdout:, stderr:)
    end
  end
end

# frozen_string_literal: true

module MinitestTestmonAcceptance
  class RailsRuntime
    attr_reader :project, :workers, :database, :env

    def initialize(project, workers:)
      @project = project
      @workers = workers
      suffix = Digest::SHA256.hexdigest(project.path.to_s)[0, 12]
      @database = "minitest_testmon_acceptance_#{Process.pid}_#{suffix}"
      @env = {
        "RAILS_ENV" => "test",
        "RAILS_ACCEPTANCE_BUNDLE_GEMFILE" =>
          MinitestTestmonAcceptance::GEMFILE.to_s,
        "PARALLEL_WORKERS" => workers.to_s,
        "PARALLEL_MODE" => "processes",
        "RAILS_ACCEPTANCE_DATABASE" => database,
        "RAILS_ACCEPTANCE_DB_HOST" => ENV.fetch("RAILS_ACCEPTANCE_DB_HOST", "localhost"),
        "RAILS_ACCEPTANCE_DB_USER" => ENV.fetch("RAILS_ACCEPTANCE_DB_USER", "postgres"),
        "RAILS_ACCEPTANCE_DB_PASSWORD" => ENV["RAILS_ACCEPTANCE_DB_PASSWORD"],
        "PLAYWRIGHT_CLI_EXECUTABLE_PATH" =>
          MinitestTestmonAcceptance::PLAYWRIGHT_CLI_EXECUTABLE.to_s,
        # Validation-only workaround for pg/libpq GSS state inherited across fork on Ruby 4.
        "PGGSSENCMODE" => ENV.fetch("RAILS_ACCEPTANCE_PGGSSENCMODE", "disable")
      }
    end

    def prepare
      result = command("script/prepare_databases.rb")
      raise "Rails acceptance database preparation failed: #{result.stdout}\n#{result.stderr}" unless result.success?
      self
    end

    def cleanup
      command("script/drop_databases.rb")
    end

    def dependencies_available?
      probe = <<~RUBY
        require "rails"
        require "pg"
        require "simplecov"
        abort "Ruby 4 required" unless Gem::Version.new(RUBY_VERSION) >= Gem::Version.new("4.0")
        abort "Rails 8.1 required" unless Gem::Version.new(Rails.version) >= Gem::Version.new("8.1")
        PG.connect(
          host: ENV.fetch("RAILS_ACCEPTANCE_DB_HOST", "localhost"),
          user: ENV.fetch("RAILS_ACCEPTANCE_DB_USER", "postgres"),
          password: ENV["RAILS_ACCEPTANCE_DB_PASSWORD"],
          dbname: "postgres"
        ).close
      RUBY
      _stdout, _stderr, status = Open3.capture3(env, RbConfig.ruby, "-e", probe, chdir: project.path.to_s)
      status.success?
    end

    private

    def command(script)
      stdout, stderr, status = Open3.capture3(env, RbConfig.ruby, script, chdir: project.path.to_s)
      CommandResult.new(argv: [RbConfig.ruby, script], status:, stdout:, stderr:)
    end
  end
end

# frozen_string_literal: true

require "optparse"
require "securerandom"

module Minitest
  module Testmon
    class CLI
      USAGE = "usage: minitest-testmon discover|run|report|runs|explain"

      def self.start(arguments)
        cli = new(arguments)
        cli.run
      rescue ConfigurationError => error
        cli.write_invalid_configuration(error)
      rescue OptionParser::ParseError => error
        warn error.message
        2
      rescue LeaseUnavailable => error
        warn error.message
        3
      rescue Error => error
        warn error.message
        4
      end

      def initialize(arguments, out: $stdout, err: $stderr)
        @arguments = arguments.dup
        @out = out
        @err = err
        @options = {}
      end

      def run
        command = @arguments.shift
        @command_name = command
        case command
        when "discover" then discover
        when "run" then run_tests
        when "report" then show_report
        when "runs" then show_runs
        when "explain" then explain
        when "help", "-h", "--help"
          @out.puts USAGE
          0
        else
          @err.puts USAGE
          2
        end
      end

      def write_invalid_configuration(error)
        @err.puts error.message
        2
      end

      private

      def discover
        separator = @arguments.index("--")
        raise OptionParser::MissingArgument, "discover requires -- COMMAND" unless separator
        options = @arguments.shift(separator)
        @arguments.shift
        command = @arguments.dup
        raise OptionParser::MissingArgument, "discover requires a command" if command.empty?
        parse_common!(options)
        configuration = configured(command)
        status = spawn_test_command(command, configuration, Selection.new(mode: :full, tests: [], reasons: ["discovery"], generation: nil), mode: :discover)
        @out.write(@fresh_report_bytes) if @fresh_report_bytes
        status
      end

      def run_tests
        separator = @arguments.index("--")
        raise OptionParser::MissingArgument, "run requires -- COMMAND" unless separator
        options = @arguments.shift(separator)
        @arguments.shift
        command = @arguments.dup
        raise OptionParser::MissingArgument, "run requires a command" if command.empty?
        parse_common!(options)
        configuration = configured(command)
        if rails_8_1_project?(configuration)
          return spawn_test_command(command, configuration, nil, mode: :run)
        end
        snapshot = Testmon.registry.snapshot(configuration)
        store = Store.new(
          configuration.database_path,
          retained_reports: configuration.retained_reports
        )
        if snapshot.context.diagnostics.any?
          write_parent_rejected_report(snapshot, store, "provider_incomplete")
          store.close
          return 4
        end
        selection = store.select(snapshot.context.artifacts, context_signature: snapshot.signature, roots: configuration.roots)

        if selection.reasons.include?("path_unresolved")
          write_parent_rejected_report(snapshot, store, "provider_incomplete")
          store.close
          return 4
        end

        if selection.none? && snapshot.source_stable? && !native_parallelism_maybe?(configuration)
          report = DiscoveryReport.new(
            generation: selection.generation,
            context_signature: snapshot.signature,
            mode: :run,
            bundles: snapshot.registrations.map { |item| "#{item.name}@#{item.version}" },
            tests: {discovered: [], selected: [], executed: []},
            artifacts: snapshot.context.artifacts,
            dependencies: snapshot.context.dependencies,
            diagnostics: snapshot.context.diagnostics,
            resolver: snapshot.context.resolver,
            publication: {published: true, reason: nil},
            selection_mode: :none
          )
          payload = report.to_h.merge(inventory: store.published_inventory || report.to_h.fetch(:inventory))
          json = CanonicalJSON.generate(payload, pretty: true)
          run_id = SecureRandom.uuid
          store.begin_run(run_id:, mode: :run, context_signature: snapshot.signature)
          store.record_report(run_id, report)
          @out.puts json
          store.close
          return 0
        end

        store.close
        if selection.none? && !snapshot.source_stable?
          spawn_test_command(command, configuration, nil, mode: :run)
        else
          spawn_test_command(
            command,
            configuration,
            selection,
            mode: :run,
            context_signature: snapshot.signature,
            snapshot_digest: snapshot.snapshot_digest
          )
        end
      end

      def spawn_test_command(command, configuration, selection, mode:, context_signature: nil, snapshot_digest: nil)
        @fresh_report_bytes = nil
        run_id = SecureRandom.uuid
        store = Store.new(
          configuration.database_path,
          retained_reports: configuration.retained_reports
        )
        store.begin_run(run_id:, mode:, context_signature:)
        store.close
        rails_root = configuration.project_root if rails_full_suite_command?(command, configuration)
        environment = {
          "MINITEST_TESTMON" => "1",
          "MINITEST_TESTMON_MODE" => mode.to_s,
          "MINITEST_TESTMON_DB" => configuration.database_path,
          "MINITEST_TESTMON_RUN_ID" => run_id
        }
        if selection
          environment["MINITEST_TESTMON_SELECTION"] = CanonicalJSON.generate({
            mode: selection.mode,
            tests: selection.tests,
            reasons: selection.reasons,
            generation: selection.generation,
            context_signature: context_signature,
            snapshot_digest: snapshot_digest
          })
        end
        environment["MINITEST_TESTMON_CONFIG"] = @config_path if @config_path
        unless rails_root
          lib = File.expand_path("../..", __dir__)
          environment["RUBYOPT"] = [ENV["RUBYOPT"], "-I#{lib}", "-rminitest/testmon_plugin"].compact.join(" ")
        end
        if rails_root
          command = [File.join(rails_root, "bin/rails"), "test"]
          pid = Process.spawn(environment, *command, chdir: rails_root)
        else
          pid = Process.spawn(environment, *command)
        end
        Process.wait(pid)
        status = $?.exitstatus || 4
        store = Store.new(
          configuration.database_path,
          retained_reports: configuration.retained_reports
        )
        report = store.report(run_id)
        store.close
        if report && valid_testmon_report?(report, mode)
          @fresh_report_bytes = "#{CanonicalJSON.generate(report, pretty: true)}\n"
        else
          report = nil
        end
        if status.zero?
          return 4 unless report

          unpublished_reason = report.dig("publication", "reason")
          return 4 if report.dig("publication", "published") == false &&
            (mode == :discover || %w[provider_incomplete worker_incomplete].include?(unpublished_reason))
        end
        status
      end

      def valid_testmon_report?(report, mode)
        return false unless report.is_a?(Hash)
        return false unless report["schema_version"] == 2
        return false unless report["mode"] == mode.to_s
        return false unless [true, false].include?(report["ready"])
        return false unless report["generation"].nil? || report["generation"].is_a?(Integer)
        return false unless report["context_signature"].is_a?(String)
        return false unless string_array?(report["bundles"])
        return false unless string_array_hash?(report["tests"], %w[discovered selected executed])
        return false unless report["observations"].is_a?(Hash)
        return false unless report["inventory"].is_a?(Hash)
        return false unless report["suggestions"].is_a?(Array)

        publication = report["publication"]
        publication.is_a?(Hash) &&
          [true, false].include?(publication["published"]) &&
          (publication["reason"].nil? || publication["reason"].is_a?(String))
      end

      def string_array_hash?(value, keys)
        value.is_a?(Hash) && keys.all? { |key| string_array?(value[key]) }
      end

      def string_array?(value)
        value.is_a?(Array) && value.all? { |item| item.is_a?(String) }
      end

      def explain
        parse_common!(@arguments, keep_paths: true)
        configuration = configured
        store = Store.new(configuration.database_path)
        requested_generation = @options[:generation] || store.generation
        rows = store.explain(@arguments, generation: requested_generation)
        @out.puts CanonicalJSON.generate({generation: requested_generation, explanations: rows}, pretty: true)
        store.close
        0
      end

      def write_parent_rejected_report(snapshot, store, reason)
        report = snapshot.observe(tests: {discovered: []}, selected: [], mode: :run)
          .finalize
          .with_generation(store.generation)
          .unpublished(reason)
        run_id = SecureRandom.uuid
        store.begin_run(run_id:, mode: :run, context_signature: snapshot.signature)
        store.record_report(run_id, report)
      end

      def show_report
        parse_common!(@arguments, keep_paths: true)
        raise OptionParser::InvalidArgument, "report accepts at most one RUN_ID" if @arguments.length > 1
        store = Store.new(report_database_path)
        report = store.report(@arguments.first)
        store.close
        raise Error, "report_not_found" unless report
        @out.puts CanonicalJSON.generate(report, pretty: true)
        0
      end

      def show_runs
        parse_common!(@arguments)
        store = Store.new(report_database_path)
        rows = store.runs(limit: @options.fetch(:limit, 20))
        store.close
        @out.puts CanonicalJSON.generate({runs: rows}, pretty: true)
        0
      end

      def report_database_path
        File.expand_path(@options[:database] || Configuration::DEFAULT_DATABASE, Dir.pwd)
      end

      def parse_common!(arguments, keep_paths: false)
        parser = OptionParser.new do |options|
          options.on("--config PATH") { |path| @options[:config] = File.expand_path(path) }
          options.on("--database PATH") { |path| @options[:database] = path }
          options.on("--generation N", Integer) { |value| @options[:generation] = value }
          options.on("--limit N", Integer) { |value| @options[:limit] = value }
        end
        keep_paths ? parser.order!(arguments) : parser.parse!(arguments)
      end

      def configured(command = nil)
        rails_root = rails_application_root(command)
        reject_noncanonical_rails_command!(command, rails_root)
        reject_rails_filter_environment! if rails_root
        project_root = rails_root || Dir.pwd
        if project_root != Dir.pwd
          ENV["MINITEST_TESTMON_PROJECT_ROOT"] = project_root
          Testmon.reset!
        end
        path = @options[:config] || File.join(project_root, ".minitest-testmon.rb")
        if File.file?(path)
          @config_path = File.expand_path(path)
          Testmon.configuration.record_config_source(@config_path)
          load @config_path
        end
        configuration = Testmon.configuration
        configuration.database(@options[:database]) if @options[:database]
        snapshot = configuration.snapshot
        if rails_root && snapshot.project_root != rails_root
          raise OptionParser::InvalidArgument, rails_project_root_usage
        end
        if command && !rails_root && rails_project_root?(snapshot.project_root)
          raise OptionParser::InvalidArgument, rails_wrapper_usage
        end
        snapshot
      end

      def rails_8_1_project?(configuration)
        return false if configuration.bundle_disabled?(:rails_8_1)
        return false unless File.file?(File.join(configuration.project_root, "config/application.rb"))
        spec = Gem.loaded_specs["railties"] || Gem::Specification.find_all_by_name("railties").max_by(&:version)
        spec && spec.version.segments.first(2) == [8, 1]
      end

      def rails_full_suite_command?(command, configuration)
        rails_application_root(command) == configuration.project_root
      end

      def rails_application_root(command)
        return unless command&.length == 2 && command.last == "test"

        rails_launcher_root(command.first)
      end

      def rails_launcher_root(token)
        executable = File.expand_path(token)
        return unless File.file?(executable)

        root = File.realpath(File.join(File.dirname(executable), ".."))
        canonical = File.join(root, "bin/rails")
        return unless File.identical?(executable, canonical)
        return unless rails_project_root?(root)

        root
      rescue SystemCallError
        nil
      end

      def reject_noncanonical_rails_command!(command, rails_root)
        return unless command
        return if rails_root
        return unless rails_project_root?(Dir.pwd) || command.any? { |token| rails_launcher_root(token) }

        raise OptionParser::InvalidArgument, rails_wrapper_usage
      end

      def rails_project_root?(root)
        File.file?(File.join(root, "config/application.rb"))
      end

      def rails_wrapper_usage
        "Rails wrapper requires the application's exact bin/rails test command"
      end

      def rails_project_root_usage
        "Rails wrapper requires :project to remain the canonical Rails application root"
      end

      def reject_rails_filter_environment!
        filters = %w[DEFAULT_TEST DEFAULT_TEST_EXCLUDE].select { |name| ENV.key?(name) }
        return if filters.empty?

        raise OptionParser::InvalidArgument,
          "--testmon requires the complete default Rails test suite; remove #{filters.join(", ")}"
      end

      def native_parallelism_maybe?(configuration)
        configuration.ruby_patterns.any? do |root_name, pattern|
          root = configuration.roots.fetch(root_name)
          Dir.glob(File.join(root, pattern), File::FNM_DOTMATCH).any? do |path|
            File.file?(path) && File.binread(path).match?(/\bparallelize_me!/)
          rescue SystemCallError
            true
          end
        end
      end
    end
  end
end

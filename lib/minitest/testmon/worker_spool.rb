# frozen_string_literal: true

require "fileutils"

module Minitest
  module Testmon
    WorkerMerge = Data.define(:observations, :executed, :complete)

    class WorkerSpool
      RUN_ID_PATTERN = /\A[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}\z/i
      WORKERS_COMPONENTS = %w[tmp minitest-testmon workers].freeze

      attr_reader :temporary_path, :final_path

      def initialize(directory:, run_id:, worker_number:, context_signature:, base_revision:)
        @owner_pid = Process.pid
        @mutex = Mutex.new
        @lifecycle_mutex = Mutex.new
        @directory = File.join(directory, run_id)
        @run_id = run_id
        @worker_number = Integer(worker_number)
        @completion_observations = []
        @sequence = 0
        @context_signature = context_signature
        @base_revision = base_revision
        FileUtils.mkdir_p(@directory)
        basename = format("%03d-%d.jsonl", @worker_number, Process.pid)
        @temporary_path = File.join(@directory, "#{basename}.tmp")
        @final_path = File.join(@directory, basename)
        @io = File.open(@temporary_path, File::WRONLY | File::CREAT | File::EXCL, 0o600)
        append(type: "start", run_id: @run_id, worker: @worker_number, pid: Process.pid,
          context_signature: @context_signature, base_revision: @base_revision)
      end

      def record_observation(observation)
        value = observation.to_h
        encoded = CanonicalJSON.generate(value)
        line = '{"type":"observation","value":' + encoded + "}\n"
        synchronize do
          ensure_open!
          @io.write(line)
          @completion_observations << encoded
        end
      end

      def record_executed(test_id)
        append(type: "executed", test_id: test_id.to_s)
      end

      # Independent, durable frames survive a later worker crash. SQLite remains
      # parent-owned. Rename happens before the result is delivered to the parent.
      def seal_test(test_id, outcome, diagnostics: [])
        test_id = test_id.to_s
        outcome = outcome.to_s
        # Serialize provider-owned values outside either lock. Observation rows
        # are already encoded when recorded, so draining does not invoke callbacks.
        diagnostics_json = CanonicalJSON.generate(diagnostics)
        synchronize_lifecycle do
          sequence, observations = synchronize do
            ensure_open!
            @sequence += 1
            pending = @completion_observations
            @completion_observations = []
            [@sequence, pending]
          end
          frame = {
            run_id: @run_id, worker: @worker_number, pid: @owner_pid,
            context_signature: @context_signature, base_revision: @base_revision,
            sequence: sequence, test_id: test_id, outcome: outcome
          }
          payload = CanonicalJSON.generate(frame).delete_suffix("}") +
            ',"diagnostics":' + diagnostics_json +
            ',"observations":[' + observations.join(",") + "]}"
          name = "test-#{Digest::SHA256.hexdigest(test_id)}-#{@worker_number}-#{@owner_pid}-#{sequence}.json"
          target = File.join(@directory, name)
          File.open("#{target}.tmp", File::WRONLY | File::CREAT | File::EXCL, 0o600) do |io|
            io.write(payload)
            io.flush
            io.fsync
          end
          File.rename("#{target}.tmp", target)
          fsync_directory
          true
        end
      end

      def self.completion(directory:, run_id:, test_id:, outcome:, context_signature:, base_revision:, worker_count:)
        files = Dir[File.join(directory, run_id, "test-#{Digest::SHA256.hexdigest(test_id)}-*.json")]
        raise PhaseError, "worker_completion_missing_or_duplicate" unless files.length == 1
        frame = CanonicalJSON.parse(File.read(files.first))
        valid = frame["run_id"] == run_id && frame["test_id"] == test_id &&
          frame["outcome"] == outcome.to_s && frame["context_signature"] == context_signature &&
          frame["base_revision"] == base_revision && frame["worker"].is_a?(Integer) && (0...worker_count).cover?(frame["worker"]) &&
          frame["sequence"].is_a?(Integer) && frame["sequence"].positive? &&
          frame["pid"].is_a?(Integer) && frame["pid"].positive? &&
          frame["diagnostics"].is_a?(Array)
        raise PhaseError, "invalid_worker_completion" unless valid
        observations = frame.fetch("observations").map { |value| deserialize_observation(value) }
        raise PhaseError, "invalid_worker_completion_owner" if observations.any? { |item| item.test_id && item.test_id != test_id }
        [observations, frame.fetch("diagnostics"), [frame["worker"], frame["pid"], frame["sequence"]]]
      end

      def complete!
        synchronize_lifecycle do
          synchronize do
            return true if @complete
            return false if @failed
            @io.write("{\"type\":\"complete\"}\n")
            @io.flush
            @io.fsync
            @io.close
            File.rename(@temporary_path, @final_path)
            fsync_directory
            @complete = true
            true
          rescue
            restore_incomplete_path
            @failed = true
            false
          end
        end
      end

      def abort
        synchronize_lifecycle do
          synchronize do
            @io&.close unless @io&.closed?
            restore_incomplete_path
            @failed = true
            false
          end
        end
      end

      def self.merge(directory:, run_id:, worker_count:, context_signature:, base_revision:, expected_tests: nil)
        run_directory = File.join(directory, run_id)
        return WorkerMerge.new(observations: [], executed: [], complete: false) unless File.directory?(run_directory)
        return WorkerMerge.new(observations: [], executed: [], complete: false) unless Dir[File.join(run_directory, "*.tmp")].empty?

        observations = []
        executed = []
        complete = true
        expected = (0...Integer(worker_count)).to_a
        expected.each do |worker_number|
          files = Dir[File.join(run_directory, format("%03d-*.jsonl", worker_number))].sort
          if files.length != 1
            complete = false
            next
          end
          parsed = parse_file(
            files.first,
            run_id: run_id,
            worker_number: worker_number,
            context_signature: context_signature,
            base_revision: base_revision
          )
          complete &&= parsed[:complete]
          observations.concat(parsed[:observations])
          executed.concat(parsed[:executed])
        rescue JSON::ParserError, KeyError, TypeError, ArgumentError
          complete = false
        end
        counts = executed.tally
        complete &&= counts.values.all? { |count| count == 1 }
        if expected_tests
          expected_test_ids = Array(expected_tests).map(&:to_s).uniq.sort
          complete &&= counts.keys.sort == expected_test_ids
        end
        WorkerMerge.new(observations: observations, executed: counts.keys.sort, complete: complete)
      end

      def self.discard_validated_run(project_root:, run_id:)
        discard_run_directory(project_root, run_id)
      end

      def self.discard_run_directory(project_root, run_id)
        return false unless run_id.to_s.match?(RUN_ID_PATTERN)
        root = trusted_workers_root(project_root)
        return false unless root

        target = File.join(root, run_id.to_s)
        return false unless File.dirname(target) == root
        stat = File.lstat(target)
        return false unless stat.directory? && !stat.symlink?
        return false unless File.realpath(target) == target

        FileUtils.remove_entry_secure(target)
        true
      rescue SystemCallError, ArgumentError, TypeError
        false
      end
      private_class_method :discard_run_directory

      def self.trusted_workers_root(project_root)
        canonical_project = File.realpath(project_root)
        project_stat = File.lstat(canonical_project)
        return unless project_stat.directory? && !project_stat.symlink?

        current = canonical_project
        trusted_components = WORKERS_COMPONENTS.all? do |component|
          current = File.join(current, component)
          stat = File.lstat(current)
          stat.directory? && !stat.symlink?
        end
        return unless trusted_components

        trusted_base = File.join(canonical_project, *WORKERS_COMPONENTS.first(2))
        base_realpath = File.realpath(trusted_base)
        root_realpath = File.realpath(current)
        return unless base_realpath == trusted_base
        return unless root_realpath == current
        return unless File.dirname(root_realpath) == base_realpath
        return unless File.basename(root_realpath) == WORKERS_COMPONENTS.last

        root_realpath
      rescue SystemCallError, ArgumentError, TypeError
        nil
      end
      private_class_method :trusted_workers_root

      def self.parse_file(path, run_id:, worker_number:, context_signature:, base_revision:)
        valid_start = false
        valid_finish = false
        body_valid = true
        observations = []
        executed = []
        line_number = 0
        finished = false
        File.foreach(path, chomp: true) do |line|
          line_number += 1
          entry = CanonicalJSON.parse(line)
          if line_number == 1
            valid_start = entry["type"] == "start" && entry["run_id"] == run_id &&
              entry["worker"] == worker_number && entry["context_signature"] == context_signature &&
              entry["base_revision"] == base_revision
            next
          end
          if finished
            body_valid = false
            next
          end
          case entry["type"]
          when "observation"
            observations << deserialize_observation(entry.fetch("value"))
          when "executed"
            executed << String(entry.fetch("test_id"))
          when "complete"
            valid_finish = entry.keys == ["type"]
            finished = true
          else
            body_valid = false
          end
        end
        duplicates = executed.tally.any? { |_test_id, count| count != 1 }
        {
          observations: observations,
          executed: executed,
          complete: valid_start && valid_finish && body_valid && !duplicates
        }
      end
      private_class_method :parse_file

      def self.deserialize_observation(value)
        data = value.transform_keys(&:to_sym)
        data[:kind] = data.fetch(:kind).to_sym
        data[:provider] = data.fetch(:provider).to_sym
        data[:operation] = data[:operation]&.to_sym
        data[:scope] = data.fetch(:scope).to_sym
        data[:reason] = data[:reason]&.to_sym
        data[:provenance] = data[:provenance]&.to_sym
        data[:callsite] = data[:callsite]&.transform_keys(&:to_sym)
        # Observation details are provider-owned canonical data. Preserve their
        # JSON key shape; recursively symbolizing them changes the public
        # extractor contract between serial and process-worker execution.
        data[:details] = data.fetch(:details, {})
        Observation.new(**data)
      end
      private_class_method :deserialize_observation

      private

      def append(value)
        line = CanonicalJSON.generate(value) + "\n"
        synchronize do
          ensure_open!
          @io.write(line)
        end
      end

      def ensure_open!
        raise PhaseError, "worker spool is closed" if @complete || @failed
      end

      def synchronize(&block)
        ensure_owner!
        @mutex.synchronize(&block)
      end

      def synchronize_lifecycle(&block)
        ensure_owner!
        @lifecycle_mutex.synchronize(&block)
      end

      def ensure_owner!
        raise PhaseError, "worker spool belongs to another process" unless Process.pid == @owner_pid
      end

      def fsync_directory
        File.open(@directory, File::RDONLY, &:fsync)
      end

      def restore_incomplete_path
        @io&.close unless @io&.closed?
        File.rename(@final_path, @temporary_path) if File.exist?(@final_path) && !File.exist?(@temporary_path)
      rescue SystemCallError, IOError
        nil
      end
    end
  end
end

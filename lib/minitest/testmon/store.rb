# frozen_string_literal: true

require "fileutils"
require "json"
require "securerandom"
require "sqlite3"
require "time"

module Minitest
  module Testmon
    RetryState = Data.define(:test_id, :outcome, :updated_at)

    # SQLite persistence for per-test dependency snapshots. Selector owns the
    # read-side decision; this class atomically validates and publishes run
    # evidence while owning durable state, leases, and receipts.
    class Store
      SCHEMA_VERSION = 6
      DEFAULT_RETAINED_REPORTS = 10
      SchemaIncompatible = Class.new(StandardError)

      attr_reader :path, :recovered_run_id

      def initialize(path, retained_reports: DEFAULT_RETAINED_REPORTS)
        @path = File.expand_path(path)
        @retained_reports = Integer(retained_reports)
        raise ArgumentError, "retained reports must be a positive integer" unless @retained_reports.positive?

        @leased = false
        @lease_token = nil
        @lease_owner_pid = nil
        FileUtils.mkdir_p(File.dirname(@path))
        connect
        validate_or_rebuild!
      end

      # standard:disable Lint/RescueException
      def close
        release_error = nil
        begin
          release_lease! if @leased && @lease_owner_pid == Process.pid && connected?
        rescue Exception => error
          release_error = error
        ensure
          @database&.close
          @database = nil
        end
        raise release_error if release_error
      end
      # standard:enable Lint/RescueException

      def connected?
        !@database.nil? && !@database.closed?
      end

      def revision
        value = metadata("revision")
        value && Integer(value)
      end
      alias_method :generation, :revision

      def snapshots_for(test_ids)
        ids = normalize_ids(test_ids)
        return {} if ids.empty?

        snapshots = rows_for_ids("test_snapshots", ids).to_h do |row|
          test_id = row.fetch("test_id")
          [test_id, TestSnapshot.new(
            test_id: test_id,
            inputs: [],
            recorded_at: row.fetch("recorded_at"),
            run_id: row.fetch("run_id")
          )]
        end
        inputs_for(ids).group_by { |test_id, _input| test_id }.each do |test_id, pairs|
          existing = snapshots.fetch(test_id)
          snapshots[test_id] = TestSnapshot.new(
            test_id: test_id,
            inputs: pairs.map(&:last),
            recorded_at: existing.recorded_at,
            run_id: existing.run_id
          )
        end
        snapshots.sort.to_h.freeze
      end

      def retries_for(test_ids)
        ids = normalize_ids(test_ids)
        return {} if ids.empty?

        rows_for_ids("retry_tests", ids).to_h do |row|
          state = RetryState.new(
            test_id: row.fetch("test_id"),
            outcome: row.fetch("outcome").to_sym,
            updated_at: row.fetch("updated_at")
          )
          [state.test_id, state]
        end.freeze
      end

      def begin_run(run_id:, mode: :run, context_signature: nil)
        @database.execute(
          <<~SQL,
            INSERT OR IGNORE INTO run_receipts(
              id, mode, state, context_signature, base_revision, started_at
            ) VALUES (?, ?, 'pending', ?, ?, ?)
          SQL
          [run_id.to_s, mode.to_s, context_signature, revision, timestamp]
        )
        prune_run_receipts
        run_id.to_s
      end

      def acquire_lease!(run_id: nil)
        raise PhaseError, "cache lease is already held" if @leased
        transaction do
          existing = @database.get_first_row("SELECT token, owner_pid, run_id FROM leases WHERE name = 'cache'")
          if existing && process_alive?(Integer(existing.fetch("owner_pid")))
            raise LeaseUnavailable, "cache_lease_unavailable"
          end
          if existing
            @recovered_run_id = existing["run_id"]
            abandon_run(@recovered_run_id, "worker_incomplete")
            @database.execute("DELETE FROM leases WHERE name = 'cache'")
          end

          @lease_token = SecureRandom.uuid
          @lease_owner_pid = Process.pid
          @database.execute(
            "INSERT INTO leases(name, token, owner_pid, run_id, created_at) VALUES ('cache', ?, ?, ?, ?)",
            [@lease_token, @lease_owner_pid, run_id&.to_s, timestamp]
          )
        end
        @leased = true
        true
      rescue SQLite3::BusyException, SQLite3::LockedException
        clear_lease
        raise LeaseUnavailable, "cache_lease_unavailable"
      rescue
        clear_lease unless @lease_token
        raise
      end

      # Persist the exact execution intent before Minitest can run. The retry
      # rows are intentionally committed separately from publication so a
      # killed process re-runs only the entities that may have partial evidence.
      def start_execution(run_id:, selection:)
        require_owned_lease!
        transaction do
          verify_lease!
          verify_revision!(selection.base_revision)
          now = timestamp
          selection.selected.each { |test_id| upsert_retry(test_id, :running, now) }
          @database.execute(
            <<~SQL,
              INSERT INTO run_receipts(
                id, mode, state, base_revision, selected_json, started_at
              ) VALUES (?, 'run', 'running', ?, ?, ?)
              ON CONFLICT(id) DO UPDATE SET
                state='running',
                base_revision=excluded.base_revision,
                selected_json=excluded.selected_json
            SQL
            [run_id.to_s, selection.base_revision, CanonicalJSON.generate(selection.selected), now]
          )
        end
        true
      end

      def publish(evidence)
        require_owned_lease!
        transaction do
          verify_lease!
          verify_revision!(evidence.base_revision)
          if !(evidence.complete && evidence.source_stable && evidence.valid_ledger?)
            reason = if !evidence.complete
              evidence.publication_reason || "provider_incomplete"
            elsif !evidence.source_stable
              "source_drift"
            else
              "provider_incomplete"
            end
            reject_evidence(evidence, reason)
          elsif evidence.failed?
            reject_evidence(evidence, "test_failure")
          elsif !evidence.publishable_snapshots?
            reject_evidence(evidence, "provider_incomplete")
          else
            next_revision = evidence.passed_ids.empty? ? revision : (revision || 0) + 1
            evidence.passed_ids.each do |test_id|
              replace_snapshot(evidence.snapshots.fetch(test_id))
              @database.execute("DELETE FROM retry_tests WHERE test_id = ?", [test_id])
            end
            evidence.outcomes.each do |test_id, outcome|
              upsert_retry(test_id, outcome) if outcome == :skipped
            end
            set_metadata("revision", next_revision.to_s) if next_revision

            published = publish_report(evidence.report, next_revision, evidence.publication_reason)
            finalize_run(evidence.run_id, published, state: "complete")
            published
          end
        end
      end

      def release_lease!
        return false unless @leased && @lease_owner_pid == Process.pid
        raise PhaseError, "cache store is disconnected" unless connected?
        transaction do
          verify_lease!
          @database.execute("DELETE FROM leases WHERE name = 'cache' AND token = ?", [@lease_token])
        end
        clear_lease
        true
      rescue SQLite3::BusyException, SQLite3::LockedException
        raise LeaseUnavailable, "cache_lease_unavailable"
      end

      def disconnect_for_fork!
        require_owned_lease!
        @database.close
        @database = nil
        true
      end

      def reconnect!
        return true if connected?
        raise PhaseError, "only the lease-owning parent may reconnect" unless @leased && @lease_owner_pid == Process.pid
        connect
        validate_or_rebuild!
        verify_lease!
        true
      end

      def report(run_id = nil)
        row = if run_id
          @database.get_first_row("SELECT report_json FROM run_receipts WHERE id = ? AND state = 'complete'", [run_id.to_s])
        else
          @database.get_first_row("SELECT report_json FROM run_receipts WHERE state = 'complete' ORDER BY finished_at DESC, rowid DESC LIMIT 1")
        end
        row && CanonicalJSON.parse(row.fetch("report_json"))
      rescue JSON::ParserError
        nil
      end

      def runs(limit: 20)
        @database.execute(
          <<~SQL,
            SELECT id, mode, state, base_revision, published_revision,
                   publication_reason, started_at, finished_at
            FROM run_receipts ORDER BY started_at DESC LIMIT ?
          SQL
          [Integer(limit)]
        )
      end

      def explain(terms = [], generation: revision)
        return [] unless generation == revision
        requested = Array(terms).map(&:to_s)
        @database.execute(<<~SQL).filter_map do |row|
          SELECT test_inputs.root, test_inputs.relative_path, test_inputs.facet,
                 test_inputs.digest AS fingerprint, test_inputs.test_id,
                 test_inputs.provider, test_inputs.input_key
          FROM test_inputs
          ORDER BY test_inputs.root, test_inputs.relative_path,
                   test_inputs.facet, test_inputs.test_id
        SQL
          path = if row["root"] && row["relative_path"]
            "#{row.fetch("root")}:#{row.fetch("relative_path")}"
          else
            row.fetch("input_key")
          end
          next unless requested.empty? || requested.any? { |term| path.include?(term) || row.fetch("test_id").include?(term) }
          {
            path: path,
            facet: row.fetch("facet"),
            fingerprint: row.fetch("fingerprint"),
            test_id: row.fetch("test_id"),
            provider: row.fetch("provider")
          }
        end
      end

      def published_inventory
        row = @database.get_first_row(<<~SQL)
          SELECT report_json FROM run_receipts
          WHERE state = 'complete' AND published_revision IS NOT NULL
          ORDER BY finished_at DESC, rowid DESC LIMIT 1
        SQL
        return unless row
        CanonicalJSON.parse(row.fetch("report_json"))["inventory"]
      rescue JSON::ParserError
        nil
      end

      private

      def connect
        @database = SQLite3::Database.new(path)
        @database.results_as_hash = true
        @database.busy_timeout = 0
        @database.execute("PRAGMA foreign_keys = ON")
      end

      def validate_or_rebuild!
        if schema_present?
          integrity = @database.get_first_value("PRAGMA integrity_check")
          raise SQLite3::CorruptException, integrity unless integrity == "ok"
          raise SchemaIncompatible, "schema mismatch" unless metadata("schema_version") == SCHEMA_VERSION.to_s
        elsif database_empty?
          create_schema!
        else
          raise SchemaIncompatible, "metadata table is missing"
        end
      rescue SQLite3::BusyException, SQLite3::LockedException
        raise LeaseUnavailable, "cache_lease_unavailable"
      rescue SchemaIncompatible
        quarantine_and_rebuild!("incompatible")
      rescue SQLite3::CorruptException, SQLite3::NotADatabaseException
        quarantine_and_rebuild!("corrupt")
      rescue SQLite3::Exception, SystemCallError, IOError => error
        raise Error, "cache_unavailable: #{error.message}"
      end

      def schema_present?
        @database.get_first_value("SELECT 1 FROM sqlite_master WHERE type='table' AND name='metadata'") == 1
      end

      def database_empty?
        @database.get_first_value("SELECT 1 FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' LIMIT 1").nil?
      end

      def create_schema!
        @database.execute_batch(<<~SQL)
          PRAGMA foreign_keys = ON;
          CREATE TABLE metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);
          CREATE TABLE leases (
            name TEXT PRIMARY KEY CHECK (name = 'cache'),
            token TEXT NOT NULL UNIQUE,
            owner_pid INTEGER NOT NULL,
            run_id TEXT,
            created_at TEXT NOT NULL
          );
          CREATE TABLE test_snapshots (
            test_id TEXT PRIMARY KEY,
            recorded_at TEXT NOT NULL,
            run_id TEXT NOT NULL
          );
          CREATE TABLE test_inputs (
            test_id TEXT NOT NULL REFERENCES test_snapshots(test_id) ON DELETE CASCADE,
            provider TEXT NOT NULL,
            input_key TEXT NOT NULL,
            facet TEXT NOT NULL,
            root TEXT,
            relative_path TEXT,
            digest TEXT,
            state TEXT NOT NULL CHECK (state IN ('known', 'missing')),
            PRIMARY KEY(test_id, provider, input_key)
          );
          CREATE INDEX test_inputs_identity ON test_inputs(provider, input_key);
          CREATE TABLE retry_tests (
            test_id TEXT PRIMARY KEY,
            outcome TEXT NOT NULL,
            updated_at TEXT NOT NULL
          );
          CREATE TABLE run_receipts (
            id TEXT PRIMARY KEY,
            mode TEXT NOT NULL,
            state TEXT NOT NULL CHECK (state IN ('pending', 'running', 'complete', 'abandoned')),
            context_signature TEXT,
            base_revision INTEGER,
            published_revision INTEGER,
            selected_json TEXT,
            publication_reason TEXT,
            report_schema_version INTEGER,
            report_json TEXT,
            started_at TEXT NOT NULL,
            finished_at TEXT
          );
          CREATE INDEX run_receipts_finished ON run_receipts(state, finished_at);
        SQL
        set_metadata("schema_version", SCHEMA_VERSION.to_s)
      end

      def quarantine_and_rebuild!(kind)
        begin
          @database.close
        rescue
          nil
        end
        suffix = Time.now.utc.strftime("%Y%m%dT%H%M%S")
        File.rename(path, "#{path}.#{kind}-#{suffix}-#{Process.pid}")
        connect
        create_schema!
      rescue SystemCallError => error
        raise Error, "cache_#{kind}_quarantine_failed: #{error.message}"
      end

      def replace_snapshot(snapshot)
        @database.execute(
          <<~SQL,
            INSERT INTO test_snapshots(test_id, recorded_at, run_id)
            VALUES (?, ?, ?)
            ON CONFLICT(test_id) DO UPDATE SET
              recorded_at=excluded.recorded_at,
              run_id=excluded.run_id
          SQL
          [snapshot.test_id, snapshot.recorded_at, snapshot.run_id]
        )
        @database.execute("DELETE FROM test_inputs WHERE test_id = ?", [snapshot.test_id])
        snapshot.inputs.each do |input|
          raise PhaseError, "unknown input cannot be published: #{input.id}" unless input.known?
          @database.execute(
            <<~SQL,
              INSERT INTO test_inputs(
                test_id, provider, input_key, facet, root, relative_path, digest, state
              ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            SQL
            [
              snapshot.test_id, input.provider, input.key, input.facet, input.root,
              input.relative_path, input.fingerprint.digest, input.fingerprint.state.to_s
            ]
          )
        end
      end

      def inputs_for(ids)
        placeholders = (["?"] * ids.length).join(",")
        @database.execute(
          <<~SQL,
            SELECT test_id, provider, input_key, facet, root, relative_path, digest, state
            FROM test_inputs WHERE test_id IN (#{placeholders})
            ORDER BY test_id, provider, input_key
          SQL
          ids
        ).map do |row|
          fingerprint = case row.fetch("state")
          when "known" then Fingerprint.known(row.fetch("digest"))
          when "missing" then Fingerprint.new(state: :missing, digest: row.fetch("digest"), reason: :nonexistent)
          else raise PhaseError, "invalid persisted fingerprint state"
          end
          [row.fetch("test_id"), Input.new(
            key: row.fetch("input_key"),
            provider: row.fetch("provider"),
            facet: row.fetch("facet"),
            root: row["root"],
            relative_path: row["relative_path"],
            fingerprint: fingerprint
          )]
        end
      end

      def reject_evidence(evidence, reason)
        evidence.outcomes.each do |test_id, outcome|
          upsert_retry(test_id, outcome) if %i[failed skipped].include?(outcome)
        end
        rejected = evidence.report.with_generation(revision).unpublished(reason)
        finalize_run(evidence.run_id, rejected, state: "complete")
        rejected
      end

      def publish_report(report, next_revision, reason)
        report.published(next_revision, reason: reason)
      end

      def finalize_run(run_id, report, state:)
        return report unless run_id
        payload = report.to_h
        unless report.publication[:published]
          inventory = published_inventory
          payload = payload.merge(inventory: inventory) if inventory
        end
        @database.execute(
          <<~SQL,
            INSERT INTO run_receipts(
              id, mode, state, context_signature, base_revision,
              published_revision, publication_reason, report_schema_version,
              report_json, started_at, finished_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
              mode=excluded.mode,
              state=excluded.state,
              context_signature=excluded.context_signature,
              published_revision=excluded.published_revision,
              publication_reason=excluded.publication_reason,
              report_schema_version=excluded.report_schema_version,
              report_json=excluded.report_json,
              finished_at=excluded.finished_at
          SQL
          [
            run_id.to_s, report.mode, state, report.context_signature, revision,
            report.generation, report.publication[:reason], payload.fetch(:schema_version),
            CanonicalJSON.generate(payload), timestamp, timestamp
          ]
        )
        prune_run_receipts
        report
      end

      def abandon_run(run_id, reason)
        return unless run_id
        @database.execute(
          "UPDATE run_receipts SET state='abandoned', publication_reason=?, finished_at=? WHERE id=? AND state != 'complete'",
          [reason.to_s, timestamp, run_id.to_s]
        )
      end

      def upsert_retry(test_id, outcome, at = timestamp)
        @database.execute(
          <<~SQL,
            INSERT INTO retry_tests(test_id, outcome, updated_at) VALUES (?, ?, ?)
            ON CONFLICT(test_id) DO UPDATE SET outcome=excluded.outcome, updated_at=excluded.updated_at
          SQL
          [test_id.to_s, outcome.to_s, at]
        )
      end

      def rows_for_ids(table, ids)
        placeholders = (["?"] * ids.length).join(",")
        @database.execute("SELECT * FROM #{table} WHERE test_id IN (#{placeholders}) ORDER BY test_id", ids)
      end

      def normalize_ids(values)
        Array(values).map(&:to_s).uniq.sort
      end

      def metadata(key)
        @database.get_first_value("SELECT value FROM metadata WHERE key = ?", [key])
      end

      def set_metadata(key, value)
        @database.execute(
          "INSERT INTO metadata(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
          [key, value]
        )
      end

      def verify_revision!(expected)
        return if revision == expected
        raise PhaseError, "stale_snapshot_revision"
      end

      def verify_lease!
        row = @database.get_first_row("SELECT token, owner_pid FROM leases WHERE name = 'cache'")
        valid = row && row.fetch("token") == @lease_token && Integer(row.fetch("owner_pid")) == @lease_owner_pid
        raise LeaseUnavailable, "cache_lease_unavailable" unless valid
      end

      def require_owned_lease!
        raise PhaseError, "exclusive cache lease is required" unless @leased && @lease_owner_pid == Process.pid
        raise PhaseError, "cache store is disconnected" unless connected?
      end

      def process_alive?(pid)
        Process.kill(0, pid)
        true
      rescue Errno::ESRCH
        false
      rescue Errno::EPERM
        true
      end

      def transaction
        @database.execute("BEGIN IMMEDIATE")
        value = yield
        @database.execute("COMMIT")
        value
      rescue
        begin
          @database.execute("ROLLBACK")
        rescue
          nil
        end
        raise
      end

      def prune_run_receipts
        @database.execute(<<~SQL, [@retained_reports])
          DELETE FROM run_receipts WHERE id IN (
            SELECT id FROM run_receipts ORDER BY started_at DESC, rowid DESC LIMIT -1 OFFSET ?
          )
        SQL
      end

      def timestamp
        Time.now.utc.iso8601(6)
      end

      def clear_lease
        @leased = false
        @lease_token = nil
        @lease_owner_pid = nil
      end
    end
  end
end

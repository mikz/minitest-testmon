# frozen_string_literal: true

require "fileutils"
require "securerandom"
require "sqlite3"
require "time"

module Minitest
  module Testmon
    Selection = Data.define(:mode, :tests, :reasons, :generation) do
      def full?
        mode == :full
      end

      def none?
        mode == :none
      end
    end

    class Store
      SCHEMA_VERSION = 4
      RETAIN_GENERATIONS = 10
      SchemaIncompatible = Class.new(StandardError)

      attr_reader :path, :recovery_reason, :recovered_run_id

      def initialize(path, retained_reports: Configuration::DEFAULT_RETAINED_REPORTS)
        @path = File.expand_path(path)
        @retained_reports = Integer(retained_reports)
        raise ArgumentError, "retained reports must be a positive integer" unless @retained_reports.positive?
        @leased = false
        @lease_token = nil
        @lease_owner_pid = nil
        @pending_abandonment = nil
        @recovery_reason = nil
        FileUtils.mkdir_p(File.dirname(@path))
        connect
        validate_or_rebuild!
        @recovery_reason ||= metadata("recovery_required")
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

      def acquire_lease!(run_id: nil)
        raise PhaseError, "cache lease is already held" if @leased
        @database.execute("BEGIN IMMEDIATE")
        existing = @database.get_first_row("SELECT token, owner_pid, run_id FROM leases WHERE name = 'cache'")
        if existing && process_alive?(Integer(existing.fetch("owner_pid")))
          @database.execute("ROLLBACK")
          raise LeaseUnavailable, "cache_lease_unavailable"
        end
        if existing
          @recovery_reason = "worker_incomplete"
          @recovered_run_id = existing["run_id"]
          @database.execute("DELETE FROM leases WHERE name = 'cache'")
          set_metadata("recovery_required", @recovery_reason)
          abandon_run(@recovered_run_id, @recovery_reason)
        end
        @lease_token = SecureRandom.uuid
        @lease_owner_pid = Process.pid
        @database.execute(
          "INSERT INTO leases(name, token, owner_pid, run_id, created_at) VALUES ('cache', ?, ?, ?, ?)",
          [@lease_token, @lease_owner_pid, run_id&.to_s, Time.now.utc.iso8601(6)]
        )
        @database.execute("COMMIT")
        @leased = true
        true
      rescue LeaseUnavailable
        raise
      rescue SQLite3::BusyException, SQLite3::LockedException
        begin
          @database.execute("ROLLBACK")
        rescue
          nil
        end
        raise LeaseUnavailable, "cache_lease_unavailable"
      rescue
        begin
          @database.execute("ROLLBACK")
        rescue
          nil
        end
        @lease_token = nil
        @lease_owner_pid = nil
        raise
      end

      def release_lease!
        return false unless @leased
        return false unless @lease_owner_pid == Process.pid
        raise PhaseError, "cache store is disconnected" unless connected?
        if @pending_abandonment
          return true if abandon_publication(*@pending_abandonment)
          raise LeaseUnavailable, "cache_lease_unavailable"
        end
        @database.execute("BEGIN IMMEDIATE")
        verify_lease!
        @database.execute("DELETE FROM leases WHERE name = 'cache' AND token = ?", [@lease_token])
        @database.execute("COMMIT")
        clear_lease
        true
      rescue SQLite3::BusyException, SQLite3::LockedException
        begin
          @database.execute("ROLLBACK")
        rescue
          nil
        end
        raise LeaseUnavailable, "cache_lease_unavailable"
      rescue
        begin
          @database.execute("ROLLBACK")
        rescue
          nil
        end
        raise
      end

      def connected?
        !@database.nil? && !@database.closed?
      end

      def disconnect_for_fork!
        raise PhaseError, "exclusive cache lease is required" unless @leased && @lease_owner_pid == Process.pid
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

      def generation
        value = metadata("generation")
        value && Integer(value)
      end

      def published_inventory
        return unless generation
        value = @database.get_first_value(
          "SELECT inventory_json FROM graph_generations WHERE id = ?",
          [generation]
        )
        value && CanonicalJSON.parse(value)
      rescue JSON::ParserError
        nil
      end

      def select(artifacts, context_signature:, roots: nil)
        current_generation = generation
        return Selection.new(mode: :full, tests: [], reasons: [recovery_reason || "cold_cache"], generation: current_generation) unless current_generation
        return Selection.new(mode: :full, tests: [], reasons: [recovery_reason], generation: current_generation) if recovery_reason
        return Selection.new(mode: :full, tests: [], reasons: ["context_changed"], generation: current_generation) unless metadata("context_signature") == context_signature
        return Selection.new(mode: :full, tests: [], reasons: ["unknown_artifact"], generation: current_generation) if artifacts.any? { |artifact| artifact.fingerprint.nil? || artifact.fingerprint.unknown? }

        stored_rows = @database.execute(
          "SELECT key, root, relative_path, facet, fingerprint, state, metadata_json FROM graph_artifacts WHERE generation_id = ?",
          [current_generation]
        )
        stored = stored_rows.to_h do |row|
          [row.fetch("key"), [row.fetch("fingerprint"), row.fetch("state")]]
        end
        current = artifacts.to_h { |artifact| [artifact.key, [artifact.fingerprint.digest, artifact.fingerprint.state.to_s]] }
        if roots && !hydrate_dynamic_artifacts!(current, stored_rows, roots)
          return Selection.new(mode: :full, tests: [], reasons: ["path_unresolved"], generation: current_generation)
        end
        new_keys = current.keys - stored.keys
        removed_keys = stored.keys - current.keys
        if (new_keys.any? || removed_keys.any?) && !membership_covers_artifact_set_change?(
          artifacts,
          stored_rows,
          stored,
          current,
          new_keys,
          removed_keys
        )
          return Selection.new(mode: :full, tests: [], reasons: ["artifact_set_changed"], generation: current_generation)
        end

        changed = current.filter_map { |key, value| key if stored.key?(key) && stored[key] != value }
        dirty_rows = dirty_test_rows
        dirty = dirty_rows.map { |row| row.fetch("id") }
        dirty_reasons = dirty_rows.map { |row| "#{row.fetch("outcome")}_test" }.uniq.sort
        if changed.empty?
          mode = dirty.empty? ? :none : :subset
          return Selection.new(mode: mode, tests: dirty, reasons: dirty_reasons, generation: current_generation)
        end

        placeholders = (["?"] * changed.length).join(",")
        tests = @database.execute(
          "SELECT DISTINCT test_id FROM graph_edges WHERE generation_id = ? AND artifact_key IN (#{placeholders})",
          [current_generation, *changed]
        ).map { |row| row.fetch("test_id") }.concat(dirty).uniq.sort
        return Selection.new(mode: :full, tests: [], reasons: ["suite_dependency_changed"], generation: current_generation) if tests.include?("*")
        return Selection.new(mode: :full, tests: [], reasons: ["unclaimed_artifact_changed"], generation: current_generation) if tests.empty?

        Selection.new(mode: :subset, tests: tests, reasons: changed.sort, generation: current_generation)
      end

      def publish(report, outcomes: {}, publication_reason: nil, run_id: nil)
        raise PhaseError, "exclusive cache lease is required" unless @leased && @lease_owner_pid == Process.pid
        raise PhaseError, "cache store is disconnected" unless connected?
        @database.execute("BEGIN IMMEDIATE")
        verify_lease!
        previous_generation = generation
        normalized_outcomes = outcomes.to_h.each_with_object({}) do |(test_id, outcome), result|
          result[test_id.to_s] = outcome.to_sym
        rescue NoMethodError
          result[test_id.to_s] = :invalid
        end
        executed = report.executed_tests
        selected = report.selected_tests
        discovered = report.discovered_tests
        failed = normalized_outcomes.filter_map { |test_id, outcome| test_id if outcome == :failed }.uniq.sort
        skipped = normalized_outcomes.filter_map { |test_id, outcome| test_id if outcome == :skipped }.uniq.sort
        passed = normalized_outcomes.filter_map { |test_id, outcome| test_id if outcome == :passed }.uniq.sort
        ledger_complete = selected == executed && normalized_outcomes.keys.sort == executed &&
          normalized_outcomes.values.all? { |outcome| %i[passed failed skipped].include?(outcome) } &&
          (!report.full_run? || selected == discovered)
        unless report.complete? && ledger_complete
          mark_dirty(failed, outcome: :failed) if previous_generation && failed.any?
          mark_dirty(skipped, outcome: :skipped) if previous_generation && skipped.any?
          reason = report.diagnostics.include?("worker_incomplete") ? "worker_incomplete" : "provider_incomplete"
          set_metadata("recovery_required", reason)
          rejected = report.with_generation(previous_generation).unpublished(reason)
          finalize_run(run_id, rejected)
          finish_lease_transaction
          @recovery_reason = reason
          return rejected
        end
        if failed.any?
          mark_dirty(failed, outcome: :failed) if previous_generation
          rejected = report.with_generation(previous_generation).unpublished("test_failure")
          finalize_run(run_id, rejected)
          finish_lease_transaction
          return rejected
        end

        test_states = stored_test_states(skipped)
        unsafe_skips = skipped.select do |test_id|
          state = test_states[test_id]
          state && (state.fetch("outcome") != "skipped" || test_has_edges?(test_id))
        end
        recovering_skip = recovery_reason == "test_skip" && report.full_run?
        if unsafe_skips.any? && !recovering_skip
          mark_dirty(unsafe_skips, outcome: :skipped)
          set_metadata("recovery_required", "test_skip")
          rejected = report.with_generation(previous_generation).unpublished("test_skip")
          finalize_run(run_id, rejected)
          finish_lease_transaction
          @recovery_reason = "test_skip"
          return rejected
        end
        report = report.without_test_dependencies(skipped)
        if certify_known_skips?(report, skipped, test_states)
          certified = report.certified(previous_generation)
          finalize_run(run_id, certified)
          finish_lease_transaction
          return certified
        end

        same_context = previous_generation && metadata("context_signature") == report.context_signature
        current_keys = report.artifacts.map(&:key).uniq
        stored_keys = active_artifact_keys
        obsolete_keys = stored_keys - current_keys
        absent_tests = report.full_run? ? stored_test_ids - discovered : []
        unsafe_edges = edge_tests_for(obsolete_keys).reject do |test_id|
          executed.include?(test_id) || absent_tests.include?(test_id) || (test_id == "*" && report.full_run?)
        end
        if unsafe_edges.any?
          set_metadata("recovery_required", "provider_incomplete")
          rejected = report.with_generation(previous_generation).unpublished("provider_incomplete")
          finalize_run(run_id, rejected)
          finish_lease_transaction
          @recovery_reason = "provider_incomplete"
          return rejected
        end

        next_generation = (previous_generation || 0) + 1
        published = report.published(next_generation, reason: publication_reason)
        payload = published.to_h
        inventory = payload.fetch(:inventory)
        @database.execute(
          "INSERT INTO graph_generations(id, context_signature, inventory_json, created_at) VALUES (?, ?, ?, ?)",
          [next_generation, report.context_signature, CanonicalJSON.generate(inventory), Time.now.utc.iso8601(6)]
        )
        clone_generation(previous_generation, next_generation) if same_context
        report.artifacts.each { |artifact| upsert_artifact(artifact, next_generation) }

        passed.each do |test_id|
          @database.execute(
            "INSERT INTO graph_tests(generation_id, id, outcome, complete) VALUES (?, ?, 'passed', 1) ON CONFLICT(generation_id, id) DO UPDATE SET outcome='passed', complete=1",
            [next_generation, test_id]
          )
          @database.execute("DELETE FROM graph_edges WHERE generation_id = ? AND test_id = ?", [next_generation, test_id])
          @database.execute("DELETE FROM dirty_tests WHERE id = ?", [test_id])
        end
        skipped.each do |test_id|
          @database.execute(
            "INSERT INTO graph_tests(generation_id, id, outcome, complete) VALUES (?, ?, 'skipped', 0) ON CONFLICT(generation_id, id) DO UPDATE SET outcome='skipped', complete=0",
            [next_generation, test_id]
          )
          @database.execute("DELETE FROM graph_edges WHERE generation_id = ? AND test_id = ?", [next_generation, test_id])
          @database.execute("DELETE FROM dirty_tests WHERE id = ?", [test_id])
        end
        @database.execute("DELETE FROM graph_edges WHERE generation_id = ? AND test_id = '*'", [next_generation])
        report.dependencies.each do |dependency|
          next unless dependency.complete
          next unless dependency.test_id == "*" || passed.include?(dependency.test_id)
          @database.execute(
            "INSERT OR IGNORE INTO graph_edges(generation_id, test_id, artifact_key, provider) VALUES (?, ?, ?, ?)",
            [next_generation, dependency.test_id, dependency.artifact_key, dependency.provider.to_s]
          )
        end
        delete_tests(absent_tests, next_generation)
        delete_artifacts(obsolete_keys, next_generation)
        set_metadata("generation", next_generation.to_s)
        set_metadata("context_signature", report.context_signature)
        set_metadata("schema_version", SCHEMA_VERSION.to_s)
        @database.execute("DELETE FROM metadata WHERE key = 'recovery_required'")
        finalize_run(run_id, published, payload:)
        finish_lease_transaction
        @recovery_reason = nil
        @recovered_run_id = nil
        published
      # standard:disable Lint/RescueException
      rescue Exception
        begin
          @database.execute("ROLLBACK")
        rescue
          nil
        end
        @pending_abandonment = [run_id, "provider_incomplete"]
        abandon_publication(run_id, "provider_incomplete") if @leased && connected?
        raise
      end
      # standard:enable Lint/RescueException

      def explain(paths, generation: self.generation)
        terms = Array(paths).map(&:to_s)
        return [] unless generation
        rows = @database.execute(<<~SQL)
          SELECT graph_artifacts.root, graph_artifacts.relative_path, graph_artifacts.facet,
                 graph_artifacts.fingerprint, graph_edges.test_id, graph_edges.provider
          FROM graph_artifacts
          LEFT JOIN graph_edges
            ON graph_edges.generation_id = graph_artifacts.generation_id
           AND graph_edges.artifact_key = graph_artifacts.key
          WHERE graph_artifacts.generation_id = #{Integer(generation)}
          ORDER BY graph_artifacts.root, graph_artifacts.relative_path, graph_artifacts.facet, graph_edges.test_id
        SQL
        rows.filter_map do |row|
          logical = "#{row.fetch("root")}:#{row.fetch("relative_path")}"
          next unless terms.empty? || terms.any? do |term|
            logical.include?(term) || row.fetch("relative_path").include?(term) || row["test_id"].to_s.include?(term)
          end
          {
            path: logical,
            facet: row.fetch("facet"),
            fingerprint: row.fetch("fingerprint"),
            test_id: row["test_id"],
            provider: row["provider"]
          }
        end
      end

      def begin_run(run_id:, mode:, context_signature: nil)
        @database.execute(
          "INSERT OR IGNORE INTO run_receipts(id, mode, state, context_signature, base_generation_id, started_at) VALUES (?, ?, 'pending', ?, ?, ?)",
          [run_id.to_s, mode.to_s, context_signature, generation, Time.now.utc.iso8601(6)]
        )
        prune_run_receipts
        run_id.to_s
      end

      def record_report(run_id, report)
        @database.execute("BEGIN IMMEDIATE")
        finalize_run(run_id, report)
        @database.execute("COMMIT")
        report
      rescue
        begin
          @database.execute("ROLLBACK")
        rescue
          nil
        end
        raise
      end

      def certify(report, run_id:)
        raise PhaseError, "exclusive cache lease is required" unless @leased && @lease_owner_pid == Process.pid
        @database.execute("BEGIN IMMEDIATE")
        verify_lease!
        finalize_run(run_id, report)
        finish_lease_transaction
        report
      # standard:disable Lint/RescueException
      rescue Exception
        begin
          @database.execute("ROLLBACK")
        rescue
          nil
        end
        @pending_abandonment = [run_id, "provider_incomplete"]
        abandon_publication(run_id, "provider_incomplete") if @leased && connected?
        raise
      end
      # standard:enable Lint/RescueException

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
          "SELECT id, mode, state, base_generation_id, published_generation_id, publication_reason, started_at, finished_at FROM run_receipts ORDER BY started_at DESC LIMIT ?",
          [Integer(limit)]
        )
      end

      private

      def connect
        @database = SQLite3::Database.new(@path)
        @database.results_as_hash = true
        @database.busy_timeout = 0
        @database.execute("PRAGMA foreign_keys = ON")
      end

      def validate_or_rebuild!
        if schema_present?
          integrity = @database.get_first_value("PRAGMA integrity_check")
          raise SQLite3::CorruptException, integrity unless integrity == "ok"
          schema = metadata("schema_version")
          raise SchemaIncompatible, "schema mismatch" unless schema == SCHEMA_VERSION.to_s
        elsif database_empty?
          create_schema!
        else
          raise SchemaIncompatible, "metadata table is missing"
        end
      rescue SQLite3::BusyException, SQLite3::LockedException
        raise LeaseUnavailable, "cache_lease_unavailable"
      rescue SQLite3::CorruptException, SQLite3::NotADatabaseException, SchemaIncompatible
        quarantine_and_rebuild!
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
          CREATE TABLE graph_generations (
            id INTEGER PRIMARY KEY,
            context_signature TEXT NOT NULL,
            inventory_json TEXT NOT NULL,
            created_at TEXT NOT NULL
          );
          CREATE TABLE graph_artifacts (
            generation_id INTEGER NOT NULL REFERENCES graph_generations(id) ON DELETE CASCADE,
            key TEXT NOT NULL,
            root TEXT NOT NULL,
            relative_path TEXT NOT NULL,
            facet TEXT NOT NULL,
            fingerprint TEXT,
            state TEXT NOT NULL,
            reason TEXT,
            metadata_json TEXT NOT NULL,
            PRIMARY KEY(generation_id, key)
          );
          CREATE INDEX graph_artifacts_path ON graph_artifacts(generation_id, root, relative_path);
          CREATE TABLE graph_tests (
            generation_id INTEGER NOT NULL REFERENCES graph_generations(id) ON DELETE CASCADE,
            id TEXT NOT NULL,
            outcome TEXT NOT NULL,
            complete INTEGER NOT NULL CHECK (complete IN (0, 1)),
            PRIMARY KEY(generation_id, id)
          );
          CREATE TABLE graph_edges (
            generation_id INTEGER NOT NULL,
            test_id TEXT NOT NULL,
            artifact_key TEXT NOT NULL,
            provider TEXT NOT NULL,
            PRIMARY KEY(generation_id, test_id, artifact_key, provider),
            FOREIGN KEY(generation_id, artifact_key)
              REFERENCES graph_artifacts(generation_id, key) ON DELETE CASCADE
          );
          CREATE INDEX graph_edges_artifact ON graph_edges(generation_id, artifact_key, test_id);
          CREATE TABLE dirty_tests (
            id TEXT PRIMARY KEY,
            outcome TEXT NOT NULL
          );
          CREATE TABLE run_receipts (
            id TEXT PRIMARY KEY,
            mode TEXT NOT NULL,
            state TEXT NOT NULL CHECK (state IN ('pending', 'complete', 'abandoned')),
            context_signature TEXT,
            base_generation_id INTEGER,
            published_generation_id INTEGER,
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

      def quarantine_and_rebuild!
        begin
          @database.close
        rescue
          nil
        end
        timestamp = Time.now.utc.strftime("%Y%m%dT%H%M%S")
        quarantine = "#{@path}.corrupt-#{timestamp}-#{Process.pid}"
        File.rename(@path, quarantine)
        @recovery_reason = "cache_corrupt_rebuilt"
        connect
        create_schema!
      rescue SystemCallError => error
        raise Error, "cache_corrupt_quarantine_failed: #{error.message}"
      end

      def upsert_artifact(artifact, generation)
        metadata_json = CanonicalJSON.generate({members: artifact.members, scope: artifact.scope, test_ids: artifact.test_ids})
        @database.execute(<<~SQL, [generation, artifact.key, artifact.root.to_s, artifact.relative_path, artifact.facet, artifact.fingerprint&.digest, artifact.fingerprint&.state&.to_s || "unknown", artifact.reason&.to_s, metadata_json])
          INSERT INTO graph_artifacts(generation_id, key, root, relative_path, facet, fingerprint, state, reason, metadata_json)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
          ON CONFLICT(generation_id, key) DO UPDATE SET
            root=excluded.root,
            relative_path=excluded.relative_path,
            facet=excluded.facet,
            fingerprint=excluded.fingerprint,
            state=excluded.state,
            reason=excluded.reason,
            metadata_json=excluded.metadata_json
        SQL
      end

      def clone_generation(source, target)
        @database.execute(<<~SQL, [target, source])
          INSERT INTO graph_artifacts(
            generation_id, key, root, relative_path, facet, fingerprint, state, reason, metadata_json
          )
          SELECT ?, key, root, relative_path, facet, fingerprint, state, reason, metadata_json
          FROM graph_artifacts WHERE generation_id = ?
        SQL
        @database.execute(<<~SQL, [target, source])
          INSERT INTO graph_tests(generation_id, id, outcome, complete)
          SELECT ?, id, outcome, complete FROM graph_tests WHERE generation_id = ?
        SQL
        @database.execute(<<~SQL, [target, source])
          INSERT INTO graph_edges(generation_id, test_id, artifact_key, provider)
          SELECT ?, test_id, artifact_key, provider FROM graph_edges WHERE generation_id = ?
        SQL
      end

      def hydrate_dynamic_artifacts!(current, stored_rows, roots)
        normalized_roots = roots.transform_keys(&:to_s)
        resolver = PathResolver.new(roots)
        stored_rows.each do |row|
          next if current.key?(row.fetch("key"))
          root = normalized_roots[row.fetch("root")]
          next unless root
          lexical_path = File.join(root, row.fetch("relative_path"))
          locator = resolver.resolve(lexical_path)
          return false unless locator.root.to_s == row.fetch("root")
          path = locator.absolute_path
          fingerprint = case row.fetch("facet")
          when "content"
            ContentFingerprint.call(path)
          when "existence"
            File.exist?(path) ? Fingerprint.known(Digest::SHA256.hexdigest("EXISTS\0")) : Fingerprint.missing
          else
            next
          end
          current[row.fetch("key")] = [fingerprint.digest, fingerprint.state.to_s]
        end
        true
      rescue PathError, SystemCallError, ArgumentError
        false
      end

      def membership_covers_artifact_set_change?(artifacts, stored_rows, stored, current, new_keys, removed_keys)
        current_by_key = artifacts.to_h { |artifact| [artifact.key, artifact] }
        stored_by_key = stored_rows.to_h { |row| [row.fetch("key"), row] }
        membership_keys = (stored.keys & current.keys).select do |key|
          artifact = current_by_key[key]
          artifact&.facet == "membership" && stored[key] != current[key]
        end
        return false if membership_keys.empty?

        affected_paths = membership_keys.flat_map do |key|
          current_members = normalize_members(current_by_key.fetch(key).members)
          stored_metadata = CanonicalJSON.parse(stored_by_key.fetch(key).fetch("metadata_json"))
          stored_members = normalize_members(stored_metadata.fetch("members"))
          (current_members - stored_members) | (stored_members - current_members)
        end.uniq

        new_keys.all? do |key|
          artifact = current_by_key[key]
          artifact && artifact.facet != "membership" && affected_paths.include?(artifact.path)
        end && removed_keys.all? do |key|
          row = stored_by_key[key]
          row && row.fetch("facet") != "membership" && affected_paths.include?("#{row.fetch("root")}:#{row.fetch("relative_path")}")
        end
      rescue JSON::ParserError, KeyError, TypeError
        false
      end

      def normalize_members(members)
        Array(members).map { |member| member.to_s.sub(/\A\d{6}:/, "") }.uniq
      end

      def metadata(key)
        @database.get_first_value("SELECT value FROM metadata WHERE key = ?", [key])
      end

      def set_metadata(key, value)
        @database.execute("INSERT INTO metadata(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", [key, value])
      end

      def clear_lease
        @leased = false
        @lease_token = nil
        @lease_owner_pid = nil
      end

      def dirty_test_rows
        accepted = if generation
          @database.execute(
            "SELECT id, outcome FROM graph_tests WHERE generation_id = ? AND outcome != 'passed'",
            [generation]
          )
        else
          []
        end
        rows = accepted.to_h { |row| [row.fetch("id"), row.fetch("outcome")] }
        @database.execute("SELECT id, outcome FROM dirty_tests").each do |row|
          rows[row.fetch("id")] = row.fetch("outcome")
        end
        rows.sort.map { |id, outcome| {"id" => id, "outcome" => outcome} }
      end

      def mark_dirty(test_ids, outcome:)
        return if test_ids.empty?
        test_ids.each do |test_id|
          @database.execute(
            "INSERT INTO dirty_tests(id, outcome) VALUES (?, ?) ON CONFLICT(id) DO UPDATE SET outcome=excluded.outcome",
            [test_id, outcome.to_s]
          )
        end
      end

      def stored_test_states(test_ids)
        return {} if test_ids.empty?
        placeholders = (["?"] * test_ids.length).join(",")
        @database.execute(
          "SELECT id, outcome, complete FROM graph_tests WHERE generation_id = ? AND id IN (#{placeholders})",
          [generation, *test_ids]
        ).to_h { |row| [row.fetch("id"), row] }
      end

      def test_has_edges?(test_id)
        !@database.get_first_value(
          "SELECT 1 FROM graph_edges WHERE generation_id = ? AND test_id = ? LIMIT 1",
          [generation, test_id]
        ).nil?
      end

      def certify_known_skips?(report, skipped, test_states)
        return false unless generation
        return false unless report.selection_mode == :subset
        return false unless report.selected_tests == skipped && report.executed_tests == skipped
        return false unless skipped.all? do |test_id|
          state = test_states[test_id]
          state && state.fetch("outcome") == "skipped" && Integer(state.fetch("complete")).zero?
        end

        stored = @database.execute(
          "SELECT key, fingerprint, state FROM graph_artifacts WHERE generation_id = ?",
          [generation]
        ).to_h do |row|
          [row.fetch("key"), [row.fetch("fingerprint"), row.fetch("state")]]
        end
        current = report.artifacts.to_h do |artifact|
          [artifact.key, [artifact.fingerprint&.digest, artifact.fingerprint&.state&.to_s || "unknown"]]
        end
        stored == current
      end

      def stored_test_ids
        return [] unless generation
        @database.execute(
          "SELECT id FROM graph_tests WHERE generation_id = ?",
          [generation]
        ).map { |row| row.fetch("id") }
      end

      def edge_tests_for(artifact_keys)
        return [] if artifact_keys.empty?
        placeholders = (["?"] * artifact_keys.length).join(",")
        @database.execute(
          "SELECT DISTINCT test_id FROM graph_edges WHERE generation_id = ? AND artifact_key IN (#{placeholders})",
          [generation, *artifact_keys]
        ).map { |row| row.fetch("test_id") }
      end

      def delete_tests(test_ids, target_generation)
        return if test_ids.empty?
        placeholders = (["?"] * test_ids.length).join(",")
        @database.execute(
          "DELETE FROM graph_edges WHERE generation_id = ? AND test_id IN (#{placeholders})",
          [target_generation, *test_ids]
        )
        @database.execute(
          "DELETE FROM graph_tests WHERE generation_id = ? AND id IN (#{placeholders})",
          [target_generation, *test_ids]
        )
        @database.execute("DELETE FROM dirty_tests WHERE id IN (#{placeholders})", test_ids)
      end

      def delete_artifacts(artifact_keys, target_generation)
        return if artifact_keys.empty?
        placeholders = (["?"] * artifact_keys.length).join(",")
        @database.execute(
          "DELETE FROM graph_edges WHERE generation_id = ? AND artifact_key IN (#{placeholders})",
          [target_generation, *artifact_keys]
        )
        @database.execute(
          "DELETE FROM graph_artifacts WHERE generation_id = ? AND key IN (#{placeholders})",
          [target_generation, *artifact_keys]
        )
      end

      def active_artifact_keys
        return [] unless generation
        @database.execute(
          "SELECT key FROM graph_artifacts WHERE generation_id = ?",
          [generation]
        ).map { |row| row.fetch("key") }
      end

      def finalize_run(run_id, report, payload: nil)
        return report unless run_id
        unless payload
          payload = report.to_h
          inventory = published_inventory
          payload = payload.merge(inventory:) if inventory
        end
        @database.execute(
          <<~SQL,
            INSERT INTO run_receipts(
              id, mode, state, context_signature, base_generation_id,
              published_generation_id, publication_reason, report_schema_version,
              report_json, started_at, finished_at
            )
            VALUES (?, ?, 'complete', ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
              mode=excluded.mode,
              state='complete',
              context_signature=excluded.context_signature,
              published_generation_id=excluded.published_generation_id,
              publication_reason=excluded.publication_reason,
              report_schema_version=excluded.report_schema_version,
              report_json=excluded.report_json,
              finished_at=excluded.finished_at
          SQL
          [
            run_id.to_s,
            report.mode,
            report.context_signature,
            generation,
            report.generation,
            report.publication[:reason],
            payload.fetch(:schema_version),
            CanonicalJSON.generate(payload),
            Time.now.utc.iso8601(6),
            Time.now.utc.iso8601(6)
          ]
        )
        prune_history
        report
      end

      # standard:disable Lint/RescueException
      def abandon_publication(run_id, reason)
        @database.execute("BEGIN IMMEDIATE")
        verify_lease!
        set_metadata("recovery_required", reason)
        abandon_run(run_id, reason)
        @database.execute("DELETE FROM leases WHERE name = 'cache' AND token = ?", [@lease_token])
        @database.execute("COMMIT")
        clear_lease
        @pending_abandonment = nil
        @recovery_reason = reason
        @recovered_run_id = nil
        true
      rescue Exception
        begin
          @database.execute("ROLLBACK")
        rescue
          nil
        end
        false
      end
      # standard:enable Lint/RescueException

      def prune_history
        @database.execute(<<~SQL, [RETAIN_GENERATIONS])
          DELETE FROM graph_generations
          WHERE id IN (
            SELECT id FROM graph_generations
            ORDER BY id DESC
            LIMIT -1 OFFSET ?
          )
        SQL
        prune_run_receipts
      end

      def prune_run_receipts
        @database.execute(<<~SQL, [@retained_reports])
          DELETE FROM run_receipts
          WHERE id IN (
            SELECT id FROM run_receipts
            ORDER BY started_at DESC, rowid DESC
            LIMIT -1 OFFSET ?
          )
          AND id NOT IN (
            SELECT run_id FROM leases
            WHERE name = 'cache' AND run_id IS NOT NULL
          )
        SQL
      end

      def abandon_run(run_id, reason)
        return unless run_id
        @database.execute(
          "UPDATE run_receipts SET state='abandoned', publication_reason=?, finished_at=? WHERE id=? AND state='pending'",
          [reason, Time.now.utc.iso8601(6), run_id.to_s]
        )
      end

      def verify_lease!
        row = @database.get_first_row("SELECT token, owner_pid FROM leases WHERE name = 'cache'")
        valid = row && row.fetch("token") == @lease_token && Integer(row.fetch("owner_pid")) == @lease_owner_pid
        raise LeaseUnavailable, "cache_lease_unavailable" unless valid
      end

      def finish_lease_transaction
        @database.execute("DELETE FROM leases WHERE name = 'cache' AND token = ?", [@lease_token])
        @database.execute("COMMIT")
        clear_lease
      end

      def process_alive?(pid)
        Process.kill(0, pid)
        true
      rescue Errno::ESRCH
        false
      rescue Errno::EPERM
        true
      end
    end
  end
end

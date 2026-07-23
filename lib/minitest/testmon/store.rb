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
      SCHEMA_VERSION = 3
      SchemaIncompatible = Class.new(StandardError)

      attr_reader :path, :recovery_reason, :recovered_run_id

      def initialize(path)
        @path = File.expand_path(path)
        @leased = false
        @lease_token = nil
        @lease_owner_pid = nil
        @recovery_reason = nil
        FileUtils.mkdir_p(File.dirname(@path))
        connect
        validate_or_rebuild!
        @recovery_reason ||= metadata("recovery_required")
      end

      def close
        release_lease! if @leased && @lease_owner_pid == Process.pid && connected?
        @database&.close
        @database = nil
      end

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
        value = metadata("published_inventory")
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

        stored_rows = @database.execute("SELECT key, root, relative_path, facet, fingerprint, state, metadata_json FROM artifacts")
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
        tests = @database.execute("SELECT DISTINCT test_id FROM edges WHERE artifact_key IN (#{placeholders})", changed).map { |row| row.fetch("test_id") }.concat(dirty).uniq.sort
        return Selection.new(mode: :full, tests: [], reasons: ["suite_dependency_changed"], generation: current_generation) if tests.include?("*")
        return Selection.new(mode: :full, tests: [], reasons: ["unclaimed_artifact_changed"], generation: current_generation) if tests.empty?

        Selection.new(mode: :subset, tests: tests, reasons: changed.sort, generation: current_generation)
      end

      def publish(report, outcomes: {}, publication_reason: nil)
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
          finish_lease_transaction
          @recovery_reason = reason
          return report.with_generation(previous_generation).unpublished(reason)
        end
        if failed.any?
          mark_dirty(failed, outcome: :failed) if previous_generation
          finish_lease_transaction
          return report.with_generation(previous_generation).unpublished("test_failure")
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
          finish_lease_transaction
          @recovery_reason = "test_skip"
          return report.with_generation(previous_generation).unpublished("test_skip")
        end
        report = report.without_test_dependencies(skipped)
        if certify_known_skips?(report, skipped, test_states)
          finish_lease_transaction
          return report.certified(previous_generation)
        end

        reset_for_context!(report.context_signature)
        current_keys = report.artifacts.map(&:key).uniq
        stored_keys = @database.execute("SELECT key FROM artifacts").map { |row| row.fetch("key") }
        obsolete_keys = stored_keys - current_keys
        absent_tests = report.full_run? ? stored_test_ids - discovered : []
        unsafe_edges = edge_tests_for(obsolete_keys).reject do |test_id|
          executed.include?(test_id) || absent_tests.include?(test_id) || (test_id == "*" && report.full_run?)
        end
        if unsafe_edges.any?
          set_metadata("recovery_required", "provider_incomplete")
          finish_lease_transaction
          @recovery_reason = "provider_incomplete"
          return report.with_generation(previous_generation).unpublished("provider_incomplete")
        end

        next_generation = (previous_generation || 0) + 1
        @database.execute(
          "INSERT INTO generations(id, context_signature, complete) VALUES (?, ?, 1)",
          [next_generation, report.context_signature]
        )
        report.artifacts.each { |artifact| upsert_artifact(artifact, next_generation) }

        passed.each do |test_id|
          @database.execute("INSERT INTO tests(id, outcome, complete, generation) VALUES (?, 'passed', 1, ?) ON CONFLICT(id) DO UPDATE SET outcome='passed', complete=1, generation=excluded.generation", [test_id, next_generation])
          @database.execute("DELETE FROM edges WHERE test_id = ?", [test_id])
        end
        skipped.each do |test_id|
          @database.execute("INSERT INTO tests(id, outcome, complete, generation) VALUES (?, 'skipped', 0, ?) ON CONFLICT(id) DO UPDATE SET outcome='skipped', complete=0, generation=excluded.generation", [test_id, next_generation])
          @database.execute("DELETE FROM edges WHERE test_id = ?", [test_id])
        end
        @database.execute("DELETE FROM edges WHERE test_id = '*' ")
        report.dependencies.each do |dependency|
          next unless dependency.complete
          next unless dependency.test_id == "*" || passed.include?(dependency.test_id)
          @database.execute(
            "INSERT OR IGNORE INTO edges(test_id, artifact_key, provider, generation) VALUES (?, ?, ?, ?)",
            [dependency.test_id, dependency.artifact_key, dependency.provider.to_s, next_generation]
          )
        end
        delete_tests(absent_tests)
        delete_artifacts(obsolete_keys)
        set_metadata("generation", next_generation.to_s)
        set_metadata("context_signature", report.context_signature)
        set_metadata("schema_version", SCHEMA_VERSION.to_s)
        set_metadata("published_inventory", CanonicalJSON.generate(report.to_h.fetch(:inventory)))
        @database.execute("DELETE FROM metadata WHERE key = 'recovery_required'")
        finish_lease_transaction
        @recovery_reason = nil
        @recovered_run_id = nil
        report.published(next_generation, reason: publication_reason)
      rescue
        begin
          @database.execute("ROLLBACK")
        rescue
          nil
        end
        release_lease! if @leased && connected?
        raise
      end

      def explain(paths)
        terms = Array(paths).map(&:to_s)
        rows = @database.execute(<<~SQL)
          SELECT artifacts.root, artifacts.relative_path, artifacts.facet,
                 artifacts.fingerprint, edges.test_id, edges.provider
          FROM artifacts
          LEFT JOIN edges ON edges.artifact_key = artifacts.key
          ORDER BY artifacts.root, artifacts.relative_path, artifacts.facet, edges.test_id
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
          CREATE TABLE generations (
            id INTEGER PRIMARY KEY,
            context_signature TEXT NOT NULL,
            complete INTEGER NOT NULL CHECK (complete IN (0, 1))
          );
          CREATE TABLE artifacts (
            key TEXT PRIMARY KEY,
            root TEXT NOT NULL,
            relative_path TEXT NOT NULL,
            facet TEXT NOT NULL,
            fingerprint TEXT,
            state TEXT NOT NULL,
            reason TEXT,
            metadata_json TEXT NOT NULL,
            generation INTEGER NOT NULL REFERENCES generations(id)
          );
          CREATE INDEX artifacts_path ON artifacts(root, relative_path);
          CREATE TABLE tests (
            id TEXT PRIMARY KEY,
            outcome TEXT NOT NULL,
            complete INTEGER NOT NULL CHECK (complete IN (0, 1)),
            generation INTEGER NOT NULL REFERENCES generations(id)
          );
          CREATE TABLE edges (
            test_id TEXT NOT NULL,
            artifact_key TEXT NOT NULL REFERENCES artifacts(key),
            provider TEXT NOT NULL,
            generation INTEGER NOT NULL REFERENCES generations(id),
            PRIMARY KEY(test_id, artifact_key, provider)
          );
          CREATE INDEX edges_artifact ON edges(artifact_key, test_id);
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

      def reset_for_context!(signature)
        return if metadata("context_signature").nil? || metadata("context_signature") == signature
        @database.execute("DELETE FROM edges")
        @database.execute("DELETE FROM tests")
        @database.execute("DELETE FROM artifacts")
        @database.execute("DELETE FROM generations")
        @database.execute("DELETE FROM metadata WHERE key IN ('generation', 'context_signature')")
      end

      def upsert_artifact(artifact, generation)
        metadata_json = CanonicalJSON.generate({members: artifact.members, scope: artifact.scope, test_ids: artifact.test_ids})
        @database.execute(<<~SQL, [artifact.key, artifact.root.to_s, artifact.relative_path, artifact.facet, artifact.fingerprint&.digest, artifact.fingerprint&.state&.to_s || "unknown", artifact.reason&.to_s, metadata_json, generation])
          INSERT INTO artifacts(key, root, relative_path, facet, fingerprint, state, reason, metadata_json, generation)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
          ON CONFLICT(key) DO UPDATE SET
            root=excluded.root,
            relative_path=excluded.relative_path,
            facet=excluded.facet,
            fingerprint=excluded.fingerprint,
            state=excluded.state,
            reason=excluded.reason,
            metadata_json=excluded.metadata_json,
            generation=excluded.generation
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
        @database.execute("SELECT id, outcome FROM tests WHERE outcome != 'passed' ORDER BY id")
      end

      def mark_dirty(test_ids, outcome:)
        return if test_ids.empty?
        placeholders = (["?"] * test_ids.length).join(",")
        @database.execute(
          "UPDATE tests SET outcome = ?, complete = 0 WHERE id IN (#{placeholders})",
          [outcome.to_s, *test_ids]
        )
      end

      def stored_test_states(test_ids)
        return {} if test_ids.empty?
        placeholders = (["?"] * test_ids.length).join(",")
        @database.execute(
          "SELECT id, outcome, complete FROM tests WHERE id IN (#{placeholders})",
          test_ids
        ).to_h { |row| [row.fetch("id"), row] }
      end

      def test_has_edges?(test_id)
        !@database.get_first_value("SELECT 1 FROM edges WHERE test_id = ? LIMIT 1", [test_id]).nil?
      end

      def certify_known_skips?(report, skipped, test_states)
        return false unless generation
        return false unless report.selection_mode == :subset
        return false unless report.selected_tests == skipped && report.executed_tests == skipped
        return false unless skipped.all? do |test_id|
          state = test_states[test_id]
          state && state.fetch("outcome") == "skipped" && Integer(state.fetch("complete")).zero?
        end

        stored = @database.execute("SELECT key, fingerprint, state FROM artifacts").to_h do |row|
          [row.fetch("key"), [row.fetch("fingerprint"), row.fetch("state")]]
        end
        current = report.artifacts.to_h do |artifact|
          [artifact.key, [artifact.fingerprint&.digest, artifact.fingerprint&.state&.to_s || "unknown"]]
        end
        stored == current
      end

      def stored_test_ids
        @database.execute("SELECT id FROM tests").map { |row| row.fetch("id") }
      end

      def edge_tests_for(artifact_keys)
        return [] if artifact_keys.empty?
        placeholders = (["?"] * artifact_keys.length).join(",")
        @database.execute(
          "SELECT DISTINCT test_id FROM edges WHERE artifact_key IN (#{placeholders})",
          artifact_keys
        ).map { |row| row.fetch("test_id") }
      end

      def delete_tests(test_ids)
        return if test_ids.empty?
        placeholders = (["?"] * test_ids.length).join(",")
        @database.execute("DELETE FROM edges WHERE test_id IN (#{placeholders})", test_ids)
        @database.execute("DELETE FROM tests WHERE id IN (#{placeholders})", test_ids)
      end

      def delete_artifacts(artifact_keys)
        return if artifact_keys.empty?
        placeholders = (["?"] * artifact_keys.length).join(",")
        @database.execute("DELETE FROM edges WHERE artifact_key IN (#{placeholders})", artifact_keys)
        @database.execute("DELETE FROM artifacts WHERE key IN (#{placeholders})", artifact_keys)
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

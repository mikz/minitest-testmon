# frozen_string_literal: true

module MinitestTestmonAcceptance
  class RailsCliOracle
    class Mismatch < StandardError; end

    FLAGS = %w[--testmon --testmon-db --testmon-report].freeze

    def self.assert_help!(result, state_files:, report_exists:)
      errors = []
      errors << "help exited #{result.exitstatus.inspect}" unless result.exitstatus == 0
      FLAGS.each { |flag| errors << "help omitted #{flag}" unless result.stdout.include?(flag) }
      errors << "help created Testmon state" unless state_files.empty?
      errors << "help created Testmon report" if report_exists
      raise Mismatch, errors.join("; ") unless errors.empty?

      true
    end

    def self.assert_plain_help!(result, state_files:, report_exists:)
      errors = []
      errors << "plain help exited #{result.exitstatus.inspect}" unless result.exitstatus == 0
      FLAGS.each { |flag| errors << "plain help advertised #{flag}" if result.stdout.include?(flag) }
      errors << "plain help created Testmon state" unless state_files.empty?
      errors << "plain help created Testmon report" if report_exists
      raise Mismatch, errors.join("; ") unless errors.empty?

      true
    end

    def self.assert_inert!(result, state_files:, report_exists:)
      errors = []
      errors << "plain Rails command exited #{result.exitstatus.inspect}" unless result.exitstatus == 0
      errors << "plain Rails command created Testmon state" unless state_files.empty?
      errors << "plain Rails command created Testmon report" if report_exists
      raise Mismatch, errors.join("; ") unless errors.empty?

      true
    end

    def self.assert_full_cold!(report)
      discovered = report.dig("tests", "discovered")
      selected = report.dig("tests", "selected")
      executed = report.dig("tests", "executed")
      errors = []
      errors << "cold suite was empty" if discovered.empty?
      errors << "cold selection was partial" unless selected == discovered
      errors << "cold execution was partial" unless executed == discovered
      errors << "cold report was not ready" unless report.fetch("ready")
      errors << "cold report was not published" unless report.dig("publication", "published")
      errors << "cold generation was not an Integer" unless report.fetch("generation").is_a?(Integer)
      raise Mismatch, errors.join("; ") unless errors.empty?

      true
    end

    def self.assert_warm!(cold, warm, selected:)
      errors = []
      errors << "warm discovery changed" unless warm.dig("tests", "discovered") == cold.dig("tests", "discovered")
      errors << "warm selection mismatch" unless warm.dig("tests", "selected") == selected.sort
      errors << "warm execution mismatch" unless warm.dig("tests", "executed") == selected.sort
      errors << "warm generation changed" unless warm.fetch("generation") == cold.fetch("generation")
      raise Mismatch, errors.join("; ") unless errors.empty?

      true
    end

    def self.assert_rejected_unchanged!(result, before:, after:, marker:, exitstatus: 2)
      errors = []
      expected_statuses = Array(exitstatus)
      errors << "rejection exited #{result.exitstatus.inspect}" unless expected_statuses.include?(result.exitstatus)
      errors << "rejection executed a test body" if marker.exist?
      errors << "database bytes changed" unless after.database_files == before.database_files
      errors << "report bytes changed" unless after.report_bytes == before.report_bytes
      raise Mismatch, errors.join("; ") unless errors.empty?

      true
    end

    def self.assert_native_partial_rejection!(result, marker:, state_files:, report_exists:)
      errors = []
      errors << "partial command exited #{result.exitstatus.inspect}" if result.exitstatus == 0
      errors << "partial command executed a test body" if marker.exist?
      errors << "partial command created Testmon state" unless state_files.empty?
      errors << "partial command created Testmon report" if report_exists
      raise Mismatch, errors.join("; ") unless errors.empty?

      true
    end

    def self.assert_retained_generation!(baseline, rejected, reason:)
      errors = []
      errors << "generation changed" unless rejected.fetch("generation") == baseline.fetch("generation")
      errors << "inventory changed" unless rejected.fetch("inventory") == baseline.fetch("inventory")
      errors << "publication succeeded" unless rejected.dig("publication", "published") == false
      errors << "reason was #{rejected.dig("publication", "reason").inspect}" unless
        rejected.dig("publication", "reason") == reason
      raise Mismatch, errors.join("; ") unless errors.empty?

      true
    end

    def self.assert_worker_equivalence!(reports)
      keys = %w[context_signature bundles inventory]
      drift = keys.reject { |key| reports.map { |report| report.fetch(key) }.uniq.one? }
      test_drift = %w[discovered selected executed].reject do |key|
        reports.map { |report| report.dig("tests", key) }.uniq.one?
      end
      return true if drift.empty? && test_drift.empty?

      raise Mismatch, "worker drift: report=#{drift.inspect} tests=#{test_drift.inspect}"
    end
  end
end

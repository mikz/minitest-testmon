# frozen_string_literal: true

module MinitestTestmonAcceptance
  class AdversarialOracle
    class Mismatch < StandardError; end

    def self.assert_preserved_unpublished!(baseline, report, reason: nil)
      errors = []
      errors << "generation changed" unless baseline.fetch("generation") == report.fetch("generation")
      errors << "inventory changed" unless baseline.fetch("inventory") == report.fetch("inventory")
      errors << "publication succeeded" unless report.dig("publication", "published") == false
      if reason && report.dig("publication", "reason") != reason
        errors << "publication reason was #{report.dig("publication", "reason").inspect}, expected #{reason.inspect}"
      end
      return true if errors.empty?

      raise Mismatch, errors.join("; ")
    end

    def self.assert_full_recovery!(report)
      discovered = report.dig("tests", "discovered")
      selected = report.dig("tests", "selected")
      executed = report.dig("tests", "executed")
      errors = []
      errors << "selection was not full" unless selected == discovered
      errors << "execution was not full" unless executed == discovered
      errors << "recovery was not published" unless report.dig("publication", "published") == true
      return true if errors.empty?

      raise Mismatch, errors.join("; ")
    end

    def self.assert_warm_zero!(report)
      selected = report.dig("tests", "selected")
      executed = report.dig("tests", "executed")
      return true if selected == [] && executed == []

      raise Mismatch, "warm run was not empty: selected=#{selected.inspect} executed=#{executed.inspect}"
    end

    # Normalized representation of the documented JSONL merge contract. Each
    # completed worker record contributes exactly one test_id.
    def self.assert_worker_results_complete!(selected:, worker_results:)
      ids = worker_results.map { |record| record.fetch("test_id") }
      duplicates = ids.tally.select { |_test_id, count| count > 1 }.keys.sort
      missing = selected - ids
      unexpected = ids.uniq - selected
      return true if duplicates.empty? && missing.empty? && unexpected.empty?

      raise Mismatch,
        "worker results invalid: missing=#{missing.sort.inspect} " \
        "duplicates=#{duplicates.inspect} unexpected=#{unexpected.sort.inspect}"
    end

    def self.assert_pruned!(report, test_id)
      test_lists = %w[discovered selected executed].to_h do |name|
        [name, report.dig("tests", name)]
      end
      inventory_ids = report.fetch("inventory").values.flat_map do |category|
        category.fetch("items").flat_map { |item| item.fetch("test_ids") }
      end
      present = test_lists.filter_map { |name, ids| name if ids.include?(test_id) }
      present << "inventory" if inventory_ids.include?(test_id)
      return true if present.empty?

      raise Mismatch, "removed test #{test_id.inspect} remained in #{present.join(", ")}"
    end

    def self.assert_suite_scoped!(report, provider:, path_suffix:)
      matches = report.dig("inventory", "suite_scoped", "items").select do |item|
        item.fetch("provider") == provider && item.fetch("path")&.end_with?(path_suffix)
      end
      return matches.first if matches.length == 1 && matches.first.fetch("scope") == "suite"

      raise Mismatch,
        "expected one suite-scoped #{provider} artifact ending #{path_suffix.inspect}; got #{matches.inspect}"
    end

    def self.assert_one_physical_artifact!(report, path_suffix:, providers:)
      items = report.fetch("inventory").values.flat_map { |category| category.fetch("items") }
      matches = items.select { |item| item.fetch("path")&.end_with?(path_suffix) }
      actual_providers = matches.map { |item| item.fetch("provider") }.uniq.sort
      paths = matches.map { |item| item.fetch("path") }.uniq
      fingerprints = matches.filter_map { |item| item.fetch("fingerprint") }.uniq
      errors = []
      errors << "providers=#{actual_providers.inspect}" unless actual_providers == providers.sort
      errors << "canonical paths=#{paths.inspect}" unless paths.length == 1
      errors << "fingerprints=#{fingerprints.inspect}" unless fingerprints.length == 1
      return matches if errors.empty?

      raise Mismatch, "physical artifact was not canonical: #{errors.join("; ")}"
    end

    def self.assert_late_background_observation!(report, path_suffix:)
      observations = report.fetch("observations").values.flat_map { |category| category.fetch("items") }
      matches = observations.select { |item| item.fetch("path")&.end_with?(path_suffix) }
      safe = matches.select do |item|
        item.fetch("scope") == "suite" && item.fetch("test_id").nil? && item.fetch("reason") == "ambiguous_context"
      end
      return safe.first unless safe.empty?

      raise Mismatch, "late background access was missing or attached to a test: #{matches.inspect}"
    end
  end
end

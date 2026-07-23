# frozen_string_literal: true

module MinitestTestmonAcceptance
  class Golden
    class Mismatch < StandardError; end

    def self.assert_full_discovery!(report)
      discovered = report.dig("tests", "discovered")
      executed = report.dig("tests", "executed")
      raise Mismatch, "discovery filtered tests: discovered=#{discovered.inspect} executed=#{executed.inspect}" unless discovered == executed
    end

    def self.assert_observation!(report, category:, **expected)
      items = report.dig("observations", category.to_s, "items") || []
      return items.find { |item| expected.all? { |key, value| value === item.fetch(key.to_s) } } if items.any? { |item| expected.all? { |key, value| value === item.fetch(key.to_s) } }

      summary_keys = %w[kind path operation reason scope test_id exists_at_observation]
      summaries = items.map { |item| item.slice(*summary_keys) }
      raise Mismatch, "missing #{category} observation matching #{expected.inspect}; got #{summaries.inspect}"
    end

    def self.assert_inventory_claims_resolve!(report)
      inventory = report.dig("inventory", "claimed", "items") || []
      by_key = inventory.to_h { |item| [item.fetch("key"), item] }
      claimed = report.dig("observations", "claimed", "items") || []

      unresolved = claimed.reject { |observation| by_key.key?(observation.fetch("key")) }
      return true if unresolved.empty?

      raise Mismatch, "claimed observations missing claimed inventory: #{unresolved.map { |item| item.fetch("key") }.inspect}"
    end

    def self.assert_selection_sound!(report, impacted_ids)
      selected = report.dig("tests", "selected") || []
      missing = impacted_ids - selected
      return true if missing.empty?

      raise Mismatch, "selection missed impacted tests: #{missing.inspect}; selected=#{selected.inspect}"
    end
  end
end

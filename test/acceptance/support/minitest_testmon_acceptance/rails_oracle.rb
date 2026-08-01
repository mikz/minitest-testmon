# frozen_string_literal: true

module MinitestTestmonAcceptance
  class RailsOracle
    BUNDLES = %w[
      rails.assets@1 rails.boot@1 rails.fixtures@1 rails.locales@1 rails.schema@1 rails.views@1
    ].freeze

    class Mismatch < StandardError; end

    def self.assert_auto_bundles!(report)
      missing = BUNDLES - report.fetch("bundles")
      errors = []
      errors << "missing auto Rails bundles: #{missing.inspect}" unless missing.empty?
      errors << "umbrella label rails_8_1 was published as a provider" if report.fetch("bundles").include?("rails_8_1")
      return true if errors.empty?

      raise Mismatch, "#{errors.join("; ")}; got #{report.fetch("bundles").inspect}"
    end

    def self.assert_provider_claim!(report, provider:, path_suffix: nil, facet: nil)
      matches = inventory_items(report).select do |item|
        item.fetch("provider") == provider &&
          (path_suffix.nil? || item.fetch("path", "").to_s.end_with?(path_suffix)) &&
          (facet.nil? || item.fetch("facet") == facet)
      end
      return true unless matches.empty?

      raise Mismatch,
        "missing #{provider} inventory claim#{" for *#{path_suffix}" if path_suffix}#{" (#{facet})" if facet}; " \
        "claims=#{inventory_items(report).map { |item| [item["provider"], item["facet"], item["path"]] }.inspect}"
    end

    def self.assert_warm_zero!(report)
      selected = report.dig("tests", "selected")
      executed = report.dig("tests", "executed")
      return true if selected == [] && executed == []

      raise Mismatch, "unchanged warm run selected/executed app tests: selected=#{selected.inspect} executed=#{executed.inspect}"
    end

    def self.assert_equivalent!(reports)
      signatures = reports.map { |report| report.fetch("context_signature") }.uniq
      bundles = reports.map { |report| report.fetch("bundles") }.uniq
      selected = reports.map { |report| report.dig("tests", "selected") }.uniq
      inventory = reports.map { |report| report.fetch("inventory") }.uniq
      return true if signatures.one? && bundles.one? && selected.one? && inventory.one?

      raise Mismatch,
        "worker reports differ: signatures=#{signatures.inspect} bundles=#{bundles.inspect} selected=#{selected.inspect} inventory_variants=#{inventory.length}"
    end

    def self.assert_rejected_before_marker!(result:, report:, marker:)
      errors = []
      errors << "thread-mode command exited zero" if result.success?
      errors << "stderr omitted Rails process parallelization" unless result.stderr.include?("Rails process parallelization")
      errors << "test marker exists" if marker.exist?
      if report
        errors << "publication was not false" unless report.dig("publication", "published") == false
        errors << "wrong publication reason" unless report.dig("publication", "reason") == "unsupported_parallelism"
      end
      return true if errors.empty?

      raise Mismatch, errors.join("; ")
    end

    def self.inventory_items(report)
      report.fetch("inventory").values.flat_map { |category| category.fetch("items") }
    end
    private_class_method :inventory_items
  end
end

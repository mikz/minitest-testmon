# frozen_string_literal: true

module MinitestTestmonAcceptance
  class ProviderOracle
    RAILS_BUILTIN_IDS = %w[
      rails.boot@1 rails.fixtures@1 rails.locales@1 rails.schema@1 rails.views@1
    ].freeze

    class Mismatch < StandardError; end

    def self.assert_full_run!(report)
      discovered = report.dig("tests", "discovered")
      selected = report.dig("tests", "selected")
      executed = report.dig("tests", "executed")
      return true if discovered == selected && discovered == executed

      raise Mismatch,
        "expected full run: discovered=#{discovered.inspect} selected=#{selected.inspect} executed=#{executed.inspect}"
    end

    def self.assert_preserved_publication!(baseline, interrupted)
      errors = []
      errors << "generation changed" unless baseline.fetch("generation") == interrupted.fetch("generation")
      errors << "inventory changed" unless baseline.fetch("inventory") == interrupted.fetch("inventory")
      return true if errors.empty?

      raise Mismatch, errors.join("; ")
    end

    def self.assert_suggestion_codes!(report, expected)
      actual = report.fetch("suggestions").map { |suggestion| suggestion.fetch("code") }.uniq.sort
      expected = expected.sort
      return true if actual == expected

      raise Mismatch, "suggestion codes differ: expected=#{expected.inspect} actual=#{actual.inspect}"
    end

    def self.assert_inventory_excludes!(report, path_suffix)
      matches = inventory_items(report).filter_map { |item| item.fetch("path") }.grep(/#{Regexp.escape(path_suffix)}\z/)
      return true if matches.empty?

      raise Mismatch, "frozen inventory admitted runtime path *#{path_suffix}: #{matches.inspect}"
    end

    def self.assert_definition_snapshot!(snapshot, expected_ids:)
      errors = []
      errors << "provider collection is mutable" unless snapshot.fetch("providers_frozen")
      errors << "provider mutation did not raise FrozenError" unless snapshot.fetch("mutation_error") == "FrozenError"
      ids = snapshot.fetch("providers").map { |provider| provider.fetch("id") }
      missing = expected_ids - ids
      errors << "missing provider IDs #{missing.inspect}" unless missing.empty?
      mutable = snapshot.fetch("providers").reject do |provider|
        provider.fetch("definition_frozen") && provider.fetch("collections_frozen").values.all?
      end
      errors << "mutable provider definitions #{mutable.map { |provider| provider.fetch("id") }.inspect}" unless mutable.empty?
      return true if errors.empty?

      raise Mismatch, errors.join("; ")
    end

    def self.assert_api_unchanged!(clean, active)
      clean_api = clean.except("ancestors")
      active_api = active.except("ancestors")
      clean_ancestors = clean.fetch("ancestors")
      active_ancestors = active.fetch("ancestors")
      errors = []
      unless clean_api == active_api
        errors << "method owners, signatures, or source locations changed"
      end
      unless clean_ancestors.keys == active_ancestors.keys
        errors << "ancestor targets changed"
      end
      (clean_ancestors.keys & active_ancestors.keys).each do |target|
        unless clean_ancestors.fetch(target).tally == active_ancestors.fetch(target).tally
          errors << "#{target} ancestors were added or removed"
        end
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

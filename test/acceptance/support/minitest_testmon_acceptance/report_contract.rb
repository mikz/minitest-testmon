# frozen_string_literal: true

module MinitestTestmonAcceptance
  class ReportContract
    TOP_LEVEL_KEYS = %w[
      schema_version mode complete ready diagnostics generation context_signature
      bundles tests observations inventory suggestions publication
    ].freeze
    TEST_KEYS = %w[discovered selected executed].freeze
    OBSERVATION_KEYS = %w[claimed ignored uncovered unresolved].freeze
    INVENTORY_KEYS = %w[claimed suite_scoped verified_empty unresolved].freeze
    OBSERVATION_ITEM_KEYS = %w[
      key kind provider path operation scope test_id callsite
      exists_at_observation reason
    ].freeze
    INVENTORY_ITEM_KEYS = %w[
      key provider facet path members scope test_ids fingerprint reason
    ].freeze
    SUGGESTION_KEYS = %w[code path event ruby].freeze
    SUGGESTION_CODES = %w[
      uncovered_file opaque_c_call uncovered_notification outside_root
      path_set_churn
    ].freeze
    SCOPES = %w[test suite].freeze
    INVENTORY_SCOPES = %w[test suite none].freeze
    FACETS = %w[content existence membership ruby_source].freeze
    REASON_CODES = %w[
      nonexistent outside_root non_regular
      conservative_file_construction opaque_c_call source_race
      ambiguous_context late_activation provider_incomplete worker_incomplete
      invalid_configuration user_ignored uncovered_file
      uncovered_event observer_unavailable observer_error extractor_error
      noncanonical_observation claim_path_missing
    ].freeze

    class Violation < StandardError; end

    def self.validate!(report)
      object!(report, "report")
      exact_keys!(report, TOP_LEVEL_KEYS, "report")

      fail!("schema_version must equal 2") unless report.fetch("schema_version") == 2
      string!(report.fetch("mode"), "mode")
      boolean!(report.fetch("complete"), "complete")
      boolean!(report.fetch("ready"), "ready")
      sorted_string_array!(report.fetch("diagnostics"), "diagnostics")
      nullable_integer!(report.fetch("generation"), "generation")
      nonempty_string!(report.fetch("context_signature"), "context_signature")
      sorted_string_array!(report.fetch("bundles"), "bundles")
      validate_suggestions!(report.fetch("suggestions"))

      validate_tests!(report.fetch("tests"))
      validate_categories!(report.fetch("observations"), OBSERVATION_KEYS, :observation)
      validate_categories!(report.fetch("inventory"), INVENTORY_KEYS, :inventory)
      validate_publication!(report.fetch("publication"))
      fail!("complete report cannot contain diagnostics") if report.fetch("complete") && !report.fetch("diagnostics").empty?
      expected_ready = report.fetch("complete") && report.dig("publication", "published")
      fail!("ready must equal complete && publication.published") unless report.fetch("ready") == expected_ready
      true
    end

    def self.validate_tests!(tests)
      object!(tests, "tests")
      exact_keys!(tests, TEST_KEYS, "tests")

      TEST_KEYS.each do |key|
        values = tests.fetch(key)
        array!(values, "tests.#{key}")
        fail!("tests.#{key} must contain only Strings") unless values.all?(String)
        fail!("tests.#{key} must be sorted") unless values == values.sort
        fail!("tests.#{key} must not contain duplicates") unless values.uniq == values
      end
    end

    def self.validate_categories!(container, keys, item_type)
      object!(container, item_type.to_s)
      exact_keys!(container, keys, item_type.to_s)

      keys.each do |key|
        category = container.fetch(key)
        object!(category, "#{item_type}.#{key}")
        exact_keys!(category, %w[count items], "#{item_type}.#{key}")
        count = category.fetch("count") { fail!("#{item_type}.#{key} missing count") }
        items = category.fetch("items") { fail!("#{item_type}.#{key} missing items") }
        integer!(count, "#{item_type}.#{key}.count")
        array!(items, "#{item_type}.#{key}.items")
        fail!("#{item_type}.#{key} count mismatch") unless count == items.length
        validate_items!(items, item_type, "#{item_type}.#{key}")
      end
    end

    def self.validate_items!(items, item_type, location)
      expected_keys = (item_type == :observation) ? OBSERVATION_ITEM_KEYS : INVENTORY_ITEM_KEYS
      items.each_with_index do |item, index|
        item_location = "#{location}.items[#{index}]"
        object!(item, item_location)
        exact_keys!(item, expected_keys, item_location)
        nonempty_string!(item.fetch("key"), "#{item_location}.key")

        if item_type == :observation
          validate_observation_item!(item, item_location)
        else
          validate_inventory_item!(item, item_location)
        end
      end
    end

    def self.validate_observation_item!(item, location)
      string!(item.fetch("kind"), "#{location}.kind")
      nullable_string!(item.fetch("provider"), "#{location}.provider")
      nullable_string!(item.fetch("path"), "#{location}.path")
      nullable_string!(item.fetch("operation"), "#{location}.operation")
      enum!(item.fetch("scope"), SCOPES, "#{location}.scope")
      nullable_string!(item.fetch("test_id"), "#{location}.test_id")
      nullable_boolean!(item.fetch("exists_at_observation"), "#{location}.exists_at_observation")
      nullable_string!(item.fetch("reason"), "#{location}.reason")
      reason_code!(item.fetch("reason"), "#{location}.reason")

      callsite = item.fetch("callsite")
      return if callsite.nil?

      object!(callsite, "#{location}.callsite")
      exact_keys!(callsite, %w[path line owner], "#{location}.callsite")
      string!(callsite.fetch("path"), "#{location}.callsite.path")
      integer!(callsite.fetch("line"), "#{location}.callsite.line")
      nullable_string!(callsite.fetch("owner"), "#{location}.callsite.owner")
    end

    def self.validate_inventory_item!(item, location)
      nonempty_string!(item.fetch("provider"), "#{location}.provider")
      enum!(item.fetch("facet"), FACETS, "#{location}.facet")
      nullable_string!(item.fetch("path"), "#{location}.path")
      enum!(item.fetch("scope"), INVENTORY_SCOPES, "#{location}.scope")
      nullable_string!(item.fetch("fingerprint"), "#{location}.fingerprint")
      nullable_string!(item.fetch("reason"), "#{location}.reason")
      reason_code!(item.fetch("reason"), "#{location}.reason")

      members = item.fetch("members")
      unless members.nil?
        array!(members, "#{location}.members")
        fail!("#{location}.members must contain only Strings") unless members.all?(String)
      end

      test_ids = item.fetch("test_ids")
      array!(test_ids, "#{location}.test_ids")
      fail!("#{location}.test_ids must contain only Strings") unless test_ids.all?(String)
    end

    def self.validate_publication!(publication)
      object!(publication, "publication")
      exact_keys!(publication, %w[published reason], "publication")
      boolean!(publication.fetch("published"), "publication.published")
      nullable_string!(publication.fetch("reason"), "publication.reason")
    end

    def self.validate_suggestions!(suggestions)
      array!(suggestions, "suggestions")
      suggestions.each_with_index do |suggestion, index|
        location = "suggestions[#{index}]"
        object!(suggestion, location)
        exact_keys!(suggestion, SUGGESTION_KEYS, location)
        enum!(suggestion.fetch("code"), SUGGESTION_CODES, "#{location}.code")
        nullable_string!(suggestion.fetch("path"), "#{location}.path")
        nullable_string!(suggestion.fetch("event"), "#{location}.event")
        nullable_string!(suggestion.fetch("ruby"), "#{location}.ruby")
      end
      expected = suggestions.sort_by do |suggestion|
        SUGGESTION_KEYS.map { |key| suggestion.fetch(key).to_s }
      end
      fail!("suggestions must be sorted by code, path, event, ruby") unless suggestions == expected
      fail!("suggestions must not contain duplicates") unless suggestions.uniq == suggestions
    end

    def self.sorted_string_array!(value, location)
      array!(value, location)
      fail!("#{location} must contain only Strings") unless value.all?(String)
      fail!("#{location} must be sorted") unless value == value.sort
      fail!("#{location} must not contain duplicates") unless value.uniq == value
    end

    def self.exact_keys!(object, expected, location)
      missing = expected - object.keys
      extra = object.keys - expected
      return if missing.empty? && extra.empty?

      fail!("#{location} keys differ: missing=#{missing.inspect} extra=#{extra.inspect}")
    end

    def self.object!(value, location)
      fail!("#{location} must be an Object") unless value.is_a?(Hash)
    end

    def self.array!(value, location)
      fail!("#{location} must be an Array") unless value.is_a?(Array)
    end

    def self.integer!(value, location)
      fail!("#{location} must be an Integer") unless value.is_a?(Integer)
    end

    def self.string!(value, location)
      fail!("#{location} must be a String") unless value.is_a?(String)
    end

    def self.nonempty_string!(value, location)
      string!(value, location)
      fail!("#{location} must not be empty") if value.empty?
    end

    def self.boolean!(value, location)
      fail!("#{location} must be Boolean") unless value == true || value == false
    end

    def self.nullable_integer!(value, location)
      integer!(value, location) unless value.nil?
    end

    def self.nullable_string!(value, location)
      string!(value, location) unless value.nil?
    end

    def self.nullable_boolean!(value, location)
      boolean!(value, location) unless value.nil?
    end

    def self.enum!(value, allowed, location)
      fail!("#{location} must be one of #{allowed.join(", ")}") unless allowed.include?(value)
    end

    def self.reason_code!(value, location)
      return if value.nil?
      enum!(value, REASON_CODES, location)
    end

    def self.fail!(message)
      raise Violation, message
    end
  end
end

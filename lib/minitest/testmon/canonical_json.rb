# frozen_string_literal: true

module Minitest
  module Testmon
    module CanonicalJSON
      module_function

      def parse(value)
        json.parse(value)
      end

      def normalize(value)
        case value
        when Hash
          pairs = value.map { |key, item| [key.to_s, normalize(item)] }
          suggestion_keys = %w[code path event ruby]
          pairs = pairs.sort_by(&:first) unless pairs.map(&:first) == suggestion_keys
          pairs.to_h
        when Array
          value.map { |item| normalize(item) }
        when Symbol
          value.to_s
        when Data
          normalize(value.to_h)
        else
          value
        end
      end

      def generate(value, pretty: false)
        normalized = normalize(value)
        pretty ? json.pretty_generate(normalized) : json.generate(normalized)
      end

      # Stable primitive encoding for hashes used before an application has
      # chosen and loaded its JSON implementation.
      def fingerprint(value)
        Marshal.dump(normalize(value))
      end

      def json
        require "json" unless defined?(::JSON)
        ::JSON
      end
    end
  end
end

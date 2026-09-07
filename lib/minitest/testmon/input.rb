# frozen_string_literal: true

module Minitest
  module Testmon
    INPUT_SCOPES = %i[test suite].freeze

    InputId = Data.define(:provider, :key) do
      def initialize(provider:, key:)
        super(provider: provider.to_s.freeze, key: key.to_s.freeze)
      end

      def to_s
        "#{provider}:#{key}"
      end
    end

    Input = Data.define(:key, :provider, :facet, :root, :relative_path, :fingerprint, :members, :scope) do
      def initialize(key:, provider:, facet:, fingerprint:, root: nil, relative_path: nil, members: [], scope: :test)
        normalized_scope = scope.to_sym
        raise ArgumentError, "input scope must be :test or :suite" unless INPUT_SCOPES.include?(normalized_scope)

        super(
          key: key.to_s.freeze,
          provider: provider.to_s.freeze,
          facet: facet.to_s.freeze,
          root: root&.to_s&.freeze,
          relative_path: relative_path&.to_s&.freeze,
          fingerprint: fingerprint,
          members: Array(members).map { |member| member.to_s.freeze }.uniq.sort.freeze,
          scope: normalized_scope
        )
      end

      def id
        InputId.new(provider: provider, key: key)
      end

      def known?
        fingerprint && !fingerprint.unknown?
      end

      def suite?
        scope == :suite
      end
    end
  end
end

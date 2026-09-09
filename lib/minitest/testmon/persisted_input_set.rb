# frozen_string_literal: true

require "digest"

module Minitest
  module Testmon
    # The encoding includes every column persisted for an input. Input#members
    # and fingerprint reasons are not part of the existing Store format.
    class PersistedInputSet
      attr_reader :id, :rows

      def initialize(inputs)
        @rows = inputs.map do |input|
          [input.provider, input.key, input.facet, input.root, input.relative_path,
            input.fingerprint.digest, input.scope.to_s, input.fingerprint.state.to_s].freeze
        end.sort_by { |row| row.first(2) }.freeze
        @id = Digest::SHA256.hexdigest(CanonicalJSON.generate(["suite-input-set-v1", @rows])).freeze
        freeze
      end
    end
  end
end

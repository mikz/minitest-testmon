# frozen_string_literal: true

require "digest"

module Minitest
  module Testmon
    Fingerprint = Data.define(:state, :digest, :reason) do
      def known?
        state == :known
      end

      def missing?
        state == :missing
      end

      def unknown?
        state == :unknown
      end

      def self.known(digest)
        new(state: :known, digest: digest, reason: nil)
      end

      def self.missing
        new(state: :missing, digest: Digest::SHA256.hexdigest("MISSING\0"), reason: :nonexistent)
      end

      def self.unknown(reason)
        new(state: :unknown, digest: nil, reason: reason.to_sym)
      end
    end

    module ContentFingerprint
      module_function

      def call(path)
        return Fingerprint.missing unless File.exist?(path)
        return Fingerprint.unknown(:non_regular) unless File.file?(path)

        digest = Digest::SHA256.file(path).hexdigest
        Fingerprint.known(digest)
      rescue Errno::ENOENT
        Fingerprint.missing
      rescue SystemCallError, IOError
        Fingerprint.unknown(:source_race)
      end
    end
  end
end

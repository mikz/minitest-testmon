# frozen_string_literal: true

module Minitest
  module Testmon
    class Error < StandardError; end
    class ConfigurationError < Error; end
    class PhaseError < Error; end
    class PathError < Error; end
    class UnsupportedISeq < Error; end
    class LeaseUnavailable < Error; end
    class UnsupportedParallelism < Error; end
    class ObserverUnavailable < Error; end
  end
end

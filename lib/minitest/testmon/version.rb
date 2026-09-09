# frozen_string_literal: true

module Minitest
  module Testmon
    GEM_ROOT = File.realpath(File.expand_path("../../..", __dir__))
    VERSION = "0.1.0"
    FINGERPRINT_ALGORITHM_VERSION = 5
    SELECTION_ALGORITHM_VERSION = 3
  end
end

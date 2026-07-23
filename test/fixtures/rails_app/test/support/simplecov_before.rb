# frozen_string_literal: true

require "simplecov"

SimpleCov.start do
  enable_coverage :branch
  coverage_dir ENV.fetch("RAILS_ACCEPTANCE_COVERAGE_DIR")
end

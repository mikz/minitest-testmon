# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "open3"
# standard:disable Lint/RedundantRequireStatement
require "pathname"
# standard:enable Lint/RedundantRequireStatement
require "securerandom"
require "shellwords"
require "tmpdir"

module MinitestTestmonAcceptance
  REPOSITORY_ROOT = Pathname.new(File.expand_path("../../..", __dir__))
  ROOT = REPOSITORY_ROOT.join("test/acceptance")
  FIXTURES = REPOSITORY_ROOT.join("test/fixtures")
  GEMFILE = REPOSITORY_ROOT.join("Gemfile")
  EXECUTABLE = REPOSITORY_ROOT.join("exe/minitest-testmon")
end

require_relative "minitest_testmon_acceptance/driver"
require_relative "minitest_testmon_acceptance/adversarial_oracle"
require_relative "minitest_testmon_acceptance/golden"
require_relative "minitest_testmon_acceptance/project"
require_relative "minitest_testmon_acceptance/provider_oracle"
require_relative "minitest_testmon_acceptance/rails_oracle"
require_relative "minitest_testmon_acceptance/rails_cli_driver"
require_relative "minitest_testmon_acceptance/rails_cli_oracle"
require_relative "minitest_testmon_acceptance/rails_runtime"
require_relative "minitest_testmon_acceptance/reporter_oracle"
require_relative "minitest_testmon_acceptance/report_contract"

# frozen_string_literal: true

require_relative "test/support/reporter_compat"

ReporterCompat.configure!

ENV["RAILS_ENV"] = "test"
require_relative "config/environment"
require "rails/test_help"
require "active_record/fixtures"

ReporterCompat::PublicApiSnapshot.write(ENV.fetch("REPORTER_API_SNAPSHOT_PATH"))

# frozen_string_literal: true

require_relative "boot"
require "rails"
require "active_model/railtie"
require "active_record/railtie"
require "action_controller/railtie"
require "action_view/railtie"
require "rails/test_unit/railtie"
require_relative "../lib/rails_policy_loader"

Bundler.require(*Rails.groups)

module TestmonRailsAcceptance
  class Application < Rails::Application
    APP_BODY_POLICY = RailsPolicyLoader.load(
      File.expand_path("../custom_inputs/application.yml", __dir__)
    ).freeze

    config.load_defaults 8.1
    config.eager_load = false
    config.secret_key_base = "minitest-testmon-rails-acceptance-secret"
    config.hosts.clear
    config.logger = Logger.new(nil)
    config.action_controller.allow_forgery_protection = false
  end
end

# frozen_string_literal: true

Rails.application.configure do
  config.cache_classes = true
  config.consider_all_requests_local = true
  config.eager_load = false
  config.public_file_server.enabled = false
  config.action_controller.perform_caching = false
  config.active_support.deprecation = :stderr
end

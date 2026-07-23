# frozen_string_literal: true

require "minitest/testmon"

Minitest::Testmon.configure do |config|
  config.provider :rails_custom_inputs, version: 1 do |provider|
    provider.inventory :policies,
      root: :project,
      base: ".",
      include: [
        "config/policies/**/*.{yml,yaml}",
        "custom_inputs/**/*.{yml,yaml}"
      ],
      exclude: []
    provider.facet :content,
      inventory: :policies,
      digest: :content,
      granularity: :file,
      scope: :test
    provider.observe_tracepoint :policy_loaded,
      target: "RailsPolicyLoader.load",
      event: :call,
      path: ->(trace) { trace.local(:path) }
    provider.claim :policy_loaded, to: [:policies, :content], path: :path
    provider.observe_notification :policy_rendered,
      "render.rails_policy",
      path: ->(event) { event.payload.fetch(:identifier) }
    provider.claim :policy_rendered, to: [:policies, :content], path: :path
  end
end

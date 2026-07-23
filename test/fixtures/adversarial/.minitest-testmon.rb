# frozen_string_literal: true

require "minitest/testmon"

Minitest::Testmon.configure do |config|
  config.provider :race_inputs, version: 1 do |provider|
    provider.inventory :files,
      root: :project,
      base: ".",
      include: [
        "data/atomic.txt",
        "data/background.txt",
        "data/background_trigger.txt",
        "data/content.txt",
        "data/content_trigger.txt",
        "data/membership_trigger.txt",
        "data/removed.txt",
        "data/skip.txt",
        "data/symlink.txt",
        "data/symlink_trigger.txt"
      ],
      exclude: []
    provider.facet :content,
      inventory: :files,
      digest: :content,
      granularity: :file,
      scope: :test
    provider.observe_tracepoint :adversarial_file_loaded,
      target: "AdversarialLoader.read",
      event: :call,
      path: ->(trace) { trace.local(:path) }
    provider.claim :adversarial_file_loaded, to: [:files, :content], path: :path

    provider.inventory :catalog,
      root: :project,
      base: ".",
      include: ["catalog/**/*.txt"],
      exclude: []
    provider.facet :membership,
      inventory: :catalog,
      digest: :paths,
      granularity: :set,
      scope: :test
    provider.observe_tracepoint :adversarial_catalog_listed,
      target: "AdversarialLoader.entries",
      event: :call,
      path: ->(trace) { trace.local(:path) }
    provider.claim :adversarial_catalog_listed, to: [:catalog, :membership], path: :path
  end

  config.provider :suite_inputs, version: 1 do |provider|
    provider.inventory :files,
      root: :project,
      base: ".",
      include: ["data/suite.txt"],
      exclude: []
    provider.facet :content,
      inventory: :files,
      digest: :content,
      granularity: :file,
      scope: :suite
    provider.observe_tracepoint :adversarial_file_loaded,
      target: "AdversarialLoader.read",
      event: :call,
      path: ->(trace) { trace.local(:path) }
    provider.claim :adversarial_file_loaded, to: [:files, :content], path: :path
  end

  %i[overlap_a overlap_b].each do |name|
    config.provider name, version: 1 do |provider|
      provider.inventory :files,
        root: :project,
        base: ".",
        include: ["data/overlap.txt"],
        exclude: []
      provider.facet :content,
        inventory: :files,
        digest: :content,
        granularity: :file,
        scope: :test
      provider.observe_tracepoint :adversarial_file_loaded,
        target: "AdversarialLoader.read",
        event: :call,
        path: ->(trace) { trace.local(:path) }
      provider.claim :adversarial_file_loaded, to: [:files, :content], path: :path
    end
  end
end

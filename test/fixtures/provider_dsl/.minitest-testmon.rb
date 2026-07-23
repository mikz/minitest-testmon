# frozen_string_literal: true

require "minitest/testmon"
require "json"

Minitest::Testmon.configure do |config|
  config.root :shared, "shared"

  config.provider :pricing_rules, version: 1 do |provider|
    provider.inventory :rules,
      root: :project,
      base: ".",
      include: ["config/pricing/**/*.{yml,yaml}"],
      exclude: ["**/*.generated"]
    provider.facet :content,
      inventory: :rules,
      digest: :content,
      granularity: :file,
      scope: :test
    provider.claim :file_read, to: [:rules, :content], path: :path
    provider.observe_tracepoint :policy_loaded,
      target: ((ENV["MISSING_STARTUP_OBSERVER"] == "1") ? "MissingPolicyLoader.load" : "PolicyLoader.load"),
      event: :call,
      path: lambda { |trace|
        marker = ENV["TRACE_WRAPPER_MARKER"]
        if marker
          File.write(marker, JSON.generate(
            event: trace.event,
            method_id: trace.method_id,
            path: trace.path,
            lineno: trace.lineno,
            local_path: trace.local(:path)
          ))
        end
        trace.local(:path)
      },
      details: lambda { |trace|
        if ENV["NONCANONICAL_DETAILS"] == "1"
          {line: trace.lineno}
        else
          {"line" => trace.lineno}
        end
      }
    provider.claim :policy_loaded, to: [:rules, :content], path: :path
    provider.observe_tracepoint :generated_file,
      target: "GeneratedLoader.load",
      event: :call,
      path: ->(trace) { trace.local(:path) }
    provider.ignore :generated_file,
      reason: "generated",
      predicate: ->(observation) { observation.path&.end_with?(".generated") }
  end

  config.provider :template_catalog, version: 1 do |provider|
    provider.inventory :templates,
      root: :project,
      base: ".",
      include: ["templates/**/*.txt"],
      exclude: []
    provider.inventory :archive,
      root: :project,
      base: ".",
      include: ["template_archive/**/*.txt"],
      exclude: []
    provider.facet :membership,
      inventory: :templates,
      digest: :paths,
      granularity: :set,
      scope: :test
    provider.facet :all_contents,
      inventory: :archive,
      digest: :contents,
      granularity: :set,
      scope: :suite
    provider.observe_tracepoint :templates_listed,
      target: "TemplateCatalog.entries",
      event: :call,
      path: ->(trace) { trace.local(:path) }
    provider.claim :templates_listed, to: [:templates, :membership], path: :path
  end

  config.provider :documents, version: 1 do |provider|
    provider.inventory :documents,
      root: :project,
      base: ".",
      include: ["config/documents/**/*.{yml,yaml}"],
      exclude: []
    provider.facet :content,
      inventory: :documents,
      digest: :content,
      granularity: :file,
      scope: :test
    notification_path = lambda do |event|
      raise "planted extractor failure" if ENV["FAIL_NOTIFICATION_EXTRACTOR"] == "1"

      path = event.payload.fetch(:identifier)
      marker = ENV["NOTIFICATION_WRAPPER_MARKER"]
      if marker
        payload = event.payload
        nested = payload.fetch(:metadata)
        File.write(marker, JSON.generate(
          name: event.name,
          payload_frozen: payload.frozen?,
          nested_frozen: nested.frozen?,
          tags_frozen: nested.fetch(:tags).frozen?
        ))
      end
      if ENV["NONCANONICAL_NOTIFICATION"] == "1"
        "#{File.dirname(path)}/../#{File.basename(File.dirname(path))}/#{File.basename(path)}"
      else
        path
      end
    end
    provider.observe_notification :document_rendered,
      "render.document",
      path: notification_path
    provider.claim :document_rendered, to: [:documents, :content], path: :path
    provider.observe_notification :audit_recorded,
      "audit.document",
      path: ->(event) { event.payload[:identifier] }
  end

  config.provider :shared_configuration, version: 1 do |provider|
    provider.inventory :shared,
      root: :shared,
      base: ".",
      include: ["**/*.yml"],
      exclude: []
    provider.facet :existence,
      inventory: :shared,
      digest: :existence,
      granularity: :file,
      scope: :suite
    provider.claim :file_open, to: [:shared, :existence], path: :path
  end

  config.provider :resolver_inputs, version: 1 do |provider|
    provider.inventory :resolver_files,
      root: :project,
      base: ".",
      include: ["config/resolver/**/*.{yml,yaml}"],
      exclude: []
    provider.facet :content,
      inventory: :resolver_files,
      digest: :content,
      granularity: :file,
      scope: :test
    provider.observe_tracepoint :resolver_loaded,
      target: "ResolverLoader.load",
      event: :call,
      path: ->(trace) { trace.local(:path) }
    resolver = lambda do |observation, facet|
      marker = ENV["RESOLVER_WRAPPER_MARKER"]
      if marker
        File.write(marker, JSON.generate(
          name: facet.name,
          digest: facet.digest,
          granularity: facet.granularity,
          scope: facet.scope,
          wrapper_frozen: facet.frozen?,
          keys_frozen: facet.artifact_keys.frozen?,
          keys_sorted: facet.artifact_keys == facet.artifact_keys.sort
        ))
      end
      next nil if ENV["RESOLVER_EMPTY"] == "1"
      next "definitely-undeclared-key" if ENV["RESOLVER_MISSING_KEY"] == "1"

      basename = File.basename(observation.path.to_s)
      facet.artifact_keys.find { |key| key.end_with?(basename) }
    end
    provider.claim :resolver_loaded, to: [:resolver_files, :content], using: resolver
  end

  config.provider :ruby_compatibility, version: 1 do |provider|
    provider.inventory :sources,
      root: :project,
      base: ".",
      include: ["lib/**/*.rb"],
      exclude: []
    provider.facet :iseq,
      inventory: :sources,
      digest: :ruby_iseq,
      granularity: :file,
      scope: :test
    provider.claim :file_read, to: [:sources, :iseq], path: :path
  end

  config.fileset :compat_templates,
    root: :project,
    base: ".",
    include: ["compat/**/*.txt"],
    exclude: [],
    mode: :contents,
    scope: :test
  config.fileset :compat_paths,
    root: :project,
    base: ".",
    include: ["compat_paths/**/*.txt"],
    exclude: [],
    mode: :paths,
    scope: :suite
end

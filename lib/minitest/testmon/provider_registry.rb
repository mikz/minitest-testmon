# frozen_string_literal: true

require "digest"
require_relative "input"

module Minitest
  module Testmon
    Registration = Data.define(:name, :provider, :version, :options) do
      def signature
        provider_signature = provider.signature if provider.respond_to?(:signature)
        {name: name.to_s, version: version, options: options, declaration: provider_signature}
      end
    end

    class SnapshotContext
      attr_reader :configuration, :resolver, :artifacts, :dependencies, :diagnostics

      def initialize(configuration)
        @configuration = configuration
        @resolver = PathResolver.new(configuration.roots)
        @artifacts = []
        @dependencies = []
        @diagnostics = []
        @capabilities = []
        @ruby_unhookable_paths = Hash.new { |hash, key| hash[key] = [] }
      end

      def add_artifact(artifact, test_id: nil, provider: artifact.provider)
        @artifacts << artifact
        @dependencies << Dependency.new(test_id: test_id || "*", artifact_key: artifact.key, provider: provider, complete: !artifact.fingerprint&.unknown?) if artifact.scope == :suite
        artifact
      end

      def incomplete(reason)
        @diagnostics << reason.to_s
      end

      def add_ruby_trace_capability(provider, locator, targets)
        unhookable = Array(targets)
        return if unhookable.empty?

        provider_id = provider.to_s
        @ruby_unhookable_paths[provider_id] << locator.absolute_path
        @capabilities << {
          kind: "ruby_target_trace",
          provider: provider_id,
          source: locator.key,
          requested_events: RUBY_TARGET_TRACE_EVENTS.map(&:to_s),
          unhookable: unhookable.map(&:signature).sort_by { |item| item.fetch(:identity) }
        }
      end

      def capabilities
        @capabilities.uniq.sort_by { |item| CanonicalJSON.generate(item) }.freeze
      end

      def ruby_unhookable_paths(provider)
        @ruby_unhookable_paths.fetch(provider.to_s, []).uniq.sort.freeze
      end
    end

    class ClaimContext
      attr_reader :artifacts, :dependencies, :diagnostics, :resolver, :observation_claims

      def initialize(snapshot_context, observations)
        @resolver = snapshot_context.resolver
        @artifacts = snapshot_context.artifacts.dup
        @dependencies = snapshot_context.dependencies.dup
        @diagnostics = snapshot_context.diagnostics.dup
        @observation_claims = Hash.new { |hash, key| hash[key] = [] }
        @observations = observations
        @observation_overrides = {}
        @suite_sources = snapshot_context.artifacts.select do |artifact|
          artifact.suite? && artifact.whole_file? && artifact.known?
        end.to_h { |artifact| [artifact.source_identity, artifact] }.freeze
      end

      def claim(artifact, observation, provider: artifact.provider)
        if observation.suite? && !artifact.suite?
          suite_source = artifact.whole_file? && @suite_sources[artifact.source_identity]
          return claim(suite_source, observation, provider: suite_source.provider) if suite_source
          if observation.explicit_suite_evidence? && artifact.whole_file? && artifact.known?
            return claim(artifact.with(scope: :suite, test_ids: [].freeze), observation, provider: artifact.provider)
          end
          reason = (observation.reason == :late_activation) ? :late_activation : :ambiguous_context
          incomplete(reason)
          unresolved(observation, reason)
          return
        end
        test_id = (observation.scope == :suite) ? "*" : observation.test_id
        unless test_id == "*"
          artifact = artifact.with(
            test_ids: [*artifact.test_ids, test_id].compact.uniq.sort.freeze
          )
        end
        @artifacts << artifact
        @dependencies << Dependency.new(test_id: test_id, artifact_key: artifact.key, provider: provider, complete: !artifact.fingerprint&.unknown?)
        @observation_claims[observation.key] << artifact.key
      end

      def incomplete(reason)
        @diagnostics << reason.to_s
      end

      def unresolved(observation, reason)
        @observation_overrides[observation.key] = observation.with(reason: reason.to_sym)
      end

      def observation_for(observation)
        @observation_overrides.fetch(observation.key, observation)
      end

      def observations
        @observations.map { |observation| observation_for(observation) }
      end
    end

    class ProviderRegistry
      def initialize
        @snapshot = false
      end

      def snapshot(configuration)
        raise PhaseError, "provider registry is already snapshotted" if @snapshot
        @snapshot = true
        configuration = configuration.snapshot
        configured = configuration.providers.map do |definition|
          Registration.new(
            name: definition.name,
            provider: ConfiguredProvider.new(definition),
            version: definition.version,
            options: {}.freeze
          )
        end
        registrations = configured.sort_by { |item| item.name.to_s }.freeze
        context = SnapshotContext.new(configuration)
        registrations.each { |item| item.provider.snapshot(context) if item.provider.respond_to?(:snapshot) }
        ProviderSnapshot.new(configuration, registrations, context)
      end
    end

    class ProviderSnapshot
      attr_reader :configuration, :registrations, :context, :signature, :snapshot_digest,
        :ruby_inventory_paths, :ruby_inventory_roots, :ruby_unhookable_paths,
        :current_inputs, :current_inputs_by_id

      def initialize(configuration, registrations, context)
        @configuration = configuration
        @registrations = registrations
        @context = context
        payload = {
          configuration: configuration.signature,
          providers: registrations.map(&:signature),
          capabilities: context.capabilities
        }
        @signature = Digest::SHA256.hexdigest(CanonicalJSON.generate(payload))
        inputs = context.artifacts.map(&:to_input)
        inputs << Input.new(
          key: "$context",
          provider: "testmon@#{Testmon::VERSION}",
          facet: :context,
          fingerprint: Fingerprint.known(@signature),
          scope: :suite
        )
        duplicates = inputs.group_by(&:id).select { |_id, matches| matches.length > 1 }.keys
        unless duplicates.empty?
          raise PhaseError, "duplicate provider input identities: #{duplicates.map(&:to_s).sort.join(", ")}"
        end
        @current_inputs = inputs.sort_by { |input| input.id.to_s }.freeze
        @current_inputs_by_id = @current_inputs.to_h { |input| [input.id, input] }.freeze
        @snapshot_digest = digest_snapshot(registrations, context)
        ruby_artifacts = context.artifacts.select do |artifact|
          artifact.provider == ruby_provider_id && artifact.facet == "ruby_source"
        end
        @ruby_inventory_paths = ruby_artifacts.map do |artifact|
          File.expand_path(artifact.relative_path, context.resolver.root(artifact.root))
        end.uniq.sort.freeze
        @ruby_inventory_roots = ruby_artifacts.map(&:root).uniq.sort.freeze
        @ruby_unhookable_paths = context.ruby_unhookable_paths(ruby_provider_id)
      end

      def observe(tests: {}, selected: [], suite_input_ids: [])
        ProviderSession.new(self, tests: tests, selected: selected, suite_input_ids: suite_input_ids).start
      end

      def test_definition_input(test_id)
        class_name, separator, method_name = test_id.to_s.rpartition("#")
        return unless separator == "#" && !class_name.empty? && !method_name.empty?

        runnable = if defined?(Minitest::Runnable)
          Minitest::Runnable.runnables.find { |candidate| candidate.to_s == class_name }
        end
        runnable ||= constantize_test_class(class_name)
        location = runnable&.instance_method(method_name)&.source_location
        return unless location&.first

        locator = context.resolver.resolve(location.first)
        candidates = current_inputs.select do |input|
          input.root == locator.root.to_s && input.relative_path == locator.relative_path
        end
        candidates.find { |input| input.facet == "content" } ||
          candidates.find { |input| input.facet == "ruby_source" }
      rescue NameError, PathError
        nil
      end

      def claims_event?(*event_kinds)
        expected = event_kinds.map(&:to_sym)
        registrations.any? do |registration|
          provider = registration.provider
          provider.respond_to?(:definition) &&
            provider.definition.claims.any? { |claim| expected.include?(claim.event_kind) }
        end
      end

      def source_stable?
        validation = current_validation_manifest
        return validation == @validated_manifest if @validated_manifest
        fresh_context = SnapshotContext.new(configuration)
        fresh_registrations = registrations.map do |registration|
          provider = if registration.provider.is_a?(ConfiguredProvider)
            ConfiguredProvider.new(registration.provider.definition, capability_cache: registration.provider.capability_cache)
          else
            registration.provider
          end
          Registration.new(
            name: registration.name,
            provider: provider,
            version: registration.version,
            options: registration.options
          )
        end
        fresh_registrations.each do |registration|
          registration.provider.snapshot(fresh_context) if registration.provider.is_a?(ConfiguredProvider)
        end
        return false unless digest_snapshot(fresh_registrations, fresh_context) == snapshot_digest
        if validation
          return false unless validation == current_validation_manifest
          @validated_manifest = validation
        end
        true
      rescue
        false
      end

      private

      def current_validation_manifest
        return unless registrations.all? { |item| item.provider.is_a?(ConfiguredProvider) }
        validation_context = SnapshotContext.new(configuration)
        payload = [configuration.current_config_source_manifest,
          RubyVM::InstructionSequence.compile_option,
          registrations.map { |item| ConfiguredProvider.new(item.provider.definition).validation_manifest(validation_context) },
          validation_context.diagnostics]
        Digest::SHA256.hexdigest(CanonicalJSON.generate(payload))
      end

      def constantize_test_class(name)
        name.split("::").reject(&:empty?).reduce(Object) do |owner, part|
          owner.const_get(part, false)
        end
      rescue NameError
        nil
      end

      def ruby_provider_id
        registration = registrations.find { |item| item.name == :ruby }
        definition = registration&.provider&.definition
        definition&.id&.to_sym
      end

      def digest_snapshot(items, snapshot_context)
        payload = {
          configuration_sources: configuration.current_config_source_manifest,
          capabilities: snapshot_context.capabilities,
          providers: items.map do |registration|
            {
              registration: registration.signature,
              manifest: registration.provider.respond_to?(:snapshot_manifest) ? registration.provider.snapshot_manifest : nil
            }
          end
        }
        Digest::SHA256.hexdigest(CanonicalJSON.generate(payload))
      end
    end

    class ProviderSession
      attr_reader :snapshot, :claimed_input_ids_by_test, :current_inputs

      def initialize(snapshot, tests:, selected:, suite_input_ids: [])
        @snapshot = snapshot
        @tests = tests
        @selected = selected
        @suite_input_ids = Array(suite_input_ids).uniq.freeze
        @observations = []
        @handles = []
        @executed = []
        @runtime_diagnostics = []
        @startup_complete = true
        @spool = nil
        @phase = :created
        @claimed_input_ids_by_test = {}.freeze
        @current_inputs = snapshot.current_inputs
      end

      def start
        transition!(:created, :observing)
        snapshot.registrations.each do |registration|
          handle = registration.provider.observe(self) if registration.provider.respond_to?(:observe)
          @handles << handle if handle
        rescue => error
          @startup_complete = false
          reason = error.is_a?(ObserverUnavailable) ? :observer_unavailable : :observer_error
          incomplete(reason)
          record(Observation.build(kind: :provider_error, provider: registration.name, operation: :observe, reason: reason, details: {error: error.class.name}))
        end
        self
      end

      def record(observation)
        return observation if @worker_sealed
        raise PhaseError, "observations are closed" unless @phase == :observing
        if ExecutionContext.evidence_scope == :suite && !observation.explicit_suite_evidence?
          observation = observation.as_suite_evidence
        end
        @spool ? @spool.record_observation(observation) : @observations << observation
        observation
      end

      def seal_completion(test_id, outcome)
        @spool&.seal_test(test_id, outcome, diagnostics: @runtime_diagnostics)
      end

      def executed(test_id)
        return test_id.to_s if @worker_sealed
        @spool ? @spool.record_executed(test_id.to_s) : @executed << test_id.to_s
      end

      def selected!(test_ids)
        raise PhaseError, "selection is closed" unless @phase == :observing
        @selected = Array(test_ids).map(&:to_s).uniq.sort
      end

      def retain_suite_input_ids!(input_ids)
        raise PhaseError, "selection is closed" unless @phase == :observing
        @suite_input_ids = Array(input_ids).uniq.freeze
      end

      def claimed_input_ids(test_id)
        @claimed_input_ids_by_test.fetch(test_id.to_s, [].freeze)
      end

      def startup_complete?
        @startup_complete
      end

      def attach_observer(handle)
        raise PhaseError, "observations are closed" unless @phase == :observing
        @handles << handle
        handle
      end

      def attach_spool(spool)
        raise PhaseError, "observations are closed" unless @phase == :observing
        @observations = []
        @executed = []
        @runtime_diagnostics = []
        @spool = spool
      end

      def import_observation(observation)
        raise PhaseError, "observations are closed" unless @phase == :observing
        @observations << observation
      end

      def import_executed(test_id)
        raise PhaseError, "observations are closed" unless @phase == :observing
        @executed << test_id.to_s
      end

      def incomplete(reason)
        @runtime_diagnostics << reason.to_s
      end

      def startup_incomplete(reason)
        @startup_complete = false
        incomplete(reason)
      end

      def close_observers_for_worker!
        errors = []
        @handles.reverse_each do |handle|
          handle.close if handle.respond_to?(:close)
        rescue => error
          errors << error
        end
        @handles = []
        errors.each do |error|
          record(Observation.build(
            kind: :provider_error,
            operation: :worker_observer_close,
            test_id: ExecutionContext.current_test,
            reason: :worker_incomplete,
            details: {error: error.class.name}
          ))
        rescue
          nil
        end
        errors.empty?
      end

      def seal_worker!
        @worker_sealed = true
      end

      def test_started(test)
        snapshot.registrations.each do |registration|
          registration.provider.test_started(test, self) if registration.provider.respond_to?(:test_started)
        rescue => error
          @startup_complete = false
          record(Observation.build(
            kind: :provider_error,
            provider: registration.name,
            operation: :test_started,
            test_id: "#{test.class}##{test.name}",
            reason: :provider_incomplete,
            details: {error: error.class.name}
          ))
        end
      end

      def finalize
        transition!(:observing, :claiming)
        @handles.reverse_each do |handle|
          handle.close if handle.respond_to?(:close)
        rescue => error
          @observations << Observation.build(kind: :provider_error, operation: :finalize, reason: :provider_incomplete, details: {error: error.class.name})
        end

        claims = process_claims
        snapshot.registrations.each do |registration|
          registration.provider.finalize(claims) if registration.provider.respond_to?(:finalize)
        rescue => error
          claims.incomplete("provider_incomplete:#{registration.name}:#{error.class}")
        end
        claims.incomplete(:source_drift) unless snapshot.source_stable?
        @phase = :finalized
        build_report(claims)
      end

      # Claim each observation once; checkpoints leave observers running. Providers
      # with a finalization hook cannot promise complete evidence before shutdown.
      def checkpoint_supported?
        snapshot.registrations.all? { |item| !item.provider.respond_to?(:finalize) }
      end

      def checkpoint_report
        raise PhaseError, "checkpoint requires active observers" unless @phase == :observing
        claims = process_claims
        @checkpoint_inputs ||= snapshot.current_inputs.to_h { |input| [input.id, input] }
        artifacts = claims.artifacts.drop(@checkpoint_artifact_count || 0)
        @checkpoint_artifact_count = claims.artifacts.length
        artifacts.each do |artifact|
          input = artifact.to_input
          previous = @checkpoint_inputs[input.id]
          if @suite_input_ids.include?(input.id) || previous&.scope == :suite
            input = input.with(scope: :suite)
          end
          @checkpoint_invalid = true if !input.known? || Observation::UNRESOLVED_REASONS.include?(artifact.reason)
          @checkpoint_inputs[input.id] = input
        end
        @checkpoint_dependencies ||= Hash.new { |hash, key| hash[key] = {} }
        dependencies = claims.dependencies.drop(@checkpoint_dependency_count || 0)
        @checkpoint_dependency_count = claims.dependencies.length
        dependencies.each do |dependency|
          next if dependency.test_id == "*"
          id = InputId.new(provider: dependency.provider, key: dependency.artifact_key)
          @checkpoint_dependencies[dependency.test_id][id] = true
        end
        @claimed_input_ids_by_test = @checkpoint_dependencies.transform_values { |ids| ids.keys.freeze }.freeze
        @current_inputs = @checkpoint_inputs.values.freeze
        DiscoveryReport.new(context_signature: snapshot.signature,
          complete: !@checkpoint_invalid, diagnostics: claims.diagnostics)
      end

      private

      def process_claims
        @claims ||= ClaimContext.new(snapshot.context, @observations)
        claims = @claims
        @runtime_diagnostics.each { |reason| claims.incomplete(reason) }
        pending = @observations.drop(@claimed_observation_count || 0)
        @claimed_observation_count = @observations.length
        @processed_observations ||= {}
        pending.each do |observation|
          next if @processed_observations[observation.key]
          @processed_observations[observation.key] = true
          # Late activation is a run-level completeness failure. A provider may
          # classify the observation as ignored for reporting, but it cannot
          # make evidence collected before its observer started complete.
          claims.incomplete(:late_activation) if observation.reason == :late_activation
          candidate_path = observation.details["candidate_path"] || observation.details[:candidate_path]
          callsite_path = observation.callsite && (observation.callsite["path"] || observation.callsite[:path])
          if observation.reason == :opaque_c_call && (candidate_path || callsite_path)
            candidate = candidate_path ? observation.with(path: candidate_path, reason: nil) : observation
            ignored = snapshot.registrations.any? do |registration|
              registration.provider.respond_to?(:ignore_observation) &&
                registration.provider.ignore_observation(candidate, claims)
            end
            next if ignored
          end
          if observation.unresolved? && !%i[outside_root late_activation].include?(observation.reason)
            next
          end
          ignored = snapshot.registrations.any? do |registration|
            registration.provider.respond_to?(:ignore_observation) &&
              registration.provider.ignore_observation(observation, claims)
          end
          next if ignored
          if observation.reason == :outside_root
            claims.incomplete(:outside_root)
            next
          end
          claimed = false
          snapshot.registrations.each do |registration|
            claimed = registration.provider.claim(observation, claims) || claimed if registration.provider.respond_to?(:claim)
          rescue => error
            claims.incomplete("provider_incomplete:#{registration.name}:#{error.class}")
          end
          unless claimed || discovery_observation?(observation)
            claims.incomplete("provider_incomplete:unclaimed:#{observation.kind}")
          end
        end
        pending.each do |observation|
          resolved = claims.observation_for(observation)
          if resolved.unresolved? && claims.observation_claims.fetch(resolved.key, []).empty?
            @checkpoint_invalid = true
          end
        end
        claims
      end

      def build_report(claims)
        @claimed_input_ids_by_test = claims.dependencies
          .reject { |dependency| dependency.test_id == "*" }
          .group_by(&:test_id)
          .to_h do |test_id, dependencies|
            ids = dependencies.map do |dependency|
              InputId.new(provider: dependency.provider, key: dependency.artifact_key)
            end.uniq.sort_by(&:to_s).freeze
            [test_id.to_s.freeze, ids]
          end
          .sort_by(&:first)
          .to_h
          .freeze
        artifacts = deduplicate_artifacts(claims.artifacts)
        artifacts = retain_suite_artifacts(artifacts, claims)
        context_input = snapshot.current_inputs.find { |input| input.key == "$context" }
        inputs = artifacts.map(&:to_input)
        inputs << context_input if context_input
        duplicates = inputs.group_by(&:id).select { |_id, matches| matches.length > 1 }.keys
        unless duplicates.empty?
          claims.incomplete("duplicate_provider_input:#{duplicates.map(&:to_s).sort.join(",")}")
        end
        @current_inputs = inputs.uniq(&:id).sort_by { |input| input.id.to_s }.freeze

        DiscoveryReport.new(
          context_signature: snapshot.signature,
          mode: :run,
          tests: {
            discovered: Array(@tests[:discovered]),
            selected: @selected,
            executed: @executed
          },
          observations: claims.observations,
          artifacts: artifacts,
          dependencies: claims.dependencies.uniq,
          observation_claims: claims.observation_claims,
          bundles: snapshot.registrations.map { |item| "#{item.name}@#{item.version}" },
          diagnostics: claims.diagnostics,
          complete: true,
          resolver: snapshot.context.resolver
        )
      end

      def transition!(from, to)
        raise PhaseError, "expected #{from} phase, got #{@phase}" unless @phase == from
        @phase = to
      end

      def discovery_observation?(observation)
        observation.provider == :core && %i[file_open file_read path_set].include?(observation.kind)
      end

      def deduplicate_artifacts(artifacts)
        artifacts.group_by { |artifact| [artifact.key, artifact.provider] }.sort_by(&:first).map do |_key, values|
          base = values.min_by { |item| CanonicalJSON.generate(item.inventory_item) }
          scope = (values.any? { |item| item.scope == :suite }) ? :suite : :test
          base.with(
            scope: scope,
            test_ids: (scope == :suite) ? [].freeze : values.flat_map(&:test_ids).compact.uniq.sort.freeze,
            reason: base.reason
          )
        end
      end

      def retain_suite_artifacts(artifacts, claims)
        artifacts.map do |artifact|
          next artifact unless @suite_input_ids.include?(artifact.to_input.id) && !artifact.suite?

          retained = artifact.with(scope: :suite, test_ids: [].freeze)
          claims.dependencies << Dependency.new(
            test_id: "*",
            artifact_key: retained.key,
            provider: retained.provider,
            complete: retained.known?
          )
          retained
        end
      end
    end
  end
end

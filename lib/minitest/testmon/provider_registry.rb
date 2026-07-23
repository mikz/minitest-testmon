# frozen_string_literal: true

require "digest"

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
          requested_events: %w[line call],
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
      end

      def claim(artifact, observation, provider: artifact.provider)
        artifact = artifact.with(scope: :suite, reason: :promoted_to_suite) if observation.reason == :late_activation
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

      def observations
        @observations.map { |observation| @observation_overrides.fetch(observation.key, observation) }
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
        :ruby_inventory_paths, :ruby_inventory_roots, :ruby_unhookable_paths

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
        @snapshot_digest = digest_snapshot(registrations, context)
        ruby_artifacts = context.artifacts.select do |artifact|
          artifact.provider == ruby_provider_id && artifact.facet == "ruby_iseq"
        end
        @ruby_inventory_paths = ruby_artifacts.map do |artifact|
          File.expand_path(artifact.relative_path, context.resolver.root(artifact.root))
        end.uniq.sort.freeze
        @ruby_inventory_roots = ruby_artifacts.map(&:root).uniq.sort.freeze
        @ruby_unhookable_paths = context.ruby_unhookable_paths(ruby_provider_id)
      end

      def observe(tests: {}, selected: [], mode: :discover)
        ProviderSession.new(self, tests: tests, selected: selected, mode: mode).start
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
        fresh_context = SnapshotContext.new(configuration)
        fresh_registrations = registrations.map do |registration|
          provider = if registration.provider.is_a?(ConfiguredProvider)
            ConfiguredProvider.new(registration.provider.definition)
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
        digest_snapshot(fresh_registrations, fresh_context) == snapshot_digest
      rescue
        false
      end

      private

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
      attr_reader :snapshot

      def initialize(snapshot, tests:, selected:, mode:)
        @snapshot = snapshot
        @tests = tests
        @selected = selected
        @mode = mode
        @observations = []
        @handles = []
        @executed = []
        @runtime_diagnostics = []
        @startup_complete = true
        @spool = nil
        @phase = :created
        @selection_mode = nil
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
        @spool ? @spool.record_observation(observation) : @observations << observation
        observation
      end

      def executed(test_id)
        return test_id.to_s if @worker_sealed
        @spool ? @spool.record_executed(test_id.to_s) : @executed << test_id.to_s
      end

      def selected!(test_ids)
        raise PhaseError, "selection is closed" unless @phase == :observing
        @selected = Array(test_ids).map(&:to_s).uniq.sort
      end

      def selection_mode!(mode)
        raise PhaseError, "selection is closed" unless @phase == :observing
        @selection_mode = mode.to_sym
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

        claims = ClaimContext.new(snapshot.context, @observations)
        @runtime_diagnostics.each { |reason| claims.incomplete(reason) }
        validate_execution_ledger(claims)
        @observations.each do |observation|
          if observation.reason == :opaque_c_call && observation.details["candidate_path"]
            candidate = observation.with(path: observation.details["candidate_path"], reason: nil)
            ignored = snapshot.registrations.any? do |registration|
              registration.provider.respond_to?(:ignore_observation) &&
                registration.provider.ignore_observation(candidate, claims, any_kind: true)
            end
            next if ignored
          end
          next if observation.unresolved? && observation.reason != :late_activation
          ignored = snapshot.registrations.any? do |registration|
            registration.provider.respond_to?(:ignore_observation) &&
              registration.provider.ignore_observation(observation, claims)
          end
          next if ignored
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
        snapshot.registrations.each do |registration|
          registration.provider.finalize(claims) if registration.provider.respond_to?(:finalize)
        rescue => error
          claims.incomplete("provider_incomplete:#{registration.name}:#{error.class}")
        end
        claims.incomplete(:source_drift) unless snapshot.source_stable?
        @phase = :finalized

        DiscoveryReport.new(
          context_signature: snapshot.signature,
          mode: @mode,
          tests: {
            discovered: Array(@tests[:discovered]),
            selected: @selected,
            executed: @executed
          },
          observations: claims.observations,
          artifacts: deduplicate_artifacts(claims.artifacts),
          dependencies: claims.dependencies.uniq,
          observation_claims: claims.observation_claims,
          bundles: snapshot.registrations.map { |item| "#{item.name}@#{item.version}" },
          diagnostics: claims.diagnostics,
          complete: true,
          resolver: snapshot.context.resolver,
          selection_mode: @selection_mode
        )
      end

      private

      def transition!(from, to)
        raise PhaseError, "expected #{from} phase, got #{@phase}" unless @phase == from
        @phase = to
      end

      def validate_execution_ledger(claims)
        return unless @selection_mode

        discovered = Array(@tests[:discovered]).map(&:to_s).uniq.sort
        selected = @selected.map(&:to_s).uniq.sort
        executed_counts = @executed.map(&:to_s).tally
        claims.incomplete(:duplicate_test_execution) unless executed_counts.values.all? { |count| count == 1 }
        claims.incomplete(:execution_ledger_mismatch) unless executed_counts.keys.sort == selected
        if @selection_mode == :full || @mode.to_sym == :discover
          claims.incomplete(:discovery_ledger_mismatch) unless selected == discovered
        end
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
            reason: (values.any? { |item| item.reason == :promoted_to_suite }) ? :promoted_to_suite : base.reason
          )
        end
      end
    end
  end
end

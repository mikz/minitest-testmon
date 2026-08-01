# frozen_string_literal: true

require "digest"

module Minitest
  module Testmon
    class ConfiguredProvider
      attr_reader :definition, :snapshot_manifest

      def initialize(definition)
        @definition = definition
        @artifacts_by_facet = {}
        @facet_snapshots = {}
        @snapshot_manifest = nil
      end

      def signature
        definition.signature
      end

      def observe(session, resolver: @resolver)
        raise ObserverUnavailable, "provider inventory was not prepared" unless resolver
        handles = []
        definition.observers.each do |observer|
          handle = case observer.type
          when :tracepoint
            TracePointObserverHandle.new(definition, observer, session, resolver)
          when :notification
            NotificationObserverHandle.new(definition, observer, session, resolver)
          when :test_start
            next
          else
            raise ObserverUnavailable, "unknown observer type: #{observer.type}"
          end
          handles << handle.start
        end
        CompositeObserverHandle.new(handles)
      rescue
        handles.reverse_each { |handle|
          begin
            handle.close
          rescue
            nil
          end
        }
        raise
      end

      def test_started(test, session)
        wrapper = TestStartObservation.new(test)
        definition.observers.each do |observer|
          next unless observer.type == :test_start

          details = observer.details ? observer.details.call(wrapper) : {}
          next if details.nil?
          details = CanonicalObservationValue.call(details)
          raise TypeError, "test-start details must return a Hash or nil" unless details.is_a?(Hash)

          session.record(Observation.build(
            kind: observer.event_kind,
            provider: definition.id.to_sym,
            operation: :test_start,
            test_id: wrapper.test_id,
            details: details
          ))
        end
      end

      def snapshot(context)
        @resolver = context.resolver
        inventory_manifests = {}
        inventories = definition.inventories.to_h do |inventory|
          files = inventory_files(inventory)
          inventory_manifests[inventory.name] = inventory_manifest(inventory, files, context)
          [inventory.name, files]
        rescue PathError, SystemCallError
          context.incomplete(:outside_root)
          inventory_manifests[inventory.name] = {error: "outside_root"}
          [inventory.name, [].freeze]
        end.freeze

        definition.facets.each do |facet|
          artifacts = build_facet(facet, inventories.fetch(facet.inventory), context).sort_by(&:key).freeze
          @artifacts_by_facet[facet.name] = artifacts
          @facet_snapshots[facet.name] = FacetSnapshot.new(
            name: facet.name,
            digest: facet.digest,
            granularity: facet.granularity,
            scope: facet.scope,
            artifact_keys: artifacts.map(&:key).sort.freeze
          ).freeze
        end
        @artifacts_by_facet.freeze
        @facet_snapshots.freeze
        @snapshot_manifest = {
          definition: definition.signature,
          inventories: inventory_manifests.sort_by { |name, _value| name.to_s }.to_h,
          artifacts: @artifacts_by_facet.values.flatten.map(&:inventory_item).sort_by { |item| item.fetch(:key) }
        }.freeze
      end

      def claim(observation, claims)
        return true if ignore_observation(observation, claims)

        matched = definition.claims.select { |claim| claim.event_kind == observation.kind }
        claimed = false
        matched.each { |claim| claimed = apply_claim(claim, observation, claims) || claimed }
        claimed
      end

      def ignore_observation(observation, claims, any_kind: false)
        ignored = definition.ignores.find do |ignore|
          (any_kind || ignore.event_kind == observation.kind) && ignore.predicate.call(observation)
        end
        return false unless ignored

        claims.unresolved(observation, :user_ignored)
        true
      rescue
        claims.unresolved(observation, :extractor_error)
        claims.incomplete(:extractor_error)
        true
      end

      private

      def inventory_files(inventory)
        root = @resolver.root(inventory.root)
        base = File.expand_path(inventory.base, root)
        @resolver.resolve(base)
        excluded = inventory.exclude_patterns.flat_map do |pattern|
          Dir.glob(File.join(base, pattern), File::FNM_DOTMATCH)
        end.to_h { |path| [File.expand_path(path), true] }

        inventory.include_patterns.flat_map do |pattern|
          Dir.glob(File.join(base, pattern), File::FNM_DOTMATCH)
        end.uniq.filter_map do |path|
          expanded = File.expand_path(path)
          next if excluded.key?(expanded)
          next unless File.file?(expanded)
          locator = @resolver.resolve(expanded, allow_missing: false)
          next unless locator.root == inventory.root
          locator
        rescue PathError
          nil
        end.sort_by { |locator| [locator.root.to_s, locator.relative_path] }.freeze
      end

      def inventory_manifest(inventory, locators, context)
        root_path = @resolver.root(inventory.root)
        base = File.expand_path(inventory.base, root_path)
        lexical_paths = inventory.include_patterns.flat_map do |pattern|
          Dir.glob(File.join(base, pattern), File::FNM_DOTMATCH)
        end.uniq
        excluded = inventory.exclude_patterns.flat_map do |pattern|
          Dir.glob(File.join(base, pattern), File::FNM_DOTMATCH)
        end.map { |path| File.expand_path(path) }.to_h { |path| [path, true] }
        entries = lexical_paths.reject { |path| excluded.key?(File.expand_path(path)) }
          .reject { |path| File.directory?(path) }
          .map do |path|
          stat = File.lstat(path)
          regular = File.file?(path)
          context.incomplete(:non_regular) unless regular
          {
            lexical_path: Pathname(File.expand_path(path)).relative_path_from(Pathname(root_path)).to_s,
            file_type: stat.ftype,
            regular: regular,
            symlink: stat.symlink? ? File.readlink(path) : nil,
            realpath: File.realpath(path),
            locator: @resolver.resolve(path, allow_missing: false).key
          }
        rescue SystemCallError, PathError => error
          context.incomplete(:non_regular)
          {lexical_path: File.expand_path(path), error: error.class.name}
        end
        {
          root: inventory.root.to_s,
          base: inventory.base,
          base_realpath: @resolver.resolve(base).absolute_path,
          files: entries.sort_by { |item| CanonicalJSON.generate(item) },
          locators: locators.map(&:key).sort
        }
      end

      def build_facet(facet, locators, context)
        artifacts = case [facet.digest, facet.granularity]
        when %i[content file]
          locators.map do |locator|
            artifact(facet, locator, ContentFingerprint.call(locator.absolute_path), identity: :content)
          end
        when %i[existence file]
          locators.map do |locator|
            artifact(facet, locator, existence_fingerprint(locator.absolute_path), identity: :existence)
          end
        when %i[paths set]
          [set_artifact(facet, locators, paths_fingerprint(locators), members: locators.map(&:key))]
        when %i[contents set]
          fingerprint, reason = contents_fingerprint(locators)
          [set_artifact(facet, locators, fingerprint, members: locators.map(&:key), reason: reason)]
        when %i[ruby_source file]
          locators.flat_map { |locator| ruby_artifacts(facet, locator, context) }
        else
          raise ConfigurationError, "unsupported facet: #{facet.digest}/#{facet.granularity}"
        end
        artifacts.each do |item|
          context.incomplete(item.fingerprint.reason) if item.fingerprint&.unknown?
          context.add_artifact(item)
        end
        artifacts
      end

      def ruby_artifacts(facet, locator, context)
        result = RubyTraceCapabilityProbe.new(@resolver).call(locator.absolute_path)
        context.add_ruby_trace_capability(definition.id, locator, result.unhookable_targets)
        scope = result.target_traceable? ? facet.scope : :suite
        fingerprint = ContentFingerprint.call(locator.absolute_path)
        [artifact(
          facet,
          locator,
          fingerprint,
          identity: :whole_file,
          members: ["identity:whole_file"],
          reason: fingerprint.reason,
          scope: scope
        )]
      end

      def artifact(facet, locator, fingerprint, identity:, members: [], reason: nil, scope: facet.scope)
        Artifact.new(
          key: artifact_key(facet, locator.root, locator.relative_path, identity),
          provider: definition.id.to_sym,
          root: locator.root,
          relative_path: locator.relative_path,
          facet: report_facet(facet),
          fingerprint: fingerprint,
          members: members.sort.freeze,
          scope: scope,
          test_ids: [].freeze,
          reason: reason || fingerprint.reason
        )
      end

      def set_artifact(facet, locators, fingerprint, members:, reason: nil)
        inventory = definition.inventories.find { |item| item.name == facet.inventory }
        root_path = @resolver.root(inventory.root)
        locator = @resolver.resolve(File.expand_path(inventory.base, root_path))
        artifact(facet, locator, fingerprint, identity: :set, members: members, reason: reason)
      end

      def report_facet(facet)
        case facet.digest
        when :content, :contents then "content"
        when :existence then "existence"
        when :paths then "membership"
        when :ruby_source then "ruby_source"
        else facet.digest.to_s
        end
      end

      def artifact_key(facet, root, relative_path, identity)
        if facet.digest == :ruby_source
          return Digest::SHA256.hexdigest([
            "physical",
            root,
            relative_path,
            report_facet(facet),
            identity
          ].join("\0"))
        end

        if facet.granularity == :set
          return "#{definition.id}/#{facet.inventory}/#{facet.name}/#{root}:#{relative_path}#set"
        end

        "physical/#{report_facet(facet)}/#{root}:#{relative_path}"
      end

      def existence_fingerprint(path)
        if File.exist?(path)
          Fingerprint.known(Digest::SHA256.hexdigest("EXISTS\0"))
        else
          Fingerprint.missing
        end
      end

      def paths_fingerprint(locators)
        Fingerprint.known(Digest::SHA256.hexdigest(CanonicalJSON.generate(locators.map(&:key))))
      end

      def contents_fingerprint(locators)
        payload = locators.map do |locator|
          fingerprint = ContentFingerprint.call(locator.absolute_path)
          return [Fingerprint.unknown(fingerprint.reason), fingerprint.reason] if fingerprint.unknown?
          [locator.key, fingerprint.state.to_s, fingerprint.digest]
        end
        [Fingerprint.known(Digest::SHA256.hexdigest(CanonicalJSON.generate(payload))), nil]
      end

      def apply_claim(claim, observation, claims)
        selected = if claim.using
          keys_from_using(claim, observation, claims)
        else
          keys_from_path(claim, observation, claims)
        end
        return true if selected == :invalid
        return false if Array(selected).empty?

        selected.each do |item|
          claims.claim(item, observation, provider: definition.id.to_sym)
        end
        true
      rescue PathError
        claims.unresolved(observation, :claim_path_missing)
        claims.incomplete(:claim_path_missing)
        true
      rescue
        claims.unresolved(observation, :extractor_error)
        claims.incomplete(:extractor_error)
        true
      end

      def keys_from_using(claim, observation, claims)
        snapshot = @facet_snapshots.fetch(claim.facet)
        result = claim.using.call(observation, snapshot)
        selected_keys = result.nil? ? [] : Array(result).uniq
        unless selected_keys.all? { |key| key.is_a?(String) && snapshot.artifact_keys.include?(key) }
          claims.unresolved(observation, :claim_path_missing)
          claims.incomplete(:claim_path_missing)
          return :invalid
        end
        return [] if selected_keys.empty?

        artifacts = @artifacts_by_facet.fetch(claim.facet)
        selected_keys.filter_map { |key| artifacts.find { |item| item.key == key } }
      end

      def keys_from_path(claim, observation, claims)
        raw_path = if claim.path.is_a?(Symbol)
          observation.public_send(claim.path)
        elsif claim.path
          claim.path.call(observation)
        else
          observation.path
        end
        unless raw_path.nil? || raw_path.is_a?(String) || raw_path.is_a?(Pathname)
          claims.unresolved(observation, :noncanonical_observation)
          claims.incomplete(:noncanonical_observation)
          return []
        end
        locator = raw_path && @resolver.resolve(raw_path.to_s)

        facet = definition.facets.find { |item| item.name == claim.facet }
        candidates = @artifacts_by_facet.fetch(claim.facet)
        if facet.digest == :content && facet.granularity == :file && locator &&
            observation.exists_at_observation && !File.exist?(locator.absolute_path)
          claims.unresolved(observation, :source_race)
          claims.incomplete(:source_race)
          return :invalid
        end
        selected = if facet.granularity == :set
          candidates
        elsif locator
          matching_file_artifacts(candidates, locator)
        else
          []
        end
        selected.tap do |items|
          next unless items.empty? && locator && inventory_matches_locator?(claim.inventory, locator)
          claims.unresolved(observation, :claim_path_missing)
          claims.incomplete(:claim_path_missing)
        end
      end

      def inventory_matches_locator?(inventory_name, locator)
        inventory = definition.inventories.find { |item| item.name == inventory_name }
        return false unless inventory && locator.root == inventory.root
        root = @resolver.root(inventory.root)
        base = File.expand_path(inventory.base, root)
        relative = Pathname(locator.absolute_path).relative_path_from(Pathname(base)).to_s
        return false if relative == ".." || relative.start_with?("..#{File::SEPARATOR}")
        flags = File::FNM_PATHNAME | File::FNM_EXTGLOB
        included = inventory.include_patterns.any? { |pattern| File.fnmatch?(pattern, relative, flags) }
        excluded = inventory.exclude_patterns.any? { |pattern| File.fnmatch?(pattern, relative, flags) }
        included && !excluded
      rescue ArgumentError
        false
      end

      def matching_file_artifacts(candidates, locator)
        candidates.select do |item|
          item.root == locator.root && item.relative_path == locator.relative_path
        end
      end
    end
  end
end

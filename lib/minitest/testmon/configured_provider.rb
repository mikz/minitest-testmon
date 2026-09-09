# frozen_string_literal: true

require "digest"

module Minitest
  module Testmon
    class ConfiguredProvider
      attr_reader :definition, :snapshot_manifest, :capability_cache

      def initialize(definition, capability_cache: {})
        @capability_cache = capability_cache
        @definition = definition
        @facets_by_name = definition.facets.to_h { |facet| [facet.name, facet] }.freeze
        @inventories_by_name = definition.inventories.to_h { |inventory| [inventory.name, inventory] }.freeze
        @claims_by_event = definition.claims.group_by(&:event_kind).freeze
        @artifacts_by_locator = {}
        @artifacts_by_key = {}
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
          paths = inventory_paths(inventory)
          resolved = {}
          files = inventory_files(inventory, paths, resolved)
          inventory_manifests[inventory.name] = inventory_manifest(inventory, files, context, paths, resolved)
          [inventory.name, files]
        rescue PathError, SystemCallError
          context.incomplete(:outside_root)
          inventory_manifests[inventory.name] = {error: "outside_root"}
          [inventory.name, [].freeze]
        end.freeze

        definition.facets.each do |facet|
          artifacts = build_facet(facet, inventories.fetch(facet.inventory), context).sort_by(&:key).freeze
          @artifacts_by_facet[facet.name] = artifacts
          @artifacts_by_locator[facet.name] = artifacts.group_by { |artifact| [artifact.root, artifact.relative_path] }.transform_values(&:freeze).freeze
          @artifacts_by_key[facet.name] = artifacts.to_h { |artifact| [artifact.key, artifact] }.freeze
          @facet_snapshots[facet.name] = FacetSnapshot.new(
            name: facet.name,
            digest: facet.digest,
            granularity: facet.granularity,
            scope: facet.scope,
            artifact_keys: artifacts.map(&:key).sort.freeze
          ).freeze
        end
        @artifacts_by_locator.freeze
        @artifacts_by_key.freeze
        @artifacts_by_facet.freeze
        @facet_snapshots.freeze
        @snapshot_manifest = {
          definition: definition.signature,
          inventories: inventory_manifests.sort_by { |name, _value| name.to_s }.to_h,
          artifacts: @artifacts_by_facet.values.flatten.map(&:inventory_item).sort_by { |item| item.fetch(:key) }
        }.freeze
      end

      # Source validation needs exact bytes and path ownership, not another
      # round of artifact construction and MRI capability probes.
      def validation_manifest(context)
        @resolver = context.resolver
        definition.inventories.map do |inventory|
          paths = inventory_paths(inventory)
          resolved = {}
          files = inventory_files(inventory, paths, resolved)
          [inventory.name, inventory_manifest(inventory, files, context, paths, resolved),
            files.map { |locator| [locator.key, ContentFingerprint.call(locator.absolute_path).to_h] }]
        end
      end

      def claim(observation, claims)
        return true if ignore_observation(observation, claims)

        matched = @claims_by_event.fetch(observation.kind, [])
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

      def inventory_paths(inventory)
        base = File.expand_path(inventory.base, @resolver.root(inventory.root))
        @resolver.resolve(base)
        pruned_directories = prunable_inventory_directories(base, inventory.exclude_patterns)
        paths = inventory.include_patterns.flat_map do |pattern|
          inventory_include_paths(base, pattern, pruned_directories)
        end.uniq
        expanded_paths = paths.map { |path| File.expand_path(path) }
        excluded = inventory.exclude_patterns.flat_map do |pattern|
          # Do not enumerate unrelated excluded trees (notably node_modules
          # and vendor) for inventories whose matches cannot be below them.
          # Relevant patterns still use glob, preserving symlink semantics.
          prefix = exclusion_directory_prefix(base, pattern)
          if prefix && pruned_directories.include?(pattern.delete_suffix("/**/*")) &&
              expanded_paths.none? { |path| path.start_with?(prefix) }
            directory = prefix.delete_suffix(File::SEPARATOR)
            # With DOTMATCH, directory/**/* contains directory/., which
            # expands to the directory itself in the exclusion index.
            next File.directory?(directory) ? [directory] : []
          end
          next [] if prefix && expanded_paths.none? { |path|
            path.start_with?(prefix) || path == prefix.delete_suffix(File::SEPARATOR)
          }

          Dir.glob(File.join(base, pattern), File::FNM_DOTMATCH)
        end.to_h { |path| [File.expand_path(path), true] }
        paths.reject { |path| excluded.key?(File.expand_path(path)) }
      end

      def prunable_inventory_directories(base, patterns)
        return [] if base.match?(/[\\*?\[\]{}]/)

        patterns.filter_map do |pattern|
          next unless pattern.end_with?("/**/*")
          name = pattern.delete_suffix("/**/*")
          next if name.empty? || name.include?("..") || name.match?(/[\\\/*?\[\]{}]/)
          name
        end
      end

      def inventory_include_paths(base, pattern, pruned_directories)
        unless %w[**/*.rb **/*].include?(pattern) && !pruned_directories.empty? && File.directory?(base)
          return Dir.glob(File.join(base, pattern), File::FNM_DOTMATCH)
        end

        suffix = pattern.delete_prefix("**/")
        paths = Dir.glob(File.join(base, suffix), File::FNM_DOTMATCH)
        Dir.children(base).each do |name|
          next if pruned_directories.include?(name)
          directory = File.join(base, name)
          # An explicit glob prefix follows directory symlinks; recursive **
          # does not. Keep those entries, but never turn them into prefixes.
          next if File.symlink?(directory) || !File.directory?(directory)
          Dir.glob(pattern, File::FNM_DOTMATCH, base: directory).each do |relative|
            next if relative == "." || relative == ".."
            paths << File.join(directory, relative)
          end
        end
        # Recursive glob orders each directory's entries before descending;
        # a flat string sort would put .hidden.rb before .hidden/nested.rb.
        paths.sort_by { |path| path.split(File::SEPARATOR) }
      end

      def exclusion_directory_prefix(base, pattern)
        return if pattern.include?("\\") || pattern.include?("..")

        literal = pattern.split(/[*?\[\]{}]/, 2).first.to_s
        boundary = literal.rindex(File::SEPARATOR)
        return unless boundary

        directory = File.expand_path(File.join(base, literal[0..boundary]))
        directory.end_with?(File::SEPARATOR) ? directory : "#{directory}#{File::SEPARATOR}"
      end

      def inventory_files(inventory, paths, resolved)
        paths.filter_map do |path|
          expanded = File.expand_path(path)
          next unless File.file?(expanded)
          locator = resolved[path] = @resolver.resolve(expanded, allow_missing: false)
          next unless locator.root == inventory.root
          next if ruby_source_inventory?(inventory.name) && !inventory_matches_locator?(inventory.name, locator)
          locator
        rescue PathError
          nil
        end.sort_by { |locator| [locator.root.to_s, locator.relative_path] }.freeze
      end

      def inventory_manifest(inventory, locators, context, paths, resolved)
        root_path = @resolver.root(inventory.root)
        base = File.expand_path(inventory.base, root_path)
        eligible_locator_keys = locators.map(&:key).to_h { |key| [key, true] }
        entries = paths
          .reject { |path| File.directory?(path) }
          .reject do |path|
            next false unless ruby_source_inventory?(inventory.name)

            locator = resolved[path] || @resolver.resolve(path, allow_missing: false)
            !eligible_locator_keys.key?(locator.key)
          rescue PathError
            true
          end
          .map do |path|
          locator = resolved[path] || @resolver.resolve(path, allow_missing: false)
          stat = File.lstat(path)
          regular = File.file?(path)
          context.incomplete(:non_regular) unless regular
          {
            lexical_path: relative_inventory_path(path, root_path),
            file_type: stat.ftype,
            regular: regular,
            symlink: stat.symlink? ? File.readlink(path) : nil,
            realpath: locator.absolute_path,
            locator: locator.key
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

      def relative_inventory_path(path, root)
        expanded = File.expand_path(path)
        prefix = root.end_with?(File::SEPARATOR) ? root : "#{root}#{File::SEPARATOR}"
        return expanded.delete_prefix(prefix) if expanded.start_with?(prefix)
        return "." if expanded == root

        Pathname(expanded).relative_path_from(Pathname(root)).to_s
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
        before = ContentFingerprint.call(locator.absolute_path)
        key = [locator.key, before.digest, RubyVM::InstructionSequence.compile_option]
        result = capability_cache[key] if before.known?
        unless result
          result = RubyTraceCapabilityProbe.new(@resolver).call(locator.absolute_path)
          after = ContentFingerprint.call(locator.absolute_path)
          context.incomplete(:source_race) unless before == after
          capability_cache[key] = result if before.known? && before == after
        end
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
          reason: reason || fingerprint.reason,
          identity: identity
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
        artifacts = @artifacts_by_key.fetch(claim.facet)
        unless selected_keys.all? { |key| key.is_a?(String) && artifacts.key?(key) }
          claims.unresolved(observation, :claim_path_missing)
          claims.incomplete(:claim_path_missing)
          return :invalid
        end
        return [] if selected_keys.empty?

        selected_keys.map { |key| artifacts.fetch(key) }
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

        facet = @facets_by_name.fetch(claim.facet)
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
          matching_file_artifacts(claim.facet, locator)
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
        inventory = @inventories_by_name[inventory_name]
        return false unless inventory && locator.root == inventory.root
        root = @resolver.root(inventory.root)
        base = @resolver.resolve(File.expand_path(inventory.base, root)).absolute_path
        relative = Pathname(locator.absolute_path).relative_path_from(Pathname(base)).to_s
        return false if relative == ".." || relative.start_with?("..#{File::SEPARATOR}")
        flags = File::FNM_PATHNAME | File::FNM_EXTGLOB | File::FNM_DOTMATCH
        included = inventory.include_patterns.any? { |pattern| File.fnmatch?(pattern, relative, flags) }
        excluded = inventory.exclude_patterns.any? { |pattern| File.fnmatch?(pattern, relative, flags) }
        included && !excluded
      rescue PathError, ArgumentError
        false
      end

      def ruby_source_inventory?(inventory_name)
        definition.facets.any? do |facet|
          facet.inventory == inventory_name && facet.digest == :ruby_source
        end
      end

      def matching_file_artifacts(facet, locator)
        @artifacts_by_locator.fetch(facet).fetch([locator.root, locator.relative_path]) { [] }
      end
    end
  end
end

# frozen_string_literal: true

require "digest"

module Minitest
  module Testmon
    class DiscoveryReport
      SCHEMA_VERSION = 3
      IGNORED_REASONS = %i[excluded nonexistent user_ignored conservative_file_construction].freeze
      SUGGESTION_CODES = %w[
        uncovered_file opaque_c_call uncovered_notification outside_root path_set_churn
      ].freeze

      attr_reader :generation, :context_signature, :observations, :artifacts, :dependencies,
        :diagnostics, :observation_claims, :mode, :bundles, :publication, :resolver

      def initialize(
        context_signature:, generation: nil,
        mode: :run,
        bundles: [],
        tests: {},
        observations: [],
        artifacts: [],
        dependencies: [],
        observation_claims: {},
        diagnostics: [],
        complete: true,
        publication: {published: false, reason: "not_published"},
        resolver: nil
      )
        @generation = generation
        @context_signature = context_signature
        @mode = mode.to_s
        @bundles = Array(bundles).map(&:to_s).sort.freeze
        @tests = {
          discovered: Array(tests[:discovered]).map(&:to_s).uniq.sort,
          selected: Array(tests[:selected]).map(&:to_s).uniq.sort,
          executed: Array(tests[:executed]).map(&:to_s).uniq.sort
        }.freeze
        @observations = observations.uniq.sort_by(&:key).freeze
        @artifacts = artifacts.sort_by(&:key).freeze
        @dependencies = dependencies.sort_by { |item| [item.test_id.to_s, item.artifact_key] }.freeze
        @observation_claims = observation_claims.transform_values { |keys| keys.uniq.sort }.freeze
        @diagnostics = diagnostics.map(&:to_s).uniq.sort.freeze
        @resolver = resolver
        @complete = complete && @diagnostics.empty? && @observations.none? do |observation|
          observation.unresolved? && @observation_claims.fetch(observation.key, []).empty?
        end && @artifacts.none? do |artifact|
          artifact.fingerprint&.unknown? || Observation::UNRESOLVED_REASONS.include?(artifact.reason)
        end
        @publication = {
          published: !!publication[:published],
          reason: publication[:reason]&.to_s
        }.freeze
      end

      def complete?
        @complete
      end

      def ready?
        complete? && publication[:published]
      end

      def published(generation, reason: nil)
        copy(generation: generation, publication: {published: true, reason: reason})
      end

      def discovered_tests
        @tests.fetch(:discovered)
      end

      def selected_tests
        @tests.fetch(:selected)
      end

      def executed_tests
        @tests.fetch(:executed)
      end

      def with_generation(generation)
        copy(generation: generation)
      end

      def unpublished(reason)
        copy(publication: {published: false, reason: reason})
      end

      def to_h
        paths = {}
        observation_categories = categorize_observations(paths)
        inventory_categories = categorize_inventory
        {
          schema_version: SCHEMA_VERSION,
          mode: mode,
          complete: complete?,
          ready: ready?,
          diagnostics: diagnostics,
          generation: generation,
          context_signature: context_signature,
          bundles: bundles,
          tests: @tests,
          observations: observation_categories.transform_values { |items| category(items) },
          inventory: inventory_categories.transform_values { |items| category(items) },
          suggestions: suggestions(paths),
          publication: publication,
          checkpoints: {count: 0, accepted_ids: [], stop_reason: nil}
        }
      end

      def to_json(pretty: false)
        CanonicalJSON.generate(to_h, pretty: pretty)
      end

      private

      def copy(**overrides)
        self.class.new(
          generation: overrides.fetch(:generation, generation),
          context_signature: context_signature,
          mode: mode,
          bundles: bundles,
          tests: @tests,
          observations: observations,
          artifacts: artifacts,
          dependencies: overrides.fetch(:dependencies, dependencies),
          observation_claims: observation_claims,
          diagnostics: diagnostics,
          complete: complete?,
          publication: overrides.fetch(:publication, publication),
          resolver: resolver
        )
      end

      def categorize_observations(paths)
        result = {claimed: [], ignored: [], uncovered: [], unresolved: []}
        observations.each do |observation|
          claimed_keys = observation_claims.fetch(observation.key, [])
          if claimed_keys.any?
            claimed_keys.each { |key| result[:claimed] << observation_item(observation, paths, key: key) }
          elsif IGNORED_REASONS.include?(observation.reason)
            result[:ignored] << observation_item(observation, paths)
          elsif observation.unresolved?
            result[:unresolved] << observation_item(observation, paths)
          else
            result[:uncovered] << observation_item(observation, paths).merge(reason: uncovered_reason(observation))
          end
        end
        result
      end

      def categorize_inventory
        result = {claimed: [], suite_scoped: [], verified_empty: [], unresolved: []}
        suite_keys = artifacts.select { |artifact| artifact.scope == :suite }
          .to_h { |artifact| [artifact.key, true] }
        claimed_keys = dependencies.select { |dependency| dependency.complete && dependency.test_id != "*" }
          .to_h { |dependency| [dependency.artifact_key, true] }
        artifacts.each do |artifact|
          item = artifact.inventory_item
          if artifact.fingerprint&.unknown? || Observation::UNRESOLVED_REASONS.include?(artifact.reason)
            result[:unresolved] << item
          elsif suite_keys[artifact.key]
            result[:suite_scoped] << item
          elsif claimed_keys[artifact.key]
            result[:claimed] << item
          else
            result[:verified_empty] << item
          end
        end
        result
      end

      def category(items)
        sorted = items.group_by { |item| [item.fetch(:key), item[:provider]] }.map do |_key, duplicates|
          duplicates.min_by { |item| [operation_priority(item[:operation]), CanonicalJSON.generate(item)] }
        end.sort_by do |item|
          [item.fetch(:key), item[:provider].to_s, CanonicalJSON.generate(item)]
        end
        {count: sorted.length, items: sorted}
      end

      def suggestions(paths)
        values = []
        observations.each do |observation|
          claimed = observation_claims.fetch(observation.key, []).any?
          ignored = IGNORED_REASONS.include?(observation.reason)
          if observation.reason == :opaque_c_call
            values << suggestion("opaque_c_call", observation, paths, ruby: "observe a public Ruby wrapper that exposes the input path")
            values << suggestion("outside_root", observation, paths, ruby: "config.root :shared, \"../shared\"")
            values << suggestion("path_set_churn", observation, paths, ruby: "facet :membership, inventory: :files, digest: :paths, granularity: :set")
          elsif observation.reason == :outside_root
            values << suggestion("outside_root", observation, paths, ruby: "config.root :shared, \"../shared\"")
          elsif !claimed && !ignored && !observation.unresolved?
            values << if observation.kind == :path_set
              suggestion("path_set_churn", observation, paths, ruby: "facet :membership, inventory: :files, digest: :paths, granularity: :set")
            elsif observation.operation.to_s.include?(".")
              suggestion("uncovered_notification", observation, paths, ruby: "claim :#{observation.kind}, to: [:files, :content], path: :path")
            else
              suggestion("uncovered_file", observation, paths, ruby: "claim :#{observation.kind}, to: [:files, :content], path: :path")
            end
          end
        end
        values.uniq.sort_by { |item| [item[:code], item[:path].to_s, item[:event].to_s, item[:ruby].to_s] }
      end

      def suggestion(code, observation, paths, ruby:)
        {
          code: code,
          path: (code == "outside_root") ? nil : logical_path(observation.path, paths),
          event: observation.operation&.to_s || observation.kind.to_s,
          ruby: ruby
        }
      end

      def uncovered_reason(observation)
        return observation.reason.to_s if observation.reason
        (%i[file_read file_open path_set].include?(observation.kind) || observation.path) ? "uncovered_file" : "uncovered_event"
      end

      def observation_item(observation, paths, key: nil)
        item = observation.report_item
        item[:path] = logical_path(item[:path], paths)
        if item[:callsite]
          item[:callsite] = item[:callsite].merge(path: logical_path(item[:callsite][:path], paths))
        end
        item[:key] = key || Digest::SHA256.hexdigest(CanonicalJSON.generate(item.except(:key)))
        item
      end

      def logical_path(path, paths)
        return path unless resolver && path
        return path if resolver.logical?(path)
        # This is a rendering-pass cache, not persisted dependency evidence.
        # Repeated claims share a path; a later rendering resolves it afresh.
        paths.fetch(path) do
          paths[path] = begin
            resolver.resolve(path).key
          rescue PathError, ArgumentError
            path
          end
        end
      end

      def operation_priority(operation)
        %w[load require File.open].include?(operation.to_s) ? 0 : 1
      end
    end
  end
end

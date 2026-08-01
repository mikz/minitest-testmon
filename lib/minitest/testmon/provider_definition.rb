# frozen_string_literal: true

module Minitest
  module Testmon
    InventoryDefinition = Data.define(:name, :root, :base, :include_patterns, :exclude_patterns) do
      def signature
        {
          name: name.to_s,
          root: root.to_s,
          base: base,
          include: include_patterns,
          exclude: exclude_patterns
        }
      end
    end

    FacetDefinition = Data.define(:name, :inventory, :digest, :granularity, :scope) do
      def signature
        {
          name: name.to_s,
          inventory: inventory.to_s,
          digest: digest.to_s,
          granularity: granularity.to_s,
          scope: scope.to_s
        }
      end
    end

    ClaimDefinition = Data.define(:event_kind, :inventory, :facet, :path, :using) do
      def to
        [inventory, facet].freeze
      end

      def signature
        {
          event_kind: event_kind.to_s,
          to: [inventory.to_s, facet.to_s],
          path: ProviderDefinition.callable_signature(path),
          using: ProviderDefinition.callable_signature(using)
        }
      end
    end

    ObserverDefinition = Data.define(
      :type,
      :event_kind,
      :target,
      :event,
      :notification_name,
      :path,
      :details
    ) do
      def signature
        {
          type: type.to_s,
          event_kind: event_kind.to_s,
          target: ProviderDefinition.declaration_value(target),
          event: event&.to_s,
          notification_name: notification_name,
          path: ProviderDefinition.callable_signature(path),
          details: ProviderDefinition.callable_signature(details)
        }
      end
    end

    IgnoreDefinition = Data.define(:event_kind, :reason, :predicate) do
      def signature
        {
          event_kind: event_kind.to_s,
          reason: reason,
          predicate: ProviderDefinition.callable_signature(predicate)
        }
      end
    end

    FacetSnapshot = Data.define(:name, :digest, :granularity, :scope, :artifact_keys)

    class ProviderDefinition
      MEMBERSHIP_DIGEST = :paths
      MEMBERSHIP_GRANULARITY = :set
      ALLOWED_FACETS = [
        %i[content file],
        %i[existence file],
        %i[paths set],
        %i[contents set],
        %i[ruby_source file]
      ].freeze

      attr_reader :id, :name, :version, :inventories, :facets, :claims, :observers, :ignores

      def initialize(name:, version:, inventories:, facets:, claims:, observers:, ignores:)
        @name = name.to_sym
        @version = Integer(version)
        @id = "#{@name}@#{@version}".freeze
        @inventories = inventories.freeze
        @facets = facets.freeze
        @claims = claims.freeze
        @observers = observers.freeze
        @ignores = ignores.freeze
        freeze
      end

      def signature
        {
          id: id,
          inventories: inventories.map(&:signature),
          facets: facets.map(&:signature),
          claims: claims.map(&:signature),
          observers: observers.map(&:signature),
          ignores: ignores.map(&:signature)
        }
      end

      class << self
        def callable_signature(callable)
          return nil unless callable

          location = callable.respond_to?(:source_location) ? callable.source_location : nil
          parameters = callable.respond_to?(:parameters) ? callable.parameters : []
          owner = if callable.respond_to?(:owner)
            callable.owner
          elsif callable.respond_to?(:receiver)
            callable.receiver.class
          end
          {
            class: callable.class.name,
            owner: TraceOwner.label(owner),
            name: callable.respond_to?(:name) ? callable.name&.to_s : nil,
            source: location && File.basename(location[0]),
            line: location && location[1],
            parameters: parameters.map { |kind, name| [kind.to_s, name&.to_s] }
          }
        end

        def declaration_value(value)
          case value
          when Array
            value.map { |item| declaration_value(item) }
          when Hash
            value.to_h { |key, item| [key.to_s, declaration_value(item)] }
          when Module
            {constant: TraceOwner.label(value)}
          when Method, UnboundMethod, Proc
            callable_signature(value)
          when Symbol
            value.to_s
          when String, Integer, Float, TrueClass, FalseClass, NilClass
            value
          else
            {class: value.class.name, value: value.to_s}
          end
        end
      end
    end

    class ProviderDefinitionBuilder
      TRACEPOINT_EVENTS = %i[call c_call c_return script_compiled].freeze

      attr_reader :name, :version

      def initialize(name, version)
        @name = name.to_sym
        @version = Integer(version)
        raise ConfigurationError, "provider version must be a positive integer" unless @version.positive?

        @inventories = []
        @facets = []
        @claims = []
        @observers = []
        @ignores = []
      rescue ArgumentError, TypeError
        raise ConfigurationError, "provider version must be a positive integer"
      end

      def inventory(name, root:, include:, base: ".", exclude: [])
        key = name.to_sym
        duplicate!(:inventory, key, @inventories)
        patterns = strings(include, "inventory include")
        raise ConfigurationError, "inventory #{key} must include at least one pattern" if patterns.empty?

        @inventories << InventoryDefinition.new(
          name: key,
          root: root.to_sym,
          base: String(base).dup.freeze,
          include_patterns: patterns,
          exclude_patterns: strings(exclude, "inventory exclude")
        )
        self
      rescue NoMethodError, TypeError
        raise ConfigurationError, "invalid inventory #{name.inspect}"
      end

      def facet(name, inventory:, digest:, granularity:, scope: :test)
        key = name.to_sym
        duplicate!(:facet, key, @facets)
        pair = [digest.to_sym, granularity.to_sym]
        unless ProviderDefinition::ALLOWED_FACETS.include?(pair)
          raise ConfigurationError,
            "facet #{key} must be content/file, existence/file, paths/set, contents/set, or ruby_source/file"
        end
        scope = scope.to_sym
        raise ConfigurationError, "facet #{key} scope must be :test or :suite" unless %i[test suite].include?(scope)

        @facets << FacetDefinition.new(
          name: key,
          inventory: inventory.to_sym,
          digest: pair[0],
          granularity: pair[1],
          scope: scope
        )
        self
      rescue NoMethodError
        raise ConfigurationError, "invalid facet #{name.inspect}"
      end

      def claim(event_kind, to:, path: nil, using: nil)
        target = Array(to)
        unless target.length == 2
          raise ConfigurationError, "claim #{event_kind} target must be [inventory, facet]"
        end
        inventory, facet = target.map(&:to_sym)
        validate_selector!(path, "claim path") if path
        validate_callable!(using, "claim using") if using
        raise ConfigurationError, "claim #{event_kind} cannot use both path: and using:" if path && using

        @claims << ClaimDefinition.new(
          event_kind: event_kind.to_sym,
          inventory: inventory,
          facet: facet,
          path: path.respond_to?(:freeze) ? path.freeze : path,
          using: using&.freeze
        )
        self
      rescue NoMethodError
        raise ConfigurationError, "invalid claim #{event_kind.inspect}"
      end

      def observe_tracepoint(event_kind, target:, event: :call, path: nil, details: nil)
        validate_callable!(path, "TracePoint path") if path
        validate_callable!(details, "TracePoint details") if details
        trace_event = event.to_sym
        raise ConfigurationError, "invalid TracePoint event: #{event}" unless TRACEPOINT_EVENTS.include?(trace_event)

        @observers << ObserverDefinition.new(
          type: :tracepoint,
          event_kind: event_kind.to_sym,
          target: frozen_target(target),
          event: trace_event,
          notification_name: nil,
          path: path&.freeze,
          details: details&.freeze
        )
        self
      rescue NoMethodError
        raise ConfigurationError, "invalid TracePoint observer #{event_kind.inspect}"
      end

      def observe_notification(event_kind, notification_name, path: nil, details: nil)
        validate_callable!(path, "notification path") if path
        validate_callable!(details, "notification details") if details
        name = String(notification_name)
        raise ConfigurationError, "notification name cannot be empty" if name.empty?

        @observers << ObserverDefinition.new(
          type: :notification,
          event_kind: event_kind.to_sym,
          target: nil,
          event: nil,
          notification_name: name.dup.freeze,
          path: path&.freeze,
          details: details&.freeze
        )
        self
      rescue TypeError, NoMethodError
        raise ConfigurationError, "invalid notification observer #{event_kind.inspect}"
      end

      def ignore(event_kind, reason:, predicate:)
        validate_callable!(predicate, "ignore predicate")
        text = String(reason)
        raise ConfigurationError, "ignore reason cannot be empty" if text.empty?

        @ignores << IgnoreDefinition.new(
          event_kind: event_kind.to_sym,
          reason: text.dup.freeze,
          predicate: predicate.freeze
        )
        self
      rescue TypeError, NoMethodError
        raise ConfigurationError, "invalid ignore #{event_kind.inspect}"
      end

      def build
        normalize_membership_facets!
        inventory_names = @inventories.map(&:name)
        @facets.each do |facet|
          unless inventory_names.include?(facet.inventory)
            raise ConfigurationError, "facet #{facet.name} references unknown inventory: #{facet.inventory}"
          end
        end
        @claims.each do |claim|
          facet = @facets.find { |item| item.name == claim.facet }
          raise ConfigurationError, "claim #{claim.event_kind} references unknown facet: #{claim.facet}" unless facet
          unless facet.inventory == claim.inventory
            raise ConfigurationError,
              "claim #{claim.event_kind} target must pair facet #{claim.facet} with inventory #{facet.inventory}"
          end
          if facet.granularity == :file && !claim.path && !claim.using
            raise ConfigurationError, "file claim #{claim.event_kind} requires path: or using:"
          end
        end

        ProviderDefinition.new(
          name: name,
          version: version,
          inventories: @inventories.sort_by { |item| item.name.to_s },
          facets: @facets.sort_by { |item| item.name.to_s },
          claims: @claims.sort_by { |item| [item.event_kind.to_s, item.inventory.to_s, item.facet.to_s] },
          observers: @observers.sort_by { |item| [item.event_kind.to_s, item.type.to_s, item.notification_name.to_s] },
          ignores: @ignores.sort_by { |item| [item.event_kind.to_s, item.reason] }
        )
      end

      private

      # Membership is an input of every declared inventory, not an optional
      # optimization a provider author has to remember. It is always
      # suite-scoped and SnapshotBuilder copies it onto every passing test.
      # A claim declaration alone cannot prove that a provider observes both
      # successful and unsuccessful lookups, so there is deliberately no
      # test-scoped membership optimization.
      def normalize_membership_facets!
        @inventories.each do |inventory|
          memberships = @facets.select do |facet|
            facet.inventory == inventory.name &&
              facet.digest == ProviderDefinition::MEMBERSHIP_DIGEST &&
              facet.granularity == ProviderDefinition::MEMBERSHIP_GRANULARITY
          end
          if memberships.length > 1
            raise ConfigurationError, "inventory #{inventory.name} must have exactly one membership facet"
          end

          membership = memberships.first || add_default_membership(inventory)
          next if membership.scope == :suite

          @facets[@facets.index(membership)] = membership.with(scope: :suite)
        end
      end

      def add_default_membership(inventory)
        candidate = :membership
        if @facets.any? { |facet| facet.name == candidate }
          candidate = :"#{inventory.name}_membership"
        end
        suffix = 2
        while @facets.any? { |facet| facet.name == candidate }
          candidate = :"#{inventory.name}_membership_#{suffix}"
          suffix += 1
        end

        FacetDefinition.new(
          name: candidate,
          inventory: inventory.name,
          digest: ProviderDefinition::MEMBERSHIP_DIGEST,
          granularity: ProviderDefinition::MEMBERSHIP_GRANULARITY,
          scope: :suite
        ).tap { |facet| @facets << facet }
      end

      def __observe_builtin_test_start(event_kind, details:)
        validate_callable!(details, "built-in test-start details")
        @observers << ObserverDefinition.new(
          type: :test_start,
          event_kind: event_kind.to_sym,
          target: nil,
          event: nil,
          notification_name: nil,
          path: nil,
          details: details.freeze
        )
        self
      rescue NoMethodError
        raise ConfigurationError, "invalid built-in test-start observer #{event_kind.inspect}"
      end

      def duplicate!(kind, name, collection)
        raise ConfigurationError, "#{kind} #{name} is already configured" if collection.any? { |item| item.name == name }
      end

      def strings(values, label)
        Array(values).map { |value| String(value).dup.freeze }.uniq.sort.freeze
      rescue TypeError
        raise ConfigurationError, "#{label} must contain strings"
      end

      def validate_callable!(callable, label)
        raise ConfigurationError, "#{label} must respond to call" unless callable.respond_to?(:call)
      end

      def validate_selector!(selector, label)
        return if selector.is_a?(Symbol)
        validate_callable!(selector, label)
      end

      def frozen_target(target)
        if target.is_a?(String)
          unless target.match?(/\A[A-Z]\w*(?:::[A-Z]\w*)*\.[a-zA-Z_]\w*[!?=]?\z/)
            raise ConfigurationError, "TracePoint target must be Constant.method"
          end
          return target.dup.freeze
        end
        return :any if target == :any
        unless target.is_a?(Array) && target.length == 2
          raise ConfigurationError, "TracePoint target must be Constant.method or [owner, method_name]"
        end

        [target[0], target[1].to_sym].freeze
      end
    end
  end
end

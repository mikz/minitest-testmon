# frozen_string_literal: true

module Minitest
  module Testmon
    # Each activation is immutable except for its enabled flag. Re-enabling a
    # subscription creates a new activation, so it cannot join an active event.
    class GlobalTraceRouter
      class Activation
        attr_reader :callback
        attr_accessor :enabled

        def initialize(callback)
          @callback = callback
          @enabled = true
        end
      end

      class Subscription
        attr_reader :event, :method_name, :activation

        def initialize(router, event, method_name, callback)
          @router = router
          @event = event
          @method_name = method_name
          @callback = callback
        end

        def enable
          return self if enabled?
          @activation = Activation.new(@callback)
          @router.activate(self)
          self
        end

        def disable
          return self unless enabled?
          @activation.enabled = false
          @router.deactivate(self)
          self
        end
        alias_method :close, :disable

        def enabled?
          @activation&.enabled || false
        end
      end

      def initialize(events:, native: true)
        @events = events.uniq.freeze
        @index = {}
        @subscriptions = []
        @trace = TracePointFactory.build_router(@events, @index, native:)
      end

      def subscribe(event, method_name = nil, &callback)
        raise ArgumentError, "event outside router event set" unless @events.include?(event)
        raise ArgumentError, "callback required" unless callback
        Subscription.new(self, event, method_name, callback).enable
      end

      def activate(subscription)
        @subscriptions.unshift(subscription)
        rebuild(subscription.event)
        @trace.enable unless @trace.enabled?
      end

      def deactivate(subscription)
        @subscriptions.delete(subscription)
        rebuild(subscription.event)
        @trace.disable if @subscriptions.empty?
      end

      def close
        @subscriptions.dup.each(&:disable)
      end

      private

      def rebuild(event)
        subscriptions = @subscriptions.select { |subscription| subscription.event == event }
        methods = subscriptions.map(&:method_name).compact.uniq
        table = {nil => subscriptions.select { |subscription| subscription.method_name.nil? }.map(&:activation).freeze}
        methods.each do |method_name|
          table[method_name] = subscriptions.select do |subscription|
            subscription.method_name.nil? || subscription.method_name == method_name
          end.map(&:activation).freeze
        end
        @index[event] = table.freeze
      end
    end
  end
end

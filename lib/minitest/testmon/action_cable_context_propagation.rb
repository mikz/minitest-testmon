# frozen_string_literal: true

module Minitest
  module Testmon
    module ActionCableContextPropagation
      class Callback
        attr_reader :original

        def initialize(original)
          @original = original
          @call = ConcurrentContextPropagation.capture(original)
        end

        def call(*arguments, **keywords)
          @call.call(*arguments, **keywords)
        end

        # SubscriberMap stores callbacks in an Array and deletes by equality.
        # Preserve unsubscribe(original), including duplicate subscriptions,
        # without changing the adapter's registration or delivery ordering.
        def ==(other)
          original == (other.is_a?(Callback) ? other.original : other)
        end
      end

      def self.install!
        return unless defined?(::ActionCable::SubscriptionAdapter)

        require "action_cable/subscription_adapter/inline"
        adapter = ::ActionCable::SubscriptionAdapter::Inline
        adapter.prepend(self) unless adapter.ancestors.include?(self)
      end

      def subscribe(channel, callback, success_callback = nil)
        super(channel, Callback.new(callback), success_callback && Callback.new(success_callback))
      end
    end
  end
end

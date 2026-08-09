# frozen_string_literal: true

module Minitest
  module Testmon
    module ObjectIdentity
      EQUAL = BasicObject.instance_method(:equal?)
      ID = BasicObject.instance_method(:__id__)

      def self.equal?(left, right)
        EQUAL.bind_call(left, right)
      end

      def self.id(object)
        ID.bind_call(object)
      end
    end
  end
end

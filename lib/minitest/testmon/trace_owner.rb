# frozen_string_literal: true

module Minitest
  module Testmon
    module TraceOwner
      MODULE_NAME = Module.instance_method(:name)
      ATTACHED_OBJECT = Class.instance_method(:attached_object)

      module_function

      def label(owner)
        return unless Module === owner

        name = MODULE_NAME.bind_call(owner)
        return name unless name.to_s.empty?

        attached = ATTACHED_OBJECT.bind_call(owner)
        attached_name = MODULE_NAME.bind_call(attached) if Module === attached
        return "#<Class:#{attached_name}>" unless attached_name.to_s.empty?

        "#<Class>"
      rescue TypeError
        (Class === owner) ? "#<Class>" : "#<Module>"
      end
    end
  end
end

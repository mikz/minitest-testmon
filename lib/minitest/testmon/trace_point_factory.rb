# frozen_string_literal: true

begin
  require "minitest/testmon/native_tracepoint"
rescue LoadError => error
  raise unless error.path == "minitest/testmon/native_tracepoint"

  require "rbconfig"
  development_extension = File.expand_path("../../../ext/minitest_testmon_native/native_tracepoint.#{RbConfig::CONFIG.fetch("DLEXT")}", __dir__)
  require development_extension if File.file?(development_extension)
end

module Minitest
  module Testmon
    module TracePointFactory
      CLASS_MEMBERSHIP = Module.instance_method(:===)

      module_function

      def build_router(events, index, native: true)
        return NativeTracePoint.build_router(events, index) {} if native && defined?(NativeTracePoint)

        TracePoint.new(*events) do |event|
          methods = index[event.event]
          next unless methods
          candidates = methods.fetch(event.method_id) { methods[nil] }
          candidates&.each { |activation| activation.callback.call(event) if activation.enabled }
        end
      end

      def build_target(source_paths:, source:, constant_lines:, recorded:, &callback)
        if defined?(NativeTracePoint) && source && constant_lines
          NativeTracePoint.build_target(source_paths, source, constant_lines, recorded, &callback)
        else
          TracePoint.new(*RUBY_TARGET_TRACE_EVENTS, &callback)
        end
      end

      def build(events, filters = {}, &callback)
        return NativeTracePoint.build(events, filters, &callback) if defined?(NativeTracePoint)

        build_ruby(events, filters, &callback)
      end

      def build_ruby(events, filters = {}, &callback)
        filters = filters.dup.freeze
        TracePoint.new(*events) do |event|
          methods = filters.fetch(event.event, nil)
          requirement = methods ? methods.fetch(event.method_id, false) : true
          next unless requirement
          if CLASS_MEMBERSHIP.bind_call(Module, requirement)
            next unless CLASS_MEMBERSHIP.bind_call(requirement, event.self)
          end
          callback.call(event)
        end
      end
    end
  end
end

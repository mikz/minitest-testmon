# frozen_string_literal: true

module Minitest
  module Testmon
    # Native TracePoint events do not expose IO's path arguments. Capture them
    # at the Ruby boundary, retaining native dispatch and its return values.
    module DirectFileReads
      GUARD = :minitest_testmon_direct_file_read
      @observers = [].freeze

      module Methods
        def read(*args, **options, &block)
          if DirectFileReads.active?
            args = DirectFileReads.arguments(self, :read, args, caller_locations(1, 1).first)
          end
          super
        end

        def binread(*args, **options, &block)
          if DirectFileReads.active?
            args = DirectFileReads.arguments(self, :binread, args, caller_locations(1, 1).first)
          end
          super
        end

        def readlines(*args, **options, &block)
          if DirectFileReads.active?
            args = DirectFileReads.arguments(self, :readlines, args, caller_locations(1, 1).first)
          end
          super
        end

        def foreach(*args, **options, &block)
          # Native enumerators call foreach again when consumed. Do not coerce
          # the path or claim a read merely because an enumerator was created.
          if block && DirectFileReads.active?
            args = DirectFileReads.arguments(self, :foreach, args, caller_locations(1, 1).first)
          end
          super
        end
      end

      class << self
        def subscribe(observer)
          IO.singleton_class.prepend(Methods) unless IO.singleton_class < Methods
          @observers = (@observers + [observer]).freeze
        end

        def unsubscribe(observer)
          @observers = @observers.reject { |item| ObjectIdentity.equal?(item, observer) }.freeze
        end

        def active?
          return false unless Ractor.current == Ractor.main
          !@observers.empty? && !Thread.current.thread_variable_get(GUARD)
        end

        def arguments(receiver, operation, args, location)
          return args if args.empty? || !location
          return args unless ObjectIdentity.equal?(receiver, File) || ObjectIdentity.equal?(receiver, IO)

          observers = @observers.select { |observer| observer.direct_read_callsite?(location) }
          return args if observers.empty?

          # Coerce once, then pass that same String to native IO. Calling to_path
          # for observation and again in IO can read a different file.
          path = File.path(args.first)
          previous_guard = Thread.current.thread_variable_get(GUARD)
          begin
            Thread.current.thread_variable_set(GUARD, true)
            observers.each { |observer| observer.record_direct_read(path, operation, location, receiver) }
          ensure
            Thread.current.thread_variable_set(GUARD, previous_guard)
          end
          [path, *args.drop(1)]
        end

        def wrapper_call?(trace)
          %i[read binread readlines foreach].include?(trace.method_id) && trace.path == __FILE__
        end
      end
    end
  end
end

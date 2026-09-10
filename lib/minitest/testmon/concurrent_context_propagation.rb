# frozen_string_literal: true

module Minitest
  module Testmon
    module ConcurrentContextPropagation
      class << self
        def install!
          # Integrate only an already loaded optional dependency. Tasks from
          # unsupported APIs retain the observer's fail-closed attribution.
          return unless defined?(::Concurrent::Promises::AbstractEventFuture) && defined?(::Concurrent::Promises::Future)

          base = ::Concurrent::Promises::AbstractEventFuture
          future = ::Concurrent::Promises::Future
          return unless base.method_defined?(:chain_on) && future.method_defined?(:then_on) && future.method_defined?(:rescue_on)

          base.prepend(EventTasks) unless base.ancestors.include?(EventTasks)
          future.prepend(FutureTasks) unless future.ancestors.include?(FutureTasks)
        end

        def capture(task)
          return unless task

          token = ExecutionContext.attribution_token
          source = task.respond_to?(:source_location) ? task : task.method(:call)
          token = nil if token && !token.owns_thread_block?(source)
          scope = ExecutionContext.evidence_scope
          proc do |*arguments, **keywords|
            # Nested immediate tasks already run under the same registration;
            # borrowing again would unregister the still-running outer task.
            if token && ExecutionContext.attribution_token.equal?(token)
              next ExecutionContext.with_evidence_scope(scope) { task.call(*arguments, **keywords) }
            end

            # A queued task can outlive its token or run synchronously inside
            # another boundary. Neither may lend it the executor's context.
            ExecutionContext.with_attribution(nil) do
              ExecutionContext.with_evidence_scope(scope) do
                if token
                  ExecutionContext.with_borrowed_attribution(token) { task.call(*arguments, **keywords) }
                else
                  task.call(*arguments, **keywords)
                end
              end
            end
          end
        end
      end

      module EventTasks
        def chain_on(executor, *arguments, &task)
          super(executor, *arguments, &ConcurrentContextPropagation.capture(task))
        end
      end

      module FutureTasks
        def then_on(executor, *arguments, &task)
          super(executor, *arguments, &ConcurrentContextPropagation.capture(task))
        end

        def rescue_on(executor, *arguments, &task)
          super(executor, *arguments, &ConcurrentContextPropagation.capture(task))
        end
      end
    end
  end
end

# frozen_string_literal: true

module Minitest
  module Testmon
    module ThreadContextPropagation
      class << self
        def install!
          singleton = Thread.singleton_class
          singleton.prepend(self) unless singleton.ancestors.include?(self)
        end
      end

      %i[new start fork].each do |constructor|
        define_method(constructor) do |*arguments, **keywords, &block|
          token = ExecutionContext.attribution_token
          return super(*arguments, **keywords, &block) unless token && block && token.owns_thread_block?(block)

          evidence_scope = ExecutionContext.evidence_scope
          thread = super(*arguments, **keywords) do |*block_arguments|
            thread = Thread.current
            ExecutionContext.with_evidence_scope(evidence_scope) do
              ExecutionContext.with_attribution(token) { block.call(*block_arguments) }
            end
          ensure
            token.unregister(thread) if thread
          end
          token.register(thread)
          thread
        end
      end
    end
  end
end

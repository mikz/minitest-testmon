# frozen_string_literal: true

module Minitest
  module Testmon
    module Engine
      module_function

      def supported?
        RUBY_ENGINE == "ruby" && defined?(RubyVM::InstructionSequence)
      end

      def signature
        {
          testmon_version: VERSION,
          fingerprint_algorithm: FINGERPRINT_ALGORITHM_VERSION,
          selection_algorithm: SELECTION_ALGORITHM_VERSION,
          engine: RUBY_ENGINE,
          version: RUBY_VERSION,
          patchlevel: RUBY_PATCHLEVEL,
          revision: RUBY_REVISION,
          platform: RUBY_PLATFORM,
          description: RUBY_DESCRIPTION,
          iseq: supported? ? RubyVM::InstructionSequence.compile("nil").to_a.values_at(0, 1, 2, 3) : nil,
          compile_options: supported? ? RubyVM::InstructionSequence.compile_option : nil
        }
      end
    end
  end
end

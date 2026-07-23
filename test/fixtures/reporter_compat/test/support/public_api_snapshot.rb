# frozen_string_literal: true

require "json"

module ReporterCompat
  module PublicApiSnapshot
    module_function

    def write(path)
      destination = Pathname(path)
      destination.dirname.mkpath
      destination.write(JSON.pretty_generate(capture))
    end

    def capture
      {
        "versions" => {
          "minitest" => Minitest::VERSION,
          "minitest-reporters" => Minitest::Reporters::VERSION,
          "rails" => Rails.version
        },
        "Minitest.singleton" => singleton_methods(Minitest, %i[init_plugins load_plugins run]),
        "Minitest::Runnable.singleton" => singleton_methods(
          Minitest::Runnable,
          %i[run run_suite runnable_methods]
        ),
        "Minitest::Test" => instance_methods(Minitest::Test, %i[run]),
        "Minitest::CompositeReporter" => instance_methods(
          Minitest::CompositeReporter,
          %i[<< start prerecord record report passed?]
        ),
        "Minitest::Reporters.singleton" => singleton_methods(
          Minitest::Reporters,
          %i[reporters reporters= use! use_runner!]
        ),
        "Minitest::Reporters::DelegateReporter" => instance_methods(
          Minitest::Reporters::DelegateReporter,
          %i[io start prerecord record report passed?]
        ),
        "ActionView::LookupContext" => instance_methods(
          ActionView::LookupContext,
          %i[exists? find find_all]
        ),
        "ActiveRecord::FixtureSet.singleton" => singleton_methods(
          ActiveRecord::FixtureSet,
          %i[create_fixtures]
        ),
        "ancestors" => {
          "Minitest::Runnable.singleton" => named_ancestors(Minitest::Runnable.singleton_class),
          "Minitest::Test" => named_ancestors(Minitest::Test),
          "Minitest::CompositeReporter" => named_ancestors(Minitest::CompositeReporter),
          "Minitest::Reporters.singleton" => named_ancestors(Minitest::Reporters.singleton_class),
          "Minitest::Reporters::DelegateReporter" => named_ancestors(
            Minitest::Reporters::DelegateReporter
          ),
          "ActionView::LookupContext" => named_ancestors(ActionView::LookupContext),
          "ActiveRecord::FixtureSet.singleton" => named_ancestors(
            ActiveRecord::FixtureSet.singleton_class
          )
        }
      }
    end

    def singleton_methods(object, names)
      names.to_h { |name| [name.to_s, method_snapshot(object.method(name))] }
    end

    def instance_methods(object, names)
      names.to_h { |name| [name.to_s, method_snapshot(object.instance_method(name))] }
    end

    def method_snapshot(callable)
      {
        "owner" => callable.owner.name,
        "source_location" => callable.source_location,
        "parameters" => callable.parameters,
        "arity" => callable.arity
      }
    end

    def named_ancestors(object)
      object.ancestors.map { |ancestor| ancestor.name || ancestor.inspect }
    end
  end
end

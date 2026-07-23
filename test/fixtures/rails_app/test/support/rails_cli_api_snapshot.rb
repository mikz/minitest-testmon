# frozen_string_literal: true

require "json"
require "psych"
require "yaml"

module RailsCliApiSnapshot
  module_function

  def write(path)
    destination = Pathname(path)
    destination.dirname.mkpath
    destination.write(JSON.pretty_generate(capture))
  end

  def capture
    {
      "File.singleton" => singleton_methods(File, %i[new open read binread]),
      "IO.singleton" => singleton_methods(IO, %i[new open read binread]),
      "IO.instance" => instance_methods(IO, %i[read readpartial sysread]),
      "Kernel.instance" => instance_methods(Kernel, %i[load require]),
      "Pathname.instance" => instance_methods(Pathname, %i[read binread open]),
      "Psych.singleton" => singleton_methods(Psych, %i[load_file safe_load_file unsafe_load_file]),
      "YAML.singleton" => singleton_methods(YAML, %i[load_file safe_load_file unsafe_load_file]),
      "JSON.singleton" => singleton_methods(JSON, %i[load parse generate]),
      "Minitest.singleton" => singleton_methods(Minitest, %i[init_plugins run process_args]),
      "Minitest::Runnable.singleton" => singleton_methods(Minitest::Runnable, %i[run runnable_methods]),
      "Minitest::Test.instance" => instance_methods(Minitest::Test, %i[run]),
      "Minitest::CompositeReporter.instance" =>
        instance_methods(Minitest::CompositeReporter, %i[start prerecord record report passed?]),
      "ActionView::LookupContext.instance" =>
        instance_methods(ActionView::LookupContext, %i[exists? find find_all]),
      "ActiveRecord::FixtureSet.singleton" =>
        singleton_methods(ActiveRecord::FixtureSet, %i[create_fixtures]),
      "I18n.singleton" => singleton_methods(I18n, %i[t translate localize]),
      "ancestors" => {
        "File" => names(File.ancestors),
        "File.singleton" => names(File.singleton_class.ancestors),
        "IO" => names(IO.ancestors),
        "IO.singleton" => names(IO.singleton_class.ancestors),
        "Kernel" => names(Kernel.ancestors),
        "Pathname" => names(Pathname.ancestors),
        "YAML.singleton" => names(YAML.singleton_class.ancestors),
        "Minitest::Runnable.singleton" => names(Minitest::Runnable.singleton_class.ancestors),
        "Minitest::Test" => names(Minitest::Test.ancestors),
        "Minitest::CompositeReporter" => names(Minitest::CompositeReporter.ancestors),
        "ActionView::LookupContext" => names(ActionView::LookupContext.ancestors),
        "ActiveRecord::FixtureSet.singleton" => names(ActiveRecord::FixtureSet.singleton_class.ancestors),
        "I18n.singleton" => names(I18n.singleton_class.ancestors)
      }
    }
  end

  def singleton_methods(object, method_names)
    method_names.to_h { |name| [name.to_s, method_snapshot(object.method(name))] }
  end

  def instance_methods(object, method_names)
    method_names.to_h { |name| [name.to_s, method_snapshot(object.instance_method(name))] }
  end

  def method_snapshot(method)
    {
      "owner" => method.owner.name,
      "source_location" => method.source_location,
      "parameters" => method.parameters,
      "arity" => method.arity
    }
  end

  def names(ancestors)
    ancestors.map { |ancestor| ancestor.name || ancestor.inspect }
  end
end

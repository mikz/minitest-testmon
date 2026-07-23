# frozen_string_literal: true

require "json"
# standard:disable Lint/RedundantRequireStatement
require "pathname"
require "psych"
# standard:enable Lint/RedundantRequireStatement

output = ENV.fetch("API_SNAPSHOT_PATH")

def method_snapshot(callable)
  {
    "owner" => callable.owner.name,
    "source_location" => callable.source_location,
    "parameters" => callable.parameters,
    "arity" => callable.arity
  }
end

def singleton_snapshot(object, names)
  names.to_h do |name|
    next [name.to_s, nil] unless object.respond_to?(name)
    [name.to_s, method_snapshot(object.method(name))]
  end
end

def instance_snapshot(object, names)
  names.to_h do |name|
    next [name.to_s, nil] unless object.method_defined?(name) || object.private_method_defined?(name)
    [name.to_s, method_snapshot(object.instance_method(name))]
  end
end

snapshot = {
  "File.singleton" => singleton_snapshot(File, %i[new open read binread]),
  "IO.singleton" => singleton_snapshot(IO, %i[new open read binread]),
  "IO.instance" => instance_snapshot(IO, %i[read readpartial sysread]),
  "Pathname.instance" => instance_snapshot(Pathname, %i[read binread open]),
  "Psych.singleton" => singleton_snapshot(Psych, %i[load_file safe_load_file unsafe_load_file]),
  "JSON.singleton" => singleton_snapshot(JSON, %i[load parse generate]),
  "ancestors" => {
    "File" => File.ancestors.map(&:name),
    "File.singleton" => File.singleton_class.ancestors.map(&:name),
    "IO" => IO.ancestors.map(&:name),
    "IO.singleton" => IO.singleton_class.ancestors.map(&:name),
    "Pathname" => Pathname.ancestors.map(&:name),
    "Psych.singleton" => Psych.singleton_class.ancestors.map(&:name),
    "JSON.singleton" => JSON.singleton_class.ancestors.map(&:name)
  }
}

File.write(output, JSON.pretty_generate(snapshot))

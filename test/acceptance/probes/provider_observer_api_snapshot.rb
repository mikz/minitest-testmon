# frozen_string_literal: true

require "active_support/notifications"
require "json"
require "yaml"

output = ENV.fetch("PROVIDER_API_SNAPSHOT_PATH")

def method_snapshot(callable)
  {
    "owner" => callable.owner.name,
    "source_location" => callable.source_location,
    "parameters" => callable.parameters,
    "arity" => callable.arity
  }
end

snapshot = {
  "TracePoint.singleton" => %i[new stat].to_h do |name|
    [name.to_s, method_snapshot(TracePoint.method(name))]
  end,
  "TracePoint.instance" => %i[enable disable enabled? event method_id path lineno].to_h do |name|
    [name.to_s, method_snapshot(TracePoint.instance_method(name))]
  end,
  "ActiveSupport::Notifications.singleton" => %i[instrument subscribe subscribed unsubscribe].to_h do |name|
    [name.to_s, method_snapshot(ActiveSupport::Notifications.method(name))]
  end,
  "Psych.singleton" => %i[load_file safe_load_file].to_h do |name|
    [name.to_s, method_snapshot(Psych.method(name))]
  end,
  "ancestors" => {
    "TracePoint" => TracePoint.ancestors.map(&:name),
    "ActiveSupport::Notifications.singleton" => ActiveSupport::Notifications.singleton_class.ancestors.map(&:name),
    "Psych.singleton" => Psych.singleton_class.ancestors.map(&:name)
  }
}

File.write(output, JSON.pretty_generate(snapshot))

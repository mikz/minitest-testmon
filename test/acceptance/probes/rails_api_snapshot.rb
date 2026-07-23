# frozen_string_literal: true

require "json"
require_relative "config/environment"
require "active_record/fixtures"

output = ENV.fetch("RAILS_API_SNAPSHOT_PATH")

def public_method_snapshot(callable)
  {
    "owner" => callable.owner.name,
    "source_location" => callable.source_location,
    "parameters" => callable.parameters,
    "arity" => callable.arity
  }
end

def public_instance_snapshot(object, names)
  names.to_h do |name|
    method = object.instance_method(name)
    [name.to_s, public_method_snapshot(method)]
  end
end

snapshot = {
  "ActionView::LookupContext" => public_instance_snapshot(
    ActionView::LookupContext,
    %i[exists? find find_all]
  ),
  "ActiveRecord::FixtureSet.singleton" => %i[create_fixtures].to_h do |name|
    [name.to_s, public_method_snapshot(ActiveRecord::FixtureSet.method(name))]
  end,
  "I18n.singleton" => %i[t translate localize].to_h do |name|
    [name.to_s, public_method_snapshot(I18n.method(name))]
  end,
  "ancestors" => {
    "ActionView::LookupContext" => ActionView::LookupContext.ancestors.map(&:name),
    "ActiveRecord::FixtureSet.singleton" => ActiveRecord::FixtureSet.singleton_class.ancestors.map(&:name),
    "I18n.singleton" => I18n.singleton_class.ancestors.map(&:name)
  }
}

File.write(output, JSON.pretty_generate(snapshot))

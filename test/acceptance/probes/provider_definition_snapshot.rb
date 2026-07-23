# frozen_string_literal: true

require "json"
require "minitest/testmon"

def deeply_frozen?(object)
  return false unless object.frozen?

  case object
  when Array
    object.all? { |item| deeply_frozen?(item) }
  when Hash
    object.all? { |key, value| deeply_frozen?(key) && deeply_frozen?(value) }
  else
    true
  end
end

providers = Minitest::Testmon.configuration.providers
snapshot = providers.map do |provider|
  {
    "id" => provider.id.to_s,
    "name" => provider.name.to_s,
    "version" => provider.version,
    "definition_frozen" => provider.frozen?,
    "collections_frozen" => %i[inventories facets claims observers].to_h do |collection|
      [collection.to_s, deeply_frozen?(provider.public_send(collection))]
    end
  }
end.sort_by { |provider| provider.fetch("id") }

mutation_error = begin
  providers << Object.new
  nil
rescue => error
  error.class.name
end

File.write(
  ENV.fetch("PROVIDER_DEFINITION_SNAPSHOT"),
  JSON.pretty_generate(
    "providers_frozen" => providers.frozen?,
    "mutation_error" => mutation_error,
    "providers" => snapshot
  )
)

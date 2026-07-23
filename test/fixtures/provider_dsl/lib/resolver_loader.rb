# frozen_string_literal: true

require "yaml"

class ResolverLoader
  def self.load(path)
    YAML.safe_load_file(path)
  end
end

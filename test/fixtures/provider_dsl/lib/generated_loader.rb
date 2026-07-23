# frozen_string_literal: true

require "yaml"

class GeneratedLoader
  def self.load(path)
    YAML.safe_load_file(path)
  end
end

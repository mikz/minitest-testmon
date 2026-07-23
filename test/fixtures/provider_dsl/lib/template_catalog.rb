# frozen_string_literal: true

class TemplateCatalog
  def self.entries(path)
    Dir.children(path).select { |entry| entry.end_with?(".txt") }.sort
  end
end

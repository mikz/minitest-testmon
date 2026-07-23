# frozen_string_literal: true

module AdversarialLoader
  module_function

  # File.open is deliberate: its Ruby block gives the observer an exact path.
  # standard:disable Style/FileRead
  def read(path)
    File.open(path, "r", &:read)
  end
  # standard:enable Style/FileRead

  def entries(path)
    Dir.children(path).sort
  end
end

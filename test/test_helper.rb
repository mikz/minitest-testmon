# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "minitest/testmon"

class TestmonTestCase < Minitest::Test
  def with_project
    Dir.mktmpdir("minitest-testmon-test") do |directory|
      yield directory
    end
  end

  def write_file(path, content)
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, content)
    path
  end
end

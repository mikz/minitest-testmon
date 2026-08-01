# frozen_string_literal: true

require "bundler/gem_tasks"
require "minitest/test_task"
require "standard/rake"
require "rubygems/package"
require "rbconfig"
require "tmpdir"

Minitest::TestTask.create do |task|
  task.test_globs = ["test/*_test.rb"]
  task.warning = true
end

Minitest::TestTask.create("test:acceptance") do |task|
  task.libs = ["test/acceptance/support", "."]
  task.test_globs = ["test/acceptance/*_test.rb"]
  task.warning = true
end

Minitest::TestTask.create("test:acceptance:self") do |task|
  task.libs = ["test/acceptance/support", "."]
  task.test_globs = ["test/acceptance/*self_test.rb"]
  task.warning = true
end

desc "Require the built gem using only its unpacked lib directory"
task package_smoke: :build do
  gem_path = Dir[File.join(__dir__, "pkg", "minitest-testmon-*.gem")].max_by { |path| File.mtime(path) }
  raise "built gem not found" unless gem_path

  Dir.mktmpdir("minitest-testmon-package") do |directory|
    Gem::Package.new(gem_path).extract_files(directory)
    success = Bundler.with_unbundled_env do
      system(
        RbConfig.ruby,
        "-I#{File.join(directory, "lib")}",
        "-e",
        'require "minitest/testmon"'
      )
    end
    raise "unpacked gem could not require minitest/testmon" unless success
  end
end

desc "Run every validation gate"
task ci: %i[test standard build package_smoke test:acceptance]

task default: %i[test standard]

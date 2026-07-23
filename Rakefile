# frozen_string_literal: true

require "bundler/gem_tasks"
require "minitest/test_task"
require "standard/rake"

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

desc "Run every validation gate"
task ci: %i[test standard build test:acceptance]

task default: %i[test standard]

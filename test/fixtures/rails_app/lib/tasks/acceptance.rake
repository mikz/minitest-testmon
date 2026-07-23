# frozen_string_literal: true

require "fileutils"

Rake::Task["test:prepare"].enhance do
  marker = ENV["RAILS_ACCEPTANCE_TASK_MARKER"]
  next unless marker

  FileUtils.mkdir_p(File.dirname(marker))
  File.write(marker, "test:prepare ran\n")
end

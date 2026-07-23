# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require_relative "../lib/adversarial_loader"

ADVERSARIAL_ROOT = Pathname.new(File.expand_path("..", __dir__))

module AdversarialFixtureHelpers
  def adversarial_read(relative_path)
    AdversarialLoader.read(ADVERSARIAL_ROOT.join(relative_path).to_s)
  end

  def wait_in_selection_gap(kind)
    return unless ENV["ADVERSARIAL_SELECTION_GAP"] == kind

    ready = Pathname.new(ENV.fetch("ADVERSARIAL_GAP_READY"))
    release = Pathname.new(ENV.fetch("ADVERSARIAL_GAP_RELEASE"))
    ready.dirname.mkpath
    ready.write(Process.pid.to_s)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 20
    until release.exist?
      raise "selection-gap barrier timed out" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      Thread.pass
    end
  end

  def replace_symlink_target(target)
    link = ADVERSARIAL_ROOT.join("data/symlink.txt")
    FileUtils.rm_f(link)
    File.symlink(target, link)
  end
end

class Minitest::Test
  include AdversarialFixtureHelpers
end

# frozen_string_literal: true

require_relative "test_helper"

class NonMutationTest < TestmonTestCase
  def test_observer_does_not_change_core_ancestors_or_method_owners
    before = core_shape
    session = RecordingSession.new
    with_project do |project|
      observer = Minitest::Testmon::CoreObserver.new(
        session,
        resolver: Minitest::Testmon::PathResolver.new(project: project)
      ).start
      observer.close
    end

    assert_equal before, core_shape
  end

  private

  def core_shape
    {
      file_singleton_ancestors: File.singleton_class.ancestors,
      file_ancestors: File.ancestors,
      file_read_owner: File.method(:read).owner,
      file_open_owner: File.method(:open).owner,
      kernel_require_owner: Kernel.instance_method(:require).owner
    }
  end

  class RecordingSession
    attr_reader :observations

    def initialize
      @observations = []
    end

    def record(observation)
      @observations << observation
    end
  end
end

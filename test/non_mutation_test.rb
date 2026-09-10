# frozen_string_literal: true

require_relative "test_helper"

class NonMutationTest < TestmonTestCase
  def test_observer_only_prepends_the_approved_direct_read_boundary_once
    before = core_shape
    session = RecordingSession.new
    with_project do |project|
      observer = Minitest::Testmon::CoreObserver.new(
        session,
        resolver: Minitest::Testmon::PathResolver.new(project: project)
      ).start
      observer.close
    end

    after = core_shape
    wrapper = Minitest::Testmon::DirectFileReads::Methods
    assert_equal before.except(:file_singleton_ancestors, :file_read_owner), after.except(:file_singleton_ancestors, :file_read_owner)
    assert_equal before.fetch(:file_singleton_ancestors).reject { |item| item == wrapper }, after.fetch(:file_singleton_ancestors).reject { |item| item == wrapper }
    assert_equal 1, after.fetch(:file_singleton_ancestors).count(wrapper)
    assert_equal wrapper, after.fetch(:file_read_owner)
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

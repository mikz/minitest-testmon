# frozen_string_literal: true

require_relative "test_helper"

class TestBoundaryObserverTest < TestmonTestCase
  class Case < Minitest::Test
    attr_reader :events

    def initialize(name)
      super
      @events = []
    end

    def setup = events << :setup
    def exercise = events << :body
    def teardown = events << :teardown
  end

  class OverrideCase < Case
    def run
      events << :before_super
      result = super
      events << :after_super
      result
    end
  end

  class SingletonCase < Case
    def initialize(name)
      super
      define_singleton_method(:run) do
        events << :singleton_before
        result = super()
        events << :singleton_after
        result
      end
    end
  end

  class RecursiveCase < Case
    def run
      return super if @recursing
      @recursing = true
      run
    ensure
      @recursing = false
    end
  end

  class NestedCase < Case
    def run
      other = self.class.new(name)
      other.instance_variable_set(:@nested, true)
      other.run unless @nested
      super
    end
  end

  class ConstructorRunsCase < Case
    def initialize(name)
      super
      self.class.new("inner").run if name == "exercise"
    end

    def inner = events << :nested_body
  end

  class RaisingCase < Case
    def run
      raise Interrupt, "escaped run"
    end
  end

  class Worker
    prepend Minitest::Testmon::TestBoundaryObserver::WorkerBridge

    attr_reader :result, :arguments

    def perform_job(job, extra = nil, marker: nil, &block)
      @arguments = [extra, marker, block&.call]
      klass, name = job
      result = klass.new(name).run
      safe_record(nil, result)
    end

    def safe_record(_reporter, result)
      @result = result
      :recorded
    end
  end

  class Session
    attr_reader :started, :outcomes, :diagnostics, :observations

    def initialize
      @started = []
      @outcomes = []
      @diagnostics = []
      @observations = []
    end

    def test_started(test)
      @started << test
      test.events << :started
    end

    def executed(_test_id)
    end

    def seal_completion(test_id, outcome)
      @outcomes << [test_id, outcome]
      @started.last.events << :sealed
    end

    def incomplete(reason) = @diagnostics << reason
    def record(observation) = @observations << observation
  end

  class Collector
    attr_reader :begun, :finished

    def initialize
      @begun = []
      @finished = []
    end

    def reset_for_fork!
    end

    def begin_test(id)
      @begun << id
      Minitest::Testmon::ExecutionContext.set(id)
    end

    def finish_test(id)
      @finished << id
      Minitest::Testmon::ExecutionContext.clear
    end
  end

  def setup
    @session = Session.new
    @collector = Collector.new
    @observer = Minitest::Testmon::TestBoundaryObserver.new(@session, @collector).start
    @worker = Worker.new
  end

  def teardown
    @observer.close
    Minitest::Testmon::ExecutionContext.clear
  end

  def test_actual_outer_override_and_singleton_boundaries_finish_before_reporting
    [Case, OverrideCase, SingletonCase].each do |klass|
      session = @session
      @worker.define_singleton_method(:safe_record) do |reporter, result|
        raise "completion arrived late" unless Minitest::Testmon::ExecutionContext.current_test.nil?
        raise "seal arrived late" unless session.started.last.events.last == :sealed
        super(reporter, result)
      end
      assert_equal :recorded, @worker.perform_job([klass, "exercise"], :extra, marker: :keyword) { :block }
      assert_equal [:extra, :keyword, :block], @worker.arguments
      actual = @session.started.last
      assert_instance_of klass, actual
      assert_equal :started, actual.events.first
      assert_equal :sealed, actual.events.last
      assert_equal 1, actual.events.count(:setup)
      assert_equal 1, actual.events.count(:body)
      assert_equal 1, actual.events.count(:teardown)
    end
    assert_empty @session.diagnostics
    assert_equal @collector.begun, @collector.finished
  end

  def test_preexisting_targeted_call_hooks_do_not_replay_the_outer_boundary
    [Case, OverrideCase, SingletonCase, RecursiveCase, NestedCase].each do |klass|
      prior = TracePoint.new(:call, :line, :b_call) {}
      enabled = false
      prior.enable(target: klass.instance_method(:run))
      enabled = true
      before = @session.started.size
      @worker.perform_job([klass, "exercise"])
      assert_equal before + 1, @session.started.size
      assert_equal :sealed, @session.started.last.events.last
      assert_equal @collector.begun, @collector.finished
      assert_empty @session.diagnostics
    ensure
      prior.disable if enabled
    end
  end

  def test_same_object_recursion_and_different_nested_objects_keep_one_boundary
    [RecursiveCase, NestedCase].each do |klass|
      before = @session.started.size
      @worker.perform_job([klass, "exercise"])
      assert_equal before + 1, @session.started.size
      assert_equal @collector.begun, @collector.finished
    end
    assert_empty @session.diagnostics
  end

  def test_constructor_nested_run_does_not_hide_the_actual_job_instance
    @worker.perform_job([ConstructorRunsCase, "exercise"])
    assert_equal ["inner", "exercise"], @session.started.map(&:name)
    assert_equal @collector.begun, @collector.finished
    assert_equal 2, @session.outcomes.size
    assert_empty @session.diagnostics
  end

  def test_target_failure_uses_conservative_global_boundary_fallback
    @observer.define_singleton_method(:install_target) { |_test| raise ArgumentError, "unsupported target" }
    @worker.perform_job([OverrideCase, "exercise"])
    assert_equal 1, @session.started.size
    assert_equal :started, @session.started.first.events.first
    assert_equal :sealed, @session.started.first.events.last
    assert_empty @session.diagnostics
    refute @observer.instance_variable_get(:@fallback).enabled?
  end

  def test_target_failure_with_ruby_factory_keeps_conservative_boundaries
    factory = Minitest::Testmon::TracePointFactory
    original = factory.method(:build)
    factory.define_singleton_method(:build) { |events, filters = {}, &callback| build_ruby(events, filters, &callback) }
    @observer.define_singleton_method(:install_target) { |_test| raise ArgumentError, "unsupported target" }
    @worker.perform_job([RecursiveCase, "exercise"])
    assert_equal 1, @session.started.size
    assert_equal :sealed, @session.started.last.events.last
    assert_empty @session.diagnostics
  ensure
    factory.define_singleton_method(:build, original) if original
  end

  def test_job_execution_on_another_thread_is_conservatively_incomplete
    @observer.around_job { Thread.new { Case.new("exercise").run }.value }
    assert_includes @session.diagnostics, :worker_incomplete
    assert_empty @session.outcomes
  end

  def test_exception_is_preserved_and_job_traces_are_cleaned
    error = assert_raises(Interrupt) { @worker.perform_job([RaisingCase, "exercise"]) }
    assert_equal "escaped run", error.message
    assert_includes @session.diagnostics, :worker_incomplete
    assert_nil Minitest::Testmon::ExecutionContext.current_test
    count = @session.started.size
    Case.new("exercise").run
    assert_equal count, @session.started.size
  end

  def test_missing_acquisition_is_incomplete
    assert_equal :value, @observer.around_job { :value }
    assert_includes @session.diagnostics, :worker_incomplete
    assert_empty @session.outcomes
  end

  def test_global_acquisition_is_disabled_through_body
    @session.define_singleton_method(:test_started) do |test|
      super(test)
      observer = Minitest::Testmon::TestBoundaryObserver.worker_observer
      raise "global acquisition still active" if observer.instance_variable_get(:@acquisition).enabled?
      raise "global fallback unexpectedly active" if observer.instance_variable_get(:@fallback)&.enabled?
    end
    @worker.perform_job([OverrideCase, "exercise"])
    assert_empty @session.diagnostics
  end
end

# frozen_string_literal: true

require_relative "test_helper"

class NativeTracepointTest < TestmonTestCase
  class Probe
    def value
      "value".bytesize
    end
    alias_method :alias_value, :value

    def require(name)
      name
    end
  end

  def test_target_gate_deduplicates_only_recorded_live_test_and_scope
    context = Minitest::Testmon::ExecutionContext
    recorded = {}
    seen = []
    source = __FILE__
    trace = Minitest::Testmon::NativeTracePoint.build_target([source], source, {}, recorded) do |event|
      seen << [context.current_test, context.evidence_scope, event.event]
      if (test_id = context.current_test)
        scopes = (recorded[test_id] ||= {})
        (scopes[context.evidence_scope] ||= {})[source] = true
      end
    end
    trace.enable(target: RubyVM::InstructionSequence.of(Probe.instance_method(:value))) do
      context.with_test("first") do
        3.times { Probe.new.value }
        context.with_evidence_scope(:suite) { 3.times { Probe.new.value } }
        Probe.new.value
      end
      context.with_test("second") { 3.times { Probe.new.value } }
      context.with_test("revoked") do
        context.attribution_token.revoke
        2.times { Probe.new.value }
      end
    end
    assert_equal [["first", :test], ["first", :suite], ["second", :test]], seen.reject { |entry| entry.first.nil? }.map { |test_id, scope, _event| [test_id, scope] }
    assert_operator seen.count { |entry| entry.first.nil? }, :>, 1
  end

  def test_target_gate_keeps_constant_lines_and_unrecorded_events
    context = Minitest::Testmon::ExecutionContext
    source = __FILE__
    iseq = RubyVM::InstructionSequence.of(Probe.instance_method(:value))
    lines = iseq.trace_points.select { |_line, event| event == :line }.to_h { |line,| [line, true] }
    recorded = {"constant" => {test: {source => true}}}
    seen = []
    trace = Minitest::Testmon::NativeTracePoint.build_target([source], source, lines, recorded) { |event| seen << event.event }
    context.with_test("constant") do
      trace.enable(target: iseq) { 2.times { Probe.new.value } }
    end
    assert_equal [:line, :line], seen
    recorded.clear
    seen.clear
    context.with_test("unrecorded") do
      trace.enable(target: iseq) { 2.times { Probe.new.value } }
    end
    assert_equal 2, seen.count(:call)
  end

  def test_target_gate_always_forwards_require_calls
    context = Minitest::Testmon::ExecutionContext
    source = __FILE__
    seen = []
    recorded = {"require" => {test: {source => true}}}
    trace = Minitest::Testmon::NativeTracePoint.build_target([source], source, {}, recorded) { |event| seen << [event.event, event.method_id] }
    context.with_test("require") do
      trace.enable(target: RubyVM::InstructionSequence.of(Probe.instance_method(:require))) do
        Probe.new.require("one")
        Probe.new.require("two")
      end
    end
    assert_equal [[:call, :require], [:call, :require]], seen
  end

  def test_target_gate_checks_revocation_in_another_thread
    context = Minitest::Testmon::ExecutionContext
    source = __FILE__
    token = context::AttributionToken.new("thread")
    recorded = {"thread" => {test: {source => true}}}
    seen = []
    trace = Minitest::Testmon::NativeTracePoint.build_target([source], source, {}, recorded) { |event| seen << event.event }
    ready = Queue.new
    proceed = Queue.new
    trace.enable(target: RubyVM::InstructionSequence.of(Probe.instance_method(:value)))
    worker = Thread.new do
      context.with_attribution(token) do
        Probe.new.value
        ready << true
        proceed.pop
        Probe.new.value
      end
    end
    ready.pop
    assert_empty seen
    token.revoke
    proceed << true
    worker.value
    assert_includes seen, :call
  ensure
    proceed << true if proceed
    worker&.join
    trace&.disable
  end

  def test_receiver_class_filters_keep_subclasses_and_live_updates_without_dispatch
    [:native, :ruby].each do |implementation|
      receiver_class = Class.new(Probe)
      receiver_class.define_singleton_method(:===) { |_object| raise "class comparison dispatched" }
      receiver = receiver_class.new
      receiver.define_singleton_method(:is_a?) { |_class| raise "receiver membership dispatched" }
      methods = {value: receiver_class}
      seen = []
      trace = build(implementation, [:call], call: methods) { |event| seen << event.self }
      trace.enable do
        Probe.new.value
        receiver.value
        GC.verify_compaction_references
        receiver.value
        methods[:value] = false
        receiver.value
        methods[:value] = Probe
        receiver.value
      end
      assert_equal [receiver, receiver, receiver], seen
    end
  end

  def test_initialize_receiver_filter_rejects_unrelated_objects_and_keeps_files
    [:native, :ruby].each do |implementation|
      seen = []
      trace = build(implementation, [:c_return], c_return: {initialize: File}) { |event| seen << event.self }
      file = nil
      trace.enable do
        Object.new
        file = File.open(__FILE__)
      end
      assert_equal [file], seen
    ensure
      file&.close
    end
  end

  def test_native_filter_matches_ruby_events_and_alias_method_ids
    native = capture(:native) { Probe.new.alias_value }
    reference = capture(:ruby) { Probe.new.alias_value }
    assert_equal reference, native
    assert_equal [[:call, :value], [:c_call, :bytesize], [:return, :value]], native
  end

  def test_live_inner_filters_and_snapshot_outer_filters_match
    [:native, :ruby].each do |implementation|
      methods = {}
      filters = {c_call: methods}
      seen = []
      trace = build(implementation, [:c_call], filters) { |event| seen << event.method_id }
      filters[:c_call] = {length: true}
      trace.enable do
        "first".bytesize
        methods[:bytesize] = true
        "second".bytesize
      end
      assert_equal [:bytesize], seen
    end
  end

  def test_gc_compaction_keeps_callback_and_filter_references_alive
    [:native, :ruby].each do |implementation|
      seen = []
      trace = build(implementation, [:call], call: {value: true}) { |event| seen << event.method_id }
      trace.enable do
        Probe.new.value
        GC.verify_compaction_references
        Probe.new.value
      end
      assert_equal [:value, :value], seen
    end
  end

  def test_callback_exception_and_disabling_during_dispatch_match
    [:native, :ruby].each do |implementation|
      trace = build(implementation, [:call], call: {value: true}) { raise "callback failure" }
      error = assert_raises(RuntimeError) { trace.enable { Probe.new.value } }
      assert_equal "callback failure", error.message
      refute trace.enabled?

      seen = []
      trace = build(implementation, [:call], call: {value: true}) do |event|
        seen << event.method_id
        trace.disable
        Probe.new.value
      end
      trace.enable do
        Probe.new.value
        Probe.new.value
      end
      assert_equal [:value], seen
    end
  end

  def test_script_compilation_without_a_method_filter_is_preserved
    [:native, :ruby].each do |implementation|
      paths = []
      trace = build(implementation, [:script_compiled], {}) { |event| paths << event.instruction_sequence.path }
      trace.enable { eval("1 + 2", binding, __FILE__, __LINE__) }
      assert_equal [__FILE__], paths
    end
  end

  def test_ractor_owned_callbacks_do_not_cross_ractor_boundaries
    # Entering multi-Ractor mode changes ObjectSpace visibility permanently.
    # Keep that VM-wide transition out of the observer discovery tests.
    script = <<~RUBY
      require "minitest/testmon"
      [:native, :ruby].each do |implementation|
        seen = []
        callback = proc { seen << Ractor.current.object_id }
        trace = if implementation == :native
          Minitest::Testmon::NativeTracePoint.build([:c_call], c_call: {bytesize: true}, &callback)
        else
          TracePoint.new(:c_call) { |event| callback.call(event) if event.method_id == :bytesize }
        end
        trace.enable do
          child = Ractor.new do
            events = []
            local_trace = Minitest::Testmon::NativeTracePoint.build([:c_call], c_call: {bytesize: true}) { events << true }
            local_trace.enable { "inside".bytesize }
            events
          end
          abort "missing child callback" unless child.value == [true]
          child.join
        end
        abort "cross-Ractor callback" unless seen.all? { |owner| owner == Ractor.current.object_id }
      end
    RUBY
    output = IO.popen([RbConfig.ruby, "-I#{File.expand_path("../lib", __dir__)}", "-e", script], err: [:child, :out], &:read)
    assert_predicate $?, :success?, output
  end

  def test_threads_and_repeated_enable_disable_match
    results = [:native, :ruby].map do |implementation|
      seen = []
      trace = build(implementation, [:call], call: {value: true}) { seen << Thread.current[:probe] }
      2.times do
        trace.enable
        Thread.new do
          Thread.current[:probe] = :child
          Probe.new.value
        end.join
        trace.disable
        Probe.new.value
      end
      seen
    ensure
      trace&.disable
    end
    assert_equal [[:child, :child], [:child, :child]], results
  end

  def test_fork_inherits_enabled_filter_and_callback
    skip "fork is unavailable" unless Process.respond_to?(:fork)

    results = [:native, :ruby].map do |implementation|
      reader, writer = IO.pipe
      seen = []
      trace = build(implementation, [:call], call: {value: true}) { seen << :value }
      trace.enable
      pid = fork do
        reader.close
        Probe.new.value
        trace.disable
        writer.write(Marshal.dump(seen))
        writer.close
        exit! 0
      end
      trace.disable
      writer.close
      captured = Marshal.load(reader.read)
      Process.wait(pid)
      assert_predicate $?, :success?
      captured
    ensure
      trace&.disable
      reader&.close unless reader&.closed?
      writer&.close unless writer&.closed?
    end
    assert_equal [[:value], [:value]], results
  end

  private

  def capture(implementation)
    seen = []
    events = [:call, :return, :c_call]
    filters = {call: {value: true}, return: {value: true}, c_call: {bytesize: true}}
    trace = build(implementation, events, filters) { |event| seen << [event.event, event.method_id] }
    trace.enable { yield }
    seen
  end

  def build(implementation, events, filters, &callback)
    if implementation == :native
      Minitest::Testmon::NativeTracePoint.build(events, filters, &callback)
    else
      Minitest::Testmon::TracePointFactory.build_ruby(events, filters, &callback)
    end
  end
end

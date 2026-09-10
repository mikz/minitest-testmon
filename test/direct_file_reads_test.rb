# frozen_string_literal: true

require_relative "test_helper"

class DirectFileReadsTest < TestmonTestCase
  Session = Struct.new(:observations, :diagnostics) do
    def record(observation) = observations << observation
    def incomplete(reason) = diagnostics << reason
  end

  def test_methods_preserve_arguments_results_and_exact_paths
    with_reader do |reader, session, path|
      assert_equal "ab", reader.call(:read, path, 2, 0)
      assert_equal "cd", reader.call(:binread, Pathname.new(path), 2, 2)
      assert_equal ["abcd", "efgh"], reader.call(:readlines, path, chomp: true)
      lines = []
      assert_nil reader.call(:foreach, path, chomp: true) { |line| lines << line }
      assert_equal ["abcd", "efgh"], lines
      observations = session.observations.select { |item| item.kind == :file_read }
      assert_equal %i[read binread readlines foreach], observations.map(&:operation)
      assert observations.all? { |item| item.path == File.realpath(path) && !item.unresolved? }
      assert_empty session.diagnostics
    end
  end

  def test_lazy_foreach_converts_once_on_consumption_and_observes_nested_reads
    with_reader do |reader, session, path|
      conversions = 0
      argument = Object.new
      argument.define_singleton_method(:to_path) {
        conversions += 1
        path
      }
      enumerator = reader.call(:foreach, argument)
      assert_equal 0, conversions
      assert_empty session.observations.select { |item| item.kind == :file_read }
      # Consume from a project callsite, just as native IO attributes the read
      # to enumeration rather than construction.
      reader.call(:consume, enumerator) { reader.call(:read, path) }
      assert_equal 1, conversions
      assert_equal %i[foreach read read], session.observations.select { |item| item.kind == :file_read }.map(&:operation)
    end
  end

  def test_reads_inside_path_conversion_are_observed
    with_reader do |reader, session, path|
      argument = Object.new
      argument.define_singleton_method(:to_path) {
        reader.call(:read, path)
        path
      }
      assert_equal "abcd\nefgh\n", reader.call(:read, argument)
      reads = session.observations.select { |item| item.kind == :file_read }
      assert_equal 2, reads.length
      assert reads.all? { |item| item.path == File.realpath(path) }
    end
  end

  def test_path_conversion_and_native_exceptions_are_preserved
    with_reader do |reader, session, path|
      conversions = 0
      argument = Object.new
      argument.define_singleton_method(:to_path) {
        conversions += 1
        path
      }
      assert_equal "abcd\nefgh\n", reader.call(:read, argument)
      assert_equal 1, conversions
      assert_raises(Errno::ENOENT) { reader.call(:read, "#{path}.missing") }
      assert_raises(ArgumentError) { reader.call(:read, path, -1) }
      assert_raises(TypeError) { reader.call(:read, nil) }
      assert_equal "abcd\nefgh\n", reader.call(:read, path)
      refute Thread.current.thread_variable_get(Minitest::Testmon::DirectFileReads::GUARD)
      assert session.observations.any? { |item| item.reason == :nonexistent }
    end
  end

  def test_saved_native_method_remains_conservatively_unresolved
    with_reader do |reader, session, path|
      native = File.method(:read).super_method
      assert_equal "abcd\nefgh\n", reader.call(:native, native, path)
      assert session.observations.any? { |item| item.reason == :opaque_c_call }
    end
  end

  private

  def with_reader
    with_project do |project|
      path = write_file(File.join(project, "data.txt"), "abcd\nefgh\n")
      source = write_file(File.join(project, "reader.rb"), <<~RUBY)
        proc do |operation, *args, **options, &block|
          if operation == :consume
            args.first.each(&block)
          elsif operation == :native
            args.first.call(args.last)
          else
            File.public_send(operation, *args, **options, &block)
          end
        end
      RUBY
      reader = RubyVM::InstructionSequence.compile_file(source).eval
      session = Session.new([], [])
      observer = Minitest::Testmon::CoreObserver.new(session,
        resolver: Minitest::Testmon::PathResolver.new(project: project)).start
      Minitest::Testmon::ExecutionContext.with_test("ReadTest#test") { yield reader, session, path }
    ensure
      observer&.close
    end
  end
end

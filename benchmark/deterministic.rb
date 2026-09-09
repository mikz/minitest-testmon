# frozen_string_literal: true

require "json"
require "fileutils"
require "open3"
require "timeout"
require "rbconfig"
require "securerandom"
require "sqlite3"

ROOT = File.expand_path("..", __dir__)
RESULTS = File.join(__dir__, "deterministic-results", "#{Time.now.utc.strftime("%Y%m%dT%H%M%S")}-#{SecureRandom.hex(3)}")
PROJECT = File.join(RESULTS, "project")
SEED = 417
TESTS = Integer(ENV.fetch("DETERMINISTIC_TESTS", "24"))
ITERATIONS = Integer(ENV.fetch("DETERMINISTIC_ITERATIONS", "160"))
REPEATS = Integer(ENV.fetch("DETERMINISTIC_REPEATS", "3"))
raise "tests must be between 1 and 120" unless TESTS.between?(1, 120)
raise "iterations and repeats must be positive" unless ITERATIONS.positive? && REPEATS.positive?
FileUtils.mkdir_p([File.join(PROJECT, "lib"), File.join(PROJECT, "test")])

File.write(File.join(PROJECT, "lib/accessor.rb"), "class Payload\n  attr_reader :text\n  def initialize(text); @text = text; end\nend\n")
120.times do |index|
  File.write(File.join(PROJECT, "lib/source_#{index}.rb"), <<~RUBY)
    module Source#{index}
      def self.transform(value)
        value.reverse.upcase.downcase + #{index.to_s.dump}
      end
    end
  RUBY
end
TESTS.times do |index|
  File.write(File.join(PROJECT, "test/work_#{index}_test.rb"), <<~RUBY)
    class Work#{index}Test < Minitest::Test
      def test_payload
        payload = Payload.new("deterministic-#{index}")
        checksum = 0
        #{ITERATIONS}.times do |iteration|
          rows = 24.times.map do |row|
            {"id" => row, "value" => Source#{index}.transform(payload.text), "iteration" => iteration}
          end
          parsed = JSON.parse(JSON.generate(rows))
          checksum += parsed.sum { |row| row.fetch("value").bytesize + row.fetch("id") }
        end
        assert_equal #{ITERATIONS} * (24 * ("deterministic-#{index}".length + #{index.to_s.length}) + 276), checksum
      end
    end
  RUBY
end

def run_child(label, enabled:, cache:)
  metrics = File.join(RESULTS, "#{label}.metrics.json")
  environment = {"MINITEST_TESTMON" => enabled ? "1" : "0", "MINITEST_TESTMON_DB" => cache,
                 "BUNDLE_GEMFILE" => File.join(ROOT, "Gemfile"), "DETERMINISTIC_METRICS" => metrics}
  command = [RbConfig.ruby, "-I#{ROOT}/lib", File.join(__dir__, "deterministic_child.rb"), "--seed", SEED.to_s]
  command << "--testmon" if enabled
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  output = nil
  status = nil
  Open3.popen2e(environment, *command, chdir: PROJECT, pgroup: true) do |input, stream, waiter|
    input.close
    reader = Thread.new { stream.read }
    begin
      Timeout.timeout(30) {
        status = waiter.value
        output = reader.value
      }
    rescue Timeout::Error
      Process.kill("KILL", -waiter.pid)
      waiter.value
      output = reader.value
      raise "#{label} exceeded 30 seconds"
    ensure
      File.write(File.join(RESULTS, "#{label}.log"), output.to_s)
    end
  end
  raise "#{label} failed; see its log" unless status.success?
  result = {label: label, enabled: enabled, wall_s: Process.clock_gettime(Process::CLOCK_MONOTONIC) - started,
            metrics: JSON.parse(File.read(metrics))}
  if enabled
    db = SQLite3::Database.new(cache)
    report = JSON.parse(db.get_first_value("SELECT report_json FROM run_receipts WHERE state='complete' ORDER BY rowid DESC LIMIT 1") || "null")
    raise "#{label} did not publish" unless report&.dig("publication", "published")
    result[:selected] = report.fetch("tests").fetch("selected")
    result[:retained] = db.get_first_value("SELECT count(*) FROM test_snapshots")
    result[:retry] = db.get_first_value("SELECT count(*) FROM retry_tests")
    raise "#{label} left retries" unless result[:retry].zero?
    db.close
  end
  puts JSON.generate(result)
  result
end

results = []
REPEATS.times do |repeat|
  order = repeat.even? ? [false, true] : [true, false]
  order.each do |enabled|
    label = "pair#{repeat}-#{enabled ? "on" : "off"}"
    results << run_child(label, enabled: enabled, cache: File.join(RESULTS, "#{label}.sqlite3"))
    raise "cold run omitted tests" if enabled && results.last[:selected].length != TESTS
  end
end
cache = File.join(RESULTS, "pair0-on.sqlite3")
warm = run_child("warm", enabled: true, cache: cache)
raise "warm did not retain every test" unless warm[:selected].empty? && warm[:retained] == TESTS
results << warm
File.open(File.join(PROJECT, "lib/source_0.rb"), "a") { |file| file.puts "# ordinary source change" }
ordinary = run_child("ordinary-change", enabled: true, cache: cache)
raise "ordinary source selection lost precision" unless ordinary[:selected] == ["Work0Test#test_payload"]
results << ordinary
File.open(File.join(PROJECT, "lib/accessor.rb"), "a") { |file| file.puts "# shared native source change" }
accessor = run_child("accessor-change", enabled: true, cache: cache)
raise "accessor change did not select every test" unless accessor[:selected].length == TESTS
results << accessor
summary = {ruby: RUBY_DESCRIPTION, seed: SEED, tests: TESTS, iterations: ITERATIONS, sources: 121,
           results: results, paired_overhead_percent: REPEATS.times.map do |index|
             on = results.find { |r| r[:label] == "pair#{index}-on" }[:wall_s]
             off = results.find { |r| r[:label] == "pair#{index}-off" }[:wall_s]
             100 * (on / off - 1)
           end}
File.write(File.join(RESULTS, "summary.json"), JSON.pretty_generate(summary))
puts "Preserved results: #{RESULTS}"

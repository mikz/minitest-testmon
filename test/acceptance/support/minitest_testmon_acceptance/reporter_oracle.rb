# frozen_string_literal: true

module MinitestTestmonAcceptance
  class ReporterOracle
    class Mismatch < StandardError; end

    def self.assert_single_execution!(report:, marker_lines:, test_fragment:)
      discovered = report.dig("tests", "discovered")
      matches = discovered.grep(/#{Regexp.escape(test_fragment)}/)
      errors = []
      errors << "expected one discovered test matching #{test_fragment.inspect}, got #{matches.inspect}" unless matches.one?

      if matches.one?
        test_id = matches.first
        errors << "selected test differs from #{test_id}" unless report.dig("tests", "selected") == [test_id]
        errors << "executed test differs from #{test_id}" unless report.dig("tests", "executed") == [test_id]
        errors << "application marker did not contain #{test_id}" unless marker_lines.one? && marker_lines.first.include?(test_id)
      end
      errors << "application test executed #{marker_lines.length} times" unless marker_lines.one?
      return matches.first if errors.empty?

      raise Mismatch, errors.join("; ")
    end

    def self.assert_callbacks_once!(events:, reporters:, records:)
      expected = {
        "start" => 1,
        "record" => records,
        "report" => 1
      }
      errors = reporters.flat_map do |reporter|
        reporter_events = events.select { |event| event.fetch("reporter") == reporter }
        expected.filter_map do |name, count|
          actual = reporter_events.count { |event| event.fetch("event") == name }
          "#{reporter}.#{name}=#{actual}, expected #{count}" unless actual == count
        end
      end
      return true if errors.empty?

      raise Mismatch, "delegated reporter lifecycle was not exactly once: #{errors.join("; ")}"
    end

    def self.assert_worker_evidence!(report:, provider:, path_suffix:, test_id:)
      matches = report.fetch("inventory").values.flat_map { |category| category.fetch("items") }.select do |item|
        item.fetch("provider") == provider &&
          item.fetch("path", "").to_s.end_with?(path_suffix) &&
          item.fetch("test_ids").include?(test_id)
      end
      return true if matches.one?

      raise Mismatch,
        "expected one merged worker claim for #{provider}:*#{path_suffix} and #{test_id}; " \
        "got #{matches.inspect}"
    end

    def self.assert_reporters_before_processes!(events:)
      preloads = events.select { |event| event.fetch("event") == "reporters_before_testmon" }
      loaded = events.select { |event| event.fetch("event") == "testmon_after_reporters" }
      preload_pids = preloads.map { |event| event.fetch("pid") }
      errors = []
      errors << "expected CLI and spawned-test preload PIDs, got #{preload_pids.inspect}" unless preload_pids.uniq.length == 2
      unless preload_pids.length == preload_pids.uniq.length
        errors << "reporters-first preload ran more than once in one process"
      end
      unless preloads.all? { |event| plugin_state?(event, false) }
        errors << "testmon plugin feature or extension was active during a reporters-first preload"
      end
      errors << "expected one test-process Testmon marker, got #{loaded.length}" unless loaded.one?
      if loaded.one?
        child = loaded.first
        errors << "test process did not observe the Testmon plugin feature and extension" unless plugin_state?(child, true)
        errors << "test-process marker has no matching preload PID" unless preload_pids.include?(child.fetch("pid"))
      end
      errors << "unexpected reporters-first boot events" unless events.length == preloads.length + loaded.length
      return true if errors.empty?

      raise Mismatch, errors.join("; ")
    end

    def self.plugin_state?(event, expected)
      event.fetch("testmon_plugin_loaded") == expected &&
        event.fetch("testmon_extension_registered") == expected
    end
    private_class_method :plugin_state?

    def self.assert_followup_finalized_once!(before:, after:, marker_lines:)
      before_generation = before.fetch("generation")
      after_generation = after.fetch("generation")
      errors = []
      errors << "baseline generation is not an Integer" unless before_generation.is_a?(Integer)
      errors << "unchanged warm run changed generation" unless after_generation == before_generation
      errors << "follow-up was not published" unless after.dig("publication", "published") == true
      if after.dig("publication", "reason") == "cache_lease_unavailable"
        errors << "prior run retained the cache lease"
      end
      errors << "follow-up selected tests" unless after.dig("tests", "selected") == []
      errors << "follow-up executed tests" unless after.dig("tests", "executed") == []
      errors << "application test ran again" unless marker_lines.one?
      return true if errors.empty?

      raise Mismatch, errors.join("; ")
    end

    def self.assert_api_unchanged!(clean:, active:)
      return true if clean == active

      differences = api_differences(clean, active).first(10)
      raise Mismatch,
        "Minitest, minitest-reporters, or Rails public owners, signatures, " \
        "source locations, or ancestors changed: #{differences.join("; ")}"
    end

    def self.api_differences(clean, active, path = [])
      if clean.is_a?(Hash) && active.is_a?(Hash)
        (clean.keys | active.keys).sort.flat_map do |key|
          api_differences(clean[key], active[key], [*path, key])
        end
      elsif clean == active
        []
      else
        ["#{path.join(".")}: #{clean.inspect} != #{active.inspect}"]
      end
    end
    private_class_method :api_differences
  end
end

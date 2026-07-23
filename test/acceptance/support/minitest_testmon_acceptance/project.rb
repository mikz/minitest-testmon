# frozen_string_literal: true

module MinitestTestmonAcceptance
  class Project
    ALL_TESTS_LOADER = <<~RUBY.strip.freeze
      test_files = ARGV.dup
      ARGV.clear
      test_files.each { |test_file| require File.expand_path(test_file) }
    RUBY

    attr_reader :path

    def self.copy_fixture(name)
      source = MinitestTestmonAcceptance::FIXTURES.join(name)
      raise ArgumentError, "unknown fixture: #{name}" unless source.directory?

      temporary = Pathname(Dir.mktmpdir("minitest-testmon-#{name}-"))
      FileUtils.cp_r("#{source}/.", temporary)
      new(temporary)
    end

    def initialize(path)
      @path = Pathname(path)
    end

    def test_command
      rails = path.join("bin/rails")
      return [rails.to_s, "test"] if rails.file?

      test_files = Dir[path.join("test/**/*_test.rb")].sort.map do |file|
        Pathname(file).relative_path_from(path).to_s
      end
      [RbConfig.ruby, "-Itest", "-e", ALL_TESTS_LOADER, "--", *test_files]
    end

    def read(relative_path)
      path.join(relative_path).read
    end

    def write(relative_path, contents)
      destination = path.join(relative_path)
      FileUtils.mkdir_p(destination.dirname)
      destination.write(contents)
    end

    def remove(relative_path)
      FileUtils.rm_f(path.join(relative_path))
    end

    def cleanup
      FileUtils.remove_entry(path) if path.exist?
    end
  end
end

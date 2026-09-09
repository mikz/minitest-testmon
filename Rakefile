# frozen_string_literal: true

require "bundler/gem_tasks"
require "minitest/test_task"
require "standard/rake"
require "rubygems/package"
require "rbconfig"
require "tmpdir"

Minitest::TestTask.create do |task|
  task.test_globs = ["test/*_test.rb"]
  task.warning = true
end

Minitest::TestTask.create("test:acceptance") do |task|
  task.libs = ["test/acceptance/support", "."]
  task.test_globs = ["test/acceptance/*_test.rb"]
  task.warning = true
end

Minitest::TestTask.create("test:acceptance:self") do |task|
  task.libs = ["test/acceptance/support", "."]
  task.test_globs = ["test/acceptance/*self_test.rb"]
  task.warning = true
end

desc "Build the native TracePoint event filter"
task :compile do
  Dir.chdir(File.join(__dir__, "ext", "minitest_testmon_native")) do
    sh RbConfig.ruby, "extconf.rb"
    sh RbConfig::CONFIG["MAKE"] || "make"
  end
end

task test: :compile
task "test:acceptance" => :compile

desc "Require the built gem using only its unpacked lib directory"
task package_smoke: :build do
  gem_path = Dir[File.join(__dir__, "pkg", "minitest-testmon-*.gem")].max_by { |path| File.mtime(path) }
  raise "built gem not found" unless gem_path

  Dir.mktmpdir("minitest-testmon-package") do |directory|
    Gem::Package.new(gem_path).extract_files(directory)
    success = Bundler.with_unbundled_env do
      system(
        RbConfig.ruby,
        "-I#{File.join(directory, "lib")}",
        "-e",
        'require "minitest/testmon"'
      )
    end
    raise "unpacked gem could not require minitest/testmon" unless success
  end
end

desc "Install the built gem and verify its native extension loads"
task package_native_smoke: :build do
  gem_path = Dir[File.join(__dir__, "pkg", "minitest-testmon-*.gem")].max_by { |path| File.mtime(path) }
  raise "built gem not found" unless gem_path

  dependency_paths = (Gem.path + Gem.loaded_specs.values.map(&:base_dir)).uniq
  Dir.mktmpdir("minitest-testmon-native-package") do |directory|
    environment = {
      "GEM_HOME" => directory,
      "GEM_PATH" => ([directory] + dependency_paths).join(File::PATH_SEPARATOR),
      "RUBYLIB" => nil
    }
    Bundler.with_unbundled_env do
      installed = system(environment, RbConfig.ruby, "-S", "gem", "install", gem_path,
        "--local", "--ignore-dependencies", "--no-document", "--install-dir", directory,
        chdir: directory)
      raise "built gem could not be installed" unless installed

      loaded = system(environment, RbConfig.ruby, "-e", <<~RUBY, chdir: directory)
        require "minitest/testmon"
        specification = Gem.loaded_specs.fetch("minitest-testmon")
        abort "loaded gem outside isolated installation" unless File.realpath(specification.base_dir) == File.realpath(ENV.fetch("GEM_HOME"))
        abort "native TracePoint extension unavailable" unless defined?(Minitest::Testmon::NativeTracePoint)
      RUBY
      raise "installed gem could not load its native extension" unless loaded
    end
  end
end

desc "Run every validation gate"
task ci: %i[test standard build package_smoke package_native_smoke test:acceptance]

task default: %i[test standard]

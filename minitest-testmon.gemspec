# frozen_string_literal: true

require_relative "lib/minitest/testmon/version"

Gem::Specification.new do |spec|
  spec.name = "minitest-testmon"
  spec.version = Minitest::Testmon::VERSION
  spec.authors = ["Michal Cichra"]
  spec.email = ["mikz@users.noreply.github.com"]

  spec.summary = "Conservative test selection for Minitest on current MRI"
  spec.description = "Records per-test runtime dependencies and selects only affected Minitest tests, with built-in Rails support."
  spec.homepage = "https://github.com/mikz/minitest-testmon"
  spec.license = "MIT"
  spec.required_ruby_version = Gem::Requirement.new(">= 4.0", "< 4.1")

  spec.metadata["allowed_push_host"] = "https://rubygems.org"
  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "#{spec.homepage}/tree/main"
  spec.metadata["documentation_uri"] = "#{spec.homepage}/tree/main/docs"
  spec.metadata["bug_tracker_uri"] = "#{spec.homepage}/issues"
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = IO.popen(
    %w[git ls-files --cached --others --exclude-standard -z],
    chdir: __dir__,
    err: IO::NULL
  ) do |files|
    files.readlines("\x0", chomp: true).select do |file|
      File.file?(File.join(__dir__, file)) &&
        file.match?(%r{\A(?:CHANGELOG\.md|LICENSE\.txt|README\.md|docs/|exe/|lib/|ext/)})
    end
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |file| File.basename(file) }
  spec.require_paths = ["lib"]
  spec.extensions = ["ext/minitest_testmon_native/extconf.rb"]

  spec.add_dependency "minitest", ">= 6.0", "< 7"
  spec.add_dependency "sqlite3", ">= 2.0", "< 3"
end

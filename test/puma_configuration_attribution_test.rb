# frozen_string_literal: true

require_relative "test_helper"
require "puma"
require "puma/configuration"
require "minitest/testmon/puma_configuration_attribution"

class PumaConfigurationAttributionTest < TestmonTestCase
  Context = Minitest::Testmon::ExecutionContext

  def setup
    Minitest::Testmon::ThreadContextPropagation.install!
    Context.reset_boundaries!
    Context.clear
  end

  def teardown
    Context.reset_boundaries!
    Context.clear
  end

  def test_configuration_and_mode_hooks_borrow_only_until_configuration_finishes
    with_project do |project|
      path = write_file(File.join(project, "config/puma.rb"), <<~RUBY)
        threads 0, 4
        Thread.current[:observed] << Minitest::Testmon::ExecutionContext.current_test
        single { Thread.current[:observed] << Minitest::Testmon::ExecutionContext.current_test }
      RUBY
      configuration = attributed_configuration(path)
      observed = Queue.new
      release = Queue.new
      begin_boundary(project)
      server = Thread.new do
        Thread.current[:observed] = observed
        configuration.clamp
        observed << Context.current_test
        release.pop
      end

      assert_equal "BrowserTest#test_boot", observed.pop
      assert_equal "BrowserTest#test_boot", observed.pop
      assert_nil observed.pop
      assert_empty Context.clear
      assert server.alive?
      assert_equal 4, configuration.options[:max_threads]
    ensure
      release << true if server&.alive?
      server&.value
    end
  end

  def test_in_flight_configuration_is_a_leak_and_loses_attribution_after_revocation
    with_project do |project|
      path = write_file(File.join(project, "config/puma.rb"), <<~RUBY)
        Thread.current[:entered] << Minitest::Testmon::ExecutionContext.current_test
        Thread.current[:release].pop
        Thread.current[:entered] << Minitest::Testmon::ExecutionContext.current_test
      RUBY
      configuration = attributed_configuration(path)
      entered = Queue.new
      release = Queue.new
      begin_boundary(project)
      server = Thread.new do
        Thread.current[:entered] = entered
        Thread.current[:release] = release
        configuration.load
      end

      assert_equal "BrowserTest#test_boot", entered.pop
      assert_equal [server], Context.clear
      release << true
      server.value
      assert_nil entered.pop
    ensure
      release << true if server&.alive?
      server&.join
    end
  end

  def test_project_child_started_by_configuration_remains_leak_checked
    with_project do |project|
      path = write_file(File.join(project, "config/puma.rb"), <<~RUBY)
        ready, release = Thread.current[:signals]
        Thread.current[:child] = Thread.new do
          ready << [Minitest::Testmon::ExecutionContext.current_test, Minitest::Testmon::ExecutionContext.evidence_scope]
          release.pop
          Minitest::Testmon::ExecutionContext.current_test
        end
      RUBY
      configuration = attributed_configuration(path)
      ready = Queue.new
      release = Queue.new
      begin_boundary(project)
      child = Thread.new do
        Thread.current[:signals] = [ready, release]
        configuration.load
        Thread.current[:child]
      end.value

      assert_equal ["BrowserTest#test_boot", :suite], ready.pop
      assert_equal [child], Context.clear
      release << true
      assert_nil child.value
    ensure
      release << true if child&.alive?
      child&.join
    end
  end

  def test_configuration_outside_a_boundary_stays_unattributed
    with_project do |project|
      path = write_file(File.join(project, "puma.rb"), "Thread.current[:observed] = Minitest::Testmon::ExecutionContext.current_test")
      configuration = attributed_configuration(path)
      observed = Thread.new do
        configuration.load
        Thread.current[:observed]
      end.value

      assert_nil observed
      assert_empty Context.clear
    end
  end

  private

  def begin_boundary(project)
    configuration = Minitest::Testmon::Configuration.new(cwd: project)
    Minitest::Testmon::Bundles::Rails81.prepare_configuration(configuration)
    configuration.provider :"rails.boot", Minitest::Testmon::Bundles::Rails81::BootDefinition.new, version: 1
    configuration.provider :ruby, Minitest::Testmon::CoreProvider.new(configuration), version: 1
    snapshot = Minitest::Testmon::ProviderRegistry.new.snapshot(configuration)
    sources = snapshot.ruby_inventory_paths.to_h { |path| [path, true] }.freeze
    Context.set("BrowserTest#test_boot", thread_sources: sources)
    Context.begin_boundary
  end

  def attributed_configuration(path)
    Puma::Configuration.new({config_files: [path]}).tap do |configuration|
      configuration.singleton_class.prepend(Minitest::Testmon::PumaConfigurationAttribution)
    end
  end
end

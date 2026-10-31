require_relative 'test_helper'
require_relative 'support/diagnostic_coverage'
require 'open3'
require 'rbconfig'

class DiagnosticCoverageTest < GraphTest
  def with_catalog(source)
    Dir.mktmpdir('vetra-diagnostics-') do |root|
      write(root, 'lib/rules.rb', source)
      yield VetraTest::DiagnosticCoverage.new(root: root)
    end
  end

  def test_catalog_uses_ruby_calls_and_ignores_comments_strings_and_forwarders
    with_catalog(<<~RUBY) do |coverage|
      # issue('comment_only', 'not a call')
      text = "Error.single('string_only', 'not a call')"
      issue('rule_a', 'first')
      fail!('rule_b', 'second')
      error('rule_c', 'third')
      ::Vetra::Graph::Error.single('rule_d', 'fourth')
      Graph::Diagnostic.new(code: 'rule_e', message: 'fifth')
      issue('rule_a', 'another emission site')
      Diagnostic.new(code: code, message: message)
      Error.single(code, message)
      object.error('not_a_helper', 'not a Vetra diagnostic')
    RUBY
      assert_equal %w[rule_a rule_b rule_c rule_d rule_e], coverage.sites.keys.sort
      assert_equal ['lib/rules.rb:3', 'lib/rules.rb:8'], coverage.sites['rule_a']
    end
  end

  def test_a_diagnostic_mentioned_in_source_but_never_emitted_fails_the_report
    with_catalog("issue('untested', 'message')\n") do |coverage|
      out, err = StringIO.new, StringIO.new
      refute coverage.report(out: out, err: err)
      assert_includes out.string, '0/1'
      assert_includes err.string, 'Sem teste que emita untested'
      assert_includes err.string, 'lib/rules.rb:1'
    end
  end

  def test_repeated_emissions_count_once_and_complete_coverage_passes
    with_catalog("issue('a', 'message')\nerror('b', 'message')\n") do |coverage|
      %w[a a b].each { |code| coverage.record(code) }
      out, err = StringIO.new, StringIO.new
      assert coverage.report(out: out, err: err)
      assert_includes out.string, '2/2'
      assert_empty err.string
    end
  end

  def test_emitting_an_unrecognized_dynamic_code_also_fails
    with_catalog("issue('known', 'message')\n") do |coverage|
      coverage.record('known')
      coverage.record('dynamic_code')
      err = StringIO.new
      refute coverage.report(out: StringIO.new, err: err)
      assert_equal ['dynamic_code'], coverage.unknown
      assert_includes err.string, 'sem declaração literal reconhecida: dynamic_code'
    end
  end

  def test_invalid_ruby_and_empty_catalogs_cannot_report_success
    Dir.mktmpdir('vetra-diagnostics-') do |root|
      write(root, 'lib/rules.rb', 'def broken(')
      error = assert_raises(ArgumentError) { VetraTest::DiagnosticCoverage.new(root: root) }
      assert_includes error.message, 'Ruby inválido'
      write(root, 'lib/rules.rb', '# no diagnostic declarations')
      error = assert_raises(ArgumentError) { VetraTest::DiagnosticCoverage.new(root: root) }
      assert_includes error.message, 'Nenhum código de diagnóstico'
    end
  end

  def test_runner_returns_failure_when_tests_pass_but_diagnostics_are_not_exercised
    script = <<~RUBY
      require 'minitest/autorun'
      class PassingTest < Minitest::Test
        def test_passes
          diagnostic = Vetra::Graph::Diagnostic.new(code: 'schema', message: 'example')
          assert_equal 'schema', diagnostic.code
        end
      end
    RUBY
    runner = File.join(PROJECT, 'test/support/diagnostic_coverage_runner.rb')
    out, err, status = Open3.capture3(RbConfig.ruby, '-I', File.join(PROJECT, 'lib'), '-r', runner, '-e', script, chdir: PROJECT)
    assert_equal 1, status.exitstatus
    assert_includes out, '1 runs, 1 assertions, 0 failures, 0 errors'
    assert_includes err, '[diagnostics_coverage] Sem teste que emita'
  end
end

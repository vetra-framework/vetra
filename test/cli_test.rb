require_relative 'test_helper'
require 'open3'
require 'rbconfig'

class CLITest < GraphTest
  def test_build_check_validate_help_and_usage_status
    with_app do |root, _compiler|
      %w[graph:build graph:check graph:validate].each do |command|
        out, err = StringIO.new, StringIO.new
        code = Vetra::CLI.run([command, '--root', root], out: out, err: err)
        assert_equal 0, code, err.string
        assert_includes out.string, 'OK'
        assert_empty err.string
      end
      assert_equal 0, Vetra::CLI.run(['graph:validate', '--sources', '--root', root], out: StringIO.new, err: StringIO.new)
      assert_equal 0, Vetra::CLI.run(['--help'], out: StringIO.new)
      assert_equal 2, Vetra::CLI.run(['unknown'], out: StringIO.new, err: StringIO.new)
      assert_equal 2, Vetra::CLI.run(['graph:check', '--sources'], out: StringIO.new, err: StringIO.new)
    end
  end

  def test_executable_reports_stale_graph_without_stack_trace
    with_app do |root, _compiler|
      out, err, status = Open3.capture3(RbConfig.ruby, File.join(PROJECT, 'bin/vetra'), 'graph:check', '--root', root)
      assert_equal 1, status.exitstatus
      assert_empty out
      assert_includes err, '[graph_stale]'
      refute_includes err, 'backtrace'
      refute_includes err, 'bundler: failed'
    end
  end

  def test_executable_help_works_outside_a_bundler_project
    Dir.mktmpdir('vetra-cli-') do |directory|
      environment = { 'RUBYOPT' => nil, 'BUNDLE_GEMFILE' => nil, 'BUNDLE_BIN_PATH' => nil }
      out, err, status = Open3.capture3(environment, RbConfig.ruby, File.join(PROJECT, 'bin/vetra'), '--help', chdir: directory)
      assert_equal 0, status.exitstatus, err
      assert_includes out, 'graph:build'
    end
  end
end

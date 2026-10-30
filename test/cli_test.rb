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

  def test_diff_json_output_is_parseable_and_breaking_exit_code_is_opt_in
    with_app do |root, compiler|
      result = compiler.write
      before_path = File.join(root, 'before.json')
      after_path = File.join(root, 'after.json')
      File.write(before_path, result.bytes)
      after = Vetra::Graph::Data.copy(result.document)
      after['nodes'].reject! { |entry| (entry['kind'] == 'query' && entry['id'] == 'blog.find_post') || entry['generated_from'] == { 'kind' => 'query', 'id' => 'blog.find_post' } }
      after['digest'] = Vetra::Graph::Canonical.digest(after)
      File.write(after_path, Vetra::Graph::Canonical.dump(after))
      out, err = StringIO.new, StringIO.new
      arguments = ['graph:diff', before_path, after_path, '--format', 'json']
      assert_equal 0, Vetra::CLI.run(arguments, out: out, err: err), err.string
      report = JSON.parse(out.string)
      assert_equal '1', report['format_version']
      assert_equal 2, report.dig('summary', 'breaking')
      assert_empty err.string
      assert_equal 3, Vetra::CLI.run([*arguments, '--fail-on-breaking'], out: StringIO.new, err: StringIO.new)
      assert_equal 0, Vetra::CLI.run(['graph:diff', before_path, before_path, '--fail-on-breaking'], out: StringIO.new, err: StringIO.new)
      assert_equal 2, Vetra::CLI.run(['graph:diff', before_path], out: StringIO.new, err: StringIO.new)
      assert_equal 2, Vetra::CLI.run([*arguments, '--sources'], out: StringIO.new, err: StringIO.new)
      assert_equal 2, Vetra::CLI.run(['graph:validate', '--format', 'json'], out: StringIO.new, err: StringIO.new)
      assert_equal 2, Vetra::CLI.run(['graph:diff', before_path, before_path, '--format', 'xml'], out: StringIO.new, err: StringIO.new)
    end
  end

  def test_diff_rejects_bad_json_without_partial_stdout
    with_app do |root, compiler|
      compiler.write
      path = File.join(root, 'bad.json')
      File.write(path, '{invalid')
      out, err = StringIO.new, StringIO.new
      assert_equal 1, Vetra::CLI.run(['graph:diff', compiler.artifact.to_s, path, '--format', 'json'], out: out, err: err)
      assert_empty out.string
      assert_includes err.string, '[invalid_json]'
    end
  end

  def test_diff_warnings_keep_source_and_stay_out_of_json_stdout
    fixture = File.join(PROJECT, 'docs/ir/exemplos/mini-crm.v0.1.json')
    out, err = StringIO.new, StringIO.new
    assert_equal 0, Vetra::CLI.run(['graph:diff', fixture, fixture, '--format', 'json'], out: out, err: err)
    report = JSON.parse(out.string)
    assert_equal 0, report.dig('summary', 'total')
    assert_equal %w[before after], report['warnings'].map { |warning| warning['side'] }
    assert_includes err.string, '[anterior]'
    assert_includes err.string, 'app/domains/crm/company.rb:1'
    assert_includes err.string, '/nodes/'
  end
end

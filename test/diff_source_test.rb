require_relative 'test_helper'
require 'open3'

class DiffSourceTest < GraphTest
  def git!(root, *arguments)
    environment = { 'GIT_CONFIG_NOSYSTEM' => '1', 'GIT_CONFIG_GLOBAL' => File::NULL }
    output, error, status = Open3.capture3(
      environment, 'git', '-C', root,
      '-c', 'user.name=Vetra Tests', '-c', 'user.email=vetra-tests@example.invalid',
      '-c', 'commit.gpgsign=false', '-c', 'tag.gpgsign=false', '-c', "core.hooksPath=#{File::NULL}",
      *arguments
    )
    raise "Git fixture: #{error}" unless status.success?
    output
  end

  def with_repository
    Dir.mktmpdir('vetra-git-') do |directory|
      git!(directory, 'init', '--quiet')
      app = File.join(directory, 'apps', 'blog space')
      FileUtils.mkdir_p(app)
      FileUtils.cp_r("#{PROJECT}/examples/blog/.", app)
      git!(directory, 'add', '--all')
      git!(directory, 'commit', '--quiet', '-m', 'Baseline graph')
      git!(directory, 'tag', '--annotate', 'baseline', '--message', 'Baseline')
      yield directory, app
    end
  end

  def test_file_input_uses_json_only_and_preserves_special_characters
    with_app do |root, compiler|
      result = compiler.write
      path = File.join(root, 'graph; $(touch escaped).json')
      File.write(path, result.bytes)
      assert_equal result.document, Vetra::Graph::DiffSource.new(root: root).read(path)
      refute File.exist?(File.join(root, 'escaped'))
      File.write(path, '{"x":1,"x":2}')
      assert_graph_error('invalid_json') { Vetra::Graph::DiffSource.new(root: root).read(path) }
      assert_graph_error('graph_missing') { Vetra::Graph::DiffSource.new(root: root).read("#{path}.missing") }
    end
  end

  def test_reads_commit_and_tag_at_application_path_without_executing_or_touching_worktree
    with_repository do |repository, app|
      source = Vetra::Graph::DiffSource.new(root: app)
      before = source.read('git:baseline')
      after = Vetra::Graph::Data.copy(before)
      node(after, 'policy')['actions'].delete('delete')
      after['digest'] = Vetra::Graph::Canonical.digest(after)
      File.write(File.join(app, '.vetra/graph.json'), Vetra::Graph::Canonical.dump(after) + "\n")
      git!(repository, 'add', '--all')
      git!(repository, 'commit', '--quiet', '-m', 'Restrict declared policy')
      write(app, 'config/app.rb', '::Kernel.raise "must not load DSL"')
      worktree_status = git!(repository, 'status', '--porcelain')
      assert_equal before, source.read('git:HEAD^')
      assert_equal after, source.read('git:HEAD')
      report = Vetra::Graph::Diff.new.compare(source.read('git:HEAD^'), source.read('git:HEAD'))
      assert_equal 1, report.data.dig('summary', 'requires_review')
      assert_equal 'indeterminate', report.data['changes'].first['permission_impact']
      assert_equal worktree_status, git!(repository, 'status', '--porcelain')
      out, err = StringIO.new, StringIO.new
      assert_equal 0, Vetra::CLI.run(['graph:diff', 'git:HEAD^', 'git:HEAD', '--root', app, '--format', 'json'], out: out, err: err), err.string
      assert_equal report.data, JSON.parse(out.string)
    end
  end

  def test_invalid_git_revision_cannot_be_treated_as_shell_code_or_an_option
    with_repository do |_repository, app|
      source = Vetra::Graph::DiffSource.new(root: app)
      ['git:', 'git:--help', "git:HEAD; touch #{app}/escaped", 'git:no_such_revision'].each do |input|
        assert_graph_error('git_reference') { source.read(input) }
      end
      refute File.exist?(File.join(app, 'escaped'))
    end
  end

  def test_wrong_root_does_not_fall_back_to_another_graph
    with_repository do |repository, _app|
      assert_graph_error('git_graph_missing') { Vetra::Graph::DiffSource.new(root: repository).read('git:HEAD') }
    end
    Dir.mktmpdir('vetra-no-git-') do |root|
      assert_graph_error('git_repository') { Vetra::Graph::DiffSource.new(root: root).read('git:HEAD') }
    end
  end
end

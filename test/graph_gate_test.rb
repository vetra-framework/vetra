require_relative 'test_helper'
require 'open3'
require_relative '../script/check_graph_compatibility'

class GraphGateTest < GraphTest
  def git(root, *arguments)
    output, error, status = Open3.capture3('git', '-C', root, *arguments)
    raise error unless status.success?
    output.strip
  end

  def with_repository
    Dir.mktmpdir('vetra-gate-') do |root|
      FileUtils.mkdir_p(File.join(root, 'examples'))
      FileUtils.cp_r(File.join(PROJECT, 'examples/blog'), File.join(root, 'examples/blog'))
      compiler = Vetra::Graph::Compiler.new(root: File.join(root, 'examples/blog'))
      compiler.write
      git(root, 'init', '--initial-branch=main')
      git(root, 'config', 'user.name', 'Teste')
      git(root, 'config', 'user.email', 'test@example.invalid')
      git(root, 'add', '.')
      git(root, 'commit', '-qm', 'Base')
      yield root, compiler, git(root, 'rev-parse', 'HEAD')
    end
  end

  def run_gate(root, base, **options)
    output = StringIO.new
    status = VetraCI::GraphGate.new(root: root, out: output, **options).run(base: base)
    [status, output.string]
  end

  def remove_route(compiler)
    edit(compiler.root, 'app/domains/blog/publish_post.rb') { |text| text.lines.reject { |line| line.include?('expose http:') }.join }
    compiler.write.document
  end

  def declare_break(root, before, after)
    write(root, '.github/graph-compatibility.json', JSON.pretty_generate({
      'format_version' => '1',
      'changes' => [{ 'artifact' => 'examples/blog/.vetra/graph.json', 'before_digest' => before,
                      'after_digest' => after, 'reason' => 'Retirada intencional de endpoint.' }]
    }))
  end

  def test_unchanged_graphs_and_metadata_changes_pass
    with_repository do |root, compiler, base|
      assert_equal 0, run_gate(root, base).first
      edit(compiler.root, 'app/domains/blog/domain.rb') { |text| "#{text}\n# comentário\n" }
      compiler.write
      status, output = run_gate(root, base)
      assert_equal 0, status
      assert_includes output, 'Metadados'
    end
  end

  def test_breaks_fail_until_the_exact_graph_pair_is_declared
    with_repository do |root, compiler, base|
      before = compiler.build.document['digest']
      after = remove_route(compiler)['digest']
      status, output = run_gate(root, base)
      assert_equal 1, status
      assert_includes output, 'Quebra sem declaração'
      declare_break(root, before, after)
      status, output = run_gate(root, base)
      assert_equal 0, status
      assert_includes output, 'Quebra intencional declarada'
      assert_includes output, 'Retirada intencional'
    end
  end

  def test_declarations_do_not_cover_additional_changes_or_a_different_base
    with_repository do |root, compiler, base|
      before = compiler.build.document['digest']
      after = remove_route(compiler)['digest']
      declare_break(root, 'sha256:' + '0' * 64, after)
      assert_equal 1, run_gate(root, base).first
      declare_break(root, before, after)
      edit(compiler.root, 'app/domains/blog/find_post.rb') { |text| "#{text}\n# outra mudança\n" }
      compiler.write
      assert_equal 1, run_gate(root, base).first
    end
  end

  # A âncora da história (ADR-038, §3): a base integrada prende os planos e modelos, mesmo que a cadeia seja
  # recalculada na árvore da entrega.
  def test_published_plans_and_models_cannot_change_and_new_plans_come_after_them
    with_repository do |root, compiler, base|
      plans = File.join(compiler.root, 'db/plans')
      assert File.file?(File.join(plans, '0001_inicial.sql'))
      write(root, 'examples/blog/db/plans/0002_mais.sql', "-- novo\n")
      write(root, 'examples/blog/db/models/0002_mais.json', "{}\n")
      assert_equal 0, run_gate(root, base).first
      edit(compiler.root, 'db/plans/0001_inicial.sql') { |text| text.sub(/;\n\z/, ";\nCOMMENT ON SCHEMA public IS 'x';\n") }
      edit(compiler.root, 'db/models/0001_inicial.json') { |text| text.sub('"version"', '"version" ') }
      status, output = run_gate(root, base)
      assert_equal 1, status
      assert_includes output, 'examples/blog/db/plans/0001_inicial.sql mudou ou foi removido'
      assert_includes output, 'examples/blog/db/models/0001_inicial.json mudou ou foi removido'
      git(root, 'checkout', '--', 'examples/blog/db')
      FileUtils.rm(File.join(compiler.root, 'db/models/0001_inicial.json'))
      assert_includes run_gate(root, base).last, 'db/models/0001_inicial.json mudou ou foi removido'
      git(root, 'checkout', '--', 'examples/blog/db')
      write(root, 'examples/blog/db/plans/0000_antes.sql', "-- antes\n")
      status, output = run_gate(root, base)
      assert_equal 1, status
      assert_includes output, '0000_antes.sql é novo, mas não vem depois'
    end
  end

  # Só o último plano é regenerado pela IR: dois planos novos na mesma integração deixariam o do meio sem conferência.
  def test_one_new_plan_per_application_per_integration
    with_repository do |root, compiler, base|
      %w[0002_a 0003_b].each do |name|
        write(root, "examples/blog/db/plans/#{name}.sql", "-- #{name}\n")
        write(root, "examples/blog/db/models/#{name}.json", "{}\n")
      end
      status, output = run_gate(root, base)
      assert_equal 1, status
      assert_includes output, 'examples/blog/db/plans tem 2 planos novos'
      # Uma aplicação que a base não tem também entra com um plano só.
      FileUtils.rm(Dir[File.join(compiler.root, 'db/{plans,models}/000[23]_*')])
      FileUtils.cp_r(compiler.root, File.join(root, 'examples/nova'))
      assert_equal 0, run_gate(root, base).first
      write(root, 'examples/nova/db/plans/0002_mais.sql', "-- mais\n")
      status, output = run_gate(root, base)
      assert_equal 1, status
      assert_includes output, 'examples/nova/db/plans tem 2 planos novos'
    end
  end

  def test_missing_artifacts_and_deleted_examples_fail
    with_repository do |root, compiler, base|
      FileUtils.rm(compiler.artifact)
      status, output = run_gate(root, base)
      assert_equal 1, status
      assert_includes output, 'Artefato removido'
      FileUtils.rm_rf(compiler.root)
      assert_equal 1, run_gate(root, base).first
    end
  end

  def test_missing_empty_and_zero_bases_cannot_silently_skip_comparison
    with_repository do |root, _compiler, _base|
      ['', 'missing', '0' * 40].each do |base|
        assert_equal 1, run_gate(root, base).first
      end
      output = StringIO.new
      gate = VetraCI::GraphGate.new(root: root, out: output)
      assert_equal 0, gate.run(base: '0' * 40, initial_push: true)
      assert_includes output.string, 'Primeiro push'
      assert_equal 1, gate.run(base: '', initial_push: true)
    end
  end

  def test_a_legitimate_base_without_graphs_passes
    with_repository do |root, _compiler, _base|
      git(root, 'checkout', '--orphan', 'empty')
      git(root, 'rm', '-rf', '.')
      write(root, 'marker', 'base sem grafo')
      git(root, 'add', '.')
      git(root, 'commit', '-qm', 'Sem grafos')
      status, output = run_gate(root, 'HEAD')
      assert_equal 0, status
      assert_includes output, 'nada a comparar'
    end
  end

  def test_invalid_or_wildcard_declarations_fail
    with_repository do |root, compiler, base|
      before = compiler.build.document['digest']
      after = remove_route(compiler)['digest']
      ['*', ''].each do |digest|
        declare_break(root, before, digest)
        assert_equal 1, run_gate(root, base).first
      end
      declare_break(root, before, after)
      file = File.join(root, '.github/graph-compatibility.json')
      document = JSON.parse(File.read(file))
      document['changes'].first['reason'] = ' '
      File.write(file, JSON.generate(document))
      assert_equal 1, run_gate(root, base).first
      document['changes'].first['reason'] = 'Motivo'
      document['changes'] << document['changes'].first.dup
      File.write(file, JSON.generate(document))
      assert_equal 1, run_gate(root, base).first
      document['format_version'] = 'future'
      File.write(file, JSON.generate(document))
      assert_equal 1, run_gate(root, base).first
    end
  end

  def test_summary_lists_changes_that_need_human_review_even_when_breaks_fail
    with_repository do |root, compiler, base|
      remove_route(compiler)
      summary = File.join(root, 'summary.md')
      assert_equal 1, run_gate(root, base, summary: summary).first
      text = File.read(summary)
      assert_includes text, 'exigem revisão do mantenedor antes da integração'
      assert_includes text, 'blog.publish_post.http_1'
      assert_includes text, 'breaking'
    end
  end
end

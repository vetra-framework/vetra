require_relative 'test_helper'
require 'open3'
require 'rbconfig'

class RactorTest < GraphTest
  def test_compiled_results_are_shared_without_copy_and_remain_deeply_frozen
    %w[blog mini_crm mini_crm_revendas chat].each do |name|
      with_app(name) do |_root, compiler|
        result = compiler.build
        assert Ractor.shareable?(result), name
        worker = Ractor.new(result) do |graph|
          protected = [
            -> { graph.document['nodes'].clear },
            -> { graph.document['app']['name'].replace('changed') },
            -> { graph.document['nodes'].find { |node| node['kind'] == 'entity' }['fields'].first['privacy']['personal'] = true }
          ].map do |mutation|
            begin
              mutation.call
              false
            rescue FrozenError
              true
            end
          end
          [graph, Vetra::Graph::Canonical.digest(graph.document), protected, graph.warnings.map(&:to_s)]
        end
        shared, digest, protected, warnings = worker.value
        assert_same result, shared, name
        assert_equal result.document['digest'], digest, name
        assert_equal [true, true, true], protected, name
        assert_equal result.warnings.map(&:to_s), warnings, name
      end
    end
  end

  def test_linked_metadata_can_be_shared_while_executable_closures_stay_in_the_owner
    with_app do |_root, compiler|
      compiler.write
      linked = compiler.link
      refute Ractor.shareable?(linked), 'A unidade com closures não pertence à cópia de dados.'
      data = [linked.document, linked.bindings, linked.warnings, linked.implementation_ids, linked.builtin_bindings].freeze
      assert Ractor.shareable?(data)
      worker = Ractor.new(data) do |payload|
        document, bindings, _warnings, ids, _builtins = payload
        ruby_binding = bindings.find { |binding| binding['kind'] == 'ruby' }
        protected = [
          -> { bindings.clear },
          -> { ruby_binding['source']['path'].replace('changed') },
          -> { ids.first.replace('changed') }
        ].map do |mutation|
          begin
            mutation.call
            false
          rescue FrozenError
            true
          end
        end
        [payload, Vetra::Graph::Canonical.digest(document), ruby_binding['parameters'], protected]
      end
      shared, digest, parameters, protected = worker.value
      assert_same data, shared
      assert_equal linked.document['digest'], digest
      assert_equal linked.bindings.find { |binding| binding['kind'] == 'ruby' }['parameters'], parameters
      assert_equal [true, true, true], protected
      refute linked.respond_to?(:call)
    end
  end

  def test_core_build_check_validate_link_and_diff_work_without_the_ractor_constant
    script = <<~RUBY
      Object.send(:remove_const, :Ractor)
      require 'vetra'
      compiler = Vetra::Graph::Compiler.new(root: ARGV.fetch(0))
      built = compiler.write
      checked = compiler.check
      validated = compiler.validate_file(compiler.artifact, sources: true)
      linked = compiler.link
      raise 'Grafo divergente' unless [checked, validated, linked].all? { |value| value.document == built.document }
      raise 'Diff inesperado' if Vetra::Graph::Diff.new.compare(built.document, linked.document).changed?
      puts built.document['digest']
    RUBY
    %w[blog mini_crm mini_crm_revendas chat].each do |name|
      with_app(name) do |root, compiler|
        expected = compiler.build.document['digest']
        out, err, status = Open3.capture3(RbConfig.ruby, '-I', File.join(PROJECT, 'lib'), '-e', script, root)
        assert status.success?, "#{name}: #{err}"
        assert_empty err, name
        assert_equal "#{expected}\n", out, name
      end
    end
  end
end

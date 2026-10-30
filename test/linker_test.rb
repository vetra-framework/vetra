require_relative 'test_helper'

class LinkerTest < GraphTest
  RegistryView = Struct.new(:declarations, :bindings, keyword_init: true)

  def with_linker
    with_app do |root, compiler|
      result = compiler.write
      manifest = Vetra::Graph::Manifest.new(root)
      registry = Vetra::Graph::DeclarationLoader.new(manifest).load
      yield Vetra::Graph::Linker.new(result.document, manifest), registry, result, root
    end
  end

  def view(registry, bindings: registry.bindings, declarations: registry.declarations)
    RegistryView.new(declarations: declarations.freeze, bindings: bindings.freeze).freeze
  end

  def test_missing_and_unexpected_implementations_are_rejected
    with_linker do |linker, registry, _result, _root|
      bindings = registry.bindings.dup
      bindings.delete('blog.publish_post#call')
      assert_graph_error('implementation_missing') { linker.link(view(registry, bindings: bindings)) }
      bindings = registry.bindings.merge('blog.unlisted#call' => proc {}.freeze)
      assert_graph_error('implementation_unexpected') { linker.link(view(registry, bindings: bindings)) }
    end
  end

  def test_only_a_sealed_registry_can_be_published
    with_linker do |linker, registry, _result, _root|
      unsealed = RegistryView.new(declarations: registry.declarations, bindings: registry.bindings)
      assert_graph_error('registry_unsealed') { linker.link(unsealed) }
    end
  end

  def test_native_callbacks_and_non_proc_values_cannot_satisfy_ruby_references
    with_linker do |linker, registry, _result, _root|
      [Object.new.freeze, Kernel.method(:puts).to_proc.freeze].each do |value|
        bindings = registry.bindings.merge('blog.publish_post#call' => value)
        assert_graph_error('implementation_source') { linker.link(view(registry, bindings: bindings)) }
      end
    end
  end

  def test_a_block_from_another_source_file_is_rejected
    with_linker do |linker, registry, _result, _root|
      bindings = registry.bindings.merge('blog.publish_post#call' => registry.bindings.fetch('blog.find_post#call'))
      assert_graph_error('implementation_source') { linker.link(view(registry, bindings: bindings)) }
    end
  end

  def test_two_call_blocks_in_the_same_file_cannot_be_swapped
    with_app do |root, compiler|
      query_path = File.join(root, 'app/domains/blog/find_post.rb')
      command_path = File.join(root, 'app/domains/blog/publish_post.rb')
      write(root, 'app/domains/blog/operations.rb', "#{File.read(query_path)}\n#{File.read(command_path)}")
      File.unlink(query_path)
      File.unlink(command_path)
      result = compiler.write
      manifest = Vetra::Graph::Manifest.new(root)
      registry = Vetra::Graph::DeclarationLoader.new(manifest).load
      bindings = registry.bindings.merge('blog.publish_post#call' => registry.bindings.fetch('blog.find_post#call'))
      linker = Vetra::Graph::Linker.new(result.document, manifest)
      assert_graph_error('analysis_binding') { linker.link(view(registry, bindings: bindings)) }
    end
  end

  def test_missing_or_duplicate_declaration_is_rejected
    with_linker do |linker, registry, _result, _root|
      target = registry.declarations.find { |entry| entry['kind'] == 'command' && entry['id'] == 'blog.publish_post' }
      missing = registry.declarations.reject { |entry| entry.equal?(target) }
      assert_graph_error('implementation_declaration') { linker.link(view(registry, declarations: missing)) }
      assert_graph_error('implementation_declaration') { linker.link(view(registry, declarations: [*registry.declarations, target])) }
    end
  end

  def test_actual_parameters_must_agree_with_the_registered_uses_order
    with_linker do |linker, registry, _result, _root|
      declarations = Vetra::Graph::Data.copy(registry.declarations)
      declarations.find { |entry| entry['id'] == 'blog.publish_post' }['uses'].reverse!
      assert_graph_error('implementation_parameters') { linker.link(view(registry, declarations: declarations)) }
    end
  end

  def test_binder_detects_capability_and_analysis_mismatch_independently_of_model_audit
    with_linker do |_linker, registry, result, root|
      document = Vetra::Graph::Data.copy(result.document)
      target = node(document, 'command', 'blog.publish_post')
      target['uses'].reject! { |reference| reference['id'] == 'blog.clock' }
      manifest = Vetra::Graph::Manifest.new(root)
      linker = Vetra::Graph::Linker.new(document, manifest)
      assert_graph_error('implementation_capabilities') { linker.link(registry) }
      target['uses'] = Vetra::Graph::Data.copy(node(result.document, 'command', 'blog.publish_post')['uses'])
      target['implementation']['analysis']['constants'] << 'different'
      assert_graph_error('implementation_analysis') { linker.link(registry) }
    end
  end

  def test_duplicate_ruby_reference_is_invalid_even_when_node_kinds_differ
    with_linker do |_linker, registry, result, root|
      document = Vetra::Graph::Data.copy(result.document)
      command = node(document, 'command', 'blog.publish_post')
      query = Vetra::Graph::Data.copy(command).merge('kind' => 'query')
      query.delete('emits')
      query['uses'] = [{ 'kind' => 'capability', 'id' => 'blog.posts_read' }]
      document['nodes'] << query
      document['digest'] = Vetra::Graph::Canonical.digest(document)
      assert_graph_error('duplicate_implementation') { Vetra::Graph::Validator.new.validate!(document) }
      linker = Vetra::Graph::Linker.new(document, Vetra::Graph::Manifest.new(root))
      assert_graph_error('duplicate_implementation') { linker.link(registry) }
    end
  end
end

module Vetra
  module Graph
    # Internal binder. Compiler#link performs artifact and package validation
    # before constructing this object or evaluating project declarations.
    class Linker
      def initialize(document, manifest)
        @document, @manifest = document, manifest
        @nodes = document.fetch('nodes').to_h { |node| [node.values_at('kind', 'id'), node] }
        @analysis = Analysis.new(manifest)
      end

      def link(registry, warnings: [])
        unless registry.frozen? && registry.bindings.frozen? && registry.declarations.frozen?
          raise Error.single('registry_unsealed', 'Sele o registro antes de vincular implementações.')
        end
        operations = @document['nodes'].select { |node| node.key?('implementation') }
        ruby_nodes = operations.select { |node| node.dig('implementation', 'kind') == 'ruby' }
        expected = ruby_nodes.map { |node| node.dig('implementation', 'ref') }
        if expected.uniq != expected
          raise Error.single('duplicate_implementation', 'Mais de uma operação usa a mesma referência de implementação.')
        end
        missing = expected - registry.bindings.keys
        extra = registry.bindings.keys - expected
        unless missing.empty?
          raise Error.single('implementation_missing', "Implementações ausentes no registro: #{missing.sort.join(', ')}.")
        end
        unless extra.empty?
          raise Error.single('implementation_unexpected', "Implementações sem operação na IR: #{extra.sort.join(', ')}.")
        end
        declarations = registry.declarations.group_by { |entry| entry.values_at('kind', 'id') }
        bindings = operations.map do |node|
          if node.dig('implementation', 'kind') == 'ruby'
            ruby_binding(node, declarations, registry.bindings)
          else
            builtin_binding(node)
          end
        end
        LinkedGraph.new(document: @document, warnings: warnings, bindings: bindings, implementations: registry.bindings)
      end

      private

      def fail!(code, message, node)
        raise Error.single(code, message, source: node['source'])
      end

      def ruby_binding(node, declarations, implementations)
        descriptor = node['implementation']
        candidates = declarations.fetch(node.values_at('kind', 'id'), [])
        unless candidates.size == 1 && candidates.first['source'] == node['source'] && candidates.first['domain'] == node.dig('domain', 'id')
          fail!('implementation_declaration', 'O vínculo exige uma única declaração correspondente à origem da operação.', node)
        end
        declaration = candidates.first
        block = implementations.fetch(descriptor['ref'])
        unless block.is_a?(Proc) && block.frozen? && block.source_location
          fail!('implementation_source', 'A implementação deve ser um bloco Ruby congelado com origem verificável.', node)
        end
        begin
          origin = @manifest.source(*block.source_location)
        rescue Error, SystemCallError
          fail!('implementation_source', 'O bloco não pertence aos fontes verificados do pacote.', node)
        end
        unless origin['path'] == descriptor['path'] && @manifest.entries.any? { |input| input['path'] == origin['path'] && input['digest'] == descriptor['digest'] }
          fail!('implementation_source', 'Arquivo ou digest do bloco difere da implementação declarada na IR.', node)
        end
        report = @analysis.inspect_block(block, declaration['uses'], declaration_source: node['source'], declaration_kind: node['kind'])
        unless report['analysis'] == descriptor['analysis']
          fail!('implementation_analysis', 'Análise do bloco difere do artefato; reconstrua e revise o pacote.', node)
        end
        arguments = declaration['uses'].each_with_index.map do |name, i|
          reference = Capabilities.reference(name, domain: declaration['domain'], operation_kind: node['kind'], nodes: @nodes, source: node['source'])
          { 'position' => i + 1, 'parameter' => name.split('.').last, 'capability' => reference }
        end
        references = arguments.map { |argument| argument['capability'] }.sort_by { |reference| reference.values_at('kind', 'id') }
        unless references == node['uses'].sort_by { |reference| reference.values_at('kind', 'id') }
          fail!('implementation_capabilities', 'As capacidades dos parâmetros diferem do conjunto uses da IR.', node)
        end
        {
          'kind' => 'ruby', 'operation' => Data.reference(node['kind'], node['id']),
          'ref' => descriptor['ref'], 'source' => report['source'],
          'parameters' => block.parameters.map { |_, name| name.to_s }, 'arguments' => arguments
        }
      end

      def builtin_binding(node)
        name = node.dig('implementation', 'name')
        action = name.delete_prefix('crud.')
        unless Schema::CRUD_ACTIONS.include?(action) && name == "crud.#{action}" && node['kind'] == (action == 'read' ? 'query' : 'command')
          fail!('builtin_implementation', 'Primitiva desconhecida ou incompatível com a operação.', node)
        end
        { 'kind' => 'builtin', 'operation' => Data.reference(node['kind'], node['id']), 'name' => name, 'executor' => 'pending' }
      end
    end
  end
end

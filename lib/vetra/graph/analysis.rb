require "prism"

module Vetra
  module Graph
    class Analysis
      DYNAMIC = %i[send public_send __send__ const_get eval instance_eval class_eval module_eval define_method instance_variable_get].freeze
      PROCESS_CALLS = %i[system exec spawn fork open sleep gets puts print warn rand srand require require_relative load exit abort at_exit trap autoload].freeze
      WRITE_CALLS = %i[create! update! delete! insert update delete save! destroy! add_member! remove_member!].freeze
      EFFECT_CLASSES = /\A(?:File|IO|Socket|TCPSocket|UDPSocket|Process|Thread|Random|SecureRandom|Net::HTTP|OpenURI|ENV)(?:::|\z)/

      def initialize(manifest)
        @manifest = manifest
        @trees = {}
      end

      def inspect_block(block, declared_uses)
        path, line = block.source_location
        source = @manifest.source(path, line)
        parsed = @trees[source['path']] ||= Prism.parse(@manifest.read(source['path']))
        candidates = descendants(parsed.value).select do |node|
          node.is_a?(Prism::CallNode) && node.name == :call && node.block.is_a?(Prism::BlockNode) && node.block.location.start_line == line
        end
        unless candidates.size == 1
          raise Error.single("analysis_binding", "Cada implementação call deve ocupar uma linha própria e ter origem no arquivo declarado.", source: source)
        end
        parameters = block.parameters
        expected = declared_uses.map { |name| name.split('.').last }
        unless parameters.size == expected.size + 1 && parameters.all? { |kind, _| %i[opt req].include?(kind) } && parameters.drop(1).map { |_, name| name.to_s } == expected
          raise Error.single("implementation_parameters", "call exige um parâmetro de entrada seguido das capacidades na ordem de uses: #{expected.join(', ')}.", source: source)
        end
        constants, dynamic, forbidden, writes = [], [], [], []
        descendants(candidates.first.block.body).each do |node|
          if node.is_a?(Prism::ConstantReadNode) || node.is_a?(Prism::ConstantPathNode)
            constants << node.location.slice.delete_prefix('::')
          elsif node.is_a?(Prism::XStringNode) || node.is_a?(Prism::InterpolatedXStringNode)
            forbidden << 'Kernel#`'
          elsif node.is_a?(Prism::CallNode)
            receiver = node.receiver
            constant = if receiver.is_a?(Prism::ConstantReadNode) || receiver.is_a?(Prism::ConstantPathNode)
              receiver.location.slice.delete_prefix('::')
            end
            name = node.name
            if constant&.match?(EFFECT_CLASSES) || (%w[Time DateTime].include?(constant) && %i[now new].include?(name)) || (constant == 'Date' && name == :today) || (constant == 'Kernel' && PROCESS_CALLS.include?(name)) || (!receiver && PROCESS_CALLS.include?(name))
              effect = "#{constant || 'Kernel'}.#{name}"
              forbidden << effect
              constants << effect
            end
            dynamic << name.to_s if DYNAMIC.include?(name)
            if !receiver && ![:fail!].include?(name) && !PROCESS_CALLS.include?(name)
              dynamic << "unresolved_call:#{name}"
            end
            if receiver.is_a?(Prism::LocalVariableReadNode) && WRITE_CALLS.include?(name)
              attributes = node.arguments&.arguments&.select { |arg| arg.is_a?(Prism::KeywordHashNode) || arg.is_a?(Prism::HashNode) } || []
              values = attributes.flat_map(&:elements).filter_map do |pair|
                next unless pair.is_a?(Prism::AssocNode) && pair.key.is_a?(Prism::SymbolNode)
                known, value = literal(pair.value)
                { 'name' => pair.key.unescaped, 'known' => known, 'value' => value }
              end
              writes << { 'receiver' => receiver.name.to_s, 'fields' => values, 'line' => node.location.start_line }
            end
          end
        end
        {
          'source' => source, 'forbidden' => forbidden.uniq.sort, 'writes' => writes,
          'analysis' => { 'status' => dynamic.empty? ? 'complete' : 'incomplete', 'constants' => constants.uniq.sort, 'dynamic' => dynamic.uniq.sort }
        }
      end

      private

      def descendants(node)
        return [] unless node
        [node, *node.compact_child_nodes.flat_map { |child| descendants(child) }]
      end

      def literal(node)
        case node
        when Prism::StringNode, Prism::SymbolNode then [true, node.unescaped]
        when Prism::IntegerNode then [true, node.value]
        when Prism::TrueNode then [true, true]
        when Prism::FalseNode then [true, false]
        when Prism::NilNode then [true, nil]
        else [false, nil]
        end
      end
    end
  end
end

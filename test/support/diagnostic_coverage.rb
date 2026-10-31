require 'prism'

module VetraTest
  # Counts codes that are actually constructed, rather than names mentioned in assertions.
  class DiagnosticCoverage
    attr_reader :sites, :observed

    def initialize(root:)
      @sites = {}
      @observed = {}
      Dir.glob(File.join(root, 'lib/**/*.rb')).sort.each do |path|
        parsed = Prism.parse_file(path)
        raise ArgumentError, "Ruby inválido em #{path}: #{parsed.errors.map(&:message).join(', ')}" unless parsed.success?
        collect(parsed.value, path.delete_prefix("#{root}/"))
      end
      raise ArgumentError, 'Nenhum código de diagnóstico encontrado em lib/.' if sites.empty?
    end

    def record(code)
      observed[code.to_s] = true
    end

    def missing
      (sites.keys - observed.keys).sort
    end

    def unknown
      (observed.keys - sites.keys).sort
    end

    def report(out: $stdout, err: $stderr)
      covered = sites.size - missing.size
      out.puts "Diagnósticos: #{covered}/#{sites.size} códigos exercitados."
      missing.each { |code| err.puts "[diagnostics_coverage] Sem teste que emita #{code}: #{sites.fetch(code).join(', ')}" }
      unknown.each { |code| err.puts "[diagnostics_coverage] Código emitido sem declaração literal reconhecida: #{code}" }
      missing.empty? && unknown.empty?
    end

    private

    def collect(node, path)
      if node.is_a?(Prism::CallNode)
        argument = code_argument(node)
        if argument.is_a?(Prism::StringNode) || argument.is_a?(Prism::SymbolNode)
          code = argument.unescaped
          (sites[code] ||= []) << "#{path}:#{node.location.start_line}"
        end
      end
      node.compact_child_nodes.each { |child| collect(child, path) }
    end

    def code_argument(call)
      arguments = call.arguments&.arguments || []
      return arguments.first if call.receiver.nil? && %i[issue fail! error].include?(call.name)
      receiver = call.receiver
      return unless receiver.is_a?(Prism::ConstantReadNode) || receiver.is_a?(Prism::ConstantPathNode)
      constant = receiver.location.slice.split('::').last
      return arguments.first if constant == 'Error' && call.name == :single
      return unless constant == 'Diagnostic' && call.name == :new
      keywords = arguments.find { |argument| argument.is_a?(Prism::KeywordHashNode) }
      keywords&.elements&.find do |pair|
        pair.is_a?(Prism::AssocNode) && pair.key.is_a?(Prism::SymbolNode) && pair.key.unescaped == 'code'
      end&.value
    end
  end
end

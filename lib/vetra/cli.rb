require "optparse"
require_relative "../vetra"

module Vetra
  class CLI
    def self.run(arguments, out: $stdout, err: $stderr)
      options = { root: Dir.pwd, sources: false }
      parser = OptionParser.new do |flags|
        flags.banner = "Uso: vetra graph:build|graph:check|graph:validate [arquivo] [--root diretório] [--sources]"
        flags.on('--root PATH', 'Raiz da aplicação') { |value| options[:root] = value }
        flags.on('--sources', 'Também verificar manifesto em graph:validate') { options[:sources] = true }
        flags.on('-h', '--help', 'Mostrar ajuda') { out.puts(flags); return 0 }
        flags.on('--version', 'Mostrar versão do protótipo') { out.puts(VERSION); return 0 }
      end
      args = parser.parse(arguments.dup)
      command = args.shift
      unless %w[graph:build graph:check graph:validate].include?(command)
        err.puts(parser)
        return 2
      end
      if (command != 'graph:validate' && (!args.empty? || options[:sources])) || args.size > 1
        raise OptionParser::InvalidArgument, 'argumentos incompatíveis com o comando'
      end
      compiler = Graph::Compiler.new(root: options[:root])
      result = case command
      when 'graph:build' then compiler.write
      when 'graph:check' then compiler.check
      when 'graph:validate'
        compiler.validate_file(args.first || compiler.artifact, sources: options[:sources])
      end
      result.warnings.each { |diagnostic| err.puts(diagnostic) }
      out.puts("#{command}: OK — #{result.document.fetch('nodes').size} nós, #{result.document.fetch('digest')}")
      0
    rescue Graph::Error => e
      e.diagnostics.each { |diagnostic| err.puts(diagnostic) }
      1
    rescue OptionParser::ParseError => e
      err.puts(e.message)
      2
    rescue SystemCallError => e
      err.puts("[filesystem] #{e.class}: não foi possível ler ou gravar o projeto.")
      1
    end
  end
end

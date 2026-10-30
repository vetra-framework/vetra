require "optparse"
require_relative "../vetra"

module Vetra
  class CLI
    def self.run(arguments, out: $stdout, err: $stderr)
      options = { root: Dir.pwd, sources: false, format: nil, fail_on_breaking: false }
      parser = OptionParser.new do |flags|
        flags.banner = "Uso: vetra graph:build|graph:check|graph:validate [arquivo] [--root diretório] [--sources]\n     vetra graph:diff ANTERIOR POSTERIOR [--root diretório] [--format text|json] [--fail-on-breaking]"
        flags.on('--root PATH', 'Raiz da aplicação') { |value| options[:root] = value }
        flags.on('--sources', 'Também verificar manifesto em graph:validate') { options[:sources] = true }
        flags.on('--format FORMAT', %w[text json], 'Formato de graph:diff: text ou json') { |value| options[:format] = value }
        flags.on('--fail-on-breaking', 'Sair com código 3 se o diff apontar quebra potencial') { options[:fail_on_breaking] = true }
        flags.on('-h', '--help', 'Mostrar ajuda') { out.puts(flags); return 0 }
        flags.on('--version', 'Mostrar versão do protótipo') { out.puts(VERSION); return 0 }
      end
      args = parser.parse(arguments.dup)
      command = args.shift
      unless %w[graph:build graph:check graph:validate graph:diff].include?(command)
        err.puts(parser)
        return 2
      end
      if command == 'graph:diff'
        raise OptionParser::InvalidArgument, 'graph:diff exige duas entradas e não aceita --sources' unless args.size == 2 && !options[:sources]
        source = Graph::DiffSource.new(root: options[:root])
        report = Graph::Diff.new.compare(*args.map { |input| source.read(input) })
        report.data['warnings'].each do |warning|
          label = warning['side'] == 'before' ? 'anterior' : 'posterior'
          diagnostic = Graph::Diagnostic.new(code: warning['code'], message: warning['message'], pointer: warning['pointer'], source: warning['source'], severity: :warning)
          err.puts("[#{label}] #{diagnostic}")
        end
        out.write(options[:format] == 'json' ? report.to_json : report.to_text)
        return options[:fail_on_breaking] && report.breaking? ? 3 : 0
      end
      if options[:format] || options[:fail_on_breaking] || (command != 'graph:validate' && (!args.empty? || options[:sources])) || args.size > 1
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

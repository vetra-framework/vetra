require "optparse"
require_relative "../vetra"

module Vetra
  class CLI
    def self.run(arguments, out: $stdout, err: $stderr)
      options = { root: Dir.pwd, sources: false, format: nil, fail_on_breaking: false }
      parser = OptionParser.new do |flags|
        flags.banner = "Uso: vetra graph:build|graph:check|graph:link [--root diretório]\n     vetra graph:validate [arquivo] [--root diretório] [--sources]\n     vetra graph:diff ANTERIOR POSTERIOR [--root diretório] [--format text|json] [--fail-on-breaking]\n     vetra db:authz:sql [--root diretório] [--sql-schema nome] [--owner-role nome] [--app-role nome]\n     vetra db:plan [--root diretório] [--snapshot | --check]\n     vetra db:migrate [--root diretório]"
        flags.on('--root PATH', 'Raiz da aplicação') { |value| options[:root] = value }
        flags.on('--sources', 'Também verificar manifesto em graph:validate') { options[:sources] = true }
        flags.on('--format FORMAT', %w[text json], 'Formato de graph:diff: text ou json') { |value| options[:format] = value }
        flags.on('--fail-on-breaking', 'Sair com código 3 se o diff apontar quebra potencial') { options[:fail_on_breaking] = true }
        flags.on('--sql-schema NAME', 'Schema novo do SQL de revisão de autorização') { |value| options[:schema] = value }
        flags.on('--owner-role NAME', 'Papel proprietário já existente') { |value| options[:owner_role] = value }
        flags.on('--app-role NAME', 'Papel da aplicação já existente') { |value| options[:app_role] = value }
        flags.on('--snapshot', 'db:plan: regravar db/schema.sql num banco descartável (DATABASE_URL)') { options[:snapshot] = true }
        flags.on('--check', 'db:plan: conferir plano e retrato num banco descartável (DATABASE_URL)') { options[:check] = true }
        flags.on('-h', '--help', 'Mostrar ajuda') { out.puts(flags); return 0 }
        flags.on('--version', 'Mostrar versão do protótipo') { out.puts(VERSION); return 0 }
      end
      args = parser.parse(arguments.dup)
      command = args.shift
      unless %w[graph:build graph:check graph:validate graph:diff graph:link db:authz:sql db:plan db:migrate].include?(command)
        err.puts(parser)
        return 2
      end
      sql_options = options.slice(:schema, :owner_role, :app_role)
      if command == 'db:plan'
        unless args.empty? && sql_options.empty? && !options[:sources] && !options[:format] && !options[:fail_on_breaking] && !(options[:snapshot] && options[:check])
          raise OptionParser::InvalidArgument, 'db:plan aceita --root e uma entre --snapshot e --check'
        end
        url = ENV['DATABASE_URL']
        database = url && !url.empty? ? SQL::ScratchDatabase.new(url: url, pg_dump: ENV.fetch('VETRA_PG_DUMP', 'pg_dump'), migrator_password: ENV['VETRA_MIGRATOR_PASSWORD']) : nil
        planner = SQL::Planner.new(root: options[:root], database: database)
        result = options[:check] ? planner.check : (options[:snapshot] ? planner.snapshot : planner.plan)
        relative = result.path.delete_prefix("#{File.expand_path(options[:root])}/")
        message = { written: "gravado #{relative}", unchanged: "sem mudanças em #{relative}", checked: "plano e #{relative} conferem" }
        out.puts("db:plan: OK — #{message.fetch(result.status)}")
        return 0
      end
      raise OptionParser::InvalidArgument, '--snapshot e --check exigem db:plan' if options[:snapshot] || options[:check]
      if command == 'db:migrate'
        unless args.empty? && sql_options.empty? && !options[:sources] && !options[:format] && !options[:fail_on_breaking]
          raise OptionParser::InvalidArgument, 'db:migrate aceita somente --root'
        end
        url = ENV['DATABASE_URL']
        raise Graph::Error.single('db_database_url', 'Defina DATABASE_URL com o banco alvo, conectando como vetra_migrator.') if url.nil? || url.empty?
        connection = SQL::MigrationDatabase.connect(url)
        begin
          database = SQL::MigrationDatabase.new(connection: connection, pg_dump: ENV.fetch('VETRA_PG_DUMP', 'pg_dump'))
          result = SQL::Migrator.new(root: options[:root], database: database).migrate
        ensure
          connection.close
        end
        if result.status == :applied
          retries = result.retries
          out.puts("db:migrate: OK — aplicado #{result.applied.map(&:file_name).join(', ')}#{" (#{retries} nova(s) tentativa(s) por lock_timeout)" if retries.positive?}; esquema confere com db/schema.sql")
        else
          out.puts('db:migrate: OK — nenhum plano pendente; esquema confere com db/schema.sql')
        end
        return 0
      end
      if command == 'db:authz:sql'
        unless args.empty? && !options[:sources] && !options[:format] && !options[:fail_on_breaking] && !options[:snapshot] && !options[:check]
          raise OptionParser::InvalidArgument, 'db:authz:sql aceita somente --root e opções de schema/papéis'
        end
        result = Graph::Compiler.new(root: options[:root]).read_artifact
        generated = SQL::Authorization.new(result.document, **sql_options).generate
        generated.warnings.each { |diagnostic| err.puts(diagnostic) }
        out.write(generated.sql)
        return 0
      end
      raise OptionParser::InvalidArgument, 'opções de SQL exigem db:authz:sql' unless sql_options.empty?
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
      when 'graph:link' then compiler.link
      end
      result.warnings.each { |diagnostic| err.puts(diagnostic) }
      if command == 'graph:link'
        out.puts("#{command}: OK — #{result.implementation_ids.size} blocos Ruby vinculados; #{result.builtin_bindings.size} descritores de primitivas sem executor; #{result.document.fetch('digest')}")
      else
        out.puts("#{command}: OK — #{result.document.fetch('nodes').size} nós, #{result.document.fetch('digest')}")
      end
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

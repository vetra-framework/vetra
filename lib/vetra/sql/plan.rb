# frozen_string_literal: true

module Vetra
  module SQL
    # Plano de migração revisável (ADR-015, §1, e ADR-025, §1): SQL com um cabeçalho e marcadores por passo, que dizem
    # a fase, o lock que o passo pede numa tabela existente e o custo. O texto é o artefato versionado em db/plans/.
    class Plan
      # transaction: nil num plano de transação única; 'sim' ou 'nao' num plano por_passo (ADR-038, §2).
      Step = Struct.new(:number, :phase, :lock, :cost, :sql, :transaction, keyword_init: true)

      PHASES = %w[expand migrate contract].freeze
      # Nomes do PostgreSQL sem o sufixo Lock; "nenhum" quando o passo só cria objetos novos.
      LOCKS = %w[nenhum AccessShare RowShare RowExclusive ShareUpdateExclusive Share ShareRowExclusive Exclusive AccessExclusive].freeze
      # catalogo: só altera o catálogo; tabela_vazia: age sobre uma tabela criada no mesmo plano, ainda sem linhas;
      # varre_tabela: lê uma tabela existente inteira sem bloquear escrita (CONCURRENTLY, VALIDATE).
      COSTS = %w[catalogo tabela_vazia varre_tabela].freeze
      # unica: todos os passos numa transação; por_passo: cada passo na sua, ou fora de transação (ADR-038, §2).
      TRANSACTIONS = %w[unica por_passo].freeze
      STEP_TRANSACTIONS = %w[sim nao].freeze
      NAME = /\A(\d{4})_([a-z][a-z0-9_]*)\.sql\z/
      HEADER = /\A-- vetra:plano (\d{4}) ([a-z][a-z0-9_]*)\z/
      TRANSACTION = /\A-- vetra:transacao (\S+)\z/
      STEP = /\A-- vetra:passo (\d+) fase=(\S+) lock=(\S+) custo=(\S+)(?: transacao=(\S+))?\z/
      INITIAL = { number: '0001', name: 'inicial' }.freeze

      # As únicas formas que o PostgreSQL exige fora de transação e que um plano pode ter (ADR-015, §4).
      OUTSIDE_TRANSACTION = [
        /\ACREATE (UNIQUE )?INDEX CONCURRENTLY "[a-z][a-z0-9_]*" ON "[a-z][a-z0-9_]*"\."[a-z][a-z0-9_]*" /,
        /\ADROP INDEX CONCURRENTLY IF EXISTS "[a-z][a-z0-9_]*"\."[a-z][a-z0-9_]*";\z/,
        /\AREINDEX INDEX CONCURRENTLY "[a-z][a-z0-9_]*"\."[a-z][a-z0-9_]*";\z/
      ].freeze

      # Filtro de instruções sobre objetos fora do banco (ADR-038, §3, item 3). Vale para o texto inteiro do passo,
      # inclusive corpos de função e blocos DO. É um filtro, não uma prova: a contenção do --check é o papel com que os
      # planos são aplicados.
      # Funções que mudam a sessão, leem arquivos ou agem sobre outras sessões e o servidor.
      FUNCTIONS = /set_config|dblink\w*|pg_read_file|pg_read_binary_file|pg_ls_\w+|pg_stat_file|lo_import|lo_export|lo_unlink|lo_from_bytea|lo_put|pg_file_\w+|pg_terminate_backend|pg_cancel_backend|pg_reload_conf|pg_rotate_logfile|pg_promote|pg_switch_wal|pg_create_\w+_slot|pg_drop_replication_slot|pg_log_backend_memory_contexts/i
      # O mesmo nome entre aspas e chamado como função: pg_catalog."set_config"(...) continua sendo set_config.
      QUOTED_FUNCTION = /\A(?:#{FUNCTIONS.source})\z/i
      GLOBAL = [
        /\b(CREATE|ALTER|DROP)\s+(ROLE|USER|GROUP|DATABASE|TABLESPACE|SUBSCRIPTION|PUBLICATION|SERVER|EVENT\s+TRIGGER|FOREIGN\s+DATA\s+WRAPPER)\b/i,
        /\bALTER\s+SYSTEM\b/i,
        /\b(SET|RESET)\s+(LOCAL\s+|SESSION\s+)?(ROLE|SESSION\s+AUTHORIZATION)\b/i,
        /\b(REASSIGN|DROP)\s+OWNED\b/i,
        /\bSECURITY\s+LABEL\b/i,
        /\bCOMMENT\s+ON\s+(DATABASE|ROLE|TABLESPACE)\b/i,
        # Privilégios sobre objetos globais: bancos, tablespaces e parâmetros. Os do banco corrente que o plano inicial
        # concede (ADR-036) vão num EXECUTE com literal e não passam por aqui.
        /\bON\s+(DATABASE|TABLESPACE|PARAMETER)\b/i,
        # Identificadores e literais com escape Unicode (U&"set\005fconfig"): o gerador nunca os emite, e o nome real só
        # aparece depois de decodificado.
        /\bU&(?:""|'')/i,
        /\bCOPY\b/i,
        /\bLOAD\s+'/i,
        # GRANT/REVOKE de papel: uma lista de nomes seguida de TO/FROM, sem ON.
        /\bGRANT\s+(?:"[^"]*"|[a-z_][a-z0-9_$]*)(?:\s*,\s*(?:"[^"]*"|[a-z_][a-z0-9_$]*))*\s+TO\b/i,
        /\bREVOKE\s+(?:(?:ADMIN|INHERIT|SET)\s+OPTION\s+FOR\s+)?(?:"[^"]*"|[a-z_][a-z0-9_$]*)(?:\s*,\s*(?:"[^"]*"|[a-z_][a-z0-9_$]*))*\s+FROM\b/i,
        /\b(?:#{FUNCTIONS.source})\s*\(/i
      ].freeze
      # Instruções de topo que mudam a sessão ou a transação do executor.
      SESSION = /\A(SET|RESET|DISCARD|BEGIN|START|COMMIT|END|ROLLBACK|ABORT|SAVEPOINT|RELEASE|PREPARE|EXECUTE|DEALLOCATE|LISTEN|UNLISTEN|NOTIFY|CALL|VACUUM|CHECKPOINT|LOAD|COPY|DECLARE|FETCH|CLOSE|MOVE)\b/i

      # Classificação dos comandos do DDL de banco vazio (ADR-035). Em banco vazio todas as tabelas nascem no próprio
      # plano: as travas não esperam por leitores nem escritores, mas ficam registradas para o revisor e para a rodada 4.
      CLASSIFICATION = [
        # Forma incremental (ADR-038, §2): índice numa tabela existente, fora de transação, sem bloquear escrita.
        [/\ACREATE (UNIQUE )?INDEX CONCURRENTLY /, 'ShareUpdateExclusive', 'varre_tabela'],
        [/\ADO \$vetra_(context_roles|database_privileges)\$/, 'nenhum', 'catalogo'],
        [/\ADO \$vetra_(roles|shared_schema|privileges|routines)\$/, 'nenhum', 'catalogo'],
        [/\ADO \$vetra_tables\$/, 'AccessShare', 'tabela_vazia'],
        [/\ALOCK TABLE /, 'ShareRowExclusive', 'tabela_vazia'],
        [/\ACREATE SCHEMA /, 'nenhum', 'catalogo'],
        [/\ACREATE EXTENSION /, 'nenhum', 'catalogo'],
        [/\ACREATE TABLE /, 'nenhum', 'catalogo'],
        [/\AALTER TABLE \S+ ADD CONSTRAINT \S+ UNIQUE /, 'AccessExclusive', 'tabela_vazia'],
        [/\ACREATE (UNIQUE )?INDEX /, 'Share', 'tabela_vazia'],
        [/\AALTER TABLE \S+ ADD CONSTRAINT \S+ FOREIGN KEY /, 'ShareRowExclusive', 'tabela_vazia'],
        [/\AALTER TABLE \S+ OWNER TO /, 'AccessExclusive', 'tabela_vazia'],
        [/\AALTER TABLE \S+ ENABLE ALWAYS TRIGGER /, 'ShareRowExclusive', 'tabela_vazia'],
        [/\AALTER TABLE \S+ (ENABLE|FORCE) ROW LEVEL SECURITY/, 'AccessExclusive', 'tabela_vazia'],
        [/\ACREATE POLICY /, 'AccessExclusive', 'tabela_vazia'],
        [/\ACREATE TRIGGER /, 'ShareRowExclusive', 'tabela_vazia'],
        [/\AINSERT INTO /, 'RowExclusive', 'tabela_vazia'],
        [/\AALTER SCHEMA \S+ OWNER TO /, 'nenhum', 'catalogo'],
        [/\ACREATE FUNCTION /, 'nenhum', 'catalogo'],
        [/\AALTER FUNCTION \S+ OWNER TO /, 'nenhum', 'catalogo'],
        [/\A(REVOKE|GRANT) .+ ON (SCHEMA|TABLE|FUNCTION) /, 'nenhum', 'catalogo'],
        [/\A(REVOKE|GRANT) .+ ON "[a-z][a-z0-9_]*"\."[a-z][a-z0-9_]*" /, 'nenhum', 'catalogo']
      ].freeze

      attr_reader :number, :name, :transaction, :steps

      def initialize(number:, name:, transaction:, steps:)
        @number, @name, @transaction = number, name, transaction
        @steps = Graph::Data.freeze(steps)
        # O gerador e o leitor passam pelo mesmo filtro: um plano só existe dentro das formas permitidas.
        @steps.each { |step| self.class.check_step!(step, transaction, "db/plans/#{file_name}") }
        freeze
      end

      def file_name
        "#{number}_#{name}.sql"
      end

      # Primeiro plano de uma aplicação, a partir do resultado de Vetra::SQL::Schema.
      def self.initial(schema)
        statements = Context.prefix + schema.blocks.flat_map { |block| block['statements'] } + Context.suffix(schema.tables)
        if schema.respond_to?(:document) && schema.document
          statements.concat(Security.new(schema).generate.statements)
          if schema.document.dig('app', 'tenant')
            statements.concat(Authorization.new(schema.document).generate.statements)
          end
        end
        steps = statements.each_with_index.map do |sql, index|
          lock, cost = classify(sql)
          Step.new(number: index + 1, phase: 'expand', lock: lock, cost: cost, sql: sql)
        end
        new(**INITIAL, transaction: 'unica', steps: steps)
      end

      # Lock e custo de um comando gerado; um comando sem classificação é erro, nunca um passo sem rótulo.
      def self.classify(sql)
        _, lock, cost = CLASSIFICATION.find { |pattern, *| pattern.match?(sql) }
        raise Graph::Error.single('db_plan_step', "Comando do esquema sem classificação de lock: #{sql.lines.first.strip}") unless lock
        [lock, cost]
      end

      # O texto que o filtro lê: sem comentários, literais ('...', E'...') e identificadores entre aspas, que não executam
      # nada e podem conter qualquer palavra (uma coluna "copy", um valor de enum, a mensagem de um RAISE). Os
      # delimitadores $tag$ viram espaço e o corpo continua sendo lido como código, com os seus próprios literais
      # retirados. Um EXECUTE com o comando num literal escapa do filtro; a contenção do --check cobre esse caso.
      # calls recebe o nome de cada identificador entre aspas chamado como função ("nome"(...)), para o filtro conferir.
      def self.code_only(sql, calls = [])
        out, index, size = +'', 0, sql.size
        while index < size
          char, pair = sql[index], sql[index, 2]
          if pair == '--'
            index = sql.index("\n", index) || size
            out << ' '
          elsif pair == '/*'
            depth, index = 1, index + 2
            while index < size && depth.positive?
              if sql[index, 2] == '/*' then depth += 1; index += 2
              elsif sql[index, 2] == '*/' then depth -= 1; index += 2
              else index += 1
              end
            end
            out << ' '
          elsif char == "'"
            escape = index.positive? && sql[index - 1].match?(/[Ee]/) && !(index > 1 && sql[index - 2].match?(/[A-Za-z0-9_]/))
            index += 1
            while index < size
              if escape && sql[index] == '\\' then index += 2
              elsif sql[index] == "'" && sql[index + 1] == "'" then index += 2
              elsif sql[index] == "'" then break
              else index += 1
              end
            end
            index += 1
            out << "''"
          elsif char == '"'
            start = index += 1
            index += sql[index, 2] == '""' ? 2 : 1 while index < size && !(sql[index] == '"' && sql[index + 1] != '"')
            calls << sql[start...index].gsub('""', '"') if call_follows?(sql, index + 1)
            index += 1
            out << '""'
          elsif char == '$' && !(index.positive? && sql[index - 1].match?(/[A-Za-z0-9_]/)) && (tag = StatementScanner::DOLLAR.match(sql, index)) && tag.begin(0) == index
            index += tag[0].size
            out << ' '
          else
            out << char
            index += 1
          end
        end
        out
      end

      # Se, depois de espaços e comentários (inclusive aninhados), o texto abre parênteses: "nome" /* x */ ( é uma chamada.
      def self.call_follows?(sql, index)
        size = sql.size
        loop do
          index += 1 while index < size && sql[index].match?(/\s/)
          if sql[index, 2] == '--'
            index = sql.index("\n", index) || size
          elsif sql[index, 2] == '/*'
            depth, index = 1, index + 2
            while index < size && depth.positive?
              if sql[index, 2] == '/*' then depth += 1; index += 2
              elsif sql[index, 2] == '*/' then depth -= 1; index += 2
              else index += 1
              end
            end
          else
            return sql[index] == '('
          end
        end
      end

      # Os inícios das instruções de topo de um trecho SQL, na ordem.
      def self.statement_starts(sql)
        scanner = StatementScanner.new
        sql.each_line { |line| scanner.feed(line.chomp) }
        scanner.starts
      end

      # Recusa um passo que alcança objetos fora do banco, muda a sessão do executor ou tem forma incompatível com a
      # transação em que roda. Vale para todo plano lido, antes de qualquer acesso ao banco.
      def self.check_step!(step, transaction, file)
        where = "#{file}, passo #{step.number}"
        calls = []
        code = code_only(step.sql, calls)
        if (call = calls.find { |name| QUOTED_FUNCTION.match?(name) })
          raise Graph::Error.single('db_plan_forbidden', "#{where}: chamada da função \"#{call}\", que age fora do banco ou da sessão.")
        end
        if (pattern = GLOBAL.find { |candidate| candidate.match?(code) })
          raise Graph::Error.single('db_plan_forbidden', "#{where}: instrução sobre objeto fora do banco ou da sessão (#{code[pattern].strip}).")
        end
        starts = statement_starts(step.sql)
        if (start = starts.find { |text| SESSION.match?(text) })
          raise Graph::Error.single('db_plan_forbidden', "#{where}: instrução de sessão ou de transação (#{start[SESSION]}).")
        end
        outside = starts.any? { |text| OUTSIDE_TRANSACTION.first.match?(text) || text.match?(/\A(DROP INDEX|REINDEX)\b.*\bCONCURRENTLY\b/i) }
        if step.transaction == 'nao'
          unless starts.size == 1 && OUTSIDE_TRANSACTION.any? { |pattern| pattern.match?(step.sql) }
            raise Graph::Error.single('db_plan_format', "#{where}: um passo transacao=nao tem uma só instrução, CREATE INDEX, DROP INDEX ou REINDEX com CONCURRENTLY.")
          end
        elsif outside
          raise Graph::Error.single('db_plan_format', "#{where}: CONCURRENTLY só roda num passo transacao=nao de um plano por_passo.")
        end
        raise Graph::Error.single('db_plan_format', "#{where}: transação #{step.transaction.inspect} incompatível com o plano #{transaction}.") unless
          (transaction == 'unica' && step.transaction.nil?) || (transaction == 'por_passo' && STEP_TRANSACTIONS.include?(step.transaction))
      end

      def render
        out = +"-- vetra:plano #{number} #{name}\n-- vetra:transacao #{transaction}\n"
        out << "--\n-- Gerado por `vetra db:plan` a partir de .vetra/graph.json. Revise antes de aplicar e confira com\n"
        out << "-- `vetra db:plan --check`. Cada passo diz a fase, o lock que pede numa tabela existente e o custo.\n"
        steps.each do |step|
          marker = "-- vetra:passo #{step.number} fase=#{step.phase} lock=#{step.lock} custo=#{step.cost}"
          marker += " transacao=#{step.transaction}" if step.transaction
          out << "\n#{marker}\n#{step.sql}\n"
        end
        out.freeze
      end

      # Lê um plano de db/plans/. Recusa nome, cabeçalho, marcadores ou valores fora do formato, para que o executor
      # nunca precise adivinhar onde um passo começa ou em que transação roda.
      def self.parse(text, file:)
        bad = ->(message) { raise Graph::Error.single('db_plan_format', "#{file}: #{message}") }
        file_match = NAME.match(File.basename(file)) or bad.call('o nome deve ser NNNN_nome.sql, em minúsculas.')
        bad.call('o plano deve ser UTF-8 válido e terminar em LF.') unless text.valid_encoding? && text.end_with?("\n") && !text.include?("\r")
        lines = text.lines(chomp: true)
        header = HEADER.match(lines[0].to_s) or bad.call('a primeira linha deve ser "-- vetra:plano NNNN nome".')
        bad.call('o número e o nome do cabeçalho devem ser os do arquivo.') unless header.captures == file_match.captures
        transaction = TRANSACTION.match(lines[1].to_s) or bad.call('a segunda linha deve ser "-- vetra:transacao unica" ou "por_passo".')
        bad.call("transação desconhecida: #{transaction[1]}.") unless TRANSACTIONS.include?(transaction[1])
        steps, current, scanner = [], nil, StatementScanner.new
        lines.drop(2).each_with_index do |line, offset|
          # Marcadores só contam entre instruções: dentro de um literal ou corpo de função, a linha é dado.
          if scanner.boundary? && (marker = STEP.match(line))
            number, phase, lock, cost, step_transaction = marker.captures
            bad.call("linha #{offset + 3}: passos numerados em sequência a partir de 1.") unless number.to_i == steps.size + 1
            bad.call("linha #{offset + 3}: fase desconhecida #{phase}.") unless PHASES.include?(phase)
            bad.call("linha #{offset + 3}: lock desconhecido #{lock}.") unless LOCKS.include?(lock)
            bad.call("linha #{offset + 3}: custo desconhecido #{cost}.") unless COSTS.include?(cost)
            if transaction[1] == 'unica' ? step_transaction : !STEP_TRANSACTIONS.include?(step_transaction)
              bad.call("linha #{offset + 3}: transacao=sim ou nao em cada passo de um plano por_passo, e em nenhum de um plano unica.")
            end
            steps << (current = { number: number.to_i, phase: phase, lock: lock, cost: cost, transaction: step_transaction, sql: [] })
          elsif scanner.boundary? && line.start_with?('-- vetra:')
            bad.call("linha #{offset + 3}: marcador desconhecido.")
          elsif current
            current[:sql] << line
            scanner.feed(line)
          elsif !(line.empty? || line.start_with?('--'))
            bad.call("linha #{offset + 3}: SQL antes do primeiro passo.")
          end
        end
        bad.call('o plano não tem passos.') if steps.empty?
        bad.call('o último passo termina dentro de um literal, comentário ou instrução sem ";".') unless scanner.boundary?
        built = steps.map do |step|
          sql = step[:sql].join("\n").strip
          bad.call("o passo #{step[:number]} está vazio.") if sql.empty?
          Step.new(**step, sql: sql)
        end
        new(number: header[1], name: header[2], transaction: transaction[1], steps: built)
      end
    end
  end
end

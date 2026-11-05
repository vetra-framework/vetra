# frozen_string_literal: true

module Vetra
  module SQL
    # Plano de migração revisável (ADR-015, §1, e ADR-025, §1): SQL com um cabeçalho e marcadores por passo, que dizem
    # a fase, o lock que o passo pede numa tabela existente e o custo. O texto é o artefato versionado em db/plans/.
    class Plan
      Step = Struct.new(:number, :phase, :lock, :cost, :sql, keyword_init: true)

      PHASES = %w[expand migrate contract].freeze
      # Nomes do PostgreSQL sem o sufixo Lock; "nenhum" quando o passo só cria objetos novos.
      LOCKS = %w[nenhum AccessShare RowShare RowExclusive ShareUpdateExclusive Share ShareRowExclusive Exclusive AccessExclusive].freeze
      # catalogo: só altera o catálogo; tabela_vazia: age sobre uma tabela criada no mesmo plano, ainda sem linhas.
      COSTS = %w[catalogo tabela_vazia].freeze
      TRANSACTIONS = %w[unica].freeze
      NAME = /\A(\d{4})_([a-z][a-z0-9_]*)\.sql\z/
      HEADER = /\A-- vetra:plano (\d{4}) ([a-z][a-z0-9_]*)\z/
      TRANSACTION = /\A-- vetra:transacao (\S+)\z/
      STEP = /\A-- vetra:passo (\d+) fase=(\S+) lock=(\S+) custo=(\S+)\z/
      INITIAL = { number: '0001', name: 'inicial' }.freeze

      # Classificação dos comandos do DDL de banco vazio (ADR-035). Em banco vazio todas as tabelas nascem no próprio
      # plano: as travas não esperam por leitores nem escritores, mas ficam registradas para o revisor e para a rodada 4.
      CLASSIFICATION = [
        [/\ADO \$vetra_(context_roles|database_privileges)\$/, 'nenhum', 'catalogo'],
        [/\ACREATE SCHEMA /, 'nenhum', 'catalogo'],
        [/\ACREATE EXTENSION /, 'nenhum', 'catalogo'],
        [/\ACREATE TABLE /, 'nenhum', 'catalogo'],
        [/\AALTER TABLE \S+ ADD CONSTRAINT \S+ UNIQUE /, 'AccessExclusive', 'tabela_vazia'],
        [/\ACREATE (UNIQUE )?INDEX /, 'Share', 'tabela_vazia'],
        [/\AALTER TABLE \S+ ADD CONSTRAINT \S+ FOREIGN KEY /, 'ShareRowExclusive', 'tabela_vazia'],
        [/\AALTER TABLE \S+ OWNER TO /, 'AccessExclusive', 'tabela_vazia'],
        [/\AALTER SCHEMA \S+ OWNER TO /, 'nenhum', 'catalogo'],
        [/\ACREATE FUNCTION /, 'nenhum', 'catalogo'],
        [/\AALTER FUNCTION \S+ OWNER TO /, 'nenhum', 'catalogo'],
        [/\A(REVOKE|GRANT) .+ ON (SCHEMA|TABLE|FUNCTION) /, 'nenhum', 'catalogo']
      ].freeze

      attr_reader :number, :name, :transaction, :steps

      def initialize(number:, name:, transaction:, steps:)
        @number, @name, @transaction = number, name, transaction
        @steps = Graph::Data.freeze(steps)
        freeze
      end

      def file_name
        "#{number}_#{name}.sql"
      end

      # Primeiro plano de uma aplicação, a partir do resultado de Vetra::SQL::Schema.
      def self.initial(schema)
        statements = Context.prefix + schema.blocks.flat_map { |block| block['statements'] } + Context.suffix(schema.tables)
        steps = statements.each_with_index.map do |sql, index|
          _, lock, cost = CLASSIFICATION.find { |pattern, *| pattern.match?(sql) }
          raise Graph::Error.single('db_plan_step', "Comando do esquema sem classificação de lock: #{sql.lines.first.strip}") unless lock
          Step.new(number: index + 1, phase: 'expand', lock: lock, cost: cost, sql: sql)
        end
        new(**INITIAL, transaction: 'unica', steps: steps)
      end

      def render
        out = +"-- vetra:plano #{number} #{name}\n-- vetra:transacao #{transaction}\n"
        out << "--\n-- Gerado por `vetra db:plan` a partir de .vetra/graph.json. Revise antes de aplicar e confira com\n"
        out << "-- `vetra db:plan --check`. Cada passo diz a fase, o lock que pede numa tabela existente e o custo.\n"
        steps.each do |step|
          out << "\n-- vetra:passo #{step.number} fase=#{step.phase} lock=#{step.lock} custo=#{step.cost}\n#{step.sql}\n"
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
        transaction = TRANSACTION.match(lines[1].to_s) or bad.call('a segunda linha deve ser "-- vetra:transacao unica".')
        bad.call("transação desconhecida: #{transaction[1]}.") unless TRANSACTIONS.include?(transaction[1])
        steps, current, scanner = [], nil, StatementScanner.new
        lines.drop(2).each_with_index do |line, offset|
          # Marcadores só contam entre instruções: dentro de um literal ou corpo de função, a linha é dado.
          if scanner.boundary? && (marker = STEP.match(line))
            number, phase, lock, cost = marker.captures
            bad.call("linha #{offset + 3}: passos numerados em sequência a partir de 1.") unless number.to_i == steps.size + 1
            bad.call("linha #{offset + 3}: fase desconhecida #{phase}.") unless PHASES.include?(phase)
            bad.call("linha #{offset + 3}: lock desconhecido #{lock}.") unless LOCKS.include?(lock)
            bad.call("linha #{offset + 3}: custo desconhecido #{cost}.") unless COSTS.include?(cost)
            steps << (current = { number: number.to_i, phase: phase, lock: lock, cost: cost, sql: [] })
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

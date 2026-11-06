# frozen_string_literal: true

require 'digest'
require 'json'

module Vetra
  module SQL
    # Modelo físico versionado de um plano (ADR-038, §1): o esquema que o banco tem depois do plano, a cadeia de
    # planos até ele e o modelo anterior. É gerado pelo db:plan, nunca editado à mão e nunca aplicado: serve de base
    # para a diferença do próximo plano, e a cadeia prende os planos que já não podem ser regenerados.
    class Model
      FORMAT = 'vetra-db-model'
      VERSION = 1
      DIRECTORY = 'db/models'
      KEYS = %w[format plan plans previous state version].freeze
      NAME = /\A(\d{4})_([a-z][a-z0-9_]*)\.json\z/
      Q = '"([a-z][a-z0-9_]*)"'

      # Tipo e objeto de cada instrução gerada. Uma instrução sem tipo é erro, como uma sem classificação de lock.
      KINDS = [
        [/\ADO \$(vetra_[a-z_]+)\$/, 'guard', ->(m) { m[1] }],
        [/\ACREATE SCHEMA #{Q}/o, 'schema', ->(m) { m[1] }],
        [/\ACREATE EXTENSION #{Q}/o, 'extension', ->(m) { m[1] }],
        [/\ACREATE TABLE #{Q}\.#{Q}/o, 'table', ->(m) { "#{m[1]}.#{m[2]}" }],
        [/\AALTER TABLE #{Q}\.#{Q} ADD CONSTRAINT #{Q}/o, 'constraint', ->(m) { "#{m[1]}.#{m[2]}.#{m[3]}" }],
        [/\ACREATE (?:UNIQUE )?INDEX (?:CONCURRENTLY )?#{Q} ON #{Q}\./o, 'index', ->(m) { "#{m[2]}.#{m[1]}" }],
        [/\ACREATE FUNCTION #{Q}\.#{Q}\(([^)]*)\)/o, 'function', ->(m) { "#{m[1]}.#{m[2]}(#{m[3]})" }],
        [/\ACREATE POLICY #{Q} ON #{Q}\.#{Q}/o, 'policy', ->(m) { "#{m[2]}.#{m[3]}.#{m[1]}" }],
        [/\ACREATE TRIGGER #{Q} .*? ON #{Q}\.#{Q}/mo, 'trigger', ->(m) { "#{m[2]}.#{m[3]}.#{m[1]}" }],
        [/\AALTER TABLE #{Q}\.#{Q} ENABLE ALWAYS TRIGGER #{Q}/o, 'trigger_mode', ->(m) { "#{m[1]}.#{m[2]}.#{m[3]}" }],
        [/\AALTER TABLE #{Q}\.#{Q} (ENABLE|FORCE) ROW LEVEL SECURITY/o, 'row_security', ->(m) { "#{m[1]}.#{m[2]}.#{m[3].downcase}" }],
        [/\AALTER (TABLE|SCHEMA|FUNCTION) (\S+) OWNER TO /, 'owner', ->(m) { "#{m[1].downcase} #{m[2].delete('"')}" }],
        [/\A(?:GRANT|REVOKE) /, 'privilege', nil],
        [/\ALOCK TABLE /, 'lock', nil],
        [/\AINSERT INTO #{Q}\.#{Q}/o, 'seed', ->(m) { "#{m[1]}.#{m[2]}" }]
      ].freeze

      # O estado descrito pelo plano inicial de um esquema: as tabelas estruturadas do ADR-035 e, na ordem do plano,
      # o tipo, o objeto e o SHA-256 de cada instrução, inclusive infraestrutura, segurança e revisão.
      def self.state(schema, plan)
        statements = plan.steps.map do |step|
          pattern, kind, object = KINDS.find { |candidate, *| candidate.match?(step.sql) }
          raise Graph::Error.single('db_plan_step', "Instrução sem tipo no modelo: #{step.sql.lines.first.strip}") unless pattern
          { 'kind' => kind, 'object' => object&.call(pattern.match(step.sql)), 'sha256' => Digest::SHA256.hexdigest(step.sql) }
        end
        Graph::Data.freeze({ 'tables' => Graph::Data.copy(schema.tables), 'statements' => statements })
      end

      def self.file_name(plan_file)
        plan_file.sub(/\.sql\z/, '.json')
      end

      # O modelo do plano, encadeado ao anterior: repete a cadeia dele e acrescenta o próprio plano.
      def self.build(plan, state, previous: nil)
        entry = { 'file' => plan.file_name, 'sha256' => Digest::SHA256.hexdigest(plan.render) }
        link = previous && { 'file' => previous.file, 'sha256' => Digest::SHA256.hexdigest(previous.text) }
        document = { 'format' => FORMAT, 'version' => VERSION, 'plan' => entry,
                     'plans' => (previous ? previous.document['plans'] : []) + [entry], 'previous' => link, 'state' => state }
        new(file: file_name(plan.file_name), text: render(document))
      end

      def self.render(document)
        "#{JSON.pretty_generate(Graph::Canonical.parse(Graph::Canonical.dump(document)))}\n"
      end

      attr_reader :file, :text, :document

      # Lê e confere um modelo de db/models/. Só aceita o formato canônico: um arquivo editado à mão é recusado.
      def initialize(file:, text:)
        bad = ->(message) { raise Graph::Error.single('db_model_format', "#{DIRECTORY}/#{file}: #{message}") }
        bad.call('o nome deve ser NNNN_nome.json, como o do plano.') unless NAME.match?(file)
        document = Graph::Canonical.parse(text) rescue bad.call('JSON inválido.')
        bad.call('fora do formato canônico; o modelo é gerado por vetra db:plan.') unless document.is_a?(Hash) && self.class.render(document) == text
        bad.call("chaves esperadas: #{KEYS.join(', ')}.") unless document.keys.sort == KEYS
        bad.call("formato #{document['format'].inspect} versão #{document['version'].inspect}; esperado #{FORMAT} #{VERSION}.") unless
          document['format'] == FORMAT && document['version'] == VERSION
        entry = ->(value) { value.is_a?(Hash) && value.keys.sort == %w[file sha256] && value['file'].is_a?(String) && value['sha256'].to_s.match?(/\A[0-9a-f]{64}\z/) }
        bad.call('plan deve ter file e sha256.') unless entry.call(document['plan']) && document['plan']['file'] == file.sub(/\.json\z/, '.sql')
        bad.call('plans deve ser a lista de planos com file e sha256.') unless document['plans'].is_a?(Array) && document['plans'].all?(&entry)
        bad.call('previous deve ser null ou ter file e sha256.') unless document['previous'].nil? || entry.call(document['previous'])
        state = document['state']
        valid_state = state.is_a?(Hash) && state.keys.sort == %w[statements tables] && state['tables'].is_a?(Array) &&
                      state['statements'].is_a?(Array) && state['statements'].all? do |statement|
                        statement.is_a?(Hash) && statement.keys.sort == %w[kind object sha256] && statement['sha256'].to_s.match?(/\A[0-9a-f]{64}\z/)
                      end
        bad.call('state deve ter tables e statements.') unless valid_state
        @file, @text, @document = file, text.dup.freeze, Graph::Data.freeze(document)
        freeze
      end

      def state
        document['state']
      end

      def same_state?(other_state)
        Graph::Canonical.dump(state) == Graph::Canonical.dump(other_state)
      end
    end
  end
end

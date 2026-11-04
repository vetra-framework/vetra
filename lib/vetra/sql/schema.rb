# frozen_string_literal: true

require 'digest'

module Vetra
  module SQL
    # Mapeamento físico do ADR-035. Não lê fontes, ambiente, relógio ou banco.
    class Schema
      Result = Struct.new(:tables, :blocks, :sql, :warnings, keyword_init: true)
      TYPES = {
        'id' => 'uuid', 'string' => 'text', 'text' => 'text', 'email' => 'text',
        'integer' => 'bigint', 'boolean' => 'boolean', 'date' => 'date',
        'timestamp' => 'timestamp(6) with time zone', 'json' => 'jsonb', 'enum' => 'text'
      }.freeze
      TEXT_TYPES = %w[string text email enum].freeze
      SYSTEM_COLUMNS = %w[tableoid xmin cmin xmax cmax ctid].freeze
      LITERAL_ESCAPES = { "'" => "''", '\\' => '\\\\', "\n" => '\\n', "\r" => '\\r', "\t" => '\\t' }.freeze

      def initialize(document)
        @document = Graph::Data.copy(document)
      end

      def generate
        warnings = Graph::Validator.new.validate!(@document)
        @positions = {}
        @document['nodes'].each_with_index { |node, i| @positions[node['id']] = "/nodes/#{i}" if node['kind'] == 'entity' }
        @entities = @document['nodes'].select { |node| node['kind'] == 'entity' }.to_h { |node| [node['id'], node] }
        @root = @document.dig('app', 'tenant', 'entity', 'id')
        @relations, @constraints = {}, {}
        ordered = @entities.values.sort_by { |entity| entity['storage'].values_at('schema', 'table') + [entity['id']] }
        # Reserva todas as tabelas antes dos nomes de índices (mesmo namespace no PostgreSQL).
        ordered.each do |entity|
          @current = entity
          storage = entity['storage']
          storage.values_at('schema', 'table').each { |name| identifier!(name) }
          if storage['schema'].start_with?('pg_') || %w[information_schema vetra vetra_private].include?(storage['schema'])
            fail!('schema_reserved', 'Schema reservado ao PostgreSQL ou à infraestrutura do Vetra.', '/storage/schema')
          end
          reserve!(@relations, storage.values_at('schema', 'table'))
        end
        @tables = ordered.map { |entity| table(entity) }
        @by_entity = @tables.to_h { |table| [table['entity'], table] }
        @tables.each { |table| foreign_keys(table) }
        @tables.each do |table|
          table['unique_keys'].sort_by! { |key| key['name'] }
          table['indexes'].sort_by! { |index| index['name'] }
          table['foreign_keys'].sort_by! { |key| key['name'] }
        end
        schemas = @tables.map { |table| table['schema'] }.uniq.sort.reject { |schema| schema == 'public' }
        blocks = [
          block('schemas', schemas.map { |schema| "CREATE SCHEMA #{quote(schema)};" }),
          block('tables', @tables.flat_map { |table| table_sql(table) }),
          block('foreign_keys', @tables.flat_map { |table| table['foreign_keys'].map { |key| foreign_key_sql(table, key) } })
        ]
        Graph::Data.freeze(Result.new(tables: @tables, blocks: blocks, sql: blocks.map { |part| part['sql'] }.join, warnings: warnings))
      end

      private

      def fail!(code, message, suffix = '')
        raise Graph::Error.single(code, message, pointer: "#{@positions[@current['id']]}#{suffix}", source: @current['source'])
      end

      def identifier!(name)
        unless name.is_a?(String) && name.match?(/\A[a-z][a-z0-9_]*\z/) && name.bytesize <= 63
          fail!('schema_identifier', 'Identificador SQL deve começar por letra, usar minúsculas ASCII, números ou sublinhado e ter até 63 bytes.')
        end
        name
      end

      def quote(name)
        %Q{"#{identifier!(name)}"}
      end

      def relation(table)
        "#{quote(table['schema'])}.#{quote(table['table'])}"
      end

      def reserve!(registry, key)
        fail!('schema_collision', "Nome físico em colisão: #{key.join('.')}.") if registry.key?(key)
        registry[key] = true
      end

      # A identidade depende da estrutura física, nunca da ordem dos nós ou do ordinal do índice na IR.
      def name_for(table, kind, *parts)
        identity = [table['schema'], table['table'], kind, *parts]
        identifier!("vt_#{kind}_#{Digest::SHA256.hexdigest(Graph::Canonical.dump(identity))[0, 32]}")
      end

      def constraint_name(table, kind, *parts, index: false)
        name = name_for(table, kind, *parts)
        reserve!(@constraints, [table['schema'], table['table'], name])
        reserve!(@relations, [table['schema'], name]) if index
        name
      end

      def table(entity)
        @current = entity
        entity['fields'].each do |field|
          identifier!(field['name'])
          if SYSTEM_COLUMNS.include?(field['name'])
            fail!('schema_reserved', 'Nome de coluna de sistema do PostgreSQL reservado.', '/fields')
          end
        end
        id = entity['fields'].find { |field| field['name'] == 'id' }
        unless entity.dig('storage', 'primary_key') == ['id'] && id && id.dig('type', 'name') == 'id' && !id['nullable'] && !id.key?('default')
          fail!('schema_primary_key', 'Mapeamento inicial exige PK simples id, tipo id, não nula e sem default declarado.', '/storage/primary_key')
        end
        scope = entity['id'] == @root ? 'tenant_root' : (entity['tenant'] ? 'tenant' : 'global')
        result = entity['storage'].slice('schema', 'table').merge(
          'entity' => entity['id'], 'scope' => scope,
          'tenant_column' => scope == 'tenant_root' ? 'id' : entity.dig('tenant', 'field'),
          'columns' => [], 'checks' => [], 'unique_keys' => [], 'indexes' => [], 'foreign_keys' => [],
          'assignments' => {}, 'transitions' => Graph::Data.copy(entity['transitions'])
        )
        entity['fields'].sort_by { |field| field['name'] }.each { |field| columns(result, field) }
        names = result['columns'].map { |column| column['name'] }
        fail!('schema_collision', 'Colunas físicas em colisão, inclusive desdobramento de money.', '/fields') if names.uniq.size != names.size
        result['primary_key'] = { 'name' => constraint_name(result, 'pk', ['id'], index: true), 'columns' => ['id'] }
        entity['indexes'].sort_by { |index| index['name'] }.each do |index|
          identifier!(index['name'])
          fail!('schema_partial_index', 'Índices parciais ainda não têm tradução física; remova where ou aguarde suporte explícito.', '/indexes') if index.key?('where')
          add_index(result, expand(entity, index['fields']), unique: index['unique'])
        end
        entity['fields'].select { |field| field.dig('constraints', 'unique') }.each do |field|
          fields = [entity.dig('tenant', 'field'), field['name']].compact.uniq
          add_index(result, expand(entity, fields), unique: true)
        end
        if entity['tenant']
          add_index(result, [entity.dig('tenant', 'field'), 'id'], unique: true)
        end
        result['checks'].sort_by! { |check| check['name'] }
        result
      end

      def expand(entity, fields)
        fields.flat_map do |name|
          field = entity['fields'].find { |entry| entry['name'] == name }
          field.dig('type', 'name') == 'money' ? ["#{name}_amount", "#{name}_currency"] : [name]
        end
      end

      def add_index(table, columns, unique: false)
        list = table[unique ? 'unique_keys' : 'indexes']
        return if list.any? { |key| key['columns'] == columns }
        kind = unique ? 'uq' : 'ix'
        name = constraint_name(table, kind, columns, index: true)
        list << { 'name' => name, 'columns' => columns }
      end

      def check(table, kind, field, expression)
        name = constraint_name(table, 'ck', kind, field)
        table['checks'] << { 'name' => name, 'expression' => expression }
      end

      def columns(table, field)
        name, type = field.values_at('name', 'type')
        logical = type['name']
        constraints = field.fetch('constraints', {})
        if (constraints.keys & %w[min_length max_length]).any? && !TEXT_TYPES.include?(logical)
          fail!('schema_constraints', 'Limites de comprimento exigem string, text, email ou enum.', '/fields')
        end
        if field['normalize'] && !TEXT_TYPES.include?(logical)
          fail!('schema_normalize', 'Normalização downcase exige coluna textual.', '/fields')
        end
        table['assignments'][name] = Graph::Data.copy(field.slice('default', 'generate', 'normalize', 'set_by', 'guarded'))
        default = field['default']
        literal = default && default['kind'] == 'literal'
        validate_default!(field) if literal
        sql_type = %w[decimal money].include?(logical) ? "numeric(#{type['precision']}, #{type['scale']})" : TYPES.fetch(logical)
        if logical == 'money'
          amount, currency = "#{name}_amount", "#{name}_currency"
          column(table, field, amount, sql_type, literal ? scalar_default(default['value'] && default['value']['amount'], 'decimal') : nil)
          column(table, field, currency, 'text', literal ? scalar_default(default['value'] && default['value']['currency'], 'string') : nil)
          check(table, 'money_pair', name, "(#{quote(amount)} IS NULL) = (#{quote(currency)} IS NULL)")
          currencies = Graph::Currency::EXPONENTS.select { |_code, exponent| exponent <= type['scale'] }.keys.sort
          check(table, 'money_currency', name, "#{quote(currency)} IN (#{currencies.map { |code| text_literal(code) }.join(', ')})")
        else
          sql_default = literal ? scalar_default(default['value'], logical) : nil
          sql_default = 'pg_catalog.gen_random_uuid()' if name == 'id'
          column(table, field, name, sql_type, sql_default)
          if logical == 'enum'
            check(table, 'enum', name, "#{quote(name)} IN (#{type['values'].sort.map { |value| text_literal(value) }.join(', ')})")
          end
        end
        if %w[decimal money].include?(logical)
          numeric_column = logical == 'money' ? "#{name}_amount" : name
          check(table, 'finite', name, "#{quote(numeric_column)} <> 'NaN'::numeric")
        end
        %w[min_length max_length].each do |key|
          next unless constraints.key?(key)
          operator = key == 'min_length' ? '>=' : '<='
          check(table, key, name, "pg_catalog.char_length(#{quote(name)}) #{operator} #{constraints[key]}")
        end
        check(table, 'downcase', name, "#{quote(name)} = pg_catalog.lower(#{quote(name)})") if field['normalize']
      end

      def column(table, field, name, type, default)
        identifier!(name)
        table['columns'] << { 'name' => name, 'field' => field['name'], 'type' => type, 'nullable' => field['nullable'], 'default' => default }
      end

      def validate_default!(field)
        value, logical = field.dig('default', 'value'), field.dig('type', 'name')
        return if value.nil?
        valid = case logical
        when 'id' then value.match?(/\A[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}\z/)
        when 'date' then Date.iso8601(value).year.between?(1, 9999)
        when 'timestamp'
          value.match?(/(?:Z|[+-]\d{2}:\d{2})\z/) && value.match?(/\A\d{4}-/) &&
            Time.iso8601(value).utc.year.between?(1, 9999) && (Time.iso8601(value).nsec % 1000).zero? &&
            !value.match?(/\.\d{7}/)
        else true
        end
        if TEXT_TYPES.include?(logical)
          constraints = field.fetch('constraints', {})
          valid &&= value.length >= constraints.fetch('min_length', 0)
          valid &&= !constraints.key?('max_length') || value.length <= constraints['max_length']
          valid &&= value == value.downcase if field['normalize']
        end
        fail!('schema_default', 'Default incompatível com UUID, data, timestamp com fuso/microssegundos, comprimento ou normalização físicos.', '/fields') unless valid
      end

      def scalar_default(value, type)
        return 'NULL' if value.nil?
        case type
        when 'boolean' then value ? 'TRUE' : 'FALSE'
        when 'integer', 'decimal' then value.to_s
        when 'json'
          validate_text!(value)
          "#{text_literal(Graph::Canonical.dump(value))}::jsonb"
        when 'id' then "#{text_literal(value.downcase)}::uuid"
        when 'date' then "#{text_literal(value)}::date"
        when 'timestamp' then "#{text_literal(Time.iso8601(value).utc.iso8601(6))}::timestamp(6) with time zone"
        else text_literal(value)
        end
      end

      def validate_text!(value)
        case value
        when Hash then value.each { |key, child| validate_text!(key); validate_text!(child) }
        when Array then value.each { |child| validate_text!(child) }
        when String
          fail!('schema_literal', 'PostgreSQL text/jsonb não armazena U+0000.', '/fields') if value.include?("\0")
        end
      end

      def text_literal(value)
        validate_text!(value)
        # E-string explícita: independe de standard_conforming_strings, sem SQL fornecido pelo grafo. Caracteres de
        # controle saem como escapes, para que o plano seja texto de linhas LF sem bytes de controle dentro de literais.
        "E'#{value.gsub(/[\\'\x01-\x1f\x7f]/) { |character| LITERAL_ESCAPES.fetch(character) { format('\\x%02X', character.ord) } }}'"
      end

      def foreign_keys(table)
        entity = @entities.fetch(table['entity'])
        @current = entity
        if entity['tenant']
          add_foreign_key(table, [entity.dig('tenant', 'field')], @by_entity.fetch(@root), ['id'])
        end
        entity['relations'].select { |rel| rel['kind'] == 'belongs_to' }.sort_by { |rel| rel['name'] }.each do |rel|
          target = @by_entity.fetch(rel.dig('target', 'id'))
          local = expand(entity, rel['local_fields'])
          remote = expand(@entities.fetch(target['entity']), rel['target_fields'])
          add_foreign_key(table, local, target, remote)
        end
      end

      def add_foreign_key(table, columns, target, target_columns)
        pairs = columns.zip(target_columns)
        types_match = columns.size == target_columns.size && pairs.all? do |local, remote|
          table['columns'].find { |column| column['name'] == local }['type'] == target['columns'].find { |column| column['name'] == remote }['type']
        end
        fail!('schema_fk_type', 'Colunas de FK exigem os mesmos tipos e modificadores físicos.', '/relations') unless types_match
        unless target['primary_key']['columns'] == target_columns || target['unique_keys'].any? { |key| key['columns'] == target_columns }
          fail!('schema_fk_target', 'Destino da FK exige PK ou chave única integral na mesma ordem.', '/relations')
        end
        return if table['foreign_keys'].any? { |key| key['columns'] == columns && key['target'] == target.values_at('schema', 'table') && key['target_columns'] == target_columns }
        name = constraint_name(table, 'fk', columns, target.values_at('schema', 'table'), target_columns)
        table['foreign_keys'] << {
          'name' => name, 'columns' => columns, 'target' => target.values_at('schema', 'table'), 'target_columns' => target_columns,
          'match' => 'SIMPLE', 'on_delete' => 'NO ACTION', 'on_update' => 'NO ACTION', 'deferrable' => true, 'initially' => 'IMMEDIATE'
        }
        # Evita índices redundantes quando PK/índice já cobre o prefixo da FK.
        keys = [table['primary_key'], *table['unique_keys'], *table['indexes']]
        add_index(table, columns) unless keys.any? { |key| key['columns'].take(columns.size) == columns }
      end

      def block(kind, statements)
        { 'kind' => kind, 'statements' => statements, 'sql' => statements.empty? ? '' : statements.join("\n") + "\n" }
      end

      def table_sql(table)
        @current = @entities.fetch(table['entity'])
        definitions = table['columns'].map do |column|
          sql = "#{quote(column['name'])} #{column['type']}"
          sql += ' NOT NULL' unless column['nullable']
          sql += " DEFAULT #{column['default']}" if column['default']
          sql
        end
        pk = table['primary_key']
        definitions << "CONSTRAINT #{quote(pk['name'])} PRIMARY KEY (#{quoted_columns(pk['columns'])})"
        definitions.concat(table['checks'].map { |check| "CONSTRAINT #{quote(check['name'])} CHECK (#{check['expression']})" })
        statements = ["CREATE TABLE #{relation(table)} (\n  #{definitions.join(",\n  ")}\n);"]
        table['unique_keys'].each do |key|
          statements << "ALTER TABLE #{relation(table)} ADD CONSTRAINT #{quote(key['name'])} UNIQUE (#{quoted_columns(key['columns'])});"
        end
        table['indexes'].each do |index|
          statements << "CREATE INDEX #{quote(index['name'])} ON #{relation(table)} (#{quoted_columns(index['columns'])});"
        end
        statements
      end

      def quoted_columns(columns)
        columns.map { |column| quote(column) }.join(', ')
      end

      def foreign_key_sql(table, key)
        "ALTER TABLE #{relation(table)} ADD CONSTRAINT #{quote(key['name'])} FOREIGN KEY (#{quoted_columns(key['columns'])}) " \
          "REFERENCES #{key['target'].map { |part| quote(part) }.join('.')} (#{quoted_columns(key['target_columns'])}) " \
          "MATCH #{key['match']} ON DELETE #{key['on_delete']} ON UPDATE #{key['on_update']} DEFERRABLE INITIALLY IMMEDIATE;"
      end
    end
  end
end

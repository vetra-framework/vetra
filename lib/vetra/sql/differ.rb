# frozen_string_literal: true

module Vetra
  module SQL
    # Diferença expand do ADR-038. O modelo só fornece estrutura e identidades: todo SQL executável vem do
    # gerador atual. Uma recusa aborta a construção inteira, antes de o Planner gravar qualquer artefato.
    class Differ
      CHECK_KINDS = %w[enum money_pair money_currency finite min_length max_length downcase].freeze
      LITERAL = /E'(?:[^'\\]|\\.|'')*'/m
      GUARDS = %w[vetra_context_roles vetra_database_privileges vetra_roles vetra_shared_schema vetra_tables vetra_privileges vetra_routines].freeze

      def self.call(base:, schema:, number:)
        new(base, schema, number).plan
      end

      def initialize(base, schema, number)
        @base, @schema, @number = base.state, schema, number
        @initial = Plan.initial(schema)
        @state = Model.state(schema, @initial)
        @old = @base['tables'].to_h { |table| [table['entity'], table] }
        @new = schema.tables.to_h { |table| [table['entity'], table] }
        @steps = []
        # A seção da outbox (ADR-040, §5) é reconhecida pelo texto exato que o gerador atual produz.
        outbox = Outbox.new(schema)
        @outbox, @outbox_storage = outbox.digests, outbox.storage_digests
        # A seção da idempotência (ADR-043) também é reconhecida pelo texto exato do gerador atual.
        @idempotency = Idempotency.new(schema).digests
        @rate_limit = RateLimit.new(schema).digests
        # Num plano por passo o GRANT só pode tornar uma tabela nova acessível depois de toda a proteção.
        @new_table_grants = @new.reject { |id, _| @old.key?(id) }.values.map do |table|
          "GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE #{relation(table)} TO #{quote('vetra_app')};"
        end
      end

      def plan
        tables!
        instructions!
        fail!('db_plan_change', 'modelo alterado sem passos SQL seguros') if @steps.empty?
        Plan.new(number: @number, name: 'expand', transaction: 'por_passo', steps: @steps)
      end

      private

      def fail!(code, detail)
        raise Graph::Error.single(code, "Diferença incremental recusada: #{detail}. Nenhum plano foi gravado")
      end

      def quote(name)
        Context.quote(name)
      end

      def relation(table)
        table.values_at('schema', 'table').map { |name| quote(name) }.join('.')
      end

      def emit(sql, existing: true, transaction: 'sim', lock: nil)
        if @revision_sql
          @revision_sql << sql
          return
        end
        classified, cost = Plan.classify(sql, existing: existing)
        lock ||= classified
        @steps << Plan::Step.new(number: @steps.size + 1, phase: 'expand', lock: lock, cost: cost, sql: sql, transaction: transaction)
      end

      def entries(table, key)
        table.fetch(key).to_h { |entry| [entry['name'], entry] }
      end

      def additions(old, current, label)
        fail!('db_plan_remove', "remoção de #{label}") unless (old.keys - current.keys).empty?
        (old.keys & current.keys).each do |key|
          fail!('db_plan_change', "alteração de #{label} #{key}") unless old[key] == current[key]
        end
        current.reject { |name, _| old.key?(name) }.values
      end

      def tables!
        # A identidade lógica conserva a distinção entre renomeação declarada/física e remoção + adição.
        removed = @old.keys - @new.keys
        if removed.any?
          renamed = @schema.document['nodes'].any? do |node|
            node['kind'] == 'entity' && (node.fetch('previous_ids', []) & removed).any?
          end
          fail!('db_plan_rename', 'entidade renomeada') if renamed
          fail!('db_plan_remove', 'entidade removida')
        end
        old_root = @old.values.find { |table| table['scope'] == 'tenant_root' }&.fetch('entity')
        new_root = @new.values.find { |table| table['scope'] == 'tenant_root' }&.fetch('entity')
        fail!('db_plan_tenant', 'mudança da raiz do tenant') unless old_root == new_root
        @old.each do |id, before|
          after = @new.fetch(id)
          fail!('db_plan_tenant', "mudança de tenant em #{id}") unless before.values_at('scope', 'tenant_column') == after.values_at('scope', 'tenant_column')
          fail!('db_plan_rename', "renomeação física de #{id}") unless before.values_at('schema', 'table') == after.values_at('schema', 'table')
          fail!('db_plan_change', "mudança de chave primária em #{id}") unless before['primary_key'] == after['primary_key']
        end
        # Schemas e todas as tabelas antes de qualquer chave: também funciona com FKs cíclicas.
        @initial.steps.each_with_index do |step, index|
          statement = @state['statements'][index]
          if statement['kind'] == 'schema' && !@base['statements'].include?(statement)
            fail!('db_plan_statement', 'schema de infraestrutura alterado') if %w[vetra vetra_private].include?(statement['object'])
            emit(step.sql, existing: false)
          elsif statement['kind'] == 'table' && @new.values.any? { |table| !@old.key?(table['entity']) && statement['object'] == table.values_at('schema', 'table').join('.') }
            emit(step.sql, existing: false)
          end
        end
        @new.each do |id, table|
          columns!(@old.fetch(id), table) if @old.key?(id)
        end
        # Todos os índices de apoio/UNIQUE são construídos antes de qualquer FK (ADR-025, §4).
        @new.each do |id, table|
          before = @old[id]
          %w[unique_keys indexes].each do |kind|
            added = additions(before ? entries(before, kind) : {}, entries(table, kind), "#{kind} de #{id}")
            added.each { |key| index!(table, key, unique: kind == 'unique_keys', existing: !before.nil?) }
          end
        end
        @new.each do |id, table|
          before = @old[id]
          added = additions(before ? entries(before, 'foreign_keys') : {}, entries(table, 'foreign_keys'), "FK de #{id}")
          added.each do |key|
            object = table.values_at('schema', 'table').join('.') + ".#{key['name']}"
            sql = @initial.steps.zip(@state['statements']).find { |_, item| item['kind'] == 'constraint' && item['object'] == object }.first.sql
            emit(sql.delete_suffix(';') + ' NOT VALID;')
            emit("ALTER TABLE #{relation(table)} VALIDATE CONSTRAINT #{quote(key['name'])};")
          end
        end
      end

      def columns!(before, table)
        old, current = entries(before, 'columns'), entries(table, 'columns')
        removed = old.keys - current.keys
        if removed.any?
          entity = @schema.document['nodes'].find { |node| node['id'] == table['entity'] }
          # previous_names usa campos lógicos; money desdobra cada um em duas colunas físicas.
          removed_fields = removed.map { |name| old.fetch(name)['field'] }.uniq
          renamed = entity['fields'].any? { |field| (field.fetch('previous_names', []) & removed_fields).any? }
          fail!('db_plan_rename', "coluna renomeada de #{table['entity']}") if renamed
          if (removed_fields & current.values.map { |column| column['field'] }).any?
            fail!('db_plan_type', "representação física de campo em #{table['entity']}")
          end
          fail!('db_plan_remove', "coluna de #{table['entity']}")
        end
        (old.keys & current.keys).each do |name|
          a, b = old[name], current[name]
          fail!('db_plan_type', "tipo de #{table['entity']}.#{name}") unless a['type'] == b['type']
          fail!('db_plan_change', "nulidade, default ou identidade de #{table['entity']}.#{name}") unless a == b
        end
        added = current.reject { |name, _| old.key?(name) }.values
        added.each do |column|
          field = @schema.document['nodes'].find { |node| node['id'] == table['entity'] }['fields'].find { |item| item['name'] == column['field'] }
          constant = field.dig('default', 'kind') == 'literal' && !field.dig('default', 'value').nil?
          fail!('db_plan_backfill', "#{table['entity']}.#{column['name']} NOT NULL sem default constante não nulo") unless column['nullable'] || constant
          sql = "ALTER TABLE #{relation(table)} ADD COLUMN #{quote(column['name'])} #{column['type']}"
          sql += ' NOT NULL' unless column['nullable']
          sql += " DEFAULT #{column['default']}" if column['default']
          emit(sql + ';')
        end
        checks!(before, table, added.map { |column| column['field'] })
        # Metadados de atribuição não podem mudar silenciosamente, mesmo quando o tipo físico não muda.
        before['assignments'].each do |field, assignment|
          after = table['assignments'].fetch(field)
          fail!('db_plan_change', "atribuição de #{table['entity']}.#{field}") unless assignment == after
        end
        fail!('db_plan_remove', "remoção de reforço de transições de #{table['entity']}") if before.dig('transitions', 'enforce') == 'db' && table.dig('transitions', 'enforce') != 'db'
      end

      def enum_values(check)
        match = /\A"[a-z][a-z0-9_]*" IN \((.*)\)\z/m.match(check['expression'])
        return unless match
        values = match[1].scan(LITERAL)
        values if values.join(', ') == match[1]
      end

      def check_name(table, kind, field)
        "vt_ck_#{Digest::SHA256.hexdigest(Graph::Canonical.dump([table['schema'], table['table'], 'ck', kind, field]))[0, 32]}"
      end

      def checks!(before, table, added_fields)
        old, current = entries(before, 'checks'), entries(table, 'checks')
        fail!('db_plan_remove', "CHECK de #{table['entity']}") unless (old.keys - current.keys).empty?
        current.each do |name, check|
          if !old.key?(name)
            field = added_fields.find do |candidate|
              CHECK_KINDS.any? do |kind|
                name == check_name(table, kind, candidate)
              end
            end
            fail!('db_plan_change', "CHECK novo sobre coluna existente de #{table['entity']}") unless field
            emit("ALTER TABLE #{relation(table)} ADD CONSTRAINT #{quote(name)} CHECK (#{check['expression']}) NOT VALID;")
            emit("ALTER TABLE #{relation(table)} VALIDATE CONSTRAINT #{quote(name)};")
          elsif check != old[name]
            is_enum = table['columns'].any? { |column| name == check_name(table, 'enum', column['field']) }
            previous, following = enum_values(old[name]), enum_values(check)
            fail!('db_plan_change', "CHECK sem tradução segura em #{table['entity']}") unless is_enum && previous && following
            fail!('db_plan_enum', "enum estreitado ou valor renomeado em #{table['entity']}") unless (previous - following).empty?
            temporary = "vt_expand_#{Digest::SHA256.hexdigest(Graph::Canonical.dump([name, check['expression']]))[0, 32]}"
            emit("ALTER TABLE #{relation(table)} ADD CONSTRAINT #{quote(temporary)} CHECK (#{check['expression']}) NOT VALID;")
            emit("ALTER TABLE #{relation(table)} VALIDATE CONSTRAINT #{quote(temporary)};")
            emit("ALTER TABLE #{relation(table)} DROP CONSTRAINT #{quote(name)};\nALTER TABLE #{relation(table)} RENAME CONSTRAINT #{quote(temporary)} TO #{quote(name)};")
          end
        end
      end

      def index!(table, key, unique:, existing:)
        columns = key['columns'].map { |name| quote(name) }.join(', ')
        if unique && !existing
          emit("ALTER TABLE #{relation(table)} ADD CONSTRAINT #{quote(key['name'])} UNIQUE (#{columns});", existing: false)
          return
        end
        sql = "CREATE #{unique ? 'UNIQUE ' : ''}INDEX #{existing ? 'CONCURRENTLY ' : ''}#{quote(key['name'])} ON #{relation(table)} (#{columns});"
        emit(sql, existing: existing, transaction: existing ? 'nao' : 'sim')
        emit("ALTER TABLE #{relation(table)} ADD CONSTRAINT #{quote(key['name'])} UNIQUE USING INDEX #{quote(key['name'])};") if unique
      end

      def physical_statement?(item, tables)
        tables.any? do |table|
          path = table.values_at('schema', 'table').join('.')
          case item['kind']
          when 'table' then item['object'] == path
          when 'constraint'
            (table['unique_keys'] + table['foreign_keys']).any? { |key| item['object'] == "#{path}.#{key['name']}" }
          when 'index'
            table['indexes'].any? { |key| item['object'] == "#{table['schema']}.#{key['name']}" }
          end
        end
      end

      def outbox_item?(item)
        @outbox.include?(item['sha256'])
      end

      def rate_limit_item?(item)
        @rate_limit.include?(item['sha256'])
      end

      def rate_limit_object?(item)
        object = item['object'].to_s.delete_prefix('table ').delete_prefix('function ')
        object.start_with?('vetra.reserve_rate_limit(') || object == 'vetra_rate_limit_routines' ||
          (object.split('.').first == 'vetra' && [RateLimit::TABLE, RateLimit::INDEX, RateLimit::PURGE_INDEX].include?(object.split('.')[1]))
      end

      def rate_limit!(old, current)
        wanted = @initial.steps.zip(current).select { |_, item| rate_limit_item?(item) }
        if old.any? { |item| rate_limit_object?(item) }
          unless wanted.any? && wanted.all? { |_, item| old.include?(item) } &&
                 old.select { |item| rate_limit_object?(item) }.all? { |item| wanted.map(&:last).include?(item) }
            fail!('db_plan_statement', 'seção do limite de taxa alterada ou removida')
          end
        elsif wanted.any?
          emit(wanted.map { |step, _| step.sql }.join("\n"), existing: false)
        end
      end

      def idempotency_item?(item)
        @idempotency.include?(item['sha256'])
      end

      # Objeto da seção da idempotência num modelo anterior, mesmo gerado por outro texto: tabela, índice, dono, RLS ou política.
      def idempotency_object?(item)
        object = item['object'].to_s.delete_prefix('table ')
        schema, name = object.split('.')
        schema == 'vetra' && [Idempotency::TABLE, Idempotency::PURGE_INDEX].include?(name)
      end

      # A seção nasce inteira, num passo transacional, quando o modelo anterior não a tem. Fora disso, qualquer diferença
      # nela é recusada: o plano incremental ainda não a traduz (ADR-043, §7).
      def idempotency!(old, current)
        wanted = @initial.steps.zip(current).select { |_, item| idempotency_item?(item) }
        if old.any? { |item| idempotency_object?(item) }
          current_items = wanted.map(&:last)
          unless wanted.all? { |_, item| old.include?(item) } && old.select { |item| idempotency_object?(item) }.all? { |item| current_items.include?(item) }
            fail!('db_plan_statement', 'seção da idempotência alterada')
          end
        elsif wanted.any?
          emit(wanted.map { |step, _| step.sql }.join("\n"), existing: false)
        end
      end

      # Objeto da outbox num modelo anterior, mesmo gerado por outro texto: tabela, índice, dono, RLS ou política.
      def outbox_object?(item)
        object = item['object'].to_s.delete_prefix('table ')
        schema, name = object.split('.')
        schema == 'vetra' && ((Outbox::TABLES + Outbox::RELAY_TABLES).include?(name) || %w[vt_outbox_relay vt_deliveries_ready].include?(name))
      end

      # A outbox nasce inteira, num passo transacional, quando o modelo anterior não a tem; numa base com só o
      # armazenamento da K11, o relay entra inteiro, também num passo. Fora disso, qualquer diferença nela é recusada:
      # o plano incremental ainda não a traduz (ADR-040, §5).
      def outbox!(old, current)
        existed = old.any? { |item| outbox_object?(item) }
        wanted = @initial.steps.zip(current).select { |_, item| outbox_item?(item) }
        if existed
          fail!('db_plan_remove', 'outbox removida; a aplicação deixou de ter eventos') if wanted.empty?
          # Igualdade nos dois sentidos: uma instrução a mais na base (política, índice, trigger) também é alteração.
          # Privilégios não têm objeto; os excedentes caem na conferência genérica de instruções removidas.
          current_items = wanted.map(&:last)
          missing = wanted.reject { |_, item| old.include?(item) }
          present = (current_items - missing.map(&:last)).map { |item| item['sha256'] }
          only_relay = present == @outbox_storage && missing.map { |_, item| item['sha256'] } == @outbox - @outbox_storage
          unless (missing.empty? || only_relay) && old.select { |item| outbox_object?(item) }.all? { |item| current_items.include?(item) }
            fail!('db_plan_statement', 'seção da outbox alterada')
          end
          unless missing.empty?
            # O passo cria políticas nas tabelas da outbox, que já existem: o rótulo é o lock mais forte das instruções.
            locks = missing.map { |step, _| Plan.classify(step.sql, existing: true).first }
            emit(missing.map { |step, _| step.sql }.join("\n"), lock: locks.max_by { |lock| Plan::LOCKS.index(lock) })
          end
        elsif wanted.any?
          emit(wanted.map { |step, _| step.sql }.join("\n"), existing: false)
        end
      end

      def instructions!
        old = @base['statements']
        current = @state['statements']
        outbox!(old, current)
        idempotency!(old, current)
        rate_limit!(old, current)
        deferred_grants = []
        # As políticas de cada tabela são uma unidade: inclusive a troca vt_access -> vt_scope_*.
        policy_tables = (old + current).select { |item| item['kind'] == 'policy' && !outbox_object?(item) && !idempotency_object?(item) && !rate_limit_object?(item) }
          .map { |item| item['object'].split('.')[0, 2] }.uniq
        replacements = {}
        policy_tables.each do |path|
          belongs = ->(item) { item['kind'] == 'policy' && item['object'].split('.')[0, 2] == path }
          previous, following = old.select(&belongs), current.select(&belongs)
          next if previous == following
          lost = previous.reject { |item| following.any? { |other| other['object'] == item['object'] } }
          gained = following.reject { |item| previous.any? { |other| other['object'] == item['object'] } }
          fail!('db_plan_remove', "política de #{path.join('.')}") if lost.any? && gained.empty?
          drops = previous.map { |item| "DROP POLICY #{quote(item['object'].split('.').last)} ON #{path.map { |part| quote(part) }.join('.')};" }
          creates = @initial.steps.zip(current).select { |_, item| belongs.call(item) }.map { |step, _| step.sql }
          replacements[path] = (drops + creates).join("\n")
        end
        # Remoções não estruturais e instruções anônimas que desapareceram não são ignoradas.
        old.each do |item|
          next if %w[policy lock].include?(item['kind']) || physical_statement?(item, @old.values)
          present = item['object'] ? current.any? { |other| other.values_at('kind', 'object') == item.values_at('kind', 'object') } : current.include?(item)
          fail!('db_plan_statement', "instrução removida #{item['kind']} #{item['object']}") unless present
        end
        emitted_policies = []
        @initial.steps.zip(current).each do |step, item|
          next if outbox_item?(item) || idempotency_item?(item) || rate_limit_item?(item)
          kind, object = item.values_at('kind', 'object')
          # O bootstrap de revisão é a última seção do plano inicial. Seu LOCK precisa cobrir os triggers,
          # REVOKEs e guardas na mesma transação, não terminar num passo anterior a eles.
          @revision_sql = [] if kind == 'guard' && object == 'vetra_roles'
          if %w[constraint index].include?(kind)
            previous = old.find { |other| other.values_at('kind', 'object') == [kind, object] }
            # Índices/constraints de infraestrutura não estão nas tabelas estruturadas: não podem desaparecer
            # na seleção do DDL das entidades, nem ter o texto alterado silenciosamente.
            unless physical_statement?(item, @new.values) ? previous.nil? || previous == item : old.include?(item)
              fail!('db_plan_statement', "índice ou constraint sem tradução #{object}")
            end
            next
          end
          if kind == 'schema'
            previous = old.find { |other| other.values_at('kind', 'object') == [kind, object] }
            fail!('db_plan_statement', "schema alterado #{object}") if previous && previous != item
            next
          end
          if kind == 'table'
            app_table = @new.values.find { |table| table.values_at('schema', 'table').join('.') == object }
            fail!('db_plan_statement', "tabela de infraestrutura #{object}") if !app_table && !old.include?(item)
            if app_table && (before = @old[app_table['entity']]) && before.values_at('columns', 'checks', 'primary_key') == app_table.values_at('columns', 'checks', 'primary_key') && !old.include?(item)
              fail!('db_plan_statement', "definição de tabela alterada fora da estrutura #{object}")
            end
            next
          end
          if kind == 'policy'
            path = object.split('.')[0, 2]
            if replacements.key?(path) && !emitted_policies.include?(path)
              emit(replacements.fetch(path))
              emitted_policies << path
            end
            next
          end
          next if old.include?(item)
          previous = old.find { |other| object && other.values_at('kind', 'object') == [kind, object] }
          case kind
          when 'guard'
            fail!('db_plan_statement', "guarda desconhecida #{object}") unless GUARDS.include?(object)
            emit(step.sql)
          when 'function', 'trigger'
            # As rotinas de contexto vêm do gerador atual (Context.prefix); o plano as instala ou as troca pelo corpo novo.
            safe = kind == 'function' ? %w[$vetra_transition$ $vetra_authz$ $vetra_context$].any? { |tag| step.sql.include?(tag) } : object.split('.').last.start_with?('vt_transition_', 'vt_authz_')
            fail!('db_plan_statement', "rotina ou trigger sem tradução #{object}") unless safe
            sql = previous ? step.sql.sub("CREATE #{kind.upcase}", "CREATE OR REPLACE #{kind.upcase}") : step.sql
            if kind == 'trigger' && previous
              path = object.split('.')
              sql += "\nALTER TABLE #{path[0, 2].map { |part| quote(part) }.join('.')} ENABLE ALWAYS TRIGGER #{quote(path.last)};"
            end
            emit(sql)
          when 'owner', 'privilege', 'row_security', 'trigger_mode'
            fail!('db_plan_statement', "dono ou modo alterado #{object}") if previous
            if @new_table_grants.include?(step.sql)
              deferred_grants << step.sql
            else
              emit(step.sql)
            end
          when 'lock'
            # Reaplicado junto da instalação abaixo, mesmo quando seu texto não mudou.
            next
          else
            fail!('db_plan_statement', "#{kind} #{object} sem tradução segura")
          end
        end
        revision = @revision_sql
        @revision_sql = nil
        if revision && !revision.empty?
          lock = @initial.steps.find { |step| step.sql.start_with?('LOCK TABLE ') }.sql
          emit(([lock] + revision).join("\n"))
        end
        deferred_grants.each { |sql| emit(sql) }
      end
    end
  end
end

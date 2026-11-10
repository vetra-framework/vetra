# frozen_string_literal: true

module Vetra
  module SQL
    # Consumidor da IR para o plano inicial (ADR-037). Não aceita fragmentos SQL da aplicação.
    class Security
      Result = Struct.new(:statements, :artifact, keyword_init: true)
      ACTIONS = { 'read' => 'SELECT', 'create' => 'INSERT', 'update' => 'UPDATE', 'delete' => 'DELETE' }.freeze
      class ApplicationPredicate < StandardError; end

      def initialize(schema)
        @schema = schema
        @document = schema.document
        @entities = @document['nodes'].select { |node| node['kind'] == 'entity' }.to_h { |node| [node['id'], node] }
        @tables = schema.tables.to_h { |table| [table['entity'], table] }
        @policies = @document['nodes'].select { |node| node['kind'] == 'policy' }.sort_by { |node| node['id'] }
        @dependencies = Hash.new { |hash, key| hash[key] = [] }
        @notes, @counter = [], 0
      end

      def generate
        statements = @schema.tables.flat_map do |table|
          table['scope'] == 'global' ? [] : tenant_policies(table)
        end
        check_cycles!
        statements.concat(@schema.tables.flat_map { |table| transitions(table) })
        if !@document.dig('app', 'tenant')
          @notes << 'Aplicação sem tenant: sem RLS de tenant/escopo e sem revisão; autorização permanece na aplicação.'
        end
        artifact = (["-- Vetra: segurança derivada da IR; aplicada somente pelos passos de db/plans/.",
                     '-- Confira com vetra db:plan --check; não aplique este espelho separadamente.'] +
                    @notes.sort.map { |note| "-- #{note}" } + statements).join("\n\n") + "\n"
        Graph::Data.freeze(Result.new(statements: statements, artifact: artifact))
      end

      private

      def quote(name)
        Context.quote(name)
      end

      def relation(table)
        table.values_at('schema', 'table').map { |name| quote(name) }.join('.')
      end

      def literal(value)
        case value
        when nil then 'NULL'
        when true then 'true'
        when false then 'false'
        when Numeric then JSON.generate(value)
        when String
          raise Graph::Error.single('security_literal', 'Literal de segurança não pode conter U+0000.') if value.include?("\0")
          escaped = value.gsub(/[\\'\x01-\x1f\x7f]/) do |char|
            { "'" => "''", '\\' => '\\\\' }.fetch(char) { format('\\x%02x', char.ord) }
          end
          "E'#{escaped}'"
        else raise ApplicationPredicate
        end
      end

      def name_for(table, kind, *parts)
        "vt_#{kind}_#{Digest::SHA256.hexdigest(Graph::Canonical.dump([table.values_at('schema', 'table'), *parts]))[0, 32]}"
      end

      def tenant_policies(table)
        path = relation(table)
        condition = "#{quote(table['tenant_column'])} = (SELECT vetra.current_tenant())"
        statements = ["ALTER TABLE #{path} ENABLE ROW LEVEL SECURITY;",
                      "ALTER TABLE #{path} FORCE ROW LEVEL SECURITY;",
                      "CREATE POLICY #{quote('vt_tenant')} ON #{path} AS RESTRICTIVE FOR ALL TO #{quote('vetra_app')} USING (#{condition}) WITH CHECK (#{condition});"]
        policies = @policies.select { |policy| policy.dig('entity', 'id') == table['entity'] }
        if policies.all? { |policy| policy.dig('predicate', 'op') == 'true' }
          @notes << "#{table['entity']}: sem escopo SQL; permissiva de tenant, RBAC na aplicação."
          return statements << "CREATE POLICY #{quote('vt_access')} ON #{path} AS PERMISSIVE FOR ALL TO #{quote('vetra_app')} USING (true) WITH CHECK (true);"
        end
        ACTIONS.each do |action, command|
          selected = policies.select { |policy| policy['actions'].include?(action) }
          next if selected.empty? # Entidade com escopo: ação sem concessão continua negada.
          entity = @entities.fetch(table['entity'])
          supported, unsupported = selected.partition { |policy| supported?(policy['predicate'], entity) }
          expressions = unsupported.map do |policy|
            @notes << "#{policy['id']}: predicado fora do subconjunto SQL; #{command} depende da autorização na aplicação."
            'true'
          end
          unless supported.empty?
            # As concessões da ação são um OR (ADR-041): o OR é normalizado antes de gerar o SQL.
            tree = normalize('op' => 'or', 'terms' => supported.map { |policy| policy['predicate'] })
            dependencies = []
            expressions << predicate(tree, entity, quote(table['table']), dependencies)
            @dependencies[table['entity']].concat(dependencies)
          end
          condition = expressions.uniq.sort.map { |expression| "(#{expression})" }.join(' OR ')
          clauses = []
          clauses << "USING (#{condition})" unless action == 'create'
          clauses << "WITH CHECK (#{condition})" if %w[create update].include?(action)
          statements << "CREATE POLICY #{quote("vt_scope_#{action}")} ON #{path} AS PERMISSIVE FOR #{command} TO #{quote('vetra_app')} #{clauses.join(' ')};"
        end
        # Ator de sistema (ADR-024, §4): alcança o tenant do evento inteiro, sempre sob a restritiva de tenant. Um
        # visitante ou um ator comum não satisfaz is_system_actor(); o limite fino, quais comandos, é o `calls` do grafo.
        statements << "CREATE POLICY #{quote('vt_system')} ON #{path} AS PERMISSIVE FOR ALL TO #{quote('vetra_app')} USING ((SELECT vetra.is_system_actor())) WITH CHECK ((SELECT vetra.is_system_actor()));"
        statements
      end

      # O predicado de uma concessão é traduzível quando todo o seu SQL é gerável; a geração de prova não deixa rastro.
      def supported?(tree, entity)
        counter = @counter
        predicate(tree, entity, 'x', [], true)
        true
      rescue ApplicationPredicate
        false
      ensure
        @counter = counter
      end

      # `positive` é falso sob um NOT: ali um EXISTS não pode virar a forma de lista, porque NULL e false
      # divergem sob a negação (ADR-041, §2).
      def predicate(tree, entity, prefix, dependencies, positive = true)
        case tree['op']
        when 'true' then 'true'
        when 'and', 'or'
          tree['terms'].map { |term| "(#{predicate(term, entity, prefix, dependencies, positive)})" }.sort.join(" #{tree['op'].upcase} ")
        when 'not' then "NOT (#{predicate(tree['term'], entity, prefix, dependencies, !positive)})"
        when 'eq'
          operator = [tree['left'], tree['right']].any? { |value| value['kind'] == 'literal' && value['value'].nil? } ? 'IS NOT DISTINCT FROM' : '='
          "#{operand(tree['left'], entity, prefix)} #{operator} #{operand(tree['right'], entity, prefix)}"
        when 'in'
          values = tree.dig('right', 'value')
          raise ApplicationPredicate unless tree.dig('right', 'kind') == 'literal' && values.is_a?(Array)
          return 'false' if values.empty?
          "#{operand(tree['left'], entity, prefix)} IN (#{values.map { |value| literal(value) }.join(', ')})"
        when 'exists' then exists(tree, entity, prefix, dependencies, positive)
        else raise ApplicationPredicate
        end
      end

      def operand(value, entity, prefix)
        case value['kind']
        when 'actor'
          raise ApplicationPredicate unless value['path'] == ['id']
          '(SELECT vetra.current_actor())'
        when 'literal' then literal(value['value'])
        when 'field'
          field = entity['fields'].find { |item| item['name'] == value['path'].first }
          raise ApplicationPredicate unless value['path'].size == 1 && field && field.dig('type', 'name') != 'money'
          "#{prefix}.#{quote(field['name'])}"
        else raise ApplicationPredicate
        end
      end

      def exists(tree, entity, prefix, dependencies, positive)
        source_tenant_column = @tables.fetch(entity['id'])['tenant_column']
        links = []
        tree['relation'].each do |name|
          link = entity['relations'].find { |item| item['name'] == name }
          raise ApplicationPredicate unless %w[belongs_to has_many].include?(link['kind'])
          links << link
          entity = @entities.fetch(link.dig('target', 'id'))
        end
        # A ida por FK e sua inversa podem correlacionar diretamente o vínculo. A FK garante a unidade.
        if links.size == 2 && links[0]['kind'] == 'belongs_to' && links[1]['kind'] == 'has_many' &&
           links[0]['target_fields'] == links[1]['local_fields']
          links = [links[1].merge('local_fields' => links[0]['local_fields'])]
        end
        from, conditions, source, joins = [], [], prefix, []
        links.each do |link|
          target = @tables.fetch(link.dig('target', 'id'))
          raise ApplicationPredicate if target['scope'] == 'global'
          dependencies << target['entity']
          target_prefix = quote("vt_scope_#{@counter += 1}")
          from << "#{relation(target)} AS #{target_prefix}"
          conditions << "#{target_prefix}.#{quote(target['tenant_column'])} = (SELECT vetra.current_tenant())"
          link['local_fields'].zip(link['target_fields']).each do |local, remote|
            next if remote == target['tenant_column'] && local == source_tenant_column
            joins << [source, local, target_prefix, remote]
            conditions << "#{target_prefix}.#{quote(remote)} = #{source}.#{quote(local)}"
          end
          source = target_prefix
          source_tenant_column = target['tenant_column']
        end
        check_scope_index!(entity, tree['where'])
        # Dentro do WHERE de um EXISTS, NULL e false excluem a linha do mesmo jeito: a polaridade recomeça positiva.
        where = predicate(tree['where'], entity, source, dependencies, true)
        if positive && links.size == 1 && joins.size == 1 && actor_bound?(tree['where'], @tables.fetch(entity['id'])['tenant_column'])
          # Forma de lista (ADR-041): os vínculos do ator, lidos uma vez por instrução, e a unidade da linha testada contra eles.
          outer, local, inner, remote = joins.first
          list = "SELECT #{inner}.#{quote(remote)} FROM #{from.first} WHERE (#{conditions.first}) AND (#{where})"
          return "#{outer}.#{quote(local)} = ANY (ARRAY(#{list}))"
        end
        conditions << where
        "EXISTS (SELECT 1 FROM #{from.join(', ')} WHERE #{conditions.map { |condition| "(#{condition})" }.join(' AND ')})"
      end

      # O predicado exige, em todos os ramos, a igualdade de um campo do vínculo com o ator: a lista tem o tamanho dos
      # vínculos do ator, não o da tabela de destino. A coluna do tenant não conta: com tenant e ator iguais, ela
      # selecionaria todos os vínculos do tenant.
      def actor_bound?(tree, tenant_column)
        case tree['op']
        when 'and' then tree['terms'].any? { |term| actor_bound?(term, tenant_column) }
        when 'or' then tree['terms'].all? { |term| actor_bound?(term, tenant_column) }
        when 'eq'
          sides = [tree['left'], tree['right']]
          field = sides.find { |value| value['kind'] == 'field' }
          field && sides.any? { |value| value['kind'] == 'actor' } && field['path'].first != tenant_column
        else false
        end
      end

      # Normalização do OR das concessões (ADR-041, §3): só equivalências exatas da lógica de três valores.
      def normalize(tree)
        case tree['op']
        when 'and' then tree.merge('terms' => tree['terms'].map { |term| normalize(term) })
        when 'not' then tree.merge('term' => normalize(tree['term']))
        when 'exists' then tree.merge('where' => normalize(tree['where']))
        when 'or' then normalize_or(tree['terms'])
        else tree
        end
      end

      def normalize_or(terms)
        terms = terms.flat_map do |term|
          term = normalize(term)
          term['op'] == 'or' ? term['terms'] : [term]
        end
        terms = merge_exists(terms).uniq { |term| key(term) }
        return terms.first if terms.size == 1
        common = terms.map { |term| conjuncts(term) }.reduce { |all, other| all.select { |item| other.any? { |value| key(value) == key(item) } } }
        if common.empty?
          terms = merge_equalities(terms)
          return terms.size == 1 ? terms.first : { 'op' => 'or', 'terms' => terms }
        end
        rests = terms.map { |term| conjuncts(term).reject { |item| common.any? { |value| key(value) == key(item) } } }
        # A ∨ (A ∧ B) = A; (A ∧ B1) ∨ (A ∧ B2) = A ∧ (B1 ∨ B2).
        inner = rests.any?(&:empty?) ? [] : [normalize_or(rests.map { |rest| rest.size == 1 ? rest.first : { 'op' => 'and', 'terms' => rest } })]
        all = common + inner
        all.size == 1 ? all.first : { 'op' => 'and', 'terms' => all }
      end

      def conjuncts(term)
        term['op'] == 'and' ? term['terms'] : [term]
      end

      def key(term)
        Graph::Canonical.dump(term)
      end

      # EXISTS(p1) OR EXISTS(p2) sobre a mesma relação é EXISTS(p1 OR p2).
      def merge_exists(terms)
        merged = {}
        terms.each_with_object([]) do |term, result|
          next result << term unless term['op'] == 'exists'
          if (index = merged[term['relation']])
            result[index] = result[index].merge('where' => normalize_or([result[index]['where'], term['where']]))
          else
            merged[term['relation']] = result.size
            result << term
          end
        end
      end

      # f = a OR f = b é f IN (a, b); só literais não nulos, porque a igualdade com NULL usa IS NOT DISTINCT FROM.
      def merge_equalities(terms)
        groups = Hash.new { |hash, name| hash[name] = [] }
        terms.each do |term|
          field, values = equality_values(term)
          groups[key(field)] << values if field
        end
        emitted = []
        terms.each_with_object([]) do |term, result|
          field, = equality_values(term)
          next result << term unless field && groups[key(field)].size > 1
          next if emitted.include?(key(field))
          emitted << key(field)
          values = groups[key(field)].flatten(1).uniq { |value| JSON.generate(value) }.sort_by { |value| JSON.generate(value) }
          result << { 'op' => 'in', 'left' => field, 'right' => { 'kind' => 'literal', 'value' => values } }
        end
      end

      def equality_values(term)
        scalar = ->(value) { !value.nil? && !value.is_a?(Array) && !value.is_a?(Hash) }
        case term['op']
        when 'eq'
          field, literal = [term['left'], term['right']].then { |pair| pair.partition { |value| value['kind'] == 'field' } }.then { |fields, others| [fields.first, others.first] }
          return unless field && field['path'].size == 1 && literal && literal['kind'] == 'literal' && scalar.call(literal['value'])
          [field, [literal['value']]]
        when 'in'
          values = term.dig('right', 'value')
          return unless term['left']['kind'] == 'field' && term['left']['path'].size == 1 && term.dig('right', 'kind') == 'literal' &&
                        values.is_a?(Array) && values.all?(&scalar)
          [term['left'], values]
        end
      end

      def check_scope_index!(entity, tree)
        if tree['op'] == 'and' || tree['op'] == 'or'
          tree['terms'].each { |term| check_scope_index!(entity, term) }
        elsif tree['op'] == 'eq'
          field, actor = [tree['left'], tree['right']].sort_by { |value| value['kind'] == 'field' ? 0 : 1 }
          return unless field['kind'] == 'field' && field['path'].size == 1 && actor['kind'] == 'actor'
          table = @tables.fetch(entity['id'])
          prefix = [table['tenant_column'], field['path'].first].uniq
          keys = [table['primary_key'], *table['unique_keys'], *table['indexes']]
          unless keys.any? { |key| key['columns'].first(prefix.size) == prefix }
            raise Graph::Error.single('security_scope_index', 'Vínculo usado pelo escopo exige índice com prefixo tenant e campo do ator.', pointer: entity['id'])
          end
        end
      end

      def check_cycles!
        visited = []
        visit = lambda do |entity, path|
          if path.include?(entity)
            raise Graph::Error.single('security_policy_cycle', 'Políticas SQL com dependências cíclicas causariam recursão de RLS; reveja os escopos.')
          end
          return if visited.include?(entity)
          @dependencies.fetch(entity, []).uniq.each { |target| visit.call(target, path + [entity]) }
          visited << entity
        end
        @dependencies.keys.each { |entity| visit.call(entity, []) }
      end

      def transitions(table)
        return [] unless table.dig('transitions', 'enforce') == 'db'
        entity = @entities.fetch(table['entity'])
        checks = entity['fields'].sort_by { |field| field['name'] }.flat_map do |field|
          columns = table['columns'].select { |column| column['field'] == field['name'] }
          new_value = "ROW(#{columns.map { |column| "NEW.#{quote(column['name'])}" }.join(', ')})"
          old_value = "ROW(#{columns.map { |column| "OLD.#{quote(column['name'])}" }.join(', ')})"
          clauses = []
          if field['set_by']
            if field['default'] && field.dig('default', 'kind') != 'literal'
              raise Graph::Error.single('security_transition_default', 'set_by com reforço no banco exige default literal ou ausência de default.')
            end
            defaults = "ROW(#{columns.map { |column| column['default'] || 'NULL' }.join(', ')})"
            clauses << transition_check("(TG_OP = 'INSERT' AND #{new_value} IS DISTINCT FROM #{defaults}) OR (TG_OP = 'UPDATE' AND #{new_value} IS DISTINCT FROM #{old_value})", field['set_by'])
          end
          field.fetch('guarded', []).sort_by { |guard| guard['value'] }.each do |guard|
            value = literal(guard['value'])
            column = quote(field['name'])
            condition = "(TG_OP = 'INSERT' AND NEW.#{column} = #{value}) OR (TG_OP = 'UPDATE' AND NEW.#{column} IS DISTINCT FROM OLD.#{column} AND (NEW.#{column} = #{value} OR OLD.#{column} = #{value}))"
            clauses << transition_check(condition, guard['commands'])
          end
          clauses
        end
        name = quote(name_for(table, 'transition'))
        function = "#{quote('vetra')}.#{name}"
        sql = <<~SQL.chomp
          CREATE FUNCTION #{function}() RETURNS trigger LANGUAGE plpgsql SECURITY INVOKER
            SET search_path = pg_catalog, pg_temp AS $vetra_transition$
          DECLARE token text; payload_part text; command_name text;
          BEGIN
            IF current_user = 'vetra_migrator' THEN RETURN NEW; END IF;
            -- A função de contexto valida o token inteiro, inclusive cmd, antes de extrair a claim.
            token := pg_catalog.current_setting('vetra.ctx', true);
            IF vetra.current_tenant() IS NULL THEN
              RAISE EXCEPTION 'transition_violation' USING ERRCODE = '42501';
            END IF;
            payload_part := pg_catalog.split_part(token, '.', 3);
            command_name := pg_catalog.convert_from(pg_catalog.decode(pg_catalog.translate(payload_part, '-_', '+/') ||
              pg_catalog.repeat('=', (4 - pg_catalog.length(payload_part) % 4) % 4), 'base64'), 'UTF8')::jsonb->>'cmd';
          #{checks.join("\n")}
            RETURN NEW;
          END $vetra_transition$;
        SQL
        [sql, "ALTER FUNCTION #{function}() OWNER TO #{quote('vetra_owner')};",
         "REVOKE ALL ON FUNCTION #{function}() FROM PUBLIC, #{quote('vetra_app')};",
         "CREATE TRIGGER #{name} BEFORE INSERT OR UPDATE ON #{relation(table)} FOR EACH ROW EXECUTE FUNCTION #{function}();",
         "ALTER TABLE #{relation(table)} ENABLE ALWAYS TRIGGER #{name};"]
      end

      def transition_check(condition, commands)
        permitted = commands.map { |command| literal(command['id']) }.uniq.sort.join(', ')
        <<~SQL.chomp
            IF (#{condition}) AND (command_name IS NULL OR command_name NOT IN (#{permitted})) THEN
              RAISE EXCEPTION 'transition_violation' USING ERRCODE = '42501';
            END IF;
        SQL
      end
    end
  end
end

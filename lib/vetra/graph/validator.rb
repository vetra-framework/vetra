require "date"
require "time"

module Vetra
  module Graph
    class Validator
      attr_reader :warnings

      def initialize
        @schema = Schema.new
      end

      def validate!(document, verify_digest: true)
        @warnings, @errors = [], []
        @document = document
        @schema.validate!(document)
        Canonical.dump(document)
        @nodes = {}
        @positions = {}
        document.fetch("nodes").each_with_index do |node, i|
          key = node.values_at("kind", "id")
          issue("duplicate_id", "Identidade repetida: #{key.join(' ')}.", node) if @nodes.key?(key)
          @nodes[key], @positions[node.object_id] = node, "/nodes/#{i}"
        end
        inputs = document.fetch("inputs")
        @inputs = inputs.to_h { |input| input.values_at("path", "digest") }
        issue("duplicate_input", "Caminho repetido no manifesto.", pointer: "/inputs") unless @inputs.size == inputs.size
        Data.references(document.fetch('app')) do |reference, pointer|
          issue('reference_missing', 'Tenant da aplicação referencia entidade não declarada.', pointer: "/app#{pointer}") unless @nodes.key?(reference.values_at('kind', 'id'))
        end
        inputs.each_with_index do |input, i|
          if input['path'].split('/').any? { |part| part == '.vetra' || part.match?(/\A(?:secrets|credentials)(?:\.|\z)|\A\.env|\.(?:key|pem|enc)\z/) }
            issue('input_path', 'Cache e segredos não pertencem ao manifesto.', pointer: "/inputs/#{i}/path")
          end
        end
        document.fetch("nodes").each { |node| common(node) }
        ruby_nodes = document['nodes'].select { |node| node.dig('implementation', 'kind') == 'ruby' }
        ruby_nodes.group_by { |node| node.dig('implementation', 'ref') }.each_value do |nodes|
          issue('duplicate_implementation', 'Referência de implementação usada por mais de uma operação.', nodes.last, suffix: '/implementation/ref') if nodes.size > 1
        end
        fail_if_errors!
        document.fetch("nodes").each do |node|
          case node['kind']
          when "domain" then domain(node)
          when "entity" then entity(node)
          when "contract" then fields(node)
          when "policy" then policy(node)
          when "command", "query", "handler" then operation(node)
          when "event" then event(node)
          when "route" then route(node)
          when "dependency"
            issue("dependency_unclassified", "Classifique a gem #{node['name']} antes de confiar nos efeitos.", node, warning: true) if %w[unclassified outside_guarantee].include?(node['trust'])
          end
        end
        domain_cycles
        historical_ids
        route_collisions
        if verify_digest && document.fetch("digest") != Canonical.digest(document)
          issue("digest_mismatch", "Digest não corresponde ao documento; reconstrua a IR.", pointer: "/digest")
        end
        fail_if_errors!
        @warnings.freeze
      end

      private

      def issue(code, message, node = nil, suffix: "", pointer: nil, warning: false)
        diagnostic = Diagnostic.new(code: code, message: message, pointer: pointer || "#{@positions[node&.object_id]}#{suffix}", source: node && node['source'], severity: warning ? :warning : :error)
        (warning ? @warnings : @errors) << diagnostic
      end

      def fail_if_errors!
        raise Error.new(@errors) unless @errors.empty?
      end

      def resolve(reference)
        @nodes.fetch(reference.values_at("kind", "id"))
      end

      def each(kind)
        @nodes.each_value.select { |node| node['kind'] == kind }
      end

      def field_map(node)
        node.fetch("fields").to_h { |field| [field.fetch('name'), field] }
      end

      def common(node)
        unless @inputs.key?(node.dig('source', 'path'))
          issue("source_manifest", "A origem deve constar no manifesto.", node, suffix: "/source/path")
        end
        valid_id = if node['kind'] == "domain"
          node['id'].match?(/\A[a-z][a-z0-9_]*\z/)
        else
          node['id'].start_with?("#{node.dig('domain', 'id')}.")
        end
        issue("node_namespace", "ID deve pertencer ao namespace do domínio.", node, suffix: "/id") unless valid_id
        implementation = node['implementation']
        if implementation && implementation['kind'] == 'builtin'
          action = implementation['name'].delete_prefix('crud.')
          expected_kind = action == 'read' ? 'query' : 'command'
          unless Schema::CRUD_ACTIONS.include?(action) && implementation['name'] == "crud.#{action}" && node['kind'] == expected_kind
            issue('builtin_implementation', 'Primitiva interna desconhecida ou incompatível com o nó.', node, suffix: '/implementation')
          end
        end
        if implementation && implementation['kind'] == "ruby"
          unless implementation['digest'] == @inputs[implementation['path']]
            issue("implementation_manifest", "Digest da implementação difere do manifesto.", node, suffix: "/implementation")
          end
          unless implementation['ref'] == "#{node['id']}#call"
            issue("implementation_ref", "A referência deve identificar exatamente este nó e seu call.", node, suffix: "/implementation/ref")
          end
          if implementation.dig('analysis', 'status') == "incomplete"
            issue("analysis_incomplete", "Análise incompleta; dependências dinâmicas continuam fora da garantia estrutural.", node, warning: true)
          end
        end
        issue("unsafe_effect", "Exceção motivada de efeitos: operação fora da garantia de repetição/sombra.", node, warning: true) if node['unsafe_effect']
        Data.references(node) do |reference, pointer|
          target = @nodes[reference.values_at("kind", "id")]
          unless target
            issue("reference_missing", "Declare #{reference['kind']} #{reference['id']} ou corrija a referência.", node, suffix: pointer)
            next
          end
          owner = node['kind'] == "domain" ? node['id'] : node.dig('domain', 'id')
          destination = target['kind'] == "domain" ? target['id'] : target.dig('domain', 'id')
          dependencies = @nodes[["domain", owner]]&.fetch("depends_on")
          if owner != destination && dependencies && !dependencies.any? { |entry| entry['id'] == destination }
            issue("domain_dependency", "Declare depends_on :#{destination} no domínio #{owner}.", node, suffix: pointer)
          end
        end
      end

      def domain(node)
        issue("domain_unrestricted", "Declare depends_on para verificar a fronteira deste domínio.", node, warning: true) if node['depends_on'].nil?
      end

      def fields(node)
        names = node['fields'].map { |field| field['name'] }
        issue("duplicate_field", "Nomes de campos devem ser únicos.", node, suffix: "/fields") unless names.uniq == names
        node['fields'].each_with_index do |field, i|
          at = "/fields/#{i}"
          type = field['type']
          if %w[decimal money].include?(type['name']) && type['scale'] > type['precision']
            issue("decimal_scale", "scale não pode exceder precision.", node, suffix: "#{at}/type")
          end
          if type['groups'] && type['groups'].values.flatten.any? { |value| !type['values'].include?(value) }
            issue("enum_group", "Grupo contém valor ausente do enum.", node, suffix: "#{at}/type/groups")
          end
          constraints = field.fetch("constraints", {})
          if constraints['min_length'] && constraints['max_length'] && constraints['min_length'] > constraints['max_length']
            issue("field_constraints", "Tamanho mínimo excede o máximo.", node, suffix: "#{at}/constraints")
          end
          if field['default'] && field.dig('default', 'kind') == "literal" && !literal_valid?(field.dig('default', 'value'), field)
            issue("field_default", "Default incompatível com tipo, nulabilidade ou precisão do campo #{field['name']}.", node, suffix: "#{at}/default")
          end
          if field.dig('default', 'kind') == 'context' && type['name'] != 'id'
            issue('field_default', 'Defaults de ator/tenant exigem campo id.', node, suffix: "#{at}/default")
          end
          if field['generate'] && !names.include?(field.dig('generate', 'from'))
            issue("field_generation", "Campo de origem da geração não existe.", node, suffix: "#{at}/generate")
          end
          guards = field.fetch("guarded", [])
          issue("duplicate_guard", "Cada valor protegido tem uma única declaração de donos.", node, suffix: "#{at}/guarded") unless guards.map { |guard| guard['value'] }.uniq.size == guards.size
          guards.each do |guard|
            issue("guard_value", "Valor protegido não pertence ao enum.", node, suffix: "#{at}/guarded") unless type.fetch('values', []).include?(guard['value'])
            if field.dig('default', 'kind') == 'literal' && field.dig('default', 'value') == guard['value']
              issue("guard_default", "Valor protegido não pode ser default; use o comando dono.", node, suffix: "#{at}/default")
            end
          end
          previous = field.fetch('previous_names', [])
          if (previous & names).any? || previous.uniq != previous
            issue("field_rename", "Identidade anterior colide com campo atual.", node, suffix: "#{at}/previous_names")
          end
        end
        aliases = node['fields'].flat_map { |field| field.fetch('previous_names', []) }
        issue("field_rename", "Identidade anterior pertence a mais de um campo.", node) unless aliases.uniq == aliases
      end

      def literal_valid?(value, field)
        return field['nullable'] if value.nil?
        type = field['type']
        case type['name']
        when 'boolean' then value == true || value == false
        when 'integer' then value.is_a?(Integer)
        when 'enum' then type['values'].include?(value)
        when 'decimal', 'money'
          amount = type['name'] == 'money' ? value['amount'] : value
          return false unless amount.is_a?(String) && amount.match?(/\A-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?\z/)
          whole, fraction = amount.delete_prefix('-').split('.', 2)
          whole.sub(/\A0+/, '').size <= type['precision'] - type['scale'] && (fraction || '').size <= type['scale']
        when 'date' then value.is_a?(String) && value.match?(/\A\d{4}-\d{2}-\d{2}\z/) && !!Date.iso8601(value)
        when 'timestamp' then value.is_a?(String) && !!Time.iso8601(value)
        when 'json' then true
        else value.is_a?(String)
        end
      rescue ArgumentError, TypeError
        false
      end

      def entity(node)
        fields(node)
        map = field_map(node)
        check_names(node, node.dig('storage', 'primary_key'), map, '/storage/primary_key')
        tenant = node['tenant']
        application_tenant = @document.dig('app', 'tenant')
        if tenant
          if tenant != application_tenant
            issue("tenant_mismatch", "Tenant da entidade deve coincidir com o tenant da aplicação.", node, suffix: '/tenant')
          end
          tenant_field = map[tenant['field']]
          if !tenant_field || tenant_field['nullable'] || tenant_field['type'] != { 'name' => 'id', 'entity' => tenant['entity'] }
            issue("tenant_field", "Declare o identificador obrigatório do tenant com a referência correta.", node, suffix: '/tenant')
          end
        elsif application_tenant && node['id'] != application_tenant.dig('entity', 'id')
          issue("tenant_missing", "Entidade global além da entidade de tenant não é suportada neste protótipo.", node, suffix: '/tenant')
        end
        if application_tenant && node['id'] == application_tenant.dig('entity', 'id') && tenant
          issue("tenant_root", "A entidade que identifica tenants deve ser global.", node, suffix: '/tenant')
        end
        relation_names = node['relations'].map { |relation| relation['name'] }
        issue("duplicate_relation", "Relações devem ter nomes únicos.", node) unless relation_names.uniq == relation_names
        node['relations'].each_with_index do |relation, index|
          target = resolve(relation['target'])
          check_names(node, relation['local_fields'], map, "/relations/#{index}/local_fields")
          check_names(node, relation['target_fields'], field_map(target), "/relations/#{index}/target_fields")
          if relation['local_fields'].size != relation['target_fields'].size
            issue("relation_key", "As duas partes da chave devem ter o mesmo tamanho.", node)
          end
          if relation['same_tenant']
            unless tenant && target['tenant'] == tenant && relation['local_fields'].first == tenant['field'] && relation['target_fields'].first == tenant['field']
              issue("same_tenant", "same_tenant exige tenants iguais e FK composta começando pelo tenant.", node, suffix: "/relations/#{index}")
            end
          elsif tenant && target['tenant']
            issue("same_tenant", "Relação entre entidades multiempresa deve declarar same_tenant.", node, suffix: "/relations/#{index}")
          end
          if relation['kind'] == 'many_to_many' && !relation['through']
            issue("relation_join", "Relação muitos-para-muitos exige entidade de junção.", node, suffix: "/relations/#{index}")
          end
          if relation['kind'] == 'many_to_many' && relation['through']
            junction = resolve(relation['through'])
            owner_links = junction['relations'].select { |other| other['kind'] == 'belongs_to' && other.dig('target', 'id') == node['id'] }
            target_links = junction['relations'].select { |other| other['kind'] == 'belongs_to' && other.dig('target', 'id') == relation.dig('target', 'id') }
            keys = owner_links.size == 1 && target_links.size == 1 && owner_links.first != target_links.first &&
              owner_links.first['target_fields'] == relation['local_fields'] && target_links.first['target_fields'] == relation['target_fields']
            issue("relation_through", "A junção exige um belongs_to para cada lado, com as chaves da relação; auto-relações não são suportadas.", node, suffix: "/relations/#{index}/through") unless keys
          elsif relation['through']
            issue("relation_through", "through só é válido em relação muitos-para-muitos.", node, suffix: "/relations/#{index}/through")
          end
          if relation['include_on_create']
            included = relation['kind'] == 'many_to_many' && relation['include_on_create'].all? do |name|
              node['relations'].any? { |other| other['name'] == name && other['kind'] == 'belongs_to' && other.dig('target', 'id') == relation.dig('target', 'id') }
            end
            issue("relation_include", "include_on_create deve citar belongs_to da entidade que apontem para o alvo da relação muitos-para-muitos.", node, suffix: "/relations/#{index}/include_on_create") unless included
          end
          if relation['kind'] == 'has_many'
            inverse = target['relations'].any? do |other|
              other['kind'] == 'belongs_to' && other.dig('target', 'id') == node['id'] && other['local_fields'] == relation['target_fields'] && other['target_fields'] == relation['local_fields']
            end
            issue("relation_inverse", "has_many exige o belongs_to inverso, com a mesma chave, na entidade de destino.", node, suffix: "/relations/#{index}") unless inverse
          end
        end
        names = node['indexes'].map { |index| index['name'] }
        issue("duplicate_index", "Índices devem ter nomes únicos.", node) unless names.uniq == names
        node['indexes'].each_with_index do |index, i|
          check_names(node, index['fields'], map, "/indexes/#{i}/fields")
          issue("tenant_index", "Índice deve começar pelo campo de tenant.", node, suffix: "/indexes/#{i}") if tenant && index['fields'].first != tenant['field']
        end
        unless each('policy').any? { |policy| policy.dig('entity', 'id') == node['id'] }
          issue("entity_no_policy", "Entidade sem política de acesso; permanece sem concessão implícita.", node, warning: true)
        end
      end

      def check_names(node, names, map, suffix)
        missing = names - map.keys
        issue("field_missing", "Campos não declarados: #{missing.join(', ')}.", node, suffix: suffix) unless missing.empty?
      end

      def policy(node)
        target = resolve(node['entity'])
        check_names(node, node['fields'], field_map(target), '/fields') if node['fields'].is_a?(Array)
        dependencies = [node['entity']]
        predicate(node['predicate'], target, dependencies, node)
        unless (dependencies.uniq - node['reads']).empty?
          issue("policy_reads", "reads omite entidades usadas pelo predicado; inclua todas as dependências.", node, suffix: '/reads')
        end
      end

      def predicate(tree, target, dependencies, owner)
        case tree['op']
        when 'and', 'or' then tree['terms'].each { |term| predicate(term, target, dependencies, owner) }
        when 'not' then predicate(tree['term'], target, dependencies, owner)
        when 'exists'
          destination = follow_relations(tree['relation'], target, dependencies, owner)
          predicate(tree['where'], destination, dependencies, owner) if destination
        when 'eq', 'in'
          %w[left right].each do |side|
            operand = tree[side]
            case operand['kind']
            when 'field'
              parts = operand['path']
              destination = follow_relations(parts[0...-1], target, dependencies, owner)
              if destination && !field_map(destination).key?(parts.last)
                issue("predicate_field", "Campo do predicado não existe: #{parts.join('.')}.", owner)
              end
            when 'actor'
              unless operand['path'] == ['id']
                issue("actor_binding", "Este protótipo só conhece actor.id; atributos materializados exigem mapeamento de dependências ainda não implementado.", owner)
              end
            when 'input'
              issue("predicate_input", "Predicados de política dependentes da entrada ainda não são suportados.", owner)
            end
          end
        end
      end

      def follow_relations(path, target, dependencies, owner)
        path.each do |name|
          relation = target['relations'].find { |entry| entry['name'] == name }
          unless relation
            issue("predicate_relation", "Relação do predicado não existe: #{name}.", owner)
            return nil
          end
          dependencies << relation['through'] if relation['through']
          dependencies << relation['target']
          target = resolve(relation['target'])
        end
        target
      end

      def operation(node)
        node['uses'].each do |reference|
          capability = resolve(reference)
          config = capability['config']
          forbidden = case node['kind']
          when 'command' then config['type'] == 'external'
          when 'query' then config['type'] == 'external' || config['access'] == 'read_write'
          when 'handler' then config['access'] == 'read_write'
          end
          issue("capability_boundary", "#{node['kind']} não pode usar #{reference['id']} com esse tipo de efeito/acesso.", node, suffix: '/uses') if forbidden
          issue("sql_boundary", "SQL explícito fica fora da garantia estrutural; RLS continua obrigatório.", node, warning: true) if config['type'] == 'sql'
        end
        if node['authorize']
          input = field_map(resolve(node['input']))
          record = node.dig('authorize', 'record')
          if record && (!input[record] || input[record].dig('type', 'name') != 'id')
            issue("authorize_record", "record deve apontar a um campo id do contrato de entrada.", node, suffix: '/authorize/record')
          end
          if record && input[record]&.dig('type', 'entity') && input[record].dig('type', 'entity') != node.dig('authorize', 'entity')
            issue('authorize_record', 'O id autorizado deve referenciar a entidade declarada.', node, suffix: '/authorize/record')
          end
        end
        crud_contract(node) if node.dig('implementation', 'kind') == 'builtin'
        node.fetch('emits', []).each do |emission|
          target = resolve(emission['from'])
          payload = resolve(resolve(emission['event'])['payload'])
          source_fields = field_map(target)
          check_names(node, emission['fields'], source_fields, '/emits')
          if emission['fields'].sort != payload['fields'].map { |field| field['name'] }.sort
            issue("event_payload", "Projeção do evento difere do contrato de payload.", node, suffix: '/emits')
          end
          payload['fields'].each do |field|
            actual = source_fields[field['name']]
            next unless actual
            unless actual['type'] == field['type'] && (!actual['nullable'] || field['nullable']) && actual['privacy'] == field['privacy']
              issue("event_payload", "Tipo, nulabilidade ou privacidade divergente no payload #{field['name']}.", node, suffix: '/emits')
            end
          end
        end
      end

      def crud_contract(node)
        action = node.dig('implementation', 'name').delete_prefix('crud.')
        target = resolve(node.dig('authorize', 'entity'))
        unless node.dig('authorize', 'action') == action
          issue('crud_authorization', 'Ação autorizada deve coincidir com a primitiva CRUD.', node)
        end
        repositories = node['uses'].map { |reference| resolve(reference)['config'] }
        unless repositories.size == 1 && repositories.first['type'] == 'repository' && repositories.first['entity'] == node.dig('authorize', 'entity')
          issue('crud_repository', 'CRUD deve usar o repositório da entidade autorizada.', node)
        end
        return unless %w[create update].include?(action)
        source = field_map(target)
        field_map(resolve(node['input'])).each do |name, input|
          next if action == 'update' && name == 'id'
          field = source[name]
          if !field || name == 'id' || name == target.dig('tenant', 'field') || field['set_by']
            issue('crud_contract', "Campo #{name} não pode ser gravável pelo CRUD genérico.", node)
            next
          end
          guarded = field.fetch('guarded', []).map { |guard| guard['value'] }
          source_type = field['type'].reject { |key, _| %w[values groups].include?(key) }
          input_type = input['type'].reject { |key, _| %w[values groups].include?(key) }
          if source_type != input_type || (input['nullable'] && !field['nullable']) || input['privacy'] != field['privacy']
            issue('crud_contract', 'Contrato genérico alterou tipo, nulabilidade ou privacidade do campo.', node)
          end
          if field.dig('type', 'name') == 'enum' && (input.dig('type', 'values').to_a - field.dig('type', 'values')).any?
            issue('crud_contract', 'Contrato genérico introduziu valor ausente do enum.', node)
          end
          if (guarded & input.dig('type', 'values').to_a).any?
            issue('crud_contract', 'Contrato genérico reintroduz valor protegido.', node)
          end
          if action == 'update' && (input['required'] || input.key?('default'))
            issue('crud_contract', 'PATCH exige campos opcionais sem defaults de criação.', node)
          end
        end
      end

      def event(node)
        if node['visibility'] == 'internal' && node['consumer_required'] && !each('handler').any? { |handler| handler['on'].include?(Data.reference('event', node['id'])) }
          issue("event_consumer", "Evento interno exige consumidor; declare um handler on #{node['id']}.", node)
        end
      end

      def route(node)
        write = node.dig('target', 'kind') == 'command'
        if %w[http webhook].include?(node['surface'])
          method = node.dig('config', 'method')
          if (write && %w[GET HEAD OPTIONS].include?(method)) || (!write && !%w[GET HEAD].include?(method))
            issue("route_target", "Método HTTP incompatível com leitura/escrita do destino.", node)
          end
          params = node.dig('config', 'path').scan(/:([a-z][a-z0-9_]*)/).flatten
          target = resolve(node['target'])
          check_names(node, params, field_map(resolve(target['input'])), '/config/path')
        end
        if node['surface'] == 'webhook' && (node['idempotency'] != 'required' || !write)
          issue("webhook_idempotency", "Webhook deve chamar comando com idempotência obrigatória.", node)
        end
      end

      def route_collisions
        seen = []
        each('route').each do |node|
          config = node['config']
          key = if %w[http webhook].include?(node['surface'])
            ['http', config['method'] == 'HEAD' ? 'GET' : config['method'], config['path'].gsub(/:[a-z][a-z0-9_]*/, ':param')]
          else
            [node['surface'], config['name']]
          end
          conflict = seen.find do |previous, _id|
            if key.first == 'http' && previous.first == 'http' && key[1] == previous[1]
              left, right = key[2].split('/'), previous[2].split('/')
              left.size == right.size && left.zip(right).all? { |a, b| a == b || a == ':param' || b == ':param' }
            else
              key == previous
            end
          end
          issue("route_collision", "Rota ambígua com #{conflict.last}.", node) if conflict
          seen << [key, node['id']]
        end
      end

      def historical_ids
        aliases = {}
        @nodes.each_value do |node|
          node.fetch('previous_ids', []).each do |previous|
            key = [node['kind'], previous]
            issue("identity_rename", "Identidade anterior colide com nó atual ou outro rename.", node) if @nodes.key?(key) || aliases.key?(key)
            aliases[key] = node['id']
          end
        end
      end

      def domain_cycles
        visited, visiting = {}, {}
        walk = lambda do |node|
          return if visited[node['id']]
          if visiting[node['id']]
            issue("domain_cycle", "Dependências entre domínios formam ciclo.", node)
            return
          end
          visiting[node['id']] = true
          node.fetch('depends_on', nil)&.each { |reference| walk.call(resolve(reference)) }
          visiting.delete(node['id'])
          visited[node['id']] = true
        end
        each('domain').each { |node| walk.call(node) }
      end
    end
  end
end

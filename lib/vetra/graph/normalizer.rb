module Vetra
  module Graph
    class Normalizer
      ACTIONS = Schema::CRUD_ACTIONS

      def initialize(registry, manifest)
        @registry, @manifest = registry, manifest
        @raw = expand_implicit_junctions(registry.declarations)
        @entities = {}
        @nodes = {}
        @analysis = Analysis.new(manifest)
      end

      def document
        app = @registry.application
        raise Error.single('app_missing', 'Declare Vetra.app em config/app.rb.') unless app
        @currency = app['currency']
        @application_tenant = application_tenant(app['tenant'])
        domains
        raw('entity').each { |entry| entity(entry) }
        raw('capability').each { |entry| add(base(entry).merge(entry.slice('adapter', 'retry_safe', 'simulation', 'config'))) }
        raw('entity').each { |entry| entity_artifacts(entry) }
        raw('role').each { |entry| role(entry) }
        raw('event').each { |entry| event(entry) }
        %w[command query handler].each { |kind| raw(kind).each { |entry| operation(entry) } }
        result = {
          'ir_version' => Schema::VERSION, 'requires' => ['vetra.core'],
          'producer' => { 'name' => 'vetra', 'version' => Vetra::VERSION, 'ruby_version' => RUBY_VERSION },
          'app' => app.slice('name', 'currency', 'locale').merge('tenant' => @application_tenant),
          'inputs' => Data.copy(@manifest.entries),
          'nodes' => @nodes.values.sort_by { |node| node.values_at('kind', 'id') }
        }
        result = Data.copy(result)
        sort_sets(result)
        result['digest'] = Canonical.digest(result)
        result
      end

      private

      def raw(kind)
        @raw.select { |entry| entry['kind'] == kind }
      end

      # Um many_to_many sem `through:` ganha uma entidade de junção gerada, com a forma que a aplicação declararia à
      # mão, e a relação passa a apontar para ela: dali em diante vale o caminho da junção explícita. Sem `entity:`, o
      # alvo é a entidade do mesmo domínio com o nome da relação no singular. A junção gerada é um nó comum da IR,
      # com `generated_from` apontando o dono. Roda antes de @raw existir, então só usa variáveis locais.
      def expand_implicit_junctions(declarations)
        entities = declarations.select { |entry| entry['kind'] == 'entity' }
        tenant_ref = @registry.application&.dig('tenant')
        tenant_id = tenant_ref && entities.find { |item| item['id'] == tenant_ref || (!tenant_ref.include?('.') && item['id'].split('.').last == tenant_ref) }&.dig('id')
        generated = []
        expanded = declarations.map do |entry|
          implicit = entry['kind'] == 'entity' && entry['relations'].any? { |relation| relation['kind'] == 'many_to_many' && (relation['target'].nil? || relation['through'].nil?) }
          next entry unless implicit
          entry = entry.merge('relations' => entry['relations'].map(&:dup))
          entry['relations'].each do |relation|
            next unless relation['kind'] == 'many_to_many'
            relation['target'] ||= inferred_target(entry, relation, entities)
            next if relation['through']
            junction = junction_declaration(entry, relation, entities + generated, tenant_id)
            generated << junction
            relation['through'] = junction['id']
          end
          entry
        end
        expanded + generated
      end

      def inferred_target(entry, relation, entities)
        id = "#{entry['domain']}.#{singular(relation['name'])}"
        unless entities.any? { |item| item['id'] == id }
          fail!('relation_target', "many_to_many :#{relation['name']} sem entity: exige a entidade #{id}; declare-a ou informe entity:.", entry)
        end
        id
      end

      def junction_declaration(owner, relation, entities, tenant_id)
        target_id = qualify(relation['target'], owner['domain'])
        target = entities.find { |item| item['id'] == target_id }
        fail!('reference_missing', "Declare entity #{target_id} ou use referência qualificada ao domínio correto.", owner) unless target
        if owner['id'] == target['id']
          fail!('relation_through', "many_to_many :#{relation['name']} liga #{owner['id']} a ela mesma: auto-relações não são suportadas, pois a IR não registra qual coluna é qual; declare a junção e through:.", owner)
        end
        id = "#{owner['domain']}.#{owner['id'].split('.').last}_#{singular(relation['name'])}"
        if entities.any? { |item| item['id'] == id }
          fail!('relation_through', "A junção gerada #{id} colide com uma entidade declarada; use through: :#{id.split('.').last}.", owner)
        end
        scoped = [owner, target].map { |item| !tenant_id.nil? && item['id'] != tenant_id && item['tenant'] != false }
        if scoped.uniq.size > 1
          fail!('relation_through', "A junção gerada de #{owner['id']} para #{target['id']} exige entidades com o mesmo tratamento de tenant; declare a junção e through:.", owner)
        end
        shared = scoped.first
        owner_name, target_name = owner['id'].split('.').last, target['id'].split('.').last
        builder = DSL::Entity.new(@registry, @manifest, owner['domain'], Data.copy(owner['source']), options: {})
        builder.tenant(false) unless shared
        builder.belongs_to(owner_name, entity: owner['id'], same_tenant: shared)
        builder.belongs_to(target_name, entity: target['id'], same_tenant: shared)
        builder.index(*(shared ? ["#{tenant_id.split('.').last}_id"] : []), "#{owner_name}_id", "#{target_name}_id", unique: true)
        { 'kind' => 'entity', 'id' => id, 'domain' => owner['domain'], 'source' => Data.copy(owner['source']),
          'generated_from' => Data.reference('entity', owner['id']) }.merge(builder.attributes)
      end

      # Inverso mínimo de plural: "ies" depois de consoante vira "y"; um "s" final cai, exceto em "ss". Quando não
      # acerta, o erro manda informar entity:.
      def singular(name)
        return "#{name[0...-3]}y" if name.match?(/[^aeiou]ies\z/)
        return name[0...-1] if name.end_with?('s') && !name.end_with?('ss')
        name
      end

      def fail!(code, message, entry)
        raise Error.single(code, message, source: entry['source'])
      end

      def add(node)
        key = node.values_at('kind', 'id')
        fail!('duplicate_id', "Identidade gerada colide com outra declaração: #{key.join(' ')}.", node) if @nodes.key?(key)
        @nodes[key] = node
        node
      end

      def base(entry, kind = entry['kind'], id = entry['id'], generated: false)
        node = { 'kind' => kind, 'id' => id, 'source' => Data.copy(entry['source']) }
        node['domain'] = Data.reference('domain', entry['domain']) unless kind == 'domain'
        node['generated_from'] = Data.reference(entry['kind'], entry['id']) if generated
        node
      end

      def qualify(value, domain)
        value.include?('.') ? value : "#{domain}.#{value}"
      end

      def entity_id(value, domain, entry)
        id = qualify(value, domain)
        unless raw('entity').any? { |entity| entity['id'] == id }
          fail!('reference_missing', "Declare entity #{id} ou use referência qualificada ao domínio correto.", entry)
        end
        id
      end

      def application_tenant(value)
        return nil unless value
        candidates = raw('entity').select { |entry| entry['id'] == value || (!value.include?('.') && entry['id'].split('.').last == value) }
        raise Error.single('tenant_reference', 'Tenant deve identificar uma única entidade declarada; use domínio.nome.') unless candidates.size == 1
        target = candidates.first['id']
        { 'entity' => Data.reference('entity', target), 'field' => "#{target.split('.').last}_id" }
      end

      def domains
        declared = raw('domain').to_h { |entry| [entry['id'], entry] }
        @raw.filter_map { |entry| entry['domain'] }.uniq.each do |name|
          declared[name] ||= { 'kind' => 'domain', 'id' => name, 'source' => @raw.find { |entry| entry['domain'] == name }['source'], 'depends_on' => nil }
        end
        declared.each_value do |entry|
          add(base(entry).merge('depends_on' => entry['depends_on']&.map { |name| Data.reference('domain', name) }))
        end
      end

      def field(entry, value)
        result = Data.copy(value)
        if result.dig('type', 'name') == 'money'
          exponent = Currency.exponent(@currency)
          unless exponent
            raise Error.single('money_currency', "A moeda #{@currency} não tem expoente na tabela ISO 4217 distribuída; use uma moeda com unidade mínima definida.", pointer: '/app/currency', source: @registry.application['source'])
          end
          result['type']['scale'] = exponent unless result['type'].key?('scale')
        end
        if result.dig('type', 'entity').is_a?(String)
          result['type']['entity'] = Data.reference('entity', entity_id(result['type']['entity'], entry['domain'], entry))
        end
        result['set_by'] = result['set_by'].map { |name| Data.reference('command', qualify(name, entry['domain'])) } if result['set_by']
        result.fetch('guarded', []).each { |guard| guard['commands'] = guard['commands'].map { |name| Data.reference('command', qualify(name, entry['domain'])) } }
        result
      end

      def id_field(name, target, required: true)
        { 'name' => name, 'type' => { 'name' => 'id', 'entity' => Data.reference('entity', target) }, 'required' => required, 'nullable' => false, 'privacy' => { 'personal' => false } }
      end

      def entity(entry)
        options = entry['options']
        tenant = if entry['id'] == @application_tenant&.dig('entity', 'id') || entry['tenant'] == false
          nil
        elsif entry.key?('tenant')
          target = entry['tenant']
          expected = @application_tenant&.dig('entity', 'id')
          unless expected && [expected, expected.split('.').last].include?(target)
            fail!('tenant_mismatch', 'Entidade deve usar o tenant da aplicação.', entry)
          end
          Data.copy(@application_tenant)
        else
          Data.copy(@application_tenant)
        end
        fields = entry['fields'].map { |value| field(entry, value) }
        if fields.any? { |value| value['name'] == 'id' }
          fail!('reserved_field', 'id é gerado pelo núcleo; não declare outra identidade neste protótipo.', entry)
        end
        fields << id_field('id', entry['id'])
        fields << id_field(tenant['field'], tenant.dig('entity', 'id')) if tenant && !fields.any? { |value| value['name'] == tenant['field'] }
        indexes = entry['indexes'].map.with_index do |index, i|
          index.merge('name' => "#{plural(entry['id'].split('.').last)}_idx_#{i + 1}")
        end
        fields.select { |value| value.dig('constraints', 'unique') }.each do |value|
          names = [tenant && tenant['field'], value['name']].compact.uniq
          indexes << { 'name' => "#{plural(entry['id'].split('.').last)}_#{value['name']}_unique", 'fields' => names, 'unique' => true }
        end
        if tenant
          indexes << { 'name' => "#{plural(entry['id'].split('.').last)}_tenant_id_unique", 'fields' => [tenant['field'], 'id'], 'unique' => true }
        end
        node = base(entry).merge(
          'storage' => { 'schema' => 'public', 'table' => options.fetch(:table, plural(entry['id'].split('.').last)).to_s, 'primary_key' => ['id'] },
          'tenant' => tenant, 'fields' => fields, 'relations' => [], 'indexes' => indexes,
          'history' => entry['history'], 'transitions' => Data.copy(entry['transitions'])
        )
        node['previous_ids'] = Array(options[:was]).map { |name| qualify(name.to_s, entry['domain']) } if options.key?(:was)
        node['generated_from'] = Data.copy(entry['generated_from']) if entry['generated_from']
        @entities[entry['id']] = add(node)
      end

      def entity_artifacts(entry)
        node = @entities.fetch(entry['id'])
        entry['relations'].each do |relation|
          target_id = entity_id(relation['target'], entry['domain'], entry)
          target = @entities.fetch(target_id)
          extra = {}
          case relation['kind']
          when 'has_many'
            local, remote, same_tenant = inverse_keys(entry, relation, target_id, target)
          when 'many_to_many'
            local, remote, same_tenant, extra = junction_keys(entry, relation, target_id)
          else
            local, remote = foreign_keys(node, relation, target, entry)
            same_tenant = relation['same_tenant']
          end
          node['relations'] << relation.slice('name', 'kind').merge('same_tenant' => same_tenant, 'target' => Data.reference('entity', target_id), 'local_fields' => local, 'target_fields' => remote).merge(extra)
        end
        check_memberships(entry, node) if entry['memberships']
        repository = entry['options'].fetch(:repository, plural(entry['id'].split('.').last)).to_s
        %w[read read_write].each do |access|
          suffix = access == 'read' ? '_read' : ''
          add(base(entry, 'capability', "#{entry['domain']}.#{repository}#{suffix}", generated: true).merge(
            'adapter' => 'core.repository', 'retry_safe' => true, 'simulation' => 'memory',
            'config' => { 'type' => 'repository', 'entity' => Data.reference('entity', entry['id']), 'access' => access }
          ))
        end
        contract = add(base(entry, 'contract', "#{entry['id']}.record", generated: true).merge('fields' => output_fields(node['fields'])))
        @entities[entry['id']]['_contract'] = contract['id']
        crud(entry) if entry['crud']
      end

      def foreign_keys(owner, relation, target, entry)
        local = ["#{relation['name']}_id"]
        remote = ['id']
        if relation['same_tenant']
          tenant = owner['tenant']
          fail!('same_tenant', 'same_tenant exige duas entidades com o mesmo tenant.', entry) unless tenant && target['tenant'] == tenant
          local.unshift(tenant['field'])
          remote.unshift(tenant['field'])
        end
        [local, remote]
      end

      # A has_many only mirrors a belongs_to of the target: both sides must share
      # one key, so the inverse is derived from it instead of declared twice.
      def inverse_keys(entry, relation, target_id, target)
        target_entry = raw('entity').find { |item| item['id'] == target_id }
        inverse = target_entry['relations'].find do |item|
          item['kind'] == 'belongs_to' && item['name'] == relation['by'] && entity_id(item['target'], target_entry['domain'], target_entry) == entry['id']
        end
        unless inverse
          fail!('relation_inverse', "has_many #{relation['name']} exige belongs_to :#{relation['by']} em #{target_id} apontando para #{entry['id']}.", entry)
        end
        local, remote = foreign_keys(target, inverse, @entities.fetch(entry['id']), target_entry)
        [remote, local, inverse['same_tenant']]
      end

      # A many_to_many goes through a junction entity declared by the application.
      # Its local and target fields are the keys of the two sides that the junction
      # references; which junction columns hold them comes from its belongs_to pair.
      def junction_keys(entry, relation, target_id)
        through_id = entity_id(relation['through'], entry['domain'], entry)
        junction = raw('entity').find { |item| item['id'] == through_id }
        links = lambda do |wanted|
          junction['relations'].select { |item| item['kind'] == 'belongs_to' && entity_id(item['target'], junction['domain'], junction) == wanted }
        end
        owner_link, target_link = links.call(entry['id']), links.call(target_id)
        unless owner_link.size == 1 && target_link.size == 1 && !owner_link.first.equal?(target_link.first)
          fail!('relation_through', "A junção #{through_id} exige exatamente um belongs_to para #{entry['id']} e um para #{target_id}; auto-relações não são suportadas.", entry)
        end
        if owner_link.first['same_tenant'] != target_link.first['same_tenant']
          fail!('relation_through', "Os dois belongs_to da junção #{through_id} devem usar o mesmo same_tenant.", entry)
        end
        junction_node = @entities.fetch(through_id)
        _, local = foreign_keys(junction_node, owner_link.first, @entities.fetch(entry['id']), junction)
        _, remote = foreign_keys(junction_node, target_link.first, @entities.fetch(target_id), junction)
        included = relation['include'].uniq.map do |name|
          own = entry['relations'].find { |item| item['kind'] == 'belongs_to' && item['name'] == name }
          unless own && entity_id(own['target'], entry['domain'], entry) == target_id
            fail!('relation_include', "include: :#{name} deve ser um belongs_to de #{entry['id']} para #{target_id}.", entry)
          end
          name
        end
        extra = { 'through' => Data.reference('entity', through_id) }
        extra['include_on_create'] = included unless included.empty?
        [local, remote, owner_link.first['same_tenant'], extra]
      end

      # The identity of a scope is the entity its `of` relation points to, already
      # qualified by domain; the relation name alone is not unique across domains.
      def membership_scope_id(entry)
        relation = entry['relations'].find { |item| item['kind'] == 'belongs_to' && item['name'] == entry.dig('memberships', 'of') }
        relation && entity_id(relation['target'], entry['domain'], entry)
      end

      def check_memberships(entry, node)
        config = entry['memberships']
        links = node['relations'].select { |relation| relation['kind'] == 'belongs_to' && [config['of'], config['actor']].include?(relation['name']) }
        unless links.map { |relation| relation['name'] }.uniq.size == 2
          fail!('memberships_relation', "memberships exige belongs_to :#{config['of']} e belongs_to :#{config['actor']}, distintos, na própria entidade.", entry)
        end
        scope_id = membership_scope_id(entry)
        duplicated = raw('entity').any? { |item| !item.equal?(entry) && item.dig('memberships', 'of') == config['of'] && membership_scope_id(item) == scope_id }
        fail!('memberships_ambiguous', "Mais de uma entidade declara memberships of: :#{config['of']} para #{scope_id}.", entry) if duplicated
        role = node['fields'].find { |value| value['name'] == config['role'] }
        unless role && role.dig('type', 'name') == 'enum' && !role['nullable']
          fail!('memberships_role', "memberships exige o enum não nulo #{config['role']} com os papéis do escopo.", entry)
        end
      end

      def output_fields(fields)
        fields.map { |value| Data.copy(value.slice('name', 'type', 'nullable', 'privacy')).merge('required' => true) }
      end

      def plural(name)
        return "#{name[0...-1]}ies" if name.match?(/[^aeiou]y\z/)
        return "#{name}es" if name.match?(/(?:s|x|ch|sh)\z/)
        "#{name}s"
      end

      def crud(entry)
        entity = @entities.fetch(entry['id'])
        local = entry['id'].split('.').last
        repository = entry['options'].fetch(:repository, plural(local)).to_s
        writable = entity['fields'].reject { |value| value['name'] == 'id' || value['name'] == entity.dig('tenant', 'field') || value['set_by'] }
        ACTIONS.each do |action|
          id = "#{entry['domain']}.#{action}_#{local}"
          input_fields = case action
          when 'create' then Data.copy(writable)
          when 'update' then [id_field('id', entry['id']), *Data.copy(writable).map { |value| value.merge('required' => false) }]
          else [id_field('id', entry['id'])]
          end
          input_fields.each do |value|
            if value['guarded']
              protected_values = value['guarded'].map { |guard| guard['value'] }
              value['type']['values'] -= protected_values
              value['type']['groups']&.each_value { |values| values.reject! { |item| protected_values.include?(item) } }
              value['type']['groups']&.delete_if { |_, values| values.empty? }
              fail!('crud_enum', 'Enum do CRUD não tem valores graváveis.', entry) if value['type']['values'].empty?
            end
            value.delete('guarded')
            value.delete('set_by')
            value.delete('previous_names')
            value.delete('default') if action == 'update'
          end
          input = add(base(entry, 'contract', "#{id}.input", generated: true).merge('fields' => input_fields))
          kind = action == 'read' ? 'query' : 'command'
          authorize = { 'action' => action, 'entity' => Data.reference('entity', entry['id']) }
          authorize['record'] = 'id' unless action == 'create'
          operation = base(entry, kind, id, generated: true).merge(
            'input' => Data.reference('contract', input['id']), 'output' => Data.reference('contract', entity.fetch('_contract')),
            'authorize' => authorize, 'uses' => [Data.reference('capability', "#{entry['domain']}.#{repository}#{kind == 'query' ? '_read' : ''}")],
            'implementation' => { 'kind' => 'builtin', 'name' => "crud.#{action}" }
          )
          operation['emits'] = [] if kind == 'command'
          add(operation)
          method = { 'create' => 'POST', 'read' => 'GET', 'update' => 'PATCH', 'delete' => 'DELETE' }.fetch(action)
          path = "/#{entity.dig('storage', 'table')}#{action == 'create' ? '' : '/:id'}"
          route(entry, operation, { 'method' => method, 'path' => path }, 'optional', "#{id}.http")
        end
      end

      def role(entry)
        add(base(entry).merge(entry.slice('anonymous')))
        entry['permissions'].each_with_index do |permission, i|
          target_id = entity_id(permission['entity'], entry['domain'], entry)
          target = @entities.fetch(target_id)
          actions = permission['actions'].flat_map { |action| action == 'manage' ? ACTIONS : [action] }
          reads = [Data.reference('entity', target_id)]
          predicate = where(permission['where'], target, reads, entry)
          scope = permission['scope'] || @raw.find { |raw| raw['kind'] == 'entity' && raw['id'] == target_id }&.dig('crud', 'scope')
          if scope
            holder = membership_for(scope, target, entry)
            scoped = if holder
              membership_scope(entry, target, holder, reads)
            elsif %w[author owner seller].include?(scope) && target['fields'].any? { |value| value['name'] == "#{scope}_id" }
              { 'op' => 'eq', 'left' => { 'kind' => 'field', 'path' => ["#{scope}_id"] }, 'right' => { 'kind' => 'actor', 'path' => ['id'] } }
            else
              declared = raw('entity').select { |item| item.dig('memberships', 'of') == scope }.map { |item| membership_scope_id(item) }
              unless declared.empty?
                fail!('scope_unsupported', "#{target['id']} não declara belongs_to :#{scope} para #{declared.join(', ')}.", entry)
              end
              fail!('scope_unsupported', "Escopo #{scope} desconhecido: use author/owner/seller por actor.id ou declare memberships of: :#{scope} em uma entidade de vínculo.", entry)
            end
            predicate = predicate['op'] == 'true' ? scoped : { 'op' => 'and', 'terms' => [predicate, scoped] }
          end
          add(base(entry, 'policy', "#{entry['id']}.permission_#{i + 1}", generated: true).merge(
            'role' => Data.reference('role', entry['id']), 'entity' => Data.reference('entity', target_id),
            'actions' => actions.uniq, 'fields' => permission['fields'], 'predicate' => predicate, 'reads' => reads.uniq
          ))
        end
      end

      # A scope name may be declared by several memberships (one per scope entity,
      # e.g. one in each domain). The one that applies is the one whose scope entity is
      # the authorized entity itself or the entity its `belongs_to :<scope>` points to.
      def membership_for(scope, target, entry)
        applicable = raw('entity').select do |item|
          next false unless item.dig('memberships', 'of') == scope

          scope_id = membership_scope_id(item)
          target['id'] == scope_id || target['relations'].any? { |relation| relation['kind'] == 'belongs_to' && relation['name'] == scope && relation.dig('target', 'id') == scope_id }
        end
        if applicable.size > 1
          fail!('memberships_ambiguous', "Mais de um vínculo (#{applicable.map { |item| item['id'] }.join(', ')}) se aplica a #{target['id']} no escopo #{scope}.", entry)
        end
        applicable.first
      end

      # The actor reaches the scope through its memberships: the record (or the
      # scope entity itself) must have a membership of the actor with this role.
      def membership_scope(entry, target, declaration, reads)
        fail!('scope_anonymous', 'Papel anônimo não tem vínculo; declare o escopo em um papel autenticado.', entry) if entry['anonymous']
        config = declaration['memberships']
        holder = @entities.fetch(declaration['id'])
        role_name = entry['id'].split('.').last
        role_values = holder['fields'].find { |value| value['name'] == config['role'] }.dig('type', 'values')
        unless role_values.include?(role_name)
          fail!('memberships_role', "O papel #{role_name} não consta em #{holder['id']}.#{config['role']} (#{role_values.join(', ')}).", entry)
        end
        link = holder['relations'].find { |relation| relation['kind'] == 'belongs_to' && relation['name'] == config['of'] }
        scope_id = link.dig('target', 'id')
        inverses = @entities.fetch(scope_id)['relations'].select do |relation|
          relation['kind'] == 'has_many' && relation.dig('target', 'id') == holder['id'] && relation['target_fields'] == link['local_fields']
        end
        unless inverses.size == 1
          fail!('scope_inverse', "Declare exatamente um has_many para #{holder['id']} (by: :#{config['of']}) em #{scope_id}.", entry)
        end
        path = [inverses.first['name']]
        unless target['id'] == scope_id
          hop = target['relations'].find { |relation| relation['kind'] == 'belongs_to' && relation['name'] == config['of'] && relation.dig('target', 'id') == scope_id }
          fail!('scope_unsupported', "#{target['id']} não declara belongs_to :#{config['of']} para #{scope_id}.", entry) unless hop
          path.unshift(hop['name'])
        end
        reads.push(Data.reference('entity', scope_id), Data.reference('entity', holder['id']))
        {
          'op' => 'exists', 'relation' => path,
          'where' => { 'op' => 'and', 'terms' => [
            { 'op' => 'eq', 'left' => { 'kind' => 'field', 'path' => ["#{config['actor']}_id"] }, 'right' => { 'kind' => 'actor', 'path' => ['id'] } },
            { 'op' => 'eq', 'left' => { 'kind' => 'field', 'path' => [config['role']] }, 'right' => { 'kind' => 'literal', 'value' => role_name } }
          ] }
        }
      end

      def where(values, target, reads, entry)
        terms = values.map do |key, value|
          name = key.to_s
          fields = target['fields'].map { |field| field['name'] }
          selector = fields.include?(name) ? name : "#{name}_id"
          if value.is_a?(Hash) || (!fields.include?(selector) && value == :current_actor)
            relation = target['relations'].find { |item| item['name'] == name }
            fail!('predicate_relation', "Relação #{name} não declarada.", entry) unless relation
            reads << relation['target']
            reads << relation['through'] if relation['through']
            destination = @entities.fetch(relation.dig('target', 'id'))
            nested = value == :current_actor ? { id: :current_actor } : value
            { 'op' => 'exists', 'relation' => [name], 'where' => where(nested, destination, reads, entry) }
          else
            right = value == :current_actor ? { 'kind' => 'actor', 'path' => ['id'] } : { 'kind' => 'literal', 'value' => value.is_a?(Symbol) ? value.to_s : value }
            { 'op' => 'eq', 'left' => { 'kind' => 'field', 'path' => [selector] }, 'right' => right }
          end
        end
        return { 'op' => 'true' } if terms.empty?
        terms.size == 1 ? terms.first : { 'op' => 'and', 'terms' => terms }
      end

      def event(entry)
        target_id = entity_id(entry['from'], entry['domain'], entry)
        target = @entities.fetch(target_id)
        selected = project_fields(target, entry['fields'], entry)
        payload = add(base(entry, 'contract', "#{entry['id']}.payload", generated: true).merge('fields' => output_fields(selected)))
        add(base(entry).merge('payload' => Data.reference('contract', payload['id']), 'version' => entry['version'], 'visibility' => entry['visibility'], 'consumer_required' => entry['consumer_required']))
      end

      def project_fields(target, names, entry)
        names.map do |name|
          target['fields'].find { |field| field['name'] == name } || fail!('field_missing', "Campo #{name} não declarado em #{target['id']}.", entry)
        end
      end

      def capability(name, entry)
        id = qualify(name, entry['domain'])
        if !@nodes.key?(['capability', id]) && %w[clock uuid random].include?(name)
          add(base(entry, 'capability', id, generated: true).merge('adapter' => "core.#{name}", 'retry_safe' => true, 'simulation' => 'seeded', 'config' => { 'type' => 'deterministic' }))
        end
        Capabilities.reference(name, domain: entry['domain'], operation_kind: entry['kind'], nodes: @nodes, source: entry['source'])
      end

      def operation(entry)
        kind = entry['kind']
        forbidden = kind == 'handler' ? %w[fields emits exposures authorize returns] : %w[on calls idempotent_by]
        forbidden += ['emits'] if kind == 'query'
        forbidden.each do |key|
          value = entry[key]
          fail!('unsupported_declaration', "#{key} não é válido em #{kind} neste protótipo.", entry) if value && (!value.respond_to?(:empty?) || !value.empty?)
        end
        block = @registry.bindings.fetch("#{entry['id']}#call")
        report = @analysis.inspect_block(block, entry['uses'], declaration_source: entry['source'], declaration_kind: kind)
        unless report['forbidden'].empty? || entry['unsafe_effect']
          fail!('direct_effect', "Efeito direto #{report['forbidden'].join(', ')}; use capacidades ou declare unsafe_effect com motivo.", entry)
        end
        node = base(entry).merge('uses' => entry['uses'].map { |name| capability(name, entry) },
          'implementation' => { 'kind' => 'ruby', 'ref' => "#{entry['id']}#call", 'path' => report.dig('source', 'path'), 'digest' => @manifest.digest_for(report.dig('source', 'path')), 'analysis' => report['analysis'] })
        node['unsafe_effect'] = entry['unsafe_effect'] if entry['unsafe_effect']
        if kind == 'handler'
          fail!('handler_idempotency', 'Declare idempotent_by :event_id no handler.', entry) unless entry['idempotent_by']
          node.merge!('on' => entry['on'].map { |name| Data.reference('event', qualify(name, entry['domain'])) }, 'calls' => entry['calls'].map { |name| Data.reference('command', qualify(name, entry['domain'])) }, 'idempotent_by' => entry['idempotent_by'])
        else
          fail!('authorize_missing', 'Declare authorize no comando ou consulta.', entry) unless entry['authorize']
          fail!('output_contract', 'Declare returns :entidade; inferência de retorno Ruby arbitrário não é implementada.', entry) unless entry['returns']
          authorization = entry['authorize'].merge('entity' => Data.reference('entity', entity_id(entry.dig('authorize', 'entity'), entry['domain'], entry)))
          input_fields = entry['fields'].map { |value| field(entry, value) }
          record = input_fields.find { |value| value['name'] == authorization['record'] }
          record['type']['entity'] ||= authorization['entity'] if record && record.dig('type', 'name') == 'id'
          input = add(base(entry, 'contract', "#{entry['id']}.input", generated: true).merge('fields' => input_fields))
          target = @entities.fetch(entity_id(entry['returns'], entry['domain'], entry))
          node.merge!('input' => Data.reference('contract', input['id']), 'output' => Data.reference('contract', target.fetch('_contract')), 'authorize' => authorization)
          node['emits'] = emissions(entry, authorization) if kind == 'command'
        end
        check_writes(entry, node, report)
        add(node)
        counts = Hash.new(0)
        entry['exposures'].each do |exposure|
          surface = exposure['surface']
          config = if %w[http webhook].include?(surface)
            method, path = exposure['value'].split(' ', 2)
            fail!('route_format', "expose #{surface} exige \"MÉTODO /caminho\".", entry.merge('source' => exposure['source'])) unless method && path
            { 'method' => method, 'path' => path }
          else
            { 'name' => exposure['value'] }
          end
          counts[surface] += 1
          route(entry, node, config, exposure['idempotency'], "#{entry['id']}.#{surface}_#{counts[surface]}", surface: surface)
        end
      end

      def emissions(entry, authorization)
        entry['emits'].map do |emission|
          target_id = emission['from'] ? entity_id(emission['from'], entry['domain'], entry) : authorization.dig('entity', 'id')
          event_id = qualify(emission['event'], entry['domain'])
          unless @nodes.key?(['event', event_id])
            event({ 'kind' => 'event', 'id' => event_id, 'domain' => entry['domain'], 'source' => entry['source'], 'from' => target_id, 'fields' => emission['fields'], 'version' => 1, 'visibility' => 'internal', 'consumer_required' => false })
          end
          { 'event' => Data.reference('event', event_id), 'from' => Data.reference('entity', target_id), 'fields' => emission['fields'] }
        end
      end

      def check_writes(entry, node, report)
        aliases = entry['uses'].zip(node['uses']).to_h { |name, reference| [name.split('.').last, @nodes[[reference['kind'], reference['id']]]] }
        report['writes'].each do |write|
          capability = aliases[write['receiver']]
          next unless capability && capability.dig('config', 'type') == 'repository'
          unless entry['kind'] == 'command'
            fail!('write_boundary', 'Queries não gravam; handlers só gravam chamando comandos.', entry)
          end
          target = @entities.fetch(capability.dig('config', 'entity', 'id'))
          write['fields'].each do |value|
            field = target['fields'].find { |item| item['name'] == value['name'] }
            fail!('field_missing', "Gravação literal em campo inexistente: #{value['name']}.", entry) unless field
            guard = field.fetch('guarded', []).find { |item| value['known'] && item['value'] == value['value'] }
            owners = field['set_by'] || guard&.fetch('commands')
            if owners && !owners.include?(Data.reference('command', entry['id']))
              fail!('transition_owner', "Campo #{value['name']} exige o comando dono declarado em set_by/guarded.", entry)
            end
          end
        end
      end

      def route(entry, target, config, idempotency, id, surface: 'http')
        add(base(entry, 'route', id, generated: true).merge('surface' => surface, 'target' => Data.reference(target['kind'], target['id']), 'config' => config, 'idempotency' => idempotency))
      end

      def sort_sets(document)
        document['nodes'].each do |node|
          node.delete('_contract')
          %w[fields relations indexes].each do |key|
            node[key].sort_by! { |value| value.is_a?(Hash) ? value['name'] : value } if node[key].is_a?(Array)
          end
          %w[uses on calls reads depends_on].each do |key|
            node[key].sort_by! { |value| value.values_at('kind', 'id') } if node[key].is_a?(Array)
          end
          %w[previous_ids actions].each { |key| node[key]&.sort! }
          node.fetch('emits', []).sort_by! { |emission| emission.dig('event', 'id') }
          node.fetch('emits', []).each { |emission| emission['fields'].sort! }
          Array(node['fields']).each do |field|
            next unless field.is_a?(Hash)
            field['previous_names']&.sort!
            field['set_by']&.sort_by! { |value| value.values_at('kind', 'id') }
            field['guarded']&.sort_by! { |guard| guard['value'] }
            field.fetch('guarded', []).each { |guard| guard['commands'].sort_by! { |value| value.values_at('kind', 'id') } }
          end
        end
      end
    end
  end
end

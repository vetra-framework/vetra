# frozen_string_literal: true

module Vetra
  module Execution
    class Authorization
      Result = ::Data.define(:allowed, :diagnostics, :input, :policy_ids) do
        def allowed? = allowed
        def code = diagnostics.first&.code
        def inspect = "#<Vetra::Execution::Authorization::Result allowed=#{allowed?}>"
        alias to_s inspect
      end

      def initialize(document)
        schema = SQL::Schema.new(document).generate
        @document = schema.document
        @nodes = @document.fetch('nodes').to_h { |node| [node['id'], node] }.freeze
        @entities = @nodes.select { |_id, node| node['kind'] == 'entity' }.freeze
        @tables = schema.tables.to_h { |table| [table['entity'], table] }.freeze
        @roles = @nodes.select { |_id, node| node['kind'] == 'role' }.freeze
        @policies = @nodes.values.select { |node| node['kind'] == 'policy' }.freeze
        @input = Input.new(@document)
        @predicate = Predicate.new(@entities, @tables)
        @policy_entities = @policies.flat_map do |policy|
          entity_id = policy.dig('entity', 'id')
          [entity_id, *@predicate.traversed(policy.fetch('predicate'), entity_id)]
        end.uniq.sort.freeze
        freeze
      end

      def snapshot(context:, roles:, revision:, records:)
        Snapshot.new(owner: self, context: context, roles: roles, revision: revision, records: records)
      end

      def validate_input(operation_id, value)
        @input.validate(operation!(operation_id).dig('input', 'id'), value)
      end

      # Entidades de dados de que a borda precisa para decidir esta operação com os papéis dados: as dos saltos das
      # políticas candidatas e, com `record:`, a entidade principal (que o avaliador lê pelo ID da entrada).
      def fact_plan(operation_id, roles)
        operation = operation!(operation_id)
        entity_id, action = operation.dig('authorize', 'entity', 'id'), operation.dig('authorize', 'action')
        assigned = roles | @roles.values.select { |role| role['anonymous'] }.map { |role| role['id'] }
        targets = @policies.select do |policy|
          policy.dig('entity', 'id') == entity_id && policy['actions'].include?(action) && assigned.include?(policy.dig('role', 'id'))
        end.flat_map { |policy| @predicate.traversed(policy.fetch('predicate'), entity_id) }
        { principal: operation.dig('authorize', 'record') ? entity_id : nil, entities: targets.uniq.sort.freeze,
          record: operation.dig('authorize', 'record') }.freeze
      end

      # Entidades que alguma política lê: mudar uma delas muda a decisão de outra operação (invalida os fatos).
      attr_reader :policy_entities

      def scope = @document.dig('app', 'tenant') ? :tenant : :global
      def operation_ids = @nodes.values.select { |node| %w[command query].include?(node['kind']) }.map { |node| node['id'] }.sort.freeze

      # Não chama o call, a unidade, o pool ou os repositórios. current_revision é da borda confiável.
      def check(operation_id, input:, context:, snapshot:, current_revision:, fields: nil)
        operation = operation!(operation_id)
        normalized = validate_input(operation_id, input)
        context!(context, operation_id)
        fresh!(snapshot, context, current_revision)
        roles = roles!(snapshot, context)
        authorization = operation.fetch('authorize')
        entity_id, action = authorization.dig('entity', 'id'), authorization.fetch('action')
        candidates = @policies.select do |policy|
          policy.dig('entity', 'id') == entity_id && policy['actions'].include?(action) && roles.include?(policy.dig('role', 'id'))
        end
        denied! if candidates.empty?
        candidates.each { |policy| @predicate.validate!(policy.fetch('predicate'), entity_id) }
        # Mesmo um ramo sem linhas exige as entidades do percurso: omissão não prova ausência sob NOT EXISTS.
        candidates.flat_map { |policy| @predicate.traversed(policy.fetch('predicate'), entity_id) }.uniq.each { |id| snapshot.rows(id) }
        row = principal_record(operation, normalized, context, snapshot)
        denied! unless @predicate.in_tenant?(entity_id, row, context)
        applicable = candidates.select { |policy| @predicate.evaluate(policy.fetch('predicate'), entity_id, row, context, snapshot) == true }
        denied! if applicable.empty?
        requested = requested_fields(operation, normalized, fields)
        unless covers?(applicable, requested)
          raise Error.single('data_authorization_fields', 'Concessões aplicáveis não autorizam todos os campos solicitados.')
        end
        unlimited = applicable.reject { |policy| policy.key?('rate_limit') }
        if unlimited.empty? || !covers?(unlimited, requested)
          raise Error.single('data_authorization_rate_limit', 'Autorização depende de limite de taxa; contadores ainda não disponíveis.')
        end
        fresh!(snapshot, context, current_revision)
        Result.new(allowed: true, diagnostics: [].freeze, input: normalized, policy_ids: unlimited.map { |policy| policy['id'] }.sort.freeze)
      rescue Data::Error => error
        Result.new(allowed: false, diagnostics: error.diagnostics.freeze, input: nil, policy_ids: [].freeze)
      end

      private

      def operation!(id)
        operation = @nodes[id]
        unless operation && %w[command query].include?(operation['kind'])
          raise Error.single('data_execution_operation', 'Operação não é um comando ou consulta desta IR.')
        end
        operation
      end

      def context!(context, operation_id)
        unless context.is_a?(Data::Context)
          raise Error.single('data_authorization_context', 'Contexto ou papéis incompatíveis com a operação.')
        end
        if context.system_actor?
          raise Error.single('data_authorization_system_actor', 'Ator de sistema exige autorização por calls do handler; não usa políticas de papéis.')
        end
        scope = @document.dig('app', 'tenant') ? :tenant : :global
        unless context.scope == scope && context.cmd == operation_id
          raise Error.single('data_authorization_context', 'Contexto ou papéis incompatíveis com a operação.')
        end
      end

      def roles!(snapshot, context)
        unless snapshot.roles.all? { |id| @roles.key?(id) && (@roles[id]['anonymous'] || context.actor_id) }
          raise Error.single('data_authorization_context', 'Contexto ou papéis incompatíveis com a operação.')
        end
        snapshot.roles | @roles.values.select { |role| role['anonymous'] }.map { |role| role['id'] }
      end

      def fresh!(snapshot, context, reader)
        unless snapshot.is_a?(Snapshot) && snapshot.matches?(self, context) && reader.respond_to?(:call) &&
               snapshot.revision == reader.call(context)
          raise Error.single('data_authorization_snapshot', 'Fatos de autorização ausentes, incompletos, incompatíveis ou obsoletos.')
        end
      rescue StandardError
        raise Error.single('data_authorization_snapshot', 'Fatos de autorização ausentes, incompletos, incompatíveis ou obsoletos.'), cause: nil
      end

      def principal_record(operation, input, context, snapshot)
        entity_id = operation.dig('authorize', 'entity', 'id')
        reference = operation.dig('authorize', 'record')
        if reference
          row = @predicate.scoped_rows(entity_id, context, snapshot).find { |candidate| candidate['id'] == input.fetch(reference) }
          denied! unless row
          return row
        end
        # Só o CRUD gerado tem correspondência garantida entre nomes de entrada e campos da entidade.
        row = {}
        if operation.dig('implementation', 'name') == 'crud.create'
          row.merge!(input)
          @entities.fetch(entity_id).fetch('fields').each do |field|
            name, default = field.fetch('name'), field['default']
            next if row.key?(name)
            if default
              value = default['kind'] == 'literal' ? default['value'] :
                { 'current_actor' => context.actor_id, 'current_tenant' => context.tenant_id }[default['name']]
              row[name] = Data::Values.coerce(value, field, currency: @document.dig('app', 'currency'))
            elsif field['nullable']
              row[name] = nil
            end
          end
        end
        column = @tables.fetch(entity_id)['tenant_column']
        row[column] = context.tenant_id if column
        row.freeze
      end

      def requested_fields(operation, input, explicit)
        names = @entities.fetch(operation.dig('authorize', 'entity', 'id')).fetch('fields').map { |field| field['name'] }
        if explicit && (!explicit.is_a?(Array) || !explicit.all? { |field| (field.is_a?(String) || field.is_a?(Symbol)) && names.include?(field.to_s) })
          raise Error.single('data_authorization_fields', 'Concessões aplicáveis não autorizam todos os campos solicitados.')
        end
        if %w[crud.create crud.update].include?(operation.dig('implementation', 'name'))
          reference = operation.dig('authorize', 'record')
          (input.keys - [reference]) | Array(explicit).map(&:to_s)
        else
          explicit ? explicit.map(&:to_s) : names
        end
      end

      def covers?(policies, fields)
        policies.any? { |policy| policy['fields'] == '*' } || (fields - policies.flat_map { |policy| policy['fields'] }).empty?
      end

      def denied!
        raise Error.single('data_authorization_denied', 'Acesso recusado pela política ou pelo escopo do registro.')
      end
    end
  end
end

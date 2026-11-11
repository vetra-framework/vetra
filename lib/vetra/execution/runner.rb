# frozen_string_literal: true

require 'securerandom'

module Vetra
  module Execution
    # Relógio da operação: o instante da unidade, compartilhado pelas criações e composições (capacidade `clock`).
    OperationClock = ::Data.define(:now) do
      def inspect = '#<Vetra::Execution::OperationClock>'
      alias to_s inspect
    end

    # `fail!` do `call`: recusa de negócio. A K19 a mapeia para 422; aqui só atravessa a unidade, que a desfaz por inteiro.
    # Carrega o campo e o motivo como dados, nunca no texto do diagnóstico.
    class Failure < Data::Error
      attr_reader :field, :reason

      def initialize(field, reason)
        @field, @reason = field.to_s.dup.freeze, reason.to_s.dup.freeze
        super([Graph::Diagnostic.new(code: 'execution_failure', message: 'Regra de negócio recusou a operação.',
                                     pointer: "/#{@field}", severity: :error)])
      end
    end

    # O que o bloco `call` enxerga além das capacidades: só `fail!`.
    class CallHost
      def fail!(field, reason = nil)
        raise Failure.new(field, reason)
      end
    end

    # Despacho das etapas 1 a 5 e 8 do ADR-016 (ADR-045). As etapas 6 e 7 têm ganchos próprios, vazios nesta entrega:
    # a K18 preenche `persist` (reautorização do estado final) e a K19, `register` (eventos e idempotência).
    #
    #   1 resolve      a borda resolve identidade, tenant e papéis (nunca vêm da entrada)
    #   2 validate     o contrato do grafo valida e normaliza a entrada
    #   3 authorize    a política é avaliada sobre os fatos da borda, fora do pool da operação
    #   4 open         a unidade abre, com os limites da C15 e o contexto assinado
    #   5 execute      o `call` verificado ou a primitiva, só com as capacidades de `uses`
    #   6 persist      (K18) reautoriza o estado final
    #   7 register     (K19) eventos, idempotência
    #   8 confirm      o commit; depois dele (ou da falha) a autoridade publica a nova geração, se aplicável
    #
    # Recusas das etapas 1 a 3 voltam como `Outcome`, sem transação. O que acontece depois da etapa 4 (`Failure`, conflito,
    # timeout, erro inesperado) levanta, com a unidade já desfeita por inteiro; a K19 o traduz para 422, 409 e 500.
    class Runner
      Outcome = ::Data.define(:status, :value, :diagnostics) do
        def ok? = status == :ok
        def code = diagnostics.first&.code
        def inspect = "#<Vetra::Execution::Runner::Outcome status=#{status}>"
        alias to_s inspect
      end

      # Recusa interna das etapas 1 a 3, convertida em Outcome por `run`.
      class Refusal < StandardError
        attr_reader :status, :diagnostics

        def initialize(status, diagnostics)
          @status, @diagnostics = status, diagnostics
          super('recusa')
        end
      end
      private_constant :Refusal

      WRITE_ACTIONS = %w[create update delete].freeze

      attr_reader :authorization

      # unit_options: statement_timeout:, lock_timeout:, isolation: (C15), aplicados a toda operação.
      def initialize(linked:, catalog:, unit:, edge:, unit_options: {})
        unless linked.is_a?(Graph::LinkedGraph) && catalog.is_a?(Data::Repositories) && unit.is_a?(Data::UnitOfWork) && edge.is_a?(Edge)
          raise Error.single('execution_runner', 'O Runner exige o grafo vinculado, o catálogo, a unidade e a borda.')
        end
        @linked, @catalog, @unit, @edge = linked, catalog, unit, edge
        @unit_options = unit_options.slice(:statement_timeout, :lock_timeout, :isolation).freeze
        @authorization = Authorization.new(linked.document)
        nodes = linked.document.fetch('nodes')
        @operations = nodes.select { |node| %w[command query].include?(node['kind']) }.to_h { |node| [node['id'], node] }.freeze
        @capabilities = nodes.select { |node| node['kind'] == 'capability' }.to_h { |node| [node['id'], node] }.freeze
        @entities = nodes.select { |node| node['kind'] == 'entity' }.to_h { |node| [node['id'], node] }.freeze
        @contracts = nodes.select { |node| node['kind'] == 'contract' }.to_h { |node| [node['id'], node] }.freeze
        freeze
      end

      def run(operation_id, input, credentials: nil)
        operation = @operations.fetch(operation_id) do
          raise Error.single('data_execution_operation', 'Operação não é um comando ou consulta desta IR.')
        end
        identity = resolve(credentials)                                   # 1
        context = context_for(identity, operation)
        normalized = validate(operation_id, input)                        # 2
        authorize(operation_id, normalized, context, identity)            # 3
        value = nil
        begin
          value = in_unit(operation, identity, context) { |unit| execute(unit, operation, normalized) } # 4 a 7
        rescue Sequel::DatabaseError => error
          # BEGIN e COMMIT: a unidade só traduz os erros retentáveis. O resto sai como erro de dados, sem a mensagem do driver.
          raise Data::DatabaseErrors.translate(error), cause: nil
        ensure
          confirm(operation, context)                                     # 8
        end
        Outcome.new(status: :ok, value: value, diagnostics: [].freeze)
      rescue Refusal => refusal
        Outcome.new(status: refusal.status, value: nil, diagnostics: refusal.diagnostics.freeze)
      end

      def inspect = '#<Vetra::Execution::Runner>'
      alias to_s inspect

      private

      def refuse!(status, error)
        raise Refusal.new(status, error.diagnostics), cause: nil
      end

      def resolve(credentials)
        @edge.resolve(credentials)
      rescue Data::Error => error
        refuse!(:unresolved, error)
      end

      def context_for(identity, operation)
        scope = @authorization.scope
        # O tenant da identidade vai como veio: o Context recusa tenant numa aplicação global e a falta dele numa de tenant.
        Data::Context.new(scope: scope, tenant_id: identity.tenant_id, actor_id: identity.actor_id,
                          op_id: SecureRandom.uuid, cmd: operation['id'])
      rescue Data::Error => error
        refuse!(:denied, error)
      end

      def validate(operation_id, input)
        @authorization.validate_input(operation_id, input)
      rescue Data::Error => error
        refuse!(:invalid, error)
      end

      def authorize(operation_id, input, context, identity)
        request = FactsRequest.new(authorization: @authorization, operation_id: operation_id, context: context,
                                   roles: identity.roles, input: input)
        snapshot = @edge.snapshot(request)
        result = @authorization.check(operation_id, input: input, context: context, snapshot: snapshot,
                                      current_revision: @edge.authority)
        raise Refusal.new(:denied, result.diagnostics) unless result.allowed?
        result
      rescue Data::Error => error
        refuse!(:denied, error)
      end

      def in_unit(operation, identity, context)
        claims = { actor_id: context.actor_id, op_id: context.op_id, cmd: context.cmd }.merge(@unit_options)
        claims[:tenant_id] = context.tenant_id if context.scope == :tenant
        mode = operation['kind'] == 'query' ? :read : :transaction
        @unit.public_send(mode, **claims) do |unit|
          result = yield unit
          persist(unit, operation, result)
          register(unit, operation, result)
          result
        end
      end

      # Etapa 6, da K18: reautoriza o estado final e confere os campos de transição.
      def persist(_unit, _operation, _result); end

      # Etapa 7, da K19: eventos do `emits` e registro de idempotência, na mesma unidade.
      def register(_unit, _operation, _result); end

      def execute(unit, operation, input)
        binding = @linked.binding_for(operation['kind'], operation['id'])
        if binding['kind'] == 'ruby'
          arguments = binding['arguments'].map { |argument| capability(argument.dig('capability', 'id'), unit) }
          # Todos os campos do contrato: o opcional ausente chega ao `call` como nil, sem NoMethodError.
          fields = @contracts.fetch(operation.dig('input', 'id')).fetch('fields').map { |field| field['name'] }
          struct = ::Data.define(*fields.map(&:to_sym)).new(**fields.to_h { |name| [name.to_sym, input[name]] })
          @linked.run_implementation(operation['kind'], operation['id'], host: CallHost.new, input: struct, arguments: arguments)
        else
          primitive(operation, binding['name'], unit, input)
        end
      end

      def capability(id, unit)
        node = @capabilities.fetch(id)
        config = node['config']
        if config['type'] == 'repository'
          @catalog.bind(id, unit: unit)
        elsif config['type'] == 'deterministic' && node['adapter'] == 'core.clock'
          OperationClock.new(now: unit.now)
        else
          raise Error.single('execution_capability', 'Capacidade sem executor nesta versão do Runner.')
        end
      end

      def primitive(operation, name, unit, input)
        repository = @catalog.bind(operation.fetch('uses').first.fetch('id'), unit: unit)
        action = name.delete_prefix('crud.')
        if Graph::Schema::CRUD_ACTIONS.include?(action) && name == "crud.#{action}"
          case action
          when 'create' then repository.create!(**input.transform_keys(&:to_sym))
          when 'read' then repository.find!(input.fetch('id'))
          when 'update' then repository.update!(input.fetch('id'), **input.except('id').transform_keys(&:to_sym))
          when 'delete' then repository.delete!(input.fetch('id'))
          end
        else
          link(operation, name, repository, input)
        end
      end

      def link(operation, name, repository, input)
        verb, relation_name = Graph::RelationCommands.parse(name)
        owner = @entities.fetch(operation.dig('authorize', 'entity', 'id'))
        relation = owner['relations'].find { |entry| entry['kind'] == 'many_to_many' && entry['name'] == relation_name }
        unless verb && relation
          raise Error.single('execution_capability', 'Capacidade sem executor nesta versão do Runner.')
        end
        keys = Graph::RelationCommands.input_fields(owner, @entities.fetch(relation.dig('target', 'id'))).map { |field| field['name'] }
        repository.public_send("#{Graph::RelationCommands.action(verb, relation)}!", input.fetch(keys.first), input.fetch(keys.last))
      end

      # Depois do commit, ou da falha depois dele: o comando que grava uma entidade lida por alguma política muda os
      # fatos de outras operações, e a autoridade em processo precisa de uma nova geração. Publicar também na falha é
      # conservador (o pior caso é um snapshot a mais refeito) e cobre o commit de resultado incerto.
      def confirm(operation, context)
        return unless @edge.publishes? && writes_policy_entity?(operation)
        @edge.publish!(context)
      end

      def writes_policy_entity?(operation)
        return false unless operation['kind'] == 'command'
        operation['uses'].any? do |reference|
          config = @capabilities.fetch(reference['id'])['config']
          config['type'] == 'repository' && config['access'] == 'read_write' && @authorization.policy_entities.include?(config.dig('entity', 'id'))
        end
      end
    end
  end
end

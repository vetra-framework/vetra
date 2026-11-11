# frozen_string_literal: true

require 'securerandom'

module Vetra
  module Execution
    # Relógio da operação: o instante da unidade, compartilhado pelas criações e composições (capacidade `clock`).
    OperationClock = ::Data.define(:now) do
      def inspect = '#<Vetra::Execution::OperationClock>'
      alias to_s inspect
    end

    # `fail!` do `call`: recusa de negócio (422). Atravessa a unidade, que a desfaz por inteiro.
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

    # As oito etapas do ADR-016 (ADR-045, ADR-046 e ADR-047).
    #
    #   1 resolve      a borda resolve identidade, tenant e papéis (nunca vêm da entrada)
    #   2 validate     o contrato do grafo valida e normaliza a entrada
    #   3 authorize    a política é avaliada sobre os fatos da borda, fora do pool da operação
    #   4 open         a unidade abre, com os limites da C15 e o contexto assinado; a chave de idempotência é reivindicada aqui
    #   5 execute      o `call` verificado ou a primitiva, só com as capacidades de `uses`
    #   6 persist      reautoriza o estado final (K18)
    #   7 register     os eventos do `emits` e o resultado da idempotência, na mesma unidade (K19)
    #   8 confirm      o commit; depois dele (ou da falha) a autoridade publica a nova geração, se aplicável
    #
    # `run` devolve sempre um `Outcome`, com o status do ADR-016 (422, 403, 404, 409, 500) e a indicação de resposta retentável;
    # só um erro de programação (operação que o grafo não tem) levanta. `run!` levanta o erro de dados em vez de mapeá-lo.
    # Falha de serialização e deadlock repetem a operação inteira, depois do rollback, até 3 vezes, só quando ela é segura
    # para repetir (ADR-016; ADR-047).
    class Runner
      # status: :ok, :unresolved (401), :invalid (422), :denied (403), :not_found (404), :failed (422, `fail!` ou chave
      # reutilizada), :conflict (409) e :error (500). `replayed`: o resultado veio do registro de idempotência (em JSON, sem
      # executar o `call`). `retryable`: o cliente pode repetir. `attempts`: quantas vezes a operação foi tentada.
      Outcome = ::Data.define(:status, :value, :diagnostics, :replayed, :retryable, :attempts) do
        def initialize(status:, value: nil, diagnostics: [].freeze, replayed: false, retryable: false, attempts: 1)
          super
        end

        def ok? = status == :ok
        def code = diagnostics.first&.code
        def http_status = self.class::HTTP.fetch(status)
        def replayed? = replayed
        def retryable? = retryable
        def inspect = "#<Vetra::Execution::Runner::Outcome status=#{status}>"
        alias to_s inspect
      end

      Outcome.const_set(:HTTP, { ok: 200, unresolved: 401, invalid: 422, denied: 403, not_found: 404, failed: 422, conflict: 409, error: 500 }.freeze)

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
      # Repetições (além da primeira tentativa) depois de falha de serialização ou deadlock (ADR-016).
      MAX_RETRIES = 3
      RETRY_BASE = 0.05

      attr_reader :authorization

      # unit_options: statement_timeout:, lock_timeout:, isolation: (C15), aplicados a toda operação. `sleeper` e `random` são
      # injetáveis para a espera crescente, com variação aleatória, entre as repetições.
      def initialize(linked:, catalog:, unit:, edge:, unit_options: {}, sleeper: ->(seconds) { sleep(seconds) }, random: -> { rand })
        unless linked.is_a?(Graph::LinkedGraph) && catalog.is_a?(Data::Repositories) && unit.is_a?(Data::UnitOfWork) && edge.is_a?(Edge)
          raise Error.single('execution_runner', 'O Runner exige o grafo vinculado, o catálogo, a unidade e a borda.')
        end
        @linked, @catalog, @unit, @edge = linked, catalog, unit, edge
        @unit_options = unit_options.slice(:statement_timeout, :lock_timeout, :isolation).freeze
        @sleeper, @random = sleeper, random
        @authorization = Authorization.new(linked.document)
        @currency = linked.document.dig('app', 'currency')
        nodes = linked.document.fetch('nodes')
        @operations = nodes.select { |node| %w[command query].include?(node['kind']) }.to_h { |node| [node['id'], node] }.freeze
        @capabilities = nodes.select { |node| node['kind'] == 'capability' }.to_h { |node| [node['id'], node] }.freeze
        @entities = nodes.select { |node| node['kind'] == 'entity' }.to_h { |node| [node['id'], node] }.freeze
        @contracts = nodes.select { |node| node['kind'] == 'contract' }.to_h { |node| [node['id'], node] }.freeze
        freeze
      end

      def run(operation_id, input, credentials: nil, idempotency_key: nil)
        perform(operation_id, input, credentials, idempotency_key, false)
      end

      # Igual a `run`, mas o erro depois da etapa 4 (e das repetições) levanta como erro de dados, para testes e diagnóstico.
      def run!(operation_id, input, credentials: nil, idempotency_key: nil)
        perform(operation_id, input, credentials, idempotency_key, true)
      end

      # A forma JSON do resultado de uma operação, a mesma que o registro de idempotência guarda e devolve na repetição: os campos
      # do contrato de saída, e só eles.
      def serialize(operation_id, value)
        operation = @operations.fetch(operation_id) { raise Error.single('data_execution_operation', 'Operação não é um comando ou consulta desta IR.') }
        contract_json(operation.dig('output', 'id'), value, 'data_idempotency_result')
      end

      def inspect = '#<Vetra::Execution::Runner>'
      alias to_s inspect

      private

      def perform(operation_id, input, credentials, key, raising)
        operation = @operations.fetch(operation_id) do
          raise Error.single('data_execution_operation', 'Operação não é um comando ou consulta desta IR.')
        end
        attempt = 0
        identity = resolve(credentials)                                   # 1
        context = context_for(identity, operation)
        normalized = validate(operation_id, input)                        # 2
        key_input = check_key!(operation, key, normalized)
        # `while`, e não `loop`: o `loop` engoliria um StopIteration levantado pelo corpo e devolveria o rollback como resultado.
        while true # rubocop:disable Style/InfiniteLoop
          attempt += 1
          authorize(operation_id, normalized, context, identity)          # 3
          begin
            value, replayed = attempt_unit(operation, identity, context, normalized, key, key_input) # 4 a 8
            return Outcome.new(status: :ok, value: value, replayed: replayed, attempts: attempt)
          rescue Data::Error => error
            if repeat?(error, operation) && attempt <= MAX_RETRIES
              @sleeper.call(RETRY_BASE * (2**(attempt - 1)) * (0.5 + @random.call))
              next
            end
            raise if raising
            return outcome_for(error, attempt)
          end
        end
      rescue Refusal => refusal
        Outcome.new(status: refusal.status, value: nil, diagnostics: refusal.diagnostics.freeze, attempts: [attempt, 1].max)
      rescue StandardError => error
        raise if raising || error.is_a?(Data::Error)
        # Erro inesperado (500): sem a mensagem nem a causa do erro original.
        diagnostic = Graph::Diagnostic.new(code: 'execution_unexpected', message: 'A operação falhou de forma inesperada.', pointer: '/', severity: :error)
        Outcome.new(status: :error, diagnostics: [diagnostic].freeze, attempts: [attempt, 1].max)
      end

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
        Data::Context.new(scope: scope, tenant_id: identity.tenant_id, actor_id: identity.actor_id, system_actor: identity.system_actor,
                          op_id: SecureRandom.uuid, cmd: operation['id'])
      rescue Data::Error => error
        refuse!(:denied, error)
      end

      def validate(operation_id, input)
        @authorization.validate_input(operation_id, input)
      rescue Data::Error => error
        refuse!(:invalid, error)
      end

      # Chave de idempotência (ADR-043, §4): só um comando a aceita, a chave tem o formato do registro, e um comando cuja saída
      # leva campo pessoal a recusa antes da etapa 4, porque o resultado não pode ser guardado em claro.
      def check_key!(operation, key, input)
        return if key.nil?
        unless operation['kind'] == 'command'
          refuse!(:invalid, Error.single('execution_idempotency_query', 'Chave de idempotência só vale para um comando.'))
        end
        # valid_encoding? e ascii_compatible?: um String inválido ou em UTF-16 faria o `match?` levantar, e a chave ruim viraria 500.
        unless key.is_a?(String) && key.encoding.ascii_compatible? && key.valid_encoding? && Data::Idempotency::KEY.match?(key)
          refuse!(:invalid, Error.single('data_idempotency_key', 'A chave deve ter de 1 a 255 caracteres ASCII visíveis.'))
        end
        if personal_contract?(operation.dig('output', 'id'), [])
          refuse!(:invalid, Error.single('execution_idempotency_personal', 'O resultado deste comando leva campo pessoal e não pode ser guardado em claro.'))
        end
        # O hash da entrada vem do contrato (campos declarados, na forma canônica dos eventos: instantes com microssegundos, decimais
        # exatos) e precisa ter forma canônica; um número não inteiro dentro de um campo JSON não tem, e a chave é recusada (422).
        json = contract_json(operation.dig('input', 'id'), input, 'data_idempotency_input', present_only: true)
        begin
          Graph::Canonical.dump(JSON.parse(JSON.generate(json)))
        rescue Graph::Error, JSON::GeneratorError, JSON::ParserError, TypeError
          refuse!(:invalid, Error.single('data_idempotency_input', 'A entrada deve ter forma canônica para ter chave de idempotência (um número não inteiro em campo JSON não tem).'))
        end
        json
      rescue Data::Error => error
        refuse!(:invalid, error)
      end

      # O JSON de um valor segundo um contrato, só com os campos declarados e na forma canônica dos eventos (decimais e dinheiro como
      # texto exato, instantes em UTC com microssegundos, datas ISO 8601), recursivamente em `record` e `collection`. É a forma que a
      # idempotência guarda (resultado) e de que tira o hash (entrada): nada fora do contrato é gravado, então um campo pessoal que
      # o contrato não declara nunca chega ao registro. Um valor que não tem um campo declarado levanta `error_code`.
      def contract_json(contract_id, value, error_code, present_only: false)
        contract = @contracts.fetch(contract_id) { return nil }
        if contract['collection']
          json_shape!(value, error_code) unless value.is_a?(Array)
          return value.map { |item| contract_item(contract, item, error_code, present_only) }
        end
        contract_item(contract, value, error_code, present_only)
      end

      def contract_item(contract, value, error_code, present_only)
        contract.fetch('fields').each_with_object({}) do |field, json|
          name = field['name']
          found, raw = field_of(value, name)
          unless found
            next if present_only
            # Um campo obrigatório do contrato que o valor não tem: o valor não é o que o contrato declara. O opcional ausente some.
            json_shape!(nil, error_code) if field['required']
            next
          end
          json[name] = field_json(field, raw, error_code)
        end
      end

      def field_of(value, name)
        if value.is_a?(Hash)
          key = value.key?(name) ? name : name.to_sym
          [value.key?(key), value[key]]
        elsif value.respond_to?(name)
          [true, value.public_send(name)]
        else
          [false, nil]
        end
      end

      def field_json(field, raw, error_code)
        if raw.nil?
          json_shape!(raw, error_code) unless field['nullable']
          return nil
        end
        type = field.fetch('type')
        case type.fetch('name')
        when 'record' then contract_json(type.dig('contract', 'id'), raw, error_code) || json_shape!(raw, error_code)
        when 'collection'
          json_shape!(raw, error_code) unless raw.is_a?(Array)
          raw.map { |item| contract_json(type.dig('contract', 'id'), item, error_code) }
        when 'json' then json_value(raw, error_code)
        else scalar_json(field, raw, error_code)
        end
      end

      # Um campo escalar na forma canônica dos eventos, depois de conferido pela **mesma** conferência que o framework faz nas entradas
      # (`Values.coerce`: tipo, nulidade, enum, UUID, comprimento, escala e precisão do decimal, dinheiro, instante e data de verdade). Um
      # valor que não confere (um Hash num campo de texto, `7` num id, um decimal fora da escala, uma data que não existe) não é guardado.
      # O JSON de uma repetição (texto, decimal, instante e data em forma canônica, dinheiro como objeto) também confere, e volta igual.
      def scalar_json(field, raw, error_code)
        Data::Values.event_value(Data::Values.coerce(raw, field, currency: @currency), field)
      rescue Data::Error
        json_shape!(raw, error_code)
      end

      def json_value(value, error_code)
        case value
        when nil, true, false, String, Integer then value
        when Float then value.finite? ? value : json_shape!(value, error_code)
        when Array then value.map { |item| json_value(item, error_code) }
        when Hash then value.to_h { |key, item| [key.to_s, json_value(item, error_code)] }
        else json_shape!(value, error_code)
        end
      end

      def json_shape!(_value, error_code)
        message = error_code == 'data_idempotency_result' ? 'O resultado guardado deve ser JSON válido de até 64 KiB, nos campos do contrato.' : 'A entrada não tem a forma do contrato.'
        raise Error.single(error_code, message), cause: nil
      end

      def personal_contract?(contract_id, seen)
        return false if contract_id.nil? || seen.include?(contract_id)
        contract = @contracts[contract_id] or return false
        contract.fetch('fields').any? do |field|
          field.dig('privacy', 'personal') || personal_contract?(field.dig('type', 'contract', 'id'), seen + [contract_id])
        end
      end

      def authorize(operation_id, input, context, identity)
        # Ator de sistema: a concessão é o `calls` do handler, estático no grafo; não há fatos nem revisão a confirmar.
        if identity.system_actor
          result = @authorization.check(operation_id, input: input, context: context)
          raise Refusal.new(:denied, result.diagnostics) unless result.allowed?
          return result
        end
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

      # Uma tentativa das etapas 4 a 8. Devolve [valor, repetição de resultado guardado].
      def attempt_unit(operation, identity, context, input, key, key_input)
        in_unit(operation, identity, context, input, key, key_input) { |unit| execute(unit, operation, input) }
      rescue Sequel::DatabaseError => error
        # BEGIN e COMMIT: a unidade só traduz os erros retentáveis. O resto sai como erro de dados, sem a mensagem do driver.
        raise Data::DatabaseErrors.translate(error), cause: nil
      ensure
        confirm(operation, context)                                       # 8
      end

      def in_unit(operation, identity, context, input, key, key_input)
        claims = { actor_id: context.actor_id, system_actor: context.system_actor, op_id: context.op_id, cmd: context.cmd }.merge(@unit_options)
        claims[:tenant_id] = context.tenant_id if context.scope == :tenant
        mode = operation['kind'] == 'query' ? :read : :transaction
        guard = AccessGuard.new(authorization: @authorization, catalog: @catalog, unit: @unit, roles: identity.roles)
        @unit.public_send(mode, **claims, guard: guard) do |unit|
          closed = false
          begin
            # Etapa 4: a chave é reivindicada na unidade, no contexto transacional da operação; cada tentativa a reivindica de novo.
            claim = key && Data::Idempotency.new(unit).claim!(command: operation['id'], key: key, input: key_input)
            if claim&.replay
              closed = true
              next [claim.result, true]
            end
            result = yield unit
            persist(unit, operation, result, guard)
            register(unit, operation, result, claim)
            closed = true
            [result, false]
          ensure
            # Um call que sai por `throw` (ou `break`) pularia a reautorização e o Sequel confirmaria a transação: sem o
            # fechamento completo, ela nunca é confirmada.
            unit.abandon! unless closed
          end
        end
      end

      # Etapa 6: reautoriza o estado final de cada linha criada ou alterada, com fatos relidos na unidade (K18). Os campos de
      # transição são conferidos pelo repositório a cada escrita. Um ator de sistema não passa por políticas: o `calls` do
      # handler já foi conferido na etapa 3.
      def persist(_unit, _operation, _result, guard)
        guard.reauthorize!
      end

      # Etapa 7: os eventos do `emits`, a partir do registro devolvido, e o resultado da idempotência, na mesma unidade. O
      # `call` nunca grava um evento nem o registro. Um replay não chega aqui: não repete evento nem escrita.
      def register(unit, operation, result, claim)
        @catalog.emit_declared!(unit, result) if operation['emits']&.any?
        return unless claim
        # O resultado guardado é o do contrato declarado (campos declarados, nenhum pessoal: conferido antes da etapa 4), e não o que o
        # call devolveu por inteiro: um valor que não tem a forma do contrato desfaz a unidade (`data_idempotency_result`).
        Data::Idempotency.new(unit).complete!(claim, contract_json(operation.dig('output', 'id'), result, 'data_idempotency_result'))
      end

      # Mapeamento do erro depois da etapa 4 para o status do ADR-016 (ADR-047).
      def outcome_for(error, attempts)
        status, retryable =
          case error
          when Failure, Data::IdempotencyKeyReuse then [:failed, false]
          when Data::RecordNotFound then [:not_found, false]
          when Data::Conflict then [:conflict, error.retryable?]
          when Data::StatementTimeout then [:error, true]
          else
            [error.code.start_with?('data_authorization') ? :denied : :error, false]
          end
        Outcome.new(status: status, diagnostics: error.diagnostics.freeze, retryable: retryable, attempts: attempts)
      end

      # Falha de serialização e deadlock repetem a operação inteira, mas só se ela é segura para repetir: nenhuma capacidade
      # `retry_safe: false` e nenhum `unsafe_effect` (ADR-004, §5, e ADR-022, §6).
      def repeat?(error, operation)
        concurrent = error.is_a?(Data::SerializationFailure) || (error.is_a?(Data::Conflict) && error.kind == :deadlock)
        concurrent && retry_safe?(operation)
      end

      def retry_safe?(operation)
        return false if operation['unsafe_effect']
        operation['uses'].all? { |reference| @capabilities.fetch(reference['id'])['retry_safe'] != false }
      end

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

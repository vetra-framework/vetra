# frozen_string_literal: true

require 'digest'
require 'time'
require 'timeout'

module Vetra
  module Execution
    # Consumidor interno do Relay (ADR-048). Uma reserva por vez; o handler não abre uma unidade. Cada comando de
    # `calls` atravessa o Runner, com a identidade do tenant da entrega, e confirma independentemente dos demais.
    class HandlerRunner
      TIMEOUT = 30

      class CommandFailure < StandardError
        attr_reader :outcome
        def initialize(outcome)
          @outcome = outcome
          super('O comando do handler falhou.')
        end

        def permanent? = !outcome.retryable? && outcome.status != :error
      end

      # Não guarda o evento no texto de erros nem em inspect. As ocorrências reiniciam a cada tentativa da entrega.
      class Host < CallHost
        def initialize(runner, handler, delivery)
          @runner, @handler, @delivery = runner, handler, delivery
          @identity = Identity.new(tenant_id: delivery.tenant_id, system_actor: handler.fetch('id'))
          @occurrences = Hash.new(0)
        end

        def key_for(scope)
          occurrence = (@occurrences[scope] += 1)
          base = HandlerRunner.event_key(@handler.fetch('id'), @delivery.event_id)
          occurrence == 1 ? base : "#{base}:#{occurrence}"
        end

        # IDs completos ou nomes locais do domínio do handler. Devolve sempre a forma JSON do contrato de saída,
        # inclusive na primeira execução: uma repetição não muda a forma dos valores usados pelo restante do call.
        def call_command(command, input)
          id = command.to_s
          id = "#{@handler.dig('domain', 'id')}.#{id}" unless id.include?('.')
          unless @handler.fetch('calls').any? { |reference| reference['id'] == id }
            raise Error.single('data_authorization_system_actor', 'O comando não está nos calls do handler deste ator de sistema.')
          end
          outcome = @runner.run(id, input, credentials: @identity, idempotency_key: key_for([:command, id]),
                                idempotency_origin: :event,
                                idempotency_event: { handler: @handler.fetch('id'), event_id: @delivery.event_id,
                                                     event_created_at: HandlerRunner.event_time(@delivery.event_created_at) })
          raise CommandFailure.new(outcome) unless outcome.ok?
          Data::Values.immutable(@runner.serialize(id, outcome.value))
        end

        def inspect = '#<Vetra::Execution::HandlerRunner::Host>'
        alias to_s inspect
      end

      # O provedor é injetado pelo hospedeiro confiável por ID de capacidade. O call só recebe esta fachada congelada;
      # o despachante acrescenta a chave e aplica o timeout da capacidade, dentro do orçamento total do handler.
      class Effect
        def initialize(provider, node, host)
          @provider, @node, @host = provider, node, host
          freeze
        end

        def method_missing(name, *args, **kwargs, &block)
          return super unless @provider.respond_to?(name)
          config = @node.fetch('config')
          kwargs = kwargs.merge(idempotency_key: @host.key_for([:effect, @node.fetch('id')])) if config['idempotency_key']
          Timeout.timeout(config.fetch('timeout_ms') / 1000.0) { @provider.public_send(name, *args, **kwargs, &block) }
        end

        def respond_to_missing?(name, include_private = false) = @provider.respond_to?(name) || super
        def inspect = '#<Vetra::Execution::HandlerRunner::Effect>'
        alias to_s inspect
      end

      # SHA-256 da tupla canônica evita ambiguidades de separador e mantém a chave ASCII abaixo de 255 caracteres,
      # mesmo com um handler de 128 caracteres. O principal continua system:<handler>, definido pela Idempotency.
      def self.event_key(handler, event_id)
        "event:#{Digest::SHA256.hexdigest(Graph::Canonical.dump([handler, event_id]))}"
      end

      def self.event_time(value) = value.is_a?(Time) ? value : Time.parse(value).utc

      # timeout é um orçamento do worker (padrão 30 s), sem campo novo na IR. A lease precisa cobrir pelo menos 2x
      # esse orçamento. Valores menores permitem exercitar cancelamento sem esperar 30 s nos testes e nas sondas.
      def initialize(linked:, relay:, runner:, effects: {}, timeout: TIMEOUT, lease: Data::Relay::LEASE)
        unless linked.is_a?(Graph::LinkedGraph) && linked.document.dig('app', 'tenant') && SQL::Outbox.needed?(linked.document)
          raise Error.single('execution_handler', 'Handlers de sistema exigem grafo vinculado, tenant e outbox.')
        end
        unless (timeout.is_a?(Integer) || timeout.is_a?(Float)) && timeout.finite? && timeout.positive? && lease.is_a?(Integer) &&
               lease.between?(1, 3600) && lease >= timeout * 2
          raise Error.single('execution_handler_timeout', 'Timeout deve ser positivo e finito, com lease inteira de 1 a 3600 s e pelo menos o dobro do timeout.')
        end
        @linked, @relay, @runner, @effects, @timeout, @lease = linked, relay, runner, effects.dup.freeze, timeout, lease
        @nodes = linked.document.fetch('nodes').to_h { |node| [node.fetch('id'), node] }.freeze
        @handlers = @nodes.select { |_, node| node['kind'] == 'handler' }.freeze
        @handlers.each_value do |handler|
          linked.binding_for('handler', handler.fetch('id'))
          handler.fetch('uses').each do |reference|
            node = @nodes.fetch(reference.fetch('id'))
            unless (node.dig('config', 'type') == 'external' && @effects.key?(node['id'])) || node['adapter'] == 'core.clock'
              raise Error.single('execution_handler_capability', 'Capacidade do handler sem provedor externo ou executor determinístico.')
            end
          end
        end
        freeze
      end

      def work(handler_id, limit: 10)
        handler = @handlers[handler_id]
        raise Error.single('data_relay_handler', 'Handler sem evento declarado no grafo.') unless handler
        unless limit.is_a?(Integer) && limit.between?(1, 1000)
          raise Error.single('data_relay_limit', 'Reserva exige limite entre 1 e 1000 e lease entre 1 e 3600 segundos.')
        end
        counts = { done: 0, retry: 0, dead: 0, lost: 0 }
        limit.times do
          delivery = @relay.reserve(handler_id, limit: 1, lease: @lease).first
          break unless delivery
          outcome = deliver(handler, delivery)
          counts[outcome] += 1
        end
        counts.freeze
      end

      def inspect = '#<Vetra::Execution::HandlerRunner>'
      alias to_s inspect

      private

      def deliver(handler, delivery)
        Timeout.timeout(@timeout, HandlerTimeout) { execute(handler, delivery) }
        @relay.complete(delivery) ? :done : :lost
      rescue HandlerTimeout => error
        # Mantém a lease do worker interrompido: outro worker só recupera depois dela, além da espera crescente.
        @relay.failed(delivery, error, retain_lease: true) || :lost
      rescue CommandFailure => error
        @relay.failed(delivery, error, permanent: error.permanent?) || :lost
      rescue Data::Relay::PermanentFailure, Failure => error
        @relay.failed(delivery, error, permanent: true) || :lost
      rescue Data::Error => error
        permanent = %w[data_authorization_system_actor execution_handler_delivery].include?(error.code)
        @relay.failed(delivery, error, permanent: permanent) || :lost
      rescue StandardError => error
        @relay.failed(delivery, error) || :lost
      end

      def execute(handler, delivery)
        event = @nodes[delivery.event]
        unless delivery.handler == handler['id'] && handler.fetch('on').any? { |ref| ref['id'] == delivery.event } &&
               event && event['version'] == delivery.version
          raise Error.single('execution_handler_delivery', 'Entrega incompatível com o handler ou com a versão do evento.')
        end
        # Confere o tenant mesmo quando o handler só usa uma capacidade externa e não chama comando algum.
        Data::Context.new(scope: :tenant, tenant_id: delivery.tenant_id, system_actor: handler['id'],
                          op_id: SecureRandom.uuid, cmd: handler['id'])
        host = Host.new(@runner, handler, delivery)
        fields = @nodes.fetch(event.dig('payload', 'id')).fetch('fields')
        input = ::Data.define(*fields.map { |field| field.fetch('name').to_sym }).new(
          **fields.to_h { |field| [field.fetch('name').to_sym, Data::Values.immutable(delivery.payload[field.fetch('name')])] })
        arguments = @linked.binding_for('handler', handler['id']).fetch('arguments').map do |argument|
          node = @nodes.fetch(argument.dig('capability', 'id'))
          if node['adapter'] == 'core.clock'
            OperationClock.new(now: self.class.event_time(delivery.event_created_at).freeze)
          else
            Effect.new(@effects.fetch(node['id']), node, host)
          end
        end
        @linked.run_implementation('handler', handler['id'], host: host, input: input, arguments: arguments)
      end
    end
  end
end

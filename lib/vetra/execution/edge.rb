# frozen_string_literal: true

module Vetra
  module Execution
    # Identidade resolvida pela borda confiável (ADR-045, §1): quem, em que tenant e com quais papéis. Nada disto vem da
    # entrada do cliente. Sem tenant numa aplicação global; sem papéis, visitante.
    Identity = ::Data.define(:tenant_id, :actor_id, :roles, :system_actor, :generation) do
      # `system_actor` é o handler (ADR-024, §4): um ator de sistema não tem actor_id nem papéis, e a concessão dele é a
      # lista `calls` do handler. `generation` é a geração da atribuição de papéis que o resolvedor leu **antes** de ler os
      # papéis (ADR-049, §3): com ela, o `Runner` recusa uma identidade cujos papéis são de uma geração já substituída.
      def initialize(tenant_id: nil, actor_id: nil, roles: [], system_actor: nil, generation: nil)
        super(tenant_id: tenant_id, actor_id: actor_id, roles: roles.is_a?(Array) ? roles.dup.freeze : roles, system_actor: system_actor,
              generation: generation)
      end

      def inspect = '#<Vetra::Execution::Identity [REDACTED]>'
      alias to_s inspect
    end

    # O que o provedor de fatos recebe para uma operação.
    FactsRequest = ::Data.define(:authorization, :operation_id, :context, :roles, :input) do
      def inspect = '#<Vetra::Execution::FactsRequest [REDACTED]>'
      alias to_s inspect
    end

    # A confirmação do marcador que o avaliador usa como `current_revision`. Depois de uma publicação que falhou, a
    # invalidação dos fatos antigos não está garantida: a confirmação fica indisponível (recusa) até uma publicação ter
    # sucesso. Nunca devolve o marcador do próprio snapshot.
    class Confirmation
      def initialize(authority)
        @authority = authority
        @mutex = Mutex.new
        @unavailable = false
        @sequence = 0
        @failure_mark = 0
      end

      def call(context)
        if @mutex.synchronize { @unavailable }
          raise Error.single('data_authorization_snapshot', 'Fatos de autorização ausentes, incompletos, incompatíveis ou obsoletos.')
        end
        @authority.call(context)
      end

      # Cada tentativa de publicar tira um número antes de publicar. Só uma tentativa iniciada **depois** da última falha
      # reabre a confirmação: a geração que ela publica é posterior ao commit que falhou em publicar. Uma publicação lenta,
      # iniciada antes da falha, não reabre (o seu incremento pode ser anterior a esse commit).
      def begin_publication = @mutex.synchronize { @sequence += 1 }

      def published!(ticket)
        @mutex.synchronize { @unavailable = false if ticket > @failure_mark }
      end

      def failed!
        @mutex.synchronize do
          @unavailable = true
          @failure_mark = @sequence
        end
      end

      def available? = @mutex.synchronize { !@unavailable }

      def inspect = '#<Vetra::Execution::Confirmation>'
      alias to_s inspect
    end

    # Contrato da borda interna: três colaboradores injetados (ADR-045, §1).
    #
    # * `identity.call(credentials)` devolve a `Identity`. A autenticidade é do adaptador do hospedeiro.
    # * `facts.call(request)` devolve o `Snapshot` da operação, lido **fora do pool da operação**, com o marcador lido
    #   **antes** dos fatos (assim uma mudança no meio faz o snapshot parecer velho, nunca novo).
    # * `authority.call(context)` confirma o marcador corrente de `current_revision`, de forma autoritativa. Se também
    #   responder a `publish!(context)`, o Runner a chama depois do commit (ou da falha) de todo comando que grava uma
    #   entidade lida por alguma política.
    #
    # Exceção de um colaborador nunca atravessa a borda: vira recusa com código próprio e sem causa. Uma publicação que
    # falha não vira erro da operação (o commit já aconteceu), e sim indisponibilidade da confirmação.
    class Edge
      def initialize(identity:, facts:, authority:)
        unless [identity, facts, authority].all? { |collaborator| collaborator.respond_to?(:call) }
          raise Error.single('execution_edge', 'A borda exige identidade, fatos e autoridade de revisão chamáveis.')
        end
        @identity, @facts = identity, facts
        @authority = authority
        @confirmation = Confirmation.new(authority)
        freeze
      end

      # O `current_revision` do avaliador: a autoridade, atrás da guarda de disponibilidade.
      def authority = @confirmation

      def resolve(credentials)
        identity = begin
          @identity.call(credentials)
        rescue Data::Error => error
          # Só quando o colaborador é o guarda do Vetra (`PublicIdentity`, que já trocou todo erro do resolvedor pelo genérico) o código
          # atravessa a borda; o erro de dados de qualquer outro colaborador, inclusive o de um resolvedor, vira o genérico (ADR-045, §1).
          raise Error.new(error.diagnostics), cause: nil if PublicIdentity === @identity # `===` do módulo: o colaborador não decide se é o guarda
          nil
        rescue StandardError
          nil
        end
        return identity if identity.is_a?(Identity)
        raise Error.single('execution_identity', 'A borda não resolveu uma identidade para esta operação.'), cause: nil
      end

      # A geração da atribuição de papéis que a identidade carrega ainda é a corrente? Sem geração na identidade, não há o que
      # conferir. Com geração e uma autoridade que não a lê, ou que falha, a resposta é não: falha fechada (ADR-049, §3).
      def identity_current?(identity, context = nil)
        return true if identity.generation.nil?
        return false unless @authority.respond_to?(:identity_generation_value)
        identity.generation == @authority.identity_generation_value(context)
      rescue StandardError
        false
      end

      # A autoridade enxerga mudanças de outros processos? As de referência não (ADR-045, §2); um adaptador que declara vários
      # processos usa isto para recusar o modo distribuído sem uma autoridade compartilhada (ADR-049, §5).
      def shared_authority? = @authority.respond_to?(:shared?) && @authority.shared?

      def snapshot(request)
        @facts.call(request)
      rescue Data::Error => error
        # Preserva o código do diagnóstico de dados (por exemplo, fatos acima do limite), sem a causa.
        raise Error.new(error.diagnostics), cause: nil
      rescue StandardError
        raise Error.single('data_authorization_snapshot', 'Fatos de autorização ausentes, incompletos, incompatíveis ou obsoletos.'), cause: nil
      end

      def publishes?
        @authority.respond_to?(:publish!)
      end

      # Nunca levanta: depois do commit, a falha de publicar não desfaz o comando nem pode mascarar a sua falha de
      # negócio. Em vez disso, a confirmação fica indisponível (toda operação seguinte recusa) até uma publicação ter
      # sucesso. Devolve true se publicou.
      def publish!(context)
        ticket = @confirmation.begin_publication
        @authority.publish!(context)
        @confirmation.published!(ticket)
        true
      rescue StandardError
        @confirmation.failed!
        false
      end

      def available? = @confirmation.available?
    end
  end
end

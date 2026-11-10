# frozen_string_literal: true

module Vetra
  module Data
    class UnitOfWork
      OMITTED_TIMEOUT = Object.new.freeze
      private_constant :OMITTED_TIMEOUT

      def initialize(db, issuer: nil, scope: :tenant, clock: -> { Time.now }, limits: Limits.new)
        unless db.is_a?(RuntimeDatabase) || (db.adapter_scheme == :mock && db.database_type == :postgres)
          raise Error.single('data_connection', 'Crie o pool do runtime por Vetra::Data.connect para conferir o login de cada conexão.')
        end
        unless %i[tenant global].include?(scope) && (scope == :global || issuer.is_a?(ContextIssuer))
          raise Error.single('data_scope', 'Unidade exige escopo válido e emissor para tenant.')
        end
        unless limits.is_a?(Limits) || limits.equal?(false)
          raise Error.single('data_limits', 'Configure o verificador com Limits ou desative explicitamente com false.')
        end
        @db, @issuer, @scope = Data.configure(db), issuer, scope
        @limits = limits
        @contexts = {}
        @times = {}
        @doomed = {}
        @clock = clock
      end

      def transaction(tenant_id: nil, actor_id: nil, system_actor: nil, op_id:, cmd:, operator_id: nil, read_only: false,
                      statement_timeout: OMITTED_TIMEOUT, lock_timeout: OMITTED_TIMEOUT, isolation: :read_committed)
        if @db.in_transaction?
          raise Error.single('data_transaction_nested', 'A unidade abre a transação mais externa; use compose dentro dela.')
        end
        timeouts = { statement_timeout: statement_timeout, lock_timeout: lock_timeout }.reject { |_, value| value.equal?(OMITTED_TIMEOUT) }
        timeouts.each_value { |value| Limits.validate_timeout!(value) }
        unless %i[read_committed serializable].include?(isolation)
          raise Error.single('data_isolation', 'Isolamento deve ser read_committed ou serializable.'), cause: nil
        end
        context = Context.new(scope: @scope, tenant_id: tenant_id, actor_id: actor_id, system_actor: system_actor,
                              op_id: op_id, cmd: cmd, operator_id: operator_id, read_only: read_only)
        @db.transaction(read_only: read_only, isolation: isolation == :read_committed ? :committed : :serializable, rollback: :reraise) do
          @limits.verify!(@db) if @limits
          # set_config(..., true) equivale a SET LOCAL e aceita parâmetros pelo protocolo.
          timeouts.each { |name, value| @db.get(Sequel.function(:set_config, name.to_s, value.to_s, true)) }
          install_context(@issuer.issue(**context.claims)) if @scope == :tenant
          Sequel.synchronize { @contexts[Sequel.current] = context }
          begin
            time = @clock.call
            Values.invalid! unless time.is_a?(Time)
            timestamp = Values.timestamp(time.getutc.floor(6))
            Sequel.synchronize { @times[Sequel.current] = timestamp }
            result = yield self
            # Uma unidade condenada nunca confirma, mesmo que o call tenha resgatado o erro (ADR-040, §2).
            doomed = Sequel.synchronize { @doomed[Sequel.current] }
            raise doomed, cause: nil if doomed
            result
          ensure
            Sequel.synchronize do
              @contexts.delete(Sequel.current)
              @times.delete(Sequel.current)
              @doomed.delete(Sequel.current)
            end
          end
        end
      rescue Sequel::DatabaseError => error
        # Inclui BEGIN/configuração e COMMIT; o Sequel já desfez a transação e limpou a conexão.
        translated = DatabaseErrors.translate(error)
        raise translated, cause: nil if translated.respond_to?(:retryable?) && translated.retryable?
        raise
      end

      def read(**context, &block)
        transaction(**context, read_only: true, &block)
      end

      def compose
        active_context!
        @db.transaction(savepoint: true, rollback: :reraise) { yield self }
      rescue Sequel::DatabaseError => error
        abort_on_retryable_error!(error)
        raise
      end

      def rollback!
        active_context!
        raise Sequel::Rollback, 'Unidade de trabalho revertida.'
      end

      def context
        active_context!
      end

      # Relógio único da operação, compartilhado pelas criações e composições.
      def now
        active_context!
        Sequel.synchronize { @times.fetch(Sequel.current) }
      end

      # Infraestrutura da K11: condena a unidade inteira e levanta o erro. O commit não acontece, nem dentro de compose
      # nem se o erro for resgatado; só o primeiro erro é guardado.
      def doom!(error)
        active_context!
        Sequel.synchronize { @doomed[Sequel.current] ||= error }
        # Cobre também break, return e throw, que pulam a conferência depois do yield: o Sequel desfaz a transação
        # inteira na saída, e não só o savepoint de compose.
        @db.rollback_on_exit
        raise error, cause: nil
      end

      # Infraestrutura da C10: o repositório usa a guarda em cada execução terminal.
      # O pool/dataset nunca é entregue ao call da aplicação.
      def access(multi_tenant:)
        active = active_context!
        if multi_tenant && active.scope != :tenant
          raise Error.single('data_scope', 'Tabela multiempresa exige unidade com contexto de tenant.')
        end
        yield @db
      rescue Sequel::DatabaseError => error
        # Mesmo SQL de infraestrutura dentro de access não pode escapar da condenação por timeout/concorrência.
        abort_on_retryable_error!(error)
        raise
      end

      def database_error!(error)
        translated = DatabaseErrors.translate(error)
        doom!(translated) if translated.respond_to?(:retryable?) && translated.retryable?
        raise translated, cause: nil
      end

      def inspect
        '#<Vetra::Data::UnitOfWork [REDACTED]>'
      end
      alias to_s inspect

      private

      def abort_on_retryable_error!(error)
        translated = DatabaseErrors.translate(error)
        doom!(translated) if translated.respond_to?(:retryable?) && translated.retryable?
      end

      def active_context!
        active = Sequel.synchronize { @contexts[Sequel.current] }
        unless active && @db.in_transaction?
          raise Error.single('data_transaction_required', 'Acesso aos dados exige uma unidade de trabalho ativa nesta fibra.')
        end
        doomed = Sequel.synchronize { @doomed[Sequel.current] }
        raise doomed, cause: nil if doomed
        active
      end

      def install_context(token)
        previous = Thread.current[:vetra_data_installing_context]
        Thread.current[:vetra_data_installing_context] = @db
        # pg_auto_parameterize envia os argumentos pelo protocolo, sem prepare/call.
        @db.get(Sequel.function(:set_config, 'vetra.ctx', token.value, true))
      rescue StandardError => error
        if error.is_a?(Sequel::DatabaseError)
          translated = DatabaseErrors.translate(error)
          raise translated, cause: nil if translated.respond_to?(:retryable?) && translated.retryable?
        end
        raise Error.single('data_context_install', 'Não foi possível instalar o contexto da unidade de trabalho.'), cause: nil
      ensure
        Thread.current[:vetra_data_installing_context] = previous
      end
    end
  end
end

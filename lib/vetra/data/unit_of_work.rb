# frozen_string_literal: true

module Vetra
  module Data
    class UnitOfWork
      def initialize(db, issuer: nil, scope: :tenant, clock: -> { Time.now })
        unless db.is_a?(RuntimeDatabase) || (db.adapter_scheme == :mock && db.database_type == :postgres)
          raise Error.single('data_connection', 'Crie o pool do runtime por Vetra::Data.connect para conferir o login de cada conexão.')
        end
        unless %i[tenant global].include?(scope) && (scope == :global || issuer.is_a?(ContextIssuer))
          raise Error.single('data_scope', 'Unidade exige escopo válido e emissor para tenant.')
        end
        @db, @issuer, @scope = Data.configure(db), issuer, scope
        @contexts = {}
        @times = {}
        @doomed = {}
        @clock = clock
      end

      def transaction(tenant_id: nil, actor_id: nil, op_id:, cmd:, operator_id: nil, read_only: false)
        if @db.in_transaction?
          raise Error.single('data_transaction_nested', 'A unidade abre a transação mais externa; use compose dentro dela.')
        end
        context = Context.new(scope: @scope, tenant_id: tenant_id, actor_id: actor_id,
                              op_id: op_id, cmd: cmd, operator_id: operator_id, read_only: read_only)
        @db.transaction(read_only: read_only, isolation: :committed, rollback: :reraise) do
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
      end

      def read(**context, &block)
        transaction(**context, read_only: true, &block)
      end

      def compose
        active_context!
        @db.transaction(savepoint: true, rollback: :reraise) { yield self }
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
      end

      def inspect
        '#<Vetra::Data::UnitOfWork [REDACTED]>'
      end
      alias to_s inspect

      private

      def active_context!
        active = Sequel.synchronize { @contexts[Sequel.current] }
        unless active && @db.in_transaction?
          raise Error.single('data_transaction_required', 'Acesso aos dados exige uma unidade de trabalho ativa nesta fibra.')
        end
        active
      end

      def install_context(token)
        previous = Thread.current[:vetra_data_installing_context]
        Thread.current[:vetra_data_installing_context] = @db
        # pg_auto_parameterize envia os argumentos pelo protocolo, sem prepare/call.
        @db.get(Sequel.function(:set_config, 'vetra.ctx', token.value, true))
      rescue StandardError
        raise Error.single('data_context_install', 'Não foi possível instalar o contexto da unidade de trabalho.'), cause: nil
      ensure
        Thread.current[:vetra_data_installing_context] = previous
      end
    end
  end
end

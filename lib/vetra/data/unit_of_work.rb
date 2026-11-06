# frozen_string_literal: true

module Vetra
  module Data
    class UnitOfWork
      def initialize(db, issuer: nil, scope: :tenant)
        unless db.is_a?(RuntimeDatabase) || (db.adapter_scheme == :mock && db.database_type == :postgres)
          raise Error.single('data_connection', 'Crie o pool do runtime por Vetra::Data.connect para conferir o login de cada conexão.')
        end
        unless %i[tenant global].include?(scope) && (scope == :global || issuer.is_a?(ContextIssuer))
          raise Error.single('data_scope', 'Unidade exige escopo válido e emissor para tenant.')
        end
        @db, @issuer, @scope = Data.configure(db), issuer, scope
        @contexts = {}
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
            yield self
          ensure
            Sequel.synchronize { @contexts.delete(Sequel.current) }
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

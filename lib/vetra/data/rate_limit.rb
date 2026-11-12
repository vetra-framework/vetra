# frozen_string_literal: true

module Vetra
  module Data
    # Pool exclusivo da borda: reserva confirma antes de abrir a transação reversível da operação (ADR-051).
    class RateLimit
      def initialize(db:, issuer:, document:)
        unless (db.is_a?(RuntimeDatabase) || (db.adapter_scheme == :mock && db.database_type == :postgres)) && issuer.is_a?(ContextIssuer)
          raise Error.single('data_connection', 'A reserva exige pool próprio de vetra_app e emissor do contexto assinado.')
        end
        @db, @issuer = Data.configure(db), issuer
        @namespace = document.fetch('app').fetch('name').dup.freeze
        freeze
      end

      def uses_database?(db) = @db.equal?(db)

      def call(context, policies)
        return 0 if policies.empty?
        raise Error.single('data_authorization_context', 'A admissão limitada exige ator confiável, inclusive para o visitante.') unless context.actor_id
        unavailable! if @db.in_transaction?
        token = @issuer.issue_rate_limit(context: context, namespace: @namespace, policies: policies)
        wait = @db.transaction(isolation: :committed, rollback: :reraise) do
          @db.get(Sequel.function(:set_config, 'statement_timeout', '2000', true))
          @db.get(Sequel.function(:set_config, 'lock_timeout', '1000', true))
          previous = Thread.current[:vetra_data_installing_context]
          begin
            Thread.current[:vetra_data_installing_context] = @db
            value = @db.get(Sequel.function(Sequel[:vetra][:reserve_rate_limit], token.value))
          ensure
            Thread.current[:vetra_data_installing_context] = previous
          end
          unavailable! unless value.is_a?(Integer) && value >= 0
          value
        end
        wait # Só depois do COMMIT: inclusive a incerteza do commit é falha fechada.
      rescue StandardError => error
        raise if error.is_a?(Error) && error.code == 'data_authorization_context'
        unavailable!
      end

      def inspect = '#<Vetra::Data::RateLimit [REDACTED]>'
      alias to_s inspect

      private

      def unavailable!
        raise Error.single('data_rate_limit_unavailable', 'Não foi possível confirmar a reserva do limite de taxa.'), cause: nil
      end
    end
  end
end

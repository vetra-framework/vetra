# frozen_string_literal: true

module Vetra
  module Data
    # Classificação única para repositórios, outbox, idempotência e fechamento da unidade.
    # Nunca retém o erro, SQL, valores ou mensagem do driver.
    module DatabaseErrors
      module_function

      def sqlstate(error)
        wrapped = error.wrapped_exception
        wrapped.respond_to?(:result) ? wrapped.result&.error_field(PG::PG_DIAG_SQLSTATE) : nil
      end

      def translate(error)
        state = sqlstate(error)
        return Conflict.new(:lock_timeout) if state == '55P03'
        return StatementTimeout.new if state == '57014'
        return Conflict.new(:deadlock) if state == '40P01'
        return SerializationFailure.new if state == '40001' || error.is_a?(Sequel::SerializationFailure)
        return Conflict.new(:unique) if state == '23505' || error.is_a?(Sequel::UniqueConstraintViolation)
        return Conflict.new(:foreign_key) if state == '23503' || error.is_a?(Sequel::ForeignKeyConstraintViolation)
        return Error.single('data_access_denied', 'Acesso aos dados recusado.') if state == '42501'

        Error.single('data_database', 'Falha ao acessar os dados.')
      end
    end
  end
end

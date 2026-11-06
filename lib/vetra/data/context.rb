# frozen_string_literal: true

module Vetra
  module Data
    # Identidades resolvidas pela borda confiável; nunca contém chave ou token.
    class Context
      UUID = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/
      attr_reader :scope, :tenant_id, :actor_id, :op_id, :cmd, :operator_id

      def initialize(scope:, tenant_id:, actor_id:, op_id:, cmd:, operator_id: nil, read_only: false)
        unless %i[tenant global].include?(scope) && (scope != :global || tenant_id.nil?)
          raise Error.single('data_scope', 'Escopo deve ser tenant ou global; contexto global não recebe tenant.')
        end
        identities = [op_id]
        identities << tenant_id << actor_id if scope == :tenant
        identities << actor_id if scope == :global && !actor_id.nil?
        identities << operator_id unless operator_id.nil?
        unless [true, false].include?(read_only) &&
               identities.all? { |id| id.is_a?(String) && id.encoding.ascii_compatible? && id.ascii_only? && UUID.match?(id) } &&
               cmd.is_a?(String) && cmd.encoding == Encoding::UTF_8 && cmd.valid_encoding? &&
               (1..255).cover?(cmd.length) && !cmd.include?("\0")
          raise Error.single('data_context', 'Contexto exige UUIDs canônicos e comando UTF-8 entre 1 e 255 caracteres, sem U+0000.')
        end
        @scope = scope
        @read_only = read_only
        @tenant_id, @actor_id, @op_id, @cmd, @operator_id =
          [tenant_id, actor_id, op_id, cmd, operator_id].map { |value| value&.dup&.freeze }
        freeze
      end

      def claims
        { tenant_id: tenant_id, actor_id: actor_id, op_id: op_id, cmd: cmd, operator_id: operator_id }
      end

      def read_only?
        @read_only
      end

      def inspect
        '#<Vetra::Data::Context [REDACTED]>'
      end
      alias to_s inspect
    end
  end
end

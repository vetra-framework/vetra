# frozen_string_literal: true

module Vetra
  module Data
    # Identidades resolvidas pela borda confiável; nunca contém chave ou token.
    class Context
      UUID = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/
      # Identificador do handler no claim system_actor (ADR-024, §4); o mesmo padrão que o banco confere.
      SYSTEM_ACTOR = /\A[A-Za-z][A-Za-z0-9_.:-]{0,127}\z/
      attr_reader :scope, :tenant_id, :actor_id, :system_actor, :op_id, :cmd, :operator_id

      def initialize(scope:, tenant_id:, actor_id: nil, system_actor: nil, op_id:, cmd:, operator_id: nil, read_only: false)
        unless %i[tenant global].include?(scope) && (scope != :global || tenant_id.nil?)
          raise Error.single('data_scope', 'Escopo deve ser tenant ou global; contexto global não recebe tenant.')
        end
        # Um ator de sistema só existe com tenant: o contexto de tenant leva exatamente um entre actor_id e system_actor.
        if scope == :tenant && (actor_id.nil? == system_actor.nil?)
          raise Error.single('data_context', 'Contexto de tenant exige actor_id ou system_actor, e nunca os dois.')
        end
        if scope == :global && !system_actor.nil?
          raise Error.single('data_context', 'Contexto global não tem ator de sistema.')
        end
        if !system_actor.nil? && !(system_actor.is_a?(String) && system_actor.encoding.ascii_compatible? && system_actor.ascii_only? && SYSTEM_ACTOR.match?(system_actor))
          raise Error.single('data_context', 'system_actor deve ser um identificador de handler ASCII de até 128 caracteres.')
        end
        identities = [op_id]
        identities << tenant_id << actor_id if scope == :tenant && !actor_id.nil?
        identities << tenant_id if scope == :tenant && actor_id.nil?
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
        @tenant_id, @actor_id, @system_actor, @op_id, @cmd, @operator_id =
          [tenant_id, actor_id, system_actor, op_id, cmd, operator_id].map { |value| value&.dup&.freeze }
        freeze
      end

      def claims
        { tenant_id: tenant_id, actor_id: actor_id, system_actor: system_actor, op_id: op_id, cmd: cmd, operator_id: operator_id }
      end

      def system_actor?
        !system_actor.nil?
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

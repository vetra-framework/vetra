# frozen_string_literal: true

require 'json'
require 'openssl'

module Vetra
  module Data
    class Token
      # Exportação sensível, somente para o protocolo. Nunca registrar este valor.
      attr_reader :value

      def initialize(value)
        @value = value.dup.freeze
        freeze
      end

      def inspect
        '#<Vetra::Data::Token [REDACTED]>'
      end
      alias to_s inspect
    end

    class ContextIssuer
      def self.from_env(env = ENV, **options)
        hex = env['VETRA_CONTEXT_SECRET_HEX']
        unless hex.is_a?(String) && hex.encoding.ascii_compatible? && hex.ascii_only? && hex.match?(/\A(?:[0-9a-fA-F]{2}){32,}\z/)
          raise Error.single('data_key', 'Configure kid válido e chave de contexto com pelo menos 32 bytes; no ambiente use hexadecimal estrito.')
        end
        new(kid: env['VETRA_CONTEXT_KID'], secret: [hex].pack('H*'), **options)
      end

      def initialize(kid:, secret:, ttl: 30, clock: -> { Time.now })
        unless kid.is_a?(String) && kid.encoding.ascii_compatible? && kid.ascii_only? && kid.match?(/\A[A-Za-z0-9_-]{1,64}\z/) &&
               secret.is_a?(String) && secret.bytesize >= 32
          raise Error.single('data_key', 'Configure kid válido e chave de contexto com pelo menos 32 bytes; no ambiente use hexadecimal estrito.')
        end
        unless ttl.is_a?(Integer) && (1..120).cover?(ttl)
          raise Error.single('data_validity', 'Validade do contexto deve ser um inteiro entre 1 e 120 segundos.')
        end
        @kid, @secret = kid.dup.freeze, secret.b.dup.freeze
        @ttl, @clock = ttl, clock
        freeze
      end

      def issue(tenant_id:, op_id:, cmd:, actor_id: nil, system_actor: nil, operator_id: nil)
        context = Context.new(scope: :tenant, tenant_id: tenant_id, actor_id: actor_id, system_actor: system_actor,
                              op_id: op_id, cmd: cmd, operator_id: operator_id)
        identity = context.system_actor? ? { system_actor: context.system_actor } : { actor_id: context.actor_id }
        payload = { tenant_id: context.tenant_id, **identity, op_id: context.op_id, cmd: context.cmd }
        sign(payload, 'v1', operator_id: context.operator_id)
      end

      # Somente a borda confiável chama: os descritores vêm da decisão sobre a IR, nunca da entrada pública.
      # Domínio separado do contexto v1: um token da unidade não pode reservar taxa, e vice-versa.
      def issue_rate_limit(context:, namespace:, policies:)
        unless context.is_a?(Context) && context.actor_id && !context.system_actor?
          raise Error.single('data_authorization_context', 'A admissão limitada exige ator confiável, inclusive para o visitante.')
        end
        sign({ tenant_id: context.tenant_id, actor_id: context.actor_id, op_id: context.op_id, cmd: context.cmd,
               namespace: namespace, policies: policies }, 'r1')
      end

      def inspect
        '#<Vetra::Data::ContextIssuer [REDACTED]>'
      end
      alias to_s inspect

      private

      def sign(payload, prefix, operator_id: nil)
        time = @clock.call
        issued = time.is_a?(Time) ? time.to_i : time
        unless issued.is_a?(Integer) && (0..999_999_999_999).cover?(issued) && issued + @ttl <= 999_999_999_999
          raise Error.single('data_context', 'Relógio do contexto deve fornecer segundos não negativos de até 12 dígitos.')
        end
        payload = payload.merge(iat: issued, exp: issued + @ttl)
        payload[:operator_id] = operator_id if operator_id
        message = "#{prefix}.#{@kid}.#{encode(JSON.generate(payload))}"
        value = "#{message}.#{encode(OpenSSL::HMAC.digest('SHA256', @secret, message))}"
        # Os limites de claims acima já cabem no teto do banco; mantém a guarda explícita do protocolo.
        if value.bytesize > 8192
          raise Error.single('data_context', 'Contexto assinado excede o limite do protocolo.')
        end
        Token.new(value)
      end

      def encode(value)
        [value].pack('m0').tr('+/', '-_').delete('=')
      end
    end
  end
end

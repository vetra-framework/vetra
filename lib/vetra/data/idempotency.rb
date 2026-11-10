# frozen_string_literal: true

require 'digest'
require 'json'

module Vetra
  module Data
    # A chave já foi usada com outra entrada ou por outro principal. A mensagem não distingue os dois casos nem
    # devolve o resultado guardado: quem não é dono da chave não aprende nada sobre ela (ADR-043, §3).
    class IdempotencyKeyReuse < Error
      def initialize
        super(Error.single('data_idempotency_key_reuse', 'A chave de idempotência já foi usada por outra operação.').diagnostics)
      end
    end

    # O registro de idempotência da operação (ADR-016 e ADR-043), usado pela borda confiável dentro da unidade de
    # trabalho, na etapa 4, e concluído na etapa 7. Não é dado à aplicação: o `call` nunca o recebe.
    class Idempotency
      KEY = /\A[!-~]{1,255}\z/
      ORIGINS = %i[adapter event].freeze
      # Teto do resultado guardado, em bytes do JSON; o CHECK do banco repete o limite (ADR-043, §4).
      RESULT_LIMIT = SQL::Idempotency::RESULT_LIMIT

      # `replay` é verdadeiro quando a chave já tinha um resultado confirmado: o `call` não deve rodar de novo.
      Claim = ::Data.define(:id, :replay, :result)
      # Os claims emitidos por `claim!`, por identidade do objeto, e o contexto transacional de cada um: `complete!` só aceita um claim que
      # esta biblioteca emitiu nesta unidade. Um Claim construído à mão, mesmo com os mesmos valores, não está aqui.
      ISSUED = ObjectSpace::WeakMap.new
      private_constant :ISSUED
      # Limite adicional do payload serializado, proteção de memória e de rede, e não o teto do resultado: o banco decide os 64 KiB sobre o
      # `jsonb::text` normalizado (chaves repetidas e números reescritos podem encolher o JSON). Acima de 1 MiB Ruby recusa mesmo um JSON
      # que normalizaria para menos; abaixo disso, o que cabe no banco passa.
      PAYLOAD_CEILING = 1_048_576

      def initialize(unit)
        @unit = unit
      end

      # Reivindica `(tenant, comando, chave)` na transação da unidade. Numa chave nova, grava a linha com o hash da entrada
      # e o principal e devolve `replay: false`. Numa chave de operação confirmada com a mesma entrada e o mesmo principal,
      # devolve o resultado guardado. Chave em uso por uma operação ainda aberta: o INSERT espera a unicidade; se a outra
      # confirma, devolve o resultado dela; se desfaz, a chave é nossa; passado o lock_timeout, é conflito (409).
      def claim!(command:, key:, input:, origin: :adapter, event: nil)
        validate!(command, key, origin, event)
        context = @unit.context
        hash = Digest::SHA256.digest(canonical(input))
        principal = principal_of(context)
        row = { tenant_id: context.tenant_id, command: command, key: key, origin: origin.to_s, principal: principal,
                input_hash: Sequel.blob(hash), handler: event&.fetch(:handler), event_id: event&.fetch(:event_id),
                event_created_at: event&.fetch(:event_created_at) }
        # A linha pode sumir entre o INSERT que não inseriu e a leitura (a purga a apagou): a chave voltou a ser livre, e uma
        # segunda tentativa a reivindica. Três tentativas bastam; mais que isso não é corrida, é estado inconsistente.
        3.times do
          claim = attempt(context, row, command, key, hash, principal)
          return claim if claim
        end
        raise Error.single('data_idempotency_state', 'A chave de idempotência não tem resultado confirmado.'), cause: nil
      rescue Sequel::DatabaseError => error
        raise translate(error), cause: nil
      end

      # Guarda o resultado da operação na mesma transação: só existe se a operação confirmar. O claim tem de ser desta unidade
      # (o mesmo contexto transacional), novo (não um replay) e ainda sem resultado: a conclusão não sobrescreve um resultado
      # confirmado, nem conclui duas vezes, nem conclui uma chave de outro principal. O resultado é JSON; o teto de 64 KiB é o
      # do banco (`octet_length(result::text)`), e a recusa do CHECK vira o diagnóstico `data_idempotency_result`.
      def complete!(claim, result)
        context = @unit.context
        unless claim.is_a?(Claim) && !claim.replay && ISSUED[claim].equal?(context)
          raise Error.single('data_idempotency_state', 'A chave de idempotência não foi reivindicada nesta unidade.'), cause: nil
        end
        json = begin
          JSON.generate(result)
        rescue JSON::GeneratorError, Encoding::UndefinedConversionError
          raise result_error, cause: nil
        end
        raise result_error, cause: nil if json.bytesize > PAYLOAD_CEILING
        @unit.access(multi_tenant: context.scope == :tenant) do |db|
          updated = table(db).where(id: claim.id, result: nil, principal: principal_of(context)).update(result: Sequel.cast(json, :jsonb))
          raise Error.single('data_idempotency_state', 'A chave de idempotência não foi reivindicada nesta unidade.'), cause: nil unless updated == 1
        end
        nil
      rescue Sequel::DatabaseError => error
        raise(sqlstate(error) == '23514' ? result_error : translate(error), cause: nil)
      end

      private

      def issue(claim, context)
        ISSUED[claim] = context
        claim
      end

      # Uma tentativa: devolve o Claim, ou nil se a linha em conflito sumiu antes da leitura.
      def attempt(context, row, command, key, hash, principal)
        @unit.access(multi_tenant: context.scope == :tenant) do |db|
          inserted = table(db).returning(:id).insert_conflict(constraint: SQL::Idempotency::KEY_CONSTRAINT).insert(row)
          return issue(Claim.new(id: inserted.first.fetch(:id), replay: false, result: nil), context) if inserted.is_a?(Array) && inserted.any?
          existing = table(db).where(tenant_id: context.tenant_id, command: command, key: key)
                              .select(:id, :principal, :input_hash, Sequel.cast(:result, :text).as(:result_text)).first
          return nil unless existing
          same = existing.fetch(:principal) == principal && existing.fetch(:input_hash).to_s.b == hash.b
          raise IdempotencyKeyReuse.new, cause: nil unless same
          unless (stored = existing.fetch(:result_text))
            raise Error.single('data_idempotency_state', 'A chave de idempotência não tem resultado confirmado.'), cause: nil
          end
          issue(Claim.new(id: existing.fetch(:id), replay: true, result: JSON.parse(stored)), context)
        end
      end

      # Mesmo mapeamento do repositório: não inclui nem retém o erro, o SQL ou os valores do driver.
      def result_error
        Error.single('data_idempotency_result', 'O resultado guardado deve ser JSON válido de até 64 KiB.')
      end

      def sqlstate(error)
        error.wrapped_exception.respond_to?(:result) ? error.wrapped_exception.result&.error_field(PG::PG_DIAG_SQLSTATE) : nil
      end

      def translate(error)
        state = sqlstate(error)
        return Conflict.new(:lock_timeout) if state == '55P03'
        return Conflict.new(:deadlock) if state == '40P01'
        return Conflict.new(:serialization) if error.is_a?(Sequel::SerializationFailure) || state == '40001'
        return Error.single('data_access_denied', 'Acesso aos dados recusado.') if state == '42501'
        Error.single('data_database', 'Falha ao acessar os dados.')
      end

      def table(db)
        db[Sequel[:vetra][:idempotency]]
      end

      # Ator comum, ator de sistema (com o identificador do handler) ou visitante (nulo): a chave pertence a um principal.
      def principal_of(context)
        return "system:#{context.system_actor}" if context.respond_to?(:system_actor?) && context.system_actor?
        context.actor_id
      end

      def canonical(input)
        Graph::Canonical.dump(JSON.parse(JSON.generate(input)))
      rescue JSON::GeneratorError, JSON::ParserError, TypeError
        raise Error.single('data_idempotency_input', 'A entrada da operação deve ser JSON para ter chave de idempotência.'), cause: nil
      end

      def validate!(command, key, origin, event)
        unless command.is_a?(String) && (1..255).cover?(command.length) && !command.include?("\0") && key.is_a?(String) && KEY.match?(key) &&
               ORIGINS.include?(origin) && (origin == :event) == !event.nil?
          raise Error.single('data_idempotency_key', 'A chave deve ter de 1 a 255 caracteres ASCII visíveis e a origem, os dados que a retenção exige.'), cause: nil
        end
        return unless event
        unless event.is_a?(Hash) && event.keys.sort == %i[event_created_at event_id handler] && event[:handler].is_a?(String) &&
               event[:event_id].is_a?(String) && event[:event_created_at].is_a?(Time)
          raise Error.single('data_idempotency_key', 'A chave deve ter de 1 a 255 caracteres ASCII visíveis e a origem, os dados que a retenção exige.'), cause: nil
        end
      end
    end
  end
end

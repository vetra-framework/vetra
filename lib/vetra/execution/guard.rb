# frozen_string_literal: true

module Vetra
  module Execution
    # Autorização de cada acesso dos repositórios e do estado final (K18, ADR-046), na unidade da operação.
    #
    # O `uses` de um `call` não concede dados (ADR-044, §2): cada leitura, escrita ou vínculo passa pelas políticas do
    # papel, por ação, registro e campos, com fatos lidos **nesta transação** (o RLS filtra os fatos dos CRMs como filtra a
    # operação). O Runner instala a guarda na unidade; fora do Runner ela não existe e os repositórios se comportam como
    # sempre. Um ator de sistema não passa por políticas de papéis: a concessão dele é a lista `calls` do handler, conferida
    # nas etapas 3 e 6 (ADR-024, §4), e o tenant continua isolado pelo repositório e pelo banco.
    class AccessGuard
      IN_UNIT = 'in_unit'

      def initialize(authorization:, catalog:, unit:, roles:, limit: DatabaseFacts::DEFAULT_LIMIT)
        @authorization, @catalog, @unit, @limit = authorization, catalog, unit, limit
        @roles = roles.dup.freeze
        @cache = {}
        @written = {}
        @suspended = 0
      end

      # Leitura de um registro já lido: o que o papel não pode ler se comporta como ausente, como no RLS.
      def authorize_read!(entity_id, record)
        require_grant!(entity_id, 'read')
        raise Data::RecordNotFound.new, cause: nil unless readable?(entity_id, record)
      end

      # Filtra uma coleção lida: as linhas que o papel não pode ler somem, como no RLS.
      def visible(entity_id, records)
        return records if skip?
        require_grant!(entity_id, 'read')
        records.select { |record| readable?(entity_id, record) }
      end

      # Ação de escrita (create, update, delete ou a de um vínculo) sobre a linha dada e os campos que ela grava.
      def authorize_write!(entity_id, action, row, fields)
        return if skip?
        decide(entity_id, action, plain(row), fields.map(&:to_s))
      end

      # O que o call escreveu: para a reautorização do estado final e para descartar os fatos lidos.
      def written!(entity_id, kind, id, fields)
        entry = ((@written[entity_id] ||= {})[id] ||= { created: false, deleted: false, fields: [] })
        entry[:created] = true if kind == :created
        # Apagar e recriar o mesmo id deixa a linha existente: só a última escrita diz se ela está apagada.
        entry[:deleted] = kind == :deleted
        entry[:fields] |= fields.map(&:to_s)
        @cache.delete(entity_id)
      end

      # `compose` abre um savepoint: se ele é desfeito, o que a guarda registrou dentro dele deixou de existir, e os fatos
      # lidos podem ser outros. A unidade pede o ponto de retorno antes e o restaura se o savepoint não termina.
      def checkpoint
        { written: Marshal.load(Marshal.dump(@written)) }
      end

      def restore!(checkpoint)
        @written = checkpoint.fetch(:written)
        @cache.clear
      end

      # Recusa estática, antes de qualquer consulta: sem concessão do papel para a ação, o resultado não pode depender de o
      # registro existir (a diferença entre "negado" e "não encontrado" seria um oráculo de existência).
      def require_grant!(entity_id, action)
        return if skip? || @authorization.granted?(entity_id, action, @roles)
        raise Error.single('data_authorization_denied', 'Acesso recusado pela política ou pelo escopo do registro.'), cause: nil
      end

      # Uma entidade mudou por dentro de uma operação já autorizada (a junção de um vínculo): só descarta os fatos.
      def touched!(entity_id)
        @cache.delete(entity_id)
      end

      # Trechos que são parte de uma operação já autorizada (o vínculo de `include_on_create`, a junção e o alvo de um
      # vínculo) não repetem a decisão sobre o que o repositório faz por dentro.
      def without_checks
        @suspended += 1
        yield
      ensure
        @suspended -= 1
      end

      # Etapa 6: o estado final de cada linha criada ou alterada, com fatos relidos, ainda precisa ser autorizado. Cobre a
      # troca de revenda no `update` (teste 4 do ADR-016) onde não há RLS e confere, onde há, o que o WITH CHECK já viu.
      def reauthorize!
        return if system?
        @cache.clear
        @written.each do |entity_id, rows|
          rows.each do |id, entry|
            next if entry[:deleted]
            row = @catalog.fact_rows(entity_id, unit: @unit, limit: 1, ids: [id]).first
            deny_final! unless row
            begin
              decide(entity_id, entry[:created] ? 'create' : 'update', row, entry[:fields])
            rescue Data::Error => error
              deny_final! if error.code == 'data_authorization_denied'
              raise
            end
          end
        end
        nil
      end

      def inspect = '#<Vetra::Execution::AccessGuard>'
      alias to_s inspect

      private

      def system?
        @unit.context.system_actor?
      end

      def skip?
        @suspended.positive? || system?
      end

      def readable?(entity_id, record)
        return true if skip?
        decide(entity_id, 'read', plain(record), @authorization.field_names(entity_id))
        true
      rescue Data::Error => error
        raise unless error.code == 'data_authorization_denied'
        false
      end

      def decide(entity_id, action, row, fields)
        @authorization.decide(entity_id, action, row, context: @unit.context, roles: @roles, fields: fields,
                              snapshot: snapshot(entity_id, action))
      end

      def snapshot(entity_id, action)
        records = @authorization.fact_entities(entity_id, action, @roles).to_h { |id| [id, rows(id)] }
        @authorization.snapshot(context: @unit.context, roles: @roles, revision: IN_UNIT, records: records)
      end

      def rows(entity_id)
        @cache[entity_id] ||= @catalog.fact_rows(entity_id, unit: @unit, limit: @limit)
      end

      def plain(record)
        (record.respond_to?(:to_h) ? record.to_h : record).transform_keys(&:to_s)
      end

      def deny_final!
        raise Error.single('data_authorization_final', 'O estado final do registro não é autorizado pelas políticas.'), cause: nil
      end
    end
  end
end

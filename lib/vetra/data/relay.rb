# frozen_string_literal: true

require 'json'

module Vetra
  module Data
    # Relay da outbox (ADR-014, ADR-024 e ADR-040, §§ 3 e 4), como vetra_relay. Lê a outbox por faixas de xid8 abaixo do
    # xmin do snapshot (ADR-008, §2), materializa uma entrega por handler declarado, reserva por lease com SKIP LOCKED
    # e confirma na hora, conclui, repete com espera crescente ou leva a entrega a `dead`, copiando-a para
    # vetra.dead_deliveries. O efeito do consumidor roda fora de qualquer transação do relay.
    class Relay
      MAX_ATTEMPTS = 10
      LEASE = 60
      CHECKPOINT = 'relay'
      # O efeito da entrega: falha definitiva vai direto a `dead` (ADR-014, §4).
      class PermanentFailure < StandardError; end

      Delivery = ::Data.define(:handler, :event_id, :event_created_at, :event_xid8, :event_seq, :event, :version,
                               :tenant_id, :payload, :attempts, :leased_until)

      # Evento => handlers que o declaram em `on`, lido do grafo.
      def self.handlers(document)
        document.fetch('nodes').select { |node| node['kind'] == 'handler' }.each_with_object({}) do |handler, map|
          handler.fetch('on').each { |event| (map[event.fetch('id')] ||= []) << handler.fetch('id') }
        end.transform_values { |ids| ids.sort.freeze }.freeze
      end

      def self.connect(url, **options)
        # Como no Data.connect, o usuário da URL é sobrescrito e cada conexão do pool é conferida.
        db = Sequel.connect(url, **options, user: 'vetra_relay', after_connect: method(:check_connection))
        Data.configure(db)
      rescue StandardError
        db&.disconnect
        raise Error.single('data_relay_connection', 'Não foi possível abrir o pool como vetra_relay no PostgreSQL.'), cause: nil
      end

      def self.check_connection(connection)
        unless connection.respond_to?(:exec) && connection.exec(<<~SQL).getvalue(0, 0) == 't'
          SELECT current_user = 'vetra_relay' AND session_user = 'vetra_relay' AND NOT rolsuper AND NOT rolbypassrls
          FROM pg_catalog.pg_roles WHERE rolname = current_user
        SQL
          raise Error.single('data_relay_connection', 'O relay deve usar vetra_relay sem superusuário nem BYPASSRLS.')
        end
      end
      private_class_method :check_connection

      def initialize(db, document:, random: Random.new)
        @db, @random = Data.configure(db), random
        @handlers = self.class.handlers(document)
        # Só uma aplicação com outbox tem chaves derivadas de um evento (ADR-043, §5).
        @events = SQL::Outbox.needed?(document)
        @known = @handlers.values.flatten.uniq.sort.freeze
      end

      # Uma faixa [checkpoint, xmin): todas as transações abaixo do xmin terminaram, então nenhum evento delas aparece
      # depois; a faixa seguinte começa onde esta termina. Devolve quantos eventos leu. Outro relay com o checkpoint
      # travado faz esta chamada devolver 0 sem esperar.
      def relay!
        outside_transaction!
        @db.transaction do
          high = @db.get(Sequel.lit('pg_catalog.pg_snapshot_xmin(pg_catalog.pg_current_snapshot())::text'))
          row = @db.fetch('SELECT next_xid8::text AS low FROM vetra.relay_checkpoints WHERE name = ? FOR UPDATE SKIP LOCKED', CHECKPOINT).first
          next 0 unless row && @db.get(Sequel.lit('?::xid8 > ?::xid8', high, row[:low]))

          events = @db.fetch(<<~SQL, row[:low], high).all
            SELECT created_at, xid8::text AS xid8, seq, event_id::text AS event_id, event, tenant_id::text AS tenant_id
              FROM vetra.outbox WHERE xid8 >= ?::xid8 AND xid8 < ?::xid8 ORDER BY xid8, seq
          SQL
          deliveries = events.flat_map do |event|
            @handlers.fetch(event[:event], []).map do |handler|
              { event_created_at: event[:created_at], event_xid8: Sequel.cast(event[:xid8], :xid8), event_seq: event[:seq],
                event_id: event[:event_id], handler: handler, tenant_id: event[:tenant_id] }
            end
          end
          # A chave (handler, event_id, event_created_at) faz uma faixa relida não duplicar entregas (ADR-024, §3).
          @db[Sequel[:vetra][:deliveries]].insert_conflict(target: %i[handler event_id event_created_at]).multi_insert(deliveries) unless deliveries.empty?
          @db[Sequel[:vetra][:relay_checkpoints]].where(name: CHECKPOINT)
            .update(next_xid8: Sequel.cast(high, :xid8), updated_at: Sequel.function(:statement_timestamp))
          events.size
        end
      end

      # Reserva até `limit` entregas pendentes do handler por `lease` segundos e confirma na hora (ADR-014, §2).
      def reserve(handler, limit: 10, lease: LEASE)
        outside_transaction!
        known!(handler)
        unless limit.is_a?(Integer) && limit.between?(1, 1000) && lease.is_a?(Integer) && lease.between?(1, 3600)
          raise Error.single('data_relay_limit', 'Reserva exige limite entre 1 e 1000 e lease entre 1 e 3600 segundos.')
        end
        rows = @db.transaction do
          lock_outbox_first
          @db.fetch(<<~SQL, handler, limit, lease).all
            WITH picked AS (
              SELECT handler, event_id, event_created_at FROM vetra.deliveries
               WHERE handler = ? AND state = 'pending' AND run_after <= pg_catalog.statement_timestamp()
                 AND (leased_until IS NULL OR leased_until <= pg_catalog.statement_timestamp())
               ORDER BY run_after, event_created_at, event_id LIMIT ? FOR UPDATE SKIP LOCKED)
            UPDATE vetra.deliveries d
               SET leased_until = pg_catalog.statement_timestamp() + pg_catalog.make_interval(secs => ?),
                   updated_at = pg_catalog.statement_timestamp()
              FROM picked, vetra.outbox o
             WHERE d.handler = picked.handler AND d.event_id = picked.event_id AND d.event_created_at = picked.event_created_at
               AND o.created_at = d.event_created_at AND o.xid8 = d.event_xid8 AND o.seq = d.event_seq
            RETURNING d.handler, d.event_id::text AS event_id, d.event_created_at::text AS event_created_at,
                      d.event_xid8::text AS event_xid8, d.event_seq, o.event, o.version, d.tenant_id::text AS tenant_id,
                      o.payload::text AS payload, d.attempts, d.leased_until::text AS leased_until
          SQL
        end
        rows.sort_by { |row| [row[:event_created_at], row[:event_id]] }.map do |row|
          Delivery.new(**row.merge(payload: Values.immutable(JSON.parse(row[:payload]))))
        end.freeze
      end

      # Conclui depois do efeito; devolve false se o lease venceu e outro worker pode ter a entrega (ADR-014, §3).
      def complete(delivery)
        outside_transaction!
        @db.fetch(<<~SQL, *fence(delivery)).all.size == 1
          UPDATE vetra.deliveries SET state = 'done', leased_until = NULL, updated_at = pg_catalog.statement_timestamp()
           WHERE #{FENCE} RETURNING 1
        SQL
      end

      # Falha do efeito: nova tentativa com espera de min(1800 s, 10 s × 2^(n−1)) ±20%, ou `dead` depois da décima
      # falha ou numa falha definitiva, com a cópia para vetra.dead_deliveries na mesma transação (ADR-024, §1 e §3).
      # O erro guardado é só a classe, sem mensagem: a mensagem pode trazer dados do evento.
      def failed(delivery, error, permanent: false)
        outside_transaction!
        attempts = delivery.attempts + 1
        reason = error.class.name.to_s[0, 200]
        @db.transaction do
          lock_outbox_first
          if permanent || attempts >= MAX_ATTEMPTS
            dead = @db.fetch(<<~SQL, reason, *fence(delivery)).all.size == 1
              UPDATE vetra.deliveries SET state = 'dead', attempts = attempts + 1, leased_until = NULL, last_error = ?,
                     updated_at = pg_catalog.statement_timestamp()
               WHERE #{FENCE} RETURNING 1
            SQL
            next false unless dead
            @db.fetch(<<~SQL, delivery.handler, delivery.event_id, delivery.event_created_at).all
              INSERT INTO vetra.dead_deliveries (handler, event_id, event_created_at, event_xid8, event_seq, event, version,
                                                 tenant_id, payload, attempts, last_error)
              SELECT d.handler, d.event_id, d.event_created_at, d.event_xid8, d.event_seq, o.event, o.version, d.tenant_id,
                     o.payload, d.attempts, d.last_error
                FROM vetra.deliveries d JOIN vetra.outbox o
                  ON o.created_at = d.event_created_at AND o.xid8 = d.event_xid8 AND o.seq = d.event_seq
               WHERE d.handler = ? AND d.event_id = ?::uuid AND d.event_created_at = ?::timestamptz
              ON CONFLICT (handler, event_id) DO NOTHING
            SQL
            :dead
          else
            delay = ([1800, 10 * (2**(attempts - 1))].min * (0.8 + (0.4 * @random.rand))).round(3)
            retried = @db.fetch(<<~SQL, reason, delay, *fence(delivery)).all.size == 1
              UPDATE vetra.deliveries SET attempts = attempts + 1, leased_until = NULL, last_error = ?,
                     run_after = pg_catalog.statement_timestamp() + pg_catalog.make_interval(secs => ?),
                     updated_at = pg_catalog.statement_timestamp()
               WHERE #{FENCE} RETURNING 1
            SQL
            retried ? :retry : false
          end
        end
      end

      # Até `limit` entregas, uma por vez: reserva logo antes do efeito, para que o lease cubra o efeito inteiro, entrega
      # ao bloco fora de transação e conclui ou registra a falha. Devolve a contagem por resultado: done, retry, dead e
      # lost (lease vencido antes da conclusão).
      def work(handler, limit: 10, lease: LEASE)
        unless limit.is_a?(Integer) && limit.between?(1, 1000)
          raise Error.single('data_relay_limit', 'Reserva exige limite entre 1 e 1000 e lease entre 1 e 3600 segundos.')
        end
        counts = { done: 0, retry: 0, dead: 0, lost: 0 }
        limit.times do
          delivery = reserve(handler, limit: 1, lease: lease).first
          break unless delivery
          outcome = begin
            yield delivery
            complete(delivery) ? :done : :lost
          rescue PermanentFailure => error
            failed(delivery, error, permanent: true) || :lost
          rescue StandardError => error
            failed(delivery, error) || :lost
          end
          counts[outcome] += 1
        end
        counts.freeze
      end

      # Manutenção das partições pela rotina fechada do plano (ADR-040, §4).
      def maintain(ahead: 3, retention: 7)
        outside_transaction!
        unless ahead.is_a?(Integer) && retention.is_a?(Integer)
          raise Error.single('data_relay_limit', 'A manutenção exige dias inteiros para ahead e retention.')
        end
        JSON.parse(@db.get(Sequel.function(Sequel[:vetra][:outbox_maintain], ahead, retention).cast(:text)))
      end

      # Purga do registro de idempotência pelo papel de manutenção (ADR-043, §5). Apaga, em lotes, as chaves de adaptador
      # mais velhas que `retention_hours` e, numa aplicação com outbox, as chaves derivadas de um evento cuja entrega já
      # não existe (nem em vetra.deliveries nem em vetra.dead_deliveries) e que também passaram do prazo. Chama de novo
      # enquanto um lote vier cheio; devolve o total apagado por origem.
      def purge_idempotency(retention_hours: 24, batch: 1000)
        outside_transaction!
        unless retention_hours.is_a?(Integer) && retention_hours.between?(1, 8760) && batch.is_a?(Integer) && batch.between?(1, 10_000)
          raise Error.single('data_relay_limit', 'A purga exige retention_hours entre 1 e 8760 e batch entre 1 e 10000.')
        end
        # O corte vem do relógio do PostgreSQL (o de `created_at`), fixado uma vez por execução: chaves que vencem enquanto a purga corre
        # ficam para a próxima, e o laço termina. Viaja como texto com o fuso (`timestamptz::text`), nunca como `timestamp` sem fuso.
        cutoff = @db.fetch('SELECT (pg_catalog.clock_timestamp() - pg_catalog.make_interval(hours => ?))::text AS cutoff', retention_hours).first.fetch(:cutoff)
        totals = { 'adapter' => 0 }
        totals['event'] = 0 if @events
        totals.each_key do |origin|
          loop do
            deleted = purge_batch(origin, cutoff, batch)
            totals[origin] += deleted
            break if deleted < batch
          end
        end
        totals
      end

      ORPHAN = <<~SQL.freeze
        AND NOT EXISTS (SELECT 1 FROM vetra.deliveries d WHERE d.handler = i.handler AND d.event_id = i.event_id
                          AND d.event_created_at = i.event_created_at)
        AND NOT EXISTS (SELECT 1 FROM vetra.dead_deliveries x WHERE x.handler = i.handler AND x.event_id = i.event_id)
      SQL

      private def purge_batch(origin, cutoff, batch)
        orphan = origin == 'event' ? ORPHAN : ''
        @db.fetch(<<~SQL, origin, cutoff, batch).all.size
          WITH doomed AS (
            SELECT i.id FROM vetra.idempotency i
             WHERE i.origin = ? AND i.created_at < CAST(? AS timestamptz) #{orphan}
             ORDER BY i.created_at, i.id LIMIT ?)
          DELETE FROM vetra.idempotency t USING doomed WHERE t.id = doomed.id RETURNING 1
        SQL
      end

      def inspect
        '#<Vetra::Data::Relay>'
      end
      alias to_s inspect

      private

      # A conclusão e a falha só valem para quem ainda tem o lease que a reserva deu.
      FENCE = "handler = ? AND event_id = ?::uuid AND event_created_at = ?::timestamptz AND state = 'pending' " \
              'AND leased_until = ?::timestamptz'

      def fence(delivery)
        [delivery.handler, delivery.event_id, delivery.event_created_at, delivery.leased_until]
      end

      # O relay abre só transações curtas e confirma antes do efeito (ADR-014, §2): dentro de outra transação, a
      # reserva não confirmaria e o efeito rodaria com ela aberta.
      def outside_transaction!
        return unless @db.in_transaction?
        raise Error.single('data_relay_transaction', 'O relay abre as próprias transações curtas; não o chame dentro de outra transação.')
      end

      # A reserva e a falha tocam as entregas e a outbox; a manutenção trava a outbox e depois as entregas. Na mesma
      # ordem, uma espera a outra sem ciclo de locks.
      def lock_outbox_first
        @db.run('LOCK TABLE vetra.outbox IN ACCESS SHARE MODE')
      end

      def known!(handler)
        return if @known.include?(handler)
        raise Error.single('data_relay_handler', 'Handler sem evento declarado no grafo.')
      end
    end
  end
end

#!/usr/bin/env ruby
# Sonda do ADR-008: intervalos xid8, continuidade e versão por linha em um PostgreSQL real.
#
#   DATABASE_URL=postgres://usuario@127.0.0.1:5432/descartavel ruby script/sonda_adr008.rb
#
# Requer PostgreSQL 17+ e permissão para CREATE SCHEMA num banco descartável. Cria um schema exclusivo
# vetra_sonda_adr008_*, removido no ensure, e fecha as sessões de cada caso. Não altera o grafo nem
# implementa o distribuidor. Retenção, failover, autorização e transporte continuam fora desta sonda.
require 'bundler/inline'
require 'securerandom'

gemfile do
  source 'https://rubygems.org'
  gem 'pg'
end

class EventContinuityProbe
  def initialize(url)
    @url = url
    @schema = "vetra_sonda_adr008_#{Process.pid}_#{SecureRandom.hex(4)}"
    @channel = @schema
    @results = []
  end

  def run
    @admin = connect
    version = @admin.exec('SHOW server_version').getvalue(0, 0)
    setup
    inverted_commits
    contiguous_intervals
    writer_holds_other_tenants
    missed_notification
    independent_listeners
    inverted_row_versions
    atomic_sql_updates
    savepoints
    fresh_snapshots
    transaction_timeout
    puts "PostgreSQL #{version} | pg #{PG::VERSION}"
    @results.each { |ok, name, detail| puts "  #{ok ? 'PASS' : 'FAIL'}  #{name} | #{detail}" }
    passed = @results.count { |ok, _, _| ok }
    puts "Resultado: #{passed}/#{@results.size} verificações passaram."
    passed == @results.size
  ensure
    if @admin && !@admin.finished?
      @admin.exec("DROP SCHEMA IF EXISTS #{@schema} CASCADE")
      @admin.close
    end
  end

  private

  def connect
    PG.connect(@url).tap do |connection|
      connection.exec("SET client_min_messages = warning")
      connection.exec("SET statement_timeout = '10s'")
      connection.exec("SET lock_timeout = '5s'")
    end
  end

  def sessions(count)
    connections = []
    count.times { connections << connect }
    yield(*connections)
  ensure
    connections.each { |connection| connection.close unless connection.finished? }
  end

  def check(name)
    @admin.exec("TRUNCATE #{@schema}.outbox, #{@schema}.records RESTART IDENTITY")
    ok, detail = yield
    @results << [ok, name, detail]
  rescue StandardError => error
    @results << [false, name, "#{error.class}: #{error.message.lines.first&.strip}"]
  end

  def setup
    @admin.exec(<<~SQL)
      CREATE SCHEMA #{@schema};
      CREATE TABLE #{@schema}.outbox (
        seq bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
        xid8 xid8 NOT NULL DEFAULT pg_current_xact_id(),
        tenant integer NOT NULL,
        label text NOT NULL,
        record_id integer,
        version bigint
      );
      CREATE TABLE #{@schema}.records (
        id integer PRIMARY KEY,
        body text NOT NULL,
        _v bigint NOT NULL DEFAULT 1
      );
      CREATE FUNCTION #{@schema}.bump_version() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        NEW._v = OLD._v + 1;
        RETURN NEW;
      END $$;
      CREATE TRIGGER version BEFORE UPDATE ON #{@schema}.records
        FOR EACH ROW EXECUTE FUNCTION #{@schema}.bump_version();
      CREATE FUNCTION #{@schema}.row_event() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        INSERT INTO #{@schema}.outbox (tenant, label, record_id, version)
          VALUES (1, TG_OP, NEW.id, NEW._v);
        PERFORM pg_notify('#{@channel}', '1');
        RETURN NEW;
      END $$;
      CREATE TRIGGER row_event AFTER INSERT OR UPDATE ON #{@schema}.records
        FOR EACH ROW EXECUTE FUNCTION #{@schema}.row_event();
    SQL
  end

  def high(connection)
    connection.exec('SELECT pg_snapshot_xmin(pg_current_snapshot())::text').getvalue(0, 0).to_i
  end

  # hi é capturado antes da leitura. Nada com xid < hi poderá confirmar depois, então uma instrução
  # posterior em READ COMMITTED pode ler o intervalo completo. Só se avança o checkpoint após a entrega.
  def interval(connection, lo)
    hi = high(connection)
    rows = connection.exec_params(<<~SQL, [lo.to_s, hi.to_s]).to_a
      SELECT seq, xid8::text, tenant, label, record_id, version FROM #{@schema}.outbox
       WHERE xid8 >= $1::xid8 AND xid8 < $2::xid8
       ORDER BY xid8, seq
    SQL
    [hi, rows]
  end

  def append(connection, label, tenant: 1)
    connection.exec_params(<<~SQL, [tenant, label]).first
      INSERT INTO #{@schema}.outbox (tenant, label) VALUES ($1, $2)
      RETURNING seq, xid8::text
    SQL
  end

  def notifications(connection, wait: false)
    received = []
    connection.wait_for_notify(3) { |_channel, _pid, payload| received << payload } if wait
    connection.exec('SELECT 1') # Processa as mensagens pendentes do protocolo antes de consultar a fila local.
    while (message = connection.notifies)
      received << message[:extra]
    end
    received
  end

  def inverted_commits
    check('commit invertido perde evento por sequência, mas não por intervalo xid8') do
      sessions(3) do |a, b, reader|
        lo = high(reader)
        a.exec('BEGIN')
        first = append(a, 'A')
        b.exec('BEGIN')
        second = append(b, 'B')
        b.exec('COMMIT')
        naive_checkpoint = reader.exec("SELECT max(seq) FROM #{@schema}.outbox").getvalue(0, 0).to_i
        held_hi, held = interval(reader, lo)
        a.exec('COMMIT')
        hi, delivered = interval(reader, held_hi)
        naive = reader.exec_params("SELECT label FROM #{@schema}.outbox WHERE seq > $1", [naive_checkpoint]).to_a
        ok = first['seq'].to_i < second['seq'].to_i && first['xid8'].to_i < second['xid8'].to_i
        ok &&= naive.empty? && held.empty? && held_hi <= first['xid8'].to_i && hi > second['xid8'].to_i
        ok &&= delivered.map { |row| row['label'] } == %w[A B]
        [ok, "seq A/B=#{first['seq']}/#{second['seq']}; leitura antecipada=#{held.size}; intervalo=#{delivered.map { |row| row['label'] }}; sequência perdeu A? #{naive.empty?}"]
      end
    end
  end

  def contiguous_intervals
    check('intervalos contíguos ordenam eventos da mesma transação e excluem rollback') do
      sessions(2) do |writer, reader|
        lo = high(reader)
        writer.exec('BEGIN')
        first = append(writer, 'primeiro')
        second = append(writer, 'segundo')
        writer.exec('COMMIT')
        hi, initial = interval(reader, lo)
        writer.exec('BEGIN')
        append(writer, 'desfeito')
        writer.exec('ROLLBACK')
        append(writer, 'terceiro')
        next_hi, following = interval(reader, hi)
        final_hi, repeated = interval(reader, next_hi)
        labels = (initial + following).map { |row| row['label'] }
        ok = first['xid8'] == second['xid8'] && labels == %w[primeiro segundo terceiro]
        ok &&= initial.map { |row| row['seq'].to_i } == [first, second].map { |row| row['seq'].to_i }
        ok &&= lo <= hi && hi <= next_hi && next_hi <= final_hi && repeated.empty?
        [ok, "limites=#{[lo, hi, next_hi, final_hi]}; eventos=#{labels}; repetidos=#{repeated.size}"]
      end
    end
  end

  def writer_holds_other_tenants
    check('uma escrita aberta segura outros tenants e rollback libera o intervalo') do
      sessions(3) do |holder, writer, reader|
        lo = high(reader)
        holder.exec('BEGIN')
        pending = append(holder, 'aberto', tenant: 1)
        completed = append(writer, 'confirmado', tenant: 2)
        held_hi, held = interval(reader, lo)
        holder.exec('ROLLBACK')
        hi, released = interval(reader, held_hi)
        ok = held_hi <= pending['xid8'].to_i && held.empty? && hi > completed['xid8'].to_i
        ok &&= released.map { |row| [row['tenant'], row['label']] } == [['2', 'confirmado']]
        [ok, "xmin preso=#{held_hi}; após rollback=#{hi}; eventos=#{released.map { |row| row['label'] }}"]
      end
    end
  end

  def missed_notification
    check('queda do LISTEN perde a notificação, mas o polling recupera a outbox') do
      sessions(3) do |old_listener, writer, reader|
        lo = high(reader)
        old_listener.exec("LISTEN #{@channel}")
        old_listener.close
        writer.exec('BEGIN')
        event = append(writer, 'durável')
        writer.exec_params('SELECT pg_notify($1, $2)', [@channel, '1'])
        writer.exec('COMMIT')
        reader.exec("LISTEN #{@channel}")
        missed = notifications(reader)
        hi, rows = interval(reader, lo)
        ok = missed.empty? && hi > event['xid8'].to_i && rows.map { |row| row['label'] } == ['durável']
        [ok, "notificações após reconexão=#{missed.size}; eventos recuperados=#{rows.size}"]
      end
    end
  end

  def independent_listeners
    check('duas sessões LISTEN recebem a mesma invalidação e leem os mesmos eventos') do
      sessions(3) do |a, b, writer|
        lo = high(a)
        [a, b].each { |listener| listener.exec("LISTEN #{@channel}") }
        writer.exec("INSERT INTO #{@schema}.records VALUES (1, 'conteúdo privado', 1)")
        notices = [notifications(a, wait: true), notifications(b, wait: true)]
        _hi_a, rows_a = interval(a, lo)
        _hi_b, rows_b = interval(b, lo)
        ok = notices == [['1'], ['1']] && rows_a == rows_b && rows_a.size == 1
        ok &&= rows_a.first.values.none? { |value| value.to_s.include?('conteúdo privado') }
        [ok, "payloads=#{notices}; eventos por sessão=#{[rows_a.size, rows_b.size]}; payload sem conteúdo"]
      end
    end
  end

  def inverted_row_versions
    check('lock serializa a linha; _v descarta o evento antigo entregue depois do novo') do
      sessions(3) do |a, b, reader|
        @admin.exec("INSERT INTO #{@schema}.records VALUES (1, 'inicial', 1)")
        @admin.exec("TRUNCATE #{@schema}.outbox RESTART IDENTITY")
        lo = high(reader)
        a.exec('BEGIN')
        xid_a = a.exec('SELECT pg_current_xact_id()::text').getvalue(0, 0).to_i
        b.exec('BEGIN')
        b.exec("UPDATE #{@schema}.records SET body = 'intermediário' WHERE id = 1")
        a.send_query("UPDATE #{@schema}.records SET body = 'final' WHERE id = 1")
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 3
        blocked = false
        loop do
          blocked = reader.exec_params('SELECT $2::int = ANY(pg_blocking_pids($1::int))', [a.backend_pid, b.backend_pid]).getvalue(0, 0) == 't'
          break if blocked || Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
          sleep 0.01
        end
        b.exec('COMMIT')
        a.get_last_result
        a.exec('COMMIT')
        _hi, events = interval(reader, lo)
        applied = 1
        ignored = 0
        events.each do |event|
          version = event['version'].to_i
          version > applied ? applied = version : ignored += 1
        end
        stored = reader.exec("SELECT body, _v FROM #{@schema}.records WHERE id = 1").first
        ok = blocked && events.map { |row| row['version'].to_i } == [3, 2]
        ok &&= events.first['xid8'].to_i == xid_a && applied == stored['_v'].to_i && ignored == 1 && stored['body'] == 'final'
        [ok, "lock observado=#{blocked}; versões na ordem xid8=#{events.map { |row| row['version'] }}; aplicada=#{applied}; ignoradas=#{ignored}"]
      end
    end
  end

  def atomic_sql_updates
    check('SQL direto incrementa _v e grava evento atomicamente, inclusive no rollback') do
      sessions(2) do |writer, reader|
        writer.exec("INSERT INTO #{@schema}.records VALUES (1, 'inicial', 1)")
        @admin.exec("TRUNCATE #{@schema}.outbox RESTART IDENTITY")
        lo = high(reader)
        writer.exec('BEGIN')
        writer.exec("UPDATE #{@schema}.records SET body = 'desfeito', _v = 999 WHERE id = 1")
        local = writer.exec("SELECT _v FROM #{@schema}.records WHERE id = 1").getvalue(0, 0)
        invisible = reader.exec("SELECT count(*) FROM #{@schema}.outbox").getvalue(0, 0) == '0'
        writer.exec('ROLLBACK')
        unchanged = reader.exec("SELECT body, _v FROM #{@schema}.records WHERE id = 1").first
        writer.exec("UPDATE #{@schema}.records SET body = 'confirmado', _v = 999 WHERE id = 1")
        _hi, rows = interval(reader, lo)
        stored = reader.exec("SELECT body, _v FROM #{@schema}.records WHERE id = 1").first
        ok = local == '2' && invisible && unchanged == { 'body' => 'inicial', '_v' => '1' }
        ok &&= stored == { 'body' => 'confirmado', '_v' => '2' } && rows.map { |row| [row['label'], row['version']] } == [['UPDATE', '2']]
        [ok, "versão local=#{local}; invisível antes do commit=#{invisible}; após rollback=#{unchanged}; SQL confirmado=#{stored}"]
      end
    end
  end

  def savepoints
    check('eventos em savepoints usam xid8 da transação principal e respeitam rollback parcial') do
      sessions(2) do |writer, reader|
        lo = high(reader)
        writer.exec('BEGIN')
        parent = writer.exec('SELECT pg_current_xact_id()::text').getvalue(0, 0)
        writer.exec('SAVEPOINT primeiro')
        writer.exec("INSERT INTO #{@schema}.records VALUES (1, 'mantido', 1)")
        writer.exec('RELEASE SAVEPOINT primeiro')
        writer.exec('SAVEPOINT segundo')
        writer.exec("UPDATE #{@schema}.records SET body = 'desfeito' WHERE id = 1")
        writer.exec('ROLLBACK TO SAVEPOINT segundo')
        writer.exec('COMMIT')
        _hi, rows = interval(reader, lo)
        stored = reader.exec("SELECT body, _v FROM #{@schema}.records WHERE id = 1").first
        ok = rows.size == 1 && rows.first['xid8'] == parent && rows.first['label'] == 'INSERT'
        ok &&= stored == { 'body' => 'mantido', '_v' => '1' }
        [ok, "xid principal=#{parent}; eventos=#{rows.map { |row| [row['xid8'], row['label']] }}; linha=#{stored}"]
      end
    end
  end

  def fresh_snapshots
    check('polling precisa de snapshot novo: REPEATABLE READ reutiliza um limite antigo') do
      sessions(3) do |stale, writer, reader|
        stale.exec('BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY')
        lo = high(stale)
        event = append(writer, 'posterior')
        stale_hi, stale_rows = interval(stale, lo)
        assigned = stale.exec('SELECT pg_current_xact_id_if_assigned()::text').getvalue(0, 0)
        fresh_hi, fresh_rows = interval(reader, lo)
        stale.exec('ROLLBACK')
        ok = assigned.nil? && stale_hi == lo && stale_rows.empty?
        ok &&= fresh_hi > event['xid8'].to_i && fresh_rows.map { |row| row['label'] } == ['posterior']
        [ok, "leitura sem xid=#{assigned.nil?}; hi antigo=#{stale_hi}; hi novo=#{fresh_hi}; eventos novos=#{fresh_rows.size}"]
      end
    end
  end

  def transaction_timeout
    check('transaction_timeout encerra a escrita longa e libera xmin sem publicar seu evento') do
      sessions(3) do |holder, writer, reader|
        lo = high(reader)
        holder.exec("SET transaction_timeout = '1500ms'")
        holder.exec('BEGIN')
        pending = append(holder, 'expirado')
        completed = append(writer, 'preservado', tenant: 2)
        held_hi, held = interval(reader, lo)
        error = begin
          holder.exec('SELECT pg_sleep(10)')
          nil
        rescue PG::Error => failure
          failure.message
        end
        hi, rows = interval(reader, held_hi)
        ok = held_hi <= pending['xid8'].to_i && held.empty? && error&.match?(/transaction timeout/i)
        ok &&= hi > completed['xid8'].to_i && rows.map { |row| row['label'] } == ['preservado']
        [ok, "xmin antes/depois=#{held_hi}/#{hi}; timeout confirmado=#{!!error&.match?(/transaction timeout/i)}; eventos=#{rows.map { |row| row['label'] }}"]
      end
    end
  end
end

exit(EventContinuityProbe.new(ENV.fetch('DATABASE_URL', 'postgres://postgres@127.0.0.1:5432/postgres')).run ? 0 : 1)

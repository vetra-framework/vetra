#!/usr/bin/env ruby
# Sonda do ADR-020 e ADR-030: revisão por instrução, revogação strict e releitura agrupada.
#
#   DATABASE_URL=postgres://superusuario@127.0.0.1:5432/descartavel ruby script/sonda_adr020.rb
#
# Use um banco descartável e um SUPERUSUÁRIO: cria um schema e dois papéis NOLOGIN exclusivos,
# removidos no ensure. As sessões da aplicação usam SET ROLE com um papel sem superusuário/BYPASSRLS.
# Os triggers e o verificador strict são protótipos; não são o gerador nem o runtime live do Vetra.
require 'bundler/inline'
require 'securerandom'

gemfile do
  source 'https://rubygems.org'
  gem 'pg'
  gem 'json', '>= 2.18', '< 3'
end

require 'json'

class LiveAuthorizationProbe
  def initialize(url)
    @url = url
    @schema = "vetra_sonda_adr020_#{Process.pid}_#{SecureRandom.hex(4)}"
    @owner, @app = "#{@schema}_owner", "#{@schema}_app"
    @roles, @results = [], []
  end

  def run
    @admin = connect(role: nil)
    version = @admin.exec('SHOW server_version').getvalue(0, 0)
    setup
    bulk_without_context
    updates_and_deletes
    empty_statements
    tenant_move
    atomic_revision
    concurrent_revisions
    revision_privileges
    temporary_shadowing
    strict_revocation
    strict_failure
    strict_snapshot
    private_row_events
    grouped_reread
    puts "PostgreSQL #{version} | pg #{PG::VERSION}"
    @results.each { |ok, name, detail| puts "  #{ok ? 'PASS' : 'FAIL'}  #{name} | #{detail}" }
    passed = @results.count { |ok, _, _| ok }
    puts "Resultado: #{passed}/#{@results.size} verificações passaram."
    passed == @results.size
  ensure
    if @admin && !@admin.finished?
      begin
        @admin.exec('RESET ROLE')
        @admin.exec("DROP SCHEMA IF EXISTS #{@schema} CASCADE")
        @roles.reverse_each { |role| @admin.exec("DROP ROLE #{role}") }
      ensure
        @admin.close
      end
    end
  end

  private

  def connect(role: @app)
    PG.connect(@url).tap do |connection|
      connection.exec("SET client_min_messages = warning")
      connection.exec("SET statement_timeout = '10s'")
      connection.exec("SET lock_timeout = '5s'")
      connection.exec("SET ROLE #{role}") if role
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
    @admin.exec("TRUNCATE #{@schema}.memberships, #{@schema}.messages, #{@schema}.revisions, #{@schema}.outbox RESTART IDENTITY")
    ok, detail = yield
    @results << [ok, name, detail]
  rescue StandardError => error
    @results << [false, name, "#{error.class}: #{error.message.lines.first&.strip}"]
  end

  def setup
    [@owner, @app].each do |role|
      @admin.exec("CREATE ROLE #{role} NOLOGIN NOSUPERUSER NOBYPASSRLS")
      @roles << role
    end
    @admin.exec("CREATE SCHEMA #{@schema} AUTHORIZATION #{@owner}")
    @admin.exec("SET ROLE #{@owner}")
    @admin.exec(<<~SQL)
      CREATE TABLE #{@schema}.revisions (tenant_id integer PRIMARY KEY, revision bigint NOT NULL);
      CREATE TABLE #{@schema}.memberships (
        tenant_id integer NOT NULL, room_id integer NOT NULL, actor_id integer NOT NULL,
        PRIMARY KEY (tenant_id, room_id, actor_id)
      );
      CREATE TABLE #{@schema}.messages (
        tenant_id integer NOT NULL, id integer NOT NULL, room_id integer NOT NULL,
        author_id integer NOT NULL, body text NOT NULL, _v bigint NOT NULL DEFAULT 1,
        PRIMARY KEY (tenant_id, id)
      );
      CREATE TABLE #{@schema}.outbox (
        seq bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
        xid8 xid8 NOT NULL DEFAULT pg_current_xact_id(), payload jsonb NOT NULL
      );
    SQL
    {
      'insert' => ['NEW TABLE AS new_members', 'SELECT DISTINCT tenant_id FROM new_members ORDER BY tenant_id'],
      'delete' => ['OLD TABLE AS old_members', 'SELECT DISTINCT tenant_id FROM old_members ORDER BY tenant_id'],
      'update' => ['OLD TABLE AS old_members NEW TABLE AS new_members', 'SELECT tenant_id FROM old_members UNION SELECT tenant_id FROM new_members ORDER BY tenant_id']
    }.each do |event, (relations, tenants)|
      @admin.exec(<<~SQL)
        CREATE FUNCTION #{@schema}.revise_#{event}() RETURNS trigger LANGUAGE plpgsql
          SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
        DECLARE affected_tenant integer;
        BEGIN
          FOR affected_tenant IN #{tenants} LOOP
            INSERT INTO #{@schema}.revisions AS stored (tenant_id, revision) VALUES (affected_tenant, 1)
              ON CONFLICT (tenant_id) DO UPDATE SET revision = stored.revision + 1;
            PERFORM pg_notify('#{@schema}', affected_tenant::text);
          END LOOP;
          RETURN NULL;
        END $$;
        CREATE TRIGGER revise_#{event} AFTER #{event.upcase} ON #{@schema}.memberships
          REFERENCING #{relations} FOR EACH STATEMENT EXECUTE FUNCTION #{@schema}.revise_#{event}();
      SQL
    end
    @admin.exec(<<~SQL)
      CREATE FUNCTION #{@schema}.bump_version() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        NEW._v = OLD._v + 1;
        RETURN NEW;
      END $$;
      CREATE TRIGGER version BEFORE UPDATE ON #{@schema}.messages
        FOR EACH ROW EXECUTE FUNCTION #{@schema}.bump_version();
      CREATE FUNCTION #{@schema}.message_event() RETURNS trigger LANGUAGE plpgsql
        SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
      DECLARE previous jsonb;
      BEGIN
        IF TG_OP = 'UPDATE' THEN
          previous = jsonb_build_object('room_id', OLD.room_id, 'author_id', OLD.author_id);
        END IF;
        INSERT INTO #{@schema}.outbox (payload) VALUES (jsonb_build_object(
          'entity', 'message', 'tenant_id', NEW.tenant_id, 'id', NEW.id, 'version', NEW._v,
          'operation', TG_OP, 'old', previous,
          'new', jsonb_build_object('room_id', NEW.room_id, 'author_id', NEW.author_id)
        ));
        RETURN NEW;
      END $$;
      CREATE TRIGGER message_event AFTER INSERT OR UPDATE ON #{@schema}.messages
        FOR EACH ROW EXECUTE FUNCTION #{@schema}.message_event();
      REVOKE ALL ON ALL FUNCTIONS IN SCHEMA #{@schema} FROM PUBLIC;
      GRANT USAGE ON SCHEMA #{@schema} TO #{@app};
      GRANT SELECT ON #{@schema}.revisions TO #{@app};
      GRANT SELECT, INSERT, UPDATE, DELETE ON #{@schema}.memberships, #{@schema}.messages TO #{@app};
    SQL
    @admin.exec('RESET ROLE')
  end

  def revisions(connection = @admin)
    connection.exec("SELECT tenant_id, revision FROM #{@schema}.revisions ORDER BY tenant_id").to_h do |row|
      [row['tenant_id'].to_i, row['revision'].to_i]
    end
  end

  def seed_members(values)
    values.each do |tenant, room, actor|
      @admin.exec_params("INSERT INTO #{@schema}.memberships VALUES ($1, $2, $3)", [tenant, room, actor])
    end
  end

  def notifications(connection, wait: false)
    received = []
    connection.wait_for_notify(3) { |_channel, _pid, payload| received << payload } if wait
    connection.exec('SELECT 1')
    while (message = connection.notifies)
      received << message[:extra]
    end
    received
  end

  def subscription(tenant: 1, room: 7, actor: 1)
    { tenant: tenant, room: room, actor: actor, revision: nil, allowed: false, status: :new }
  end

  def suspend(subscription, reason)
    subscription.merge!(revision: nil, allowed: false, status: :suspended, reason: reason)
    :suspended
  end

  # Demonstração strict, sem assinatura autenticada, RLS ou transporte. A aplicação real ainda precisa
  # fornecer esses componentes. Nenhum resultado protegido é entregue quando não se confirma a revisão.
  def strict_batch(connection, subscription)
    return :revoked if subscription[:status] == :revoked
    isolation = connection.exec('SHOW transaction_isolation').getvalue(0, 0)
    return suspend(subscription, :stale_snapshot) unless isolation == 'read committed'
    current = connection.exec_params("SELECT revision FROM #{@schema}.revisions WHERE tenant_id = $1", [subscription[:tenant]]).first
    return suspend(subscription, :missing_revision) unless current
    revision = current['revision'].to_i
    if revision != subscription[:revision]
      allowed = connection.exec_params(<<~SQL, subscription.values_at(:tenant, :room, :actor)).getvalue(0, 0) == 't'
        SELECT EXISTS (SELECT 1 FROM #{@schema}.memberships WHERE tenant_id = $1 AND room_id = $2 AND actor_id = $3)
      SQL
      subscription.merge!(revision: revision, allowed: allowed, status: allowed ? :active : :revoked)
    end
    subscription[:allowed] ? :deliver : :revoked
  rescue PG::Error => error
    suspend(subscription, error.result&.error_field(PG::PG_DIAG_SQLSTATE) || :connection)
  end

  def bulk_without_context
    check('INSERT em lote, sem contexto, incrementa uma vez por tenant afetado') do
      sessions(1) do |writer|
        context = writer.exec("SELECT current_setting('vetra.ctx', true)").getvalue(0, 0)
        writer.exec("INSERT INTO #{@schema}.memberships SELECT 1 + g % 2, 7, g FROM generate_series(1, 200) g")
        observed = revisions
        [context.to_s.empty? && observed == { 1 => 1, 2 => 1 }, "contexto ausente=#{context.to_s.empty?}; 200 linhas; revisões=#{observed}"]
      end
    end
  end

  def updates_and_deletes
    check('UPDATE e DELETE invalidam somente os tenants das linhas afetadas') do
      seed_members([[1, 7, 1], [1, 7, 2], [2, 7, 1]])
      @admin.exec("TRUNCATE #{@schema}.revisions")
      sessions(1) do |writer|
        writer.exec("UPDATE #{@schema}.memberships SET room_id = 8")
        updated = revisions
        writer.exec("DELETE FROM #{@schema}.memberships WHERE tenant_id = 1")
        deleted = revisions
        [updated == { 1 => 1, 2 => 1 } && deleted == { 1 => 2, 2 => 1 }, "após UPDATE=#{updated}; após DELETE=#{deleted}"]
      end
    end
  end

  def empty_statements
    check('instruções sem linhas afetadas não criam revisões') do
      sessions(1) do |writer|
        writer.exec("INSERT INTO #{@schema}.memberships SELECT 1, 7, 1 WHERE false")
        writer.exec("UPDATE #{@schema}.memberships SET room_id = 8 WHERE false")
        writer.exec("DELETE FROM #{@schema}.memberships WHERE false")
        [revisions.empty?, "revisões=#{revisions}"]
      end
    end
  end

  def tenant_move
    check('troca de tenant invalida origem e destino, sem usar tenant de sessão') do
      seed_members([[1, 7, 1]])
      @admin.exec("TRUNCATE #{@schema}.revisions")
      sessions(1) do |writer|
        writer.exec("SET vetra.sonda_tenant = '999'")
        writer.exec("UPDATE #{@schema}.memberships SET tenant_id = 2 WHERE tenant_id = 1")
        observed = revisions
        [observed == { 1 => 1, 2 => 1 }, "origem/destino=#{observed}; seletor de sessão=999"]
      end
    end
  end

  def atomic_revision
    check('mudança de permissão e revisão confirmam ou desfazem juntas') do
      seed_members([[1, 7, 1]])
      sessions(2) do |writer, reader|
        before = revisions(reader)
        reader.exec("LISTEN #{@schema}")
        writer.exec('BEGIN')
        writer.exec("DELETE FROM #{@schema}.memberships WHERE tenant_id = 1")
        own = revisions(writer)
        invisible = revisions(reader)
        writer.exec('ROLLBACK')
        reverted = revisions(reader)
        rolled_back_notices = notifications(reader)
        kept = reader.exec("SELECT count(*) FROM #{@schema}.memberships").getvalue(0, 0) == '1'
        writer.exec("DELETE FROM #{@schema}.memberships WHERE tenant_id = 1")
        committed = revisions(reader)
        committed_notices = notifications(reader, wait: true)
        ok = before == { 1 => 1 } && own == { 1 => 2 } && invisible == before && reverted == before && kept
        ok &&= rolled_back_notices.empty? && committed_notices == ['1']
        [ok && committed == { 1 => 2 }, "local=#{own}; outra sessão=#{invisible}; rollback=#{reverted}; commit=#{committed}; notificações rollback/commit=#{[rolled_back_notices.size, committed_notices.size]}"]
      end
    end
  end

  def concurrent_revisions
    check('UPSERT concorrente espera o lock e preserva os dois incrementos') do
      sessions(3) do |a, b, reader|
        a.exec('BEGIN')
        a.exec("INSERT INTO #{@schema}.memberships VALUES (1, 7, 1)")
        b.exec('BEGIN')
        b.send_query("INSERT INTO #{@schema}.memberships VALUES (1, 7, 2)")
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 3
        blocked = false
        loop do
          blocked = reader.exec_params('SELECT $2::int = ANY(pg_blocking_pids($1::int))', [b.backend_pid, a.backend_pid]).getvalue(0, 0) == 't'
          break if blocked || Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
          sleep 0.01
        end
        a.exec('COMMIT')
        b.get_last_result
        b.exec('COMMIT')
        observed = revisions(reader)
        [blocked && observed == { 1 => 2 }, "lock observado=#{blocked}; revisões=#{observed}"]
      end
    end
  end

  def revision_privileges
    check('papel da aplicação não altera revisões nem desativa a invalidação') do
      sessions(1) do |writer|
        flags = writer.exec('SELECT rolsuper, rolbypassrls FROM pg_roles WHERE rolname = current_user').first
        attempts = [
          "INSERT INTO #{@schema}.revisions VALUES (1, 999)",
          "UPDATE #{@schema}.revisions SET revision = 999",
          "DELETE FROM #{@schema}.revisions",
          "TRUNCATE #{@schema}.memberships",
          "ALTER TABLE #{@schema}.memberships DISABLE TRIGGER ALL",
          "INSERT INTO #{@schema}.outbox (payload) VALUES ('{}')"
        ].map do |sql|
          begin
            writer.exec(sql)
            nil
          rescue PG::Error => error
            error.result&.error_field(PG::PG_DIAG_SQLSTATE)
          end
        end
        ok = flags == { 'rolsuper' => 'f', 'rolbypassrls' => 'f' } && attempts == ['42501'] * 6
        [ok, "papel=#{flags}; recusas SQLSTATE=#{attempts}"]
      end
    end
  end

  def temporary_shadowing
    check('tabelas temporárias não substituem revisões nem relações de transição') do
      sessions(1) do |writer|
        writer.exec('CREATE TEMP TABLE revisions (tenant_id integer, revision bigint)')
        writer.exec('INSERT INTO revisions VALUES (999, 999)')
        writer.exec('CREATE TEMP TABLE new_members (tenant_id integer)')
        writer.exec('INSERT INTO new_members VALUES (999)')
        writer.exec("INSERT INTO #{@schema}.memberships VALUES (1, 7, 1)")
        observed = revisions
        untouched = writer.exec('SELECT revision FROM pg_temp.revisions').getvalue(0, 0) == '999'
        [observed == { 1 => 1 } && untouched, "revisões reais=#{observed}; tabela temporária intacta=#{untouched}"]
      end
    end
  end

  def strict_revocation
    check('strict revalida após revogação, mesmo sem receber a notificação') do
      seed_members([[1, 7, 1], [1, 8, 1]])
      sessions(2) do |writer, reader|
        affected = subscription
        other = subscription(room: 8)
        initial = [strict_batch(reader, affected), strict_batch(reader, other)]
        writer.exec("DELETE FROM #{@schema}.memberships WHERE tenant_id = 1 AND room_id = 7")
        following = [strict_batch(reader, affected), strict_batch(reader, other)]
        ok = initial == [:deliver, :deliver] && following == [:revoked, :deliver]
        [ok, "antes=#{initial}; após commit=#{following}; sem conexão LISTEN"]
      end
    end
  end

  def strict_failure
    check('falha de leitura suspende strict e a recuperação exige nova autorização') do
      seed_members([[1, 7, 1]])
      sessions(2) do |writer, reader|
        target = subscription
        initial = strict_batch(reader, target)
        writer.exec("DELETE FROM #{@schema}.memberships WHERE tenant_id = 1")
        @admin.exec('BEGIN')
        begin
          @admin.exec("LOCK TABLE #{@schema}.revisions IN ACCESS EXCLUSIVE MODE")
          reader.exec("SET lock_timeout = '100ms'")
          failed = strict_batch(reader, target)
          reason = target[:reason]
        ensure
          @admin.exec('ROLLBACK')
        end
        recovered = strict_batch(reader, target)
        missing = strict_batch(reader, subscription(tenant: 999))
        ok = initial == :deliver && failed == :suspended && reason == '55P03' && recovered == :revoked && missing == :suspended
        [ok, "falha=#{failed}/#{reason}; recuperação=#{recovered}; revisão ausente=#{missing}"]
      end
    end
  end

  def strict_snapshot
    check('strict recusa snapshot repetível antigo e consulta nova observa a revogação') do
      seed_members([[1, 7, 1]])
      sessions(2) do |writer, reader|
        target = subscription
        initial = strict_batch(reader, target)
        reader.exec('BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY')
        revisions(reader)
        writer.exec("DELETE FROM #{@schema}.memberships WHERE tenant_id = 1")
        stale = strict_batch(reader, target)
        reason = target[:reason]
        reader.exec('ROLLBACK')
        fresh = strict_batch(reader, target)
        ok = initial == :deliver && stale == :suspended && reason == :stale_snapshot && fresh == :revoked
        [ok, "snapshot antigo=#{stale}/#{reason}; snapshot novo=#{fresh}"]
      end
    end
  end

  def private_row_events
    check('SQL direto produz OLD/NEW sem conteúdo pessoal e rollback desfaz o evento') do
      sessions(1) do |writer|
        writer.exec("INSERT INTO #{@schema}.messages VALUES (1, 1, 7, 1, 'segredo-inicial', 1)")
        writer.exec("UPDATE #{@schema}.messages SET body = 'segredo-novo', room_id = 8 WHERE tenant_id = 1")
        writer.exec('BEGIN')
        writer.exec("UPDATE #{@schema}.messages SET body = 'segredo-desfeito' WHERE tenant_id = 1")
        writer.exec('ROLLBACK')
        rows = @admin.exec("SELECT payload::text FROM #{@schema}.outbox ORDER BY seq").map { |row| JSON.parse(row['payload']) }
        stored = writer.exec("SELECT body, _v FROM #{@schema}.messages").first
        expected = %w[entity id new old operation tenant_id version]
        ok = rows.size == 2 && rows.all? { |row| row.keys.sort == expected }
        ok &&= rows.all? { |row| row['new'].keys.sort == %w[author_id room_id] }
        ok &&= rows.first['old'].nil? && rows.last['old'] == { 'room_id' => 7, 'author_id' => 1 }
        ok &&= rows.last['new'] == { 'room_id' => 8, 'author_id' => 1 } && rows.last['version'] == 2
        ok &&= stored == { 'body' => 'segredo-novo', '_v' => '2' } && !JSON.generate(rows).include?('segredo')
        [ok, "eventos=#{rows.size}; versão=#{stored['_v']}; chaves novas=#{rows.last&.dig('new')&.keys}; conteúdo pessoal ausente=#{!JSON.generate(rows).include?('segredo')}"]
      end
    end
  end

  def grouped_reread
    check('releitura demonstrativa agrupa por tenant e predicado sem uma consulta por tela') do
      @admin.exec("INSERT INTO #{@schema}.memberships SELECT tenant, 7, actor FROM generate_series(1, 2) tenant CROSS JOIN generate_series(1, 100) actor")
      @admin.exec("INSERT INTO #{@schema}.messages VALUES (1, 1, 7, 1, 'privado-1', 1), (2, 1, 7, 1, 'privado-2', 1)")
      subscribers = (1..2).flat_map do |tenant|
        (1..100).map { |actor| { tenant: tenant, room: 7, actor: actor, fields: %w[body], locale: 'pt-BR', template: 'message' } }
      end
      groups = subscribers.group_by do |subscriber|
        subscriber.values_at(:tenant, :room, :fields, :locale, :template) + [subscriber[:actor] == 1]
      end
      reads = 0
      correct = true
      sessions(1) do |reader|
        groups.each_value do |group|
          representative = group.first
          row = reader.exec_params(<<~SQL, representative.values_at(:tenant, :room, :actor)).first
            SELECT message.body FROM #{@schema}.messages message
             WHERE message.tenant_id = $1 AND message.room_id = $2 AND message.id = 1
               AND EXISTS (SELECT 1 FROM #{@schema}.memberships member
                 WHERE member.tenant_id = $1 AND member.room_id = $2 AND member.actor_id = $3)
          SQL
          reads += 1
          correct &&= row && group.all? { |subscriber| row['body'] == "privado-#{subscriber[:tenant]}" }
          correct &&= group.map { |subscriber| subscriber[:actor] == 1 }.uniq.size == 1
        end
      end
      [correct && reads == 4 && groups.size == 4, "telas=#{subscribers.size}; grupos e consultas=#{reads}; tenants e predicados separados=#{!!correct}"]
    end
  end
end

exit(LiveAuthorizationProbe.new(ENV.fetch('DATABASE_URL', 'postgres://postgres@127.0.0.1:5432/postgres')).run ? 0 : 1)

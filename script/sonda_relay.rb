#!/usr/bin/env ruby
# PostgreSQL 17/18 descartável, bootstrap ADR-036 pronto (com vetra_relay); DATABASE_URL administrativa.
# VETRA_APP_PASSWORD e VETRA_RELAY_PASSWORD: senhas dos logins reais, se necessárias. VETRA_PG_DUMP: pg_dump da versão.
# Aplica os planos pelo db:migrate como vetra_migrator, grava eventos como vetra_app e roda o relay, as entregas e a
# manutenção como vetra_relay, com consumidores simulados (ADR-014, ADR-024 e ADR-040). Não altera papéis nem artefatos.
require_relative 'sonda_outbox'

class RelayProbe < OutboxProbe
  EXAMPLES = %w[mini_crm blog].freeze

  # Provedor simulado: com chave de idempotência, um efeito por event_id; sem chave, um efeito por chamada.
  class Provider
    attr_reader :effects

    def initialize(keyed)
      @keyed, @effects = keyed, []
    end

    def deliver(delivery)
      @effects << delivery.event_id unless @keyed && @effects.include?(delivery.event_id)
    end
  end

  def run
    @admin = PG.connect(@url)
    @admin.exec('SET client_min_messages = warning')
    @admin.exec(Vetra::SQL::Context.role_guard)
    before = roles
    EXAMPLES.each do |example|
      @example = example
      @root = File.expand_path("../examples/#{example}", __dir__)
      @linked = Vetra::Graph::Compiler.new(root: @root).link
      @catalog = Vetra::Data::Repositories.new(@linked.document)
      @connection = create_database
      @database_name = @databases.last
      migrate_checks
      open_runtime
      if tenant?
        provision('runtime', @secret)
        @work = Vetra::Data::UnitOfWork.new(@runtime, issuer: Vetra::Data::ContextIssuer.new(kid: 'runtime', secret: @secret))
        @tenants, @actors = [@tenant, SecureRandom.uuid], [@actor, SecureRandom.uuid]
      else
        @work = Vetra::Data::UnitOfWork.new(@runtime, scope: :global)
      end
      open_relay
      maintenance_checks
      prepare_records
      relay_checks
      tenant? ? delivery_checks : global_checks
      purge_checks if tenant?
      concurrent_purge_check if tenant?
      lock_order_check if tenant?
      worker_order_check if tenant?
      isolation_checks
      check_case('nenhum statement nomeado no relay nem no runtime') do
        @relay_db[:pg_prepared_statements].count.zero? && @runtime[:pg_prepared_statements].count.zero?
      end
      close_relay
      close_runtime
    end
    check('nenhum papel global mudou') { roles == before }
    puts "#{@results.count(true)}/#{@results.size} verificações passaram (PostgreSQL #{@admin.server_version})."
    @results.all?
  ensure
    close_relay
    close_runtime
    @listener&.close
    if @admin
      @databases.reverse_each { |name| @admin.exec("DROP DATABASE IF EXISTS #{PG::Connection.quote_ident(name)} WITH (FORCE)") }
      @admin.close
    end
  end

  private

  def migrator_connection
    connection = PG.connect(connection_params(@database_name))
    connection.exec('SET client_min_messages = warning')
    connection.exec('SET SESSION AUTHORIZATION vetra_migrator')
    connection
  end

  def migrate
    connection = migrator_connection
    database = Vetra::SQL::MigrationDatabase.new(connection: connection, pg_dump: ENV.fetch('VETRA_PG_DUMP', 'pg_dump'))
    Vetra::SQL::Migrator.new(root: @root, database: database, sleeper: ->(_) {}).migrate
  ensure
    connection&.close
  end

  def drift
    migrate
    false
  rescue Vetra::Graph::Error => error
    error.diagnostics.map(&:code).include?('db_migrate_drift')
  end

  def open_relay
    @relay_db = Vetra::Data::Relay.connect({ adapter: :postgres, host: @admin.host, hostaddr: @admin.hostaddr, port: @admin.port,
                                             database: @database_name, password: ENV.fetch('VETRA_RELAY_PASSWORD', '') },
                                           max_connections: 2)
    @relay = Vetra::Data::Relay.new(@relay_db, document: @linked.document, random: Random.new(7))
  end

  def close_relay
    @relay_db&.disconnect
    @relay_db = nil
  end

  def as_superuser(sql, params = [])
    @connection.exec_params(sql, params).to_a
  end

  def today
    Time.now.utc.to_date
  end

  def partitions
    as_superuser(<<~SQL).map { |row| row['relname'] }
      SELECT c.relname FROM pg_inherits i JOIN pg_class c ON c.oid = i.inhrelid
       WHERE i.inhparent IN ('vetra.outbox'::regclass, 'vetra.deliveries'::regclass) AND c.relname ~ '_p[0-9]{8}$'
       ORDER BY 1
    SQL
  end

  def deliveries
    as_superuser("SELECT handler, event_id::text, state, attempts, last_error, tableoid::regclass::text AS partition FROM vetra.deliveries ORDER BY event_created_at, event_id")
  end

  def migrate_checks
    check_case('db:migrate aplica os três planos como vetra_migrator, com a guarda do vetra_relay') do
      result = migrate
      result.status == :applied && result.applied.map(&:file_name) == %w[0001_inicial.sql 0002_expand.sql 0003_expand.sql]
    end
  end

  def maintenance_checks
    days = (0..3).map { |offset| (today + offset).strftime('%Y%m%d') }
    expected = days.flat_map { |day| ["deliveries_p#{day}", "outbox_p#{day}"] }.sort
    check_case('manutenção cria as partições de hoje a três dias, com RLS forçado, dono vetra_owner e sem concessões') do
      summary = @relay.maintain(ahead: 3, retention: 7)
      shape = as_superuser(<<~SQL)
        SELECT bool_and(c.relrowsecurity AND c.relforcerowsecurity AND pg_get_userbyid(c.relowner) = 'vetra_owner'
                        AND (c.relacl IS NULL OR c.relacl = acldefault('r', c.relowner))) AS ok
          FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
         WHERE n.nspname = 'vetra' AND c.relname ~ '_p[0-9]{8}$'
      SQL
      summary['criadas'].sort == expected && summary['recuperadas'].zero? && partitions == expected && shape.first['ok'] == 't'
    end
    check_case('segunda manutenção não cria nada') { @relay.maintain(ahead: 3, retention: 7)['criadas'].empty? }
    check_case('db:migrate reconhece as partições da manutenção sem deriva') { migrate.status == :up_to_date }
    check_case('partição com concessão a mais é deriva; sem ela, volta a conferir') do
      as_superuser("GRANT SELECT ON vetra.outbox_p#{days.first} TO vetra_app")
      tampered = drift
      as_superuser("REVOKE SELECT ON vetra.outbox_p#{days.first} FROM vetra_app")
      tampered && migrate.status == :up_to_date
    end
    check_case('partição com o nome da manutenção e intervalo errado é deriva') do
      day = (today + 20).strftime('%Y%m%d')
      as_superuser("CREATE TABLE vetra.outbox_p#{day} PARTITION OF vetra.outbox FOR VALUES FROM ('#{today + 20}') TO ('#{today + 22}')")
      as_superuser("ALTER TABLE vetra.outbox_p#{day} OWNER TO vetra_owner")
      tampered = drift
      as_superuser("DROP TABLE vetra.outbox_p#{day}")
      tampered && migrate.status == :up_to_date
    end
  end

  def emit(index)
    emit_one(index).first.first
  end

  def relay_checks
    @events = []
    check_case('eventos novos caem na partição do dia, e o relay materializa uma entrega por handler, uma vez só') do
      @events << emit(0) << emit(2)
      read = @relay.relay!
      handlers = Vetra::Data::Relay.handlers(@linked.document).values.flatten
      rows = deliveries
      again = @relay.relay!
      in_day = outbox_rows.all? { |row| row['partition'] == "vetra.outbox_p#{today.strftime('%Y%m%d')}" }
      read == 2 && again.zero? && in_day && rows.size == 2 * handlers.size && deliveries == rows &&
        rows.all? { |row| row['state'] == 'pending' && row['partition'] == "vetra.deliveries_p#{today.strftime('%Y%m%d')}" }
    end
    check_case('transação aberta segura a faixa e o relay não pula o evento dela') do
      blocker = Vetra::Data.connect({ adapter: :postgres, host: @admin.host, hostaddr: @admin.hostaddr, port: @admin.port,
                                      database: @database_name, password: ENV.fetch('VETRA_APP_PASSWORD', '') }, max_connections: 1)
      begin
        held = Queue.new
        release = Queue.new
        # No CRM, a revisão de autorização do tenant serializa as escritas dele: a transação aberta fica no outro tenant.
        extra = if tenant?
          within('crm.create_lead', tenant_index: 1) do
            repository('crm.companies').create!(name: 'Outra empresa')
            repository('crm.leads').create!(name: 'Lead do outro tenant')
          end
        else
          new_record
        end
        thread = Thread.new do
          work = tenant? ? Vetra::Data::UnitOfWork.new(blocker, issuer: Vetra::Data::ContextIssuer.new(kid: 'runtime', secret: @secret)) :
                           Vetra::Data::UnitOfWork.new(blocker, scope: :global)
          claims = { actor_id: tenant? ? @actors[1] : @actor, op_id: SecureRandom.uuid, cmd: tenant? ? 'crm.win_lead' : 'blog.publish_post' }
          claims[:tenant_id] = @tenants[1] if tenant?
          work.transaction(**claims) do |unit|
            record = tenant? ? @catalog.bind('crm.leads', unit: unit).update!(extra.id, status: 'won') :
                               @catalog.bind('blog.posts', unit: unit).update!(extra.id, status: 'published', published_at: unit.now)
            held << @catalog.emit!(unit, record).first
            release.pop
          end
        end
        slow = held.pop(timeout: 10)
        later = emit_extra
        first = @relay.relay!
        release << true
        thread.join(10)
        second = @relay.relay!
        @events << slow << later
        first.zero? && second == 2 && deliveries.size == @events.size * handler_count
      ensure
        release << true
        blocker.disconnect
      end
    end
    check_case('evento de uma unidade desfeita nunca chega às entregas') do
      before = deliveries.size
      begin
        emit_one(1, rollback: true)
      rescue Sequel::Rollback
        nil
      end
      @relay.relay!
      deliveries.size == before
    end
    check_case('outro relay com o checkpoint travado devolve 0 sem esperar') do
      emit_extra.then { |id| @events << id }
      other = Sequel.connect({ adapter: :postgres, host: @admin.host, hostaddr: @admin.hostaddr, port: @admin.port,
                               database: @database_name, user: 'vetra_relay', password: ENV.fetch('VETRA_RELAY_PASSWORD', '') })
      begin
        locked = Queue.new
        done = Queue.new
        thread = Thread.new do
          other.transaction do
            other.fetch("SELECT 1 FROM vetra.relay_checkpoints WHERE name = 'relay' FOR UPDATE").all
            locked << true
            done.pop
          end
        end
        locked.pop(timeout: 10)
        skipped = @relay.relay!
        done << true
        thread.join(10)
        skipped.zero? && @relay.relay! == 1
      ensure
        done << true
        other.disconnect
      end
    end
  end

  def handler_count
    Vetra::Data::Relay.handlers(@linked.document).values.flatten.size
  end

  def new_record
    if tenant?
      within('crm.create_lead') { repository('crm.leads').create!(name: 'Lead extra') }
    else
      within('blog.create_post') { repository('blog.posts').create!(title: 'Post extra') }
    end
  end

  # Um evento a mais, por um comando real, num registro novo.
  def emit_extra
    if tenant?
      lead = within('crm.create_lead') { repository('crm.leads').create!(name: 'Lead extra') }
      command_with_events('crm.win_lead', { lead_id: lead.id }).first.first
    else
      post = within('blog.create_post') { repository('blog.posts').create!(title: 'Post extra') }
      command_with_events('blog.publish_post', { post_id: post.id }).first.first
    end
  end

  def global_checks
    check_case('sem handlers, o relay avança o checkpoint sem criar entregas') do
      checkpoint = as_superuser("SELECT next_xid8::text FROM vetra.relay_checkpoints WHERE name = 'relay'").first['next_xid8']
      deliveries.empty? && @connection.exec_params('SELECT $1::xid8 > $2::xid8', [checkpoint, '0']).getvalue(0, 0) == 't'
    end
  end

  def delivery_checks
    handler = 'crm.notify_sales'
    check_case('dois workers não reservam a mesma entrega enquanto o lease vale') do
      first = @relay.reserve(handler, limit: 100, lease: 30)
      second = @relay.reserve(handler, limit: 100, lease: 30)
      @reserved = first
      first.size == @events.size && second.empty? && first.all? { |delivery| delivery.payload['id'].is_a?(String) && delivery.frozen? }
    end
    check_case('worker que cai: o lease vence, outro repete; com chave um efeito, sem chave dois') do
      keyed, plain = Provider.new(true), Provider.new(false)
      # O primeiro worker faz o efeito e cai antes de concluir.
      @reserved.each { |delivery| keyed.deliver(delivery); plain.deliver(delivery) }
      as_superuser("UPDATE vetra.deliveries SET leased_until = statement_timestamp() - interval '1 second' WHERE state = 'pending'")
      open = []
      counts = @relay.work(handler, limit: 100) do |delivery|
        # Durante o efeito, nenhuma sessão do relay segura transação: o xmin não fica preso (ADR-014, §2).
        open << as_superuser("SELECT count(*) FROM pg_stat_activity WHERE usename = 'vetra_relay' AND datname = current_database() " \
                             "AND (backend_xid IS NOT NULL OR state LIKE 'idle in transaction%')").first['count']
        keyed.deliver(delivery)
        plain.deliver(delivery)
      end
      late = @reserved.none? { |delivery| @relay.complete(delivery) }
      counts[:done] == @reserved.size && late && open.uniq == ['0'] &&
        keyed.effects.size == @reserved.size && plain.effects.size == 2 * @reserved.size
    end
    check_case('falha retentável repete com espera crescente e sem a mensagem do erro') do
      event = emit_extra
      @relay.relay!
      counts = @relay.work(handler) { raise ArgumentError, 'segredo do evento' }
      row = as_superuser("SELECT attempts, last_error, run_after - statement_timestamp() AS wait FROM vetra.deliveries WHERE event_id = $1", [event]).first
      wait = row['wait'][/\A00:00:(\d+(?:\.\d+)?)/, 1].to_f
      counts[:retry] == 1 && row['attempts'] == '1' && row['last_error'] == 'ArgumentError' && wait.between?(7, 13)
    end
    check_case('a décima falha leva a dead e copia o evento para dead_deliveries') do
      as_superuser("UPDATE vetra.deliveries SET attempts = 9, run_after = statement_timestamp() WHERE state = 'pending'")
      counts = @relay.work(handler) { raise IOError }
      dead = as_superuser("SELECT handler, event_id::text, attempts, payload->>'id' AS id FROM vetra.dead_deliveries")
      counts[:dead] == 1 && dead.size == 1 && dead.first['attempts'] == '10' && !dead.first['id'].nil?
    end
    check_case('falha definitiva vai direto a dead, sem atrasar as outras') do
      permanent, normal = emit_extra, emit_extra
      @relay.relay!
      counts = @relay.work(handler) do |delivery|
        raise Vetra::Data::Relay::PermanentFailure if delivery.event_id == permanent
      end
      states = deliveries.to_h { |row| [row['event_id'], row['state']] }
      counts[:dead] == 1 && counts[:done] == 1 && states[permanent] == 'dead' && states[normal] == 'done'
    end
  end

  def purge_checks
    old = (today - 10)
    check_case('DEFAULT populada antes da manutenção é recuperada sem perder nem duplicar eventos') do
      ids = Array.new(2) { SecureRandom.uuid }
      ids.each do |id|
        as_superuser(<<~SQL, [old.to_s, id, @tenant, @actor, id])
          INSERT INTO vetra.outbox (created_at, event_id, event, version, tenant_id, actor_id, op_id, cmd, payload)
          VALUES ($1::date::timestamp AT TIME ZONE 'UTC', $2, 'crm.lead.won', 1, $3, $4, gen_random_uuid(), 'crm.win_lead', jsonb_build_object('id', $5::text))
        SQL
      end
      in_default = as_superuser('SELECT count(*) FROM vetra.outbox_default').first['count'] == '2'
      summary = @relay.maintain(ahead: 3, retention: 30)
      moved = as_superuser("SELECT event_id::text, tableoid::regclass::text AS partition FROM vetra.outbox WHERE event_id = ANY($1::uuid[])",
                           ["{#{ids.join(',')}}"])
      in_default && summary['recuperadas'] == 2 && summary['criadas'].include?("outbox_p#{old.strftime('%Y%m%d')}") &&
        moved.map { |row| row['event_id'] }.sort == ids.sort && moved.all? { |row| row['partition'] == "vetra.outbox_p#{old.strftime('%Y%m%d')}" } &&
        as_superuser('SELECT count(*) FROM vetra.outbox_default').first['count'] == '0' && migrate.status == :up_to_date
    end
    check_case('purga mantém o dia com evento não lido ou entrega pendente, recupera entregas na DEFAULT e remove depois') do
      day = old.strftime('%Y%m%d')
      pair = ["deliveries_p#{day}", "outbox_p#{day}"]
      unread = @relay.maintain(ahead: 3, retention: 7)['mantidas'].include?("outbox_p#{day}")
      @relay.relay!
      second = @relay.maintain(ahead: 3, retention: 7)
      pending = second['recuperadas'] == 2 && (second['mantidas'] & pair).sort == pair
      as_superuser("UPDATE vetra.deliveries SET state = 'done' WHERE event_created_at < $1::date::timestamp AT TIME ZONE 'UTC'", [(old + 1).to_s])
      dead_before = as_superuser('SELECT count(*) FROM vetra.dead_deliveries').first['count']
      removed = @relay.maintain(ahead: 3, retention: 7)['removidas']
      unread && pending && removed.sort == pair && (partitions & pair).empty? &&
        as_superuser('SELECT count(*) FROM vetra.dead_deliveries').first['count'] == dead_before && migrate.status == :up_to_date
    end
  end

  # Uma materialização em curso trava o checkpoint e insere entregas ainda não confirmadas: a purga espera por ela e,
  # depois, enxerga as entregas e mantém o dia.
  def concurrent_purge_check
    check_case('a purga espera uma materialização em curso e não apaga as entregas dela') do
      day = today - 12
      name = day.strftime('%Y%m%d')
      as_superuser(<<~SQL, [day.to_s, @tenant, @actor])
        INSERT INTO vetra.outbox (created_at, event_id, event, version, tenant_id, actor_id, op_id, cmd, payload)
        VALUES ($1::date::timestamp AT TIME ZONE 'UTC', gen_random_uuid(), 'crm.lead.won', 1, $2, $3, gen_random_uuid(),
                'crm.win_lead', '{}')
      SQL
      @relay.maintain(ahead: 3, retention: 30)
      @relay.relay!
      as_superuser("UPDATE vetra.deliveries SET state = 'done' WHERE event_created_at < $1::date::timestamp AT TIME ZONE 'UTC'", [(day + 1).to_s])
      other = Sequel.connect({ adapter: :postgres, host: @admin.host, hostaddr: @admin.hostaddr, port: @admin.port,
                               database: @database_name, user: 'vetra_relay', password: ENV.fetch('VETRA_RELAY_PASSWORD', '') })
      fake = SecureRandom.uuid
      begin
        locked, release = Queue.new, Queue.new
        holder = Thread.new do
          other.transaction do
            other.fetch("SELECT 1 FROM vetra.relay_checkpoints WHERE name = 'relay' FOR UPDATE").all
            other.run("INSERT INTO vetra.deliveries (event_created_at, event_xid8, event_seq, event_id, handler, tenant_id) " \
                      "VALUES ('#{day}'::date::timestamp AT TIME ZONE 'UTC', '1', 1, '#{fake}', 'crm.notify_sales', '#{@tenant}')")
            locked << true
            release.pop
          end
        end
        locked.pop(timeout: 10)
        result = Queue.new
        purge = Thread.new { result << @relay.maintain(ahead: 3, retention: 7) }
        deadline = Time.now + 5
        waited = false
        until waited || Time.now > deadline
          waited = as_superuser("SELECT count(*) FROM pg_stat_activity WHERE usename = 'vetra_relay' AND wait_event_type = 'Lock'").first['count'] != '0'
          sleep 0.05
        end
        release << true
        holder.join(10)
        purge.join(10)
        summary = result.pop(timeout: 1)
        kept = ["deliveries_p#{name}", "outbox_p#{name}"]
        waited && summary && (summary['mantidas'] & kept).sort == kept && (partitions & kept).sort == kept &&
          as_superuser('SELECT count(*) FROM vetra.deliveries WHERE event_id = $1', [fake]).first['count'] == '1'
      ensure
        release << true
        other.disconnect
      end
    end
  end

  # O relay trava o checkpoint e depois lê a outbox; a manutenção que precisa criar uma partição trava o checkpoint
  # antes de qualquer lock na outbox. Na mesma ordem, uma espera pela outra, sem deadlock.
  def lock_order_check
    check_case('manutenção que cria partição espera o relay em curso, na mesma ordem de locks, sem deadlock') do
      other = Sequel.connect({ adapter: :postgres, host: @admin.host, hostaddr: @admin.hostaddr, port: @admin.port,
                               database: @database_name, user: 'vetra_relay', password: ENV.fetch('VETRA_RELAY_PASSWORD', '') })
      begin
        locked, go = Queue.new, Queue.new
        read = nil
        holder = Thread.new do
          other.transaction do
            other.fetch("SELECT 1 FROM vetra.relay_checkpoints WHERE name = 'relay' FOR UPDATE").all
            locked << true
            go.pop
            # Como o relay!, lê a outbox depois de travar o checkpoint, com a manutenção já esperando.
            read = other.fetch('SELECT count(*) AS n FROM vetra.outbox').first[:n]
          end
        end
        locked.pop(timeout: 10)
        result = Queue.new
        maintenance = Thread.new do
          result << begin
            @relay.maintain(ahead: 12, retention: 30)
          rescue StandardError => error
            error
          end
        end
        deadline = Time.now + 5
        waited = false
        until waited || Time.now > deadline
          waited = as_superuser("SELECT count(*) FROM pg_stat_activity WHERE usename = 'vetra_relay' AND wait_event_type = 'Lock'").first['count'] != '0'
          sleep 0.05
        end
        go << true
        holder.join(10)
        maintenance.join(15)
        summary = result.pop(timeout: 1)
        future = "outbox_p#{(today + 12).strftime('%Y%m%d')}"
        waited && !read.nil? && summary.is_a?(Hash) && summary['criadas'].include?(future) && partitions.include?(future)
      ensure
        go << true
        other.disconnect
      end
    end
  end

  # Um worker que leva uma entrega a dead trava a outbox, atualiza as entregas e copia o evento; a manutenção que cria
  # partições trava a outbox e depois as entregas. Na mesma ordem, a manutenção espera o worker, sem deadlock.
  def worker_order_check
    check_case('manutenção espera um worker que trava a outbox e as entregas, na mesma ordem, sem deadlock') do
      other = Sequel.connect({ adapter: :postgres, host: @admin.host, hostaddr: @admin.hostaddr, port: @admin.port,
                               database: @database_name, user: 'vetra_relay', password: ENV.fetch('VETRA_RELAY_PASSWORD', '') })
      begin
        locked, go = Queue.new, Queue.new
        copied = nil
        worker = Thread.new do
          other.transaction do
            other.run('LOCK TABLE vetra.outbox IN ACCESS SHARE MODE')
            other.run("UPDATE vetra.deliveries SET updated_at = updated_at WHERE handler = 'crm.nenhum'")
            locked << true
            go.pop
            copied = other.fetch('SELECT count(*) AS n FROM vetra.outbox').first[:n]
          end
        end
        locked.pop(timeout: 10)
        result = Queue.new
        maintenance = Thread.new do
          result << begin
            @relay.maintain(ahead: 14, retention: 30)
          rescue StandardError => error
            error
          end
        end
        deadline = Time.now + 5
        waited = false
        until waited || Time.now > deadline
          waited = as_superuser("SELECT count(*) FROM pg_stat_activity WHERE usename = 'vetra_relay' AND wait_event_type = 'Lock'").first['count'] != '0'
          sleep 0.05
        end
        go << true
        worker.join(10)
        maintenance.join(15)
        summary = result.pop(timeout: 1)
        future = "deliveries_p#{(today + 14).strftime('%Y%m%d')}"
        waited && !copied.nil? && summary.is_a?(Hash) && summary['criadas'].include?(future)
      ensure
        go << true
        other.disconnect
      end
    end
  end

  def relay_denied(sql)
    @relay_db.run(sql)
    false
  rescue Sequel::DatabaseError => error
    error.wrapped_exception.respond_to?(:result) && error.wrapped_exception.result&.error_field(PG::PG_DIAG_SQLSTATE) == '42501'
  end

  def isolation_checks
    app_table = tenant? ? 'public.leads' : 'public.posts'
    check_case('o relay não lê a aplicação, as chaves nem as partições, e não grava na outbox') do
      day = today.strftime('%Y%m%d')
      ["SELECT 1 FROM #{app_table}", 'SELECT 1 FROM vetra_private.keys', "SELECT 1 FROM vetra.outbox_p#{day}",
       "SELECT 1 FROM vetra.deliveries_p#{day}", "DELETE FROM vetra.outbox", "UPDATE vetra.outbox SET cmd = 'x'",
       'DELETE FROM vetra.deliveries', 'DELETE FROM vetra.dead_deliveries', "INSERT INTO vetra.relay_checkpoints VALUES ('outro', '0')"]
        .all? { |sql| relay_denied(sql) }
    end
    check_case('a aplicação não executa a manutenção nem lê entregas e checkpoint') do
      ['SELECT vetra.outbox_maintain(3, 7)', 'SELECT 1 FROM vetra.deliveries', 'SELECT 1 FROM vetra.relay_checkpoints']
        .all? { |sql| denied_app(sql) }
    end
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    exit(RelayProbe.new(ENV.fetch('DATABASE_URL')).run ? 0 : 1)
  rescue StandardError => error
    warn "FALHA: sonda do relay interrompida (#{error.class})."
    exit 1
  end
end

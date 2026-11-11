#!/usr/bin/env ruby
# PostgreSQL 17/18 descartável. DATABASE_URL administrativa; bootstrap ADR-036/C15 já aplicado.
# VETRA_APP_PASSWORD e VETRA_RELAY_PASSWORD: logins reais dos papéis de produção, se necessários.
# Aplica os planos commitados do mini_crm como vetra_migrator; só as operações mudam na cópia temporária.
require_relative 'sonda_runner'
require_relative 'support/handlers_fixture'
require 'json'

class HandlersProbe < RunnerProbe
  include HandlersFixture
  HANDLERS = %w[crm.notify_sales crm.notify_again].freeze

  class Provider
    attr_reader :keys, :effects
    attr_accessor :failure
    def initialize
      @keys, @effects = [], {}
    end
    def deliver(_template, **kwargs)
      @keys << kwargs.fetch(:idempotency_key)
      raise failure if failure
      @effects[keys.last] ||= kwargs
    end
  end

  def run
    @admin = PG.connect(@url)
    @admin.exec('SET client_min_messages = warning')
    @admin.exec(Vetra::SQL::Context.role_guard)
    before = roles
    boot('mini_crm', true)
    with_handlers_fixture(command_body: '$c14_handler_pause&.call') do |linked|
      @linked = linked
      @catalog = Vetra::Data::Repositories.new(linked.document)
      @authority = Vetra::Execution::DatabaseAuthority.new(db: @edge_db)
      @runner = runner_for(edge_with(@authority))
      @relay_db = relay_pool
      @relay = Vetra::Data::Relay.new(@relay_db, document: linked.document)
      @provider = Provider.new
      seed
      fanout
      crash_and_recovery
      dead_and_purge
      isolation
      total_timeout
    end
    check('nenhum papel global mudou') { roles == before }
    puts "#{@results.count(true)}/#{@results.size} verificações passaram (PostgreSQL #{@admin.server_version})."
    @results.all?
  ensure
    $c14_handler_pause = nil
    @relay_db&.disconnect
    close_all
    if @admin
      @databases.reverse_each { |name| @admin.exec("DROP DATABASE IF EXISTS #{PG::Connection.quote_ident(name)} WITH (FORCE)") }
      @admin.close
    end
  end

  private

  def pool_params
    { adapter: :postgres, host: @admin.host, hostaddr: @admin.hostaddr, port: @admin.port, database: @database_name }
  end

  def relay_pool
    Vetra::Data::Relay.connect(pool_params.merge(password: ENV.fetch('VETRA_RELAY_PASSWORD', '')), max_connections: 1)
  end

  def worker(relay: @relay, runner: @runner, provider: @provider, **options)
    Vetra::Execution::HandlerRunner.new(linked: @linked, relay: relay, runner: runner,
                                       effects: { 'crm.mailer' => provider }, **options)
  end

  def rows(sql, params = []) = @connection.exec_params(sql, params).to_a
  def count(sql, params = []) = rows(sql, params).first.fetch('n').to_i
  def company_name(tenant = @tenant) = rows('SELECT name FROM public.companies WHERE id = $1', [tenant]).first.fetch('name')
  def events = count("SELECT count(*) AS n FROM vetra.outbox WHERE event = 'crm.company.touched'")
  def keys(event) = rows('SELECT key, principal, handler, origin, event_created_at::text AS stamp FROM vetra.idempotency WHERE event_id = $1 ORDER BY handler', [event])

  def seed
    @other_tenant, @foreign_lead = SecureRandom.uuid, SecureRandom.uuid
    migration do
      [@tenant, @other_tenant].each do |tenant|
        @connection.exec_params('INSERT INTO public.companies (id, name, created_at) VALUES ($1, $2, transaction_timestamp())', [tenant, 'Empresa'])
      end
      @connection.exec_params('INSERT INTO public.leads (id, company_id, name, status, created_at) VALUES ($1, $2, $3, $4, transaction_timestamp())',
                              [@foreign_lead, @other_tenant, 'Outro tenant', 'new'])
    end
    @identity = Vetra::Execution::Identity.new(tenant_id: @tenant, actor_id: @actor, roles: ['crm.gerente'])
  end

  # A emissão vem de um comando real pelo Runner, nunca de um INSERT administrativo na outbox.
  def emit
    lead = @runner.run('crm.create_lead', { name: 'Cliente da sonda' }, credentials: @identity)
    raise 'criação recusada' unless lead.ok?
    won = @runner.run('crm.win_lead', { lead_id: lead.value.id }, credentials: @identity)
    raise 'emissão recusada' unless won.ok?
    event = rows("SELECT event_id::text AS id FROM vetra.outbox WHERE event = 'crm.lead.won' AND payload->>'id' = $1", [lead.value.id]).first.fetch('id')
    @relay.relay!
    event
  end

  def fanout
    @first_event = emit
    check('Runner emite no tenant; relay entrega a dois handlers, cada comando escreve e emite uma vez, com chaves distintas') do
      before = events
      results = HANDLERS.map { |handler| worker.work(handler, limit: 1) }
      records = keys(@first_event)
      results.all? { |result| result[:done] == 1 } && company_name == 'Empresa++' && events == before + 2 &&
        records.size == 2 && records.map { |row| row['key'] }.uniq.size == 2 && records.all? do |row|
          row['origin'] == 'event' && row['principal'] == "system:#{row['handler']}" &&
            row['key'] == Vetra::Execution::HandlerRunner.event_key(row['handler'], @first_event) && @provider.keys.include?(row['key'])
        end
    end
    check('handler não segura transação do relay durante os efeitos; conexão de aplicação volta sem contexto') do
      count("SELECT count(*) AS n FROM pg_stat_activity WHERE datname = current_database() AND usename IN ('vetra_app', 'vetra_relay') " \
            "AND (backend_xid IS NOT NULL OR state LIKE 'idle in transaction%')").zero? && empty_context?
    end
  end

  def crash_and_recovery
    event = emit
    before_name, before_events = company_name, events
    reader, writer = IO.pipe
    # O filho abre pools novos: nenhuma conexão herdada do processo pai é usada pelo worker.
    pid = fork do
      begin
        reader.close
        provider = Provider.new
        app = Vetra::Data.connect(pool_params.merge(password: ENV.fetch('VETRA_APP_PASSWORD', '')), max_connections: 1)
        unit = Vetra::Data::UnitOfWork.new(app, issuer: @issuer)
        edge = Vetra::Execution::Edge.new(identity: ->(c) { c }, facts: ->(_) { raise 'fatos indevidos' }, authority: ->(_) { 0 })
        runner = Vetra::Execution::Runner.new(linked: @linked, catalog: @catalog, unit: unit, edge: edge)
        relay = Vetra::Data::Relay.new(relay_pool, document: @linked.document)
        relay.define_singleton_method(:complete) do |_delivery|
          writer.write(JSON.generate(provider.keys))
          writer.close
          Process.kill('KILL', Process.pid)
        end
        worker(relay: relay, runner: runner, provider: provider).work(HANDLERS.first, limit: 1)
      ensure
        # Nem uma falha de conexão pode alcançar o ensure administrativo do pai, com conexões herdadas.
        exit! 2
      end
    end
    writer.close
    # Espera limitada: uma falha do filho não deixa a sonda presa num pipe ou waitpid.
    child_keys, status = Timeout.timeout(15) do
      data = JSON.parse(reader.read)
      _, child_status = Process.wait2(pid)
      [data, child_status]
    end
    pid = nil
    check('worker morto por SIGKILL depois do commit e antes de complete deixa comando, evento e chave confirmados') do
      status.signaled? && status.termsig == Signal.list.fetch('KILL') && keys(event).size == 1 &&
        company_name == "#{before_name}+" && events == before_events + 1 && child_keys == [keys(event).first['key']]
    end
    check('chave vencida continua retida enquanto a entrega está pendente, inclusive depois da queda') do
      age(event)
      @relay.purge_idempotency
      keys(event).size == 1
    end
    check('outro worker só reserva após vencer a lease, e o replay não repete a escrita nem a emissão') do
      held = worker.work(HANDLERS.first, limit: 1)[:done].zero?
      rows("UPDATE vetra.deliveries SET leased_until = statement_timestamp() - interval '1 second' WHERE event_id = $1 AND handler = $2", [event, HANDLERS.first])
      result = worker.work(HANDLERS.first, limit: 1)
      after_replay = company_name == "#{before_name}+" && events == before_events + 1 && @provider.keys.last == child_keys.first
      second = worker.work(HANDLERS.last, limit: 1)
      held && result[:done] == 1 && after_replay && second[:done] == 1 && company_name == "#{before_name}++" && keys(event).size == 2
    end
  ensure
    reader&.close unless reader&.closed?
    writer&.close unless writer&.closed?
    if pid
      Process.kill('KILL', pid) rescue Errno::ESRCH
      Process.wait(pid) rescue Errno::ECHILD
    end
  end

  def age(event)
    rows("UPDATE vetra.idempotency SET created_at = statement_timestamp() - interval '2 days' WHERE event_id = $1", [event])
  end

  def dead_and_purge
    event = emit
    @provider.failure = Vetra::Data::Relay::PermanentFailure.new
    check('falha permanente depois do comando leva a dead; a chave fica retida também na cópia não particionada') do
      results = HANDLERS.map { |handler| worker.work(handler, limit: 1) }
      age(event)
      @relay.purge_idempotency
      kept = keys(event).size == 2
      # Administração da fixture simula o descarte da partição, preservando a cópia dead (não reprocessa a entrega).
      rows('DELETE FROM vetra.deliveries WHERE event_id = $1', [event])
      @relay.purge_idempotency
      results.all? { |result| result[:dead] == 1 } && kept && keys(event).size == 2 &&
        count('SELECT count(*) AS n FROM vetra.dead_deliveries WHERE event_id = $1', [event]) == 2
    end
    check('vetra_relay só purga a chave derivada vencida depois que a última entrega some') do
      rows('DELETE FROM vetra.dead_deliveries WHERE event_id = $1', [event])
      purged = @relay.purge_idempotency
      purged['event'] == 2 && keys(event).empty?
    end
  ensure
    @provider.failure = nil
  end

  def isolation
    event = emit
    # Corrupção administrativa controlada: o handler recebe referência a um lead de outro tenant. A identidade
    # continua vindo do tenant da entrega; nem o repositório nem o RLS devem aceitar essa referência.
    rows('UPDATE vetra.outbox SET payload = jsonb_build_object(\'id\', $1::text) WHERE event_id = $2', [@foreign_lead, event])
    before = company_name
    check('ator de sistema do tenant do evento não alcança registro de outro tenant, nem escreve nem emite') do
      previous = events
      results = HANDLERS.map { |handler| worker.work(handler, limit: 1) }
      results.all? { |result| result[:dead] == 1 } && company_name == before && company_name(@other_tenant) == 'Empresa' &&
        events == previous && keys(event).empty?
    end
  end

  def total_timeout
    event = emit
    before, previous = company_name, events
    $c14_handler_pause = -> { sleep 0.5 }
    check('timeout total interrompe comando depois da escrita, desfaz unidade/claim/evento e mantém lease, sem transação aberta') do
      result = worker(timeout: 0.2, lease: 1).work(HANDLERS.first, limit: 1)
      entry = rows('SELECT attempts, leased_until > statement_timestamp() AS leased FROM vetra.deliveries WHERE event_id = $1 AND handler = $2', [event, HANDLERS.first]).first
      result[:retry] == 1 && entry['attempts'] == '1' && entry['leased'] == 't' && company_name == before &&
        events == previous && keys(event).empty? && empty_context? &&
        count("SELECT count(*) AS n FROM pg_stat_activity WHERE datname = current_database() AND usename = 'vetra_app' AND state LIKE 'idle in transaction%'").zero?
    end
    $c14_handler_pause = nil
    check('outro worker recupera timeout após lease e espera crescente, sem deixar unidade anterior aberta') do
      held = worker.work(HANDLERS.first, limit: 1)[:done].zero?
      rows("UPDATE vetra.deliveries SET leased_until = statement_timestamp() - interval '1 second', run_after = statement_timestamp() WHERE event_id = $1 AND handler = $2", [event, HANDLERS.first])
      result = worker.work(HANDLERS.first, limit: 1)
      held && result[:done] == 1 && company_name == "#{before}+" && events == previous + 1 && keys(event).size == 1 && empty_context?
    end
  ensure
    $c14_handler_pause = nil
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    exit(HandlersProbe.new(ENV.fetch('DATABASE_URL')).run ? 0 : 1)
  rescue StandardError => error
    warn "FALHA: sonda dos handlers interrompida (#{error.class})."
    exit 1
  end
end

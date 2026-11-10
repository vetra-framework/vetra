#!/usr/bin/env ruby
# PostgreSQL 17/18 descartável; DATABASE_URL administrativa, bootstrap ADR-036/040 pronto.
# VETRA_APP_PASSWORD / VETRA_RELAY_PASSWORD: senhas dos logins reais, se necessárias.
# Planos integrados do blog e mini CRM como vetra_migrator; operações como vetra_app; relay como vetra_relay.
# Só muda parâmetros de vetra_app IN DATABASE no banco efêmero desta sonda, e os restaura no ensure.
require_relative 'sonda_vetra_data'

class UnitLimitsProbe < VetraDataProbe
  def run
    @admin = PG.connect(@url)
    @admin.exec('SET client_min_messages = warning')
    @admin.exec(Vetra::SQL::Context.role_guard)
    @admin.exec(Vetra::SQL::Context.relay_guard)
    before = roles
    settings_before = role_settings
    @example = 'blog'
    prepare_example(@example)
    root = File.expand_path('../examples/blog', __dir__)
    @document = Vetra::Graph::Compiler.new(root: root).read_artifact.document
    @catalog = Vetra::Data::Repositories.new(@document)
    verifier_checks
    role_limits(transaction: 30_000, idle: 10_000)
    connect_runtime
    @relay_db = Vetra::Data::Relay.connect(runtime_options('VETRA_RELAY_PASSWORD'), max_connections: 1)
    @relay = Vetra::Data::Relay.new(@relay_db, document: @document)
    @relay.maintain
    @target = operation { |unit| posts(unit).create!(title: 'Alvo de lock') }
    operation_limits_checks
    serialization_check
    measure_verifier
    reset_role_limits
    @runtime.disconnect
    @relay_db.disconnect
    @connection.close
    @example = 'mini_crm'
    prepare_example(@example)
    @document = Vetra::Graph::Compiler.new(root: File.expand_path('../examples/mini_crm', __dir__)).read_artifact.document
    @catalog = Vetra::Data::Repositories.new(@document)
    provision('runtime', @secret)
    @issuer = Vetra::Data::ContextIssuer.new(kid: 'runtime', secret: @secret)
    role_limits(transaction: 30_000, idle: 10_000)
    connect_runtime
    @other_tenant = SecureRandom.uuid
    [@tenant, @other_tenant].each do |tenant|
      operation(tenant_id: tenant) { |unit| @catalog.bind('crm.companies', unit: unit).create!(name: 'Empresa da sonda') }
    end
    @relay_db = Vetra::Data::Relay.connect(runtime_options('VETRA_RELAY_PASSWORD'), max_connections: 1)
    @relay = Vetra::Data::Relay.new(@relay_db, document: @document)
    @relay.maintain
    server_timeout_check(:transaction)
    server_timeout_check(:idle)
    check('parâmetros operacionais restaurados e nenhum papel global mudou') do
      reset_role_limits
      @runtime&.disconnect
      @relay_db&.disconnect
      @connection&.close
      @runtime = @relay_db = @connection = nil
      @databases.each { |name| @admin.exec("DROP DATABASE #{PG::Connection.quote_ident(name)} WITH (FORCE)") }
      @database_name = nil
      @databases.clear
      roles == before && role_settings == settings_before
    end
    puts "#{@results.count(true)}/#{@results.size} verificações passaram (PostgreSQL #{@admin.server_version})."
    @results.all?
  ensure
    @runtime&.disconnect
    @relay_db&.disconnect
    @other&.disconnect
    reset_role_limits if @admin && @database_name
    @connection&.close
    if @admin
      @databases.reverse_each { |name| @admin.exec("DROP DATABASE IF EXISTS #{PG::Connection.quote_ident(name)} WITH (FORCE)") }
      @admin.close
    end
  end

  private

  def role_settings
    @admin.exec('SELECT setdatabase, setrole, setconfig::text FROM pg_db_role_setting ORDER BY setdatabase, setrole').to_a
  end

  def reset_role_limits
    @admin.exec("ALTER ROLE vetra_app IN DATABASE #{PG::Connection.quote_ident(@database_name)} RESET ALL")
  end

  def role_limits(transaction:, idle:)
    # Nomes são constantes e valores inteiros de teste; só o nome aleatório do banco precisa de quote_ident.
    database = PG::Connection.quote_ident(@database_name)
    @admin.exec("ALTER ROLE vetra_app IN DATABASE #{database} SET transaction_timeout = '#{Integer(transaction)}ms'")
    @admin.exec("ALTER ROLE vetra_app IN DATABASE #{database} SET idle_in_transaction_session_timeout = '#{Integer(idle)}ms'")
  end

  def runtime_options(password = 'VETRA_APP_PASSWORD')
    { adapter: :postgres, host: @admin.host, hostaddr: @admin.hostaddr, port: @admin.port,
      database: @database_name, password: ENV.fetch(password, '') }
  end

  def new_runtime
    Vetra::Data.connect(runtime_options, max_connections: 1)
  end

  def connect_runtime
    @runtime&.disconnect
    @runtime = new_runtime
    @work = new_work(@runtime)
  end

  def new_work(db)
    @example == 'mini_crm' ? Vetra::Data::UnitOfWork.new(db, issuer: @issuer) : Vetra::Data::UnitOfWork.new(db, scope: :global)
  end

  def operation(work = @work, **options, &block)
    claims = { op_id: SecureRandom.uuid, actor_id: @actor, cmd: @example == 'mini_crm' ? 'crm.win_lead' : 'blog.publish_post' }
    claims[:tenant_id] = @tenant if @example == 'mini_crm'
    work.transaction(**claims.merge(options), &block)
  end

  def posts(unit)
    @catalog.bind('blog.posts', unit: unit)
  end

  def post_exists?(id)
    # Identificador vem apenas dos dois exemplos fixos desta sonda.
    table = @example == 'mini_crm' ? 'leads' : 'posts'
    @connection.exec_params("SELECT EXISTS (SELECT 1 FROM public.#{table} WHERE id = $1)", [id]).getvalue(0, 0) == 't'
  end

  def event_exists?(id)
    @connection.exec_params('SELECT EXISTS (SELECT 1 FROM vetra.outbox WHERE event_id = $1)', [id]).getvalue(0, 0) == 't'
  end

  def sanitized?(error)
    error.is_a?(Vetra::Data::Error) && error.cause.nil? && !error.full_message.match?(/SELECT|INSERT|UPDATE|Alvo de lock/)
  end

  def verifier_checks
    [[0, 0], [30_000, 0], [0, 10_000], [30_001, 10_000], [30_000, 10_001]].each do |transaction, idle|
      check("verificador recusa parâmetros efetivos #{transaction}/#{idle} ms antes do corpo") do
        role_limits(transaction: transaction, idle: idle)
        connect_runtime # ALTER ROLE só vale para novo login, não para SET ROLE.
        called = false
        refused = data_error('data_limits') { operation { called = true } }
        refused && !called && !@runtime.in_transaction?
      end
    end
    check('verificador aceita os dois parâmetros do papel em login real vetra_app') do
      role_limits(transaction: 30_000, idle: 10_000)
      connect_runtime
      operation do |unit|
        unit.access(multi_tenant: false) do |db|
          db.get(Sequel.lit("current_user = 'vetra_app' AND session_user = 'vetra_app'"))
        end
      end
    end
  end

  def operation_limits_checks
    @other = new_runtime
    other_work = Vetra::Data::UnitOfWork.new(@other, scope: :global)
    [[:lock, { lock_timeout: 120, statement_timeout: 2000 }],
     [:statement, { lock_timeout: 2000, statement_timeout: 120 }]].each do |kind, options|
      check("#{kind}_timeout: erro retentável, rollback externo mesmo com savepoint resgatado, sem linha nem evento") do
        previous_timeouts = operation_timeouts
        marker = SecureRandom.uuid
        emitted = nil
        caught = nil
        outer = nil
        operation(other_work) do |blocker|
          posts(blocker).lock!(@target.id)
          begin
            operation(**options) do |unit|
              record = posts(unit).create!(id: marker, title: 'Será desfeito')
              record = posts(unit).update!(record, status: 'published', published_at: unit.now)
              emitted = @catalog.emit!(unit, record).first
              begin
                unit.compose { posts(unit).lock!(@target.id) }
              rescue Vetra::Data::Error => error
                caught = error
              end
            end
          rescue Vetra::Data::Error => error
            outer = error
          end
        end
        correct = kind == :lock ? caught.is_a?(Vetra::Data::Conflict) && caught.kind == :lock_timeout && caught.code == 'data_lock_timeout' :
                                 caught.is_a?(Vetra::Data::StatementTimeout) && caught.code == 'data_statement_timeout'
        correct && caught.equal?(outer) && caught.retryable? && sanitized?(caught) &&
          !post_exists?(marker) && emitted && !event_exists?(emitted) && operation_timeouts == previous_timeouts
      end
    end
  ensure
    @other&.disconnect
    @other = nil
  end

  def operation_timeouts
    @runtime.select(Sequel.function(:current_setting, 'lock_timeout').as(:lock),
                    Sequel.function(:current_setting, 'statement_timeout').as(:statement)).first
  end

  def serialization_check
    check('READ COMMITTED por padrão; SERIALIZABLE por opção; 40001 tem tipo próprio e não repete nem deixa linha') do
      default = operation { |unit| unit.access(multi_tenant: false) { |db| db.get(Sequel.function(:current_setting, 'transaction_isolation')) } }
      @other = new_runtime
      other_work = Vetra::Data::UnitOfWork.new(@other, scope: :global)
      marker = SecureRandom.uuid
      attempts = 0
      selected = nil
      caught = nil
      begin
        operation(isolation: :serializable) do |unit|
          attempts += 1
          selected = unit.access(multi_tenant: false) { |db| db.get(Sequel.function(:current_setting, 'transaction_isolation')) }
          posts(unit).find!(@target.id) # fixa o snapshot antes da escrita concorrente.
          posts(unit).create!(id: marker, title: 'Será desfeito por serialização')
          operation(other_work) { |other| posts(other).update!(@target.id, title: 'Concorrente confirmou') }
          posts(unit).update!(@target.id, title: 'Snapshot obsoleto')
        end
      rescue Vetra::Data::Error => error
        caught = error
      end
      persisted = operation { |unit| posts(unit).find!(@target.id) }
      default == 'read committed' && selected == 'serializable' && attempts == 1 &&
        caught.is_a?(Vetra::Data::SerializationFailure) && caught.kind == :serialization && caught.retryable? &&
        caught.code == 'data_serialization' && sanitized?(caught) && !post_exists?(marker) && persisted.title == 'Concorrente confirmou'
    ensure
      @other&.disconnect
      @other = nil
    end
  end

  def xmin
    @connection.exec('SELECT pg_snapshot_xmin(pg_current_snapshot())::text').getvalue(0, 0).to_i
  end

  def backend_active?(pid)
    @connection.exec_params('SELECT EXISTS (SELECT 1 FROM pg_stat_activity WHERE pid = $1)', [pid]).getvalue(0, 0) == 't'
  end

  def server_timeout_check(kind)
    check("#{kind}_timeout: servidor encerra backend escritor, libera xmin e relay entrega o evento posterior") do
      # Limites curtos só neste banco descartável. transaction mantém consulta ativa; idle não envia consultas.
      role_limits(transaction: kind == :transaction ? 3000 : 10_000, idle: kind == :idle ? 3000 : 10_000)
      @other = new_runtime
      work = new_work(@other)
      ready, release, result = Queue.new, Queue.new, Queue.new
      marker = SecureRandom.uuid
      thread = Thread.new do
        Thread.current.report_on_exception = false
        begin
          operation(work, tenant_id: @other_tenant, statement_timeout: 0) do |unit|
            @catalog.bind('crm.leads', unit: unit).create!(id: marker, name: 'Escritor encerrado pelo servidor')
            data = unit.access(multi_tenant: true) do |db|
              [db.get(Sequel.function(:pg_backend_pid)), db.get(Sequel.function(:pg_current_xact_id)).to_i]
            end
            ready << data
            release.pop(timeout: 15) || raise('A sonda não liberou o escritor')
            if kind == :transaction
              # pg_sleep é cancelado pela morte da sessão, não por statement_timeout (explicitamente zero).
              unit.access(multi_tenant: false) { |db| db.get(Sequel.function(:pg_sleep, 15)) }
            else
              unit.access(multi_tenant: false) { |db| db.get(1) }
            end
          end
          result << :unexpected_commit
        rescue Vetra::Data::Error, Sequel::DatabaseError => error
          result << error.class # não conserva nem imprime mensagem/SQL do driver.
        rescue StandardError => error
          result << error.class
        end
      end
      pid, xid = ready.pop(timeout: 10) || raise('Escritor não abriu')
      held_xmin = xmin
      @relay.relay! # limpa faixas antigas até o escritor aberto.
      later_id = operation do |unit|
        leads = @catalog.bind('crm.leads', unit: unit)
        record = leads.create!(name: 'Evento atrás do escritor')
        won = leads.update!(record, status: 'won')
        @catalog.emit!(unit, won).first
      end
      stopped = @relay.relay!.zero?
      absent = @connection.exec_params('SELECT count(*) FROM vetra.deliveries WHERE event_id = $1', [later_id]).getvalue(0, 0) == '0'
      if kind == :transaction
        release << true
      end
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 12
      sleep(0.02) while backend_active?(pid) && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
      terminated = !backend_active?(pid) # antes de liberar idle: só o servidor pode ter encerrado a sessão.
      advanced = xmin > xid
      release << true if kind == :idle
      joined = thread.join(5)
      outcome = result.pop(timeout: 1) if joined
      read = @relay.relay!
      delivered = @connection.exec_params('SELECT count(*) FROM vetra.deliveries WHERE event_id = $1', [later_id]).getvalue(0, 0).to_i
      handlers = Vetra::Data::Relay.handlers(@document).fetch('crm.lead.won').size
      consumed = []
      Vetra::Data::Relay.handlers(@document).fetch('crm.lead.won').each do |handler|
        @relay.work(handler) { |delivery| consumed << delivery.event_id }
      end
      held_xmin <= xid && stopped && absent && terminated && advanced && joined && outcome.is_a?(Class) &&
        !post_exists?(marker) && read == 1 && handlers.positive? && delivered == handlers &&
        consumed.count(later_id) == handlers && @relay.relay!.zero?
    ensure
      release << true if release
      if thread&.alive?
        # Limpeza após falha; nunca conta como prova de encerramento pelo servidor.
        @connection.exec_params('SELECT pg_terminate_backend($1)', [pid]) if pid
        thread.join(5)
        thread.kill if thread.alive?
        thread.join
      end
      @other&.disconnect
      @other = nil
    end
  end

  def measure_verifier
    check('medição: uma leitura conjunta por transação, zero leituras nos acessos e savepoints') do
      counter = Module.new do
        attr_reader :limits_reads
        def execute(sql, opts = Sequel::OPTS, &block)
          @limits_reads = limits_reads.to_i + 1 if sql.include?('current_setting')
          super
        end
      end
      @runtime.extend(counter)
      samples = { verified: [], disabled: [] }
      disabled = Vetra::Data::UnitOfWork.new(@runtime, scope: :global, limits: false)
      count_before = @runtime.limits_reads.to_i
      3.times do
        { verified: @work, disabled: disabled }.each do |name, work|
          started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          100.times { operation(work) { |unit| unit.compose { posts(unit).find!(@target.id) } } }
          samples[name] << (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 10 # ms por operação.
        end
      end
      reads = @runtime.limits_reads.to_i - count_before
      verified = samples[:verified].sort[1]
      plain = samples[:disabled].sort[1]
      puts format('Verificador: mediana %.3f ms/op com, %.3f ms/op sem, diferença %.3f ms/op; %d leituras/300 operações verificadas.',
                  verified, plain, verified - plain, reads)
      reads == 300
    end
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    exit(UnitLimitsProbe.new(ENV.fetch('DATABASE_URL')).run ? 0 : 1)
  rescue StandardError => error
    warn "Sonda interrompida (#{error.class}); detalhes do driver omitidos."
    exit 1
  end
end

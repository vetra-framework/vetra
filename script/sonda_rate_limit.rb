#!/usr/bin/env ruby
# PostgreSQL 17/18 descartável, bootstrap ADR-036/C15 pronto; DATABASE_URL administrativa.
# VETRA_APP_PASSWORD e VETRA_RELAY_PASSWORD: senhas dos logins reais; VETRA_PG_DUMP da versão do servidor.
# Aplica os planos do blog como vetra_migrator; reservas como vetra_app, purga como vetra_relay.
# Os limites curtos são envelopes da borda confiável da sonda; nenhum grafo ou papel é alterado.
require_relative 'sonda_idempotencia'
require_relative '../lib/vetra/execution'

class RateLimitProbe < IdempotencyProbe
  def run
    @admin = PG.connect(@url)
    @admin.exec('SET client_min_messages = warning')
    @admin.exec(Vetra::SQL::Context.role_guard)
    before = roles
    @example = 'blog'
    @root = File.expand_path('../examples/blog', __dir__)
    @linked = Vetra::Graph::Compiler.new(root: @root).link
    @connection = create_database
    @database_name = @databases.last
    check_case('planos do blog aplicados por vetra_migrator, inclusive tabela e função de reserva') do
      migrate.status == :applied && as_superuser("SELECT to_regclass('vetra.rate_limit')::text AS name").first['name'] == 'vetra.rate_limit'
    end
    provision('runtime', @secret)
    @issuer = Vetra::Data::ContextIssuer.new(kid: 'runtime', secret: @secret, clock: -> { now })
    @runtime = app_pool(32)
    @limiter = Vetra::Data::RateLimit.new(db: @runtime, issuer: @issuer, document: @linked.document)
    open_relay
    sliding_checks
    concurrency_checks
    joint_checks
    identity_checks
    runner_checks
    privilege_checks
    purge_checks
    failure_checks
    check_case('nenhum statement nomeado no runtime nem no relay') do
      @runtime[:pg_prepared_statements].count.zero? && @relay_db[:pg_prepared_statements].count.zero?
    end
    check('nenhum papel global mudou') { roles == before }
    puts "#{@results.count(true)}/#{@results.size} verificações passaram (PostgreSQL #{@admin.server_version})."
    @results.all?
  ensure
    @operation_db&.disconnect
    close_relay
    close_runtime
    if @admin
      @databases.reverse_each { |name| @admin.exec("DROP DATABASE IF EXISTS #{PG::Connection.quote_ident(name)} WITH (FORCE)") }
      @admin.close
    end
  end

  private

  def app_pool(size)
    Vetra::Data.connect({ adapter: :postgres, host: @admin.host, hostaddr: @admin.hostaddr, port: @admin.port,
                          database: @database_name, password: ENV.fetch('VETRA_APP_PASSWORD', '') }, max_connections: size, pool_timeout: 5)
  end

  def policy(id, limit = 3, window = 60)
    { 'id' => "sonda.#{id}", 'limit' => limit, 'window_seconds' => window }
  end

  def context(actor: @actor, tenant: nil)
    Vetra::Data::Context.new(scope: tenant ? :tenant : :global, tenant_id: tenant, actor_id: actor,
                             op_id: SecureRandom.uuid, cmd: 'blog.create_comment')
  end

  def reserve(policies, **identity)
    @limiter.call(context(**identity), Array(policies))
  end

  def total(id, actor: nil)
    sql = 'SELECT count(*) AS n FROM vetra.rate_limit WHERE policy_id = $1'
    params = ["sonda.#{id}"]
    if actor
      sql += ' AND actor_id = $2::uuid'
      params << actor
    end
    as_superuser(sql, params).first['n'].to_i
  end

  def sliding_checks
    short = policy('sliding', 3, 2)
    check_case('janela móvel: três admissões, quarta recusada com espera mínima 1, sem linha na recusa') do
      admitted = Array.new(3) { reserve([short]) }
      wait = reserve([short])
      admitted == [0, 0, 0] && wait.between?(1, 2) && total('sliding') == 3
    end
    check_case('depois da janela do relógio do banco, volta a admitir') do
      @connection.exec('SELECT pg_sleep(2.1)')
      reserve([short]).zero? && total('sliding') == 4
    end
    check_case('janela móvel conserva a admissão recente enquanto a antiga vence (sem balde fixo)') do
      staggered = policy('staggered', 2, 2)
      first = reserve([staggered])
      @connection.exec('SELECT pg_sleep(1.1)')
      second = reserve([staggered])
      blocked = reserve([staggered])
      @connection.exec('SELECT pg_sleep(1.05)')
      third = reserve([staggered])
      fourth = reserve([staggered])
      [first, second, third] == [0, 0, 0] && blocked.positive? && fourth.positive? && total('staggered') == 3
    end
  end

  def concurrent_reservations
    # Abre as conexões antes da barreira; cada thread mantém sua conexão até concluir a reserva.
    ready, start = Queue.new, Queue.new
    threads = Array.new(32) do |index|
      Thread.new do
        @runtime.synchronize do
          ready << true
          start.pop
          # Sem compartilhar a conexão administrativa entre threads.
          issuer = Vetra::Data::ContextIssuer.new(kid: 'runtime', secret: @secret)
          limiter = Vetra::Data::RateLimit.new(db: @runtime, issuer: issuer, document: @linked.document)
          limiter.call(context, yield(index))
        end
      end
    end
    begin
      32.times { raise 'Conexão não chegou à barreira' unless ready.pop(timeout: 15) }
      32.times { start << true }
      threads.map(&:value)
    ensure
      threads.each { |thread| thread.kill if thread.alive? }
      threads.each(&:join)
    end
  end

  def concurrency_checks
    check_case('32 conexões simultâneas nunca ultrapassam cinco admissões') do
      concurrent = policy('concurrent', 5)
      results = concurrent_reservations { |_index| [concurrent] }
      results.count(0) == 5 && results.count { |wait| wait.positive? } == 27 && total('concurrent') == 5
    end
    check_case('32 reservas conjuntas em ordens opostas não ultrapassam a menor cota nem consomem parcialmente') do
      a, b = policy('concurrent_a', 5), policy('concurrent_b', 2)
      results = concurrent_reservations { |index| index.even? ? [a, b] : [b, a] }
      results.count(0) == 2 && results.count { |wait| wait.positive? } == 30 && total('concurrent_a') == 2 && total('concurrent_b') == 2
    end
  end

  def joint_checks
    check_case('uma política cheia recusa conjuntamente sem consumir a outra, nas duas ordens') do
      a, b = policy('joint_a', 1), policy('joint_b', 4)
      reserve([a]).zero? && reserve([a, b]).positive? && reserve([b, a]).positive? && total('joint_a') == 1 && total('joint_b').zero?
    end
    check_case('políticas distintas e janelas distintas consomem seus próprios contadores') do
      a, b = policy('window_a', 1, 1), policy('window_b', 2, 60)
      first = reserve([a, b])
      @connection.exec('SELECT pg_sleep(1.1)')
      second = reserve([a, b])
      first.zero? && second.zero? && reserve([a, b]).positive? && total('window_a') == 2 && total('window_b') == 2
    end
    check_case('reduzir o limite espera vencer admissões suficientes, sem usar só a mais antiga') do
      many = policy('lowered', 3, 60)
      3.times { reserve([many]) }
      reserve([policy('lowered', 1, 60)]).positive? && total('lowered') == 3
    end
  end

  def identity_checks
    check_case('tenants distintos e ausência de tenant têm contadores separados para o mesmo ator') do
      p = policy('tenants', 1)
      a, b = SecureRandom.uuid, SecureRandom.uuid
      [reserve([p], tenant: a), reserve([p], tenant: b), reserve([p])].all?(&:zero?) &&
        [reserve([p], tenant: a), reserve([p], tenant: b), reserve([p])].all?(&:positive?) && total('tenants') == 3
    end
    check_case('dois visitantes estáveis não dividem a cota; sem ator não há reserva') do
      issuer = Vetra::Execution::AnonymousIssuer.new(secret: @secret)
      # O emissor público deriva UUID v8; a cota usa esse ator do contexto confiável.
      first, second = issuer.verify(issuer.issue), issuer.verify(issuer.issue)
      p = policy('actors', 1)
      reserve([p], actor: first).zero? && reserve([p], actor: second).zero? && reserve([p], actor: first).positive? &&
        capture(Vetra::Data::Error) { reserve([p], actor: nil) }&.code == 'data_authorization_context' && total('actors') == 2
    end
    check_case('namespace também separa a cota com mesmo tenant, ator e ID de política') do
      p = policy('namespace', 1)
      first = reserve([p])
      token = @issuer.issue_rate_limit(context: context, namespace: 'outra-aplicacao', policies: [p])
      other = @runtime.get(Sequel.function(Sequel[:vetra][:reserve_rate_limit], token.value))
      first.zero? && other.zero? && reserve([p]).positive? && total('namespace') == 2
    end
  end

  def runner_checks
    @operation_db = app_pool(1)
    catalog = Vetra::Data::Repositories.new(@linked.document)
    authority = Vetra::Execution::InProcessAuthority.new
    facts = ->(request) { request.authorization.snapshot(context: request.context, roles: request.roles,
                                                         revision: authority.call, records: {}) }
    edge = Vetra::Execution::Edge.new(identity: ->(identity) { identity }, facts: facts, authority: authority, rate_limit: @limiter)
    runner = Vetra::Execution::Runner.new(linked: @linked, catalog: catalog, edge: edge,
                                         unit: Vetra::Data::UnitOfWork.new(@operation_db, scope: :global))
    identity = Vetra::Execution::Identity.new(actor_id: SecureRandom.uuid)
    before = as_superuser('SELECT count(*) AS n FROM vetra.rate_limit').first['n'].to_i
    check_case('falha da operação depois da admissão não devolve a cota') do
      # FK inexistente: a reserva confirma, a operação abre a sua transação e desfaz.
      result = runner.run('blog.create_comment', { post_id: SecureRandom.uuid, author_name: 'Visitante',
                                                  author_email: 'v@probe.invalid', body: 'Falha por FK' }, credentials: identity)
      result.status == :conflict && as_superuser('SELECT count(*) AS n FROM vetra.rate_limit').first['n'].to_i == before + 1
    end
    check_case('o visitante do blog comenta com reserva configurada; a sexta admissão é 429') do
      post = SecureRandom.uuid
      as_superuser("INSERT INTO public.posts (id, author_id, title, created_at) VALUES ($1, $2, 'Post', clock_timestamp())", [post, @actor])
      input = { post_id: post, author_name: 'Visitante', author_email: 'v@probe.invalid', body: 'Olá' }
      visitor = Vetra::Execution::Identity.new(actor_id: SecureRandom.uuid)
      outcomes = Array.new(6) { runner.run('blog.create_comment', input, credentials: visitor) }
      outcomes.first(5).all?(&:ok?) && outcomes.last.status == :rate_limited && outcomes.last.retry_after >= 1 &&
        as_superuser('SELECT count(*) AS n FROM public.comments WHERE post_id = $1', [post]).first['n'].to_i == 5
    end
  end

  def privilege_checks
    check_case('aplicação não lê, insere, altera, apaga ou esvazia admissões nem define o carimbo') do
      ['SELECT * FROM vetra.rate_limit', 'DELETE FROM vetra.rate_limit', 'TRUNCATE vetra.rate_limit',
       'UPDATE vetra.rate_limit SET admitted_at = clock_timestamp()',
       "INSERT INTO vetra.rate_limit (namespace, policy_id, actor_id, admitted_at) VALUES ('falso', 'falso', gen_random_uuid(), clock_timestamp())"].all? do |sql|
        capture(Sequel::DatabaseError) { @runtime.run(sql) }&.wrapped_exception&.result&.error_field(PG::PG_DIAG_SQLSTATE) == '42501'
      end
    end
    check_case('envelope adulterado, token v1 e ausência de assinatura não reservam nem revelam cota') do
      token = @issuer.issue_rate_limit(context: context, namespace: 'blog', policies: [policy('forgery')]).value
      altered = token.dup
      altered[-1] = altered[-1] == 'A' ? 'B' : 'A'
      ordinary = @issuer.issue(tenant_id: @tenant, actor_id: @actor, op_id: SecureRandom.uuid, cmd: 'blog.create_comment').value
      [altered, ordinary, 'r1.falso.payload.mac'].all? do |value|
        @runtime.get(Sequel.function(Sequel[:vetra][:reserve_rate_limit], value)).nil?
      end && total('forgery').zero?
    end
    check_case('guarda de rotinas recusa corpo e atributo adulterados, e confere a assinatura exata') do
      guard = Vetra::SQL::RateLimit.new(Vetra::SQL::Schema.new(@linked.document).generate).statements.last
      signature = 'vetra.reserve_rate_limit(text)'
      @connection.exec("ALTER FUNCTION #{signature} STABLE")
      refused = pg_state('P0001') { @connection.exec(guard) }
      @connection.exec("ALTER FUNCTION #{signature} VOLATILE")
      definition = @connection.exec("SELECT pg_get_functiondef('vetra.reserve_rate_limit(text)'::regprocedure)").getvalue(0, 0)
      begin
        raise 'Corpo esperado ausente' unless definition.include?('RETURN 0;')
        @connection.exec(definition.sub('RETURN 0;', 'RETURN 1;'))
        refused_body = pg_state('P0001') { @connection.exec(guard) }
      ensure
        @connection.exec(definition)
      end
      refused && refused_body && @connection.exec(guard).cmd_status == 'DO'
    end
  end

  def purge_checks
    check_case('só a manutenção purga; usa a maior janela e conserva as admissões recentes') do
      p = policy('purge', 3)
      reserve([p])
      reserve([p])
      as_superuser("UPDATE vetra.rate_limit SET admitted_at = clock_timestamp() - interval '61 seconds' " \
                   "WHERE id = (SELECT min(id) FROM vetra.rate_limit WHERE policy_id = 'sonda.purge')")
      deleted = @relay.purge_rate_limit(batch: 2)
      deleted >= 1 && total('purge') == 1 &&
        !capture(Sequel::DatabaseError) { @relay_db.run("INSERT INTO vetra.rate_limit (namespace, policy_id, actor_id) VALUES ('x', 'x', gen_random_uuid())") }.nil? &&
        !capture(Sequel::DatabaseError) { @relay_db.get(Sequel.function(Sequel[:vetra][:reserve_rate_limit], 'inválido')) }.nil?
    end
  end

  def failure_checks
    check_case('espera de trava excede timeout e falha fechada, sem admissão parcial') do
      locked = policy('timeout', 1)
      holder = PG.connect(connection_params(@database_name))
      begin
        holder.exec('BEGIN')
        holder.exec_params('SELECT pg_advisory_xact_lock(hashtextextended(jsonb_build_array($1::text, $2::text, NULL::uuid, $3::uuid)::text, 0))',
                           ['blog', locked['id'], @actor])
        error = capture(Vetra::Data::Error) { reserve([locked, policy('timeout_other')]) }
        error&.code == 'data_rate_limit_unavailable' && total('timeout').zero? && total('timeout_other').zero?
      ensure
        holder.exec('ROLLBACK')
        holder.close
      end
    end
    check_case('perda do acesso à tabela é indisponibilidade e nunca admissão') do
      # FORCE RLS vale também para o dono da função; uma política indisponível nunca admite.
      @connection.exec('ALTER POLICY vt_rate_limit_owner ON vetra.rate_limit USING (false) WITH CHECK (false)')
      begin
        error = capture(Vetra::Data::Error) { reserve([policy('offline')]) }
        error&.code == 'data_rate_limit_unavailable'
      ensure
        @connection.exec('ALTER POLICY vt_rate_limit_owner ON vetra.rate_limit USING (true) WITH CHECK (true)')
      end
    end
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    exit(RateLimitProbe.new(ENV.fetch('DATABASE_URL')).run ? 0 : 1)
  rescue StandardError => error
    warn "FALHA: sonda do limite de taxa interrompida (#{error.class})."
    warn error.backtrace.first(8).join("\n") if ENV['VETRA_SONDA_DEBUG']
    exit 1
  end
end

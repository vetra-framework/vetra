#!/usr/bin/env ruby
# Medição da K20 (ADR-023, ADR-022 §3, ADR-043, ADR-016) com o executor, num PostgreSQL 17/18 descartável com o bootstrap do
# ADR-036 pronto. DATABASE_URL administrativa; VETRA_APP_PASSWORD e VETRA_RELAY_PASSWORD: senhas dos logins reais, se necessárias.
# VETRA_MEDICAO_AMOSTRAS (padrão 120): chamadas medidas de cada comando; VETRA_MEDICAO_SEGUNDOS (padrão 3) e
# VETRA_MEDICAO_RODADAS (padrão 3): as séries com 16 clientes da vt_system; VETRA_PGBOUNCER: caminho do binário do PgBouncer,
# para medir o pooler em modo de transação (sem ele, essa parte é pulada e dita).
# Falha só nas conferências funcionais. Não cumpre o teste de aceitação 6 do ADR-023 (que exige falhar acima do limiar): relata.
#
# O que mede:
#   1. a latência de cada comando de referência dos quatro exemplos pelo Runner (um cliente), com as instruções SQL, as validações
#      de contexto (chamadas de vetra.current_tenant, current_actor e is_system_actor, contadas pelo banco) e o percentual que o
#      custo por validação, medido contra o RLS ingênuo, representa na latência;
#   2. o custo da escrita em vetra.idempotency: o mesmo comando sem chave, com chave nova e na repetição;
#   3. o custo da condição vt_system (ator de sistema) no ator comum, com 16 clientes;
#   4. a construção dos registros contra o gate de 10% do ADR-022, §3;
#   5. a latência atrás do pooler em modo de transação, se houver PgBouncer.
require_relative 'sonda_custo_contexto'
require_relative '../lib/vetra/execution'
require 'tmpdir'
require 'fileutils'
require 'socket'

class ExecutorCostProbe < ContextCostProbe
  WARMUP = 20
  CONTEXT_LIMIT = 25.0
  FUNCTIONS = %w[current_tenant current_actor is_system_actor].freeze
  DATA_STATEMENT = /\)\s+(SELECT|INSERT|UPDATE|DELETE|WITH)\b/i
  Row = Struct.new(:example, :operation, :median, :p95, :ops, :edge, :validations, :percent, :by_function)

  def run
    @admin = PG.connect(@url)
    @admin.exec('SET client_min_messages = warning')
    @admin.exec(Vetra::SQL::Context.role_guard)
    @seconds = Float(ENV.fetch('VETRA_MEDICAO_SEGUNDOS', '3'))
    @rounds = Integer(ENV.fetch('VETRA_MEDICAO_RODADAS', '3'))
    @samples = Integer(ENV.fetch('VETRA_MEDICAO_AMOSTRAS', '120'))
    @report, @detail, @thresholds, @rows, @notes = [], [], [], [], []
    before = roles
    revendas
    crm
    blog
    chat
    check('nenhum papel global mudou') { roles == before }
    print_report
    puts "#{@results.count(true)}/#{@results.size} verificações passaram (PostgreSQL #{@admin.server_version})."
    @results.all?
  ensure
    close_pools
    stop_pgbouncer
    if @admin
      @databases.reverse_each { |name| @admin.exec("DROP DATABASE IF EXISTS #{PG::Connection.quote_ident(name)} WITH (FORCE)") }
      @admin.close
    end
  end

  private

  def clock = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  def uuid(prefix, index) = format("00000000-0000-4000-#{prefix}-%012d", index)

  def percentile(values, share)
    sorted = values.sort
    sorted[[(sorted.size * share).ceil - 1, 0].max]
  end

  # ---- infraestrutura: pools, borda e contagem ---------------------------------------------------------------------------

  def close_pools
    @edge_db&.disconnect
    @edge_db = nil
    @runtime&.disconnect
    @runtime = nil
  end

  def pool_params(host: @admin.host, hostaddr: @admin.hostaddr, port: @admin.port)
    { adapter: :postgres, host: host, hostaddr: hostaddr, port: port, database: @database_name, password: ENV.fetch('VETRA_APP_PASSWORD', '') }.compact
  end

  def log_of(db)
    statements = []
    logger = Object.new
    %i[info error warn debug].each { |level| logger.define_singleton_method(level) { |message| statements << message.to_s } }
    db.loggers << logger
    statements
  end

  def open_pools(scoped, params = nil)
    close_pools
    params ||= pool_params
    @runtime = Vetra::Data.connect(params, max_connections: 1)
    @edge_db = Vetra::Data.connect(params, max_connections: 1)
    @ops_log, @edge_log = log_of(@runtime), log_of(@edge_db)
    @catalog = Vetra::Data::Repositories.new(@linked.document)
    options = scoped ? { issuer: @issuer } : { scope: :global }
    ops_unit = Vetra::Data::UnitOfWork.new(@runtime, **options)
    edge_unit = Vetra::Data::UnitOfWork.new(@edge_db, **options)
    authority = scoped ? Vetra::Execution::DatabaseAuthority.new(db: @edge_db) : Vetra::Execution::InProcessAuthority.new
    facts = Vetra::Execution::DatabaseFacts.new(catalog: @catalog, unit: edge_unit, authority: authority)
    edge = Vetra::Execution::Edge.new(identity: ->(credentials) { credentials }, facts: facts, authority: authority)
    @runner = Vetra::Execution::Runner.new(linked: @linked, catalog: @catalog, unit: ops_unit, edge: edge)
  end

  def start_example(example, scoped)
    setup_example(example)
    @scoped = scoped
  end

  # A contagem de chamadas de função vale só para as sessões abertas com track_functions ligado, e ligá-lo custa latência por
  # chamada: as séries cronometradas rodam sem ele, e a contagem roda à parte, em pools novos, com ele ligado só nessa passada.
  def with_tracking
    database = PG::Connection.quote_ident(@database_name)
    @admin.exec("ALTER DATABASE #{database} SET track_functions = 'pl'")
    yield
  ensure
    @admin.exec("ALTER DATABASE #{database} RESET track_functions")
  end

  # Chamadas de cada função de contexto, com as estatísticas das duas sessões descarregadas antes da leitura.
  def function_calls
    [@runtime, @edge_db].compact.each { |db| db.run('SELECT pg_stat_force_next_flush()') }
    @connection.exec('SELECT pg_stat_clear_snapshot()')
    found = @connection.exec("SELECT funcname, sum(calls)::bigint AS n FROM pg_stat_user_functions WHERE schemaname = 'vetra' AND funcname IN (#{FUNCTIONS.map { |f| "'#{f}'" }.join(', ')}) GROUP BY funcname")
                       .to_h { |row| [row['funcname'], row['n'].to_i] }
    FUNCTIONS.to_h { |name| [name, found.fetch(name, 0)] }
  end

  def data_statements(log) = log.count { |statement| statement.match?(DATA_STATEMENT) && !statement.include?('set_config') }
  def begins(log) = log.count { |statement| statement.match?(/\bBEGIN\b/) }

  def identity(tenant: nil, actor: SecureRandom.uuid, roles: [])
    Vetra::Execution::Identity.new(tenant_id: tenant, actor_id: actor, roles: roles)
  end

  # Mede um comando: WARMUP chamadas de aquecimento e @samples medidas (a entrada de cada uma sai de `builder`), depois uma
  # chamada à parte, só para contar instruções e validações. O resultado precisa ser ok em todas.
  def time_command(example, operation, who, builder, keyed: false)
    samples = []
    (WARMUP + @samples).times do |index|
      key = keyed ? "k20-#{SecureRandom.hex(8)}" : nil
      began = clock
      outcome = @runner.run(operation, builder.call(index), credentials: who, idempotency_key: key)
      elapsed = (clock - began) * 1000
      raise "#{operation} falhou: #{outcome.status} #{outcome.code}" unless outcome.ok?
      samples << elapsed if index >= WARMUP
    end
    by_function, ops, edge = counted(operation, who, builder.call(WARMUP + @samples), builder.call(WARMUP + @samples + 1), keyed)
    validations = by_function.values.sum
    median = median(samples)
    percent = @validation_us ? validations * @validation_us / 1000.0 / median * 100 : nil
    @rows << Row.new(example, operation, median, percentile(samples, 0.95), ops, edge, validations, percent, by_function)
    samples
  end

  # Duas chamadas em pools novos com o rastreio ligado: a primeira aquece, a segunda é contada. Devolve as validações de contexto
  # e as instruções SQL de dados da operação e da borda; depois reabre os pools sem rastreio.
  def counted(operation, who, warm_input, input, keyed)
    key = -> { keyed ? "k20-#{SecureRandom.hex(8)}" : nil }
    with_tracking do
      open_pools(@scoped)
      raise "#{operation} falhou na contagem" unless @runner.run(operation, warm_input, credentials: who, idempotency_key: key.call).ok?
      @ops_log.clear
      @edge_log.clear
      before = function_calls
      raise "#{operation} falhou na contagem" unless @runner.run(operation, input, credentials: who, idempotency_key: key.call).ok?
      after = function_calls
      [FUNCTIONS.to_h { |name| [name, after.fetch(name) - before.fetch(name)] }, data_statements(@ops_log), data_statements(@edge_log)]
    end
  ensure
    open_pools(@scoped)
  end

  # ---- 1. custo de uma validação de contexto, contra o RLS ingênuo -----------------------------------------------------------

  def validation_cost
    connection = app_connection
    value = token(tenant(1), SecureRandom.uuid)
    rows = 20_000
    # `g < 0` é falso em toda linha e depende da coluna: o planejador não puxa a função para um filtro de uma vez só, e ela roda
    # uma vez por linha. A conferência abaixo prova a contagem pelo próprio banco.
    signed_sql = "SELECT count(*) FROM generate_series(1, #{rows}) g WHERE g < 0 OR vetra.current_tenant() IS NOT NULL"
    naive_sql = "SELECT count(*) FROM generate_series(1, #{rows}) g WHERE g < 0 OR pg_catalog.current_setting('bench.tenant', true)::uuid IS NOT NULL"
    run = lambda do |sql, setting, setting_value|
      connection.exec('BEGIN')
      connection.exec_params('SELECT pg_catalog.set_config($1, $2, true)', [setting, setting_value])
      began = clock
      connection.exec(sql)
      elapsed = (clock - began) * 1000
      connection.exec('ROLLBACK')
      elapsed
    end
    signed, naive = [], []
    9.times do |round|
      pair = round.even? ? %i[signed naive] : %i[naive signed]
      pair.each do |kind|
        kind == :signed ? signed << run.(signed_sql, 'vetra.ctx', value) : naive << run.(naive_sql, 'bench.tenant', tenant(1))
      end
    end
    @validation_us = (median(signed) - median(naive)) / rows * 1000
    @validation_abs_us = median(signed) / rows * 1000
    @report << "Custo de uma validação do contexto assinado (vetra.current_tenant), PostgreSQL #{@admin.server_version}: " \
               "#{rows} chamadas por instrução, mediana de 9 repetições em ordem alternada"
    @report << "- assinada: #{ms(@validation_abs_us)} µs por chamada; ingênua (current_setting): #{ms(median(naive) / rows * 1000)} µs; " \
               "acréscimo por validação: #{ms(@validation_us)} µs"
    check_case('o contador do banco confere: três chamadas conhecidas contam três, e a instrução da medição chama a função uma vez por linha (100 linhas, 100 chamadas)') do
      with_tracking do
        counter = app_connection
        before = function_calls_for(counter)
        counter.exec('BEGIN')
        counter.exec_params('SELECT pg_catalog.set_config($1, $2, true)', ['vetra.ctx', value])
        3.times { counter.exec('SELECT vetra.current_tenant()') }
        counter.exec('COMMIT')
        known = function_calls_for(counter) - before
        counter.exec('BEGIN')
        counter.exec_params('SELECT pg_catalog.set_config($1, $2, true)', ['vetra.ctx', value])
        counter.exec(signed_sql.sub(rows.to_s, '100'))
        counter.exec('COMMIT')
        per_row = function_calls_for(counter) - before - known
        counter.close
        known == 3 && per_row == 100
      end
    end
  ensure
    connection&.close
  end

  # O mesmo custo por validação, com os 16 clientes em processos próprios da questão 1 do ADR-023: cada instrução valida 1.000 vezes,
  # e o custo por validação é a diferença entre a assinada e a ingênua, dividida por 1.000.
  def validation_cost_concurrent
    # Cada instrução valida 200 vezes (cerca de 20 ms): com 11 instruções por transação, uma série curta ainda completa transações.
    # O piso de 2 s existe para que uma série curta (a da CI) tenha amostras; a mediana de uma lista vazia não existe.
    rows = 200
    saved_seconds = @seconds
    @seconds = [@seconds, 2.0].max
    prepare = lambda do |_connection, client|
      tenant_id = tenant(client + 1)
      { tenant: tenant_id, token: token(tenant_id, uuid('9000', client + 1), 'crm.read_lead') }
    end
    contexts = { signed: ->(state) { ['vetra.ctx', state[:token]] }, naive: ->(state) { ['bench.tenant', state[:tenant]] } }
    statements = {
      signed: ->(c, _s) { c.exec("SELECT count(*) FROM generate_series(1, #{rows}) g WHERE g < 0 OR vetra.current_tenant() IS NOT NULL") },
      naive: ->(c, _s) { c.exec("SELECT count(*) FROM generate_series(1, #{rows}) g WHERE g < 0 OR pg_catalog.current_setting('bench.tenant', true)::uuid IS NOT NULL") }
    }
    costs = { signed: [], naive: [] }
    @rounds.times do |round|
      %i[signed naive].rotate(round).each do |kind|
        cost, raw = per_statement(round, restore: -> {}, context: contexts.fetch(kind), statement: statements.fetch(kind), &prepare)
        costs[kind] << cost
        @detail << "- Validação com 16 clientes, #{kind}, rodada #{round + 1}: #{ms(raw[1].first)} / #{ms(raw[STATEMENTS].first)} (#{raw[1].last} / #{raw[STATEMENTS].last})"
      end
    end
    extras = costs[:signed].zip(costs[:naive]).map { |signed_cost, naive_cost| (signed_cost - naive_cost) / rows * 1000 }
    @validation_us_16 = median(extras)
    @report << "- Com #{CLIENTS} clientes em processos próprios (#{@seconds} s por série, #{@rounds} rodadas): acréscimo por validação de #{ms(@validation_us_16)} µs " \
               "(#{ms(extras.min)} a #{ms(extras.max)})"
  ensure
    @seconds = saved_seconds
  end

  def function_calls_for(session)
    session.exec('SELECT pg_stat_force_next_flush()')
    @connection.exec('SELECT pg_stat_clear_snapshot()')
    @connection.exec("SELECT coalesce(sum(calls), 0)::bigint FROM pg_stat_user_functions WHERE schemaname = 'vetra'").getvalue(0, 0).to_i
  end

  # ---- dados e comandos de cada exemplo ----------------------------------------------------------------------------------------

  def load_scope_data
    series = ->(prefix) { "('00000000-0000-4000-#{prefix}-' || pg_catalog.lpad(%s::text, 12, '0'))::uuid" }
    tenant_of = series.call('8000')
    script(<<~SQL)
      INSERT INTO public.companies (id, name, created_at)
        SELECT #{format(tenant_of, 'i')}, 'Empresa ' || i, now() FROM generate_series(1, 16) i;
      INSERT INTO public.users (id, company_id, name, email, created_at)
        SELECT #{format(series.call('9000'), 'i')}, #{format(tenant_of, 'i')}, 'Gerente', 'g' || i || '@medicao.invalid', now()
          FROM generate_series(1, 16) i;
      INSERT INTO public.dealers (id, company_id, name, created_at)
        SELECT #{format(series.call('a000'), '(i * 1000 + d)')}, #{format(tenant_of, 'i')}, 'Revenda', now()
          FROM generate_series(1, 16) i, generate_series(1, 10) d;
      INSERT INTO public.memberships (company_id, user_id, dealer_id, role, created_at)
        SELECT #{format(tenant_of, 'i')}, #{format(series.call('9000'), 'i')}, #{format(series.call('a000'), '(i * 1000 + d)')}, 'gerente', now()
          FROM generate_series(1, 16) i, generate_series(1, 10) d;
    SQL
  end

  def manager = uuid('9000', 1)

  def seed_leads(count, dealer: nil)
    first = tenant(1)
    columns = dealer ? '(company_id, dealer_id, name, status, created_at)' : '(company_id, name, status, created_at)'
    values = dealer ? "$1, '#{dealer}', 'Lead ' || g, 'new', now()" : "$1, 'Lead ' || g, 'new', now()"
    before = as_superuser('SELECT id::text FROM public.leads WHERE company_id = $1', [first]).map { |row| row['id'] }
    insert_leads(first, "INSERT INTO public.leads #{columns} SELECT #{values} FROM generate_series(1, #{count}) g", [first])
    as_superuser('SELECT id::text FROM public.leads WHERE company_id = $1 ORDER BY id', [first]).map { |row| row['id'] } - before
  end

  def crm_commands(example, who, dealer: nil)
    needed = WARMUP + @samples + 3
    ids = seed_leads(needed + 1, dealer: dealer)
    base = dealer ? { dealer_id: dealer } : {}
    fixed = ids.first
    wins = ids.drop(1)
    time_command(example, 'crm.read_lead', who, ->(_) { { id: fixed } })
    time_command(example, 'crm.update_lead', who, ->(index) { { id: fixed, name: "Cliente #{index}" } })
    time_command(example, 'crm.create_lead', who, ->(index) { { name: "Novo #{index}" }.merge(base) })
    time_command(example, 'crm.win_lead', who, ->(index) { { lead_id: wins.fetch(index) } })
  end

  def revendas
    start_example('mini_crm_revendas', true)
    load_scope_data
    first_dealer = uuid('a000', 1001)
    script('ANALYZE')
    validation_cost
    validation_cost_concurrent
    open_pools(true)
    who = identity(tenant: tenant(1), actor: manager, roles: ['crm.gerente'])
    crm_commands('mini_crm_revendas', who, dealer: first_dealer)
    @notes << 'mini_crm_revendas: o gerente tem vínculo com 10 revendas; as consultas passam pelo RLS com escopo por vínculo.'
    pooler_latency(who, first_dealer)
    close_pools
    system_actor_cost
    records_gate(tenant(2))
  end

  def crm
    start_example('mini_crm', true)
    script(<<~SQL)
      INSERT INTO public.companies (id, name, created_at) VALUES ('#{tenant(1)}', 'Empresa', now());
    SQL
    open_pools(true)
    crm_commands('mini_crm', identity(tenant: tenant(1), roles: ['crm.gerente']))
    close_pools
  end

  def blog
    start_example('blog', false)
    author = SecureRandom.uuid
    needed = WARMUP + @samples + 3
    script("INSERT INTO public.posts (id, author_id, title, status, created_at) SELECT gen_random_uuid(), '#{author}', 'Rascunho ' || g, 'draft', now() FROM generate_series(1, #{needed + 1}) g")
    ids = as_superuser("SELECT id::text FROM public.posts WHERE author_id = $1 ORDER BY id", [author]).map { |row| row['id'] }
    open_pools(false)
    who = identity(actor: author, roles: ['blog.autor'])
    fixed = ids.first
    time_command('blog', 'blog.find_post', who, ->(_) { { post_id: fixed } })
    time_command('blog', 'blog.update_post', who, ->(index) { { id: fixed, title: "Título #{index}" } })
    time_command('blog', 'blog.create_post', who, ->(index) { { title: "Novo #{index}" } })
    time_command('blog', 'blog.publish_post', who, ->(index) { { post_id: ids.drop(1).fetch(index) } })
    idempotency_cost(who, fixed)
    close_pools
  end

  def chat
    start_example('chat', false)
    ana = SecureRandom.uuid
    room = SecureRandom.uuid
    script("INSERT INTO public.users (id, name, email, created_at) VALUES ('#{ana}', 'Ana', 'ana@medicao.invalid', now())")
    script("INSERT INTO public.rooms (id, owner_id, name, created_at) VALUES ('#{room}', '#{ana}', 'Geral', now())")
    script("INSERT INTO public.room_memberships (room_id, user_id, created_at) VALUES ('#{room}', '#{ana}', now())")
    script("INSERT INTO public.messages (room_id, author_id, body, created_at) SELECT '#{room}', '#{ana}', 'Mensagem ' || g, now() FROM generate_series(1, 50) g")
    open_pools(false)
    who = identity(actor: ana, roles: ['chat.authenticated'])
    time_command('chat', 'chat.room_page', who, ->(_) { { room_id: room } })
    time_command('chat', 'chat.my_rooms', who, ->(_) { {} })
    time_command('chat', 'chat.create_message', who, ->(index) { { room_id: room, body: "Texto #{index}" } })
    time_command('chat', 'chat.create_room', who, ->(index) { { name: "Sala #{index}" } })
    close_pools
  end

  # ---- 2. custo da escrita em vetra.idempotency ----------------------------------------------------------------------------------

  def idempotency_cost(who, post)
    rounds = 5
    per_round = @samples / rounds
    plain, keyed, replayed = [], [], []
    replay_key = "k20-replay-#{SecureRandom.hex(6)}"
    @runner.run('blog.update_post', { id: post, title: 'Repetição' }, credentials: who, idempotency_key: replay_key)
    run_one = lambda do |kind, index|
      key = { plain: nil, keyed: "k20-#{SecureRandom.hex(8)}", replayed: replay_key }.fetch(kind)
      title = kind == :replayed ? 'Repetição' : "Série #{index}"
      began = clock
      outcome = @runner.run('blog.update_post', { id: post, title: title }, credentials: who, idempotency_key: key)
      elapsed = (clock - began) * 1000
      raise "update_post com #{kind} falhou: #{outcome.status} #{outcome.code}" unless outcome.ok? && (kind != :replayed || outcome.replayed?)
      elapsed
    end
    10.times { |index| %i[plain keyed replayed].each { |kind| run_one.(kind, -index) } }
    rounds.times do |round|
      per_round.times do |index|
        %i[plain keyed replayed].rotate(round).each do |kind|
          { plain: plain, keyed: keyed, replayed: replayed }.fetch(kind) << run_one.(kind, round * per_round + index)
        end
      end
    end
    cost = median(keyed) - median(plain)
    @report << ''
    @report << "Custo da escrita em vetra.idempotency (ADR-043), blog.update_post pelo Runner, #{per_round * rounds} chamadas de cada tipo em ordem alternada, " \
               "PostgreSQL #{@admin.server_version} (ms, mediana e p95)"
    @report << '| Sem chave | Com chave nova (claim e complete) | Repetição com a mesma chave | Acréscimo da chave nova |'
    @report << '|---|---|---|---|'
    @report << "| #{ms(median(plain))} (p95 #{ms(percentile(plain, 0.95))}) | #{ms(median(keyed))} (p95 #{ms(percentile(keyed, 0.95))}) | " \
               "#{ms(median(replayed))} (p95 #{ms(percentile(replayed, 0.95))}) | #{signed(cost)} ms (#{format('%+.0f', cost / median(plain) * 100)}%) |"
    check_case('a chave nova gravou uma linha por chamada em vetra.idempotency e as repetições não gravaram outra (uma linha a mais, a da chave repetida)') do
      as_superuser("SELECT count(*)::int AS n FROM vetra.idempotency WHERE key LIKE 'k20-%'").first['n'].to_i == 10 + per_round * rounds + 1
    end
  end

  # ---- 3. custo da condição vt_system no ator comum -------------------------------------------------------------------------------

  def system_actor_cost
    script(<<~SQL)
      CREATE SCHEMA bench_vt; CREATE SCHEMA bench_novt;
      GRANT USAGE ON SCHEMA bench_vt TO vetra_app; GRANT USAGE ON SCHEMA bench_novt TO vetra_app;
      CREATE TABLE bench_vt.leads (LIKE public.leads INCLUDING DEFAULTS INCLUDING CONSTRAINTS);
      INSERT INTO bench_vt.leads (company_id, dealer_id, name, status, created_at)
        SELECT ('00000000-0000-4000-8000-' || pg_catalog.lpad(i::text, 12, '0'))::uuid,
               ('00000000-0000-4000-a000-' || pg_catalog.lpad((i * 1000 + 1 + g % 10)::text, 12, '0'))::uuid, 'Lead ' || g, 'new', now()
          FROM generate_series(1, 16) i, generate_series(1, 2000) g;
      CREATE TABLE bench_novt.leads (LIKE public.leads INCLUDING DEFAULTS INCLUDING CONSTRAINTS);
      INSERT INTO bench_novt.leads SELECT * FROM bench_vt.leads;
    SQL
    %w[vt novt].each do |variant|
      script(<<~SQL)
        ALTER TABLE bench_#{variant}.leads ADD PRIMARY KEY (id);
        CREATE INDEX ON bench_#{variant}.leads (company_id, dealer_id);
        ALTER TABLE bench_#{variant}.leads ENABLE ROW LEVEL SECURITY;
        ALTER TABLE bench_#{variant}.leads FORCE ROW LEVEL SECURITY;
        GRANT SELECT, INSERT, UPDATE ON bench_#{variant}.leads TO vetra_app;
      SQL
    end
    # As políticas das cópias são as da tabela gerada; a variante sem vt_system só deixa de ter essa.
    as_superuser("SELECT policyname, permissive, cmd, qual, with_check FROM pg_policies WHERE schemaname = 'public' AND tablename = 'leads'").each do |policy|
      %w[vt novt].each do |variant|
        next if variant == 'novt' && policy['policyname'] == 'vt_system'
        sql = +"CREATE POLICY #{PG::Connection.quote_ident(policy['policyname'])} ON bench_#{variant}.leads AS #{policy['permissive']} FOR #{policy['cmd']} TO vetra_app"
        sql << " USING (#{policy['qual']})" if policy['qual']
        sql << " WITH CHECK (#{policy['with_check']})" if policy['with_check']
        script(sql)
      end
    end
    script('VACUUM ANALYZE')
    policies = as_superuser("SELECT schemaname, count(*)::int AS n FROM pg_policies WHERE tablename = 'leads' GROUP BY schemaname").to_h { |row| [row['schemaname'], row['n'].to_i] }
    check_case('as cópias têm as políticas da tabela gerada: a com vt_system tem uma a mais, e o ator comum lê as mesmas linhas nas duas') do
      actor = token(tenant(1), manager, 'crm.read_lead')
      counts = %w[bench_vt bench_novt].map { |schema| count_as_app("#{schema}.leads", 'vetra.ctx', actor) }
      policies['bench_vt'] == policies['bench_novt'] + 1 && policies['public'] == policies['bench_vt'] && counts == [2000, 2000]
    end
    check_case('o ator de sistema lê o tenant inteiro só onde a política vt_system existe, e o ator sem vínculo não lê nada em nenhuma') do
      system = @issuer.issue(tenant_id: tenant(1), system_actor: 'crm.notify_seller', op_id: SecureRandom.uuid, cmd: 'crm.win_lead').value
      stranger = token(tenant(1), SecureRandom.uuid, 'crm.read_lead')
      count_as_app('bench_vt.leads', 'vetra.ctx', system) == 2000 && count_as_app('bench_novt.leads', 'vetra.ctx', system).zero? &&
        %w[bench_vt bench_novt].all? { |schema| count_as_app("#{schema}.leads", 'vetra.ctx', stranger).zero? }
    end
    ids = (1..CLIENTS).to_h { |client| [client, as_superuser("SELECT id::text FROM bench_vt.leads WHERE company_id = $1 ORDER BY id LIMIT 200", [tenant(client)]).map { |row| row['id'] }] }
    prepare = lambda do |_connection, client|
      tenant_id = tenant(client + 1)
      { tenant: tenant_id, ids: ids.fetch(client + 1), token: token(tenant_id, uuid('9000', client + 1), 'crm.read_lead'), next: 0 }
    end
    context = ->(state) { ['vetra.ctx', state[:token]] }
    pick = ->(state) { state[:ids][(state[:next] += 1) % state[:ids].size] }
    operations = {
      'Busca por chave' => ->(table) { ->(c, s) { c.exec_params("SELECT name FROM #{table} WHERE id = $1", [pick.(s)]) } },
      'Varredura do tenant (2.000 linhas)' => ->(table) { ->(c, _s) { c.exec("SELECT count(*) FROM #{table}") } },
      '`UPDATE` com `WITH CHECK`' => ->(table) { ->(c, s) { c.exec_params("UPDATE #{table} SET name = name WHERE id = $1", [pick.(s)]) } },
      '`INSERT` com `WITH CHECK`' => lambda do |table|
        ->(c, s) { c.exec_params("INSERT INTO #{table} (company_id, dealer_id, name, status, created_at) VALUES ($1, $2, 'Lead medido', 'new', now())", [s[:tenant], uuid('a000', (s[:tenant][-12..].to_i * 1000) + 1)]) }
      end
    }
    @report << ''
    @report << "Condição vt_system no ator comum (K15), PostgreSQL #{@admin.server_version}: custo por instrução (ms), #{CLIENTS} clientes em processos próprios, " \
               "#{@seconds} s por série, #{@rounds} rodadas em ordem alternada (mediana; mínimo a máximo). Decisão do mantenedor: não há limiar."
    @report << '| Instrução | Sem vt_system | Com vt_system | Acréscimo da vt_system |'
    @report << '|---|---|---|---|'
    extras = []
    operations.each do |label, build|
      costs = Hash.new { |hash, key| hash[key] = [] }
      @rounds.times do |round|
        %w[vt novt].rotate(round).each do |variant|
          table = "bench_#{variant}.leads"
          restore = lambda do
            script("DELETE FROM #{table} WHERE name = 'Lead medido'")
            script("VACUUM ANALYZE #{table}")
          end
          cost, raw = per_statement(round, restore: restore, context: context, statement: build.call(table), &prepare)
          costs[variant] << cost
          @detail << "- vt_system #{label}, #{variant}, rodada #{round + 1}: #{ms(raw[1].first)} / #{ms(raw[STATEMENTS].first)} (#{raw[1].last} / #{raw[STATEMENTS].last})"
        end
      end
      extra = costs['vt'].zip(costs['novt']).map { |with, without| with - without }
      extras.concat(extra)
      range = ->(values) { "#{ms(median(values))} (#{ms(values.min)} a #{ms(values.max)})" }
      @report << "| #{label} | #{range.(costs['novt'])} | #{range.(costs['vt'])} | #{signed(median(extra))} (#{signed(extra.min)} a #{signed(extra.max)}) |"
    end
    @vt_system_extra = median(extras)
  end

  # ---- 5. pooler em modo de transação --------------------------------------------------------------------------------------------

  def free_port
    server = TCPServer.new('127.0.0.1', 0)
    server.addr[1].tap { server.close }
  end

  def start_pgbouncer
    binary = ENV['VETRA_PGBOUNCER']
    return nil unless binary && File.executable?(binary)
    @pgbouncer_dir = Dir.mktmpdir('vetra-pgbouncer-')
    port = free_port
    # Medição local: o servidor descartável aceita o login por confiança; o PgBouncer só precisa conhecer o usuário. O arquivo
    # leva a senha de VETRA_APP_PASSWORD, se houver: modo 0600, e o diretório inteiro é removido em stop_pgbouncer, mesmo após erro.
    File.write(File.join(@pgbouncer_dir, 'userlist.txt'), %("vetra_app" "#{ENV.fetch('VETRA_APP_PASSWORD', '')}"\n), perm: 0o600)
    File.write(File.join(@pgbouncer_dir, 'pgbouncer.ini'), <<~INI)
      [databases]
      * = host=#{@admin.host} port=#{@admin.port}
      [pgbouncer]
      listen_addr = 127.0.0.1
      listen_port = #{port}
      unix_socket_dir = #{@pgbouncer_dir}
      auth_type = trust
      auth_file = #{@pgbouncer_dir}/userlist.txt
      pool_mode = transaction
      default_pool_size = 4
      max_client_conn = 50
      ignore_startup_parameters = extra_float_digits,options
      logfile = #{@pgbouncer_dir}/pgbouncer.log
      pidfile = #{@pgbouncer_dir}/pgbouncer.pid
    INI
    @pgbouncer_pid = Process.spawn(binary, File.join(@pgbouncer_dir, 'pgbouncer.ini'), %i[out err] => File::NULL)
    deadline = clock + 10
    ready = false
    until ready
      raise 'o PgBouncer encerrou ao iniciar' if Process.wait(@pgbouncer_pid, Process::WNOHANG)
      raise 'o PgBouncer não aceitou conexões em 10 s' if clock > deadline
      begin
        TCPSocket.new('127.0.0.1', port).close
        ready = true
      rescue SystemCallError
        sleep 0.1
      end
    end
    port
  end

  # Encerra o PgBouncer, recolhe o processo (com KILL depois de 5 s) e apaga o diretório com a lista de usuários.
  def stop_pgbouncer
    if @pgbouncer_pid
      pid, @pgbouncer_pid = @pgbouncer_pid, nil
      begin
        Process.kill('TERM', pid)
        deadline = clock + 5
        until Process.wait(pid, Process::WNOHANG)
          if clock > deadline
            Process.kill('KILL', pid)
            Process.wait(pid)
            break
          end
          sleep 0.05
        end
      rescue Errno::ESRCH, Errno::ECHILD
        nil
      end
    end
    FileUtils.rm_rf(@pgbouncer_dir) if @pgbouncer_dir
    @pgbouncer_dir = nil
  end

  def pooler_latency(who, dealer)
    port = start_pgbouncer
    unless port
      @notes << 'Pooler transacional: não medido, porque não há PgBouncer neste ambiente (VETRA_PGBOUNCER aponta o binário).'
      return
    end
    lead = seed_leads(1, dealer: dealer).first
    series = ->(label) do
      samples = { read: [], update: [] }
      (WARMUP + @samples).times do |index|
        { read: ['crm.read_lead', { id: lead }], update: ['crm.update_lead', { id: lead, name: "Pooler #{label} #{index}" }] }.each do |kind, (operation, input)|
          began = clock
          outcome = @runner.run(operation, input, credentials: who)
          raise "#{operation} atrás do pooler falhou: #{outcome.status} #{outcome.code}" unless outcome.ok?
          samples[kind] << (clock - began) * 1000 if index >= WARMUP
        end
      end
      samples
    end
    direct, pooled = nil, nil
    2.times do |round|
      [:direct, :pooled].rotate(round).each do |mode|
        open_pools(true, mode == :direct ? pool_params : pool_params(host: '127.0.0.1', hostaddr: nil, port: port))
        result = series.call(mode)
        mode == :direct ? direct = result : pooled = result
      end
    end
    check_case('atrás do pooler em modo de transação o contexto não vaza entre transações: nenhuma sessão fica com contexto ou transação aberta') do
      open_pools(true, pool_params(host: '127.0.0.1', hostaddr: nil, port: port))
      empty = @runtime.get(Sequel.function(:current_setting, 'vetra.ctx', true))
      [nil, ''].include?(empty) && as_superuser("SELECT count(*)::int AS n FROM pg_stat_activity WHERE datname = current_database() AND usename = 'vetra_app' AND state LIKE 'idle in transaction%'").first['n'].to_i.zero?
    end
    @report << ''
    @report << "Latência atrás do PgBouncer em modo de transação (pool de 4 servidores), mini_crm_revendas pelo Runner, #{@samples} chamadas por série (ms, mediana; p95)"
    @report << '| Comando | Direto | Atrás do pooler | Acréscimo do pooler |'
    @report << '|---|---|---|---|'
    %i[read update].each do |kind|
      name = kind == :read ? 'crm.read_lead' : 'crm.update_lead'
      @report << "| #{name} | #{ms(median(direct[kind]))} (p95 #{ms(percentile(direct[kind], 0.95))}) | #{ms(median(pooled[kind]))} (p95 #{ms(percentile(pooled[kind], 0.95))}) | " \
                 "#{signed(median(pooled[kind]) - median(direct[kind]))} ms |"
    end
  ensure
    close_pools
    stop_pgbouncer
  end

  # ---- relatório --------------------------------------------------------------------------------------------------------------------

  def print_report
    puts "Latência por comando de referência, pelo Runner, um cliente, #{@samples} chamadas medidas após #{WARMUP} de aquecimento, PostgreSQL #{@admin.server_version}, " \
         "Ruby #{RUBY_VERSION}"
    puts "Custo por validação de contexto sobre o RLS ingênuo: #{ms(@validation_us)} µs com um cliente e #{ms(@validation_us_16)} µs com #{CLIENTS} clientes. " \
         'Acréscimo = validações × custo ÷ mediana do comando.'
    puts '| Exemplo | Comando | Mediana (ms) | p95 (ms) | Instruções SQL da operação | da borda | Validações de contexto | tenant / ator / sistema | Validações por instrução | Acréscimo (custo de 1 cliente) | Acréscimo (custo de 16 clientes) | Sem as validações de sistema (custo de 16 clientes) |'
    puts '|---|---|---|---|---|---|---|---|---|---|---|---|'
    cost16 = ->(row, count) { count * @validation_us_16 / 1000.0 / row.median * 100 }
    system_free = ->(row) { cost16.call(row, row.validations - row.by_function.fetch('is_system_actor')) }
    @rows.each do |row|
      total = row.ops + row.edge
      ratio = total.zero? ? '—' : ms(row.validations.to_f / total)
      split = FUNCTIONS.map { |name| row.by_function.fetch(name) }.join(' / ')
      puts "| #{row.example} | #{row.operation} | #{ms(row.median)} | #{ms(row.p95)} | #{row.ops} | #{row.edge} | #{row.validations} | #{split} | #{ratio} | " \
           "#{ms(row.percent)}% | #{ms(cost16.call(row, row.validations))}% | #{ms(system_free.call(row))}% |"
    end
    with_rls = @rows.select { |row| row.validations.positive? }
    unless with_rls.empty?
      threshold('ADR-023: acréscimo das validações sobre a latência de cada comando com RLS, custo medido com 1 cliente', with_rls.map(&:percent), CONTEXT_LIMIT, '%')
      threshold('ADR-023: o mesmo, com o custo por validação medido com 16 clientes', with_rls.map { |row| cost16.call(row, row.validations) }, CONTEXT_LIMIT, '%')
      threshold('ADR-023: o mesmo, com 16 clientes e sem as validações de is_system_actor (a política vt_system)', with_rls.map(&system_free), CONTEXT_LIMIT, '%')
    end
    @notes.each { |note| puts "- #{note}" }
    puts '- Comandos sem RLS (blog e chat) não validam contexto assinado: zero validações.'
    puts ''
    puts @report
    puts ''
    puts 'Limiares (hipóteses dos ADRs). Medição informativa: não cumpre o teste de aceitação 6 do ADR-023, que exige falhar acima do limiar;'
    puts 'esse gate continua pendente. "Inconclusivo" quando a mediana fica dentro e alguma execução acima.'
    puts @thresholds
    puts ''
    puts 'Detalhe das séries com 16 clientes (mediana da transação com 1 e com 11 instruções, ms; amostras):'
    puts @detail
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    exit(ExecutorCostProbe.new(ENV.fetch('DATABASE_URL')).run ? 0 : 1)
  rescue StandardError => error
    warn "FALHA: medição do executor interrompida (#{error.class}: #{error.message.lines.first&.strip})"
    warn error.backtrace.first(6).join("\n") if ENV['VETRA_SONDA_DEBUG']
    exit 1
  end
end

#!/usr/bin/env ruby
# Medição preliminar e informativa do ADR-023 (questões 1 e 2) e do gate do ADR-022, §3, num PostgreSQL 17/18
# descartável, com o bootstrap do ADR-036 pronto; DATABASE_URL administrativa. VETRA_APP_PASSWORD: senha do login real
# vetra_app. VETRA_MEDICAO_SEGUNDOS (padrão 3) e VETRA_MEDICAO_RODADAS (padrão 3): duração de cada série e número de
# rodadas. Aplica os planos pelo db:migrate, carrega dados como superusuário e mede como vetra_app, com 16 clientes.
# Falha só nas conferências funcionais: não cumpre o teste de aceitação 6 do ADR-023, que exige falhar acima do limiar.
# Não altera papéis nem artefatos.
require_relative 'sonda_relay'

class ContextCostProbe < RelayProbe
  CLIENTS = 16
  STATEMENTS = 11
  TENANTS = 50
  PER_TENANT = 4_000
  READY_TIMEOUT = 60
  # Limiares de hipótese do ADR-023 (questões 1 e 2) e do ADR-022, §3.
  SIGNED_LIMIT_MS = 0.5
  SCOPE_LIMIT_MS = 1.0
  RECORDS_LIMIT = 0.10

  def run
    @admin = PG.connect(@url)
    @admin.exec('SET client_min_messages = warning')
    @admin.exec(Vetra::SQL::Context.role_guard)
    @seconds = Float(ENV.fetch('VETRA_MEDICAO_SEGUNDOS', '3'))
    @rounds = Integer(ENV.fetch('VETRA_MEDICAO_RODADAS', '3'))
    @report, @detail, @thresholds = [], [], []
    before = roles
    signed_cost
    scope_cost
    check('nenhum papel global mudou') { roles == before }
    puts @report
    puts ''
    puts 'Limiares (hipóteses dos ADRs). Medição informativa: não cumpre o teste de aceitação 6 do ADR-023, que exige'
    puts 'falhar acima do limiar; esse gate continua pendente. "Inconclusivo" quando a mediana fica dentro e alguma rodada acima.'
    puts @thresholds
    puts ''
    puts 'Detalhe por rodada (mediana da transação com 1 e com 11 instruções, ms; amostras):'
    puts @detail
    puts "#{@results.count(true)}/#{@results.size} verificações passaram (PostgreSQL #{@admin.server_version})."
    @results.all?
  ensure
    if @admin
      @databases.reverse_each { |name| @admin.exec("DROP DATABASE IF EXISTS #{PG::Connection.quote_ident(name)} WITH (FORCE)") }
      @admin.close
    end
  end

  private

  def script(sql)
    @connection.exec(sql)
  end

  def tenant(index)
    format('00000000-0000-4000-8000-%012d', index)
  end

  def dealer(index)
    format('00000000-0000-4000-a000-%012d', index)
  end

  def setup_example(example)
    @example = example
    @root = File.expand_path("../examples/#{example}", __dir__)
    @linked = Vetra::Graph::Compiler.new(root: @root).link
    @connection = create_database
    @database_name = @databases.last
    raise 'db:migrate não aplicou os planos' unless migrate.status == :applied
    @secret = SecureRandom.random_bytes(32)
    provision('medicao', @secret)
    @issuer = Vetra::Data::ContextIssuer.new(kid: 'medicao', secret: @secret, ttl: 120)
  end

  def app_connection
    PG.connect({ host: @admin.host, hostaddr: @admin.hostaddr, port: @admin.port, dbname: @database_name,
                 user: 'vetra_app', password: ENV.fetch('VETRA_APP_PASSWORD', '') }.compact)
  end

  def token(tenant_id, actor_id, cmd = 'crm.read_lead')
    @issuer.issue(tenant_id: tenant_id, actor_id: actor_id, op_id: SecureRandom.uuid, cmd: cmd).value
  end

  # Os triggers de transição do plano exigem o comando no contexto também para quem carrega os dados.
  def insert_leads(tenant_id, sql, params = [])
    @connection.exec('BEGIN')
    @connection.exec_params('SELECT pg_catalog.set_config($1, $2, true)', ['vetra.ctx', token(tenant_id, SecureRandom.uuid, 'crm.create_lead')])
    @connection.exec_params(sql, params)
    @connection.exec('COMMIT')
  rescue StandardError
    @connection.exec('ROLLBACK') rescue nil
    raise
  end

  def median(values)
    sorted = values.sort
    middle = sorted.size / 2
    sorted.size.odd? ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2.0
  end

  def ms(value)
    format('%.3f', value).tr('.', ',')
  end

  def signed(value)
    format('%+.3f', value).tr('.', ',')
  end

  def threshold(label, values, limit, unit)
    middle, top = median(values), values.max
    verdict = if top <= limit then 'dentro'
              elsif middle <= limit then 'inconclusivo'
              else 'acima'
              end
    @thresholds << "- #{label}: mediana #{ms(middle)} #{unit} (rodadas de #{ms(values.min)} a #{ms(top)}), limiar " \
                   "#{ms(limit)} #{unit}: #{verdict}"
  end

  # 16 clientes por @seconds, cada um num processo próprio com a sua conexão: threads do mesmo processo disputariam o
  # GVL, e a latência mediria o Ruby. Cada transação abre, instala o contexto da variante e emite `count` vezes a
  # instrução. Devolve a latência mediana da transação, em milissegundos, e o número de amostras. O primeiro meio
  # segundo é aquecimento. Um filho que falha avisa o pai, que encerra e recolhe todos os filhos.
  def latency(count, context:, statement:, &prepare)
    completed = false
    ready_reader, ready_writer = IO.pipe
    go_reader, go_writer = IO.pipe
    children = []
    CLIENTS.times do |client|
      out_reader, out_writer = IO.pipe
      pid = Process.fork do
        # Um sinal nunca leva o filho pelos finalizadores: eles encerrariam no servidor as sessões herdadas do pai.
        %w[TERM INT].each { |signal| trap(signal) { exit!(1) } }
        [ready_reader, go_writer, out_reader].each(&:close)
        status = 0
        begin
          connection = app_connection
          state = prepare.call(connection, client)
          ready_writer.write('R')
          ready_writer.close
          # Sem o sinal (o pai desistiu), o filho sai sem medir.
          raise 'medição cancelada' unless go_reader.read(1)
          samples = []
          warm = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 0.5
          deadline = warm + @seconds
          loop do
            began = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            break if began > deadline
            connection.exec('BEGIN')
            connection.exec_params('SELECT pg_catalog.set_config($1, $2, true)', context.call(state))
            count.times { statement.call(connection, state) }
            connection.exec('COMMIT')
            samples << ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - began) * 1000) if began > warm
          end
          out_writer.write(Marshal.dump(samples))
        rescue StandardError => error
          (ready_writer.write('E') rescue nil) unless ready_writer.closed?
          out_writer.write(Marshal.dump(error.class.name)) rescue nil
          status = 1
        ensure
          out_writer.close rescue nil
          connection&.close
          # Sem finalizadores: as conexões herdadas do processo pai não podem ser encerradas pelo filho.
          exit!(status)
        end
      end
      out_writer.close
      children << [pid, out_reader]
    end
    ready_writer.close
    go_reader.close
    signals = +''
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + READY_TIMEOUT
    while signals.size < CLIENTS && !signals.include?('E')
      remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
      break if remaining <= 0 || !IO.select([ready_reader], nil, nil, remaining)
      chunk = ready_reader.read_nonblock(CLIENTS, exception: false)
      break if chunk.nil?
      signals << chunk if chunk.is_a?(String)
    end
    raise "clientes da medição não ficaram prontos (#{signals.count('R')} de #{CLIENTS})" unless signals == 'R' * CLIENTS
    go_writer.write('G' * CLIENTS)
    go_writer.close
    samples = children.flat_map do |pid, reader|
      data = Marshal.load(reader.read)
      raise "cliente da medição falhou (#{data})" unless data.is_a?(Array)
      data
    end
    completed = true
    [median(samples), samples.size]
  ensure
    go_writer.close unless go_writer.nil? || go_writer.closed?
    ready_reader.close unless ready_reader.nil? || ready_reader.closed?
    children&.each do |pid, reader|
      reader.close unless reader.closed?
      # No caminho normal o filho já está saindo; só uma falha justifica o sinal.
      Process.kill('TERM', pid) rescue nil unless completed
      Process.wait(pid) rescue nil
    end
  end

  # Custo por instrução de uma variante, numa rodada: (mediana com 11 instruções − mediana com 1) / 10, com a ordem das
  # duas séries alternada entre rodadas. O BEGIN, o set_config e o COMMIT se cancelam sob a hipótese de que se somam; a
  # alternância e as rodadas expõem o quanto ela falha.
  def per_statement(round, restore:, context:, statement:, &prepare)
    order = round.even? ? [1, STATEMENTS] : [STATEMENTS, 1]
    results = order.to_h do |count|
      restore.call
      [count, latency(count, context: context, statement: statement, &prepare)]
    end
    [(results[STATEMENTS].first - results[1].first) / (STATEMENTS - 1), results]
  end

  def load_crm
    script(<<~SQL)
      INSERT INTO public.companies (id, name, created_at)
        SELECT ('00000000-0000-4000-8000-' || pg_catalog.lpad(i::text, 12, '0'))::uuid, 'Empresa ' || i, now()
          FROM generate_series(1, #{TENANTS}) i;
      CREATE SCHEMA bench;
      GRANT USAGE ON SCHEMA bench TO vetra_app;
    SQL
    (1..TENANTS).each do |index|
      insert_leads(tenant(index), <<~SQL, [tenant(index)])
        INSERT INTO public.leads (company_id, name, status, created_at)
          SELECT $1, 'Lead ' || g, 'new', now() FROM generate_series(1, #{PER_TENANT}) g
      SQL
    end
    # Três cópias com os mesmos dados e índices, sem os triggers de transição: sem RLS e com o filtro à mão, com RLS
    # ingênuo (current_setting) e com a forma da política gerada pelo plano, que usa o contexto assinado. A diferença
    # entre a ingênua e a assinada é só a função de contexto, como na questão 1 do ADR-023.
    { 'plain' => nil, 'naive' => "(SELECT pg_catalog.current_setting('bench.tenant', true)::uuid)",
      'signed' => '(SELECT vetra.current_tenant())' }.each do |name, tenant|
      script(<<~SQL)
        CREATE TABLE bench.leads_#{name} (LIKE public.leads INCLUDING DEFAULTS INCLUDING CONSTRAINTS);
        INSERT INTO bench.leads_#{name} SELECT * FROM public.leads;
        ALTER TABLE bench.leads_#{name} ADD PRIMARY KEY (id);
        CREATE INDEX ON bench.leads_#{name} (company_id, id);
        GRANT SELECT, INSERT, UPDATE ON bench.leads_#{name} TO vetra_app;
      SQL
      next unless tenant
      script(<<~SQL)
        ALTER TABLE bench.leads_#{name} ENABLE ROW LEVEL SECURITY;
        ALTER TABLE bench.leads_#{name} FORCE ROW LEVEL SECURITY;
        CREATE POLICY vt_tenant ON bench.leads_#{name} AS RESTRICTIVE FOR ALL TO vetra_app
          USING (company_id = #{tenant}) WITH CHECK (company_id = #{tenant});
        CREATE POLICY vt_access ON bench.leads_#{name} AS PERMISSIVE FOR ALL TO vetra_app USING (true) WITH CHECK (true);
      SQL
    end
    script('VACUUM ANALYZE')
  end

  def ids_of(tenant_id)
    as_superuser('SELECT id::text FROM public.leads WHERE company_id = $1 ORDER BY id LIMIT 200', [tenant_id]).map { |row| row['id'] }
  end

  def as_app(sql, setting, value)
    connection = app_connection
    connection.exec('BEGIN')
    connection.exec_params('SELECT pg_catalog.set_config($1, $2, true)', [setting, value]) if setting
    connection.exec(sql).values
  ensure
    connection&.exec('ROLLBACK') rescue nil
    connection&.close
  end

  def count_as_app(table, setting, value)
    as_app("SELECT count(*) FROM #{table}", setting, value).first.first.to_i
  end

  def signed_cost
    setup_example('mini_crm')
    load_crm
    first = tenant(1)
    actor = SecureRandom.uuid
    valid = token(first, actor)
    altered = valid[0...-1] + (valid[-1] == 'A' ? 'B' : 'A')
    check_case('isolamento antes de medir: sem contexto nenhuma linha, com o token o tenant, com o MAC alterado nenhuma') do
      %w[public.leads bench.leads_signed].all? do |table|
        count_as_app(table, nil, nil).zero? && count_as_app(table, 'vetra.ctx', valid) == PER_TENANT &&
          count_as_app(table, 'vetra.ctx', altered).zero?
      end && count_as_app('bench.leads_naive', 'bench.tenant', first) == PER_TENANT
    end
    ids = (1..CLIENTS).to_h { |client| [client, ids_of(tenant(client))] }
    prepare = lambda do |_connection, client|
      tenant_id = tenant(client + 1)
      { tenant: tenant_id, ids: ids.fetch(client + 1), token: token(tenant_id, actor), next: 0 }
    end
    contexts = {
      'plain' => ->(state) { ['bench.dummy', state[:tenant]] },
      'naive' => ->(state) { ['bench.tenant', state[:tenant]] },
      'signed' => ->(state) { ['vetra.ctx', state[:token]] }
    }
    pick = ->(state) { state[:ids][(state[:next] += 1) % state[:ids].size] }
    operations = {
      'Busca por chave' => lambda do |table, filter|
        ->(c, s) { c.exec_params("SELECT name FROM #{table} WHERE id = $1#{filter ? ' AND company_id = $2' : ''}", filter ? [pick.(s), s[:tenant]] : [pick.(s)]) }
      end,
      'Varredura do tenant (4.000 linhas)' => lambda do |table, filter|
        ->(c, s) { c.exec_params("SELECT count(*) FROM #{table}#{filter ? ' WHERE company_id = $1' : ''}", filter ? [s[:tenant]] : []) }
      end,
      '`UPDATE` com `WITH CHECK`' => lambda do |table, filter|
        ->(c, s) { c.exec_params("UPDATE #{table} SET name = name WHERE id = $1#{filter ? ' AND company_id = $2' : ''}", filter ? [pick.(s), s[:tenant]] : [pick.(s)]) }
      end,
      '`INSERT` com `WITH CHECK`' => lambda do |table, _filter|
        ->(c, s) { c.exec_params("INSERT INTO #{table} (company_id, name, status, created_at) VALUES ($1, 'Lead medido', 'new', now())", [s[:tenant]]) }
      end
    }
    variants = %w[plain naive signed]
    @report << "Questão 1 do ADR-023, PostgreSQL #{@admin.server_version}: custo por instrução (ms), #{CLIENTS} clientes em " \
               "processos próprios, #{@seconds} s por série, #{@rounds} rodadas em ordem alternada (mediana; mínimo a máximo)"
    @report << '| Instrução | Sem RLS | RLS ingênuo | Contexto assinado | Acréscimo assinado − ingênuo |'
    @report << '|---|---|---|---|---|'
    extras = []
    operations.each do |label, build|
      costs = Hash.new { |hash, key| hash[key] = [] }
      @rounds.times do |round|
        # Ordem das variantes girada a cada rodada; cada série parte da tabela limpa (VACUUM, sem as linhas inseridas).
        variants.rotate(round).each do |variant|
          table = "bench.leads_#{variant}"
          restore = lambda do
            script("DELETE FROM #{table} WHERE name = 'Lead medido'")
            script("VACUUM ANALYZE #{table}")
          end
          cost, raw = per_statement(round, restore: restore, context: contexts.fetch(variant), statement: build.call(table, variant == 'plain'), &prepare)
          costs[variant] << cost
          @detail << "- Q1 #{label}, #{variant}, rodada #{round + 1}: #{ms(raw[1].first)} / #{ms(raw[STATEMENTS].first)} (#{raw[1].last} / #{raw[STATEMENTS].last})"
        end
      end
      extra = costs['signed'].zip(costs['naive']).map { |signed_cost, naive_cost| signed_cost - naive_cost }
      extras.concat(extra)
      cells = variants.map { |variant| "#{ms(median(costs[variant]))} (#{ms(costs[variant].min)} a #{ms(costs[variant].max)})" }
      @report << "| #{label} | #{cells.join(' | ')} | #{signed(median(extra))} (#{signed(extra.min)} a #{signed(extra.max)}) |"
    end
    threshold('ADR-023, questão 1: acréscimo do contexto assinado sobre o RLS ingênuo, todas as instruções', extras, SIGNED_LIMIT_MS, 'ms por instrução')
  end

  def load_dealers
    tenants = 200
    script(<<~SQL)
      INSERT INTO public.companies (id, name, created_at)
        SELECT ('00000000-0000-4000-8000-' || pg_catalog.lpad(i::text, 12, '0'))::uuid, 'Empresa ' || i, now() FROM generate_series(1, #{tenants}) i;
      INSERT INTO public.users (id, company_id, name, email, created_at)
        SELECT ('00000000-0000-4000-9000-' || pg_catalog.lpad((t * 100 + u)::text, 12, '0'))::uuid,
               ('00000000-0000-4000-8000-' || pg_catalog.lpad(t::text, 12, '0'))::uuid, 'Usuário', 'u' || t || '-' || u || '@medicao.invalid', now()
          FROM generate_series(1, #{tenants}) t, generate_series(1, 25) u;
      INSERT INTO public.dealers (id, company_id, name, created_at)
        SELECT ('00000000-0000-4000-a000-' || pg_catalog.lpad((t * 1000 + d)::text, 12, '0'))::uuid,
               ('00000000-0000-4000-8000-' || pg_catalog.lpad(t::text, 12, '0'))::uuid, 'Revenda', now()
          FROM generate_series(1, #{tenants}) t, generate_series(1, 200) d;
      INSERT INTO public.memberships (company_id, user_id, dealer_id, role, created_at)
        SELECT ('00000000-0000-4000-8000-' || pg_catalog.lpad(t::text, 12, '0'))::uuid,
               ('00000000-0000-4000-9000-' || pg_catalog.lpad((t * 100 + u)::text, 12, '0'))::uuid,
               ('00000000-0000-4000-a000-' || pg_catalog.lpad((t * 1000 + d)::text, 12, '0'))::uuid, 'vendedor', now()
          FROM generate_series(1, #{tenants}) t, generate_series(1, 25) u, generate_series(1, 200) d;
    SQL
  end

  def add_actor(company, label, memberships)
    user = SecureRandom.uuid
    as_superuser("INSERT INTO public.users (id, company_id, name, email, created_at) VALUES ($1, $2, 'Ator', $3, now())",
                 [user, company, "#{label}@medicao.invalid"])
    memberships.each do |role, dealers|
      dealers.each do |index|
        as_superuser("INSERT INTO public.memberships (company_id, user_id, dealer_id, role, created_at) VALUES ($1, $2, $3, $4, now())",
                     [company, user, dealer(1000 + index), role])
      end
    end
    user
  end

  def scope_cost
    setup_example('mini_crm_revendas')
    load_dealers
    company = tenant(1)
    # Atores do tenant 1: gerentes com 1, 10 e 100 revendas, um vendedor com 10, um ator com papéis mistos (inclusive os
    # dois papéis na mesma revenda) e um sem vínculos. Os 4.000 leads ficam nas 100 primeiras revendas. Os seis entram na
    # conferência funcional; só os gerentes e o vendedor são temporizados.
    actors = {
      'gerente de 1' => add_actor(company, 'g1', 'gerente' => [1]),
      'gerente de 10' => add_actor(company, 'g10', 'gerente' => (1..10).to_a),
      'gerente de 100' => add_actor(company, 'g100', 'gerente' => (1..100).to_a),
      'vendedor de 10' => add_actor(company, 'v10', 'vendedor' => (11..20).to_a),
      'misto' => add_actor(company, 'misto', 'gerente' => [21, 22, 23], 'vendedor' => [23, 24, 150]),
      'sem vínculos' => add_actor(company, 'nenhum', {})
    }
    insert_leads(company, <<~SQL, [company])
      INSERT INTO public.leads (company_id, dealer_id, name, status, created_at)
        SELECT $1, ('00000000-0000-4000-a000-' || pg_catalog.lpad((1000 + 1 + g % 100)::text, 12, '0'))::uuid, 'Lead ' || g, 'new', now()
          FROM generate_series(1, 4000) g
    SQL
    # Controle sem escopo (só o tenant) e a forma alternativa de leitura, com a mesma semântica da política gerada:
    # gerente ou vendedor da revenda do lead, com a lista de revendas do ator calculada uma vez por instrução.
    script(<<~SQL)
      CREATE SCHEMA bench;
      GRANT USAGE ON SCHEMA bench TO vetra_app;
      CREATE TABLE bench.leads_tenant (LIKE public.leads INCLUDING DEFAULTS INCLUDING CONSTRAINTS);
      INSERT INTO bench.leads_tenant SELECT * FROM public.leads;
      ALTER TABLE bench.leads_tenant ADD PRIMARY KEY (id);
      CREATE INDEX ON bench.leads_tenant (company_id, dealer_id);
      ALTER TABLE bench.leads_tenant ENABLE ROW LEVEL SECURITY;
      ALTER TABLE bench.leads_tenant FORCE ROW LEVEL SECURITY;
      CREATE POLICY vt_tenant ON bench.leads_tenant AS RESTRICTIVE FOR ALL TO vetra_app
        USING (company_id = (SELECT vetra.current_tenant())) WITH CHECK (company_id = (SELECT vetra.current_tenant()));
      CREATE POLICY vt_access ON bench.leads_tenant AS PERMISSIVE FOR ALL TO vetra_app USING (true) WITH CHECK (true);
      GRANT SELECT ON bench.leads_tenant TO vetra_app;
      CREATE TABLE bench.leads_list (LIKE public.leads INCLUDING DEFAULTS INCLUDING CONSTRAINTS);
      INSERT INTO bench.leads_list SELECT * FROM public.leads;
      ALTER TABLE bench.leads_list ADD PRIMARY KEY (id);
      CREATE INDEX ON bench.leads_list (company_id, dealer_id);
      ALTER TABLE bench.leads_list ENABLE ROW LEVEL SECURITY;
      ALTER TABLE bench.leads_list FORCE ROW LEVEL SECURITY;
      CREATE POLICY vt_tenant ON bench.leads_list AS RESTRICTIVE FOR ALL TO vetra_app
        USING (company_id = (SELECT vetra.current_tenant())) WITH CHECK (company_id = (SELECT vetra.current_tenant()));
      CREATE POLICY vt_scope_read ON bench.leads_list AS PERMISSIVE FOR SELECT TO vetra_app
        USING (dealer_id = ANY (ARRAY(SELECT m.dealer_id FROM public.memberships m WHERE m.company_id = (SELECT vetra.current_tenant())
          AND m.user_id = (SELECT vetra.current_actor()) AND m.role IN ('gerente', 'vendedor'))));
      GRANT SELECT ON bench.leads_list TO vetra_app;
    SQL
    # VACUUM não roda dentro da transação implícita de um script com várias instruções.
    script('VACUUM ANALYZE')
    total = as_superuser('SELECT count(*) FROM public.memberships').first['count'].to_i
    expected = { 'gerente de 1' => 40, 'gerente de 10' => 400, 'gerente de 100' => 4000, 'vendedor de 10' => 400,
                 'misto' => 160, 'sem vínculos' => 0 }
    check_case("com #{total} vínculos, a forma alternativa devolve os mesmos leads que a política gerada, para gerente, vendedor, papéis mistos e ator sem vínculos") do
      total >= 1_000_000 && actors.all? do |label, user|
        value = token(company, user)
        generated = as_app('SELECT id FROM public.leads ORDER BY id', 'vetra.ctx', value).flatten
        listed = as_app('SELECT id FROM bench.leads_list ORDER BY id', 'vetra.ctx', value).flatten
        generated == listed && generated.size == expected.fetch(label)
      end
    end
    check_case('os planos das duas formas de escopo não varrem a tabela de vínculos inteira, com 1, 10 e 100 revendas') do
      %w[gerente\ de\ 1 gerente\ de\ 10 gerente\ de\ 100].all? do |label|
        value = token(company, actors.fetch(label))
        %w[public.leads bench.leads_list].none? do |table|
          as_app("EXPLAIN SELECT count(*) FROM #{table}", 'vetra.ctx', value).flatten.join("\n").match?(/Seq Scan on memberships/)
        end
      end
    end
    prepare = ->(_connection, _client) { { token: nil } }
    restore = -> {}
    measured = ['gerente de 1', 'gerente de 10', 'gerente de 100', 'vendedor de 10']
    @report << ''
    @report << "Questão 2 do ADR-023, PostgreSQL #{@admin.server_version}: varredura de leitura dos leads do tenant com escopo " \
               "por vínculo, #{total} vínculos (ms por instrução; mediana de #{@rounds} rodadas, mínimo a máximo)"
    @report << '| Ator | Linhas | Controle, só o tenant | Política gerada | Acréscimo da gerada | Lista do ator | Acréscimo da lista |'
    @report << '|---|---|---|---|---|---|---|'
    generated_extras = []
    measured.each do |label|
      context = ->(state) { ['vetra.ctx', state[:token] ||= token(company, actors.fetch(label))] }
      costs = Hash.new { |hash, key| hash[key] = [] }
      @rounds.times do |round|
        %w[bench.leads_tenant public.leads bench.leads_list].rotate(round).each do |table|
          cost, raw = per_statement(round, restore: restore, context: context, statement: ->(c, _s) { c.exec("SELECT count(*) FROM #{table}") }, &prepare)
          costs[table] << cost
          @detail << "- Q2 #{label}, #{table}, rodada #{round + 1}: #{ms(raw[1].first)} / #{ms(raw[STATEMENTS].first)} (#{raw[1].last} / #{raw[STATEMENTS].last})"
        end
      end
      generated = costs['public.leads'].zip(costs['bench.leads_tenant']).map { |a, b| a - b }
      listed = costs['bench.leads_list'].zip(costs['bench.leads_tenant']).map { |a, b| a - b }
      generated_extras.concat(generated)
      range = ->(values) { "#{ms(median(values))} (#{ms(values.min)} a #{ms(values.max)})" }
      delta = ->(values) { "#{signed(median(values))} (#{signed(values.min)} a #{signed(values.max)})" }
      @report << "| #{label} | #{expected.fetch(label)} | #{range.(costs['bench.leads_tenant'])} | #{range.(costs['public.leads'])} | " \
                 "#{delta.(generated)} | #{range.(costs['bench.leads_list'])} | #{delta.(listed)} |"
    end
    threshold('ADR-023, questão 2: acréscimo da política de escopo gerada sobre o controle, leitura', generated_extras, SCOPE_LIMIT_MS, 'ms por instrução')
    records_gate(company)
  end

  # ADR-022, §3: construir os registros não pode custar mais de 10% do tempo da consulta que os trouxe. É uma
  # aproximação do cenário do ADR: o lead do CRM com revendas tem 9 campos lógicos e 10 colunas, não 10 campos.
  def records_gate(_company)
    other = tenant(2)
    manager = SecureRandom.uuid
    as_superuser("INSERT INTO public.users (id, company_id, name, email, created_at) VALUES ($1, $2, 'Gerente', 'gate@medicao.invalid', now())",
                 [manager, other])
    as_superuser(<<~SQL, [other, manager])
      INSERT INTO public.memberships (company_id, user_id, dealer_id, role, created_at)
        VALUES ($1, $2, '00000000-0000-4000-a000-000000002001', 'gerente', now())
    SQL
    insert_leads(other, <<~SQL, [other])
      INSERT INTO public.leads (company_id, dealer_id, name, email, status, valor_amount, valor_currency, created_at)
        SELECT $1, '00000000-0000-4000-a000-000000002001', 'Lead ' || g, 'lead' || g || '@medicao.invalid', 'new', 123.45, 'BRL', now()
          FROM generate_series(1, 10000) g
    SQL
    script('ANALYZE public.leads')
    open_runtime
    work = Vetra::Data::UnitOfWork.new(@runtime, issuer: @issuer)
    catalog = Vetra::Data::Repositories.new(@linked.document)
    claims = { tenant_id: other, actor_id: manager, cmd: 'crm.read_lead' }
    query, build = [], []
    7.times do
      work.read(**claims.merge(op_id: SecureRandom.uuid)) do |unit|
        unit.access(multi_tenant: true) do |db|
          began = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          rows = db[Sequel[:public][:leads]].where(company_id: other).order(:id).all
          query << (Process.clock_gettime(Process::CLOCK_MONOTONIC) - began)
          raise 'consulta incompleta' unless rows.size == 10_000
        end
        repository = catalog.bind('crm.leads_read', unit: unit)
        began = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        records = repository.all
        build << (Process.clock_gettime(Process::CLOCK_MONOTONIC) - began)
        raise 'registros incompletos' unless records.size == 10_000 && Ractor.shareable?(records.first)
      end
    end
    query_ms, total_ms = median(query) * 1000, median(build) * 1000
    construction = total_ms - query_ms
    ratio = construction / query_ms
    @report << ''
    @report << "Gate do ADR-022, §3 (aproximação: 9 campos lógicos, 10 colunas), Ruby #{RUBY_VERSION}, PostgreSQL #{@admin.server_version}: " \
               '10.000 leads, mediana de 7'
    @report << '| Consulta (Sequel) | Repositório (consulta e registros) | Construção dos registros | Construção / consulta | Limiar |'
    @report << '|---|---|---|---|---|'
    @report << "| #{format('%.1f', query_ms).tr('.', ',')} ms | #{format('%.1f', total_ms).tr('.', ',')} ms | " \
               "#{format('%.1f', construction).tr('.', ',')} ms | #{format('%.0f', ratio * 100)}% | #{(RECORDS_LIMIT * 100).round}% |"
    ratios = (0...query.size).map { |index| (build[index] - query[index]) / query[index] * 100 }
    threshold('ADR-022, §3: construção dos registros sobre a consulta, por execução', ratios, RECORDS_LIMIT * 100, '%')
  ensure
    close_runtime
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    exit(ContextCostProbe.new(ENV.fetch('DATABASE_URL')).run ? 0 : 1)
  rescue StandardError => error
    warn "FALHA: medição interrompida (#{error.class})."
    exit 1
  end
end

#!/usr/bin/env ruby
# Medição das saídas para o custo da política vt_system (ADR-024, §4; ADR-023, questão 1), num PostgreSQL 17/18 descartável com o
# bootstrap do ADR-036 pronto. DATABASE_URL administrativa; VETRA_APP_PASSWORD: senha do login real vetra_app.
# VETRA_MEDICAO_AMOSTRAS (padrão 120), VETRA_MEDICAO_SEGUNDOS (padrão 3) e VETRA_MEDICAO_RODADAS (padrão 3), como na K20.
#
# Mede, no CRM com revendas, pelo Runner e com o gerente de 10 revendas (o ator comum), os quatro comandos de referência da K20 em
# quatro variantes das políticas de linha, reescritas no lugar sobre o banco migrado:
#   atual         as políticas como o gerador as emite hoje (vt_scope + vt_system, três funções de contexto);
#   papel         saída 1: o ator de sistema ganha um papel de banco próprio; as políticas de escopo ficam só para vetra_app, e a
#                 permissiva do papel de sistema não existe para o ator comum (a política `vt_system` sai);
#   unica         saída 2: uma função única, vetra.context(), valida o token uma vez por referência e devolve (tenant, ator, sistema);
#                 as referências a tenant e a ator na mesma subconsulta de escopo passam a ser uma chamada só;
#   papel+unica   as duas.
# É um PROTÓTIPO DE MEDIÇÃO: reescreve só as políticas (pg_policies), não as funções de gatilho (vt_authz_*, vt_transition_*), que seguem
# chamando as funções de contexto, e não implementa o papel de banco nem o plano de migração de nenhuma saída. Não cumpre o teste de
# aceitação 6 do ADR-023, não muda limiar e não decide a saída: relata, por comando, as validações contadas pelo banco e a latência.
require_relative 'medir_executor'

class SystemExitProbe < ExecutorCostProbe
  FUNCTIONS = %w[current_tenant current_actor is_system_actor context].freeze
  VARIANTS = %w[atual papel unica papel+unica].freeze
  COMMANDS = %w[crm.read_lead crm.update_lead crm.create_lead crm.win_lead].freeze
  HIDDEN_DEALER = '00000000-0000-4000-a000-000000001099'
  CONTEXT_REFERENCE = /FROM (\S+) (vt_scope_(\d+))\n|\( SELECT vetra\.(current_tenant|current_actor|is_system_actor)\(\) AS \4\)/
  CONTEXT_PATTERN = /vetra\.(current_tenant|current_actor|is_system_actor)\(\)/

  def run
    @admin = PG.connect(@url)
    @admin.exec('SET client_min_messages = warning')
    @admin.exec(Vetra::SQL::Context.role_guard)
    @seconds = Float(ENV.fetch('VETRA_MEDICAO_SEGUNDOS', '3'))
    @rounds = Integer(ENV.fetch('VETRA_MEDICAO_RODADAS', '3'))
    @samples = Integer(ENV.fetch('VETRA_MEDICAO_AMOSTRAS', '120'))
    @report, @detail, @thresholds, @rows, @notes = [], [], [], [], []
    @latency = Hash.new { |hash, key| hash[key] = [] }
    @counts = {}
    before = roles
    start_example('mini_crm_revendas', true)
    load_scope_data
    script('ANALYZE')
    install_context_function
    @originals = policy_snapshot
    check('o instantâneo traz as políticas que chamam as funções de contexto, e a vt_system de cada tabela de escopo') do
      @originals.any? { |p| p['policyname'] == 'vt_system' } && @originals.count { |p| p['policyname'] == 'vt_tenant' } >= 3
    end
    call_costs
    measure_variants
    check('nenhum papel global mudou') { roles == before }
    print_report
    puts "#{@results.count(true)}/#{@results.size} verificações passaram (PostgreSQL #{@admin.server_version})."
    @results.all?
  ensure
    close_pools
    if @admin
      @databases.reverse_each { |name| @admin.exec("DROP DATABASE IF EXISTS #{PG::Connection.quote_ident(name)} WITH (FORCE)") }
      @admin.close
    end
  end

  private

  # ---- a função única -----------------------------------------------------------------------------------------------------------

  # O mesmo corpo de vetra.is_system_actor() (ADR-036, ADR-024 §4), com a validação inteira uma vez e a devolução dos três valores:
  # só a saída muda. Falha fechada: tenant e ator nulos e is_system falso.
  def context_body
    body = Vetra::SQL::Context.body('system_actor', system_actor: true)
    body = body.gsub('RETURN false;', 'is_system := false; RETURN;')
    success = "RETURN payload ? 'system_actor';"
    raise 'o corpo de is_system_actor mudou; ajuste a função única da medição' unless body.include?(success)
    body.sub(success, "tenant := (payload->>'tenant_id')::uuid;\n    actor := CASE WHEN payload ? 'actor_id' THEN (payload->>'actor_id')::uuid END;\n    " \
                      "is_system := payload ? 'system_actor';\n    RETURN;")
  end

  def install_context_function
    script(<<~SQL)
      CREATE FUNCTION vetra.context(OUT tenant uuid, OUT actor uuid, OUT is_system boolean) LANGUAGE plpgsql STABLE SECURITY DEFINER PARALLEL UNSAFE
        SET search_path = pg_catalog, pg_temp AS $vetra_context$#{context_body}$vetra_context$;
      ALTER FUNCTION vetra.context() OWNER TO vetra_owner;
      REVOKE ALL ON FUNCTION vetra.context() FROM PUBLIC, vetra_app;
      GRANT EXECUTE ON FUNCTION vetra.context() TO vetra_app;
    SQL
    # O emissor recusa um contexto sem ator e sem ator de sistema (data_context), então o visitante não é um caso que a função possa receber.
    check('a função única devolve o mesmo que as três: ator comum, ator de sistema e token inválido') do
      common = token(tenant(1), manager)
      system = @issuer.issue(tenant_id: tenant(1), system_actor: 'crm.notify_seller', op_id: SecureRandom.uuid, cmd: 'crm.win_lead').value
      [common, system, 'lixo'].all? do |value|
        one = as_app('SELECT current_tenant, current_actor, is_system_actor FROM (SELECT vetra.current_tenant(), vetra.current_actor(), vetra.is_system_actor()) t(current_tenant, current_actor, is_system_actor)', 'vetra.ctx', value).first
        all = as_app('SELECT tenant, actor, is_system FROM vetra.context()', 'vetra.ctx', value).first
        one == all
      end
    end
  end

  # Custo de uma chamada de vetra.context() sobre a ingênua, com um e com 16 clientes, no método de validation_cost.
  def call_costs
    validation_cost
    validation_cost_concurrent
    @context_us = single_call_cost('(vetra.context()).tenant')
    @context_us_16 = concurrent_call_cost('(vetra.context()).tenant')
    @report << "- Uma chamada de vetra.context(): #{ms(@context_us)} µs com um cliente e #{ms(@context_us_16)} µs com #{CLIENTS} clientes " \
               "(vetra.current_tenant: #{ms(@validation_us)} e #{ms(@validation_us_16)} µs)."
    check_case('o contador do banco confere para a função única: três chamadas conhecidas contam três') do
      with_tracking do
        counter = app_connection
        value = token(tenant(1), manager)
        read = -> { counter.exec('SELECT pg_stat_force_next_flush()'); @connection.exec('SELECT pg_stat_clear_snapshot()'); @connection.exec("SELECT coalesce(sum(calls), 0)::bigint FROM pg_stat_user_functions WHERE schemaname = 'vetra' AND funcname = 'context'").getvalue(0, 0).to_i }
        before = read.call
        counter.exec('BEGIN')
        counter.exec_params('SELECT pg_catalog.set_config($1, $2, true)', ['vetra.ctx', value])
        3.times { counter.exec('SELECT tenant FROM vetra.context()') }
        counter.exec('COMMIT')
        delta = read.call - before
        counter.close
        delta == 3
      end
    end
  end

  def single_call_cost(expression)
    connection = app_connection
    value = token(tenant(1), SecureRandom.uuid)
    rows = 20_000
    signed_sql = "SELECT count(*) FROM generate_series(1, #{rows}) g WHERE g < 0 OR #{expression} IS NOT NULL"
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
      (round.even? ? %i[signed naive] : %i[naive signed]).each do |kind|
        kind == :signed ? signed << run.(signed_sql, 'vetra.ctx', value) : naive << run.(naive_sql, 'bench.tenant', tenant(1))
      end
    end
    (median(signed) - median(naive)) / rows * 1000
  ensure
    connection&.close
  end

  def concurrent_call_cost(expression)
    rows = 200
    saved = @seconds
    @seconds = [@seconds, 2.0].max
    prepare = lambda do |_connection, client|
      tenant_id = tenant(client + 1)
      { tenant: tenant_id, token: token(tenant_id, uuid('9000', client + 1), 'crm.read_lead') }
    end
    contexts = { signed: ->(state) { ['vetra.ctx', state[:token]] }, naive: ->(state) { ['bench.tenant', state[:tenant]] } }
    statements = {
      signed: ->(c, _s) { c.exec("SELECT count(*) FROM generate_series(1, #{rows}) g WHERE g < 0 OR #{expression} IS NOT NULL") },
      naive: ->(c, _s) { c.exec("SELECT count(*) FROM generate_series(1, #{rows}) g WHERE g < 0 OR pg_catalog.current_setting('bench.tenant', true)::uuid IS NOT NULL") }
    }
    costs = { signed: [], naive: [] }
    @rounds.times do |round|
      %i[signed naive].rotate(round).each do |kind|
        cost, = per_statement(round, restore: -> {}, context: contexts.fetch(kind), statement: statements.fetch(kind), &prepare)
        costs[kind] << cost
      end
    end
    median(costs[:signed].zip(costs[:naive]).map { |with, without| (with - without) / rows * 1000 })
  ensure
    @seconds = saved
  end

  # ---- as variantes das políticas -----------------------------------------------------------------------------------------------

  def policy_snapshot
    as_superuser(<<~SQL)
      SELECT schemaname, tablename, policyname, permissive, array_to_string(roles, ',') AS roles, cmd, qual, with_check
        FROM pg_policies
       WHERE schemaname IN ('public', 'vetra') AND (qual ~ 'vetra\\.(current_tenant|current_actor|is_system_actor)' OR with_check ~ 'vetra\\.(current_tenant|current_actor|is_system_actor)')
       ORDER BY schemaname, tablename, policyname
    SQL
  end

  # A forma da função única: dentro de uma subconsulta de escopo (`FROM memberships vt_scope_N`), tenant e ator saem de uma chamada só,
  # por um FROM vetra.context(); fora dela, cada referência vira um escalar de uma chamada.
  def single_function(text)
    return text if text.nil?
    scope = nil
    text.gsub(CONTEXT_REFERENCE) do
      match = Regexp.last_match
      if match[2]
        scope = match[3]
        "FROM #{match[1]} #{match[2]}, vetra.context() vt_ctx_#{scope}\n"
      else
        field = { 'current_tenant' => 'tenant', 'current_actor' => 'actor', 'is_system_actor' => 'is_system' }.fetch(match[4])
        scope && field != 'is_system' ? "vt_ctx_#{scope}.#{field}" : "( SELECT c.#{field} FROM vetra.context() c)"
      end
    end
  end

  def apply_variant(variant)
    drop_system = variant.start_with?('papel')
    single = variant.end_with?('unica')
    statements = @originals.map do |policy|
      table = "#{PG::Connection.quote_ident(policy['schemaname'])}.#{PG::Connection.quote_ident(policy['tablename'])}"
      name = PG::Connection.quote_ident(policy['policyname'])
      drop = "DROP POLICY IF EXISTS #{name} ON #{table};"
      next drop if drop_system && policy['policyname'] == 'vt_system' && policy['schemaname'] == 'public'
      qual = single ? single_function(policy['qual']) : policy['qual']
      check = single ? single_function(policy['with_check']) : policy['with_check']
      sql = +"CREATE POLICY #{name} ON #{table} AS #{policy['permissive']} FOR #{policy['cmd']} TO #{policy['roles'].split(',').map { |role| PG::Connection.quote_ident(role) }.join(', ')}"
      sql << " USING (#{qual})" if qual && !qual.empty?
      sql << " WITH CHECK (#{check})" if check && !check.empty?
      "#{drop} #{sql};"
    end
    script(statements.join("\n"))
    script('ANALYZE')
  end

  # ---- a medição ----------------------------------------------------------------------------------------------------------------

  def series(operation, who, builder)
    samples = []
    (WARMUP + @samples).times do |index|
      began = clock
      outcome = @runner.run(operation, builder.call(index), credentials: who)
      elapsed = (clock - began) * 1000
      raise "#{operation} falhou: #{outcome.status} #{outcome.code}" unless outcome.ok?
      samples << elapsed if index >= WARMUP
    end
    samples
  end

  def measure_variants
    dealer = uuid('a000', 1001)
    who = identity(tenant: tenant(1), actor: manager, roles: ['crm.gerente'])
    # Leads de outro tenant, para que o isolamento do ator de sistema e do ator comum seja uma conferência com linhas de verdade.
    insert_leads(tenant(2), "INSERT INTO public.leads (company_id, dealer_id, name, status, created_at) SELECT $1, '#{uuid('a000', 2001)}', 'Outro ' || g, 'new', now() FROM generate_series(1, 5) g", [tenant(2)])
    # Uma revenda do tenant 1 sem vínculo com o gerente, com leads: prova a restrição por revenda, e não só a por tenant.
    script("INSERT INTO public.dealers (id, company_id, name, created_at) VALUES ('#{HIDDEN_DEALER}', '#{tenant(1)}', 'Revenda sem vínculo', now())")
    insert_leads(tenant(1), "INSERT INTO public.leads (company_id, dealer_id, name, status, created_at) SELECT $1, '#{HIDDEN_DEALER}', 'Escondido ' || g, 'new', now() FROM generate_series(1, 5) g", [tenant(1)])
    @rounds.times do |round|
      VARIANTS.rotate(round).each do |variant|
        apply_variant(variant)
        open_pools(true)
        needed = WARMUP + @samples + 3
        ids = seed_leads(needed + 1, dealer: dealer)
        check_variant(variant) if round.zero?
        fixed = ids.first
        wins = ids.drop(1)
        builders = {
          'crm.read_lead' => ->(_) { { id: fixed } },
          'crm.update_lead' => ->(index) { { id: fixed, name: "Cliente #{index}" } },
          'crm.create_lead' => ->(index) { { name: "Novo #{index}", dealer_id: dealer } },
          'crm.win_lead' => ->(index) { { lead_id: wins.fetch(index) } }
        }
        builders.each do |operation, builder|
          @latency[[variant, operation]] << median(series(operation, who, builder))
          next unless round.zero?
          by_function, ops, edge = counted(operation, who, builder.call(WARMUP + @samples), builder.call(WARMUP + @samples + 1), false)
          @counts[[variant, operation]] = { by_function: by_function, ops: ops, edge: edge }
        end
        close_pools
      end
    end
    apply_variant('atual')
  end

  # Os IDs que cada ator enxerga em public.leads, como vetra_app com o contexto assinado dele.
  def visible_ids
    system = @issuer.issue(tenant_id: tenant(1), system_actor: 'crm.notify_seller', op_id: SecureRandom.uuid, cmd: 'crm.win_lead').value
    { common: token(tenant(1), manager), stranger: token(tenant(1), SecureRandom.uuid), system: system }.transform_values do |value|
      as_app('SELECT id::text FROM public.leads ORDER BY id', 'vetra.ctx', value).flatten
    end
  end

  # O esperado vem do superusuário no momento da conferência, por conjunto de IDs: o gerente tem vínculo com as dez primeiras revendas do
  # tenant 1 e com nenhuma outra, e o tenant 1 tem uma revenda sem vínculo com leads (`HIDDEN_DEALER`); o ator sem vínculo não lê nada; o de
  # sistema lê o tenant 1 inteiro, inclusive a revenda sem vínculo, e nenhuma linha do tenant 2, onde a permissiva existe.
  def check_variant(variant)
    seen = visible_ids
    linked = as_superuser('SELECT id::text FROM public.leads WHERE company_id = $1 AND dealer_id <> $2 ORDER BY id', [tenant(1), HIDDEN_DEALER]).map { |row| row['id'] }
    own = as_superuser('SELECT id::text FROM public.leads WHERE company_id = $1 ORDER BY id', [tenant(1)]).map { |row| row['id'] }
    hidden = own - linked
    others = as_superuser('SELECT count(*)::int AS n FROM public.leads WHERE company_id <> $1', [tenant(1)]).first['n'].to_i
    check_case("variante #{variant}: o ator comum lê exatamente os #{linked.size} leads das revendas com vínculo, nenhum dos #{hidden.size} da revenda sem vínculo nem dos #{others} de outro tenant, e o ator sem vínculo não lê nada") do
      !hidden.empty? && others.positive? && !linked.empty? && seen[:common] == linked && seen[:stranger].empty?
    end
    papel = variant.start_with?('papel')
    check_case("variante #{variant}: o ator de sistema #{papel ? 'não alcança linha como vetra_app (a permissiva é do papel próprio, não medido aqui)' : "lê exatamente os #{own.size} leads do tenant do evento, inclusive a revenda sem vínculo, e nenhum de outro tenant"}") do
      seen[:system] == (papel ? [] : own)
    end
    shape = as_superuser("SELECT count(*)::int AS n FROM pg_policies WHERE schemaname = 'public' AND tablename = 'leads' AND (qual ~ 'vetra\\.context' OR with_check ~ 'vetra\\.context')").first['n'].to_i
    check_case("variante #{variant}: as políticas de leads #{variant.end_with?('unica') ? 'usam' : 'não usam'} vetra.context()") do
      variant.end_with?('unica') ? shape.positive? : shape.zero?
    end
  end

  # ---- relatório ----------------------------------------------------------------------------------------------------------------

  def per_call_cost(by_function)
    ordinary = by_function.slice('current_tenant', 'current_actor', 'is_system_actor').values.sum
    (ordinary * @validation_us_16 + by_function.fetch('context') * @context_us_16) / 1000.0
  end

  def print_report
    puts "Saídas para o custo da vt_system, CRM com revendas, gerente de 10 revendas, pelo Runner, um cliente, #{@samples} chamadas medidas após #{WARMUP} de " \
         "aquecimento, #{@rounds} rodadas em ordem girada, PostgreSQL #{@admin.server_version}, Ruby #{RUBY_VERSION}"
    puts @report
    puts "Acréscimo = validações × custo por chamada com #{CLIENTS} clientes ÷ mediana do comando (a regra da K20); a coluna de ms é o numerador."
    puts '| Variante | Comando | tenant / ator / sistema / única | Validações | Chamadas de ms (16 clientes) | Mediana (ms; rodadas) | Acréscimo | Δ validações vs atual | Δ mediana vs atual |'
    puts '|---|---|---|---|---|---|---|---|---|'
    percents = Hash.new { |hash, key| hash[key] = [] }
    VARIANTS.each do |variant|
      COMMANDS.each do |operation|
        count = @counts.fetch([variant, operation])[:by_function]
        base = @counts.fetch(['atual', operation])[:by_function]
        median_ms = median(@latency[[variant, operation]])
        base_median = median(@latency[['atual', operation]])
        cost = per_call_cost(count)
        percent = cost / median_ms * 100
        percents[variant] << percent
        total = count.values.sum
        puts "| #{variant} | #{operation} | #{FUNCTIONS.map { |name| count.fetch(name) }.join(' / ')} | #{total} | #{ms(cost)} | " \
             "#{ms(median_ms)} (#{ms(@latency[[variant, operation]].min)} a #{ms(@latency[[variant, operation]].max)}) | #{ms(percent)}% | " \
             "#{format('%+d', total - base.values.sum)} | #{signed(median_ms - base_median)} ms |"
      end
    end
    VARIANTS.each do |variant|
      threshold("ADR-023, variante #{variant}: acréscimo das validações sobre a latência de cada comando, custo de #{CLIENTS} clientes", percents[variant], CONTEXT_LIMIT, '%')
    end
    @notes.each { |note| puts "- #{note}" }
    puts ''
    puts 'Limiares (hipóteses dos ADRs). Medição informativa: não cumpre o teste de aceitação 6 do ADR-023 e não decide a saída da vt_system.'
    puts @thresholds
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    exit(SystemExitProbe.new(ENV.fetch('DATABASE_URL')).run ? 0 : 1)
  rescue StandardError => error
    warn "FALHA: medição das saídas da vt_system interrompida (#{error.class}: #{error.message.lines.first&.strip})"
    warn error.backtrace.first(6).join("\n") if ENV['VETRA_SONDA_DEBUG']
    exit 1
  end
end

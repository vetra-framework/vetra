#!/usr/bin/env ruby
# Medição da K14 (ADR-041): a forma da política de escopo por vínculo, por ação, num PostgreSQL 17/18 descartável, com o
# bootstrap do ADR-036 pronto; DATABASE_URL administrativa. VETRA_APP_PASSWORD: senha do login real vetra_app.
# VETRA_MEDICAO_SEGUNDOS (padrão 2) e VETRA_MEDICAO_RODADAS (padrão 3). Aplica os planos do CRM com revendas pelo
# db:migrate, carrega 1 milhão de vínculos e mede como vetra_app, com 16 clientes em processos próprios.
#
# Compara, para cada ação, seis variantes da mesma tabela `leads`, sem os triggers de transição:
#   f0  só a política de tenant (controle de custo, não é uma forma equivalente);
#   f1  a política gerada hoje: um EXISTS correlacionado com a linha, por papel;
#   f2  a lista do ator calculada uma vez por instrução: dealer_id = ANY (ARRAY(SELECT ...));
#   f3  a mesma lista como subconsulta não correlacionada: dealer_id IN (SELECT ...);
#   f4  a tabela materializada do escopo efetivo do ADR-023, consultada como f1;
#   f5  um único EXISTS correlacionado, com os papéis juntos em `role IN (...)`;
#   f6  calibração: a f5 mais duas referências inúteis ao tenant, para medir o custo de cada chamada de contexto.
# As referências ao contexto por SELECT são 1 (f0), 5 (f1 e f6) e 3 (f2 a f5): cada uma revalida o token (ADR-024, §4).
# Antes de medir, confere por CONJUNTO DE IDs que f1 a f6 dão as mesmas permissões que a política real do plano, por
# ação (ler, inserir, atualizar, apagar) e por ator (gerente, vendedor, papéis mistos e sem vínculos). As quatro ações
# rodam contra a tabela real e contra cada variante, e o UPDATE compara também a mudança de unidade (OLD e NEW). Falha só nas
# conferências funcionais: os limiares são relatados e o gate do teste 6 do ADR-023 continua pendente.
require_relative 'sonda_custo_contexto'

class ScopeFormsProbe < ContextCostProbe
  FORMS = %w[f0 f1 f2 f3 f4 f5 f6].freeze
  SCOPED = %w[f1 f2 f3 f4 f5 f6].freeze
  ACTION_ROLES = { 'read' => %w[gerente vendedor], 'create' => %w[gerente vendedor], 'update' => %w[gerente vendedor],
                   'delete' => %w[gerente] }.freeze
  SAMPLE_DEALERS = ((1..120).to_a + [150]).freeze

  def run
    @admin = PG.connect(@url)
    @admin.exec('SET client_min_messages = warning')
    @admin.exec(Vetra::SQL::Context.role_guard)
    @seconds = Float(ENV.fetch('VETRA_MEDICAO_SEGUNDOS', '2'))
    @rounds = Integer(ENV.fetch('VETRA_MEDICAO_RODADAS', '3'))
    @report, @detail, @thresholds = [], [], []
    before = roles
    prepare_scope_database
    equivalence_checks
    measure_actions
    check('nenhum papel global mudou') { roles == before }
    puts @report
    puts ''
    puts 'Limiares (hipótese de 1 ms por instrução do ADR-023, questão 2; medição informativa, o teste 6 continua pendente):'
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

  def quote_name(name)
    PG::Connection.quote_ident(name)
  end

  def form_table(form)
    "bench.leads_#{form}"
  end

  def indexes(list)
    list.map { |index| dealer(1000 + index) }
  end

  def prepare_scope_database
    setup_example('mini_crm_revendas')
    load_dealers
    @company = tenant(1)
    # Atores do tenant 1. Os 4.000 leads ficam nas 100 primeiras revendas, 40 em cada.
    @dealers_of = {
      'gerente de 1' => { 'gerente' => [1] }, 'gerente de 10' => { 'gerente' => (1..10).to_a },
      'gerente de 100' => { 'gerente' => (1..100).to_a }, 'gerente de 1000' => { 'gerente' => (1..1000).to_a },
      'vendedor de 10' => { 'vendedor' => (11..20).to_a },
      'misto' => { 'gerente' => [21, 22, 23], 'vendedor' => [23, 24, 150] }, 'sem vínculos' => {}
    }
    # Revendas além das 200 de cada tenant, só para o ator de 1.000 unidades: elas não têm leads.
    script("INSERT INTO public.dealers (id, company_id, name, created_at) SELECT ('00000000-0000-4000-a000-' || pg_catalog.lpad((1000 + g)::text, 12, '0'))::uuid, '#{@company}', 'Revenda extra', now() FROM generate_series(201, 1000) g")
    @actors = @dealers_of.to_h { |label, memberships| [label, add_actor(@company, label.tr(' ', '-'), memberships)] }
    insert_leads(@company, <<~SQL, [@company])
      INSERT INTO public.leads (company_id, dealer_id, name, status, created_at)
        SELECT $1, ('00000000-0000-4000-a000-' || pg_catalog.lpad((1000 + 1 + g % 100)::text, 12, '0'))::uuid, 'Lead ' || g, 'new', now()
          FROM generate_series(1, 4000) g
    SQL
    script('CREATE SCHEMA bench')
    script('GRANT USAGE ON SCHEMA bench TO vetra_app')
    script(<<~SQL)
      CREATE TABLE bench.scope_rw AS SELECT DISTINCT company_id, user_id, dealer_id FROM public.memberships WHERE role IN ('gerente', 'vendedor');
      ALTER TABLE bench.scope_rw ADD PRIMARY KEY (company_id, user_id, dealer_id);
      CREATE TABLE bench.scope_g AS SELECT DISTINCT company_id, user_id, dealer_id FROM public.memberships WHERE role = 'gerente';
      ALTER TABLE bench.scope_g ADD PRIMARY KEY (company_id, user_id, dealer_id);
      GRANT SELECT ON bench.scope_rw, bench.scope_g TO vetra_app;
    SQL
    FORMS.each { |form| create_form(form) }
    script('VACUUM ANALYZE')
  end

  def condition(form, table, roles)
    tenant = '(SELECT vetra.current_tenant())'
    actor = '(SELECT vetra.current_actor())'
    column = "#{quote_name(table)}.#{quote_name('dealer_id')}"
    list_roles = roles.map { |role| "'#{role}'" }.join(', ')
    case form
    when 'f1'
      # Como a política gerada pelo plano: um EXISTS correlacionado por papel, unidos por OR.
      roles.sort.map do |role|
        "(EXISTS (SELECT 1 FROM public.memberships AS m WHERE (m.company_id = #{tenant}) AND (m.dealer_id = #{column}) AND ((m.role = '#{role}') AND (m.user_id = #{actor}))))"
      end.join(' OR ')
    when 'f2'
      "#{column} = ANY (ARRAY(SELECT m.dealer_id FROM public.memberships AS m WHERE m.company_id = #{tenant} AND m.user_id = #{actor} AND m.role IN (#{list_roles})))"
    when 'f3'
      "#{column} IN (SELECT m.dealer_id FROM public.memberships AS m WHERE m.company_id = #{tenant} AND m.user_id = #{actor} AND m.role IN (#{list_roles}))"
    when 'f5'
      "(EXISTS (SELECT 1 FROM public.memberships AS m WHERE (m.company_id = #{tenant}) AND (m.dealer_id = #{column}) AND (m.role IN (#{list_roles})) AND (m.user_id = #{actor})))"
    when 'f6'
      "((EXISTS (SELECT 1 FROM public.memberships AS m WHERE (m.company_id = #{tenant}) AND (m.dealer_id = #{column}) AND (m.role IN (#{list_roles})) AND (m.user_id = #{actor}))) AND #{tenant} IS NOT NULL AND #{tenant} IS NOT NULL)"
    when 'f4'
      source = roles.include?('vendedor') ? 'bench.scope_rw' : 'bench.scope_g'
      "EXISTS (SELECT 1 FROM #{source} AS s WHERE s.company_id = #{tenant} AND s.user_id = #{actor} AND s.dealer_id = #{column})"
    end
  end

  def create_form(form)
    table = form_table(form)
    name = "leads_#{form}"
    script(<<~SQL)
      CREATE TABLE #{table} (LIKE public.leads INCLUDING DEFAULTS INCLUDING CONSTRAINTS);
      INSERT INTO #{table} SELECT * FROM public.leads;
      ALTER TABLE #{table} ADD PRIMARY KEY (id);
      CREATE INDEX ON #{table} (company_id, dealer_id);
      GRANT SELECT, INSERT, UPDATE, DELETE ON #{table} TO vetra_app;
      ALTER TABLE #{table} ENABLE ROW LEVEL SECURITY;
      ALTER TABLE #{table} FORCE ROW LEVEL SECURITY;
      CREATE POLICY vt_tenant ON #{table} AS RESTRICTIVE FOR ALL TO vetra_app
        USING (company_id = (SELECT vetra.current_tenant())) WITH CHECK (company_id = (SELECT vetra.current_tenant()));
    SQL
    if form == 'f0'
      script("CREATE POLICY vt_access ON #{table} AS PERMISSIVE FOR ALL TO vetra_app USING (true) WITH CHECK (true)")
      return
    end
    read, create, update, delete = %w[read create update delete].map { |action| condition(form, name, ACTION_ROLES.fetch(action)) }
    script(<<~SQL)
      CREATE POLICY vt_scope_read ON #{table} AS PERMISSIVE FOR SELECT TO vetra_app USING (#{read});
      CREATE POLICY vt_scope_create ON #{table} AS PERMISSIVE FOR INSERT TO vetra_app WITH CHECK (#{create});
      CREATE POLICY vt_scope_update ON #{table} AS PERMISSIVE FOR UPDATE TO vetra_app USING (#{update}) WITH CHECK (#{update});
      CREATE POLICY vt_scope_delete ON #{table} AS PERMISSIVE FOR DELETE TO vetra_app USING (#{delete});
    SQL
  end

  # O que cada ação alcança, como vetra_app, sempre em transação desfeita: conjuntos de IDs e de revendas, e, no UPDATE,
  # também o resultado da mudança de unidade (OLD pelo USING, NEW pelo WITH CHECK).
  def reachable(table, actor, action)
    value = token(@company, @actors.fetch(actor))
    case action
    when 'read' then as_app("SELECT id::text FROM #{table} ORDER BY id", 'vetra.ctx', value).flatten
    when 'update'
      { 'rows' => as_app("UPDATE #{table} SET name = name RETURNING id::text", 'vetra.ctx', value).flatten.sort,
        'moves' => moves(table, value, move_cases(actor)) }
    when 'delete' then as_app("DELETE FROM #{table} RETURNING id::text", 'vetra.ctx', value).flatten.sort
    when 'create' then insertable(table, value)
    end
  end

  # Pares (revenda de origem, revenda de destino) de um UPDATE da unidade do lead: origem permitida e proibida, destino
  # permitido, proibido e nulo (:null, sempre recusado: a coluna é NOT NULL).
  def move_cases(actor)
    allowed = allowed_dealers(actor, 'update')
    old_allowed = allowed.find { |index| index <= 100 }
    old_forbidden = (1..100).find { |index| !allowed.include?(index) }
    new_allowed = allowed.find { |index| index <= 200 && index != old_allowed } || old_allowed
    new_forbidden = (1..200).find { |index| !allowed.include?(index) }
    cases = []
    [[old_allowed, [new_allowed, new_forbidden, :null]], [old_forbidden, [new_allowed, new_forbidden]]].each do |old, news|
      next unless old
      news.compact.each { |new| cases << [old, new] }
    end
    cases.uniq
  end

  def allowed_dealers(actor, action)
    roles = ACTION_ROLES.fetch(action)
    @dealers_of.fetch(actor).select { |role, _| roles.include?(role) }.values.flatten.uniq.sort
  end

  def lead_of(dealer_number)
    as_superuser('SELECT id::text FROM public.leads WHERE company_id = $1 AND dealer_id = $2 ORDER BY id LIMIT 1',
                 [@company, dealer(1000 + dealer_number)]).first.fetch('id')
  end

  def moves(table, value, cases)
    connection = app_connection
    connection.exec('BEGIN')
    connection.exec_params('SELECT pg_catalog.set_config($1, $2, true)', ['vetra.ctx', value])
    cases.map do |old, new|
      connection.exec('SAVEPOINT mudanca')
      target = new == :null ? 'NULL' : "'#{dealer(1000 + new)}'"
      outcome = begin
        connection.exec("UPDATE #{table} SET dealer_id = #{target} WHERE id = '#{lead_of(old)}' RETURNING id").ntuples
      rescue PG::Error
        'erro'
      end
      connection.exec('ROLLBACK TO SAVEPOINT mudanca')
      [old, new, outcome]
    end
  ensure
    connection&.exec('ROLLBACK') rescue nil
    connection&.close
  end

  def insertable(table, value)
    connection = app_connection
    allowed = []
    connection.exec('BEGIN')
    connection.exec_params('SELECT pg_catalog.set_config($1, $2, true)', ['vetra.ctx', value])
    SAMPLE_DEALERS.each do |index|
      connection.exec('SAVEPOINT tentativa')
      begin
        connection.exec_params("INSERT INTO #{table} (company_id, dealer_id, name, status, created_at) VALUES ($1, $2, 'Tentativa', 'new', now())",
                               [@company, dealer(1000 + index)])
        allowed << index
        connection.exec('RELEASE SAVEPOINT tentativa')
      rescue PG::Error
        connection.exec('ROLLBACK TO SAVEPOINT tentativa')
      end
    end
    allowed
  ensure
    connection&.exec('ROLLBACK') rescue nil
    connection&.close
  end

  # A expectativa é calculada sem consultar nenhuma política: só os vínculos do ator e a regra de cada ação.
  def expected(actor, action)
    numbers = allowed_dealers(actor, action)
    return numbers & SAMPLE_DEALERS if action == 'create'
    ids = as_superuser('SELECT id::text FROM public.leads WHERE company_id = $1 AND dealer_id = ANY($2::uuid[]) ORDER BY id',
                       [@company, "{#{indexes(numbers).join(',')}}"]).map { |row| row['id'] }
    return ids unless action == 'update'
    moves = move_cases(actor).map do |old, new|
      [old, new, numbers.include?(old) ? (new != :null && numbers.include?(new) ? 1 : 'erro') : 0]
    end
    { 'rows' => ids, 'moves' => moves }
  end

  def equivalence_checks
    tables = ['public.leads'] + SCOPED.map { |form| form_table(form) }
    check_case('a política real do plano e as seis formas concedem o mesmo, por ação e por ator, e o mesmo que a expectativa independente (conjunto de IDs)') do
      %w[read create update delete].all? do |action|
        @actors.keys.all? do |actor|
          wanted = expected(actor, action)
          tables.all? { |table| reachable(table, actor, action) == wanted }
        end
      end
    end
    check_case('o UPDATE exercita a origem permitida e proibida (OLD) e o destino permitido, proibido e nulo (NEW), com os três desfechos') do
      outcomes = @actors.keys.flat_map { |actor| expected(actor, 'update')['moves'].map(&:last) }
      [1, 0, 'erro'].all? { |outcome| outcomes.include?(outcome) }
    end
    check_case('o plano de cada forma não varre a tabela de vínculos inteira, com 1, 10 e 100 revendas') do
      ['gerente de 1', 'gerente de 10', 'gerente de 100'].all? do |actor|
        value = token(@company, @actors.fetch(actor))
        SCOPED.none? do |form|
          as_app("EXPLAIN SELECT count(*) FROM #{form_table(form)}", 'vetra.ctx', value).flatten.join("\n").match?(/Seq Scan on (memberships|scope_)/)
        end
      end
    end
  end

  def partition(ids)
    Array.new(CLIENTS) { |client| ids.each_with_index.select { |_, index| index % CLIENTS == client }.map(&:first) }
  end

  def measure_actions
    @report << "Questão 2 do ADR-023 por ação, PostgreSQL #{@admin.server_version}: custo por instrução (ms), #{CLIENTS} clientes em processos " \
               "próprios, #{@seconds} s por série, #{@rounds} rodadas (mediana; mínimo a máximo). O controle f0 só tem o tenant; as colunas " \
               'f1 a f6 mostram o **acréscimo sobre f0**, rodada a rodada.'
    @report << '| Ação | Ator | f0, custo absoluto | f1, gerada | f2, ANY(ARRAY) | f3, IN (SELECT) | f4, materializada | f5, EXISTS único | f6, f5 + 2 chamadas |'
    @report << '|---|---|---|---|---|---|---|---|---|'
    plans = [
      ['SELECT por chave', ['gerente de 1', 'gerente de 100', 'gerente de 1000', 'vendedor de 10'], :rw, :read_point, 'COMMIT', false],
      ['SELECT varredura do tenant', ['gerente de 1', 'gerente de 100', 'gerente de 1000', 'vendedor de 10'], :rw, :read_scan, 'COMMIT', false],
      ['INSERT (`WITH CHECK`)', %w[gerente\ de\ 10 gerente\ de\ 100 vendedor\ de\ 10], :rw, :insert, 'COMMIT', true],
      ['UPDATE por chave (`USING` e `WITH CHECK`)', %w[gerente\ de\ 10 gerente\ de\ 100 vendedor\ de\ 10], :rw, :update, 'COMMIT', true],
      ['DELETE por chave (`USING`, desfeito)', %w[gerente\ de\ 10 gerente\ de\ 100], :g, :delete, 'ROLLBACK', true]
    ]
    @extras = Hash.new { |hash, key| hash[key] = Hash.new { |inner, form| inner[form] = [] } }
    plans.each do |label, actors, scope, kind, finish, vacuum|
      filter = ENV['VETRA_ESCOPO_ATORES']&.split(',')&.map(&:strip)
      actors.each { |actor| measure_one(label, actor, scope, kind, finish, vacuum) if filter.nil? || filter.include?(actor) }
    end
    SCOPED.each do |form|
      @extras.each do |label, by_form|
        values = by_form[form]
        threshold("ADR-023, questão 2, #{label}, forma #{form}", values, SCOPE_LIMIT_MS, 'ms por instrução') unless values.empty?
      end
    end
  end

  def measure_one(label, actor, scope, kind, finish, vacuum)
    user = @actors.fetch(actor)
    value = token(@company, user)
    roles = scope == :g ? %w[gerente] : %w[gerente vendedor]
    wanted = @dealers_of.fetch(actor).select { |role, _| roles.include?(role) }.values.flatten.uniq.sort
    ids = as_superuser('SELECT id::text FROM public.leads WHERE company_id = $1 AND dealer_id = ANY($2::uuid[]) ORDER BY id',
                       [@company, "{#{indexes(wanted).join(',')}}"]).map { |row| row['id'] }
    shares = partition(ids)
    dealers = indexes(wanted.select { |index| index <= 100 }.first(10))
    prepare = lambda do |_connection, client|
      { ids: shares.fetch(client), dealers: dealers, token: value, next: 0 }
    end
    context = ->(state) { ['vetra.ctx', state[:token]] }
    pick = ->(state) { state[:ids][(state[:next] += 1) % state[:ids].size] }
    builder = lambda do |table|
      case kind
      when :read_point then ->(c, s) { c.exec_params("SELECT name FROM #{table} WHERE id = $1", [pick.(s)]) }
      when :read_scan then ->(c, _s) { c.exec("SELECT count(*) FROM #{table}") }
      when :insert
        ->(c, s) { c.exec_params("INSERT INTO #{table} (company_id, dealer_id, name, status, created_at) VALUES ($1, $2, 'Lead medido', 'new', now())", [@company, s[:dealers][(s[:next] += 1) % s[:dealers].size]]) }
      when :update then ->(c, s) { c.exec_params("UPDATE #{table} SET name = name WHERE id = $1", [pick.(s)]) }
      when :delete then ->(c, s) { c.exec_params("DELETE FROM #{table} WHERE id = $1", [pick.(s)]) }
      end
    end
    costs = Hash.new { |hash, key| hash[key] = [] }
    @finish_statement = finish
    @rounds.times do |round|
      FORMS.rotate(round).each do |form|
        table = form_table(form)
        restore = lambda do
          script("DELETE FROM #{table} WHERE name = 'Lead medido'")
          script("VACUUM ANALYZE #{table}") if vacuum
        end
        cost, raw = per_statement(round, restore: restore, context: context, statement: builder.call(table), &prepare)
        costs[form] << cost
        @detail << "- #{label}, #{actor}, #{form}, rodada #{round + 1}: #{ms(raw[1].first)} / #{ms(raw[STATEMENTS].first)} (#{raw[1].last} / #{raw[STATEMENTS].last})"
      end
    end
    @finish_statement = nil
    extras = SCOPED.to_h { |form| [form, costs[form].zip(costs['f0']).map { |a, b| a - b }] }
    extras.each { |form, values| @extras[label][form].concat(values) }
    range = ->(values) { "#{signed(median(values))} (#{signed(values.min)} a #{signed(values.max)})" }
    @report << "| #{label} | #{actor} | #{ms(median(costs['f0']))} | #{SCOPED.map { |form| range.(extras[form]) }.join(' | ')} |"
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    exit(ScopeFormsProbe.new(ENV.fetch('DATABASE_URL')).run ? 0 : 1)
  rescue StandardError => error
    warn "FALHA: medição do escopo interrompida (#{error.class})."
    exit 1
  end
end

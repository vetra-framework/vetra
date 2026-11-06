#!/usr/bin/env ruby
# Sonda C9: PostgreSQL 17/18 descartável, bootstrap Context.roles_sql já aplicado; URL administrativa,
# VETRA_MIGRATOR_PASSWORD e VETRA_PG_DUMP como na sonda da fundação. Não executa db:migrate (K10).
# Cada cenário usa uma cópia temporária e prova replay, convergência, dados e constraints pelo gerador padrão.
require 'bundler/setup'
require 'fileutils'
require 'pg'
require 'tmpdir'
require_relative '../lib/vetra'
require_relative 'support/casos_plano_aditivo'

class AdditivePlanProbe
  EXAMPLES = File.expand_path('../examples', __dir__)
  ID = '00000000-0000-4000-8000-000000000001'
  ACTOR = '00000000-0000-4000-8000-000000000002'
  DEALER = '00000000-0000-4000-8000-000000000003'
  ROWS = 1_000_000

  # Delega a conexão que realmente entrou como migrador; observa só as instruções longas, mantendo PlanExecutor.
  class ObservedConnection
    def initialize(connection, observer)
      @connection, @observer = connection, observer
    end

    def exec(sql)
      if sql.match?(/\ACREATE (UNIQUE )?INDEX CONCURRENTLY /) || sql.include?(' VALIDATE CONSTRAINT ')
        @observer.call(sql)
      else
        @connection.exec(sql)
      end
    end
  end

  def initialize(url, pg_dump, password)
    @url, @password, @results = url, password, []
    @scratch = Vetra::SQL::ScratchDatabase.new(url: url, pg_dump: pg_dump, migrator_password: password)
  end

  def check(label)
    ok = yield == true
    @results << ok
    puts "#{ok ? 'OK' : 'FALHA'}: #{label}"
    raise "Verificação falhou: #{label}" unless ok
  end

  def run
    @admin = PG.connect(@url)
    @admin.exec('SET client_min_messages = warning')
    raise 'Use PostgreSQL 17 ou 18' unless [17, 18].include?(@admin.server_version / 10_000)
    @admin.exec(Vetra::SQL::Context.role_guard)
    before = @admin.exec_params(Vetra::SQL::ScratchDatabase::ROLE_CATALOG, ['']).getvalue(0, 0)
    AdditivePlanCases::CASES.each { |name, example| scenario(name, example) }
    check('nenhum objeto global foi alterado e todos os bancos temporários foram removidos') do
      @admin.exec_params(Vetra::SQL::ScratchDatabase::ROLE_CATALOG, ['']).getvalue(0, 0) == before
    end
    puts "#{@results.count(true)}/#{@results.size} verificações passaram (PostgreSQL #{@admin.server_version})."
    true
  rescue StandardError => e
    warn "FALHA: #{e.class}: #{e.message.lines.first&.strip}"
    puts "#{@results.count(true)}/#{@results.size} verificações passaram."
    false
  ensure
    @admin&.close
  end

  private

  def scenario(name, example)
    Dir.mktmpdir('vetra-sonda-aditiva-') do |root|
      FileUtils.cp_r(File.join(EXAMPLES, example, '.'), root)
      FileUtils.rm_rf(File.join(root, 'db'))
      AdditivePlanCases.prepare(root, name)
      compiler = Vetra::Graph::Compiler.new(root: root)
      AdditivePlanCases.compile(compiler, name)
      planner = Vetra::SQL::Planner.new(root: root, database: @scratch)
      planner.plan
      AdditivePlanCases.change(root, name)
      AdditivePlanCases.compile(compiler, name, changed: true)
      result = planner.plan
      check("#{name}: nome e regeneração determinísticos, com filtro em todos os passos") do
        result.path.end_with?('/0002_expand.sql') && planner.plan.status == :unchanged &&
          result.plans.last.steps.all? { |step| Vetra::SQL::Plan.check_step!(step, 'por_passo', 'sonda').nil? }
      end
      check("#{name}: --snapshot aplica ambos os planos e prova convergência, incluindo donos/ACL/RLS/rotinas/triggers") do
        planner.snapshot.status == :written && Vetra::SQL::Planner.parse_schema(File.read(File.join(root, 'db/schema.sql')))[:bases].size == 2
      end
      check("#{name}: --check repete replay e convergência como vetra_migrator pelo ScratchDatabase") { planner.check.status == :checked }
      with_data(name, example, result.plans)
    end
  end

  def with_data(name, example, plans)
    database = "vetra_aditiva_#{SecureRandom.hex(6)}"
    @admin.exec("CREATE DATABASE #{database} OWNER vetra_migrator TEMPLATE template0 ENCODING 'UTF8' LOCALE 'C'")
    created = true
    params = PG::Connection.conninfo_parse(@url).each_with_object({}) do |option, out|
      out[option[:keyword]] = option[:val] if option[:val] && !option[:val].empty?
    end
    target = params.merge('dbname' => database, 'host' => @admin.host,
                          'port' => @admin.port.to_s, 'hostaddr' => @admin.hostaddr.to_s)
    # Mesmo login isolado de credenciais administrativas que o executor temporário usa.
    connection = @scratch.send(:connect_migrator, target)
    connection.exec('SET client_min_messages = warning')
    check("#{name}: PlanExecutor recebe uma sessão vetra_migrator sem poderes administrativos") do
      connection.exec(Vetra::SQL::ScratchDatabase::IDENTITY).values.first == Vetra::SQL::ScratchDatabase::EXPECTED_IDENTITY
    end
    Vetra::SQL::PlanExecutor.new(connection).apply([plans.first])
    seed(connection, example, %i[indice fk composta].include?(name) ? ROWS : 2)
    if name == :composta
      connection.exec(<<~SQL)
        INSERT INTO public.categories (id, company_id, code, created_at)
        SELECT ('00000000-0000-4000-8000-' || lpad(to_hex(n), 12, '0'))::uuid,
          '#{ID}'::uuid, 'cat-' || n, now() FROM generate_series(1, #{ROWS}) n;
      SQL
      connection.exec("UPDATE public.leads SET category_code = 'cat-1'")
    end
    table = example == 'blog' ? 'posts' : 'leads'
    original = connection.exec("SELECT table_name, column_name FROM information_schema.columns WHERE table_schema = 'public' ORDER BY table_name, ordinal_position")
                         .values.group_by(&:first).transform_values { |rows| rows.map(&:last) }
    fingerprint = data_fingerprint(connection, original)
    revisions = revision_data(connection, example)
    policy_rollback(connection, plans.last) if name == :politica
    observer = lambda { |sql| concurrent_write(connection, target, table, sql, name) }
    executor_connection = %i[indice fk composta].include?(name) ? ObservedConnection.new(connection, observer) : connection
    Vetra::SQL::PlanExecutor.new(executor_connection).apply([plans.last])
    check("#{name}: conteúdo original e contadores de revisão são preservados por 0002") do
      data_fingerprint(connection, original) == fingerprint && revision_data(connection, example) == revisions
    end
    check("#{name}: todas as constraints e todos os índices terminam válidos, sem CHECK auxiliar") do
      connection.exec(<<~SQL).getvalue(0, 0) == 't'
        SELECT NOT EXISTS (SELECT 1 FROM pg_constraint WHERE NOT convalidated)
          AND NOT EXISTS (SELECT 1 FROM pg_index WHERE NOT indisvalid)
          AND NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname LIKE 'vt_expand_%')
      SQL
    end
    verify_effect(connection, name)
  ensure
    connection&.close
    @admin.exec("DROP DATABASE IF EXISTS #{database} WITH (FORCE)") if created
  end

  def seed(connection, example, count)
    if example == 'blog'
      connection.exec(<<~SQL)
        INSERT INTO public.posts (id, author_id, title, status, created_at)
        SELECT ('00000000-0000-4000-8000-' || lpad(to_hex(n), 12, '0'))::uuid,
          '#{ACTOR}'::uuid, 'post-' || n, 'draft', '2026-01-01T00:00:00Z'::timestamptz
        FROM generate_series(1, #{count}) n;
      SQL
    else
      connection.exec("INSERT INTO public.companies (id, name, created_at) VALUES ('#{ID}', 'Empresa', now())")
      if example == 'mini_crm_revendas'
        connection.exec("INSERT INTO public.users (id, company_id, name, email, created_at) VALUES ('#{ACTOR}', '#{ID}', 'Ator', 'ator@example.test', now())")
        connection.exec("INSERT INTO public.dealers (id, company_id, name, created_at) VALUES ('#{DEALER}', '#{ID}', 'Revenda', now())")
      end
      dealer_columns, dealer_values = example == 'mini_crm_revendas' ? [', dealer_id', ", '#{DEALER}'::uuid"] : ['', '']
      connection.exec(<<~SQL)
        INSERT INTO public.leads (id, company_id, name, status, created_at#{dealer_columns})
        SELECT ('00000000-0000-4000-8000-' || lpad(to_hex(n), 12, '0'))::uuid,
          '#{ID}'::uuid, 'Lead-' || n, 'new', now()#{dealer_values} FROM generate_series(1, #{count}) n;
      SQL
    end
  end

  def data_fingerprint(connection, tables)
    tables.to_h do |table, columns|
      values = columns.map { |column| Vetra::SQL::Context.quote(column) }.join(', ')
      [table, connection.exec("SELECT count(*), sum(hashtext(jsonb_build_array(#{values})::text)::bigint) FROM public.#{Vetra::SQL::Context.quote(table)}").values]
    end
  end

  def revision_data(connection, example)
    return [] if example == 'blog'
    connection.exec('SELECT tenant_id, revision FROM vetra.authz_revisions ORDER BY tenant_id').values
  end

  def rejects(connection, sql, state)
    connection.exec(sql)
    false
  rescue PG::Error => e
    e.result.error_field(PG::PG_DIAG_SQLSTATE) == state
  end

  def policy_rollback(connection, plan)
    catalog = "SELECT coalesce(jsonb_agg(to_jsonb(p) ORDER BY policyname), '[]')::text FROM pg_policies p WHERE tablename = 'leads'"
    previous = connection.exec(catalog).getvalue(0, 0)
    swap = plan.steps.find { |step| step.sql.start_with?('DROP POLICY ') }
    # Falha proposital depois do CREATE: o executor deve desfazer também todos os DROPs do mesmo passo.
    failed = Vetra::SQL::Plan::Step.new(**swap.to_h.merge(number: 1, sql: swap.sql + "\nSELECT 1/0;"))
    attempted = Vetra::SQL::Plan.new(number: '0002', name: 'falha_politica', transaction: 'por_passo', steps: [failed])
    check('politica: falha depois dos DROPs/CREATEs preserva integralmente as políticas anteriores') do
      begin
        Vetra::SQL::PlanExecutor.new(connection).apply([attempted])
        false
      rescue Vetra::Graph::Error => e
        e.diagnostics.map(&:code).include?('db_plan_apply') && connection.exec(catalog).getvalue(0, 0) == previous
      end
    end
  end

  def verify_effect(connection, name)
    check("#{name}: o novo contrato é efetivo sobre dados") do
      case name
      when :coluna
        connection.exec('SELECT bool_and(nota IS NULL) FROM public.posts').getvalue(0, 0) == 't' &&
          rejects(connection, "UPDATE public.posts SET nota = repeat('x', 41) WHERE id = '#{ID}'", '23514')
      when :constante, :combinado
        connection.exec('SELECT bool_and(score = 0) FROM public.posts').getvalue(0, 0) == 't' &&
          rejects(connection, "UPDATE public.posts SET score = NULL WHERE id = '#{ID}'", '23502')
      when :unica
        rejects(connection, "UPDATE public.posts SET title = 'post-1' WHERE title = 'post-2'", '23505')
      when :fk
        rejects(connection, "UPDATE public.posts SET category_id = '#{ACTOR}' WHERE id = '#{ID}'", '23503')
      when :composta
        rejects(connection, "UPDATE public.leads SET category_code = 'inexistente' WHERE id = '#{ID}'", '23503')
      when :enum
        connection.exec("UPDATE public.posts SET status = 'archived' WHERE id = '#{ID}'")
        rejects(connection, "UPDATE public.posts SET status = 'desconhecido' WHERE id = '#{ID}'", '23514')
      when :tabela
        connection.exec("INSERT INTO public.notes (company_id, created_at) VALUES ('#{ID}', now())")
        connection.exec('SELECT count(*) FROM public.notes').getvalue(0, 0) == '1'
      when :schema
        connection.exec('INSERT INTO archive.notes (created_at) VALUES (now())')
        connection.exec('SELECT body FROM archive.notes').getvalue(0, 0) == ''
      when :revisao
        previous = connection.exec("SELECT revision FROM vetra.authz_revisions WHERE tenant_id = '#{ID}'").getvalue(0, 0).to_i
        connection.exec("INSERT INTO public.notes (company_id, body, created_at) VALUES ('#{ID}', 'nota', now())")
        connection.exec("SELECT revision FROM vetra.authz_revisions WHERE tenant_id = '#{ID}'").getvalue(0, 0).to_i > previous
      when :transicao
        connection.exec("UPDATE public.leads SET closed_at = now() WHERE id = '#{ID}'")
        connection.exec("SELECT closed_at IS NOT NULL FROM public.leads WHERE id = '#{ID}'").getvalue(0, 0) == 't'
      when :politica
        connection.exec("SELECT count(*) FROM pg_policies WHERE tablename = 'leads' AND policyname = 'vt_access'").getvalue(0, 0) == '1'
      when :indice
        connection.exec("SELECT count(*) FROM pg_indexes WHERE tablename = 'posts' AND indexdef LIKE '%(title)%'").getvalue(0, 0) == '1'
      else false
      end
    end
  end

  def concurrent_write(connection, target, table, sql, name)
    writer = @scratch.send(:connect_migrator, target)
    writer.exec('BEGIN')
    writer.exec("SET LOCAL statement_timeout = '1500ms'")
    is_index = sql.match?(/\ACREATE (UNIQUE )?INDEX CONCURRENTLY /)
    table = sql[/ ON "public"\."([a-z_]+)"/, 1] if is_index
    # CIC espera este escritor prévio. VALIDATE fica na transação do passo, conservando o lock após a varredura.
    column = { 'posts' => 'title', 'leads' => 'name', 'categories' => 'code' }.fetch(table)
    writer.exec("UPDATE public.#{table} SET #{column} = #{column} WHERE id = '#{ID}'") if is_index
    worker = Thread.new { connection.exec(sql) }
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
    loop do
      observed = writer.exec_params(<<~SQL, [connection.backend_pid, "public.#{table}"]).getvalue(0, 0) == 't'
        SELECT EXISTS (SELECT 1 FROM pg_locks WHERE pid = $1::integer AND relation = $2::regclass
          AND mode = 'ShareUpdateExclusiveLock' AND granted)
      SQL
      break if observed
      raise 'Não observou ShareUpdateExclusive no passo' if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      sleep 0.01
    end
    check("#{name}: escrita concorrente com #{is_index ? 'CONCURRENTLY' : 'VALIDATE'} mantendo ShareUpdateExclusive em #{ROWS} linhas") do
      writer.exec("UPDATE public.#{table} SET #{column} = #{column} WHERE id = '#{ACTOR}'").cmd_tuples == 1
    end
    # A escrita prova a compatibilidade e é desfeita para não alterar dados nem revisões medidos pelo cenário.
    writer.exec('ROLLBACK')
    worker.value
  ensure
    writer&.exec('ROLLBACK') if writer && writer.transaction_status != PG::PQTRANS_IDLE
    writer&.close
    worker&.join
  end
end

url = ENV['DATABASE_URL'] or abort 'Defina DATABASE_URL com um PostgreSQL 17/18 descartável e bootstrap Vetra.'
exit(AdditivePlanProbe.new(url, ENV.fetch('VETRA_PG_DUMP', 'pg_dump'), ENV['VETRA_MIGRATOR_PASSWORD']).run ? 0 : 1)

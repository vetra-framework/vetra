#!/usr/bin/env ruby
# Sonda da fundação do plano incremental (ADR-038): o banco descartável do db:plan aplica os planos numa conexão que
# entra como vetra_migrator, dono só do banco temporário. Confere:
# - um plano por_passo com CREATE INDEX CONCURRENTLY fora de transação;
# - as tentativas de sair do banco ou do papel, montadas em partes para escapar do filtro de texto;
# - a alteração do próprio papel, apontada pelo catálogo de papéis;
# - a convergência de dois planos com o plano inicial da IR, num exemplo copiado.
#
# Requer PostgreSQL 17+ descartável, superusuário na URL e o bootstrap Vetra::SQL::Context.roles_sql já executado;
# com senha no servidor, VETRA_MIGRATOR_PASSWORD. Desfaz no fim as alterações de papel que provoca.
#   DATABASE_URL=postgres://postgres@localhost/postgres VETRA_PG_DUMP=/usr/lib/postgresql/18/bin/pg_dump \
#     bundle exec ruby script/sonda_plano_incremental.rb
require 'bundler/setup'
require 'fileutils'
require 'pg'
require 'tmpdir'
require_relative '../lib/vetra'

class IncrementalPlanProbe
  EXAMPLES = File.expand_path('../examples', __dir__)

  # Diferença de teste: cada índice novo da IR vira um passo CREATE INDEX CONCURRENTLY. A diferença real é da C9.
  def self.indexes(rename: false)
    lambda do |base:, schema:, number:|
      known = base.state['tables'].flat_map { |table| table['indexes'].map { |index| index['name'] } }
      steps = schema.tables.flat_map do |table|
        table['indexes'].reject { |index| known.include?(index['name']) }.map do |index|
          name = rename ? "#{index['name'][0, 50]}_outro" : index['name']
          %(CREATE INDEX CONCURRENTLY "#{name}" ON "#{table['schema']}"."#{table['table']}" (#{index['columns'].map { |column| %("#{column}") }.join(', ')});)
        end
      end
      built = steps.each_with_index.map do |sql, offset|
        lock, cost = Vetra::SQL::Plan.classify(sql)
        Vetra::SQL::Plan::Step.new(number: offset + 1, phase: 'expand', lock: lock, cost: cost, sql: sql, transaction: 'nao')
      end
      Vetra::SQL::Plan.new(number: number, name: 'indices', transaction: 'por_passo', steps: built)
    end
  end

  def initialize(url, pg_dump, password)
    @url, @pg_dump, @password, @results = url, pg_dump, password, []
  end

  def run
    @admin = PG.connect(@url)
    @admin.exec('SET client_min_messages = warning')
    version = @admin.exec('SHOW server_version').getvalue(0, 0)
    @scratch = Vetra::SQL::ScratchDatabase.new(url: @url, pg_dump: @pg_dump, migrator_password: @password)
    run_checks
    puts "#{@results.count(true)}/#{@results.size} verificações passaram (PostgreSQL #{version})."
    @results.all?
  ensure
    restore_roles
    @admin&.close
  end

  private

  def check(label)
    ok = yield == true
    @results << ok
    puts "#{ok ? 'OK' : 'FALHA'}: #{label}"
  rescue StandardError => e
    @results << false
    puts "FALHA: #{label} (#{e.class}: #{e.message.lines.first&.strip})"
  end

  def refused(code)
    yield
    false
  rescue Vetra::Graph::Error => e
    puts "  recusado: #{e.message.lines.first.strip[0, 160]}"
    e.diagnostics.map(&:code).include?(code)
  end

  def step(number, sql, transaction = nil)
    Vetra::SQL::Plan::Step.new(number: number, phase: 'expand', lock: 'nenhum', cost: 'catalogo', sql: sql, transaction: transaction)
  end

  def probe_plan(number, sql)
    Vetra::SQL::Plan.new(number: number, name: 'sonda', transaction: 'unica', steps: [step(1, sql)])
  end

  def initial(name)
    Vetra::SQL::Plan.parse(File.read(File.join(EXAMPLES, name, 'db/plans/0001_inicial.sql'), encoding: 'UTF-8'), file: 'db/plans/0001_inicial.sql')
  end

  def role_settings
    @admin.exec(<<~SQL).getvalue(0, 0)
      SELECT coalesce(pg_catalog.string_agg(pg_catalog.array_to_string(s.setconfig, ','), ';'), '')
      FROM pg_catalog.pg_db_role_setting s JOIN pg_catalog.pg_roles r ON r.oid = s.setrole WHERE r.rolname = 'vetra_migrator'
    SQL
  end

  def restore_roles
    return unless @admin
    @admin.exec('ALTER ROLE vetra_migrator RESET ALL')
    @admin.exec("ALTER ROLE vetra_migrator PASSWORD #{@password && !@password.empty? ? @admin.escape_literal(@password) : 'NULL'}") if @password_touched
    @admin.exec('DROP ROLE IF EXISTS vetra_intruso')
    @admin.exec('ALTER DATABASE postgres RESET work_mem')
  end

  def run_checks
    blog = initial('blog')
    check('o plano roda numa sessão que entrou como vetra_migrator, num banco de que ele é dono') do
      guard = probe_plan('0002', <<~SQL.chomp)
        DO $vetra_sonda$
        BEGIN
          IF session_user <> 'vetra_migrator' OR current_user <> 'vetra_migrator' THEN
            RAISE EXCEPTION 'sessão %/%', session_user, current_user;
          END IF;
          IF (SELECT datdba::regrole::text FROM pg_catalog.pg_database WHERE datname = pg_catalog.current_database()) <> 'vetra_migrator' THEN
            RAISE EXCEPTION 'dono do banco';
          END IF;
        END $vetra_sonda$;
      SQL
      dumps = @scratch.replay([blog, guard])
      dumps.size == 2 && dumps[0] == dumps[1]
    end

    check('um plano por_passo cria o índice com CONCURRENTLY fora de transação, e o dump o mostra') do
      steps = [step(1, %(CREATE INDEX CONCURRENTLY "vt_sonda_status" ON "public"."posts" ("status");), 'nao'),
               step(2, %(CREATE TABLE "public"."sonda" ("id" uuid PRIMARY KEY);), 'sim')]
      plan = Vetra::SQL::Plan.new(number: '0002', name: 'sonda', transaction: 'por_passo', steps: steps)
      dumps = @scratch.replay([blog, plan])
      !dumps[0].include?('vt_sonda_status') && dumps[1].include?('CREATE INDEX vt_sonda_status ON public.posts USING btree (status);') &&
        dumps[1].include?('CREATE TABLE public.sonda')
    end

    check('CREATE INDEX CONCURRENTLY num plano de transação única é recusado antes do banco') do
      refused('db_plan_format') { probe_plan('0002', 'CREATE INDEX CONCURRENTLY "i" ON "blog"."posts" ("status");') }
    end

    check('RESET ROLE montado em partes não devolve o superusuário: criar papel falha') do
      plan = probe_plan('0002', "DO $vetra_sonda$\nBEGIN\n  EXECUTE 'RESET ' || 'ROLE';\n  EXECUTE 'CREATE ' || 'ROLE vetra_intruso';\nEND $vetra_sonda$;")
      refused('db_plan_apply') { @scratch.replay([blog, plan]) } &&
        @admin.exec("SELECT count(*) FROM pg_catalog.pg_roles WHERE rolname = 'vetra_intruso'").getvalue(0, 0) == '0'
    end

    check('SET SESSION AUTHORIZATION montado em partes é negado ao vetra_migrator') do
      plan = probe_plan('0002', "DO $vetra_sonda$\nBEGIN\n  EXECUTE 'SET SESSION ' || 'AUTHORIZATION postgres';\nEND $vetra_sonda$;")
      refused('db_plan_apply') { @scratch.replay([blog, plan]) }
    end

    check('alterar outro banco montado em partes é negado e não deixa parâmetro') do
      plan = probe_plan('0002', "DO $vetra_sonda$\nBEGIN\n  EXECUTE 'ALTER ' || 'DATABASE postgres SET work_mem = ''8MB''';\nEND $vetra_sonda$;")
      refused('db_plan_apply') { @scratch.replay([blog, plan]) } &&
        @admin.exec("SELECT count(*) FROM pg_catalog.pg_db_role_setting s JOIN pg_catalog.pg_database d ON d.oid = s.setdatabase WHERE d.datname = 'postgres'").getvalue(0, 0) == '0'
    end

    check('um parâmetro no próprio papel, montado em partes, é apontado pelo catálogo de papéis') do
      before = role_settings
      plan = probe_plan('0002', "DO $vetra_sonda$\nBEGIN\n  EXECUTE 'ALTER ' || 'ROLE vetra_migrator SET work_mem = ''8MB''';\nEND $vetra_sonda$;")
      refused('db_plan_global') { @scratch.replay([blog, plan]) } && role_settings != before
    ensure
      @admin.exec('ALTER ROLE vetra_migrator RESET ALL')
    end

    check('a senha do próprio papel, trocada em partes, é apontada pelo catálogo de papéis') do
      @password_touched = true
      plan = probe_plan('0002', "DO $vetra_sonda$\nBEGIN\n  EXECUTE 'ALTER ' || 'ROLE vetra_migrator PASSWORD ''trocada''';\nEND $vetra_sonda$;")
      refused('db_plan_global') { @scratch.replay([blog, plan]) }
    ensure
      restore_roles
      @password_touched = false
    end

    check('conceder privilégio em outro banco não dá o privilégio, e o catálogo de bancos aponta a mudança') do
      # Sem ser dono nem ter GRANT OPTION, o PostgreSQL só avisa ("no privileges were granted"), mas grava a ACL padrão
      # explícita no lugar de NULL: o catálogo dos bancos acusa a alteração, e a aplicação continua sem CREATE.
      @admin.exec('CREATE DATABASE vetra_sonda_outro')
      # Direto, o filtro já recusa; montado em partes, escapa dele e cai no catálogo.
      direct = refused('db_plan_forbidden') { probe_plan('0002', 'GRANT CREATE ON DATABASE "vetra_sonda_outro" TO "vetra_app";') }
      plan = probe_plan('0002', "DO $vetra_sonda$\nBEGIN\n  EXECUTE 'GRANT CREATE ON ' || 'DATABASE vetra_sonda_outro TO vetra_app';\nEND $vetra_sonda$;")
      direct && refused('db_plan_global') { @scratch.replay([blog, plan]) } &&
        @admin.exec("SELECT pg_catalog.has_database_privilege('vetra_app', 'vetra_sonda_outro', 'CREATE')").getvalue(0, 0) == 'f'
    ensure
      @admin.exec('DROP DATABASE IF EXISTS vetra_sonda_outro')
    end

    check('um servidor em que o vetra_migrator já é dono de outro banco é recusado antes de criar o temporário') do
      @admin.exec('CREATE DATABASE vetra_sonda_alheio OWNER vetra_migrator')
      before = @admin.exec("SELECT count(*) FROM pg_catalog.pg_database WHERE datname LIKE 'vetra_plan_%'").getvalue(0, 0)
      refused('db_plan_role') { @scratch.replay([blog]) } &&
        @admin.exec("SELECT count(*) FROM pg_catalog.pg_database WHERE datname LIKE 'vetra_plan_%'").getvalue(0, 0) == before
    ensure
      @admin.exec('DROP DATABASE IF EXISTS vetra_sonda_alheio')
    end

    check('um tablespace do vetra_migrator ou um privilégio dele num parâmetro também recusa o servidor') do
      # Tablespace no próprio diretório de dados (opção de desenvolvedor do PostgreSQL), para não depender de um caminho
      # no servidor: funciona também no contêiner da CI.
      @admin.exec('SET allow_in_place_tablespaces = on')
      @admin.exec("CREATE TABLESPACE vetra_sonda_espaco OWNER vetra_migrator LOCATION ''")
      tablespace = refused('db_plan_role') { @scratch.replay([blog]) }
      @admin.exec('DROP TABLESPACE vetra_sonda_espaco')
      @admin.exec('GRANT SET ON PARAMETER work_mem TO vetra_migrator')
      parameter = refused('db_plan_role') { @scratch.replay([blog]) }
      tablespace && parameter
    ensure
      @admin.exec('DROP TABLESPACE IF EXISTS vetra_sonda_espaco')
      @admin.exec('REVOKE SET ON PARAMETER work_mem FROM vetra_migrator')
    end

    check('um privilégio com GRANT OPTION para pg_database_owner, que o dono do temporário recebe, também recusa o servidor') do
      @admin.exec('GRANT CREATE ON DATABASE postgres TO pg_database_owner WITH GRANT OPTION')
      refused('db_plan_role') { @scratch.replay([blog]) }
    ensure
      @admin.exec('REVOKE CREATE ON DATABASE postgres FROM pg_database_owner CASCADE')
    end

    check('um vetra_migrator promovido a superusuário é recusado pela guarda do executor, antes de qualquer plano') do
      @admin.exec('ALTER ROLE vetra_migrator SUPERUSER')
      before = @admin.exec("SELECT count(*) FROM pg_catalog.pg_database WHERE datname LIKE 'vetra_plan_%'").getvalue(0, 0)
      refused('db_plan_role') { @scratch.replay([blog]) } &&
        @admin.exec("SELECT count(*) FROM pg_catalog.pg_database WHERE datname LIKE 'vetra_plan_%'").getvalue(0, 0) == before
    ensure
      @admin.exec('ALTER ROLE vetra_migrator NOSUPERUSER')
    end

    check('uma sessão do vetra_migrator aberta noutro banco recusa o servidor, e continua viva') do
      params = PG::Connection.conninfo_parse(@url).each_with_object({}) { |option, out| out[option[:keyword]] = option[:val] if option[:val] && !option[:val].empty? }
      login = params.reject { |key, _| %w[user password].include?(key) }.merge('user' => 'vetra_migrator', 'dbname' => 'postgres')
      login['password'] = @password if @password && !@password.empty?
      other = PG.connect(login)
      begin
        refused('db_plan_role') { @scratch.replay([blog]) } && other.exec('SELECT 1').getvalue(0, 0) == '1'
      ensure
        other.close
      end
    end

    check('o banco temporário some depois de cada aplicação, inclusive nas falhas') do
      @admin.exec("SELECT count(*) FROM pg_catalog.pg_database WHERE datname LIKE 'vetra_plan_%'").getvalue(0, 0) == '0'
    end

    Dir.mktmpdir('vetra-sonda-incremental-') do |root|
      FileUtils.cp_r(File.join(EXAMPLES, 'mini_crm/.'), root)
      FileUtils.rm_rf(File.join(root, 'db'))
      compiler = Vetra::Graph::Compiler.new(root: root)
      compiler.write
      planner = ->(differ = Vetra::SQL::Planner::REFUSE) { Vetra::SQL::Planner.new(root: root, database: @scratch, differ: differ) }
      planner.call.plan
      planner.call.snapshot
      lead = File.join(root, 'app/domains/crm/lead.rb')
      File.write(lead, File.read(lead).sub('  crud', "  index :company_id, :created_at\n  crud"))
      compiler.write
      differ = self.class.indexes
      check('dois planos com índice CONCURRENTLY convergem com o plano inicial da IR, e o retrato ganha as duas bases') do
        planner.call(differ).plan.status == :written && planner.call(differ).snapshot.status == :written &&
          planner.call(differ).check.status == :checked &&
          Vetra::SQL::Planner.parse_schema(File.read(File.join(root, 'db/schema.sql')))[:bases].map(&:first) == %w[0001_inicial 0002_indices]
      end
      check('um índice com outro nome não converge com o plano inicial da IR') do
        FileUtils.rm(File.join(root, 'db/plans/0002_indices.sql'))
        FileUtils.rm(File.join(root, 'db/models/0002_indices.json'))
        renamed = self.class.indexes(rename: true)
        planner.call(renamed).plan
        refused('db_plan_convergence') { planner.call(renamed).snapshot }
      end
    end

    # Uma coluna acrescentada por ADD COLUMN fica no fim da tabela, e o plano inicial ordena as colunas pelo nome: a
    # convergência não depende dessa ordem, e o retrato continua exato.
    Dir.mktmpdir('vetra-sonda-coluna-') do |root|
      FileUtils.cp_r(File.join(EXAMPLES, 'blog/.'), root)
      FileUtils.rm_rf(File.join(root, 'db'))
      compiler = Vetra::Graph::Compiler.new(root: root)
      compiler.write
      Vetra::SQL::Planner.new(root: root, database: @scratch).plan
      post = File.join(root, 'app/domains/blog/post.rb')
      File.write(post, File.read(post).sub('  crud', "  string :aaa, optional: true\n  crud"))
      compiler.write
      columns = lambda do |base:, schema:, number:|
        known = base.state['tables'].to_h { |table| [[table['schema'], table['table']], table['columns'].map { |column| column['name'] }] }
        added = schema.tables.flat_map do |table|
          table['columns'].reject { |column| known.fetch([table['schema'], table['table']], []).include?(column['name']) }.map do |column|
            %(ALTER TABLE "#{table['schema']}"."#{table['table']}" ADD COLUMN "#{column['name']}" #{column['type']};)
          end
        end
        steps = added.each_with_index.map { |sql, offset| step(offset + 1, sql, 'sim').tap { |item| item.lock = 'AccessExclusive' } }
        Vetra::SQL::Plan.new(number: number, name: 'colunas', transaction: 'por_passo', steps: steps)
      end
      check('uma coluna acrescentada no fim da tabela converge com o plano inicial, que a põe em ordem de nome') do
        planner = Vetra::SQL::Planner.new(root: root, database: @scratch, differ: columns)
        ok = planner.plan.status == :written && planner.snapshot.status == :written && planner.check.status == :checked
        body = File.read(File.join(root, 'db/schema.sql'))[/CREATE TABLE public\.posts \(\n(.*?)\n\);/m, 1].lines.map(&:strip)
        # No retrato a coluna nova vem depois das outras, fora da ordem de nome: o retrato é exato, e só a convergência a ignora.
        ok && body.index { |line| line.start_with?('aaa text') } > body.index { |line| line.start_with?('id uuid') }
      end
    end
  end
end

ok = IncrementalPlanProbe.new(ENV.fetch('DATABASE_URL'), ENV.fetch('VETRA_PG_DUMP', 'pg_dump'), ENV['VETRA_MIGRATOR_PASSWORD']).run
exit(ok ? 0 : 1)

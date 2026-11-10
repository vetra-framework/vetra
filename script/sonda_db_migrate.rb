#!/usr/bin/env ruby
# Sonda do db:migrate (ADR-015 §1 e §5, ADR-025 §1 e §2): aplica o plano inicial de um exemplo num banco real como
# vetra_migrator e confere registro, segunda execução, migrador único, deriva, plano alterado, banco não vazio,
# novas tentativas de lock_timeout e retomada depois de uma conexão derrubada.
#
# Requer PostgreSQL 17+ descartável, superusuário na URL e o bootstrap Vetra::SQL::Context.roles_sql já executado.
# Cria e remove bancos vetra_migrate_*; não cria, altera nem remove papéis.
#   DATABASE_URL=postgres://postgres@localhost/postgres VETRA_PG_DUMP=/usr/lib/postgresql/18/bin/pg_dump \
#     bundle exec ruby script/sonda_db_migrate.rb
require 'bundler/setup'
require 'pg'
require 'securerandom'
require_relative '../lib/vetra'

class MigrateProbe
  ROOT = File.expand_path('../examples/mini_crm_revendas', __dir__)

  def initialize(url, pg_dump)
    @url, @pg_dump, @results, @databases = url, pg_dump, [], []
  end

  def run
    @admin = PG.connect(@url)
    @admin.exec('SET client_min_messages = warning')
    version = @admin.exec('SHOW server_version').getvalue(0, 0)
    run_checks
    puts "#{@results.count(true)}/#{@results.size} verificações passaram (PostgreSQL #{version})."
    @results.all?
  ensure
    @databases.each { |name| @admin&.exec("DROP DATABASE IF EXISTS #{PG::Connection.quote_ident(name)} WITH (FORCE)") }
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

  # Banco vazio cujo dono é o migrador, como o operador o cria (ADR-036).
  def database
    name = "vetra_migrate_#{SecureRandom.hex(6)}"
    @admin.exec("CREATE DATABASE #{PG::Connection.quote_ident(name)} OWNER vetra_migrator TEMPLATE template0 ENCODING 'UTF8' LOCALE 'C'")
    @databases << name
    name
  end

  def connect(name, as: 'vetra_migrator')
    params = PG::Connection.conninfo_parse(@url).each_with_object({}) { |o, out| out[o[:keyword]] = o[:val] if o[:val] && !o[:val].empty? }
    connection = PG.connect(params.merge('dbname' => name, 'host' => @admin.host, 'port' => @admin.port.to_s))
    connection.exec('SET client_min_messages = warning')
    connection.exec("SET SESSION AUTHORIZATION #{as}") if as
    connection
  end

  def migrate(connection, sleeper: ->(_) {})
    database = Vetra::SQL::MigrationDatabase.new(connection: connection, pg_dump: @pg_dump)
    Vetra::SQL::Migrator.new(root: ROOT, database: database, sleeper: sleeper).migrate
  end

  def refused(code)
    yield
    false
  rescue Vetra::Graph::Error => e
    e.diagnostics.map(&:code).include?(code)
  end

  def records(connection)
    connection.exec('SELECT plan, sha256, steps, applied_by FROM vetra.migrations ORDER BY plan').to_a
  end

  # Os planos commitados, na ordem: o inicial, o 0002 e o 0003 (outbox e relay, ADR-040) e o 0004 (forma da política de escopo, ADR-041).
  def expected_records
    Vetra::SQL::Planner.new(root: ROOT).migration_plans.map do |plan|
      { 'plan' => plan.file_name.delete_suffix('.sql'), 'sha256' => Vetra::SQL::Migrator.digest(plan),
        'steps' => plan.steps.size.to_s, 'applied_by' => 'vetra_migrator' }
    end
  end

  # Cada unidade aplicada conta uma tentativa: o plano de transação única é uma unidade, e o por passo, uma por passo.
  def expected_units
    Vetra::SQL::Planner.new(root: ROOT).migration_plans.sum { |plan| plan.transaction == 'unica' ? 1 : plan.steps.size }
  end

  def run_checks
    name = database
    connection = connect(name)
    expected = expected_records
    check('aplica o plano inicial e os incrementais num banco vazio como vetra_migrator e registra o hash de cada um') do
      result = migrate(connection)
      result.status == :applied && expected.map { |row| row['plan'] } == %w[0001_inicial 0002_expand 0003_expand 0004_expand 0005_expand] && records(connection) == expected
    end
    check('segunda execução não aplica nada e confere o esquema com o retrato') do
      migrate(connection).status == :up_to_date && records(connection) == expected
    end
    check('vetra_app não lê nem grava vetra.migrations') do
      app = connect(name, as: 'vetra_app')
      begin
        %w[SELECT INSERT].all? do |command|
          sql = command == 'SELECT' ? 'SELECT 1 FROM vetra.migrations' : "INSERT INTO vetra.migrations (plan, sha256, steps) VALUES ('0002_x', '#{'0' * 64}', 1)"
          begin
            app.exec(sql)
            false
          rescue PG::InsufficientPrivilege
            true
          end
        end
      ensure
        app.close
      end
    end
    check('um segundo migrador é recusado enquanto o primeiro segura o lock') do
      holder = connect(name)
      begin
        holder.exec_params('SELECT pg_catalog.pg_advisory_lock($1::integer, $2::integer)', Vetra::SQL::MigrationDatabase::LOCK_KEY)
        refused('db_migrate_locked') { migrate(connection) }
      ensure
        holder.close
      end
    end
    check('superusuário e aplicação não aplicam planos') do
      superuser = connect(name, as: nil)
      app = connect(name, as: 'vetra_app')
      begin
        refused('db_migrate_role') { migrate(superuser) } && refused('db_migrate_role') { migrate(app) }
      ensure
        superuser.close
        app.close
      end
    end
    check('deriva fora dos planos é recusada e nada é alterado') do
      connection.exec('ALTER TABLE public.leads ADD COLUMN extra integer')
      drift = refused('db_migrate_drift') { migrate(connection) }
      connection.exec('ALTER TABLE public.leads DROP COLUMN extra')
      drift && migrate(connection).status == :up_to_date
    end
    check('um plano alterado depois de aplicado é recusado pelo hash') do
      owner = connect(name, as: nil)
      begin
        owner.exec("UPDATE vetra.migrations SET sha256 = '#{'0' * 64}'")
        altered = refused('db_migrate_altered') { migrate(connection) }
        expected.each { |row| owner.exec_params('UPDATE vetra.migrations SET sha256 = $1 WHERE plan = $2', row.values_at('sha256', 'plan')) }
        altered
      ensure
        owner.close
      end
    end
    check('privilégio do banco dado depois à aplicação é deriva, embora o pg_dump --schema-only não o mostre') do
      owner = connect(name, as: nil)
      begin
        owner.exec("GRANT CREATE, TEMPORARY ON DATABASE #{PG::Connection.quote_ident(name)} TO vetra_app")
        drift = refused('db_migrate_drift') { migrate(connection) }
        owner.exec("REVOKE CREATE, TEMPORARY ON DATABASE #{PG::Connection.quote_ident(name)} FROM vetra_app")
        drift && migrate(connection).status == :up_to_date
      ensure
        owner.close
      end
    end
    check('large object criado depois é deriva, embora o pg_dump --schema-only não o mostre') do
      owner = connect(name, as: nil)
      begin
        owner.exec("SELECT pg_catalog.lo_from_bytea(1234, '\\x616263'::bytea)")
        drift = refused('db_migrate_drift') { migrate(connection) }
        owner.exec('SELECT pg_catalog.lo_unlink(1234)')
        drift && migrate(connection).status == :up_to_date
      ensure
        owner.close
      end
    end
    check('parâmetro por banco definido depois é deriva, embora o pg_dump --schema-only não o mostre') do
      owner = connect(name, as: nil)
      quoted = PG::Connection.quote_ident(name)
      begin
        owner.exec("ALTER DATABASE #{quoted} SET session_replication_role = replica")
        drift = refused('db_migrate_drift') { migrate(connection) }
        owner.exec("ALTER DATABASE #{quoted} RESET session_replication_role")
        drift && migrate(connection).status == :up_to_date
      ensure
        owner.close
      end
    end
    connection.close

    subscription = 'CREATE SUBSCRIPTION legado CONNECTION \'dbname=inexistente\' PUBLICATION legado ' \
                   'WITH (connect = false, enabled = false, create_slot = false, slot_name = NONE)'
    { 'tabela' => ['CREATE TABLE public.legado (id integer)', nil],
      'collation' => ['CREATE COLLATION public.legado FROM pg_catalog."C"', nil],
      'privilégio padrão' => ['ALTER DEFAULT PRIVILEGES GRANT SELECT ON TABLES TO vetra_app', nil],
      'subscription' => [subscription, 'DROP SUBSCRIPTION legado'],
      'publicação' => ['CREATE PUBLICATION legado FOR ALL TABLES', nil],
      'large object de OID baixo' => ["SELECT pg_catalog.lo_from_bytea(1234, '\\x616263'::bytea)", nil],
      'parâmetro por banco' => ['ALTER DATABASE %<db>s SET session_replication_role = replica', nil],
      'parâmetro de papel no banco' => ['ALTER ROLE vetra_app IN DATABASE %<db>s SET work_mem = \'8MB\'', nil] }.each do |kind, (sql, cleanup)|
      check("banco com #{kind} e sem registro é recusado antes de aplicar qualquer passo") do
        dirty = database
        setup = connect(dirty, as: nil)
        begin
          # A subscription sem conexão gera um aviso esperado do PostgreSQL.
          setup.exec('SET client_min_messages = error')
          setup.exec(format(sql, db: PG::Connection.quote_ident(dirty)))
          migrator = connect(dirty)
          begin
            refused('db_migrate_not_empty') { migrate(migrator) } &&
              migrator.exec("SELECT pg_catalog.to_regnamespace('vetra') IS NULL").getvalue(0, 0) == 't'
          ensure
            migrator.close
          end
        ensure
          # Uma subscription impede remover o banco; sai antes do DROP DATABASE do ensure da sonda.
          setup.exec(cleanup) if cleanup
          setup.close
        end
      end
    end

    check('lock_timeout: a nova tentativa aplica depois que o bloqueio sai') do
      with_blocker do |migrator, blocker|
        sleeps = []
        result = migrate(migrator, sleeper: ->(seconds) { sleeps << seconds; blocker.exec('ROLLBACK') if sleeps.size == 1 })
        result.status == :applied && result.attempts == expected_units + 1 && sleeps.size == 1 && records(migrator) == expected
      end
    end

    check('lock_timeout: esgotadas as tentativas, nada fica aplicado e a execução seguinte retoma') do
      with_blocker do |migrator, blocker|
        sleeps = []
        exhausted = refused('db_migrate_lock_timeout') { migrate(migrator, sleeper: ->(seconds) { sleeps << seconds }) }
        clean = migrator.exec("SELECT pg_catalog.to_regnamespace('vetra') IS NULL").getvalue(0, 0) == 't'
        blocker.exec('ROLLBACK')
        resumed = migrate(migrator).status == :applied && records(migrator) == expected
        exhausted && sleeps.size == Vetra::SQL::Migrator::BACKOFF.size && clean && resumed
      end
    end

    check('conexão derrubada no meio do plano não deixa nada aplicado e a execução seguinte retoma') do
      target = nil
      died = with_blocker do |migrator, blocker, name|
        target = name
        pid = migrator.exec('SELECT pg_catalog.pg_backend_pid()').getvalue(0, 0).to_i
        killer = Thread.new do
          # Espera, com prazo, o migrador ficar preso no lock; então derruba a conexão dele.
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 20
          watcher = connect(name, as: nil)
          begin
            until watcher.exec_params("SELECT count(*) FROM pg_catalog.pg_stat_activity WHERE pid = $1 AND wait_event_type = 'Lock'", [pid]).getvalue(0, 0).to_i.positive?
              raise 'o migrador não chegou a esperar pelo lock' if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
              sleep 0.1
            end
            watcher.exec_params('SELECT pg_catalog.pg_terminate_backend($1)', [pid])
          ensure
            watcher.close
          end
        end
        begin
          outcome = begin
            migrate(migrator)
            false
          rescue Vetra::Graph::Error, PG::Error
            true
          end
          killer.join(30) && outcome
        ensure
          killer.kill if killer.alive?
          blocker.exec('ROLLBACK') rescue nil
        end
      end
      fresh = connect(target)
      begin
        nothing = fresh.exec("SELECT pg_catalog.to_regnamespace('vetra') IS NULL").getvalue(0, 0) == 't'
        died && nothing && migrate(fresh).status == :applied && records(fresh) == expected
      ensure
        fresh.close
      end
    end
  end

  # Banco vazio com uma tabela de mesmo nome criada e não confirmada por outra sessão: o CREATE TABLE do plano espera
  # por ela além do lock_timeout de 3 s. Conexões e transação são encerradas também numa falha.
  def with_blocker
    name = database
    migrator = connect(name)
    blocker = connect(name, as: nil)
    begin
      blocker.exec('BEGIN')
      blocker.exec('CREATE TABLE public.companies (x integer)')
      yield migrator, blocker, name
    ensure
      blocker.close
      migrator.close
    end
  end
end

ok = MigrateProbe.new(ENV.fetch('DATABASE_URL'), ENV.fetch('VETRA_PG_DUMP', 'pg_dump')).run
exit(ok ? 0 : 1)

#!/usr/bin/env ruby
# Sonda do db:migrate incremental (ADR-038, §4 e §5): num banco que já recebeu o plano inicial e tem dados, aplica um
# segundo plano por passo, com índice CONCURRENTLY fora de transação e coluna nova. Confere:
# - o registro de cada passo em vetra.migration_steps e do plano em vetra.migrations;
# - a retomada depois de uma queda em cada passo, inclusive depois do DDL fora de transação e antes do registro;
# - o índice inválido deixado por uma tentativa anterior, refeito, e o índice válido ainda não registrado, aceito;
# - a recusa de uma base que não é o retrato do plano anterior;
# - as novas tentativas de lock_timeout por passo;
# - o índice de mesmo nome em outra tabela, recusado como deriva.
#
# Requer PostgreSQL 17+ descartável, superusuário na URL e o bootstrap Vetra::SQL::Context.roles_sql já executado.
# Cria e remove bancos vetra_migrate_inc_*; não cria, altera nem remove papéis.
#   DATABASE_URL=postgres://postgres@localhost/postgres VETRA_PG_DUMP=/usr/lib/postgresql/18/bin/pg_dump \
#     bundle exec ruby script/sonda_db_migrate_incremental.rb
require 'bundler/setup'
require 'fileutils'
require 'pg'
require 'securerandom'
require 'tmpdir'
require_relative '../lib/vetra'

class IncrementalMigrateProbe
  EXAMPLE = File.expand_path('../examples/mini_crm', __dir__)
  TENANT = '11111111-1111-4111-8111-111111111111'
  # A mudança do modelo: uma coluna anulável e dois índices novos numa tabela com dados.
  CHANGE = "  string :nota, optional: true\n  index :company_id, :created_at\n  index :company_id, :name\n"
  # Só índices: o plano começa por um passo fora de transação.
  INDEXES = "  index :company_id, :created_at\n  index :company_id, :name\n"

  # Queda simulada: o passo escolhido roda (inclusive o DDL fora de transação), e o processo cai antes do registro;
  # com before: true, cai antes do DDL.
  class Crash < StandardError; end

  class CrashingDatabase < Vetra::SQL::MigrationDatabase
    def initialize(crash_at:, before: false, **options)
      super(**options)
      @crash_at, @before = crash_at, before
    end

    def apply_step(plan, name, digest, step, last:)
      return super unless step.number == @crash_at
      if @before
        nil
      elsif step.transaction == 'nao'
        send(:outside_transaction, step)
      else
        @connection.exec('BEGIN')
        @connection.exec(step.sql)
      end
      raise Crash, "queda simulada no passo #{step.number}"
    end
  end

  def initialize(url, pg_dump, password)
    @url, @pg_dump, @password, @results, @databases = url, pg_dump, password, [], []
  end

  def run
    @admin = PG.connect(@url)
    @admin.exec('SET client_min_messages = warning')
    version = @admin.exec('SHOW server_version').getvalue(0, 0)
    Dir.mktmpdir('vetra-sonda-migrate-inc-') do |root|
      @root, @change = root, CHANGE
      prepare_plans
      run_checks
    end
    # Os bancos do primeiro cenário são do vetra_migrator: o banco descartável do db:plan recusaria o servidor com eles.
    drop_databases
    Dir.mktmpdir('vetra-sonda-migrate-inc-') do |root|
      @root, @change = root, INDEXES
      prepare_plans
      index_first_checks
    end
    puts "#{@results.count(true)}/#{@results.size} verificações passaram (PostgreSQL #{version})."
    @results.all?
  ensure
    drop_databases if @admin
    @admin&.close
  end

  def drop_databases
    @databases.each { |name| @admin.exec("DROP DATABASE IF EXISTS #{PG::Connection.quote_ident(name)} WITH (FORCE)") }
    @databases.clear
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

  # Plano inicial e segundo plano de uma cópia do mini CRM, com os retratos de duas bases tirados num banco descartável.
  def prepare_plans
    FileUtils.cp_r("#{EXAMPLE}/.", @root)
    FileUtils.rm_rf(File.join(@root, 'db'))
    compiler = Vetra::Graph::Compiler.new(root: @root)
    compiler.write
    scratch = Vetra::SQL::ScratchDatabase.new(url: @url, pg_dump: @pg_dump, migrator_password: @password)
    Vetra::SQL::Planner.new(root: @root, database: scratch).tap(&:plan).snapshot
    @initial_schema = File.read(File.join(@root, 'db/schema.sql'))
    @initial_plans = Dir[File.join(@root, 'db/{plans,models}/*')].to_h { |path| [path, File.read(path)] }
    lead = File.join(@root, 'app/domains/crm/lead.rb')
    File.write(lead, File.read(lead).sub('  crud', "#{@change}  crud"))
    compiler.write
    planner = Vetra::SQL::Planner.new(root: @root, database: scratch)
    planner.plan
    planner.snapshot
    @plan = Vetra::SQL::Plan.parse(File.read(File.join(@root, 'db/plans/0002_expand.sql')), file: 'db/plans/0002_expand.sql')
  end

  def database
    name = "vetra_migrate_inc_#{SecureRandom.hex(6)}"
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

  def migrate(connection, database: nil, sleeper: ->(_) {})
    database ||= Vetra::SQL::MigrationDatabase.new(connection: connection, pg_dump: @pg_dump)
    Vetra::SQL::Migrator.new(root: @root, database: database, sleeper: sleeper).migrate
  end

  # Banco com o plano inicial aplicado por db:migrate (com os artefatos de então) e algumas linhas.
  def initial_database
    name = database
    current = Dir[File.join(@root, 'db/{plans,models}/*')].to_h { |path| [path, File.read(path)] }
    current_schema = File.read(File.join(@root, 'db/schema.sql'))
    begin
      FileUtils.rm(current.keys - @initial_plans.keys)
      @initial_plans.each { |path, text| File.write(path, text) }
      File.write(File.join(@root, 'db/schema.sql'), @initial_schema)
      lead = File.join(@root, 'app/domains/crm/lead.rb')
      changed = File.read(lead)
      File.write(lead, changed.sub(@change, ''))
      Vetra::Graph::Compiler.new(root: @root).write
      connection = connect(name)
      migrate(connection)
      seed(connection)
      connection.close
    ensure
      File.write(lead, changed) if changed
      Vetra::Graph::Compiler.new(root: @root).write
      current.each { |path, text| File.write(path, text) }
      File.write(File.join(@root, 'db/schema.sql'), current_schema)
    end
    name
  end

  def seed(connection)
    connection.exec("INSERT INTO public.companies (id, name, created_at) VALUES ('#{TENANT}', 'Empresa', now())")
    connection.exec(<<~SQL)
      INSERT INTO public.leads (id, company_id, name, status, created_at)
      SELECT gen_random_uuid(), '#{TENANT}', 'lead ' || g, 'new', now() FROM generate_series(1, 2000) g
    SQL
  end

  # Os passos registrados, sem o marcador do começo do plano (passo 0); a tabela nasce com o começo do primeiro plano
  # por passo.
  def steps(connection)
    return [] if connection.exec("SELECT to_regclass('vetra.migration_steps') IS NULL").getvalue(0, 0) == 't'
    connection.exec("SELECT plan, step, sha256 FROM vetra.migration_steps WHERE step > 0 ORDER BY plan, step").values
  end

  def plans_recorded(connection)
    connection.exec('SELECT plan FROM vetra.migrations ORDER BY plan').column_values(0)
  end

  def expected_steps
    @plan.steps.map { |step| ['0002_expand', step.number.to_s, Digest::SHA256.hexdigest(step.sql)] }
  end

  def indexes_valid?(connection)
    names = @plan.steps.filter_map { |step| step.sql[/\ACREATE (?:UNIQUE )?INDEX CONCURRENTLY "([^"]+)"/, 1] }
    names.all? do |name|
      connection.exec_params("SELECT indisvalid FROM pg_catalog.pg_index WHERE indexrelid = to_regclass($1)", ["public.#{name}"]).getvalue(0, 0) == 't'
    end
  end

  def leads(connection)
    connection.exec('SELECT count(*) FROM public.leads').getvalue(0, 0).to_i
  end

  def outside_steps
    @plan.steps.select { |step| step.transaction == 'nao' }
  end

  # Um plano que começa por índice: a queda depois do CREATE INDEX CONCURRENTLY e antes do registro deixa o banco fora do
  # retrato anterior, e a retomada reconhece o índice pelo marcador do começo do plano, sem acusar deriva da base.
  def index_first_checks
    check('o plano só de índices começa por um passo fora de transação') do
      @plan.steps.first.transaction == 'nao'
    end
    check('queda depois do primeiro índice e antes do registro: a retomada aceita o índice e conclui') do
      name = initial_database
      crashed = connect(name)
      fell = begin
        migrate(crashed, database: CrashingDatabase.new(crash_at: 1, connection: crashed, pg_dump: @pg_dump))
        false
      rescue Crash
        true
      end
      crashed.close
      resumed = connect(name)
      begin
        marker = resumed.exec("SELECT count(*) FROM vetra.migration_steps WHERE step = 0").getvalue(0, 0) == '1'
        fell && marker && steps(resumed).empty? && migrate(resumed).status == :applied && steps(resumed) == expected_steps &&
          indexes_valid?(resumed)
      ensure
        resumed.close
      end
    end
    check('um índice homônimo com outra definição, criado entre a queda e a retomada, é deriva e não é registrado') do
      name = initial_database
      step = @plan.steps.last
      index = step.sql[/"([^"]+)" ON/, 1]
      crashed = connect(name)
      begin
        migrate(crashed, database: CrashingDatabase.new(crash_at: step.number, before: true, connection: crashed, pg_dump: @pg_dump))
      rescue Crash
        nil
      ensure
        crashed.close
      end
      admin = connect(name, as: nil)
      begin
        admin.exec("CREATE INDEX #{PG::Connection.quote_ident(index)} ON public.leads (name)")
      ensure
        admin.close
      end
      resumed = connect(name)
      begin
        refused('db_migrate_drift') { migrate(resumed) } && steps(resumed).size == step.number - 1 &&
          plans_recorded(resumed) == %w[0001_inicial]
      ensure
        resumed.close
      end
    end
    check('um índice homônimo com as mesmas colunas, mas uma delas em INCLUDE, também é deriva') do
      name = initial_database
      step = @plan.steps.find { |item| item.sql.include?('("company_id", "created_at")') }
      index = step.sql[/"([^"]+)" ON/, 1]
      crashed = connect(name)
      begin
        migrate(crashed, database: CrashingDatabase.new(crash_at: step.number, before: true, connection: crashed, pg_dump: @pg_dump))
      rescue Crash
        nil
      ensure
        crashed.close
      end
      admin = connect(name, as: nil)
      begin
        admin.exec("CREATE INDEX #{PG::Connection.quote_ident(index)} ON public.leads (company_id) INCLUDE (created_at)")
      ensure
        admin.close
      end
      resumed = connect(name)
      begin
        refused('db_migrate_drift') { migrate(resumed) } && steps(resumed).none? { |row| row[1] == step.number.to_s }
      ensure
        resumed.close
      end
    end
  end

  def run_checks
    check('o segundo plano é por passo e tem passos dentro e fora de transação') do
      @plan.transaction == 'por_passo' && outside_steps.size >= 2 && @plan.steps.any? { |step| step.transaction == 'sim' }
    end

    name = initial_database
    connection = connect(name)
    check('aplica o segundo plano passo a passo sobre o inicial com dados, registra cada passo e o plano') do
      result = migrate(connection)
      result.status == :applied && result.applied.map(&:file_name) == ['0002_expand.sql'] &&
        steps(connection) == expected_steps && plans_recorded(connection) == %w[0001_inicial 0002_expand] &&
        leads(connection) == 2000 && indexes_valid?(connection)
    end
    check('segunda execução não aplica nada e confere o esquema com o retrato') do
      migrate(connection).status == :up_to_date
    end
    check('vetra_app não lê vetra.migration_steps') do
      app = connect(name, as: 'vetra_app')
      begin
        app.exec('SELECT 1 FROM vetra.migration_steps')
        false
      rescue PG::InsufficientPrivilege
        true
      ensure
        app.close
      end
    end
    connection.close

    @plan.steps.each do |step|
      check("queda no passo #{step.number} (#{step.transaction == 'nao' ? 'fora de transação, depois do DDL e antes do registro' : 'dentro da transação'}): a nova execução retoma e conclui") do
        name = initial_database
        crashed = connect(name)
        database = CrashingDatabase.new(crash_at: step.number, connection: crashed, pg_dump: @pg_dump)
        fell = begin
          migrate(crashed, database: database)
          false
        rescue Crash
          true
        end
        crashed.close
        resumed = connect(name)
        begin
          partial = steps(resumed).size == step.number - 1
          result = migrate(resumed)
          fell && partial && result.status == :applied && steps(resumed) == expected_steps && indexes_valid?(resumed) &&
            plans_recorded(resumed) == %w[0001_inicial 0002_expand] && leads(resumed) == 2000
        ensure
          resumed.close
        end
      end
    end

    check('um índice inválido de uma tentativa anterior é removido sem bloquear e criado de novo') do
      name = initial_database
      step = outside_steps.first
      index = step.sql[/"([^"]+)" ON/, 1]
      admin = connect(name, as: nil)
      begin
        admin.exec(step.sql)
        admin.exec_params("UPDATE pg_catalog.pg_index SET indisvalid = false WHERE indexrelid = to_regclass($1)", ["public.#{index}"])
        invalid = admin.exec_params('SELECT indisvalid FROM pg_catalog.pg_index WHERE indexrelid = to_regclass($1)', ["public.#{index}"]).getvalue(0, 0) == 'f'
      ensure
        admin.close
      end
      connection = connect(name)
      begin
        invalid && migrate(connection).status == :applied && indexes_valid?(connection) && steps(connection) == expected_steps
      ensure
        connection.close
      end
    end

    check('uma base que não é o retrato do plano inicial é recusada antes do primeiro passo') do
      name = initial_database
      connection = connect(name)
      begin
        connection.exec('ALTER TABLE public.leads ADD COLUMN extra integer')
        refused('db_migrate_drift') { migrate(connection) } &&
          connection.exec("SELECT to_regclass('vetra.migration_steps') IS NULL").getvalue(0, 0) == 't' &&
          plans_recorded(connection) == %w[0001_inicial]
      ensure
        connection.close
      end
    end

check('um parâmetro do banco posto depois do plano inicial é recusado antes de qualquer passo') do
  name = initial_database
  @admin.exec("ALTER DATABASE #{PG::Connection.quote_ident(name)} SET work_mem = '8MB'")
  connection = connect(name)
  begin
    refused('db_migrate_drift') { migrate(connection) } &&
      connection.exec("SELECT to_regclass('vetra.migration_steps') IS NULL").getvalue(0, 0) == 't'
  ensure
    connection.close
  end
end

    check('o lock_timeout de um passo é repetido com espera e o plano conclui quando o lock sai') do
      name = initial_database
      blocker = connect(name, as: nil)
      blocker.exec('BEGIN')
      # SHARE bloqueia o ADD COLUMN e o CREATE INDEX CONCURRENTLY, mas não o ACCESS SHARE do pg_dump da base.
      blocker.exec('LOCK TABLE public.leads IN SHARE MODE')
      waits = 0
      sleeper = lambda do |_seconds|
        waits += 1
        blocker.exec('COMMIT') if waits == 2
      end
      connection = connect(name)
      begin
        result = migrate(connection, sleeper: sleeper)
        result.status == :applied && waits == 2 && result.attempts == @plan.steps.size + 2 && steps(connection) == expected_steps
      ensure
        connection.close
        blocker.close
      end
    end

    check('um índice de mesmo nome em outra tabela é deriva, e o passo não fica registrado') do
      name = initial_database
      step = outside_steps.first
      index = step.sql[/"([^"]+)" ON/, 1]
      admin = connect(name, as: nil)
      begin
        admin.exec("CREATE INDEX #{PG::Connection.quote_ident(index)} ON public.companies (name)")
      ensure
        admin.close
      end
      connection = connect(name)
      begin
        refused('db_migrate_drift') { migrate(connection) } &&
          steps(connection).none? { |row| row[1] == step.number.to_s } && plans_recorded(connection) == %w[0001_inicial]
      ensure
        connection.close
      end
    end
  end
end

ok = IncrementalMigrateProbe.new(ENV.fetch('DATABASE_URL'), ENV.fetch('VETRA_PG_DUMP', 'pg_dump'), ENV['VETRA_MIGRATOR_PASSWORD']).run
exit(ok ? 0 : 1)

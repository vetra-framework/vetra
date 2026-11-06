require_relative 'test_helper'

class DBMigrateTest < GraphTest
  # Banco falso do Migrator: guarda o estado em memória, para testar a lógica sem PostgreSQL. A aplicação real é
  # conferida pela sonda script/sonda_db_migrate.rb.
  class FakeDatabase
    attr_accessor :user, :locked, :records, :objects, :dumped, :timeouts, :privilege_problems, :undumped
    attr_reader :applied_plans, :unlocked

    def initialize(dumped:)
      @user, @locked, @records, @objects, @dumped, @timeouts = 'vetra_migrator', false, [], [], dumped, 0
      @applied_plans, @unlocked, @privilege_problems, @undumped = [], false, [], []
    end

    def ensure_migrator!
      Vetra::SQL::MigrationDatabase.allocate.tap { |real| real.instance_variable_set(:@connection, self) }.ensure_migrator!
    end

    # Só o que ensure_migrator! consulta.
    def exec(_sql)
      Struct.new(:value) { def getvalue(*) = value }.new(@user)
    end

    def try_lock = !@locked
    def unlock = @unlocked = true
    def applied = @records.map(&:dup)
    def foreign_objects = @objects
    def database_privilege_problems = @privilege_problems
    def undumped_objects = @undumped
    def dump = @dumped

    def apply(plan, name, digest)
      if @timeouts.positive?
        @timeouts -= 1
        raise Vetra::SQL::MigrationDatabase::LockTimeout
      end
      @applied_plans << plan.file_name
      @records << { 'plan' => name, 'sha256' => digest }
      @objects = ['pg_class']
    end
  end

  def prepared(name = 'mini_crm_revendas')
    with_app(name) do |root, compiler|
      compiler.write
      Vetra::SQL::Planner.new(root: root).plan
      snapshot = "CREATE TABLE public.companies ();\n"
      File.write(File.join(root, 'db/schema.sql'), Vetra::SQL::Planner.render_schema([['0001_inicial', '0' * 64]], snapshot))
      yield root, snapshot
    end
  end

  def migrator(root, database, sleeps = [])
    Vetra::SQL::Migrator.new(root: root, database: database, sleeper: ->(seconds) { sleeps << seconds }, random: Random.new(1))
  end

  def test_applies_the_initial_plan_to_an_empty_database_and_records_its_hash
    prepared do |root, snapshot|
      database = FakeDatabase.new(dumped: snapshot)
      result = migrator(root, database).migrate
      assert_equal :applied, result.status
      assert_equal ['0001_inicial.sql'], database.applied_plans
      plan = Vetra::SQL::Plan.parse(File.read(File.join(root, 'db/plans/0001_inicial.sql')), file: 'db/plans/0001_inicial.sql')
      assert_equal [{ 'plan' => '0001_inicial', 'sha256' => Digest::SHA256.hexdigest(plan.render) }], database.records
      assert database.unlocked
      # Uma segunda execução reconhece o plano registrado e confere o esquema com o retrato.
      again = migrator(root, database).migrate
      assert_equal :up_to_date, again.status
      assert_equal ['0001_inicial.sql'], database.applied_plans
    end
  end

  def test_refuses_another_migrator_a_wrong_role_and_a_non_empty_database
    prepared do |root, snapshot|
      busy = FakeDatabase.new(dumped: snapshot)
      busy.locked = true
      assert_graph_error('db_migrate_locked') { migrator(root, busy).migrate }
      refute busy.unlocked
      app = FakeDatabase.new(dumped: snapshot)
      app.user = 'postgres'
      error = assert_graph_error('db_migrate_role') { migrator(root, app).migrate }
      assert_includes error.message, 'postgres'
      dirty = FakeDatabase.new(dumped: snapshot)
      dirty.objects = ['pg_collation']
      error = assert_graph_error('db_migrate_not_empty') { migrator(root, dirty).migrate }
      assert_includes error.message, 'pg_collation'
      assert_includes error.message, 'Nada foi alterado'
      assert_empty dirty.applied_plans
      assert dirty.unlocked
    end
  end

  def test_detects_an_altered_plan_an_unknown_record_and_drift
    prepared do |root, snapshot|
      database = FakeDatabase.new(dumped: snapshot)
      database.records = [{ 'plan' => '0001_inicial', 'sha256' => '0' * 64 }]
      error =assert_graph_error('db_migrate_altered') { migrator(root, database).migrate }
      assert_includes error.message, 'escreve-se outro'
      database.records = [{ 'plan' => '0002_outro', 'sha256' => '0' * 64 }]
      assert_graph_error('db_migrate_unknown') { migrator(root, database).migrate }
      migrator(root, fresh = FakeDatabase.new(dumped: snapshot)).migrate
      fresh.dumped = "CREATE TABLE public.companies (extra int);\n"
      error = assert_graph_error('db_migrate_drift') { migrator(root, fresh).migrate }
      assert_includes error.message, 'Nada foi alterado'
      # Privilégios do próprio banco, que o pg_dump --schema-only não mostra, também contam como deriva.
      fresh.dumped = snapshot
      fresh.privilege_problems = ['vetra_app pode criar objetos no banco (CREATE)']
      error = assert_graph_error('db_migrate_drift') { migrator(root, fresh).migrate }
      assert_includes error.message, 'vetra_app pode criar objetos'
      # Subscriptions e large objects, que o pg_dump --schema-only não mostra, também.
      fresh.privilege_problems = []
      fresh.undumped = ['large object (pg_largeobject_metadata)']
      error = assert_graph_error('db_migrate_drift') { migrator(root, fresh).migrate }
      assert_includes error.message, 'o banco tem large object'
      # O esquema que diverge do retrato logo depois da aplicação também é apontado, sem dizer que nada mudou.
      drifted = FakeDatabase.new(dumped: "CREATE TABLE public.outra ();\n")
      error = assert_graph_error('db_migrate_drift') { migrator(root, drifted).migrate }
      assert_includes error.message, 'foram aplicados'
      refute_includes error.message, 'Nada foi alterado'
    end
  end

  def test_retries_lock_timeouts_with_backoff_and_gives_up_without_applying
    prepared do |root, snapshot|
      database = FakeDatabase.new(dumped: snapshot)
      database.timeouts = 2
      sleeps = []
      result = migrator(root, database, sleeps).migrate
      assert_equal 3, result.attempts
      assert_equal 2, sleeps.size
      sleeps.zip([1, 2]).each { |slept, base| assert_in_delta base, slept, base * Vetra::SQL::Migrator::JITTER }
      stuck = FakeDatabase.new(dumped: snapshot)
      stuck.timeouts = 99
      sleeps = []
      error = assert_graph_error('db_migrate_lock_timeout') { migrator(root, stuck, sleeps).migrate }
      assert_includes error.message, '6 tentativas'
      assert_equal 5, sleeps.size
      assert_empty stuck.applied_plans
      assert stuck.unlocked
    end
  end

  def test_only_plans_that_the_ir_generates_are_migrated
    prepared do |root, snapshot|
      edit(root, 'db/plans/0001_inicial.sql') { |text| text.sub(/;\n\z/, ";\nCOMMENT ON DATABASE postgres IS 'x';\n") }
      database = FakeDatabase.new(dumped: snapshot)
      assert_graph_error('db_plan_forbidden') { migrator(root, database).migrate }
      # Uma edição permitida pelo filtro também é recusada: o plano deixa de ser o que a cadeia de modelos prende.
      edit(root, 'db/plans/0001_inicial.sql') { |text| text.sub('COMMENT ON DATABASE postgres', 'COMMENT ON SCHEMA public') }
      assert_graph_error('db_model_chain') { migrator(root, database).migrate }
      assert_empty database.applied_plans
      FileUtils.rm(File.join(root, 'db/schema.sql'))
      FileUtils.rm_rf(File.join(root, 'db/models'))
      Vetra::SQL::Planner.new(root: root).tap { FileUtils.rm(File.join(root, 'db/plans/0001_inicial.sql')) }.plan
      assert_graph_error('db_schema_missing') { migrator(root, FakeDatabase.new(dumped: snapshot)).migrate }
      FileUtils.rm(File.join(root, 'db/plans/0001_inicial.sql'))
      assert_graph_error('db_plan_missing') { migrator(root, FakeDatabase.new(dumped: snapshot)).migrate }
    end
  end

  def test_connection_requires_the_driver_and_hides_the_url
    error = assert_graph_error('db_driver') { Vetra::SQL::MigrationDatabase.connect('postgres://x', driver: -> { raise LoadError }) }
    assert_includes error.message, 'gem pg'
    error = assert_graph_error('db_connection') { Vetra::SQL::MigrationDatabase.connect('postgres://usuario:segredo%zz@127.0.0.1:1/x') }
    refute_includes error.message, 'segredo'
  end

  def test_cli_requires_database_url_and_refuses_extra_options
    prepared do |root, _snapshot|
      previous = ENV.delete('DATABASE_URL')
      begin
        err = StringIO.new
        assert_equal 1, Vetra::CLI.run(['db:migrate', '--root', root], out: StringIO.new, err: err)
        assert_includes err.string, '[db_database_url]'
      ensure
        ENV['DATABASE_URL'] = previous if previous
      end
      assert_equal 2, Vetra::CLI.run(['db:migrate', '--check', '--root', root], out: StringIO.new, err: StringIO.new)
      assert_equal 2, Vetra::CLI.run(['db:migrate', 'extra', '--root', root], out: StringIO.new, err: StringIO.new)
    end
  end
end

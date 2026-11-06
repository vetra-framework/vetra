require_relative 'test_helper'

class DBMigrateTest < GraphTest
  # Banco falso do Migrator: guarda o estado em memória, para testar a lógica sem PostgreSQL. A aplicação real é
  # conferida pela sonda script/sonda_db_migrate.rb.
  class FakeDatabase
    attr_accessor :user, :locked, :records, :objects, :dumped, :timeouts, :privilege_problems, :undumped, :steps, :fail_at, :start_timeouts
    attr_reader :applied_plans, :unlocked, :applied_steps

    def initialize(dumped:)
      @user, @locked, @records, @objects, @dumped, @timeouts = 'vetra_migrator', false, [], [], dumped, 0
      @applied_plans, @unlocked, @privilege_problems, @undumped = [], false, [], []
      @steps, @applied_steps, @fail_at, @start_timeouts = [], [], nil, 0
    end

    def step_plans = @steps.map { |row| row['plan'] }.uniq.sort
    def steps_done(name) = @steps.select { |row| row['plan'] == name }.map(&:dup)
    def mark_started(name, digest)
      if @start_timeouts.positive?
        @start_timeouts -= 1
        raise Vetra::SQL::MigrationDatabase::LockTimeout
      end
      @steps << { 'plan' => name, 'step' => '0', 'sha256' => digest }
    end
    # Só os passos aplicados, sem o marcador do começo do plano (passo 0).
    def applied_rows = @steps.reject { |row| row['step'] == '0' }

    # Um passo com lock_timeout pendente falha sem registro; fail_at simula a queda do processo antes do registro.
    def apply_step(plan, name, digest, step, last:)
      if @timeouts.positive?
        @timeouts -= 1
        raise Vetra::SQL::MigrationDatabase::LockTimeout
      end
      @applied_steps << [name, step.number]
      raise IOError, 'queda simulada' if @fail_at == [name, step.number]
      @steps << { 'plan' => name, 'step' => step.number.to_s, 'sha256' => Digest::SHA256.hexdigest(step.sql) }
      return unless last
      @applied_plans << plan.file_name
      @records << { 'plan' => name, 'sha256' => digest }
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
      File.write(File.join(root, 'db/schema.sql'), Vetra::SQL::Planner.render_schema([['0001_inicial', Digest::SHA256.hexdigest(snapshot)]], snapshot))
      yield root, snapshot
    end
  end

  def migrator(root, database, sleeps = [])
    Vetra::SQL::Migrator.new(root: root, database: database, sleeper: ->(seconds) { sleeps << seconds }, random: Random.new(1))
  end

  # Um segundo plano por passo, com o retrato de duas bases. O banco falso devolve sempre o mesmo dump, então as duas
  # bases são o hash dele.
  def incremental(root, snapshot)
    # Dois índices novos: dois passos fora de transação, para haver um meio de plano onde parar.
    edit(root, 'app/domains/blog/post.rb') { |text| text.sub('  crud', "  index :title\n  index :published_at\n  crud") }
    Vetra::Graph::Compiler.new(root: root).write
    Vetra::SQL::Planner.new(root: root).plan
    digest = Digest::SHA256.hexdigest(snapshot)
    File.write(File.join(root, 'db/schema.sql'), Vetra::SQL::Planner.render_schema([['0001_inicial', digest], ['0002_expand', digest]], snapshot))
    Vetra::SQL::Plan.parse(File.read(File.join(root, 'db/plans/0002_expand.sql')), file: 'db/plans/0002_expand.sql')
  end

  def test_applies_the_initial_plan_and_then_the_incremental_one_step_by_step
    prepared('blog') do |root, snapshot|
      second = incremental(root, snapshot)
      assert_equal 'por_passo', second.transaction
      database = FakeDatabase.new(dumped: snapshot)
      result = migrator(root, database).migrate
      assert_equal :applied, result.status
      assert_equal %w[0001_inicial.sql 0002_expand.sql], result.applied.map(&:file_name)
      assert_equal %w[0001_inicial 0002_expand], database.records.map { |record| record['plan'] }
      assert_equal second.steps.map { |step| ['0002_expand', step.number] }, database.applied_steps
      assert_equal second.steps.map { |step| Digest::SHA256.hexdigest(step.sql) }, database.applied_rows.map { |row| row['sha256'] }
      assert_equal [['0002_expand', '0', Vetra::SQL::Migrator.digest(second)]], database.steps.select { |row| row['step'] == '0' }.map(&:values)
      assert database.unlocked
      assert_equal 0, result.retries
      assert_operator result.attempts, :>, result.applied.size
      assert_equal :up_to_date, migrator(root, database).migrate.status
    end
  end

  def test_an_interrupted_incremental_plan_resumes_from_the_next_step_without_rechecking_the_base
    prepared('blog') do |root, snapshot|
      second = incremental(root, snapshot)
      database = FakeDatabase.new(dumped: snapshot)
      database.fail_at = ['0002_expand', second.steps.size]
      assert_raises(IOError) { migrator(root, database).migrate }
      assert_equal %w[0001_inicial], database.records.map { |record| record['plan'] }
      done = database.applied_rows.size
      assert_equal second.steps.size - 1, done
      # No meio do plano o banco está entre dois retratos: a base não é conferida de novo, só o estado final.
      database.fail_at = nil
      dumps = 0
      database.define_singleton_method(:dump) { dumps += 1; @dumped }
      result = migrator(root, database).migrate
      assert_equal 1, dumps
      assert_equal :applied, result.status
      assert_equal %w[0002_expand.sql], result.applied.map(&:file_name)
      assert_equal [['0002_expand', second.steps.size]], database.applied_steps.last(1)
      assert_equal second.steps.size, database.applied_rows.size
    end
  end

  def test_the_base_is_checked_before_the_first_step_and_progress_is_checked_step_by_step
    prepared('blog') do |root, snapshot|
      second = incremental(root, snapshot)
      initial = Vetra::SQL::Plan.parse(File.read(File.join(root, 'db/plans/0001_inicial.sql')), file: 'db/plans/0001_inicial.sql')
      database = FakeDatabase.new(dumped: "CREATE TABLE public.companies (extra int);\n")
      database.records = [{ 'plan' => '0001_inicial', 'sha256' => Vetra::SQL::Migrator.digest(initial) }]
      error = assert_graph_error('db_migrate_drift') { migrator(root, database).migrate }
      assert_includes error.message, '0001_inicial.sql'
      assert_includes error.message, 'Nada foi alterado'
      assert_empty database.applied_steps
      # Um passo registrado com outro hash é um passo editado depois de aplicado.
      database.dumped = snapshot
      marker = { 'plan' => '0002_expand', 'step' => '0', 'sha256' => Vetra::SQL::Migrator.digest(second) }
      database.steps = [marker, { 'plan' => '0002_expand', 'step' => '1', 'sha256' => '0' * 64 }]
      assert_graph_error('db_migrate_altered') { migrator(root, database).migrate }
      # O marcador guarda o SHA-256 do plano: um plano editado no meio da aplicação é recusado.
      database.steps = [marker.merge('sha256' => '0' * 64)]
      error = assert_graph_error('db_migrate_altered') { migrator(root, database).migrate }
      assert_includes error.message, 'em andamento'
      # Passos registrados sem o começo do plano não vêm do db:migrate.
      database.steps = [{ 'plan' => '0002_expand', 'step' => '1', 'sha256' => Digest::SHA256.hexdigest(second.steps.first.sql) }]
      assert_graph_error('db_migrate_unknown') { migrator(root, database).migrate }
      database.steps = [marker] + second.steps.map { |step| { 'plan' => '0002_expand', 'step' => step.number.to_s, 'sha256' => Digest::SHA256.hexdigest(step.sql) } } +
                       [{ 'plan' => '0002_expand', 'step' => (second.steps.size + 1).to_s, 'sha256' => '0' * 64 }]
      assert_graph_error('db_migrate_unknown') { migrator(root, database).migrate }
      # Passos de um plano que não é o próximo também não pertencem ao banco.
      database.steps = [{ 'plan' => '0003_expand', 'step' => '1', 'sha256' => '0' * 64 }]
      error = assert_graph_error('db_migrate_unknown') { migrator(root, database).migrate }
      assert_includes error.message, '0003_expand'
      # Um retrato sem a base de cada plano não serve para conferir.
      database.steps = []
      File.write(File.join(root, 'db/schema.sql'), Vetra::SQL::Planner.render_schema([['0001_inicial', Digest::SHA256.hexdigest(snapshot)]], snapshot))
      assert_graph_error('db_schema_stale') { migrator(root, database).migrate }
    end
  end

  # Conexão falsa do adaptador: registra os comandos e responde à consulta do índice com a linha dada.
  class StepConnection
    Rows = Struct.new(:rows) { def first = rows.first }
    attr_reader :commands

    def initialize(index: nil, fail_on: nil, state: nil)
      @index, @fail_on, @state, @commands = index, fail_on, state, []
    end

    def exec(sql)
      @commands << sql
      if @fail_on && sql.start_with?(@fail_on)
        error = PG::LockNotAvailable.new('lock timeout')
        result = Struct.new(:state) { def error_field(*) = state }.new(@state)
        error.define_singleton_method(:result) { result }
        raise error
      end
      Rows.new([])
    end

    def exec_params(sql, params)
      @commands << [sql.lines.first.strip, params]
      Rows.new(sql.include?('pg_index') && @index ? [@index] : [])
    end
  end

  def step_plan(sql_steps)
    steps = sql_steps.each_with_index.map do |(sql, transaction), index|
      Vetra::SQL::Plan::Step.new(number: index + 1, phase: 'expand', lock: 'nenhum', cost: 'catalogo', sql: sql, transaction: transaction)
    end
    Vetra::SQL::Plan.new(number: '0002', name: 'expand', transaction: 'por_passo', steps: steps)
  end

  def test_the_adapter_records_each_step_and_recognizes_an_index_left_by_an_earlier_attempt
    require 'pg'
    index = 'CREATE INDEX CONCURRENTLY "vt_ix_a" ON "public"."posts" ("title");'
    plan = step_plan([[index, 'nao'], ['CREATE TABLE "public"."u" ("id" uuid);', 'sim']])
    run = lambda do |connection, step, last|
      Vetra::SQL::MigrationDatabase.new(connection: connection).apply_step(plan, '0002_expand', 'a' * 64, step, last: last)
      connection.commands.map { |command| command.is_a?(Array) ? command.first : command.lines.first.strip }
    end
    # Sem índice prévio: lock_timeout de sessão, o índice, e o registro do passo numa transação curta.
    fresh = run.call(StepConnection.new, plan.steps[0], false)
    assert_equal ["SET lock_timeout = '3s'", 'BEGIN', "SET LOCAL search_path = ''", 'SELECT i.indisvalid,', 'COMMIT', index,
                  'RESET lock_timeout', 'BEGIN', "SET LOCAL lock_timeout = '3s'"], fresh.first(9)
    assert_includes fresh, 'INSERT INTO "vetra"."migration_steps" (plan, step, sha256) VALUES ($1, $2, $3)'
    refute_includes fresh, 'INSERT INTO "vetra"."migrations" (plan, sha256, steps) VALUES ($1, $2, $3)'
    assert_equal 'COMMIT', fresh.last
    # Índice válido na mesma tabela: é o efeito de uma tentativa anterior, aceito sem criar de novo.
    definition = { 'indisvalid' => 't', 'same' => 't' }
    valid = run.call(StepConnection.new(index: definition), plan.steps[0], false)
    refute_includes valid, index
    assert_includes valid, 'INSERT INTO "vetra"."migration_steps" (plan, step, sha256) VALUES ($1, $2, $3)'
    # Índice inválido (CONCURRENTLY interrompido): removido sem bloquear e criado de novo.
    invalid = run.call(StepConnection.new(index: definition.merge('indisvalid' => 'f')), plan.steps[0], false)
    assert_operator invalid.index('DROP INDEX CONCURRENTLY IF EXISTS "public"."vt_ix_a"'), :<, invalid.index(index)
    # O mesmo nome em outra tabela é deriva, sem tocar no banco.
    # Um índice homônimo cuja definição (pg_get_indexdef) não é a do passo é deriva, válido ou não, e não é removido.
    [{ 'same' => 'f' }, { 'same' => 'f', 'indisvalid' => 'f' }].each do |difference|
      other = StepConnection.new(index: definition.merge(difference))
      assert_graph_error('db_migrate_drift') { run.call(other, plan.steps[0], false) }
      refute_includes other.commands, index, difference.inspect
      refute other.commands.any? { |command| command.is_a?(String) && command.start_with?('DROP INDEX') }, difference.inspect
    end
    # Passo em transação: instrução e registro na mesma transação; o último passo grava também o plano.
    last = run.call(StepConnection.new, plan.steps[1], true)
    assert_equal ['BEGIN', "SET LOCAL lock_timeout = '3s'", plan.steps[1].sql], last.first(3)
    assert_includes last, 'INSERT INTO "vetra"."migrations" (plan, sha256, steps) VALUES ($1, $2, $3)'
    assert_equal 'COMMIT', last.last
    # 55P03 vira LockTimeout, para o Migrator repetir o passo; outro erro diz o plano e o passo.
    assert_raises(Vetra::SQL::MigrationDatabase::LockTimeout) { run.call(StepConnection.new(fail_on: 'CREATE TABLE', state: '55P03'), plan.steps[1], true) }
    error = assert_graph_error('db_plan_apply') { run.call(StepConnection.new(fail_on: 'CREATE TABLE', state: '42P07'), plan.steps[1], true) }
    assert_includes error.message, 'passo 2'
  end

def test_catalog_drift_in_a_migrated_database_is_refused_before_any_pending_step
  prepared('blog') do |root, snapshot|
    incremental(root, snapshot)
    initial = Vetra::SQL::Plan.parse(File.read(File.join(root, 'db/plans/0001_inicial.sql')), file: 'db/plans/0001_inicial.sql')
    [[:privilege_problems=, ['vetra_app pode criar objetos no banco (CREATE)']], [:undumped=, ['parâmetro por banco (pg_db_role_setting)']]].each do |setter, value|
      database = FakeDatabase.new(dumped: snapshot)
      database.records = [{ 'plan' => '0001_inicial', 'sha256' => Vetra::SQL::Migrator.digest(initial) }]
      database.public_send(setter, value)
      error = assert_graph_error('db_migrate_drift') { migrator(root, database).migrate }
      assert_includes error.message, 'Nada foi alterado'
      assert_empty database.steps
    end
  end
end

  def test_lock_timeouts_are_retried_per_step_and_exhaustion_registers_nothing_of_that_step
    prepared('blog') do |root, snapshot|
      second = incremental(root, snapshot)
      initial = Vetra::SQL::Plan.parse(File.read(File.join(root, 'db/plans/0001_inicial.sql')), file: 'db/plans/0001_inicial.sql')
      database = FakeDatabase.new(dumped: snapshot)
      database.records = [{ 'plan' => '0001_inicial', 'sha256' => Vetra::SQL::Migrator.digest(initial) }]
      database.timeouts = 2
      sleeps = []
      result = migrator(root, database, sleeps).migrate
      assert_equal second.steps.size + 2, result.attempts
      assert_equal 2, result.retries
      assert_equal 2, sleeps.size
      # O registro do começo do plano também é repetido com espera, e esgotado não aplica nenhum passo.
      starting = FakeDatabase.new(dumped: snapshot)
      starting.records = database.records.first(1)
      starting.start_timeouts = 2
      result = migrator(root, starting, []).migrate
      assert_equal :applied, result.status
      assert_equal 2, result.retries
      blocked = FakeDatabase.new(dumped: snapshot)
      blocked.records = database.records.first(1)
      blocked.start_timeouts = 99
      error = assert_graph_error('db_migrate_lock_timeout') { migrator(root, blocked, []).migrate }
      assert_includes error.message, 'registro do começo'
      assert_empty blocked.steps
      stuck = FakeDatabase.new(dumped: snapshot)
      stuck.records = database.records.first(1)
      stuck.timeouts = 99
      error = assert_graph_error('db_migrate_lock_timeout') { migrator(root, stuck, []).migrate }
      assert_includes error.message, 'passo 1'
      assert_includes error.message, '6 tentativas'
      assert_empty stuck.applied_rows
    end
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

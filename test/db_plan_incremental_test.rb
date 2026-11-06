require_relative 'test_helper'
require_relative 'db_plan_test'
require_relative 'db_migrate_test'
require 'pg'

# Fundação do plano incremental (ADR-038): modelo versionado, cadeia, transação por passo, filtro de instruções
# globais, contenção do banco descartável e convergência. A diferença real entre modelos é da C9; aqui uma diferença
# de teste só cria os índices novos.
class DBPlanIncrementalTest < GraphTest
  class FakeDatabase
    attr_reader :calls

    def initialize(dump, fresh: nil)
      @dump, @fresh, @calls = dump, fresh || dump, []
    end

    def replay(plans)
      @calls << plans.map(&:file_name)
      plans.size == 1 && plans.first.file_name == '0001_inicial.sql' && @calls.size > 1 ? [@fresh] : [@dump] * plans.size
    end
  end

  # Diferença de teste: cada índice novo da IR vira um passo CREATE INDEX CONCURRENTLY fora de transação.
  INDEXES = lambda do |base:, schema:, number:|
    known = base.state['tables'].flat_map { |table| table['indexes'].map { |index| index['name'] } }
    steps = schema.tables.flat_map do |table|
      table['indexes'].reject { |index| known.include?(index['name']) }.map do |index|
        columns = index['columns'].map { |column| %("#{column}") }.join(', ')
        %(CREATE INDEX CONCURRENTLY "#{index['name']}" ON "#{table['schema']}"."#{table['table']}" (#{columns});)
      end
    end
    raise 'nenhum índice novo' if steps.empty?
    built = steps.each_with_index.map do |sql, offset|
      lock, cost = Vetra::SQL::Plan.classify(sql)
      Vetra::SQL::Plan::Step.new(number: offset + 1, phase: 'expand', lock: lock, cost: cost, sql: sql, transaction: 'nao')
    end
    Vetra::SQL::Plan.new(number: number, name: 'indices', transaction: 'por_passo', steps: built)
  end

  def planner(root, database = nil, differ: Vetra::SQL::Planner::REFUSE)
    Vetra::SQL::Planner.new(root: root, database: database, differ: differ)
  end

  def model_path(root, name = '0001_inicial')
    File.join(root, "db/models/#{name}.json")
  end

  def add_index(root)
    edit(root, 'app/domains/crm/lead.rb') { |text| text.sub('  crud', "  index :company_id, :created_at\n  crud") }
  end

  def test_plan_writes_a_canonical_model_chained_to_the_plan
    with_app('mini_crm') do |root, compiler|
      document = compiler.write.document
      planner(root).plan
      text = File.read(model_path(root))
      model = Vetra::SQL::Model.new(file: '0001_inicial.json', text: text)
      plan_text = File.read(File.join(root, 'db/plans/0001_inicial.sql'))
      entry = { 'file' => '0001_inicial.sql', 'sha256' => Digest::SHA256.hexdigest(plan_text) }
      assert_equal entry, model.document['plan']
      assert_equal [entry], model.document['plans']
      assert_nil model.document['previous']
      schema = Vetra::SQL::Schema.new(document).generate
      plan = Vetra::SQL::Plan.parse(plan_text, file: 'db/plans/0001_inicial.sql')
      assert_equal plan.steps.size, model.state['statements'].size
      assert_equal plan.steps.map { |step| Digest::SHA256.hexdigest(step.sql) }, model.state['statements'].map { |item| item['sha256'] }
      kinds = model.state['statements'].map { |item| item['kind'] }.uniq
      assert_includes kinds, 'policy'
      assert_includes kinds, 'function'
      assert_includes model.state['statements'].map { |item| item['object'] }, 'vetra.current_tenant()'
      assert_equal schema.tables.map { |table| table['table'] }, model.state['tables'].map { |table| table['table'] }
      assert model.frozen?
      assert_equal :unchanged, planner(root).plan.status
    end
  end

  def test_an_initial_plan_without_model_receives_the_model_the_same_ir_generates
    with_app('blog') do |root, compiler|
      compiler.write
      planner(root).plan
      expected = File.read(model_path(root))
      FileUtils.rm(model_path(root))
      result = planner(root).plan
      assert_equal :written, result.status
      assert_equal model_path(root), result.path
      assert_equal expected, File.read(model_path(root))
      # Um espelho de políticas divergente também impede gravar o modelo.
      FileUtils.rm(model_path(root))
      policies = File.join(root, 'db/policies/0001_seguranca.sql')
      original = File.read(policies)
      File.write(policies, "#{original}-- editado\n")
      assert_graph_error('db_policies_stale') { planner(root).plan }
      refute File.exist?(model_path(root))
      File.write(policies, original)
      # Um plano inicial que a IR não gera não ganha modelo.
      edit(root, 'db/plans/0001_inicial.sql') { |text| text.sub(/;\n\z/, ";\nCOMMENT ON SCHEMA public IS 'x';\n") }
      assert_graph_error('db_model_chain') { planner(root).plan }
      refute File.exist?(model_path(root))
    end
  end

  def test_models_outside_the_format_or_the_chain_are_refused
    with_app('blog') do |root, compiler|
      compiler.write
      planner(root).plan
      good = File.read(model_path(root))
      document = JSON.parse(good)
      {
        'não canônico' => good.sub("\n", "\n\n"),
        'JSON' => '{',
        'chaves' => Vetra::SQL::Model.render(document.merge('extra' => 1)),
        'versão' => Vetra::SQL::Model.render(document.merge('version' => 2)),
        'plano' => Vetra::SQL::Model.render(document.merge('plan' => { 'file' => '0001_inicial.sql' })),
        'estado' => Vetra::SQL::Model.render(document.merge('state' => { 'tables' => [] }))
      }.each do |label, text|
        error = assert_raises(Vetra::Graph::Error, label) { Vetra::SQL::Model.new(file: '0001_inicial.json', text: text) }
        assert_includes error.diagnostics.map(&:code), 'db_model_format', label
      end
      assert_graph_error('db_model_format') { Vetra::SQL::Model.new(file: 'inicial.json', text: good) }
      FileUtils.mkdir_p(File.join(root, 'db/models/rascunho'))
      assert_graph_error('db_model_format') { planner(root).plan }
      FileUtils.rm_rf(File.join(root, 'db/models/rascunho'))
      # Um modelo canônico que não corresponde ao plano quebra a cadeia.
      write(root, 'db/models/0001_inicial.json', Vetra::SQL::Model.render(document.merge('plan' => { 'file' => '0001_inicial.sql', 'sha256' => '0' * 64 })))
      assert_graph_error('db_model_chain') { planner(root).plan }
      write(root, 'db/models/0001_inicial.json', good)
      write(root, 'db/models/0002_outro.json', Vetra::SQL::Model.render(document.merge('plan' => document['plan'].merge('file' => '0002_outro.sql'))))
      assert_graph_error('db_model_chain') { planner(root).plan }
      FileUtils.rm(model_path(root, '0002_outro'))
      FileUtils.rm(File.join(root, 'db/plans/0001_inicial.sql'))
      error = assert_graph_error('db_model_chain') { planner(root).plan }
      assert_includes error.message, 'modelos sem plano'
    end
  end

  def test_a_second_plan_runs_step_by_step_and_chains_the_models
    with_app('mini_crm') do |root, compiler|
      compiler.write
      planner(root).plan
      add_index(root)
      compiler.write
      assert_graph_error('db_plan_incremental') { planner(root).plan }
      result = planner(root, differ: INDEXES).plan
      assert_equal :written, result.status
      text = File.read(File.join(root, 'db/plans/0002_indices.sql'))
      assert text.start_with?("-- vetra:plano 0002 indices\n-- vetra:transacao por_passo\n")
      assert_includes text, 'lock=ShareUpdateExclusive custo=varre_tabela transacao=nao'
      first, second = %w[0001_inicial 0002_indices].map { |name| Vetra::SQL::Model.new(file: "#{name}.json", text: File.read(model_path(root, name))) }
      assert_equal({ 'file' => '0001_inicial.json', 'sha256' => Digest::SHA256.hexdigest(first.text) }, second.document['previous'])
      assert_equal first.document['plans'] + [second.document['plan']], second.document['plans']
      assert_equal :unchanged, planner(root, differ: INDEXES).plan.status
      # Com a diferença padrão, o último plano não pode ser recalculado: a C9 ainda não existe.
      assert_graph_error('db_plan_incremental') { planner(root).plan }
      # Editar o plano antigo, o modelo antigo ou remover o plano novo quebra a cadeia.
      original = File.read(File.join(root, 'db/plans/0001_inicial.sql'))
      edit(root, 'db/plans/0001_inicial.sql') { |plan| plan.sub(/;\n\z/, ";\nCOMMENT ON SCHEMA public IS 'x';\n") }
      assert_graph_error('db_model_chain') { planner(root, differ: INDEXES).plan }
      write(root, 'db/plans/0001_inicial.sql', original)
      FileUtils.mv(File.join(root, 'db/plans/0002_indices.sql'), File.join(root, 'fora.sql'))
      assert_graph_error('db_model_chain') { planner(root, differ: INDEXES).plan }
      FileUtils.mv(File.join(root, 'fora.sql'), File.join(root, 'db/plans/0002_indices.sql'))
      # Um último plano que difere do recalculado é recusado como desatualizado.
      edit(root, 'db/plans/0002_indices.sql') { |plan| plan.sub('custo=varre_tabela', 'custo=catalogo') }
      edit(root, 'db/models/0002_indices.json') do |model|
        document = JSON.parse(model)
        sha = Digest::SHA256.hexdigest(File.read(File.join(root, 'db/plans/0002_indices.sql')))
        document['plan']['sha256'] = sha
        document['plans'][-1]['sha256'] = sha
        Vetra::SQL::Model.render(document)
      end
      assert_graph_error('db_plan_stale') { planner(root, differ: INDEXES).plan }
    end
  end

  def test_check_replays_every_plan_writes_the_bases_and_proves_convergence
    with_app('mini_crm') do |root, compiler|
      compiler.write
      planner(root).plan
      add_index(root)
      compiler.write
      planner(root, differ: INDEXES).plan
      database = FakeDatabase.new("CREATE TABLE public.t ();\n")
      planner(root, database, differ: INDEXES).snapshot
      assert_equal [%w[0001_inicial.sql 0002_indices.sql], ['0001_inicial.sql']], database.calls
      snapshot = File.read(File.join(root, 'db/schema.sql'))
      parsed = Vetra::SQL::Planner.parse_schema(snapshot)
      digest = Digest::SHA256.hexdigest("CREATE TABLE public.t ();\n")
      assert_equal [['0001_inicial', digest], ['0002_indices', digest]], parsed[:bases]
      assert_equal "CREATE TABLE public.t ();\n", parsed[:body]
      assert_equal "CREATE TABLE public.t ();\n", Vetra::SQL::Planner.schema_body(snapshot)
      assert_equal :checked, planner(root, FakeDatabase.new("CREATE TABLE public.t ();\n"), differ: INDEXES).check.status
      error = assert_graph_error('db_plan_convergence') do
        planner(root, FakeDatabase.new("CREATE TABLE public.t ();\n", fresh: "CREATE TABLE public.u ();\n"), differ: INDEXES).check
      end
      assert_includes error.message, '0002_indices.sql'
      # Um retrato sem as bases, ou com outras, não confere.
      write(root, 'db/schema.sql', Vetra::SQL::Planner.render_schema([], "CREATE TABLE public.t ();\n"))
      assert_graph_error('db_schema_stale') { planner(root, FakeDatabase.new("CREATE TABLE public.t ();\n"), differ: INDEXES).check }
      assert_nil Vetra::SQL::Planner.parse_schema("outro\n")
      # A IR que mudou depois do último plano deixa check e snapshot desatualizados, sem acessar o banco.
      edit(root, 'app/domains/crm/lead.rb') { |text| text.sub("  index :company_id, :created_at\n", '') }
      compiler.write
      untouched = FakeDatabase.new("x\n")
      assert_graph_error('db_plan_stale') { planner(root, untouched, differ: INDEXES).check }
      assert_empty untouched.calls
    end
  end

  def test_step_by_step_plans_follow_the_transaction_rules
    concurrent = 'CREATE INDEX CONCURRENTLY "i" ON "public"."t" ("a");'
    step = ->(sql, transaction) { Vetra::SQL::Plan::Step.new(number: 1, phase: 'expand', lock: 'nenhum', cost: 'catalogo', sql: sql, transaction: transaction) }
    plan = Vetra::SQL::Plan.new(number: '0002', name: 'x', transaction: 'por_passo',
                                steps: [step.call(concurrent, 'nao'), step.call('CREATE TABLE "public"."u" ("id" uuid);', 'sim').tap { |s| s.number = 2 }])
    parsed = Vetra::SQL::Plan.parse(plan.render, file: 'db/plans/0002_x.sql')
    assert_equal %w[nao sim], parsed.steps.map(&:transaction)
    assert_equal plan.render, parsed.render
    {
      'duas instruções fora de transação' => [[step.call("#{concurrent}\n#{concurrent}", 'nao')], 'por_passo'],
      'forma comum fora de transação' => [[step.call('CREATE INDEX "i" ON "public"."t" ("a");', 'nao')], 'por_passo'],
      'CONCURRENTLY em transação' => [[step.call(concurrent, 'sim')], 'por_passo'],
      'CONCURRENTLY no plano único' => [[step.call(concurrent, nil)], 'unica'],
      'passo sem transação no plano por passo' => [[step.call('CREATE TABLE "public"."u" ();', nil)], 'por_passo'],
      'transação no plano único' => [[step.call('CREATE TABLE "public"."u" ();', 'sim')], 'unica']
    }.each do |label, (steps, transaction)|
      error = assert_raises(Vetra::Graph::Error, label) { Vetra::SQL::Plan.new(number: '0002', name: 'x', transaction: transaction, steps: steps) }
      assert_includes error.diagnostics.map(&:code), 'db_plan_format', label
    end
    text = plan.render
    assert_graph_error('db_plan_format') { Vetra::SQL::Plan.parse(text.sub(' transacao=sim', ''), file: 'db/plans/0002_x.sql') }
    assert_graph_error('db_plan_format') { Vetra::SQL::Plan.parse(text.sub('transacao por_passo', 'transacao unica'), file: 'db/plans/0002_x.sql') }
  end

  def test_global_and_session_statements_are_refused_in_any_plan
    step = ->(sql) { Vetra::SQL::Plan::Step.new(number: 1, phase: 'expand', lock: 'nenhum', cost: 'catalogo', sql: sql) }
    [
      'ALTER ROLE "vetra_migrator" SET work_mem = \'8MB\';',
      "DO $x$\nBEGIN\n  SET ROLE postgres;\nEND $x$;",
      "DO $x$\nBEGIN\n  CREATE ROLE intruso;\nEND $x$;",
      'COMMENT ON DATABASE postgres IS \'x\';',
      'COPY "public"."t" TO \'/tmp/x\';',
      'GRANT "vetra_owner" TO "vetra_app";',
      'REVOKE ADMIN OPTION FOR "vetra_owner" FROM "vetra_migrator";',
      "SELECT pg_catalog.set_config('session_replication_role', 'replica', false);",
      "SELECT pg_read_file('/etc/passwd');",
      'SET search_path = public;',
      "CREATE TABLE \"public\".\"t\" ();\nCOMMIT;",
      'CREATE TABLESPACE x LOCATION \'/tmp\';',
      "DO $x$\nBEGIN\n  EXECUTE $q$ALTER ROLE vetra_migrator SET work_mem = '8MB'$q$;\nEND $x$;",
      "SELECT pg_catalog.\"set_config\"('lock_timeout', '0', true);",
      "SELECT \"pg_read_file\" ('/etc/passwd');",
      "SELECT pg_catalog.\"set_config\"/* comentário /* aninhado */ */('lock_timeout', '0', true);",
      "SELECT \"set_config\" -- comentário\n('lock_timeout', '0', true);",
      'GRANT CREATE ON TABLESPACE "compartilhado" TO "vetra_app";',
      'GRANT CREATE ON DATABASE "app_real" TO "vetra_app";',
      'GRANT SET ON PARAMETER work_mem TO "vetra_app";',
      "SELECT pg_catalog.U&\"set\\005fconfig\"('lock_timeout', '0', true);",
      "SELECT pg_catalog.u&\"set\\005fconfig\" UESCAPE '!' ('lock_timeout', '0', true);",
      "SELECT U&'\\0041';"
    ].each do |sql|
      error = assert_raises(Vetra::Graph::Error, sql) { Vetra::SQL::Plan.new(number: '0001', name: 'inicial', transaction: 'unica', steps: [step.call(sql)]) }
      assert_includes error.diagnostics.map(&:code), 'db_plan_forbidden', sql
    end
    # Identificadores, literais, comentários e mensagens não executam nada: uma coluna "copy", um default 'COPY', um
    # valor de enum ou a mensagem de um RAISE passam. Um EXECUTE com o comando num literal também passa: é a contenção
    # do --check que o cobre, não o filtro.
    allowed = [
      "DO $x$\nBEGIN\n  RAISE EXCEPTION 'Aplicação não pode assumir por SET ROLE papel com SUPERUSER';\nEND $x$;",
      'GRANT SELECT, INSERT ON TABLE "public"."t" TO "vetra_app";',
      'REVOKE ALL ON SCHEMA "public" FROM PUBLIC, "vetra_app";',
      "CREATE TABLE \"public\".\"t\" (\n  \"copy\" text DEFAULT E'COPY \\'x\\' TO',\n  \"role\" text CHECK (\"role\" IN (E'alter role', E'set role'))\n);",
      "-- ALTER ROLE num comentário\nCREATE TABLE \"public\".\"u\" ();",
      "CREATE TABLE \"public\".\"copy\" (\"set_config\" text);",
      "DO $x$\nBEGIN\n  EXECUTE 'CREATE ' || 'ROLE intruso';\nEND $x$;"
    ]
    allowed.each { |sql| Vetra::SQL::Plan.new(number: '0001', name: 'inicial', transaction: 'unica', steps: [step.call(sql)]) }
    assert_equal ['CREATE TABLE "a" ();', 'CREATE TABLE "b" ();'], Vetra::SQL::Plan.statement_starts("-- c\nCREATE TABLE \"a\" ();\n/* x */ CREATE TABLE \"b\" ();")
    assert_equal %q{CREATE TABLE "".""( "" text DEFAULT E'');},Vetra::SQL::Plan.code_only(%q{CREATE TABLE "a"."b"( "c""d" text DEFAULT E'x\'y');})
  end

  def test_a_column_named_like_a_forbidden_command_compiles_into_a_plan
    with_app('blog') do |root, compiler|
      edit(root, 'app/domains/blog/post.rb') { |text| text.sub('  crud', "  string :copy\n  crud") }
      compiler.write
      assert_equal :written, planner(root).plan.status
      assert_includes File.read(File.join(root, 'db/plans/0001_inicial.sql')), '"copy" text'
    end
  end

  def test_convergence_ignores_only_the_column_order_inside_create_table
    initial = "CREATE TABLE public.leads (\n    aaa text,\n    id uuid NOT NULL,\n    zzz text\n);\n\nALTER TABLE public.leads OWNER TO vetra_owner;\n"
    added = "CREATE TABLE public.leads (\n    id uuid NOT NULL,\n    zzz text,\n    aaa text\n);\n\nALTER TABLE public.leads OWNER TO vetra_owner;\n"
    assert_equal Vetra::SQL::Planner.structural(initial), Vetra::SQL::Planner.structural(added)
    refute_equal Vetra::SQL::Planner.structural(initial), Vetra::SQL::Planner.structural(added.sub('aaa text', 'aaa bigint'))
    refute_equal Vetra::SQL::Planner.structural(initial), Vetra::SQL::Planner.structural(added.sub('OWNER TO vetra_owner', 'OWNER TO postgres'))
    partitioned = "CREATE TABLE public.e (\n    b text,\n    a text\n)\nPARTITION BY RANGE (a);\n"
    assert_equal "CREATE TABLE public.e (\n    a text\n    b text\n)\nPARTITION BY RANGE (a);\n", Vetra::SQL::Planner.structural(partitioned)
    # Uma definição com literal de várias linhas é comparada inteira: trocar as linhas do literal muda o esquema.
    literal = ->(lines) { "CREATE TABLE public.t (\n    id uuid,\n    nota text DEFAULT 'inicio\n#{lines.join("\n")}\nfim,'::text\n);\n" }
    refute_equal Vetra::SQL::Planner.structural(literal.call(%w[alpha beta])), Vetra::SQL::Planner.structural(literal.call(%w[beta alpha]))
    # Um CR antes do LF dentro de um literal é dado e conta na comparação.
    refute_equal Vetra::SQL::Planner.structural(literal.call(["alpha\r", 'beta'])), Vetra::SQL::Planner.structural(literal.call(%w[alpha beta]))
    moved = "CREATE TABLE public.t (\n    nota text DEFAULT 'inicio\nalpha\nbeta\nfim,'::text,\n    id uuid\n);\n"
    assert_equal Vetra::SQL::Planner.structural(literal.call(%w[alpha beta]).sub("    id uuid,\n", '').sub("::text\n);", "::text,\n    id uuid\n);")),
                 Vetra::SQL::Planner.structural(moved)
  end

  def test_executor_runs_step_by_step_plans_with_their_transactions
    connection = DBPlanTest::FakeConnection.new
    step = ->(number, sql, transaction) { Vetra::SQL::Plan::Step.new(number: number, phase: 'expand', lock: 'nenhum', cost: 'catalogo', sql: sql, transaction: transaction) }
    plan = Vetra::SQL::Plan.new(number: '0002', name: 'x', transaction: 'por_passo', steps: [
      step.call(1, 'CREATE INDEX CONCURRENTLY "i" ON "public"."t" ("a");', 'nao'),
      step.call(2, 'CREATE TABLE "public"."u" ();', 'sim')
    ])
    Vetra::SQL::PlanExecutor.new(connection).apply([plan])
    assert_equal ["SET lock_timeout = '3s'", plan.steps[0].sql, 'RESET lock_timeout',
                  'BEGIN', "SET LOCAL lock_timeout = '3s'", plan.steps[1].sql, 'COMMIT'], connection.commands
    failing = DBPlanTest::FakeConnection.new(fail_on: 'CREATE INDEX')
    error = assert_graph_error('db_plan_apply') { Vetra::SQL::PlanExecutor.new(failing).apply([plan]) }
    assert_includes error.message, 'passo 1'
    assert_equal 'RESET lock_timeout', failing.commands.last
    refute_includes failing.commands, 'ROLLBACK'
  end

  # Conexão falsa do banco descartável: responde ao catálogo de papéis com os valores dados, em ordem, e às consultas
  # de superusuário e de bancos administrados pelo migrador.
  class FakePG
    Result = Struct.new(:value, :values) do
      def getvalue(*) = value
      def column_values(*) = values || []
    end
    attr_reader :commands

    def initialize(catalogs: [], fail_create: false, superuser: false, administered: [], passwords: [], bad_roles: false, sessions: 0)
      @catalogs, @fail_create, @superuser, @administered, @passwords, @commands = catalogs, fail_create, superuser, administered, passwords, []
      @bad_roles, @sessions = bad_roles, sessions
    end

    def exec(sql)
      @commands << sql
      raise PG::InsufficientPrivilege, 'sem permissão' if @fail_create && sql.start_with?('CREATE DATABASE')
      raise PG::RaiseException, 'Papéis Vetra ausentes' if @bad_roles && sql == Vetra::SQL::Context.role_guard
      case sql
      when Vetra::SQL::ScratchDatabase::SUPERUSER then Result.new(@superuser ? 't' : 'f')
      when Vetra::SQL::ScratchDatabase::ADMINISTERED then Result.new(nil, @administered)
      when Vetra::SQL::ScratchDatabase::SESSIONS then Result.new(@sessions.to_s)
      when Vetra::SQL::ScratchDatabase::PASSWORDS then Result.new(@passwords.shift)
      else Result.new(nil)
      end
    end

    def exec_params(sql, params)
      @commands << [sql, params]
      raise 'consulta inesperada' unless sql == Vetra::SQL::ScratchDatabase::ROLE_CATALOG && params.first.start_with?('vetra_plan_')
      Result.new(@catalogs.shift)
    end

    def server_version = 180_006
    def host = '/tmp/sock'
    def port = 5432
    def hostaddr = ''
    def conninfo_hash = { host: '/tmp/sock', port: '5432', user: 'postgres', dbname: 'vetra_plan_x' }
    def close; end
  end

  # Conexão falsa do migrador: registra os comandos e responde à conferência de identidade.
  class FakeMigrator
    Rows = Struct.new(:values)
    attr_reader :commands

    def initialize(identity: Vetra::SQL::ScratchDatabase::EXPECTED_IDENTITY)
      @identity, @commands = identity, []
    end

    def exec(sql)
      @commands << sql
      Rows.new(sql == Vetra::SQL::ScratchDatabase::IDENTITY ? [@identity] : [])
    end

    def close; end
  end

  def scratch(admin, migrator, password: nil, url: 'postgres://postgres:segredo@/postgres?host=/tmp/sock')
    targets, environment = [], []
    Dir.mktmpdir('vetra-pgdump-') do |directory|
      pg_dump = File.join(directory, 'pg_dump')
      File.write(pg_dump, "#!/bin/sh\nif [ \"$1\" = \"--version\" ]; then echo 'pg_dump (PostgreSQL) 18.6'; else printf 'CREATE TABLE public.t ();\\n'; fi\n")
      File.chmod(0o755, pg_dump)
      connector = lambda do |target|
        targets << target
        next admin unless target.is_a?(Hash) && target['user'] == 'vetra_migrator'
        environment << Vetra::SQL::ScratchDatabase::LOGIN_ENV.to_h { |key| [key, ENV.fetch(key, nil)] }
        raise PG::ConnectionBad, 'senha recusada' if migrator == :refused
        migrator
      end
      database = Vetra::SQL::ScratchDatabase.new(url: url, pg_dump: pg_dump, migrator_password: password, driver: -> {}, connector: connector)
      yield database, targets, environment
    end
  end

  def blog_plan
    with_app('blog') do |root, compiler|
      compiler.write
      Vetra::SQL::Planner.new(root: root).plan
      return Vetra::SQL::Plan.parse(File.read(File.join(root, 'db/plans/0001_inicial.sql')), file: 'db/plans/0001_inicial.sql')
    end
  end

  def migrator_login(targets)
    targets.find { |target| target.is_a?(Hash) && target['user'] == 'vetra_migrator' }
  end

  def test_default_additive_plan_is_filtered_and_only_sent_to_the_migrator_connection
    with_app('mini_crm') do |root, compiler|
      compiler.write
      planner = Vetra::SQL::Planner.new(root: root)
      planner.plan
      add_index(root)
      edit(root, 'app/domains/crm/lead.rb') { |s| s.sub('  crud', "  string :origem, optional: true\n  crud") }
      compiler.write
      plans = planner.plan.plans
      admin, migrator = FakePG.new(catalogs: %w[a a]), FakeMigrator.new
      scratch(admin, migrator) do |database, targets|
        assert_equal 2, database.replay(plans).size
        assert_equal 'vetra_migrator', migrator_login(targets)['user']
        assert plans.last.steps.any? { |step| step.sql.start_with?('ALTER TABLE') }
        assert plans.last.steps.any? { |step| step.sql.start_with?('CREATE INDEX CONCURRENTLY') }
        plans.last.steps.each do |step|
          assert_nil Vetra::SQL::Plan.check_step!(step, 'por_passo', plans.last.file_name)
          assert_includes migrator.commands, step.sql
          refute_includes admin.commands, step.sql
          assert_operator migrator.commands.index(Vetra::SQL::ScratchDatabase::IDENTITY), :<, migrator.commands.index(step.sql)
        end
      end
    end
  end

  def test_scratch_database_applies_as_vetra_migrator_and_checks_the_role_catalog
    plan = blog_plan
    admin, migrator = FakePG.new(catalogs: %w[a a]), FakeMigrator.new
    scratch(admin, migrator, password: 'do-migrador') do |database, targets|
      assert_equal ["CREATE TABLE public.t ();\n"], database.replay([plan])
      login = migrator_login(targets)
      assert_equal 'do-migrador', login['password']
      assert_equal '/tmp/sock', login['host']
      assert_match(/vetra-sem-pgpass-[0-9a-f]{16}\z/, login['passfile'])
      refute File.exist?(login['passfile'])
      refute_includes login.values, 'segredo'
      assert admin.commands.any? { |sql| sql.is_a?(String) && sql.start_with?('CREATE DATABASE vetra_plan_') && sql.include?('OWNER "vetra_migrator"') }
      assert admin.commands.last.start_with?('DROP DATABASE IF EXISTS vetra_plan_')
      refute_includes admin.commands, Vetra::SQL::ScratchDatabase::PASSWORDS
      # A guarda dos papéis do gerador atual roda pela conexão administrativa antes de qualquer texto dos planos.
      assert_operator admin.commands.index(Vetra::SQL::Context.role_guard), :<, admin.commands.index { |sql| sql.is_a?(String) && sql.start_with?('CREATE DATABASE') }
      assert_includes migrator.commands, plan.steps.first.sql
      assert_operator migrator.commands.index(Vetra::SQL::ScratchDatabase::IDENTITY), :<, migrator.commands.index(plan.steps.first.sql)
    end
    # Sem senha própria, nem a URL, nem o ambiente, nem um service completam o login do migrador com a do administrador.
    previous = ENV.to_h.slice('PGPASSWORD', 'PGSERVICE')
    ENV['PGPASSWORD'], ENV['PGSERVICE'] = 'do-administrador', 'administrativo'
    begin
      scratch(FakePG.new(catalogs: %w[a a]), migrator, url: 'postgres://postgres:segredo@/postgres?host=/tmp/sock&passfile=/tmp/pgpass') do |database, targets, environment|
        database.replay([plan])
        login = migrator_login(targets)
        refute login.key?('password')
        refute login.key?('service')
        assert_match(/vetra-sem-pgpass-[0-9a-f]{16}\z/, login['passfile'])
        assert_equal [nil], environment.map { |values| values['PGPASSWORD'] }.uniq
        assert_equal [nil], environment.map { |values| values['PGSERVICE'] }.uniq
        assert_equal 'do-administrador', ENV['PGPASSWORD']
      end
    ensure
      %w[PGPASSWORD PGSERVICE].each { |key| previous.key?(key) ? ENV.store(key, previous[key]) : ENV.delete(key) }
    end
    # Um catálogo de papéis ou de bancos diferente depois da aplicação falha, e o banco temporário é removido.
    changed = FakePG.new(catalogs: %w[a b])
    scratch(changed, migrator) do |database, _|
      error = assert_graph_error('db_plan_global') { database.replay([plan]) }
      assert_includes error.message, 'vetra_migrator'
      assert changed.commands.last.start_with?('DROP DATABASE IF EXISTS')
    end
    # Com superusuário, a senha também entra na comparação.
    superuser = FakePG.new(catalogs: %w[a a], superuser: true, passwords: %w[hash outro])
    scratch(superuser, migrator) do |database, _|
      assert_graph_error('db_plan_global') { database.replay([plan]) }
      assert_includes superuser.commands, Vetra::SQL::ScratchDatabase::PASSWORDS
    end
  end

  def test_scratch_database_refuses_servers_where_the_migrator_administers_other_databases
    plan = blog_plan
    admin = FakePG.new(administered: ["banco app_real"])
    scratch(admin, nil) do |database, _|
      error = assert_graph_error('db_plan_role') { database.replay([plan]) }
      assert_includes error.message, 'app_real'
      assert_includes error.message, 'servidor descartável'
      refute admin.commands.any? { |sql| sql.is_a?(String) && sql.start_with?('CREATE DATABASE') }
    end
    # Uma sessão do migrador aberta noutro banco também recusa o servidor: o plano poderia encerrá-la.
    busy = FakePG.new(sessions: 2)
    scratch(busy, nil) do |database, _|
      error = assert_graph_error('db_plan_role') { database.replay([plan]) }
      assert_includes error.message, '2 sessão(ões)'
      refute busy.commands.any? { |sql| sql.is_a?(String) && sql.start_with?('CREATE DATABASE') }
    end
  end

  def test_scratch_database_reports_missing_roles_and_a_refused_login
    plan = blog_plan
    scratch(FakePG.new(catalogs: %w[a], fail_create: true), nil) do |database, _|
      error = assert_graph_error('db_plan_role') { database.replay([plan]) }
      assert_includes error.message, 'bootstrap'
    end
    admin = FakePG.new(catalogs: %w[a])
    scratch(admin, :refused) do |database, _|
      error = assert_graph_error('db_plan_role') { database.replay([plan]) }
      assert_includes error.message, 'VETRA_MIGRATOR_PASSWORD'
      refute_includes error.message, 'senha recusada'
      assert admin.commands.last.start_with?('DROP DATABASE IF EXISTS')
    end
    # Papéis com poderes a mais são recusados pela guarda do executor antes de criar o banco, sem depender do plano.
    bad = FakePG.new(bad_roles: true)
    scratch(bad, FakeMigrator.new) do |database, _|
      error = assert_graph_error('db_plan_role') { database.replay([plan]) }
      assert_includes error.message, 'bootstrap'
      refute bad.commands.any? { |sql| sql.is_a?(String) && sql.start_with?('CREATE DATABASE') }
    end
    # Uma conexão do migrador promovido a superusuário não recebe nenhum passo dos planos.
    promoted = FakeMigrator.new(identity: %w[vetra_migrator vetra_migrator t f f f])
    admin = FakePG.new(catalogs: %w[a a])
    scratch(admin, promoted) do |database, _|
      error = assert_graph_error('db_plan_role') { database.replay([plan]) }
      assert_includes error.message, 'sem poderes administrativos'
      refute_includes promoted.commands, plan.steps.first.sql
      assert admin.commands.last.start_with?('DROP DATABASE IF EXISTS')
    end
  end

  # Diferença de teste que grava o segundo plano em transação única, como uma C9 que errasse o modo.
  SINGLE = lambda do |base:, schema:, number:|
    plan = INDEXES.call(base: base, schema: schema, number: number)
    steps = plan.steps.map { |step| step.dup.tap { |copy| copy.sql = copy.sql.sub(' CONCURRENTLY', ''); copy.transaction = nil } }
    Vetra::SQL::Plan.new(number: number, name: 'indices', transaction: 'unica', steps: steps)
  end

  def test_migrate_refuses_every_plan_after_the_initial_until_k10
    [INDEXES, SINGLE].each do |differ|
      with_app('mini_crm') do |root, compiler|
        compiler.write
        planner(root).plan
        add_index(root)
        compiler.write
        planner(root, differ: differ).plan
        database = DBMigrateTest::FakeDatabase.new(dumped: "x\n")
        write(root, 'db/schema.sql', Vetra::SQL::Planner.render_schema([], "x\n"))
        migrator = Vetra::SQL::Migrator.new(root: root, database: database, differ: differ)
        error = assert_graph_error('db_migrate_incremental') { migrator.migrate }
        assert_includes error.message, '0002_indices.sql'
        initial = Vetra::SQL::Plan.parse(File.read(File.join(root, 'db/plans/0001_inicial.sql')), file: 'db/plans/0001_inicial.sql')
        database.records = [{ 'plan' => '0001_inicial', 'sha256' => Vetra::SQL::Migrator.digest(initial) }]
        error = assert_graph_error('db_migrate_incremental') { migrator.migrate }
        assert_includes error.message, '0002_indices.sql'
        assert_empty database.applied_plans
      end
    end
  end
end

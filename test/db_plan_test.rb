require_relative 'test_helper'

class DBPlanTest < GraphTest
  # Banco falso: devolve um retrato fixo e registra os planos recebidos, para testar o fluxo sem PostgreSQL.
  class FakeDatabase
    attr_reader :received

    def initialize(dump)
      @dump = dump
    end

    def replay(plans)
      @received = plans
      [@dump] * plans.size
    end
  end

  # Conexão falsa para o executor: registra os comandos e falha no comando indicado.
  class FakeConnection
    attr_reader :commands

    def initialize(fail_on: nil)
      @commands, @fail_on = [], fail_on
    end

    def exec(sql)
      @commands << sql
      raise StandardError, "erro simulado em #{sql[0, 20]}\ndetalhe" if @fail_on && sql.start_with?(@fail_on)
    end
  end

  def planner(root, database = nil)
    Vetra::SQL::Planner.new(root: root, database: database)
  end

  def plan_path(root)
    File.join(root, 'db/plans/0001_inicial.sql')
  end

  def test_initial_plan_has_one_classified_step_per_schema_statement
    with_app('mini_crm_revendas') do |root, compiler|
      document = compiler.write.document
      schema = Vetra::SQL::Schema.new(document).generate
      result = planner(root).plan
      assert_equal :written, result.status
      text = File.read(plan_path(root))
      assert text.start_with?("-- vetra:plano 0001 inicial\n-- vetra:transacao unica\n")
      plan = Vetra::SQL::Plan.parse(text, file: 'db/plans/0001_inicial.sql')
      statements = Vetra::SQL::Context.prefix + schema.blocks.flat_map { |block| block['statements'] } + Vetra::SQL::Context.suffix(schema.tables)
      statements += Vetra::SQL::Security.new(schema).generate.statements + Vetra::SQL::Authorization.new(document).generate.statements
      assert_equal statements, plan.steps.map(&:sql)
      assert_equal (1..statements.size).to_a, plan.steps.map(&:number)
      assert_equal ['expand'], plan.steps.map(&:phase).uniq
      locks = plan.steps.select { |step| step.sql.match?(/\A(CREATE TABLE|CREATE INDEX|ALTER TABLE \S+ ADD CONSTRAINT)/) }.to_h { |step| [step.sql[/\A(CREATE TABLE|CREATE INDEX|ALTER TABLE \S+ ADD CONSTRAINT \S+ (UNIQUE|FOREIGN KEY))/, 1]&.sub(/\AALTER TABLE \S+ ADD CONSTRAINT \S+ /, ''), step.lock] }
      assert_equal({ 'CREATE TABLE' => 'nenhum', 'UNIQUE' => 'AccessExclusive', 'CREATE INDEX' => 'Share', 'FOREIGN KEY' => 'ShareRowExclusive' }, locks)
      assert_equal %w[catalogo tabela_vazia], plan.steps.map(&:cost).uniq.sort
      # As FKs vêm depois de todas as tabelas, como nos blocos do ADR-035.
      last_table = plan.steps.rindex { |step| step.sql.match?(/\ACREATE TABLE "public"/) }
      assert plan.steps.drop(last_table + 1).any? { |step| step.sql.include?('FOREIGN KEY') }
      refute plan.steps.take(last_table).any? { |step| step.sql.include?('FOREIGN KEY') }
      assert_equal text, plan.render
      assert plan.frozen?
      assert plan.steps.frozen?
    end
  end

  def test_control_characters_in_defaults_are_escaped_and_the_plan_rereads
    with_app('blog') do |root, compiler|
      edit(root, 'app/domains/blog/post.rb') { |text| text.sub('  crud', "  text :nota, default: \"a\\rb\\nc\\td\\u0001e\"\n  crud") }
      compiler.write
      planner(root).plan
      text = File.binread(plan_path(root))
      assert_includes text, %q{DEFAULT E'a\rb\nc\td\x01e'}
      refute_match(/[\x01-\x09\x0b-\x1f\x7f]/, text)
      assert_equal :unchanged, planner(root).plan.status
    end
  end

  def test_carriage_returns_inside_literals_change_the_snapshot
    with_cr = "CREATE TABLE public.t (\n    nota text DEFAULT 'a\r\nb'::text\n);\n"
    without = "CREATE TABLE public.t (\n    nota text DEFAULT 'a\nb'::text\n);\n"
    normalized = Vetra::SQL::ScratchDatabase.normalize_dump(with_cr)
    assert_equal with_cr, normalized
    refute_equal normalized, Vetra::SQL::ScratchDatabase.normalize_dump(without)
  end

  def test_statement_without_lock_classification_is_refused
    schema = Struct.new(:blocks, :tables).new([{ 'kind' => 'tables', 'statements' => ['DROP TABLE "public"."x";'] }], [])
    error = assert_graph_error('db_plan_step') { Vetra::SQL::Plan.initial(schema) }
    assert_includes error.message, 'DROP TABLE'
  end

  def test_markers_inside_literals_and_bodies_are_data
    sql = <<~SQL.chomp
      CREATE TABLE "public"."t" (
        "nota" text NOT NULL DEFAULT E'inicio
      -- vetra:passo 2 fase=contract lock=nenhum custo=catalogo
      -- vetra:valor interno
      fim',
        "x" text DEFAULT $corpo$
      -- vetra:outro
      $corpo$
      );
    SQL
    schema = Struct.new(:blocks, :tables).new([{ 'kind' => 'tables', 'statements' => [sql, 'CREATE INDEX "i" ON "public"."t" ("nota");'] }], [])
    plan = Vetra::SQL::Plan.initial(schema)
    parsed = Vetra::SQL::Plan.parse(plan.render, file: 'db/plans/0001_inicial.sql')
    assert_equal [*Vetra::SQL::Context.prefix, sql, 'CREATE INDEX "i" ON "public"."t" ("nota");', *Vetra::SQL::Context.suffix([])], parsed.steps.map(&:sql)
    assert_equal plan.render, parsed.render
  end

  def test_plan_is_deterministic_and_a_second_run_changes_nothing
    with_app('chat') do |root, compiler|
      compiler.write
      planner(root).plan
      first = File.binread(plan_path(root))
      assert_equal :unchanged, planner(root).plan.status
      assert_equal first, File.binread(plan_path(root))
      with_app('chat') do |other, other_compiler|
        other_compiler.write
        planner(other).plan
        assert_equal first, File.binread(plan_path(other))
      end
    end
  end

  def test_stale_plan_and_extra_plans_are_refused
    with_app('mini_crm') do |root, compiler|
      compiler.write
      planner(root).plan
      edit(root, 'app/domains/crm/lead.rb') { |text| text.sub('  crud', "  string :origem, max: 40\n  crud") }
      compiler.write
      error = assert_graph_error('db_plan_backfill') { planner(root).plan }
      assert_includes error.message, 'default constante'
      write(root, 'db/plans/0002_mais.sql', File.read(plan_path(root)).sub('0001 inicial', '0002 mais'))
      assert_graph_error('db_model_chain') { planner(root).plan }
    end
  end

  def test_plan_parser_refuses_files_outside_the_format
    good = nil
    with_app('blog') do |root, compiler|
      compiler.write
      planner(root).plan
      good = File.read(plan_path(root))
    end
    bad = {
      'nome' => ['db/plans/1_inicial.sql', good],
      'cabeçalho' => ['db/plans/0001_inicial.sql', good.sub('-- vetra:plano 0001 inicial', '-- vetra:plano 0002 inicial')],
      'transação' => ['db/plans/0001_inicial.sql', good.sub('transacao unica', 'transacao varias')],
      'numeração' => ['db/plans/0001_inicial.sql', good.sub('-- vetra:passo 2 ', '-- vetra:passo 3 ')],
      'fase' => ['db/plans/0001_inicial.sql', good.sub('fase=expand', 'fase=depois')],
      'lock' => ['db/plans/0001_inicial.sql', good.sub('lock=nenhum', 'lock=Total')],
      'custo' => ['db/plans/0001_inicial.sql', good.sub('custo=catalogo', 'custo=barato')],
      'marcador' => ['db/plans/0001_inicial.sql', good.sub("\n-- vetra:passo 1", "\n-- vetra:pausa\n-- vetra:passo 1")],
      'SQL solto' => ['db/plans/0001_inicial.sql', good.sub("\n-- vetra:passo 1", "\nDROP TABLE x;\n-- vetra:passo 1")],
      'passo vazio' => ['db/plans/0001_inicial.sql', good.sub(/(-- vetra:passo 1 [^\n]*\n).*?(\n-- vetra:passo 2 )/m, "\\1\\2")],
      'literal aberto' => ['db/plans/0001_inicial.sql', good.sub(/;\n\z/, " E'aberto;\n")],
      'CRLF' => ['db/plans/0001_inicial.sql', good.gsub("\n", "\r\n")],
      'sem passos' => ['db/plans/0001_inicial.sql', good.lines.first(2).join]
    }
    bad.each do |label, (file, text)|
      error = assert_raises(Vetra::Graph::Error, label) { Vetra::SQL::Plan.parse(text, file: file) }
      assert_includes error.diagnostics.map(&:code), 'db_plan_format', label
    end
  end

  def test_hand_edits_outside_the_canonical_form_are_refused
    with_app('blog') do |root, compiler|
      compiler.write
      planner(root).plan
      edit(root, 'db/plans/0001_inicial.sql') { |text| text.sub("\n-- vetra:passo 1", "\n-- comentário a mais\n\n-- vetra:passo 1") }
      error = assert_graph_error('db_plan_format') { planner(root).plan }
      assert_includes error.message, 'formato canônico'
      FileUtils.rm(plan_path(root))
      FileUtils.mkdir_p(File.join(root, 'db/plans/rascunho'))
      assert_graph_error('db_plan_format') { planner(root).plan }
    end
  end

  def test_snapshot_and_check_use_the_database_and_compare_the_snapshot
    with_app('mini_crm_revendas') do |root, compiler|
      compiler.write
      assert_graph_error('db_plan_missing') { planner(root, FakeDatabase.new("x\n")).snapshot }
      assert_graph_error('db_plan_missing') { planner(root, FakeDatabase.new("x\n")).check }
      planner(root).plan
      assert_graph_error('db_database_url') { planner(root).check }
      assert_graph_error('db_schema_missing') { planner(root, FakeDatabase.new("x\n")).check }
      database = FakeDatabase.new("CREATE TABLE public.companies ();\n")
      planner(root, database).snapshot
      assert_equal ['0001_inicial.sql'], database.received.map(&:file_name)
      snapshot = File.read(File.join(root, 'db/schema.sql'))
      assert snapshot.start_with?(Vetra::SQL::Planner::SCHEMA_HEADER)
      assert_equal :checked, planner(root, FakeDatabase.new("CREATE TABLE public.companies ();\n")).check.status
      error = assert_graph_error('db_schema_stale') { planner(root, FakeDatabase.new("CREATE TABLE public.dealers ();\n")).check }
      assert_includes error.message, 'linha 3'
    end
  end

  def test_snapshot_only_applies_plans_that_the_ir_generates
    with_app('blog') do |root, compiler|
      compiler.write
      planner(root).plan
      # Um passo editado no formato canônico continua legível, mas não é o que a cadeia prende: nunca chega ao banco.
      edit(root, 'db/plans/0001_inicial.sql') { |text| text.sub(/;\n\z/, ";\nCOMMENT ON SCHEMA public IS 'x';\n") }
      database = FakeDatabase.new("x\n")
      assert_graph_error('db_model_chain') { planner(root, database).snapshot }
      assert_nil database.received
      assert_graph_error('db_model_chain') { planner(root, database).check }
      assert_nil database.received
      # Uma instrução sobre objeto fora do banco é recusada já na leitura do plano.
      edit(root, 'db/plans/0001_inicial.sql') { |text| text.sub('COMMENT ON SCHEMA public', 'COMMENT ON DATABASE postgres') }
      assert_graph_error('db_plan_forbidden') { planner(root, database).check }
      assert_nil database.received
    end
  end

  def test_pg_dump_targets_the_effective_connection_and_ignores_inherited_pg_variables
    require 'pg'
    effective = { 'host' => '/tmp/sock dir', 'port' => '5432', 'user' => "o'ne", 'dbname' => 'vetra_plan_abc',
                  'password' => 'segredo', 'sslmode' => 'disable', 'options' => '-c x=1 -c endpoint=ep\\ a',
                  'target_session_attrs' => 'read-write', 'hostaddr' => '' }
    environment, arguments = Vetra::SQL::ScratchDatabase.pg_dump_invocation(effective)
    assert_equal ['--schema-only', '--dbname'], arguments.first(2)
    conninfo = arguments.last
    assert_equal "host='/tmp/sock dir' port='5432' user='o\\'ne' dbname='vetra_plan_abc' options='-c x=1 -c endpoint=ep\\\\ a' " \
                 "target_session_attrs='read-write' sslmode='disable'", conninfo
    refute arguments.join(' ').include?('segredo')
    assert_equal 'segredo', environment['PGPASSWORD']
    %w[PGSERVICE PGSERVICEFILE PGHOST PGPORT PGDATABASE PGUSER PGOPTIONS PGTARGETSESSIONATTRS].each { |name| assert environment.key?(name) && environment[name].nil?, name }
    # A string de conexão é a que a libpq lê: os mesmos valores, inclusive com espaço, aspas e barra invertida.
    parsed = PG::Connection.conninfo_parse(conninfo).to_h { |option| [option[:keyword], option[:val]] }
    assert_equal ['/tmp/sock dir', "o'ne", 'vetra_plan_abc', '-c x=1 -c endpoint=ep\\ a', 'read-write'],
                 parsed.values_at('host', 'user', 'dbname', 'options', 'target_session_attrs')
    environment, = Vetra::SQL::ScratchDatabase.pg_dump_invocation(effective.merge('password' => nil))
    assert environment.key?('PGPASSWORD') && environment['PGPASSWORD'].nil?
  end

  def test_connection_errors_do_not_echo_the_url
    database = Vetra::SQL::ScratchDatabase.new(url: 'postgres://usuario:segredo%zz@127.0.0.1:1/x')
    error = assert_graph_error('db_connection') { database.replay([]) }
    refute_includes error.message, 'segredo'
    refute_includes error.message, 'usuario'
  end

  def test_dump_normalization_drops_only_session_noise
    dump = <<~SQL
      --
      -- PostgreSQL database dump
      --
      \\restrict AbC123

      -- Dumped from database version 18.6
      SET statement_timeout = 0;
      SELECT pg_catalog.set_config('search_path', '', false);


      CREATE TABLE public.t (
          id uuid NOT NULL
      );



      ALTER TABLE ONLY public.t ENABLE ROW LEVEL SECURITY;
      GRANT SELECT ON TABLE public.t TO app;
      \\unrestrict AbC123
    SQL
    expected = "CREATE TABLE public.t (\n    id uuid NOT NULL\n);\n\nALTER TABLE ONLY public.t ENABLE ROW LEVEL SECURITY;\nGRANT SELECT ON TABLE public.t TO app;\n"
    assert_equal expected, Vetra::SQL::ScratchDatabase.normalize_dump(dump)
  end

  def test_dump_normalization_keeps_literals_and_function_bodies
    dump = <<~SQL
      SET check_function_bodies = false;

      CREATE FUNCTION public.f() RETURNS void
          LANGUAGE plpgsql
          AS $_$
      BEGIN
        SET row_security = on;
      -- valor A


        PERFORM 1;
      END
      $_$;

      CREATE TABLE public.t (
          nota text DEFAULT E'inicio\\'
      -- valor A
      SET x = 1;

      fim'::text,
          outra text DEFAULT 'a''
      -- dentro'::text
      );
      /* bloco
      -- dentro do bloco
      */
      SET depois = 1;
    SQL
    normalized = Vetra::SQL::ScratchDatabase.normalize_dump(dump)
    refute_includes normalized, 'check_function_bodies'
    refute_includes normalized, 'SET depois'
    assert_includes normalized, "BEGIN\n  SET row_security = on;\n-- valor A\n\n\n  PERFORM 1;"
    assert_includes normalized, "E'inicio\\'\n-- valor A\nSET x = 1;\n\nfim'::text"
    assert_includes normalized, "'a''\n-- dentro'::text"
    assert_includes normalized, "/* bloco\n-- dentro do bloco\n*/"
    # O mesmo esquema com um valor diferente dentro do literal produz outro retrato.
    refute_equal normalized, Vetra::SQL::ScratchDatabase.normalize_dump(dump.sub('-- valor A', '-- valor B'))
  end

  def test_pg_dump_must_match_the_server_major_version
    Vetra::SQL::ScratchDatabase.check_pg_dump!("pg_dump (PostgreSQL) 18.6 (Ubuntu 18.6-1)\n", 18)
    error = assert_graph_error('db_pg_dump') { Vetra::SQL::ScratchDatabase.check_pg_dump!("pg_dump (PostgreSQL) 16.15\n", 18) }
    assert_includes error.message, 'VETRA_PG_DUMP'
    assert_graph_error('db_pg_dump') { Vetra::SQL::ScratchDatabase.check_pg_dump!("outra coisa\n", 17) }
    missing = Vetra::SQL::ScratchDatabase.new(url: 'postgres://x', pg_dump: '/caminho/inexistente/pg_dump', driver: -> {})
    assert_graph_error('db_pg_dump') { missing.send(:pg_dump_version) }
  end

  def test_missing_driver_is_reported
    database = Vetra::SQL::ScratchDatabase.new(url: 'postgres://x', driver: -> { raise LoadError, 'cannot load such file -- pg' })
    error = assert_graph_error('db_driver') { database.replay([]) }
    assert_includes error.message, 'gem pg'
  end

  def test_executor_runs_each_plan_in_one_transaction_and_rolls_back_on_failure
    with_app('chat') do |root, compiler|
      compiler.write
      planner(root).plan
      plan = Vetra::SQL::Plan.parse(File.read(plan_path(root)), file: 'db/plans/0001_inicial.sql')
      connection = FakeConnection.new
      Vetra::SQL::PlanExecutor.new(connection).apply([plan])
      assert_equal ['BEGIN', "SET LOCAL lock_timeout = '3s'", *plan.steps.map(&:sql), 'COMMIT'], connection.commands
      failing = FakeConnection.new(fail_on: 'ALTER TABLE')
      error = assert_graph_error('db_plan_apply') { Vetra::SQL::PlanExecutor.new(failing).apply([plan]) }
      first_alter = plan.steps.find { |step| step.sql.start_with?('ALTER TABLE') }
      assert_includes error.message, "passo #{first_alter.number}: erro simulado"
      refute_includes error.message, 'detalhe'
      assert_equal 'ROLLBACK', failing.commands.last
      refute_includes failing.commands, 'COMMIT'
    end
  end

  def test_cli_plans_and_requires_database_url_for_check
    with_app('blog') do |root, compiler|
      compiler.write
      out, err = StringIO.new, StringIO.new
      assert_equal 0, Vetra::CLI.run(['db:plan', '--root', root], out: out, err: err), err.string
      assert_includes out.string, 'db/plans/0001_inicial.sql'
      out = StringIO.new
      assert_equal 0, Vetra::CLI.run(['db:plan', '--root', root], out: out, err: StringIO.new)
      assert_includes out.string, 'sem mudanças'
      previous = ENV.delete('DATABASE_URL')
      begin
        err = StringIO.new
        assert_equal 1, Vetra::CLI.run(['db:plan', '--check', '--root', root], out: StringIO.new, err: err)
        assert_includes err.string, '[db_database_url]'
      ensure
        ENV['DATABASE_URL'] = previous if previous
      end
      assert_equal 2, Vetra::CLI.run(['db:plan', '--check', '--snapshot', '--root', root], out: StringIO.new, err: StringIO.new)
      assert_equal 2, Vetra::CLI.run(['db:plan', '--sources', '--root', root], out: StringIO.new, err: StringIO.new)
      assert_equal 2, Vetra::CLI.run(['graph:check', '--check', '--root', root], out: StringIO.new, err: StringIO.new)
    end
  end
end

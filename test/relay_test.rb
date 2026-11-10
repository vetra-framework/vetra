require_relative 'test_helper'
require 'vetra/data'
require 'securerandom'
require 'stringio'

class RelaySQLTest < GraphTest
  EVENTS = %w[blog mini_crm mini_crm_revendas].freeze

  def document(example)
    JSON.parse(File.read(File.join(PROJECT, 'examples', example, '.vetra/graph.json')))
  end

  def schema(example)
    Vetra::SQL::Schema.new(document(example)).generate
  end

  def model(example, name)
    file = "#{name}.json"
    Vetra::SQL::Model.new(file: file, text: File.read(File.join(PROJECT, 'examples', example, 'db/models', file)))
  end

  def test_bootstrap_creates_the_relay_login_without_links_or_bypass
    sql = Vetra::SQL::Context.roles_sql
    assert_includes sql, 'CREATE ROLE "vetra_relay" LOGIN INHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;'
    refute_match(/GRANT "vetra_(owner|app)" TO "vetra_relay"/, sql)
    # O bootstrap também confere um vetra_relay que já existia, com a mesma guarda do plano.
    assert_includes sql, Vetra::SQL::Context.relay_guard
    assert_equal Vetra::SQL::Context.relay_guard, Vetra::SQL::Outbox.new(schema('mini_crm')).relay.first
  end

  def test_relay_section_follows_the_storage_and_passes_the_plan_filters
    outbox = Vetra::SQL::Outbox.new(schema('mini_crm'))
    assert_equal outbox.storage + outbox.relay, outbox.statements
    relay = outbox.relay
    assert relay.first.start_with?('DO $vetra_relay_role$')
    assert_includes relay, "INSERT INTO \"vetra\".\"relay_checkpoints\" (\"name\", \"next_xid8\") VALUES ('relay', '0');"
    assert_includes relay, 'CREATE POLICY "vt_outbox_relay" ON "vetra"."outbox" AS PERMISSIVE FOR SELECT TO "vetra_relay" USING (true);'
    assert_includes relay, 'GRANT SELECT, INSERT, UPDATE ON TABLE "vetra"."deliveries" TO "vetra_relay";'
    assert_includes relay, 'GRANT SELECT, INSERT ON TABLE "vetra"."dead_deliveries" TO "vetra_relay";'
    assert_includes relay, 'REVOKE ALL ON FUNCTION "vetra"."outbox_maintain"(integer,integer) FROM PUBLIC, "vetra_app";'
    assert_includes relay, 'GRANT EXECUTE ON FUNCTION "vetra"."outbox_maintain"(integer,integer) TO "vetra_relay";'
    # A aplicação não recebe nada do relay, e o relay não recebe DELETE nem acesso às tabelas da aplicação.
    refute relay.any? { |sql| sql.start_with?('GRANT') && sql.include?('"vetra_app"') }
    refute relay.any? { |sql| sql.include?('DELETE') && sql.start_with?('GRANT') }
    function = relay.find { |sql| sql.start_with?('CREATE FUNCTION "vetra"."outbox_maintain"') }
    assert_match(/SECURITY DEFINER SET search_path = pg_catalog, pg_temp SET lock_timeout = '3s'/, function)
    steps = relay.each_with_index.map do |sql, index|
      lock, cost = Vetra::SQL::Plan.classify(sql)
      Vetra::SQL::Plan::Step.new(number: index + 1, phase: 'expand', lock: lock, cost: cost, sql: sql, transaction: nil)
    end
    steps.each { |step| assert_nil Vetra::SQL::Plan.check_step!(step, 'unica', '0001_inicial.sql') }
    plan = Vetra::SQL::Plan.new(number: '0001', name: 'inicial', transaction: 'unica', steps: steps)
    kinds = Vetra::SQL::Model.state(schema('mini_crm'), plan)['statements'].map { |item| item.values_at('kind', 'object') }
    assert_includes kinds, %w[guard vetra_relay_role]
    assert_includes kinds, %w[seed vetra.relay_checkpoints]
    assert_includes kinds, ['function', 'vetra.outbox_maintain(ahead integer, retention integer)']
    assert_empty Vetra::SQL::Outbox.new(schema('chat')).relay
  end

  def test_incremental_plan_adds_the_whole_relay_section_in_one_step
    EVENTS.each do |example|
      plan = Vetra::SQL::Differ.call(base: model(example, '0002_expand'), schema: schema(example), number: '0003')
      # Nos CRMs o mesmo plano traz a troca das rotinas de contexto e das políticas (ADR-024, ADR-041): só o relay é conferido aqui.
      relay_sql = Vetra::SQL::Outbox.new(schema(example)).relay.join("\n")
      steps = plan.steps.select { |step| step.sql == relay_sql }
      assert_equal 1, steps.size
      assert_equal Vetra::SQL::Outbox.new(schema(example)).relay.join("\n"), steps.first.sql
      # Cria políticas nas tabelas da outbox, que já existem: o rótulo é o lock mais forte, não o da primeira instrução.
      assert_equal %w[AccessExclusive catalogo sim], steps.first.to_h.values_at(:lock, :cost, :transaction)
      committed = Vetra::SQL::Plan.parse(File.read(File.join(PROJECT, 'examples', example, 'db/plans/0003_expand.sql')), file: '0003_expand.sql')
      assert_equal committed.steps.map(&:sql), steps.map(&:sql)
      # Uma base sem outbox recebe as duas partes juntas, num passo.
      fresh = Vetra::SQL::Differ.call(base: model(example, '0001_inicial'), schema: schema(example), number: '0002')
      outbox_sql = Vetra::SQL::Outbox.new(schema(example)).statements.join("\n")
      assert_equal [outbox_sql], fresh.steps.map(&:sql).select { |sql| sql == outbox_sql }
    end
  end

  def test_incremental_plan_refuses_a_partial_relay
    document = Vetra::Graph::Data.copy(model('blog', '0002_expand').document)
    relay = Vetra::SQL::Outbox.new(schema('blog')).relay
    initial = Vetra::SQL::Plan.initial(schema('blog'))
    current = Vetra::SQL::Model.state(schema('blog'), initial)['statements']
    first = initial.steps.index { |step| step.sql == relay.first }
    document['state']['statements'] << current[first]
    partial = Vetra::SQL::Model.new(file: '0002_expand.json', text: Vetra::SQL::Model.render(document))
    error = assert_graph_error('db_plan_statement') { Vetra::SQL::Differ.call(base: partial, schema: schema('blog'), number: '0003') }
    assert_match(/seção da outbox alterada/, error.message)
  end

  def dump
    <<~SQL
      CREATE TABLE vetra.outbox_default (
          seq bigint NOT NULL
      );

      ALTER TABLE ONLY vetra.outbox_default FORCE ROW LEVEL SECURITY;

      ALTER TABLE vetra.outbox_default OWNER TO vetra_owner;

      ALTER TABLE ONLY vetra.outbox ATTACH PARTITION vetra.outbox_default DEFAULT;

      CREATE INDEX outbox_default_seq_idx ON vetra.outbox_default USING btree (seq);

      ALTER INDEX vetra.vt_outbox_relay ATTACH PARTITION vetra.outbox_default_seq_idx;

      CREATE POLICY vt_outbox_default_owner ON vetra.outbox_default TO vetra_owner USING (true) WITH CHECK (true);
    SQL
  end

  def partition(name, from, to, extra: nil)
    chunks = ["CREATE TABLE vetra.#{name} (\n    seq bigint NOT NULL\n);", "ALTER TABLE ONLY vetra.#{name} FORCE ROW LEVEL SECURITY;",
              "ALTER TABLE vetra.#{name} OWNER TO vetra_owner;",
              "ALTER TABLE ONLY vetra.outbox ATTACH PARTITION vetra.#{name} FOR VALUES FROM ('#{from}') TO ('#{to}');",
              "CREATE INDEX #{name}_seq_idx ON vetra.#{name} USING btree (seq);",
              "ALTER INDEX vetra.vt_outbox_relay ATTACH PARTITION vetra.#{name}_seq_idx;"]
    chunks << extra if extra
    chunks.join("\n\n")
  end

  def test_drift_ignores_only_partitions_identical_to_the_default_with_a_utc_day
    base = dump.chomp
    good = "#{base}\n\n#{partition('outbox_p20261107', '2026-11-06 21:00:00-03', '2026-11-07 21:00:00-03')}"
    assert_equal base, Vetra::SQL::Outbox.without_operational_partitions(good)
    [partition('outbox_p20261107', '2026-11-07 00:00:00+00', '2026-11-09 00:00:00+00'),
     partition('outbox_p20261107', '2026-11-08 00:00:00+00', '2026-11-09 00:00:00+00'),
     partition('outbox_p20261107', '2026-11-07 00:00:00+00', '2026-11-08 00:00:00+00', extra: 'GRANT SELECT ON TABLE vetra.outbox_p20261107 TO vetra_app;'),
     partition('outbox_p20261107', '2026-11-07 00:00:00+00', '2026-11-08 00:00:00+00').sub('OWNER TO vetra_owner', 'OWNER TO postgres'),
     partition('outbox_p20261199', '2026-11-07 00:00:00+00', '2026-11-08 00:00:00+00')].each do |tampered|
      text = "#{base}\n\n#{tampered}"
      refute_equal base, Vetra::SQL::Outbox.without_operational_partitions(text)
    end
    # Uma partição escrita dentro de um corpo de função, com linhas vazias, é dado: nada sai do corpo.
    inside = partition('outbox_p20261107', '2026-11-07 00:00:00+00', '2026-11-08 00:00:00+00')
    body = "#{base}\n\nCREATE FUNCTION public.f() RETURNS text LANGUAGE sql AS $$\n\n#{inside}\n\n$$;\n"
    assert_equal body, Vetra::SQL::Outbox.without_operational_partitions(body)
    assert_equal "#{base}\n", Vetra::SQL::Outbox.without_operational_partitions("#{good}\n")
    # Um CR dentro de um literal é dado: o filtro o preserva, e dois defaults diferentes não se confundem.
    crlf = "#{base}\n\nALTER TABLE ONLY public.t ALTER COLUMN c SET DEFAULT 'a\r\nb'::text;\n"
    assert_equal crlf, Vetra::SQL::Outbox.without_operational_partitions(crlf)
    refute_equal Vetra::SQL::Outbox.without_operational_partitions(crlf.sub("\r", '')), Vetra::SQL::Outbox.without_operational_partitions(crlf)
  end
end

class RelayRuntimeTest < GraphTest
  def document(example)
    JSON.parse(File.read(File.join(PROJECT, 'examples', example, '.vetra/graph.json')))
  end

  def setup
    @db = Sequel.mock(host: :postgres)
    @relay = Vetra::Data::Relay.new(@db, document: document('mini_crm'), random: Random.new(1))
  end

  def delivery(attempts: 0)
    Vetra::Data::Relay::Delivery.new(handler: 'crm.notify_sales', event_id: SecureRandom.uuid, event_created_at: '2026-11-07 10:00:00+00',
                                     event_xid8: '700', event_seq: 3, event: 'crm.lead.won', version: 1, tenant_id: SecureRandom.uuid,
                                     payload: { 'id' => SecureRandom.uuid }.freeze, attempts: attempts, leased_until: '2026-11-07 10:01:00+00')
  end

  def test_handlers_come_from_the_graph
    assert_equal({ 'crm.lead.won' => ['crm.notify_sales'] }, Vetra::Data::Relay.handlers(document('mini_crm')))
    assert_equal({}, Vetra::Data::Relay.handlers(document('blog')))
    assert Vetra::Data::Relay.handlers(document('mini_crm')).frozen?
  end

  def test_reserve_refuses_unknown_handlers_and_limits_before_sql
    @db.sqls
    assert_graph_error('data_relay_handler') { @relay.reserve('crm.outro') }
    assert_graph_error('data_relay_limit') { @relay.reserve('crm.notify_sales', limit: 0) }
    assert_graph_error('data_relay_limit') { @relay.reserve('crm.notify_sales', lease: 7200) }
    assert_graph_error('data_relay_limit') { @relay.maintain(ahead: '3', retention: 7) }
    assert_empty @db.sqls
  end

  def test_relay_reads_below_the_snapshot_xmin_and_skips_a_locked_checkpoint
    @db.fetch = lambda do |sql|
      if sql.include?('pg_snapshot_xmin') then [{ v: '900' }]
      elsif sql.include?('relay_checkpoints') && sql.include?('SKIP LOCKED') then []
      else []
      end
    end
    assert_equal 0, @relay.relay!
    sqls = @db.sqls
    assert sqls.any? { |sql| sql.include?('FOR UPDATE SKIP LOCKED') }
    refute sqls.any? { |sql| sql.include?('FROM vetra.outbox') }
    @db.fetch = lambda do |sql|
      if sql.include?('pg_snapshot_xmin') then [{ v: '900' }]
      elsif sql.include?('SKIP LOCKED') then [{ low: '800' }]
      elsif sql.include?('::xid8 > ') then [{ v: true }]
      elsif sql.include?('FROM vetra.outbox')
        [{ created_at: Time.utc(2026, 11, 7), xid8: '850', seq: 4, event_id: SecureRandom.uuid, event: 'crm.lead.won', tenant_id: SecureRandom.uuid }]
      else []
      end
    end
    assert_equal 1, @relay.relay!
    sqls = @db.sqls
    assert sqls.any? { |sql| sql.include?('xid8 >= $1::xid8 AND xid8 < $2::xid8 ORDER BY xid8, seq') }
    assert sqls.any? { |sql| sql.start_with?('INSERT INTO "vetra"."deliveries"') && sql.include?('ON CONFLICT ("handler", "event_id", "event_created_at") DO NOTHING') }
    assert sqls.any? { |sql| sql.start_with?('UPDATE "vetra"."relay_checkpoints"') }
    assert_empty @db.prepared_statements
  end

  def test_failures_retry_with_growing_wait_and_go_dead_with_a_copy
    @db.fetch = [{ v: 1 }]
    assert_equal :retry, @relay.failed(delivery(attempts: 0), ArgumentError.new('dado do evento'))
    retry_sql = @db.sqls.find { |sql| sql.include?("SET attempts = attempts + 1, leased_until = NULL, last_error = ") }
    wait = retry_sql[/"ArgumentError", ([0-9.]+)/, 1].to_f
    assert_includes 8.0..12.0, wait
    refute_includes retry_sql, 'dado do evento'
    assert_equal :dead, @relay.failed(delivery(attempts: 9), IOError.new)
    sqls = @db.sqls
    # A outbox vem antes das entregas, como na manutenção: sem ciclo de locks.
    assert_equal 'LOCK TABLE vetra.outbox IN ACCESS SHARE MODE', sqls[sqls.index('BEGIN') + 1]
    assert sqls.any? { |sql| sql.include?("SET state = 'dead'") }
    assert sqls.any? { |sql| sql.include?('INSERT INTO vetra.dead_deliveries') && sql.include?('ON CONFLICT (handler, event_id) DO NOTHING') }
    assert_equal :dead, @relay.failed(delivery, Vetra::Data::Relay::PermanentFailure.new, permanent: true)
    @db.fetch = []
    refute @relay.failed(delivery, IOError.new)
    refute @relay.complete(delivery)
  end

  def test_work_runs_the_effect_outside_any_relay_transaction
    row = { handler: 'crm.notify_sales', event_id: SecureRandom.uuid, event_created_at: '2026-11-07 10:00:00+00', event_xid8: '700',
            event_seq: 3, event: 'crm.lead.won', version: 1, tenant_id: SecureRandom.uuid, payload: '{"id":"x"}', attempts: 0,
            leased_until: '2026-11-07 10:01:00+00' }
    reserved = 0
    @db.fetch = lambda { |sql| sql.include?('WITH picked') ? ((reserved += 1) == 1 ? [row] : []) : [{ v: 1 }] }
    seen = []
    counts = @relay.work('crm.notify_sales') do |delivery|
      seen << [@db.in_transaction?, delivery.payload]
      raise Vetra::Data::Relay::PermanentFailure if seen.size > 1
    end
    assert_equal [[false, { 'id' => 'x' }]], seen
    assert_equal({ done: 1, retry: 0, dead: 0, lost: 0 }, counts)
    # Uma reserva por entrega, logo antes do efeito: o lease cobre só o efeito dela.
    assert_equal 2, reserved
    sqls = @db.sqls
    sqls.each_index.select { |index| sqls[index].include?('WITH picked') }.each do |index|
      assert_equal 'LOCK TABLE vetra.outbox IN ACCESS SHARE MODE', sqls[index - 1]
    end
  end

  def test_relay_refuses_to_run_inside_an_outer_transaction
    @db.transaction do
      [-> { @relay.relay! }, -> { @relay.reserve('crm.notify_sales') }, -> { @relay.complete(delivery) },
       -> { @relay.failed(delivery, IOError.new) }, -> { @relay.work('crm.notify_sales') { flunk } },
       -> { @relay.maintain }].each { |call| assert_graph_error('data_relay_transaction', &call) }
    end
    refute @db.sqls.any? { |sql| sql.include?('vetra.') }
  end

  def test_connection_failures_are_sanitized
    error = assert_graph_error('data_relay_connection') do
      Vetra::Data::Relay.connect('postgres://vetra_relay:segredo@127.0.0.1:1/nada', connect_timeout: 1, test: true)
    end
    refute_includes error.message, 'segredo'
    assert_nil error.cause
  end

  def test_cli_maintenance_requires_the_database_url_and_refuses_options_of_other_commands
    out, err = StringIO.new, StringIO.new
    with_env('DATABASE_URL' => nil) do
      assert_equal 1, Vetra::CLI.run(['outbox:maintain', '--root', File.join(PROJECT, 'examples', 'mini_crm')], out: out, err: err)
    end
    assert_includes err.string, 'db_database_url'
    err = StringIO.new
    assert_equal 2, Vetra::CLI.run(['graph:check', '--ahead', '3'], out: out, err: err)
    assert_includes err.string, '--ahead e --retention exigem outbox:maintain'
  end

  def with_env(values)
    previous = values.keys.to_h { |key| [key, ENV[key]] }
    values.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    yield
  ensure
    previous.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end
end

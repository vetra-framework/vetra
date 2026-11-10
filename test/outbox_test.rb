require_relative 'test_helper'
require 'vetra/data'
require 'securerandom'

class OutboxTest < GraphTest
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

  def edited_model(example, name)
    document = Vetra::Graph::Data.copy(model(example, name).document)
    yield document['state']['statements']
    Vetra::SQL::Model.new(file: "#{name}.json", text: Vetra::SQL::Model.render(document))
  end

  def test_only_applications_with_events_get_the_outbox_before_the_security_section
    EVENTS.each do |example|
      statements = Vetra::SQL::Outbox.new(schema(example)).statements
      assert_equal 29, Vetra::SQL::Outbox.new(schema(example)).storage.size
      initial = Vetra::SQL::Plan.initial(schema(example)).steps.map(&:sql)
      first = initial.index(statements.first)
      assert_equal statements, initial[first, statements.size]
      revision = initial.index { |sql| sql.start_with?('DO $vetra_roles$') }
      assert revision.nil? || revision > first + statements.size
      kinds = Vetra::SQL::Model.state(schema(example), Vetra::SQL::Plan.initial(schema(example)))['statements'].map { |item| item['kind'] }
      refute_includes kinds, nil
    end
    assert_empty Vetra::SQL::Outbox.new(schema('chat')).statements
    refute Vetra::SQL::Outbox.needed?(document('chat'))
  end

  def test_application_writes_only_the_allowed_columns_and_only_its_own_tenant
    crm = Vetra::SQL::Outbox.new(schema('mini_crm')).storage
    blog = Vetra::SQL::Outbox.new(schema('blog')).storage
    grant = 'GRANT INSERT ("event_id", "event", "version", "tenant_id", "actor_id", "op_id", "cmd", "payload") ON TABLE "vetra"."outbox" TO "vetra_app";'
    assert_equal grant, crm.last
    assert_equal grant, blog.last
    assert_equal 1, crm.count { |sql| sql.include?('TO "vetra_app"') && sql.start_with?('GRANT') }
    assert_includes crm, 'CREATE POLICY "vt_outbox_insert" ON "vetra"."outbox" AS PERMISSIVE FOR INSERT TO "vetra_app" WITH CHECK ' \
                         '("tenant_id" = (SELECT vetra.current_tenant()) AND "actor_id" IS NOT DISTINCT FROM (SELECT vetra.current_actor()));'
    assert_includes blog, 'CREATE POLICY "vt_outbox_insert" ON "vetra"."outbox" AS PERMISSIVE FOR INSERT TO "vetra_app" WITH CHECK ("tenant_id" IS NULL);'
    Vetra::SQL::Outbox::TABLES.each do |name|
      relation = %("vetra"."#{name}")
      %W[ALTER\ TABLE\ #{relation}\ OWNER\ TO\ "vetra_owner"; REVOKE\ ALL\ ON\ TABLE\ #{relation}\ FROM\ PUBLIC,\ "vetra_app";
         ALTER\ TABLE\ #{relation}\ ENABLE\ ROW\ LEVEL\ SECURITY; ALTER\ TABLE\ #{relation}\ FORCE\ ROW\ LEVEL\ SECURITY;].each do |sql|
        assert_includes crm, sql
      end
    end
    outbox = crm.first
    assert_match(/"created_at" timestamp\(6\) with time zone NOT NULL DEFAULT pg_catalog\.statement_timestamp\(\)/, outbox)
    assert_match(/"xid8" pg_catalog\.xid8 NOT NULL DEFAULT pg_catalog\.pg_current_xact_id\(\)/, outbox)
    assert_match(/"seq" bigint GENERATED ALWAYS AS IDENTITY/, outbox)
    assert_match(/PRIMARY KEY \("created_at", "xid8", "seq"\)\n\) PARTITION BY RANGE \("created_at"\);\z/, outbox)
    assert_includes crm, 'CREATE INDEX "vt_deliveries_ready" ON "vetra"."deliveries" ("run_after") WHERE "state" = \'pending\';'
  end

  def test_every_outbox_statement_passes_the_plan_filters_and_has_a_model_identity
    statements = Vetra::SQL::Outbox.new(schema('mini_crm')).statements
    steps = statements.each_with_index.map do |sql, index|
      lock, cost = Vetra::SQL::Plan.classify(sql)
      Vetra::SQL::Plan::Step.new(number: index + 1, phase: 'expand', lock: lock, cost: cost, sql: sql, transaction: nil)
    end
    steps.each { |step| assert_nil Vetra::SQL::Plan.check_step!(step, 'unica', '0001_inicial.sql') }
    plan = Vetra::SQL::Plan.new(number: '0001', name: 'inicial', transaction: 'unica', steps: steps)
    objects = Vetra::SQL::Model.state(schema('mini_crm'), plan)['statements'].map { |item| item.values_at('kind', 'object') }
    assert_includes objects, %w[table vetra.outbox_default]
    assert_includes objects, %w[index vetra.vt_outbox_relay]
    assert_includes objects, %w[policy vetra.outbox.vt_outbox_insert]
  end

  def test_incremental_plan_creates_the_whole_outbox_in_one_transactional_step
    EVENTS.each do |example|
      plan = Vetra::SQL::Differ.call(base: model(example, '0001_inicial'), schema: schema(example), number: '0002')
      # Nos CRMs o mesmo plano traz a troca das rotinas de contexto e das políticas (ADR-024, ADR-041): só a outbox é conferida aqui.
      outbox_sql = Vetra::SQL::Outbox.new(schema(example)).statements.join("\n")
      steps = plan.steps.select { |item| item.sql == outbox_sql }
      assert_equal 1, steps.size
      step = steps.first
      assert_equal %w[sim nenhum catalogo], [step.transaction, step.lock, step.cost]
      assert_equal Vetra::SQL::Outbox.new(schema(example)).statements.join("\n"), step.sql
      # O 0002 integrado tem só o armazenamento (K11); o relay da K12 vem no 0003, sobre ele.
      committed = Vetra::SQL::Plan.parse(File.read(File.join(PROJECT, 'examples', example, 'db/plans/0002_expand.sql')), file: '0002_expand.sql')
      assert_equal [Vetra::SQL::Outbox.new(schema(example)).storage.join("\n")], committed.steps.map(&:sql)
    end
  end

  def test_incremental_plan_refuses_a_changed_or_removed_outbox
    changed = edited_model('blog', '0002_expand') do |statements|
      policy = statements.find { |item| item['kind'] == 'policy' && item['object'].start_with?('vetra.outbox.') }
      policy['sha256'] = '0' * 64
    end
    error = assert_graph_error('db_plan_statement') do
      Vetra::SQL::Differ.call(base: changed, schema: schema('blog'), number: '0003')
    end
    assert_match(/seção da outbox alterada/, error.message)
    removed = edited_model('chat', '0001_inicial') do |statements|
      statements << { 'kind' => 'table', 'object' => 'vetra.outbox', 'sha256' => '1' * 64 }
    end
    error = assert_graph_error('db_plan_remove') do
      Vetra::SQL::Differ.call(base: removed, schema: schema('chat'), number: '0002')
    end
    assert_match(/deixou de ter eventos/, error.message)
    # Uma instrução a mais na base também é alteração: a política excedente seguiria no banco sem estar no modelo.
    extra = edited_model('blog', '0002_expand') do |statements|
      statements << { 'kind' => 'policy', 'object' => 'vetra.outbox.vt_extra', 'sha256' => '2' * 64 }
    end
    error = assert_graph_error('db_plan_statement') do
      Vetra::SQL::Differ.call(base: extra, schema: schema('blog'), number: '0003')
    end
    assert_match(/seção da outbox alterada/, error.message)
    grant = edited_model('blog', '0002_expand') do |statements|
      statements << { 'kind' => 'privilege', 'object' => nil, 'sha256' => '3' * 64 }
    end
    assert_graph_error('db_plan_statement') { Vetra::SQL::Differ.call(base: grant, schema: schema('blog'), number: '0003') }
  end

  def test_dump_normalization_drops_only_the_inherited_default_not_null_names
    dump = <<~SQL
      CREATE TABLE vetra.outbox_default (
          seq bigint CONSTRAINT outbox_seq_not_null NOT NULL,
          created_at timestamp(6) with time zone DEFAULT statement_timestamp() CONSTRAINT outbox_created_at_not_null NOT NULL,
          tenant_id uuid CONSTRAINT nome_proprio NOT NULL,
          op_id uuid CONSTRAINT outbox_seq_not_null NOT NULL
      );

      CREATE TABLE public.t (
          seq bigint CONSTRAINT qualquer_seq_not_null NOT NULL,
          id uuid CONSTRAINT t_id_not_null NOT NULL
      );

      CREATE FUNCTION public.f() RETURNS text LANGUAGE sql AS $$
          seq bigint CONSTRAINT outbox_seq_not_null NOT NULL,
      $$;
    SQL
    normalized = Vetra::SQL::ScratchDatabase.normalize_dump(dump)
    assert_includes normalized, "    seq bigint NOT NULL,\n"
    assert_includes normalized, "    created_at timestamp(6) with time zone DEFAULT statement_timestamp() NOT NULL,\n"
    assert_includes normalized, 'tenant_id uuid CONSTRAINT nome_proprio NOT NULL'
    assert_includes normalized, 'op_id uuid CONSTRAINT outbox_seq_not_null NOT NULL'
    # Fora de uma tabela <pai>_..., o nome fica, mesmo com o sufixo da coluna.
    assert_includes normalized, 'seq bigint CONSTRAINT qualquer_seq_not_null NOT NULL'
    assert_includes normalized, 'id uuid CONSTRAINT t_id_not_null NOT NULL'
    assert_includes normalized, "$$\n    seq bigint CONSTRAINT outbox_seq_not_null NOT NULL,\n$$"
    # Dentro de um literal, inclusive aberto na própria linha, o texto é dado e fica intacto.
    defaults = <<~SQL
      CREATE TABLE public.t (
          note text DEFAULT 'linha
          seq bigint CONSTRAINT outbox_seq_not_null NOT NULL,
      fim'::text,
          seq text DEFAULT 'x CONSTRAINT t_seq_not_null NOT NULL
      '::text
      );
    SQL
    assert_equal defaults, Vetra::SQL::ScratchDatabase.normalize_dump(defaults)
  end
end

class OutboxEmissionTest < GraphTest
  def document(example)
    JSON.parse(File.read(File.join(PROJECT, 'examples', example, '.vetra/graph.json')))
  end

  def setup
    @db = Sequel.mock(host: :postgres)
    @time = Time.iso8601('2026-11-06T12:34:56.123456Z')
    @actor, @tenant, @id = Array.new(3) { SecureRandom.uuid }
    @claims = { op_id: SecureRandom.uuid, actor_id: @actor, cmd: 'blog.publish_post' }
    @work = Vetra::Data::UnitOfWork.new(@db, limits: false, scope: :global, clock: -> { @time })
    @catalog = Vetra::Data::Repositories.new(document('blog'))
  end

  def post(catalog = @catalog)
    catalog.record_type('blog.post').new(id: @id, title: 'Post', author_id: @actor, status: 'published',
                                         published_at: @time, created_at: @time)
  end

  def outbox_inserts
    @db.sqls.select { |sql| sql.start_with?('INSERT INTO "vetra"."outbox"') }
  end

  def test_emission_inserts_the_projected_payload_without_returning_and_notifies_without_content
    ids = @work.transaction(**@claims) { @catalog.emit!(@work, post) }
    assert_equal 1, ids.size
    assert ids.frozen?
    sqls = @db.sqls
    inserts = sqls.select { |sql| sql.start_with?('INSERT INTO "vetra"."outbox"') }
    assert_equal 1, inserts.size
    # pg_auto_parameterize: os valores vão como argumentos do protocolo, nenhum no texto do SQL.
    statement, arguments = inserts.first.split(' -- args: ', 2)
    assert_equal 'INSERT INTO "vetra"."outbox" ("event_id", "event", "version", "tenant_id", "actor_id", "op_id", "cmd", "payload") ' \
                 'VALUES ($1, $2, $3::int4, NULL, $4, $5, $6, $7::jsonb)', statement
    expected = [ids.first, 'blog.post.published', 1, @actor, @claims[:op_id], 'blog.publish_post', { 'id' => @id }]
    assert arguments.start_with?(expected.inspect)
    refute_match(/RETURNING/, statement)
    assert sqls.any? { |sql| sql.start_with?('SELECT pg_notify($1, $2)') && sql.include?('["vetra_outbox", ""]') }
    assert_includes sqls, 'COMMIT'
    assert_empty @db.prepared_statements
  end

  def test_tenant_emission_carries_the_context_tenant_and_requires_a_tenant_unit
    catalog = Vetra::Data::Repositories.new(document('mini_crm'))
    issuer = Vetra::Data::ContextIssuer.new(kid: 'test', secret: SecureRandom.random_bytes(32))
    work = Vetra::Data::UnitOfWork.new(@db, limits: false, issuer: issuer, clock: -> { @time })
    lead = catalog.record_type('crm.lead').new(id: @id, company_id: @tenant, name: 'Lead', status: 'won', email: nil,
                                               valor: nil, created_at: @time)
    work.transaction(**@claims.merge(tenant_id: @tenant, cmd: 'crm.win_lead')) { catalog.emit!(work, lead) }
    sqls = @db.sqls
    assert sqls.any? { |sql| sql.start_with?('INSERT INTO "vetra"."outbox"') && sql.include?(%("crm.lead.won", 1, "#{@tenant}", "#{@actor}")) }
    assert sqls.any? { |sql| sql.start_with?('SELECT pg_notify($1, $2)') && sql.include?(%(["vetra_outbox", "#{@tenant}"])) }
    global = Vetra::Data::UnitOfWork.new(@db, limits: false, scope: :global, clock: -> { @time })
    assert_graph_error('data_scope') do
      global.transaction(**@claims.merge(cmd: 'crm.win_lead')) { catalog.emit!(global, lead) }
    end
  end

  def test_emission_is_refused_outside_the_declared_command_record_and_writable_unit
    assert_graph_error('data_transaction_required') { @catalog.emit!(@work, post) }
    assert_graph_error('data_event') do
      @work.transaction(**@claims.merge(cmd: 'blog.create_post')) { @catalog.emit!(@work, post) }
    end
    assert_graph_error('data_event') do
      @work.transaction(**@claims) { @catalog.emit!(@work, ::Data.define(:id).new(id: @id)) }
    end
    other = Vetra::Data::Repositories.new(document('blog'))
    assert_graph_error('data_event') { @work.transaction(**@claims) { @catalog.emit!(@work, post(other)) } }
    assert_graph_error('data_read_only') { @work.read(**@claims) { @catalog.emit!(@work, post) } }
    assert_empty outbox_inserts
  end

  def test_personal_payload_dooms_the_whole_unit_even_when_the_error_is_rescued
    # O lead.won passa a projetar também o email, campo pessoal do lead: a IR aceita, a outbox não.
    doc = document('mini_crm')
    nodes = doc['nodes']
    email = nodes.find { |node| node['id'] == 'crm.lead' }['fields'].find { |field| field['name'] == 'email' }
    nodes.find { |node| node['id'] == 'crm.lead.won.payload' }['fields'] << email
    nodes.find { |node| node['id'] == 'crm.win_lead' }['emits'].first['fields'] << 'email'
    doc['digest'] = Vetra::Graph::Canonical.digest(doc)
    catalog = Vetra::Data::Repositories.new(doc)
    issuer = Vetra::Data::ContextIssuer.new(kid: 'test', secret: SecureRandom.random_bytes(32))
    work = Vetra::Data::UnitOfWork.new(@db, limits: false, issuer: issuer, clock: -> { @time })
    lead = catalog.record_type('crm.lead').new(id: @id, company_id: @tenant, name: 'Lead', status: 'won',
                                               email: 'lead@example.invalid', valor: nil, created_at: @time)
    [false, true].each do |composed|
      @db.sqls
      error = assert_graph_error('data_event_personal') do
        work.transaction(**@claims.merge(tenant_id: @tenant, cmd: 'crm.win_lead')) do
          body = lambda do
            catalog.emit!(work, lead)
          rescue Vetra::Data::Error
            :resgatado
          end
          composed ? work.compose { body.call } : body.call
          :continuou
        end
      end
      assert_nil error.cause
      sqls = @db.sqls
      refute sqls.any? { |sql| sql.start_with?('INSERT INTO "vetra"."outbox"') }
      assert_includes sqls, 'ROLLBACK'
      refute_includes sqls, 'COMMIT'
    end
    # Uma saída não local (throw, break, return) pula a conferência depois do yield: o rollback vem do próprio doom!.
    [false, true].each do |composed|
      @db.sqls
      catch(:sair) do
        work.transaction(**@claims.merge(tenant_id: @tenant, cmd: 'crm.win_lead')) do
          body = lambda do
            catalog.emit!(work, lead)
          rescue Vetra::Data::Error
            throw :sair
          end
          composed ? work.compose { body.call } : body.call
        end
      end
      sqls = @db.sqls
      assert_includes sqls, 'ROLLBACK'
      refute_includes sqls, 'COMMIT'
    end
  end

  def test_event_values_are_exact_json_text
    decimal = { 'type' => { 'name' => 'decimal', 'precision' => 10, 'scale' => 2 } }
    money = { 'type' => { 'name' => 'money', 'precision' => 12, 'scale' => 2 } }
    assert_equal '100.00', Vetra::Data::Values.event_value(BigDecimal('100'), decimal)
    assert_equal '-0.50', Vetra::Data::Values.event_value(BigDecimal('-0.5'), decimal)
    assert_equal '7', Vetra::Data::Values.event_value(BigDecimal('7'), { 'type' => { 'name' => 'decimal', 'precision' => 4, 'scale' => 0 } })
    assert_equal({ 'amount' => '123.40', 'currency' => 'BRL' },
                 Vetra::Data::Values.event_value(Vetra::Data::Money.new(amount: BigDecimal('123.4'), currency: 'BRL'), money))
    assert_equal '2026-11-06T12:34:56.123456Z', Vetra::Data::Values.event_value(@time.getlocal('-03:00'), { 'type' => { 'name' => 'timestamp' } })
    assert_equal '2026-11-06', Vetra::Data::Values.event_value(Date.new(2026, 11, 6), { 'type' => { 'name' => 'date' } })
    assert_nil Vetra::Data::Values.event_value(nil, decimal)
    assert_equal 'texto', Vetra::Data::Values.event_value('texto', { 'type' => { 'name' => 'string' } })
  end
end

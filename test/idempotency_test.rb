require_relative 'test_helper'
require 'vetra/data'
require 'pg'
require 'securerandom'
require 'digest'

# Registro de idempotência (ADR-043): o gerador SQL, o plano incremental, a API da unidade de trabalho e a purga.
class IdempotencyTest < GraphTest
  EXAMPLES = %w[blog chat mini_crm mini_crm_revendas].freeze
  FIRST_PLAN = { 'blog' => ['0003_expand', '0004'], 'chat' => ['0001_inicial', '0002'],
                 'mini_crm' => ['0004_expand', '0005'], 'mini_crm_revendas' => ['0005_expand', '0006'] }.freeze

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

  def sql(example)
    Vetra::SQL::Idempotency.new(schema(example)).statements
  end

  def test_one_unique_key_serves_the_global_and_the_tenant_context_and_has_no_sentinel_tenant
    EXAMPLES.each do |example|
      table = sql(example).find { |statement| statement.start_with?('CREATE TABLE "vetra"."idempotency"') }
      assert_includes table, 'UNIQUE NULLS NOT DISTINCT ("tenant_id", "command", "key")'
      assert_includes table, %q{"key" text NOT NULL CHECK ("key" ~ '^[!-~]{1,255}$')}
      assert_includes table, 'pg_catalog.octet_length("input_hash") = 32'
      assert_includes table, 'pg_catalog.octet_length("result"::text) <= 65536'
      refute_match(/DEFAULT '0{8}-/, table)
      assert_equal 1, sql(example).count { |statement| statement.include?('CREATE INDEX "vt_idempotency_purge"') }
    end
  end

  def test_origin_event_exists_only_with_an_outbox_and_the_columns_are_all_or_none
    with_outbox = %w[blog mini_crm mini_crm_revendas].map { |example| sql(example).find { |s| s.start_with?('CREATE TABLE') } }
    without = sql('chat').find { |s| s.start_with?('CREATE TABLE') }
    with_outbox.each { |table| assert_includes table, %q{"origin" IN ('adapter', 'event')} }
    assert_includes without, %q{"origin" IN ('adapter')}
    refute_includes without, %q{'adapter', 'event'}
    EXAMPLES.each do |example|
      table = sql(example).find { |s| s.start_with?('CREATE TABLE') }
      assert_includes table, %q{"origin" = 'event' AND "handler" IS NOT NULL AND "event_id" IS NOT NULL AND "event_created_at" IS NOT NULL}
      assert_includes table, %q{"origin" = 'adapter' AND "handler" IS NULL AND "event_id" IS NULL AND "event_created_at" IS NULL}
    end
  end

  def test_the_application_never_deletes_and_only_updates_the_result_while_the_maintenance_role_purges
    EXAMPLES.each do |example|
      statements = sql(example)
      assert_includes statements, 'GRANT SELECT ON TABLE "vetra"."idempotency" TO "vetra_app";'
      assert_includes statements, 'GRANT UPDATE ("result") ON TABLE "vetra"."idempotency" TO "vetra_app";'
      insert = statements.find { |s| s.start_with?('GRANT INSERT (') }
      assert_equal %w[tenant_id command key origin principal input_hash handler event_id event_created_at], insert.scan(/"(\w+)"/).flatten.first(9)
      refute_includes insert, '"result"'
      refute_includes insert, '"created_at""'
      refute statements.any? { |s| s.match?(/GRANT .*(DELETE|TRUNCATE).* TO "vetra_app"/) }
      assert_includes statements, 'GRANT SELECT, DELETE ON TABLE "vetra"."idempotency" TO "vetra_relay";'
      assert_includes statements, 'REVOKE ALL ON TABLE "vetra"."idempotency" FROM PUBLIC, "vetra_app", "vetra_relay";'
      assert_includes statements, 'ALTER TABLE "vetra"."idempotency" FORCE ROW LEVEL SECURITY;'
    end
  end

  def test_the_policy_binds_to_the_tenant_of_the_context_or_to_a_null_tenant
    EXAMPLES.each do |example|
      policy = sql(example).find { |s| s.start_with?('CREATE POLICY "vt_idempotency_app"') }
      tenant = %w[mini_crm mini_crm_revendas].include?(example)
      expected = tenant ? '"tenant_id" = (SELECT vetra.current_tenant())' : '"tenant_id" IS NULL'
      assert_includes policy, "USING (#{expected}) WITH CHECK (#{expected})"
    end
  end

  def test_the_maintenance_guard_and_usage_are_not_repeated_when_the_outbox_already_has_them
    EXAMPLES.each do |example|
      idempotency = Vetra::SQL::Idempotency.new(schema(example))
      outbox = Vetra::SQL::Outbox.new(schema(example))
      assert_empty idempotency.digests & outbox.digests
      assert_equal outbox.statements.empty?, sql(example).include?(Vetra::SQL::Context.relay_guard)
      assert_equal idempotency.digests.uniq, idempotency.digests
    end
  end

  def test_the_section_goes_after_the_outbox_and_before_the_security_in_every_initial_plan
    EXAMPLES.each do |example|
      steps = Vetra::SQL::Plan.initial(schema(example)).steps.map(&:sql)
      first = steps.index(sql(example).first)
      assert_equal sql(example), steps[first, sql(example).size]
      outbox = Vetra::SQL::Outbox.new(schema(example)).statements
      assert_equal first, steps.index(outbox.first) + outbox.size unless outbox.empty?
      assert_equal Vetra::SQL::Plan.initial(schema(example)).render,
                   Vetra::SQL::Plan.parse(Vetra::SQL::Plan.initial(schema(example)).render, file: '0001_inicial.sql').render
    end
  end

  def test_the_incremental_plan_creates_the_whole_section_in_one_transactional_step
    EXAMPLES.each do |example|
      base, number = FIRST_PLAN.fetch(example)
      plan = Vetra::SQL::Differ.call(base: model(example, base), schema: schema(example), number: number)
      committed = File.read(File.join(PROJECT, 'examples', example, "db/plans/#{number}_expand.sql"))
      assert_equal committed, plan.render
      step = plan.steps.first
      assert_equal sql(example).join("\n"), step.sql
      assert_equal %w[sim], [step.transaction]
      assert_equal 1, plan.steps.size
    end
  end

  def test_a_changed_or_extra_section_is_refused_by_the_differ
    base, number = ['0004_expand', '0005']
    document = Vetra::Graph::Data.copy(model('blog', base).document)
    statements = document['state']['statements']
    statements.find { |item| item['kind'] == 'table' && item['object'] == 'vetra.idempotency' }['sha256'] = '0' * 64
    changed = Vetra::SQL::Model.new(file: "#{base}.json", text: Vetra::SQL::Model.render(document))
    assert_graph_error('db_plan_statement') { Vetra::SQL::Differ.call(base: changed, schema: schema('blog'), number: number) }
    # Uma instrução a mais da seção na base (uma política a mais) também é alteração.
    document = Vetra::Graph::Data.copy(model('blog', base).document)
    document['state']['statements'] << { 'kind' => 'policy', 'object' => 'vetra.idempotency.vt_extra', 'sha256' => '1' * 64 }
    extra = Vetra::SQL::Model.new(file: "#{base}.json", text: Vetra::SQL::Model.render(document))
    assert_graph_error('db_plan_statement') { Vetra::SQL::Differ.call(base: extra, schema: schema('blog'), number: number) }
  end

  def test_an_unchanged_base_needs_no_new_plan_for_the_section
    EXAMPLES.each do |example|
      latest = Dir.glob(File.join(PROJECT, 'examples', example, 'db/models/*.json')).map { |file| File.basename(file, '.json') }.max
      number = format('%04d', latest[0, 4].to_i + 1)
      assert_graph_error('db_plan_change') { Vetra::SQL::Differ.call(base: model(example, latest), schema: schema(example), number: number) }
    end
  end

  # --- A API da unidade de trabalho, com um PostgreSQL simulado -------------------------------------------------------

  def setup
    @secret = SecureRandom.random_bytes(32)
    @issuer = Vetra::Data::ContextIssuer.new(kid: 'ephemeral', secret: @secret, clock: -> { 1_800_000_000 })
    @claims = { tenant_id: SecureRandom.uuid, actor_id: SecureRandom.uuid, op_id: SecureRandom.uuid, cmd: 'crm.create_lead' }
  end

  def digest(input)
    Digest::SHA256.digest(Vetra::Graph::Canonical.dump(JSON.parse(JSON.generate(input))))
  end

  # Respostas simuladas: o INSERT ... ON CONFLICT devolve `inserted`; a leitura devolve `existing`.
  def unit_with(inserted:, existing: nil)
    db = Sequel.mock(host: :postgres)
    db.fetch = lambda do |sql|
      if sql.include?('ON CONFLICT')
        inserted
      elsif sql.start_with?('SELECT')
        existing ? [existing] : []
      else
        []
      end
    end
    db.numrows = 1
    work = Vetra::Data::UnitOfWork.new(db, limits: false, issuer: @issuer)
    [db, work]
  end

  def claim(work, **options)
    work.transaction(**@claims) { |unit| Vetra::Data::Idempotency.new(unit).claim!(command: 'crm.create_lead', **options) }
  end

  def test_a_new_key_is_claimed_with_the_hash_the_principal_and_no_result
    db, work = unit_with(inserted: [{ id: 41 }])
    claim = claim(work, key: 'k-1', input: { 'b' => 2, 'a' => 1 })
    refute claim.replay
    assert_equal 41, claim.id
    insert = db.sqls.find { |sql| sql.include?('INSERT INTO "vetra"."idempotency"') }
    assert_includes insert, 'ON CONFLICT ON CONSTRAINT "vt_idempotency_key" DO NOTHING'
    assert_includes insert, @claims[:actor_id]
    assert_includes insert, @claims[:tenant_id]
    assert_includes insert, 'k-1'
    refute_includes insert, 'result'
  end

  def test_a_confirmed_key_with_the_same_input_and_principal_replays_the_stored_result
    row = { id: 5, principal: @claims[:actor_id], input_hash: Sequel.blob(digest({ 'a' => 1, 'b' => 2 })), result_text: '{"id":9,"ok":true}' }
    _, work = unit_with(inserted: [], existing: row)
    claim = claim(work, key: 'k-2', input: { 'b' => 2, 'a' => 1 })
    assert claim.replay
    assert_equal({ 'id' => 9, 'ok' => true }, claim.result)
    assert_equal 5, claim.id
  end

  def test_another_input_or_another_principal_gets_the_same_refusal_without_the_stored_result
    row = { id: 5, principal: @claims[:actor_id], input_hash: Sequel.blob(digest({ 'a' => 1 })), result_text: '{"segredo":"x"}' }
    _, work = unit_with(inserted: [], existing: row)
    by_input = assert_raises(Vetra::Data::IdempotencyKeyReuse) { claim(work, key: 'k-3', input: { 'a' => 2 }) }
    other = row.merge(principal: SecureRandom.uuid)
    _, work = unit_with(inserted: [], existing: other)
    by_principal = assert_raises(Vetra::Data::IdempotencyKeyReuse) { claim(work, key: 'k-3', input: { 'a' => 1 }) }
    [by_input, by_principal].each do |error|
      assert_equal 'data_idempotency_key_reuse', error.diagnostics.first.code
      refute_includes error.message, 'segredo'
      assert_nil error.cause
    end
    assert_equal by_input.message, by_principal.message
  end

  def test_a_row_without_a_stored_result_and_a_vanished_row_are_handled
    row = { id: 5, principal: @claims[:actor_id], input_hash: Sequel.blob(digest({ 'a' => 1 })), result_text: nil }
    _, work = unit_with(inserted: [], existing: row)
    assert_graph_error('data_idempotency_state') { claim(work, key: 'k-4', input: { 'a' => 1 }) }
    # A purga apagou a linha entre as duas instruções: a chave voltou a ser livre e a segunda tentativa a reivindica.
    attempts = 0
    db = Sequel.mock(host: :postgres)
    db.fetch = ->(sql) { sql.include?('ON CONFLICT') ? ((attempts += 1) == 1 ? [] : [{ id: 8 }]) : [] }
    result = Vetra::Data::UnitOfWork.new(db, limits: false, issuer: @issuer).transaction(**@claims) do |unit|
      Vetra::Data::Idempotency.new(unit).claim!(command: 'c', key: 'k-5', input: {})
    end
    refute result.replay
    assert_equal 8, result.id
  end

  def test_a_system_actor_claims_with_its_own_principal
    db, work = unit_with(inserted: [{ id: 3 }])
    work.transaction(tenant_id: @claims[:tenant_id], system_actor: 'crm.on_lead_won', op_id: @claims[:op_id], cmd: 'crm.create_followup') do |unit|
      Vetra::Data::Idempotency.new(unit).claim!(command: 'crm.create_followup', key: 'evento-1', input: { 'a' => 1 })
    end
    assert db.sqls.any? { |sql| sql.include?('INSERT INTO "vetra"."idempotency"') && sql.include?('system:crm.on_lead_won') }
  end

  def test_the_event_origin_carries_the_retention_data_and_nothing_else_does
    db, work = unit_with(inserted: [{ id: 1 }])
    event = { handler: 'crm.on_lead_won', event_id: SecureRandom.uuid, event_created_at: Time.utc(2026, 11, 10, 12) }
    claim(work, key: "evento:#{event[:event_id]}", input: {}, origin: :event, event: event)
    insert = db.sqls.find { |sql| sql.include?('INSERT INTO "vetra"."idempotency"') }
    assert_includes insert, event[:handler]
    assert_includes insert, event[:event_id]
  end

  def test_invalid_keys_origins_inputs_and_results_are_refused_before_any_sql
    db, work = unit_with(inserted: [{ id: 1 }])
    ['', ' ', 'a b', 'á', 'x' * 256, "a\nb", nil, 12].each do |key|
      assert_graph_error('data_idempotency_key') { claim(work, key: key, input: {}) }
    end
    assert_graph_error('data_idempotency_key') { claim(work, key: 'k', input: {}, origin: :event) }
    assert_graph_error('data_idempotency_key') { claim(work, key: 'k', input: {}, origin: :adapter, event: { handler: 'h' }) }
    assert_graph_error('data_idempotency_key') { claim(work, key: 'k', input: {}, origin: :event, event: { handler: 'h', event_id: 'i' }) }
    assert_graph_error('data_idempotency_key') { claim(work, key: 'k', input: {}, origin: :other) }
    assert_graph_error('data_idempotency_input') { claim(work, key: 'k', input: { 'x' => Float::NAN }) }
    refute db.sqls.any? { |sql| sql.include?('INSERT INTO "vetra"."idempotency"') }
  end

  def test_complete_stores_json_within_the_limit_and_refuses_what_is_not_json_or_too_large
    db, work = unit_with(inserted: [{ id: 6 }])
    work.transaction(**@claims) do |unit|
      idempotency = Vetra::Data::Idempotency.new(unit)
      claim = idempotency.claim!(command: 'c', key: 'k-6', input: {})
      assert_nil idempotency.complete!(claim, { 'ok' => true })
      assert_graph_error('data_idempotency_result') { idempotency.complete!(claim, { 'x' => 'a' * 1_100_000 }) } # acima do teto de sanidade
      assert_graph_error('data_idempotency_result') { idempotency.complete!(claim, { 'x' => Float::INFINITY }) }
      assert_nil idempotency.complete!(claim, { 'x' => 'a' * 60_000 })
    end
    update = db.sqls.find { |sql| sql.start_with?('UPDATE "vetra"."idempotency"') }
    assert_includes update, '("id" = $2::int4)'
    assert_includes update, ', 6, '
    assert_includes update, 'CAST($1 AS jsonb)'
  end

  def test_complete_only_accepts_a_new_claim_of_the_same_unit_and_only_once
    db, work = unit_with(inserted: [{ id: 21 }])
    claim_of_a_previous_unit = nil
    work.transaction(**@claims) { |unit| claim_of_a_previous_unit = Vetra::Data::Idempotency.new(unit).claim!(command: 'c', key: 'k-a', input: {}) }
    work.transaction(**@claims) do |unit|
      idempotency = Vetra::Data::Idempotency.new(unit)
      # Um claim de outra transação, um fabricado e um replay não concluem nada.
      assert_graph_error('data_idempotency_state') { idempotency.complete!(claim_of_a_previous_unit, {}) }
      forged = Vetra::Data::Idempotency::Claim.new(id: 99, replay: false, result: nil)
      assert_graph_error('data_idempotency_state') { idempotency.complete!(forged, {}) }
      assert_graph_error('data_idempotency_state') { idempotency.complete!(Object.new, {}) }
      replay = Vetra::Data::Idempotency::Claim.new(id: 5, replay: true, result: {})
      assert_graph_error('data_idempotency_state') { idempotency.complete!(replay, {}) }
      claim = idempotency.claim!(command: 'c', key: 'k-b', input: {})
      # Um Claim construído à mão com os mesmos valores de um claim pendente não vale: a procedência é do objeto emitido por `claim!`.
      look_alike = Vetra::Data::Idempotency::Claim.new(id: claim.id, replay: false, result: nil)
      assert_equal claim, look_alike
      assert_graph_error('data_idempotency_state') { idempotency.complete!(look_alike, {}) }
      assert_nil idempotency.complete!(claim, { 'ok' => true })
      # A segunda conclusão não acha a linha sem resultado: o UPDATE exige `result IS NULL`.
      db.numrows = 0
      assert_graph_error('data_idempotency_state') { idempotency.complete!(claim, { 'ok' => false }) }
    end
    updates = db.sqls.select { |sql| sql.start_with?('UPDATE "vetra"."idempotency"') }
    assert_equal 2, updates.size
    updates.each do |sql|
      assert_includes sql, '"result" IS NULL'
      assert_includes sql, '"principal" ='
    end
  end

  # Como um erro do driver: não é um Sequel::Error; o Sequel o embrulha, e o `result` carrega o SQLSTATE.
  def failing_database(state)
    Class.new(StandardError) do
      define_method(:initialize) { |code| @code = code; super('ERRO com segredo do driver') }
      define_method(:result) { self }
      define_method(:error_field) { |_field| @code }
    end.new(state)
  end

  def test_complete_translates_database_errors_through_the_public_api_without_the_driver_message
    { '55P03' => ->(e) { e.kind == :lock_timeout }, '40P01' => ->(e) { e.kind == :deadlock },
      '23514' => ->(e) { e.diagnostics.first.code == 'data_idempotency_result' },
      '42501' => ->(e) { e.diagnostics.first.code == 'data_access_denied' },
      'XX000' => ->(e) { e.diagnostics.first.code == 'data_database' } }.each do |state, expectation|
      db, work = unit_with(inserted: [{ id: 30 }])
      error = assert_raises(Vetra::Data::Error) do
        work.transaction(**@claims) do |unit|
          idempotency = Vetra::Data::Idempotency.new(unit)
          claim = idempotency.claim!(command: 'c', key: "k-#{state}", input: {})
          failure = failing_database(state)
          db.numrows = ->(_sql) { raise failure }
          idempotency.complete!(claim, {})
        end
      end
      ok = begin
        expectation.call(error)
      rescue NoMethodError
        false
      end
      assert ok, "#{state}: #{error.class} #{error.diagnostics.first.code}"
      refute_includes error.message, 'segredo'
      assert_nil error.cause
    end
  end

  def test_the_database_is_the_judge_of_the_result_size_and_ruby_only_filters_the_obvious
    # {"x":"a"*65528} ocupa 65.536 bytes em JSON compacto, mas o jsonb::text tem um espaço a mais: o banco recusa (23514).
    _, work = unit_with(inserted: [{ id: 31 }])
    boundary = { 'x' => 'a' * 65_528 }
    assert_equal 65_536, JSON.generate(boundary).bytesize
    work.transaction(**@claims) do |unit|
      idempotency = Vetra::Data::Idempotency.new(unit)
      claim = idempotency.claim!(command: 'c', key: 'k-limite', input: {})
      assert_nil idempotency.complete!(claim, boundary) # o banco simulado aceita; quem decide é o CHECK real (sonda)
      # O JSON compacto pode ser MAIOR que o jsonb::text: chaves repetidas ficam só com a última, números e escapes encolhem. Por isso o
      # Ruby não decide o teto de 64 KiB: abaixo do limite do payload serializado (1 MiB) o que cabe no banco passa, e acima dele é recusado antes.
      repeated = { 'x' => 'a' * 65_528, x: 1 }
      assert_operator JSON.generate(repeated).bytesize, :>, 65_536
      assert_nil idempotency.complete!(claim, repeated)
      assert_graph_error('data_idempotency_result') { idempotency.complete!(claim, { 'x' => 'a' * 1_100_000 }) }
    end
  end

  def test_database_errors_are_translated_without_the_driver_message
    fake = Struct.new(:state) do
      def result = self
      def error_field(_) = state
    end
    work = Vetra::Data::UnitOfWork.new(Sequel.mock(host: :postgres), limits: false, issuer: @issuer)
    translate = lambda do |state, klass = Sequel::DatabaseError|
      error = klass.new('ERRO com segredo do driver')
      error.wrapped_exception = fake.new(state)
      work.transaction(**@claims) { Vetra::Data::DatabaseErrors.translate(error) }
    end
    assert_equal :lock_timeout, translate.call('55P03').kind
    assert_equal :deadlock, translate.call('40P01').kind
    assert_equal :serialization, translate.call('40001').kind
    assert_equal :serialization, translate.call('XX000', Sequel::SerializationFailure).kind
    assert_equal 'data_access_denied', translate.call('42501').diagnostics.first.code
    other = translate.call('XX000')
    assert_equal 'data_database', other.diagnostics.first.code
    refute_includes other.message, 'segredo'
  end

  # --- A purga, pelo papel de manutenção -------------------------------------------------------------------------------

  CUTOFF = '2026-11-10 10:00:00.123456+00'

  # O corte vem do banco: a primeira consulta devolve CUTOFF, as demais (os lotes) devolvem `rows`.
  def cutoff_fetch(rows)
    ->(sql) { sql.include?('AS cutoff') ? [{ cutoff: CUTOFF }] : (rows.respond_to?(:call) ? rows.call : rows) }
  end

  def relay(example, rows: [])
    db = Sequel.mock(host: :postgres)
    db.fetch = cutoff_fetch(rows)
    [db, Vetra::Data::Relay.new(db, document: document(example))]
  end

  def test_the_purge_covers_the_adapter_origin_and_the_event_origin_only_with_an_outbox
    db, relay = relay('blog')
    assert_equal({ 'adapter' => 0, 'event' => 0 }, relay.purge_idempotency)
    logged = db.sqls # o mock esvazia o registro a cada leitura
    cutoff = logged.first
    assert_includes cutoff, 'pg_catalog.clock_timestamp()'
    assert_includes cutoff, 'make_interval(hours => $1'
    assert_includes cutoff, '::text AS cutoff'
    deletes = logged.select { |sql| sql.include?('DELETE FROM vetra.idempotency') }
    assert_equal 2, deletes.size, logged.join("\n---\n")
    adapter, event = deletes
    assert_includes adapter, 'origin = $1'
    assert_includes adapter, 'i.created_at < CAST($2 AS timestamptz)'
    assert_includes adapter, %(-- args: ["adapter", "#{CUTOFF}", 1000])
    assert_includes adapter, 'LIMIT $3::int4'
    refute_includes adapter, 'deliveries'
    assert_includes event, %(-- args: ["event", "#{CUTOFF}", 1000])
    assert_includes event, 'NOT EXISTS (SELECT 1 FROM vetra.deliveries'
    assert_includes event, 'NOT EXISTS (SELECT 1 FROM vetra.dead_deliveries'
    refute_includes event, 'FOR UPDATE'
    db, relay = relay('chat')
    assert_equal({ 'adapter' => 0 }, relay.purge_idempotency(retention_hours: 48, batch: 7))
    logged = db.sqls
    assert_equal 1, logged.count { |sql| sql.include?('DELETE FROM vetra.idempotency') }
    assert_includes logged.first, '48'
    assert_includes logged.last, %(-- args: ["adapter", "#{CUTOFF}", 7])
  end

  def test_the_purge_repeats_while_a_batch_comes_full_and_sums_the_deletions
    db, relay = relay('chat', rows: [{ x: 1 }, { x: 1 }])
    assert_equal({ 'adapter' => 2 }, relay.purge_idempotency(batch: 3))
    assert_equal 1, db.sqls.count { |sql| sql.include?('DELETE FROM vetra.idempotency') }
    calls = 0
    db = Sequel.mock(host: :postgres)
    db.fetch = cutoff_fetch(-> { (calls += 1) < 3 ? [{ x: 1 }, { x: 1 }] : [{ x: 1 }] })
    relay = Vetra::Data::Relay.new(db, document: document('chat'))
    assert_equal({ 'adapter' => 5 }, relay.purge_idempotency(batch: 2))
    assert_equal 3, calls
  end

  def test_the_purge_cutoff_comes_from_the_database_once_per_run_so_a_continuous_load_cannot_keep_it_running
    calls = 0
    db = Sequel.mock(host: :postgres)
    db.fetch = cutoff_fetch(-> { (calls += 1) < 4 ? [{ x: 1 }, { x: 1 }] : [] })
    relay = Vetra::Data::Relay.new(db, document: document('chat'))
    assert_equal({ 'adapter' => 6 }, relay.purge_idempotency(batch: 2))
    logged = db.sqls
    assert_equal 1, logged.count { |sql| sql.include?('AS cutoff') }
    cutoffs = logged.select { |sql| sql.include?('DELETE FROM') }.map { |sql| sql[/-- args: \["adapter", "([^"]+)"/, 1] }
    assert_equal 4, cutoffs.size
    assert_equal [CUTOFF], cutoffs.uniq
    # Texto com o fuso e CAST para timestamptz: nunca um `timestamp` sem fuso, que mudaria o corte conforme a sessão.
    refute(logged.any? { |sql| sql.include?('::timestamp ') || sql.include?('$2::timestamp') })
  end

  def test_the_purge_refuses_invalid_limits_and_a_surrounding_transaction
    _, relay = relay('chat')
    [{ retention_hours: 0 }, { retention_hours: 8761 }, { batch: 0 }, { batch: 10_001 }, { retention_hours: '24' }, { batch: 2.5 }].each do |options|
      assert_graph_error('data_relay_limit') { relay.purge_idempotency(**options) }
    end
    db = Sequel.mock(host: :postgres)
    relay = Vetra::Data::Relay.new(db, document: document('chat'))
    db.transaction { assert_graph_error('data_relay_transaction') { relay.purge_idempotency } }
  end

  def test_cli_purge_requires_the_database_url_and_refuses_options_of_other_commands
    out, err = StringIO.new, StringIO.new
    with_env('DATABASE_URL' => nil) do
      assert_equal 1, Vetra::CLI.run(['idempotency:purge', '--root', File.join(PROJECT, 'examples', 'chat')], out: out, err: err)
    end
    assert_includes err.string, 'db_database_url'
    err = StringIO.new
    assert_equal 2, Vetra::CLI.run(['graph:check', '--batch', '5'], out: out, err: err)
    assert_includes err.string, '--retention-hours e --batch exigem idempotency:purge'
    %w[db:plan outbox:maintain db:migrate].each do |command|
      err = StringIO.new
      assert_equal 2, Vetra::CLI.run([command, '--batch', '5'], out: out, err: err), command
      assert_includes err.string, '--retention-hours e --batch exigem idempotency:purge'
    end
    err = StringIO.new
    assert_equal 2, Vetra::CLI.run(['idempotency:purge', '--ahead', '3'], out: out, err: err)
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

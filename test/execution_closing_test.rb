require_relative 'test_helper'
require 'vetra/execution'
require 'securerandom'
require 'digest'

# Fechamento transacional do Runner (K19, ADR-047), sem banco: eventos na etapa 7, idempotência na unidade, o mapeamento do erro
# para o status do ADR-016 e a repetição depois de falha de serialização ou deadlock.
class ExecutionClosingTest < GraphTest
  def self.linked(example)
    (@linked ||= {})[example] ||= Vetra::Graph::Compiler.new(root: File.join(PROJECT, 'examples', example)).link
  end

  def id = SecureRandom.uuid

  def setup
    @actor = id
    @post_id = id
    @now = Time.now.utc.floor(6)
    @row = { id: @post_id, title: 'Título', author_id: @actor, status: 'draft', published_at: nil, created_at: @now }
    @identity = Vetra::Execution::Identity.new(actor_id: @actor, roles: ['blog.autor'])
    @sleeps = []
    @seen = []
  end

  def routed_db(tables)
    Sequel.mock(host: :postgres).tap do |db|
      db.numrows = 1
      db.fetch = lambda do |sql|
        next [] if sql.include?('set_config') || sql.include?('current_setting')
        table = sql[/(?:FROM|INTO|UPDATE) "(?:public|vetra)"\."(\w+)"/, 1]
        rows = tables[table]
        rows = rows.call(sql) if rows.respond_to?(:call)
        Array(rows)
      end
    end
  end

  def sqls = @seen.concat(@ops_db.sqls)

  def build(example, ops_tables, facts_tables = nil, scoped: false, unit_options: {})
    linked = example.is_a?(String) ? self.class.linked(example) : example
    catalog = Vetra::Data::Repositories.new(linked.document)
    @authority = Vetra::Execution::InProcessAuthority.new
    @ops_db = routed_db(ops_tables)
    facts_db = routed_db(facts_tables || ops_tables)
    options = scoped ? { issuer: Vetra::Data::ContextIssuer.new(kid: 'k', secret: SecureRandom.random_bytes(32)) } : { scope: :global }
    facts = Vetra::Execution::DatabaseFacts.new(catalog: catalog, authority: @authority,
                                                unit: Vetra::Data::UnitOfWork.new(facts_db, limits: false, **options))
    edge = Vetra::Execution::Edge.new(identity: ->(c) { c }, facts: facts, authority: @authority)
    Vetra::Execution::Runner.new(linked: linked, catalog: catalog, edge: edge, unit_options: unit_options,
                                 unit: Vetra::Data::UnitOfWork.new(@ops_db, limits: false, **options),
                                 sleeper: ->(seconds) { @sleeps << seconds }, random: -> { 0.5 })
  end

  def blog(tables = nil, **options)
    tables ||= options.select { |key, _| key.is_a?(String) }
    options = options.reject { |key, _| key.is_a?(String) }
    build('blog', tables.empty? ? { 'posts' => [@row] } : tables, **options)
  end

  def publish(runner, key: nil) = runner.run('blog.publish_post', { post_id: @post_id }, credentials: @identity, idempotency_key: key)

  def failure_with(state, klass = Sequel::DatabaseError)
    wrapped = Struct.new(:state) do
      def result = self
      def error_field(_field) = state
    end.new(state)
    klass.new('SQL SELECT segredo').tap { |error| error.wrapped_exception = wrapped }
  end

  def input_hash(input)
    Digest::SHA256.digest(Vetra::Graph::Canonical.dump(JSON.parse(JSON.generate(input))))
  end

  # ---- eventos (etapa 7) -----------------------------------------------------------------------------------------------

  def test_the_runner_writes_the_declared_event_in_step_seven_from_the_returned_record_and_never_the_call
    runner = blog
    outcome = publish(runner)
    assert outcome.ok?, outcome.diagnostics.map(&:to_s).join
    statements = sqls
    outbox = statements.select { |sql| sql.start_with?('INSERT INTO "vetra"."outbox"') }
    assert_equal 1, outbox.size
    assert_includes outbox.first, 'blog.post.published'
    assert(statements.any? { |sql| sql.include?("pg_notify('vetra_outbox'") || sql.include?('pg_notify($1') || sql.include?('pg_notify') })
    assert_equal 1, statements.count { |sql| sql.start_with?('COMMIT') }
    last_write = statements.rindex { |sql| sql.start_with?('UPDATE "public"."posts"') }
    assert_operator statements.index(outbox.first), :>, last_write, 'o evento é gravado depois da escrita, na etapa 7'
  end

  def test_a_failed_or_refused_operation_writes_no_event
    runner = blog('posts' => [@row.merge(status: 'published')])
    failed = runner.run('blog.publish_post', { post_id: @post_id }, credentials: @identity)
    assert_equal :failed, failed.status
    assert(sqls.none? { |sql| sql.start_with?('INSERT INTO "vetra"."outbox"') })
    @seen.clear
    denied = blog.run('blog.publish_post', { post_id: @post_id }, credentials: Vetra::Execution::Identity.new)
    assert_equal :denied, denied.status
    assert_empty sqls
  end

  def test_declared_events_need_the_record_of_their_entity_and_a_command_without_events_writes_none
    linked = self.class.linked('blog')
    catalog = Vetra::Data::Repositories.new(linked.document)
    unit = Vetra::Data::UnitOfWork.new(routed_db({}), scope: :global, limits: false)
    unit.transaction(actor_id: @actor, op_id: id, cmd: 'blog.publish_post') do |active|
      comment = catalog.record_type('blog.comment').new(id: id, post_id: id, author_name: 'A', author_email: 'a@b.invalid', body: 'B',
                                                         approved: false, created_at: @now)
      assert_equal 'data_event', assert_raises(Vetra::Data::Error) { catalog.emit_declared!(active, comment) }.code
      assert_equal 'data_event', assert_raises(Vetra::Data::Error) { catalog.emit_declared!(active, { 'not' => 'a record' }) }.code
    end
    unit.transaction(actor_id: @actor, op_id: id, cmd: 'blog.find_post') do |active|
      assert_empty catalog.emit_declared!(active, :anything)
    end
  end

  # ---- idempotência (etapa 4 e 7) ------------------------------------------------------------------------------------------

  def test_a_new_key_is_claimed_in_the_unit_and_its_result_is_completed_with_the_event_in_the_same_transaction
    ops = { 'posts' => [@row], 'idempotency' => [{ id: 7 }] }
    runner = blog(ops)
    outcome = publish(runner, key: 'chave-1')
    assert outcome.ok?, outcome.diagnostics.map(&:to_s).join
    refute outcome.replayed?
    statements = sqls
    claim = statements.index { |sql| sql.start_with?('INSERT INTO "vetra"."idempotency"') }
    complete = statements.index { |sql| sql.start_with?('UPDATE "vetra"."idempotency"') }
    event = statements.index { |sql| sql.start_with?('INSERT INTO "vetra"."outbox"') }
    commit = statements.index { |sql| sql.start_with?('COMMIT') }
    first_read = statements.index { |sql| sql.include?('FOR UPDATE') }
    assert claim && complete && event && commit
    assert_operator claim, :<, first_read, 'a chave é reivindicada na etapa 4, antes do call'
    assert_operator event, :<, commit
    assert_operator complete, :<, commit, 'o resultado entra na mesma transação'
    assert_includes statements[complete], '"id"', 'o claim é concluído pelo id que a biblioteca emitiu'
  end

  def test_the_same_key_and_input_replays_the_stored_result_without_running_the_call_writing_or_emitting
    stored = { 'id' => @post_id, 'title' => 'Título', 'status' => 'published' }
    existing = { id: 7, principal: @actor, input_hash: input_hash('post_id' => @post_id), result_text: JSON.generate(stored) }
    ops = { 'posts' => [@row], 'idempotency' => ->(sql) { sql.start_with?('INSERT') ? [] : [existing] } }
    runner = blog(ops)
    outcome = publish(runner, key: 'chave-1')
    assert outcome.ok?
    assert outcome.replayed?
    assert_equal stored, outcome.value, 'o replay devolve o JSON guardado'
    statements = sqls
    assert(statements.none? { |sql| sql.start_with?('UPDATE', 'DELETE') || sql.include?('FOR UPDATE') }, 'o call não roda de novo')
    assert(statements.none? { |sql| sql.start_with?('INSERT INTO "vetra"."outbox"') }, 'sem evento duplicado')
    assert_includes statements, 'COMMIT'
  end

  def test_a_key_used_with_another_input_or_principal_is_a_422_that_reveals_nothing
    existing = { id: 7, principal: @actor, input_hash: input_hash('post_id' => id), result_text: '{"segredo":1}' }
    runner = blog('posts' => [@row], 'idempotency' => ->(sql) { sql.start_with?('INSERT') ? [] : [existing] })
    outcome = publish(runner, key: 'chave-1')
    assert_equal :failed, outcome.status
    assert_equal 422, outcome.http_status
    assert_equal 'data_idempotency_key_reuse', outcome.code
    refute_includes outcome.diagnostics.map(&:message).join, 'segredo'
    refute(sqls.any? { |sql| sql.start_with?('INSERT INTO "vetra"."outbox"') })
  end

  def test_a_key_is_refused_before_step_four_for_a_query_a_bad_key_and_a_personal_result
    runner = blog
    query = runner.run('blog.find_post', { post_id: @post_id }, credentials: @identity, idempotency_key: 'k')
    assert_equal [:invalid, 'execution_idempotency_query'], [query.status, query.code]
    ['', 'com espaço', 'x' * 256, 7].each do |key|
      bad = publish(runner, key: key)
      assert_equal [:invalid, 'data_idempotency_key'], [bad.status, bad.code], key.inspect
    end
    assert_empty sqls

    crm = build('mini_crm', {}, {}, scoped: true)
    identity = Vetra::Execution::Identity.new(tenant_id: id, actor_id: @actor, roles: ['crm.gerente'])
    personal = crm.run('crm.update_lead', { id: id, name: 'Cliente' }, credentials: identity, idempotency_key: 'k')
    assert_equal [:invalid, 'execution_idempotency_personal'], [personal.status, personal.code]
    assert_empty sqls
  end

  # ---- status do ADR-016 ----------------------------------------------------------------------------------------------------

  def test_fail_is_a_422_a_missing_record_a_404_a_denied_access_in_the_body_a_403
    failed = blog('posts' => [@row.merge(status: 'published')]).run('blog.publish_post', { post_id: @post_id }, credentials: @identity)
    assert_equal [:failed, 422, false], [failed.status, failed.http_status, failed.retryable?]
    assert_equal 'execution_failure', failed.code

    missing = build('blog', { 'posts' => [] }, { 'posts' => [@row] }).run('blog.read_post', { id: @post_id }, credentials: @identity)
    assert_equal [:not_found, 404], [missing.status, missing.http_status]

    room = { id: id, owner_id: @actor, name: 'S', created_at: @now }
    chat = build('chat', { 'rooms' => [room], 'room_memberships' => [{ id: id, room_id: room[:id], user_id: @actor, created_at: @now }],
                           'users' => [{ id: @actor, name: 'E', email: 'e@probe.invalid', created_at: @now }] })
    @seen.clear
    denied = chat.run('chat.add_member_by_email', { room_id: room[:id], email: 'ana@probe.invalid' },
                      credentials: Vetra::Execution::Identity.new(actor_id: @actor, roles: ['chat.authenticated']))
    assert_equal [:denied, 403, 'data_authorization_denied'], [denied.status, denied.http_status, denied.code]
    statements = sqls
    assert_includes statements, 'ROLLBACK'
    refute(statements.any? { |sql| sql.start_with?('INSERT') }, 'a recusa no corpo não deixa escrita nem evento')
  end

  def test_a_unique_conflict_is_a_409_that_is_not_retried_and_a_timeout_is_a_retryable_500
    unique = blog('posts' => ->(sql) { raise Sequel::UniqueConstraintViolation, 'x' if sql.start_with?('UPDATE'); [@row] })
    outcome = publish(unique)
    assert_equal [:conflict, 409, false, 1], [outcome.status, outcome.http_status, outcome.retryable?, outcome.attempts]
    assert_empty @sleeps

    timeout = blog('posts' => ->(sql) { raise failure_with('57014') if sql.include?('FOR UPDATE'); [@row] })
    outcome = publish(timeout)
    assert_equal [:error, 500, true], [outcome.status, outcome.http_status, outcome.retryable?]
    assert_equal 'data_statement_timeout', outcome.code

    locked = blog('posts' => ->(sql) { raise failure_with('55P03') if sql.include?('FOR UPDATE'); [@row] })
    outcome = publish(locked)
    assert_equal [:conflict, true, 1], [outcome.status, outcome.retryable?, outcome.attempts], 'lock_timeout não é repetido pelo Runner'
    assert_empty @sleeps
  end

  def test_an_unexpected_error_is_a_500_without_its_message_and_run_bang_raises_it
    with_app('blog') do |root, compiler|
      edit(root, 'app/domains/blog/publish_post.rb') { |source| source.sub(/^(\s*)fail! :status.*$/) { "#{Regexp.last_match(1)}raise \"segredo-do-call\"" } }
      compiler.write
      boom = build(compiler.link, { 'posts' => [@row] })
      outcome = publish(boom)
      assert_equal [:error, 500, 'execution_unexpected'], [outcome.status, outcome.http_status, outcome.code]
      refute_includes outcome.diagnostics.map(&:message).join, 'segredo'
      assert_equal 'segredo-do-call', assert_raises(RuntimeError) { boom.run!('blog.publish_post', { post_id: @post_id }, credentials: @identity) }.message
      assert_includes sqls, 'ROLLBACK'
    end
  end

  def test_the_outcome_maps_every_status_to_its_http_code_and_hides_its_value
    statuses = Vetra::Execution::Runner::Outcome::HTTP
    assert_equal({ ok: 200, unresolved: 401, invalid: 422, denied: 403, not_found: 404, failed: 422, conflict: 409, error: 500 }, statuses)
    outcome = Vetra::Execution::Runner::Outcome.new(status: :ok, value: { secret: 1 })
    assert_equal 1, outcome.attempts
    refute outcome.replayed?
    refute_includes outcome.inspect, 'secret'
  end

  # ---- repetição --------------------------------------------------------------------------------------------------------------

  def flaky(failures, error = -> { Sequel::SerializationFailure.new('x') })
    calls = 0
    -> (sql) do
      if sql.include?('FOR UPDATE') && (calls += 1) <= failures
        raise error.call
      end
      [@row]
    end
  end

  def test_a_serialization_failure_repeats_the_whole_operation_once_it_is_rolled_back_without_a_duplicate_event
    runner = blog({ 'posts' => flaky(1) })
    outcome = publish(runner)
    assert outcome.ok?, outcome.diagnostics.map(&:to_s).join
    assert_equal 2, outcome.attempts
    assert_equal 1, @sleeps.size
    assert_operator @sleeps.first, :>, 0
    statements = sqls
    assert_includes statements, 'ROLLBACK'
    assert_equal 1, statements.count { |sql| sql.start_with?('INSERT INTO "vetra"."outbox"') }, 'o evento da tentativa desfeita não existe'
    assert_equal 1, statements.count { |sql| sql.start_with?('COMMIT') }
  end

  def test_a_deadlock_repeats_too_and_the_wait_grows_with_each_repetition_until_three_repetitions
    deadlock = -> { failure_with('40P01') }
    runner = blog({ 'posts' => flaky(2, deadlock) })
    outcome = publish(runner)
    assert_equal [true, 3], [outcome.ok?, outcome.attempts]
    assert_equal 2, @sleeps.size
    assert_operator @sleeps.last, :>, @sleeps.first

    @sleeps.clear
    exhausted = blog({ 'posts' => flaky(99) })
    outcome = publish(exhausted)
    assert_equal [:conflict, 409, true, 4], [outcome.status, outcome.http_status, outcome.retryable?, outcome.attempts]
    assert_equal 3, @sleeps.size, 'no máximo 3 repetições'
    assert_equal @sleeps.sort, @sleeps
    assert_equal 'data_serialization', outcome.code
    assert(sqls.none? { |sql| sql.start_with?('INSERT INTO "vetra"."outbox"') })
  end

  def test_an_operation_with_an_unsafe_effect_or_a_capability_without_safe_retry_is_never_repeated
    with_app('blog') do |root, compiler|
      edit(root, 'app/domains/blog/publish_post.rb') { |source| source.sub("  uses :posts, :clock\n", "  uses :posts, :clock\n  unsafe_effect \"escreve fora do banco\"\n") }
      compiler.write
      runner = build(compiler.link, { 'posts' => flaky(1) })
      outcome = publish(runner)
      assert_equal [:conflict, true, 1], [outcome.status, outcome.retryable?, outcome.attempts]
      assert_empty @sleeps
    end
    crm = build('mini_crm', {}, {}, scoped: true)
    mailer = { 'uses' => [{ 'id' => 'crm.mailer', 'kind' => 'capability' }] }
    assert crm.__send__(:retry_safe?, { 'uses' => [{ 'id' => 'crm.leads', 'kind' => 'capability' }] })
    assert crm.__send__(:retry_safe?, mailer), 'o mailer do exemplo declara retry_safe true'
    refute crm.__send__(:retry_safe?, { 'uses' => [], 'unsafe_effect' => 'motivo' })
    with_app('mini_crm') do |root, compiler|
      edit(root, 'app/domains/crm/effects.rb') { |source| source.sub('retry_safe true', 'retry_safe false') }
      compiler.write
      unsafe = build(compiler.link, {}, {}, scoped: true)
      refute unsafe.__send__(:retry_safe?, mailer), 'uma capacidade retry_safe: false torna a operação irrepetível'
    end
  end

  def test_each_attempt_claims_the_key_again_and_the_unique_result_is_completed_once
    runner = blog({ 'posts' => flaky(1), 'idempotency' => [{ id: 7 }] })
    outcome = publish(runner, key: 'chave-1')
    assert outcome.ok?
    statements = sqls
    assert_equal 2, statements.count { |sql| sql.start_with?('INSERT INTO "vetra"."idempotency"') }, 'a tentativa desfeita perdeu o claim'
    assert_equal 1, statements.count { |sql| sql.start_with?('UPDATE "vetra"."idempotency"') }
  end

  # ---- rodada 1 da auditoria ----------------------------------------------------------------------------------------------

  def test_the_stored_result_has_only_the_declared_fields_and_a_value_off_the_contract_is_never_stored
    with_app('blog') do |root, compiler|
      File.write(File.join(root, 'app/domains/blog/publish_post.rb'), <<~RUBY)
        command :publish_post do
          input :post_id, :id
          returns :post
          authorize :update, :post, record: :post_id
          uses :posts, :comments

          call do |input, posts, comments|
            case input.post_id
            when "#{@post_id}"
              # outra entidade, com campo pessoal
              comments.create!(post_id: input.post_id, author_name: "A", author_email: "a@b.invalid", body: "B")
            else
              # um hash só com o campo pessoal projetado
              { "outer" => [{ "author_email" => "a@b.invalid" }] }
            end
          end
        end
      RUBY
      compiler.write
      comment = { id: id, post_id: @post_id, author_name: 'A', author_email: 'a@b.invalid', body: 'B', approved: false, created_at: @now }
      other_post = id
      runner = build(compiler.link, { 'posts' => [@row.merge(id: other_post), @row], 'comments' => [comment], 'idempotency' => [{ id: 7 }] })
      admin = Vetra::Execution::Identity.new(actor_id: @actor, roles: ['blog.admin'])
      [@post_id, other_post].each do |post_id|
        @seen.clear
        keyed = runner.run('blog.publish_post', { post_id: post_id }, credentials: admin, idempotency_key: "k-#{post_id}")
        assert_equal [:error, 'data_idempotency_result'], [keyed.status, keyed.code], post_id
        statements = sqls
        assert_includes statements, 'ROLLBACK'
        refute(statements.any? { |sql| sql.start_with?('UPDATE "vetra"."idempotency"') }, 'um valor fora do contrato nunca é guardado')
      end
    end
  end

  def test_extra_fields_of_the_returned_record_are_not_stored
    runner = blog('posts' => [@row], 'idempotency' => [{ id: 7 }])
    statements = nil
    assert publish(runner, key: 'k-extra').ok?
    statements = sqls
    update = statements.find { |sql| sql.start_with?('UPDATE "vetra"."idempotency"') }
    refute_nil update
    refute_includes update, 'author_email'
    post = Vetra::Data::Repositories.new(self.class.linked('blog').document).record_type('blog.post').new(**@row)
    assert_equal %w[author_id created_at id published_at status title], runner.serialize('blog.publish_post', post).keys.sort
  end

  def test_a_body_that_raises_stop_iteration_is_an_unexpected_error_not_a_silent_rollback
    with_app('blog') do |root, compiler|
      edit(root, 'app/domains/blog/publish_post.rb') { |source| source.sub(/^(\s*)fail! :status.*$/) { "#{Regexp.last_match(1)}[].each.next" } }
      compiler.write
      runner = build(compiler.link, { 'posts' => [@row] })
      outcome = publish(runner)
      assert_equal [:error, 'execution_unexpected'], [outcome.status, outcome.code]
      assert_includes sqls, 'ROLLBACK'
      assert_raises(StopIteration) { runner.run!('blog.publish_post', { post_id: @post_id }, credentials: @identity) }
    end
  end

  def test_attempts_keep_counting_when_an_unexpected_error_follows_a_repetition
    with_app('blog') do |root, compiler|
      edit(root, 'app/domains/blog/publish_post.rb') { |source| source.sub(/^(\s*)fail! :status.*$/) { "#{Regexp.last_match(1)}raise \"segredo-do-call\"" } }
      compiler.write
      runner = build(compiler.link, { 'posts' => flaky(1) })
      outcome = publish(runner)
      assert_equal [:error, 'execution_unexpected', 2], [outcome.status, outcome.code, outcome.attempts]
    end
  end

  def test_a_malformed_key_is_a_422_even_with_a_broken_encoding
    runner = blog
    ["\xFF".dup.force_encoding('UTF-8'), 'chaveé', 'k'.encode('UTF-16LE'), "k\0"].each do |key|
      outcome = publish(runner, key: key)
      assert_equal [:invalid, 'data_idempotency_key'], [outcome.status, outcome.code], key.inspect
    end
    assert_empty sqls
  end

  def test_the_input_hash_keeps_microseconds_and_a_json_input_with_a_fraction_cannot_carry_a_key
    with_app('blog') do |root, compiler|
      edit(root, 'app/domains/blog/publish_post.rb') { |source| source.sub("  input :post_id, :id\n", "  input :post_id, :id\n  input :quando, :timestamp, optional: true\n  input :meta, :json, optional: true\n") }
      compiler.write
      runner = build(compiler.link, { 'posts' => [@row], 'idempotency' => [{ id: 7 }] })
      one = '2026-11-11T10:00:00.000001Z'
      two = '2026-11-11T10:00:00.999999Z'
      first = runner.__send__(:check_key!, runner.instance_variable_get(:@operations).fetch('blog.publish_post'), 'k',
                              runner.authorization.validate_input('blog.publish_post', post_id: @post_id, quando: one))
      second = runner.__send__(:check_key!, runner.instance_variable_get(:@operations).fetch('blog.publish_post'), 'k',
                               runner.authorization.validate_input('blog.publish_post', post_id: @post_id, quando: two))
      refute_equal Digest::SHA256.digest(Vetra::Graph::Canonical.dump(JSON.parse(JSON.generate(first)))),
                   Digest::SHA256.digest(Vetra::Graph::Canonical.dump(JSON.parse(JSON.generate(second)))), 'os microssegundos entram no hash'
      assert_equal one, first['quando']
      fraction = runner.run('blog.publish_post', { post_id: @post_id, meta: { 'score' => 1.5 } }, credentials: @identity, idempotency_key: 'k')
      assert_equal [:invalid, 'data_idempotency_input'], [fraction.status, fraction.code]
      assert_empty sqls
      whole = runner.run('blog.publish_post', { post_id: @post_id, meta: { 'n' => 1 } }, credentials: @identity, idempotency_key: 'k')
      assert whole.ok?, whole.diagnostics.map(&:to_s).join
    end
  end

  # ---- resultado em JSON ----------------------------------------------------------------------------------------------------

  def test_the_result_is_serialized_by_the_declared_contract_like_an_event_payload
    crm = build('mini_crm', {}, {}, scoped: true)
    catalog = Vetra::Data::Repositories.new(self.class.linked('mini_crm').document)
    lead = catalog.record_type('crm.lead').new(id: id, company_id: id, name: 'N', email: nil, status: 'won',
                                                valor: Vetra::Data::Money.new(amount: BigDecimal('1.5'), currency: 'BRL'), created_at: @now)
    json = crm.serialize('crm.win_lead', lead)
    assert_equal({ 'amount' => '1.50', 'currency' => 'BRL' }, json['valor'])
    assert_equal @now.getutc.iso8601(6), json['created_at']
    assert_nil json['email']
    assert_equal 'data_idempotency_result', assert_raises(Vetra::Data::Error) { crm.serialize('crm.win_lead', Object.new) }.code
    assert_equal 'data_execution_operation', assert_raises(Vetra::Data::Error) { crm.serialize('crm.nada', lead) }.code

    chat = build('chat', {})
    chat_catalog = Vetra::Data::Repositories.new(self.class.linked('chat').document)
    room = chat_catalog.record_type('chat.room').new(id: id, owner_id: id, name: 'Sala', created_at: @now)
    message = chat_catalog.record_type('chat.message').new(id: id, room_id: room.id, author_id: id, body: 'Oi', created_at: @now)
    page = chat.serialize('chat.room_page', { room: room, messages: [message] })
    assert_equal %w[messages room], page.keys.sort
    assert_equal 'Sala', page['room']['name']
    assert_equal ['Oi'], page['messages'].map { |entry| entry['body'] }
    assert_equal 'data_idempotency_result', assert_raises(Vetra::Data::Error) { chat.serialize('chat.room_page', { room: room, messages: 'não é lista' }) }.code
    assert_equal({ 'score' => 1.5, 'lista' => [1, nil] }, chat.__send__(:json_value, { score: 1.5, lista: [1, nil] }, 'data_idempotency_result'))
    assert_raises(Vetra::Data::Error) { chat.__send__(:json_value, Float::NAN, 'data_idempotency_result') }
  end

  def test_a_value_of_the_wrong_type_is_never_stored_and_the_json_form_serializes_again_unchanged
    runner = blog
    catalog = Vetra::Data::Repositories.new(self.class.linked('blog').document)
    post = catalog.record_type('blog.post').new(**@row)
    json = runner.serialize('blog.publish_post', post)
    assert_equal json, runner.serialize('blog.publish_post', json), 'o JSON de uma repetição passa de novo pelo mesmo serializador'
    assert_equal json, runner.serialize('blog.publish_post', json.transform_keys(&:to_sym))
    bad = lambda do |changes|
      assert_equal 'data_idempotency_result', assert_raises(Vetra::Data::Error) { runner.serialize('blog.publish_post', post.with(**changes)) }.code, changes.inspect
    end
    bad.call(title: { author_email: 'pessoal@audit.invalid' })
    bad.call(title: nil)
    bad.call(status: 'inexistente')
    bad.call(status: :draft)
    bad.call(created_at: 'pessoal@audit.invalid')
    bad.call(author_id: ['x'])
    assert_equal 'data_idempotency_result', assert_raises(Vetra::Data::Error) { runner.serialize('blog.publish_post', json.merge('published_at' => 'pessoal@audit.invalid')) }.code
    assert_equal({ 'post_id' => @post_id }, runner.__send__(:contract_json, 'blog.publish_post.input', { 'post_id' => @post_id, 'extra' => 'fora do contrato' }, 'data_idempotency_input', present_only: true))
  end

  def test_a_collection_output_is_serialized_as_a_list_of_records
    chat = build('chat', {})
    catalog = Vetra::Data::Repositories.new(self.class.linked('chat').document)
    room = catalog.record_type('chat.room').new(id: id, owner_id: id, name: 'Sala', created_at: @now)
    assert_equal [], chat.serialize('chat.my_rooms', [])
    assert_equal ['Sala'], chat.serialize('chat.my_rooms', [room]).map { |entry| entry['name'] }
    list = chat.serialize('chat.my_rooms', [room])
    assert_equal list, chat.serialize('chat.my_rooms', list), 'a lista em JSON passa de novo pelo serializador'
    assert_equal 'data_idempotency_result', assert_raises(Vetra::Data::Error) { chat.serialize('chat.my_rooms', room) }.code
    assert_equal 'data_idempotency_result', assert_raises(Vetra::Data::Error) { chat.serialize('chat.my_rooms', [{ 'name' => 'sem os outros campos' }]) }.code
  end

  def test_scalars_are_checked_by_the_same_rules_as_the_inputs_and_the_canonical_json_comes_back_unchanged
    runner = blog
    field = ->(type, **more) { { 'name' => 'campo', 'nullable' => false, 'required' => true, 'type' => { 'name' => type }.merge(more) } }
    scalar = ->(definition, value) { runner.__send__(:scalar_json, definition, value, 'data_idempotency_result') }
    rejects = lambda do |definition, value|
      assert_equal 'data_idempotency_result', assert_raises(Vetra::Data::Error) { scalar.call(definition, value) }.code, value.inspect
    end
    uuid = id
    assert_equal uuid, scalar.call(field.call('id'), uuid)
    assert_equal uuid, scalar.call(field.call('id'), uuid.upcase), 'o UUID sai na forma canônica, em minúsculas'
    [7, 'pessoal@audit.invalid', ['x']].each { |value| rejects.call(field.call('id'), value) }
    decimal = field.call('decimal', 'precision' => 5, 'scale' => 2)
    assert_equal '123.45', scalar.call(decimal, BigDecimal('123.45'))
    assert_equal '123.45', scalar.call(decimal, '123.45'), 'o texto canônico confere'
    ['1234567.12345', BigDecimal('NaN'), BigDecimal('Infinity'), 'NaN.00', 1.5].each { |value| rejects.call(decimal, value) }
    stamp = field.call('timestamp')
    assert_equal '2026-11-11T10:00:00.000001Z', scalar.call(stamp, '2026-11-11T10:00:00.000001Z')
    ['2026-99-99T99:99:99Z', 'pessoal@audit.invalid', DateTime.new(2026, 11, 11), 1].each { |value| rejects.call(stamp, value) }
    date = field.call('date')
    assert_equal '2026-11-11', scalar.call(date, Date.new(2026, 11, 11))
    ['2026-02-31', DateTime.new(2026, 11, 11, 10), 'amanhã'].each { |value| rejects.call(date, value) }
    money = field.call('money', 'precision' => 12, 'scale' => 2)
    assert_equal({ 'amount' => '1.50', 'currency' => 'BRL' }, scalar.call(money, Vetra::Data::Money.new(amount: BigDecimal('1.5'), currency: 'BRL')))
    assert_equal({ 'amount' => '1.50', 'currency' => 'BRL' }, scalar.call(money, { 'amount' => '1.50', 'currency' => 'BRL' }))
    rejects.call(money, { 'amount' => { 'email' => 'pessoal@audit.invalid' }, 'currency' => 'BRL' })
    rejects.call(field.call('string'), { 'author_email' => 'x' })
    rejects.call(field.call('enum', 'values' => %w[a b]), 'c')
    rejects.call(field.call('integer'), '7')
    rejects.call(field.call('boolean'), 'true')
  end

  def test_a_null_obeys_nullable_and_an_optional_absent_field_is_omitted
    runner = blog
    strict = { 'name' => 'm', 'nullable' => false, 'required' => false, 'type' => { 'name' => 'string' } }
    assert_equal 'data_idempotency_result', assert_raises(Vetra::Data::Error) { runner.__send__(:field_json, strict, nil, 'data_idempotency_result') }.code
    assert_nil runner.__send__(:field_json, strict.merge('nullable' => true), nil, 'data_idempotency_result')
    contract = { 'fields' => [strict, { 'name' => 'obrigatorio', 'nullable' => false, 'required' => true, 'type' => { 'name' => 'string' } }] }
    assert_equal({ 'obrigatorio' => 'x' }, runner.__send__(:contract_item, contract, { 'obrigatorio' => 'x' }, 'data_idempotency_result', false))
    assert_equal 'data_idempotency_result', assert_raises(Vetra::Data::Error) { runner.__send__(:contract_item, contract, {}, 'data_idempotency_result', false) }.code
  end
end

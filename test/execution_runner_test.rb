require_relative 'test_helper'
require 'vetra/execution'
require 'securerandom'

# Runner, borda e provedores de referência (K17, ADR-045), sem banco: dois bancos simulados, o da operação e o da borda,
# para separar as duas contagens de transações.
class ExecutionRunnerTest < GraphTest
  def self.linked(example)
    (@linked ||= {})[example] ||= Vetra::Graph::Compiler.new(root: File.join(PROJECT, 'examples', example)).link
  end

  def setup
    @linked = self.class.linked('blog')
    @actor = SecureRandom.uuid
    @post_id = SecureRandom.uuid
    @row = { id: @post_id, title: 'Título', author_id: @actor, status: 'draft', published_at: nil, created_at: Time.now.utc.floor(6) }
    @ops_rows = -> { [@row] }
    @facts_rows = -> { [@row] }
    @ops_db = mock_db { @ops_rows.call }
    @facts_db = mock_db { @facts_rows.call }
    @catalog = Vetra::Data::Repositories.new(@linked.document)
    @authority = Vetra::Execution::InProcessAuthority.new
    @facts = Vetra::Execution::DatabaseFacts.new(
      catalog: @catalog, authority: @authority, unit: Vetra::Data::UnitOfWork.new(@facts_db, scope: :global, limits: false)
    )
    @identity = Vetra::Execution::Identity.new(actor_id: @actor, roles: ['blog.autor'])
    @edge = Vetra::Execution::Edge.new(identity: ->(credentials) { credentials }, facts: @facts, authority: @authority)
    @runner = Vetra::Execution::Runner.new(
      linked: @linked, catalog: @catalog, edge: @edge,
      unit: Vetra::Data::UnitOfWork.new(@ops_db, scope: :global, limits: false)
    )
  end

  def mock_db(&rows)
    Sequel.mock(host: :postgres).tap do |db|
      db.fetch = ->(sql) { sql.include?('set_config') ? [] : rows.call }
    end
  end

  def run_as(identity, operation, input = {})
    @runner.run(operation, input, credentials: identity)
  end

  def visitor = Vetra::Execution::Identity.new

  # Sequel.mock#sqls devolve e zera a lista: acumula por banco para conferir mais de uma vez.
  def ops_sqls = (@ops_seen ||= []).concat(@ops_db.sqls)
  def facts_sqls = (@facts_seen ||= []).concat(@facts_db.sqls)

  # Linha publicada, com data de publicação.
  def publish_row!
    @row[:status] = 'published'
    @row[:published_at] = Time.now.utc.floor(6)
  end

  def test_the_author_reads_a_post_and_the_two_transaction_counts_are_separate
    publish_row!
    outcome = run_as(@identity, 'blog.find_post', post_id: @post_id)
    assert outcome.ok?, outcome.diagnostics.map(&:to_s).join
    assert_equal @post_id, outcome.value.id
    assert_equal 1, ops_sqls.count('BEGIN'), 'a operação abre uma transação'
    assert_equal 1, facts_sqls.count('BEGIN'), 'a borda lê os fatos na sua própria transação, que não é zero'
    refute_includes ops_sqls.join, 'set_config', 'o escopo global não instala contexto'
  end

  def test_denial_opens_no_transaction_of_the_operation_but_the_edge_still_reads
    outcome = run_as(visitor, 'blog.publish_post', post_id: @post_id)
    refute outcome.ok?
    assert_equal :denied, outcome.status
    assert_equal 'data_authorization_denied', outcome.code
    assert_empty ops_sqls, 'recusa nas etapas 1 a 3 não toca o pool da operação'
    assert_equal 1, facts_sqls.count('BEGIN')
    assert_equal 0, @authority.call, 'recusa não publica geração'
  end

  def test_a_visitor_reads_nothing_because_the_author_scope_also_binds_the_visitor_policy
    outcome = run_as(visitor, 'blog.find_post', post_id: @post_id)
    assert_equal :denied, outcome.status
    assert_empty ops_sqls
  end

  def test_invalid_input_is_refused_in_step_two_before_the_edge_reads_anything
    outcome = run_as(@identity, 'blog.find_post', post_id: 'não é uuid')
    assert_equal :invalid, outcome.status
    refute_empty outcome.diagnostics
    assert_empty ops_sqls
    assert_empty facts_sqls
    assert_equal :invalid, run_as(@identity, 'blog.find_post', post_id: @post_id, extra: 1).status
  end

  def test_an_unresolved_identity_is_refused_without_the_edge_exception
    edge = Vetra::Execution::Edge.new(identity: ->(_) { raise 'segredo-do-provedor' }, facts: @facts, authority: @authority)
    runner = Vetra::Execution::Runner.new(linked: @linked, catalog: @catalog, edge: edge,
                                          unit: Vetra::Data::UnitOfWork.new(@ops_db, scope: :global, limits: false))
    outcome = runner.run('blog.find_post', { post_id: @post_id }, credentials: 'x')
    assert_equal :unresolved, outcome.status
    assert_equal 'execution_identity', outcome.code
    refute_includes outcome.diagnostics.map(&:message).join, 'segredo'
    nested = lambda do |_|
      begin
        raise 'segredo-interno'
      rescue StandardError
        raise Vetra::Data::Error.single('data_context', 'x')
      end
    end
    leaked = assert_raises(Vetra::Data::Error) do
      Vetra::Execution::Edge.new(identity: nested, facts: @facts, authority: @authority).resolve(nil)
    end
    assert_equal 'execution_identity', leaked.code
    assert_nil leaked.cause
    [->(_) { :not_an_identity }, nested].each do |resolver|
      edge = Vetra::Execution::Edge.new(identity: resolver, facts: @facts, authority: @authority)
      other = Vetra::Execution::Runner.new(linked: @linked, catalog: @catalog, edge: edge,
                                           unit: Vetra::Data::UnitOfWork.new(@ops_db, scope: :global, limits: false))
      assert_equal :unresolved, other.run('blog.find_post', { post_id: @post_id }, credentials: nil).status
    end
    assert_empty ops_sqls
  end

  def test_a_context_the_application_cannot_build_is_denied
    tenant_identity = Vetra::Execution::Identity.new(tenant_id: SecureRandom.uuid, actor_id: @actor, roles: ['blog.autor'])
    assert_equal :denied, run_as(tenant_identity, 'blog.find_post', post_id: @post_id).status
    assert_equal :denied, run_as(Vetra::Execution::Identity.new(actor_id: 'x'), 'blog.find_post', post_id: @post_id).status
  end

  def test_an_unknown_operation_is_a_programming_error_not_an_outcome
    error = assert_raises(Vetra::Data::Error) { run_as(@identity, 'blog.inexistente') }
    assert_equal 'data_execution_operation', error.code
  end

  def test_a_stale_or_failing_authority_refuses_without_transporting_the_exception
    flips = 0
    authority = Class.new do
      define_method(:call) do |_context|
        flips += 1
        flips == 1 ? 1 : 2 # o marcador muda entre a leitura dos fatos e a admissão
      end
    end.new
    facts = Vetra::Execution::DatabaseFacts.new(catalog: @catalog, authority: authority,
                                                unit: Vetra::Data::UnitOfWork.new(@facts_db, scope: :global, limits: false))
    edge = Vetra::Execution::Edge.new(identity: ->(c) { c }, facts: facts, authority: authority)
    runner = Vetra::Execution::Runner.new(linked: @linked, catalog: @catalog, edge: edge,
                                          unit: Vetra::Data::UnitOfWork.new(@ops_db, scope: :global, limits: false))
    outcome = runner.run('blog.find_post', { post_id: @post_id }, credentials: @identity)
    assert_equal :denied, outcome.status
    assert_equal 'data_authorization_snapshot', outcome.code
    assert_empty ops_sqls

    broken = Class.new { def call(_) = raise('segredo-da-autoridade') }.new
    edge = Vetra::Execution::Edge.new(identity: ->(c) { c }, facts: facts, authority: broken)
    runner = Vetra::Execution::Runner.new(linked: @linked, catalog: @catalog, edge: edge,
                                          unit: Vetra::Data::UnitOfWork.new(@ops_db, scope: :global, limits: false))
    outcome = runner.run('blog.find_post', { post_id: @post_id }, credentials: @identity)
    assert_equal 'data_authorization_snapshot', outcome.code
    refute_includes outcome.diagnostics.map(&:message).join, 'segredo'
  end

  def test_a_failing_facts_provider_is_refused_with_its_data_code_or_a_generic_one
    sanitized = Vetra::Execution::Edge.new(identity: ->(c) { c }, facts: ->(_) { raise 'segredo-do-provedor' }, authority: @authority)
    runner = Vetra::Execution::Runner.new(linked: @linked, catalog: @catalog, edge: sanitized,
                                          unit: Vetra::Data::UnitOfWork.new(@ops_db, scope: :global, limits: false))
    outcome = runner.run('blog.find_post', { post_id: @post_id }, credentials: @identity)
    assert_equal 'data_authorization_snapshot', outcome.code
    refute_includes outcome.diagnostics.map(&:message).join, 'segredo'
    data = Vetra::Execution::Edge.new(identity: ->(c) { c }, facts: ->(_) { raise Vetra::Data::Error.single('data_access_denied', 'x') },
                                      authority: @authority)
    runner = Vetra::Execution::Runner.new(linked: @linked, catalog: @catalog, edge: data,
                                          unit: Vetra::Data::UnitOfWork.new(@ops_db, scope: :global, limits: false))
    assert_equal 'data_access_denied', runner.run('blog.find_post', { post_id: @post_id }, credentials: @identity).code
  end

  def test_the_author_publishes_a_draft_and_the_authority_publishes_a_new_generation_after_the_commit
    before = @authority.call
    outcome = run_as(@identity, 'blog.publish_post', post_id: @post_id)
    assert outcome.ok?, outcome.diagnostics.map(&:to_s).join
    assert_equal @post_id, outcome.value.id
    assert_equal %w[BEGIN COMMIT], [ops_sqls.first, ops_sqls.last]
    assert_equal before + 1, @authority.call, 'o comando grava uma entidade lida pela política'
  end

  def test_a_query_never_publishes_a_generation
    publish_row!
    before = @authority.call
    assert run_as(@identity, 'blog.find_post', post_id: @post_id).ok?
    assert_equal before, @authority.call
  end

  def test_fail_rolls_back_everything_and_still_publishes_because_the_commit_outcome_is_not_assumed
    @ops_rows = -> { [@row.merge(status: 'published')] }
    before = @authority.call
    error = assert_raises(Vetra::Execution::Failure) { run_as(@identity, 'blog.publish_post', post_id: @post_id) }
    assert_equal 'status', error.field
    assert_equal 'execution_failure', error.code
    refute_includes error.diagnostics.map(&:message).join, error.reason
    assert_includes ops_sqls, 'ROLLBACK'
    refute_includes ops_sqls, 'COMMIT'
    assert_equal before + 1, @authority.call
  end

  # Autoridade em memória cuja publicação pode falhar, para provar que a falha de publicar não escapa nem deixa fatos velhos válidos.
  class FlakyAuthority < Vetra::Execution::InProcessAuthority
    attr_accessor :failing

    def publish!(context = nil)
      raise 'segredo-da-publicacao' if failing
      super
    end
  end

  def flaky_runner
    authority = FlakyAuthority.new
    facts = Vetra::Execution::DatabaseFacts.new(catalog: @catalog, authority: authority,
                                                unit: Vetra::Data::UnitOfWork.new(@facts_db, scope: :global, limits: false))
    edge = Vetra::Execution::Edge.new(identity: ->(c) { c }, facts: facts, authority: authority)
    runner = Vetra::Execution::Runner.new(linked: @linked, catalog: @catalog, edge: edge,
                                          unit: Vetra::Data::UnitOfWork.new(@ops_db, scope: :global, limits: false))
    [runner, edge, authority]
  end

  def test_a_failed_publication_neither_escapes_nor_leaves_old_facts_valid_and_a_later_publication_recovers
    runner, edge, authority = flaky_runner
    authority.failing = true
    context = Vetra::Data::Context.new(scope: :global, tenant_id: nil, actor_id: @actor, op_id: SecureRandom.uuid, cmd: 'blog.find_post')
    request = Vetra::Execution::FactsRequest.new(authorization: runner.authorization, operation_id: 'blog.find_post', context: context,
                                                roles: ['blog.autor'], input: { 'post_id' => @post_id })
    old = edge.snapshot(request)
    outcome = runner.run('blog.publish_post', { post_id: @post_id }, credentials: @identity)
    assert outcome.ok?, 'o commit já aconteceu: a falha de publicar não vira erro da operação'
    assert_includes ops_sqls, 'COMMIT'
    refute edge.available?
    stale = runner.authorization.check('blog.find_post', input: { post_id: @post_id }, context: context, snapshot: old, current_revision: edge.authority)
    assert_equal 'data_authorization_snapshot', stale.code
    assert_equal 'data_authorization_snapshot', runner.run('blog.find_post', { post_id: @post_id }, credentials: @identity).code
    refute edge.publish!(nil), 'a nova tentativa também falha: continua indisponível'
    authority.failing = false
    assert edge.publish!(nil)
    assert edge.available?
    assert runner.run('blog.find_post', { post_id: @post_id }, credentials: @identity).ok?
  end

  def test_a_slow_publication_started_before_a_failure_cannot_reopen_the_guard
    authority = Class.new(Vetra::Execution::InProcessAuthority) do
      def publish!(context = nil)
        plan = Thread.current[:plan]
        raise 'segredo-da-publicacao' if plan == :fail
        super
        return unless plan == :hold
        Thread.current[:entered].push(true)
        Thread.current[:release].pop
      end
    end.new
    edge = Vetra::Execution::Edge.new(identity: ->(c) { c }, facts: ->(_) {}, authority: authority)
    entered, release = Queue.new, Queue.new
    slow = Thread.new do
      Thread.current[:plan], Thread.current[:entered], Thread.current[:release] = :hold, entered, release
      edge.publish!(nil)
    end
    entered.pop # a publicação lenta já incrementou a geração e está suspensa
    Thread.new { Thread.current[:plan] = :fail; edge.publish!(nil) }.join
    release.push(true)
    assert slow.value
    refute edge.available?, 'a publicação iniciada antes da falha não reabre a confirmação'
    assert_equal 'data_authorization_snapshot', assert_raises(Vetra::Data::Error) { edge.authority.call(nil) }.code
    assert edge.publish!(nil), 'uma publicação iniciada depois da falha reabre'
    assert edge.available?
  end

  def test_a_failed_publication_does_not_mask_the_business_failure
    runner, edge, authority = flaky_runner
    authority.failing = true
    @ops_rows = -> { [@row.merge(status: 'published')] }
    error = assert_raises(Vetra::Execution::Failure) { runner.run('blog.publish_post', { post_id: @post_id }, credentials: @identity) }
    assert_nil error.cause
    refute edge.available?
  end

  def test_a_driver_error_at_commit_is_translated_without_message_or_cause
    failing = Class.new(Vetra::Data::UnitOfWork) do
      def transaction(**)
        raise Sequel::DatabaseError, 'segredo-do-driver SELECT senha'
      end
    end
    runner = Vetra::Execution::Runner.new(linked: @linked, catalog: @catalog, edge: @edge,
                                          unit: failing.new(@ops_db, scope: :global, limits: false))
    error = assert_raises(Vetra::Data::Error) { runner.run('blog.update_post', { id: @post_id, title: 'Outro' }, credentials: @identity) }
    assert_equal 'data_database', error.code
    assert_nil error.cause
    refute_includes error.full_message, 'segredo'
  end

  def test_crud_create_runs_the_primitive_with_the_authorized_input
    outcome = run_as(@identity, 'blog.create_post', title: 'Novo')
    assert outcome.ok?, outcome.diagnostics.map(&:to_s).join
    assert_equal @post_id, outcome.value.id
    assert(ops_sqls.any? { |sql| sql.start_with?(%q(INSERT INTO "public"."posts")) })
  end

  def test_crud_read_update_and_delete_primitives
    read = run_as(@identity, 'blog.read_post', id: @post_id)
    assert read.ok?, read.diagnostics.map(&:to_s).join
    updated = run_as(@identity, 'blog.update_post', id: @post_id, title: 'Outro')
    assert updated.ok?, updated.diagnostics.map(&:to_s).join
    assert(ops_sqls.any? { |sql| sql.start_with?(%q(UPDATE "public"."posts")) })
    deleted = run_as(@identity, 'blog.delete_post', id: @post_id)
    assert deleted.ok?, deleted.diagnostics.map(&:to_s).join
    assert(ops_sqls.any? { |sql| sql.start_with?(%q(DELETE FROM "public"."posts")) })
  end

  def test_relation_primitive_calls_the_generated_repository_method
    chat = self.class.linked('chat')
    runner = Vetra::Execution::Runner.new(linked: chat, catalog: Vetra::Data::Repositories.new(chat.document), edge: @edge,
                                          unit: Vetra::Data::UnitOfWork.new(@ops_db, scope: :global, limits: false))
    calls = []
    repository = Object.new
    repository.define_singleton_method(:add_member!) { |owner, target| calls << [owner, target] }
    operation = { 'authorize' => { 'entity' => { 'id' => 'chat.room' } } }
    runner.__send__(:link, operation, 'many_to_many.add.members', repository, { 'room_id' => 'a', 'user_id' => 'b' })
    assert_equal [%w[a b]], calls
    error = assert_raises(Vetra::Data::Error) { runner.__send__(:link, operation, 'many_to_many.add.inexistente', repository, {}) }
    assert_equal 'execution_capability', error.code
  end

  def test_a_capability_without_an_executor_is_refused
    with_app('blog') do |root, compiler|
      edit(root, 'app/domains/blog/find_post.rb') { |text| text.sub('uses :posts', 'uses :posts, :uuid').sub('|input, posts|', '|input, posts, uuid|') }
      compiler.write
      linked = compiler.link
      runner = Vetra::Execution::Runner.new(linked: linked, catalog: Vetra::Data::Repositories.new(linked.document), edge: @edge,
                                            unit: Vetra::Data::UnitOfWork.new(@ops_db, scope: :global, limits: false))
      publish_row!
      error = assert_raises(Vetra::Data::Error) { runner.run('blog.find_post', { post_id: @post_id }, credentials: @identity) }
      assert_equal 'execution_capability', error.code
      assert_includes ops_sqls, 'ROLLBACK'
    end
  end

  def test_the_clock_capability_is_the_unit_instant
    unit = Vetra::Data::UnitOfWork.new(@ops_db, scope: :global, limits: false)
    unit.transaction(actor_id: @actor, op_id: SecureRandom.uuid, cmd: 'blog.publish_post') do |active|
      clock = @runner.__send__(:capability, 'blog.clock', active)
      assert_equal active.now, clock.now
      assert_equal '#<Vetra::Execution::OperationClock>', clock.inspect
    end
  end

  def test_optional_input_absent_reaches_the_call_as_nil_and_the_host_only_offers_fail
    host = Vetra::Execution::CallHost.new
    assert_equal [:fail!], host.public_methods(false)
    error = assert_raises(Vetra::Execution::Failure) { host.fail!(:status) }
    assert_equal 'status', error.field
    assert_equal '', error.reason
  end

  def test_edge_and_runner_refuse_malformed_collaborators
    assert_equal 'execution_edge', assert_raises(Vetra::Data::Error) { Vetra::Execution::Edge.new(identity: 1, facts: @facts, authority: @authority) }.code
    assert_equal 'execution_runner', assert_raises(Vetra::Data::Error) {
      Vetra::Execution::Runner.new(linked: {}, catalog: @catalog, edge: @edge, unit: nil)
    }.code
    assert_equal 'execution_edge', assert_raises(Vetra::Data::Error) {
      Vetra::Execution::DatabaseFacts.new(catalog: nil, authority: @authority, unit: nil)
    }.code
    assert @edge.publishes?
    assert_equal '#<Vetra::Execution::Identity [REDACTED]>', @identity.inspect
    assert_equal '#<Vetra::Execution::Runner>', @runner.inspect
    publish_row!
    assert_equal '#<Vetra::Execution::Runner::Outcome status=ok>', run_as(@identity, 'blog.find_post', post_id: @post_id).inspect
    assert_equal '#<Vetra::Execution::InProcessAuthority>', @authority.inspect
    assert_equal '#<Vetra::Execution::DatabaseFacts>', @facts.inspect
  end

  def test_facts_over_the_row_limit_are_refused_instead_of_truncated
    @facts_rows = -> { [@row, @row.merge(id: SecureRandom.uuid)] }
    facts = Vetra::Execution::DatabaseFacts.new(catalog: @catalog, authority: @authority, limit: 1,
                                                unit: Vetra::Data::UnitOfWork.new(@facts_db, scope: :global, limits: false))
    edge = Vetra::Execution::Edge.new(identity: ->(c) { c }, facts: facts, authority: @authority)
    runner = Vetra::Execution::Runner.new(linked: @linked, catalog: @catalog, edge: edge,
                                          unit: Vetra::Data::UnitOfWork.new(@ops_db, scope: :global, limits: false))
    publish_row!
    assert_equal 'data_authorization_snapshot', runner.run('blog.find_post', { post_id: @post_id }, credentials: visitor).code
  end

  def test_database_authority_reads_one_composite_marker_and_refuses_a_missing_tenant
    revision = { revision: 7 }
    db = Sequel.mock(host: :postgres)
    db.fetch = ->(_sql) { revision ? [revision] : [] }
    generation = Vetra::Execution::InProcessAuthority.new
    authority = Vetra::Execution::DatabaseAuthority.new(db: db, identity_generation: generation)
    context = Vetra::Data::Context.new(scope: :tenant, tenant_id: SecureRandom.uuid, actor_id: @actor, op_id: SecureRandom.uuid, cmd: 'crm.win_lead')
    assert_equal [7, 0], authority.call(context)
    statements = db.sqls
    assert_equal 1, statements.size, 'uma só instrução'
    refute_includes statements.first, 'BEGIN'
    authority.identity_changed!
    assert_equal [7, 1], authority.call(context)
    revision = nil
    assert_equal 'data_authorization_snapshot', assert_raises(Vetra::Data::Error) { authority.call(context) }.code
    assert_equal 'data_connection', assert_raises(Vetra::Data::Error) { Vetra::Execution::DatabaseAuthority.new(db: Object.new) }.code
    assert_equal 'execution_edge', assert_raises(Vetra::Data::Error) { Vetra::Execution::DatabaseAuthority.new(db: db, identity_generation: 1) }.code
    assert_equal '#<Vetra::Execution::DatabaseAuthority>', authority.inspect
    refute authority.respond_to?(:publish!), 'a revisão dos CRMs sobe por trigger, não por publicação'
  end

  def test_fact_plan_and_policy_entities_come_from_the_ir
    crm = Vetra::Execution::Authorization.new(self.class.linked('mini_crm_revendas').document)
    assert_equal %w[crm.dealer crm.lead crm.membership], crm.policy_entities & %w[crm.dealer crm.lead crm.membership]
    plan = crm.fact_plan('crm.update_lead', ['crm.gerente'])
    assert_equal 'crm.lead', plan[:principal]
    assert_equal 'id', plan[:record]
    assert_includes plan[:entities], 'crm.membership'
    assert_nil crm.fact_plan('crm.create_lead', [])[:principal]
    assert_equal :tenant, crm.scope
    assert_includes crm.operation_ids, 'crm.win_lead'
    blog = Vetra::Execution::Authorization.new(@linked.document)
    assert_equal :global, blog.scope
    assert_equal [], blog.fact_plan('blog.find_post', [])[:entities]
  end
end

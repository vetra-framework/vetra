require_relative 'test_helper'
require 'vetra/http'
require 'securerandom'
require 'digest'

# A admissão é da borda; guardas, linhas e tentativas internas não consultam contadores.
class ExecutionRateLimitTest < GraphTest
  def self.linked
    @linked ||= Vetra::Graph::Compiler.new(root: File.join(PROJECT, 'examples/blog')).link
  end

  def setup
    @linked = self.class.linked
    @actor, @post = SecureRandom.uuid, SecureRandom.uuid
    @now = Time.now.utc.floor(6)
    @row = { id: SecureRandom.uuid, post_id: @post, author_name: 'Visitante', author_email: 'v@example.test',
             body: 'Olá', approved: false, created_at: @now }
    @input = @row.slice(:post_id, :author_name, :author_email, :body)
    @visitor = Vetra::Execution::Identity.new(actor_id: @actor)
    @wait = 0
    @counter_calls = []
    @executions = 0
    @counter = lambda do |context, policies|
      @counter_calls << [context, policies]
      raise @wait if @wait.is_a?(Exception)
      @wait
    end
    @ops = Sequel.mock(host: :postgres)
    @ops.numrows = 1
    @ops.fetch = lambda do |sql|
      if sql.include?('INSERT INTO "public"."comments"')
        @executions += 1
        raise Sequel::SerializationFailure, 'segredo' if @serialize_once && @executions == 1
      end
      [@row]
    end
  end

  def runner(counter: @counter, linked: @linked)
    catalog = Vetra::Data::Repositories.new(linked.document)
    authority = Vetra::Execution::InProcessAuthority.new
    facts = ->(request) { request.authorization.snapshot(context: request.context, roles: request.roles, revision: authority.call(request.context), records: {}) }
    edge = Vetra::Execution::Edge.new(identity: ->(identity) { identity }, facts: facts, authority: authority, rate_limit: counter)
    Vetra::Execution::Runner.new(linked: linked, catalog: catalog, edge: edge,
                                 unit: Vetra::Data::UnitOfWork.new(@ops, scope: :global, limits: false), sleeper: ->(_) {})
  end

  def run_comment(subject = runner, identity: @visitor)
    subject.run('blog.create_comment', @input, credentials: identity)
  end

  def test_limited_admission_precedes_the_unit_and_guard_and_final_state_do_not_charge
    @counter = ->(context, policies) do
      assert_empty @ops.sqls, 'a reserva precede a abertura da unidade'
      @counter_calls << [context, policies]
      0
    end
    outcome = run_comment
    assert outcome.ok?, outcome.diagnostics.map(&:to_s).join
    assert_equal 1, @counter_calls.size
    context, policies = @counter_calls.first
    assert_equal @actor, context.actor_id
    assert_nil context.tenant_id
    assert_equal [{ 'id' => 'blog.visitor.permission_3', 'limit' => 5, 'window_seconds' => 60 }], policies
    assert_equal 1, @ops.sqls.count('COMMIT')
  end

  def test_unlimited_grant_and_denied_authorization_never_consult_counters
    admin = Vetra::Execution::Identity.new(actor_id: @actor, roles: ['blog.admin'])
    assert run_comment(identity: admin).ok?
    result = runner.run('blog.create_post', { title: 'Não autorizado' }, credentials: @visitor)
    assert_equal 'data_authorization_denied', result.code
    assert_empty @counter_calls
  end

  def test_excess_produces_429_and_the_database_wait_without_opening_the_unit
    @wait = 17
    outcome = run_comment
    assert_equal :rate_limited, outcome.status
    assert_equal 'data_rate_limit_exceeded', outcome.code
    assert_equal 429, outcome.http_status
    assert_equal 17, outcome.retry_after
    assert outcome.retryable?
    assert_empty @ops.sqls
  end

  def test_counter_failure_is_retryable_unavailable_and_never_admits
    [RuntimeError.new('credencial secreta'), nil, -1].each do |value|
      @wait = value
      outcome = run_comment
      assert_equal :denied, outcome.status
      assert_equal 'data_rate_limit_unavailable', outcome.code
      assert outcome.retryable?
      refute_includes outcome.diagnostics.map(&:message).join, 'secreta'
    end
    assert_equal 'data_rate_limit_unavailable', run_comment(runner(counter: nil)).code
    assert_empty @ops.sqls
  end

  def test_visitor_without_trusted_actor_is_refused_before_consulting_counter
    outcome = run_comment(identity: Vetra::Execution::Identity.new)
    assert_equal :denied, outcome.status
    assert_equal 'data_authorization_context', outcome.code
    assert_empty @counter_calls
    assert_empty @ops.sqls
  end

  def test_internal_serialization_and_deadlock_retries_charge_only_once
    wrapped = Struct.new(:state) do
      def result = self
      def error_field(_) = state
    end.new('40P01')
    deadlock = Sequel::DatabaseError.new('segredo')
    deadlock.wrapped_exception = wrapped
    [Sequel::SerializationFailure.new('segredo'), deadlock].each do |failure|
      @counter_calls.clear
      @executions = 0
      @ops.fetch = lambda do |sql|
        if sql.include?('INSERT INTO "public"."comments"')
          @executions += 1
          raise failure if @executions == 1
        end
        [@row]
      end
      outcome = run_comment
      assert outcome.ok?, outcome.diagnostics.map(&:to_s).join
      assert_equal 2, outcome.attempts
      assert_equal 1, @counter_calls.size
    end
  end

  def test_two_visitors_reach_the_counter_with_distinct_trusted_identities
    subject = runner
    assert run_comment(subject).ok?
    second = Vetra::Execution::Identity.new(actor_id: SecureRandom.uuid)
    assert run_comment(subject, identity: second).ok?
    assert_equal [@actor, second.actor_id], @counter_calls.map { |context, _| context.actor_id }
  end

  def test_failure_after_admission_does_not_reserve_again_or_refund
    @ops.fetch = ->(_) { raise Sequel::DatabaseError, 'falha depois' }
    outcome = run_comment
    refute outcome.ok?
    assert_equal 1, @counter_calls.size
    assert_includes @ops.sqls, 'ROLLBACK'
  end

  def test_all_limited_policies_are_returned_together_including_distinct_windows
    document = Vetra::Graph::Data.copy(@linked.document)
    original = document['nodes'].find { |node| node['rate_limit'] }
    additional = Vetra::Graph::Data.copy(original)
    additional['id'] = 'blog.visitor.permission_extra'
    additional['rate_limit'] = { 'limit' => 8, 'window_seconds' => 120, 'key' => 'actor_tenant' }
    document['nodes'] << additional
    document.delete('digest')
    document['digest'] = Vetra::Graph::Canonical.digest(document)
    authorization = Vetra::Execution::Authorization.new(document)
    context = Vetra::Data::Context.new(scope: :global, tenant_id: nil, actor_id: @actor, op_id: SecureRandom.uuid, cmd: 'blog.create_comment')
    snapshot = authorization.snapshot(context: context, roles: [], revision: 0, records: {})
    decision = authorization.check('blog.create_comment', input: @input, context: context, snapshot: snapshot, current_revision: ->(_) { 0 })
    assert decision.allowed?, decision.diagnostics.map(&:to_s).join
    assert_equal [original['id'], additional['id']], decision.rate_limits.map { |policy| policy['id'] }
    assert_equal [60, 120], decision.rate_limits.map { |policy| policy['window_seconds'] }
  end

  def test_client_repetition_with_same_idempotency_key_charges_again_even_on_replay
    with_app do |root, compiler|
      edit(root, 'app/domains/blog/roles.rb') { |text| text.sub('on: :post, scope: :author', 'on: :post, scope: :author, rate_limit: "5/min"') }
      compiler.write
      linked = compiler.link
      row = { id: @post, title: 'Título', author_id: @actor, status: 'draft', published_at: nil, created_at: @now }
      stored = nil
      hash = Digest::SHA256.digest(Vetra::Graph::Canonical.dump('title' => 'Título'))
      @ops.fetch = lambda do |sql|
        if sql.include?('INSERT INTO "vetra"."idempotency"')
          stored ? [] : [{ id: 1 }]
        elsif sql.include?('FROM "vetra"."idempotency"')
          [{ id: 1, principal: @actor, input_hash: hash, result_text: JSON.generate(stored) }]
        else
          [row]
        end
      end
      subject = runner(linked: linked)
      identity = Vetra::Execution::Identity.new(actor_id: @actor, roles: ['blog.autor'])
      first = subject.run('blog.create_post', { title: 'Título' }, credentials: identity, idempotency_key: 'mesma-chave')
      assert first.ok?, first.diagnostics.map(&:to_s).join
      stored = subject.serialize('blog.create_post', first.value)
      second = subject.run('blog.create_post', { title: 'Título' }, credentials: identity, idempotency_key: 'mesma-chave')
      assert second.ok?, second.diagnostics.map(&:to_s).join
      assert second.replayed?
      assert_equal 2, @counter_calls.size
    end
  end
end

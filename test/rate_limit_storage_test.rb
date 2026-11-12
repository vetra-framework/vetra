require_relative 'test_helper'
require 'vetra/execution'
require 'securerandom'

class RateLimitStorageTest < GraphTest
  def document(example = 'blog')
    Vetra::Graph::Compiler.new(root: File.join(PROJECT, 'examples', example)).read_artifact.document
  end

  def schema(example = 'blog') = Vetra::SQL::Schema.new(document(example)).generate
  def storage = Vetra::SQL::RateLimit.new(schema)

  def setup
    @db = Sequel.mock(host: :postgres)
    @db.fetch = ->(sql) { sql.include?('reserve_rate_limit') ? [{ wait: 0 }] : [] }
    @issuer = Vetra::Data::ContextIssuer.new(kid: 'teste', secret: SecureRandom.random_bytes(32))
    @context = Vetra::Data::Context.new(scope: :global, tenant_id: nil, actor_id: SecureRandom.uuid,
                                        op_id: SecureRandom.uuid, cmd: 'blog.create_comment')
    @policies = [{ 'id' => 'blog.visitor.permission_3', 'limit' => 5, 'window_seconds' => 60 }]
  end

  def limiter(db = @db) = Vetra::Data::RateLimit.new(db: db, issuer: @issuer, document: document)

  def test_only_graphs_requiring_rate_limit_gain_the_section_and_no_graph_changes
    assert Vetra::SQL::RateLimit.needed?(document)
    %w[chat mini_crm mini_crm_revendas].each do |example|
      assert_empty Vetra::SQL::RateLimit.new(schema(example)).statements
    end
    statements = storage.statements
    assert_includes statements, 'ALTER TABLE "vetra"."rate_limit" FORCE ROW LEVEL SECURITY;'
    assert_includes statements, 'REVOKE ALL ON TABLE "vetra"."rate_limit" FROM PUBLIC, "vetra_app", "vetra_relay";'
    assert_includes statements, 'GRANT SELECT, DELETE ON TABLE "vetra"."rate_limit" TO "vetra_relay";'
    grants = statements.grep(/\AGRANT/).join("\n")
    refute_match(/ON TABLE .* TO "vetra_app"/, grants)
    assert_includes grants, 'GRANT EXECUTE ON FUNCTION "vetra"."reserve_rate_limit"(text) TO "vetra_app";'
    assert_includes Vetra::SQL::RateLimit.body, 'pg_catalog.clock_timestamp()'
    assert_includes Vetra::SQL::RateLimit.body, 'pg_catalog.pg_advisory_xact_lock(lock_key)'
    assert_empty storage.digests & Vetra::SQL::Idempotency.new(schema).digests
  end

  def test_incremental_plan_is_the_whole_section_and_an_immutable_section_is_guarded
    root = File.join(PROJECT, 'examples/blog')
    base = Vetra::SQL::Model.new(file: '0004_expand.json', text: File.read("#{root}/db/models/0004_expand.json"))
    plan = Vetra::SQL::Differ.call(base: base, schema: schema, number: '0005')
    assert_equal File.read("#{root}/db/plans/0005_expand.sql"), plan.render
    assert_equal [storage.statements.join("\n")], plan.steps.map(&:sql)
    assert_equal ['sim'], plan.steps.map(&:transaction)
    latest = Vetra::SQL::Model.new(file: '0005_expand.json', text: File.read("#{root}/db/models/0005_expand.json"))
    %w[vetra.rate_limit vetra.reserve_rate_limit(text) vetra_rate_limit_routines].each do |object|
      altered = Vetra::Graph::Data.copy(latest.document)
      altered['state']['statements'].find { |item| item['object'] == object }['sha256'] = '0' * 64
      model = Vetra::SQL::Model.new(file: latest.file, text: Vetra::SQL::Model.render(altered))
      assert_graph_error('db_plan_statement') { Vetra::SQL::Differ.call(base: model, schema: schema, number: '0006') }
    end
  end

  def test_tenant_routine_guards_recognize_only_the_exact_closed_reservation
    doc = Vetra::Graph::Data.copy(document('mini_crm'))
    doc['requires'] = (doc['requires'] | ['vetra.rate_limit']).sort
    doc['digest'] = Vetra::Graph::Canonical.digest(doc)
    sql = Vetra::SQL::Authorization.new(doc).generate.sql
    assert_includes sql, Vetra::SQL::RateLimit.trusted_routine_sql
    assert_includes sql, "p.proargtypes = '25'::pg_catalog.oidvector"
    assert_includes sql, Digest::SHA256.hexdigest(Vetra::SQL::RateLimit.body)
  end

  def test_reservation_has_short_timeouts_separate_commit_and_no_clock_from_ruby
    assert_equal 0, limiter.call(@context, @policies)
    sql = @db.sqls
    assert_includes sql, 'COMMIT'
    assert_includes sql.join, 'statement_timeout'
    assert_includes sql.join, '2000'
    assert_includes sql.join, 'lock_timeout'
    token = @issuer.issue_rate_limit(context: @context, namespace: 'blog', policies: @policies).value
    assert token.start_with?('r1.')
    payload = JSON.parse((token.split('.')[2].tr('-_', '+/') + '=' * ((4 - token.split('.')[2].size % 4) % 4)).unpack1('m0'))
    assert_equal @context.actor_id, payload['actor_id']
    assert_nil payload['tenant_id']
    assert_equal @policies, payload['policies']
    refute payload.key?('admitted_at')
  end

  def test_database_failure_timeout_invalid_result_and_open_transaction_all_fail_closed
    [nil, -2, '1', Sequel::DatabaseError.new('segredo')].each do |result|
      @db.fetch = lambda do |sql|
        next [] unless sql.include?('reserve_rate_limit')
        raise result if result.is_a?(Exception)
        [{ wait: result }]
      end
      error = assert_raises(Vetra::Data::Error) { limiter.call(@context, @policies) }
      assert_equal 'data_rate_limit_unavailable', error.code
      assert_nil error.cause
      refute_includes error.message, 'segredo'
    end
    @db.transaction do
      error = assert_raises(Vetra::Data::Error) { limiter.call(@context, @policies) }
      assert_equal 'data_rate_limit_unavailable', error.code
    end
  end

  def test_shared_operation_pool_is_refused_and_missing_actor_never_queries
    unit = Vetra::Data::UnitOfWork.new(@db, scope: :global, limits: false)
    edge = Vetra::Execution::Edge.new(identity: ->(_) {}, facts: ->(_) {}, authority: ->(_) {}, rate_limit: limiter)
    error = assert_raises(Vetra::Data::Error) { edge.reserve_rate_limit(@context, @policies, operation_unit: unit) }
    assert_equal 'data_rate_limit_unavailable', error.code
    empty = Vetra::Data::Context.new(scope: :global, tenant_id: nil, op_id: SecureRandom.uuid, cmd: 'blog.create_comment')
    error = assert_raises(Vetra::Data::Error) { limiter.call(empty, @policies) }
    assert_equal 'data_authorization_context', error.code
    assert_empty @db.sqls
  end

  def test_tenant_actor_policy_and_window_are_signed_separately_and_not_taken_from_input
    contexts = [@context, Vetra::Data::Context.new(scope: :tenant, tenant_id: SecureRandom.uuid, actor_id: @context.actor_id,
                                                 op_id: SecureRandom.uuid, cmd: @context.cmd)]
    another = Vetra::Data::Context.new(scope: :tenant, tenant_id: SecureRandom.uuid, actor_id: @context.actor_id,
                                      op_id: SecureRandom.uuid, cmd: @context.cmd)
    contexts << another
    contexts.each do |context|
      token = @issuer.issue_rate_limit(context: context, namespace: 'blog', policies: @policies).value
      payload = JSON.parse((token.split('.')[2].tr('-_', '+/') + '=' * ((4 - token.split('.')[2].size % 4) % 4)).unpack1('m0'))
      context.tenant_id ? assert_equal(context.tenant_id, payload['tenant_id']) : assert_nil(payload['tenant_id'])
      assert_equal context.actor_id, payload['actor_id']
    end
    assert_equal 3, contexts.map(&:tenant_id).uniq.size
  end

  def test_purge_uses_maximum_declared_window_and_one_database_cutoff_in_batches
    db = Sequel.mock(host: :postgres)
    deletes = 0
    db.fetch = lambda do |sql|
      next [{ cutoff: '2026-11-12 10:00:00+00' }] if sql.include?(' AS cutoff')
      deletes += 1
      deletes == 1 ? [{ n: 1 }, { n: 1 }] : []
    end
    relay = Vetra::Data::Relay.new(db, document: document)
    assert_equal 2, relay.purge_rate_limit(batch: 2)
    sql = db.sqls
    assert_equal 1, sql.count { |statement| statement.include?('clock_timestamp()') }
    assert_includes sql.join, '-- args: [60]'
    assert_equal 2, sql.count { |statement| statement.include?('DELETE FROM vetra.rate_limit') }
    error = assert_raises(Vetra::Data::Error) { relay.purge_rate_limit(batch: 0) }
    assert_equal 'data_relay_limit', error.code
    assert_equal 0, Vetra::Data::Relay.new(db, document: document('chat')).purge_rate_limit
  end
  def test_cli_purge_requires_maintenance_database_and_refuses_retention_override
    out, err = StringIO.new, StringIO.new
    original = ENV.delete('DATABASE_URL')
    begin
      assert_equal 1, Vetra::CLI.run(['rate_limit:purge', '--root', File.join(PROJECT, 'examples/blog')], out: out, err: err)
      assert_includes err.string, 'db_database_url'
    ensure
      ENV['DATABASE_URL'] = original if original
    end
    assert_equal 2, Vetra::CLI.run(['rate_limit:purge', '--retention-hours', '1'], out: out, err: err)
    assert_equal 2, Vetra::CLI.run(['rate_limit:purge', '--ahead', '1'], out: out, err: err)
  end

end

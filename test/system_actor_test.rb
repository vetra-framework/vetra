require_relative 'test_helper'
require 'vetra/data'
require 'securerandom'

# Ator de sistema (ADR-024, §4): o contexto assinado, as rotinas do banco, a guarda e a política vt_system.
class SystemActorTest < GraphTest
  def setup
    @secret = SecureRandom.random_bytes(32)
    @claims = { tenant_id: SecureRandom.uuid, op_id: SecureRandom.uuid, cmd: 'crm.win_lead' }
    @issuer = Vetra::Data::ContextIssuer.new(kid: 'ephemeral', secret: @secret, clock: -> { 1_800_000_000 })
  end

  def payload(token)
    encoded = token.value.split('.')[2]
    JSON.parse((encoded.tr('-_', '+/') + '=' * ((4 - encoded.length % 4) % 4)).unpack1('m0'))
  end

  def test_system_token_carries_system_actor_instead_of_actor_id_and_keeps_the_claim_order
    token = @issuer.issue(**@claims, system_actor: 'crm.on_lead_won')
    body = payload(token)
    assert_equal %w[tenant_id system_actor op_id cmd iat exp], body.keys
    refute body.key?('actor_id')
    assert_equal 'crm.on_lead_won', body['system_actor']
    actor = payload(@issuer.issue(**@claims, actor_id: SecureRandom.uuid))
    assert_equal %w[tenant_id actor_id op_id cmd iat exp], actor.keys
    refute actor.key?('system_actor')
  end

  def test_context_requires_exactly_one_identity_and_never_a_system_actor_in_the_global_scope
    actor = SecureRandom.uuid
    assert_graph_error('data_context') { @issuer.issue(**@claims) }
    assert_graph_error('data_context') { @issuer.issue(**@claims, actor_id: actor, system_actor: 'crm.on_lead_won') }
    assert_graph_error('data_context') do
      Vetra::Data::Context.new(scope: :global, tenant_id: nil, system_actor: 'crm.on_lead_won', op_id: @claims[:op_id], cmd: 'blog.x')
    end
    ['', '1abc', 'a b', "a\0b", 'a' * 129, 'ação', 12, :sym].each do |bad|
      assert_graph_error('data_context') { @issuer.issue(**@claims, system_actor: bad) }
    end
    context = Vetra::Data::Context.new(scope: :tenant, system_actor: 'crm.on_lead_won', **@claims)
    assert context.system_actor?
    assert_nil context.actor_id
    assert_equal 'crm.on_lead_won', context.claims[:system_actor]
    refute Vetra::Data::Context.new(scope: :tenant, actor_id: actor, **@claims).system_actor?
  end

  def test_unit_of_work_installs_the_system_context_and_exposes_no_actor
    db = Sequel.mock(host: :postgres)
    work = Vetra::Data::UnitOfWork.new(db, issuer: @issuer)
    seen = nil
    work.transaction(**@claims, system_actor: 'crm.on_lead_won') { |unit| seen = unit.context }
    assert seen.system_actor?
    assert_nil seen.actor_id
    assert_graph_error('data_context') { work.transaction(**@claims) { |_| } }
  end

  def test_tenant_application_gets_the_system_routines_and_a_global_one_keeps_the_original_text
    tenant = Vetra::SQL::Context.prefix(system_actor: true).join("\n")
    legacy = Vetra::SQL::Context.prefix.join("\n")
    assert_includes tenant, 'CREATE FUNCTION "vetra"."is_system_actor"() RETURNS boolean'
    refute_includes legacy, 'is_system_actor'
    refute_includes legacy, 'system_actor'
    # current_actor() devolve NULL para o ator de sistema; o corpo original exige actor_id e não muda na aplicação global.
    assert_includes Vetra::SQL::Context.body('actor_id'), "OR (payload->>'actor_id') !~ uuid_pattern"
    body = Vetra::SQL::Context.body('actor_id', system_actor: true)
    refute_includes body, "!~ uuid_pattern OR (payload->>'actor_id') !~ uuid_pattern"
    assert_includes body, "IF (payload ? 'actor_id') = (payload ? 'system_actor') THEN RETURN NULL; END IF;"
    assert_includes Vetra::SQL::Context.body('system_actor', system_actor: true), "RETURN payload ? 'system_actor';"
    assert_includes Vetra::SQL::Context.body('system_actor', system_actor: true), 'RETURN false;'
    assert_raises(ArgumentError) { Vetra::SQL::Context.body('system_actor') }
  end

  def test_guard_trusts_exactly_the_generated_bodies_with_their_return_types
    guard = Vetra::SQL::Context.trusted_routine_sql(system_actor: true)
    Vetra::SQL::Context::SYSTEM_ROUTINES.each do |name, claim, returns|
      body = Vetra::SQL::Context.body(claim, system_actor: true)
      assert_includes guard, "p.proname = '#{name}' AND p.prorettype = 'pg_catalog.#{returns == 'boolean' ? 'bool' : returns}'::pg_catalog.regtype"
      assert_includes guard, Digest::SHA256.hexdigest(body)
    end
    # A guarda da aplicação global não conhece o ator de sistema nem muda o texto original.
    legacy = Vetra::SQL::Context.trusted_routine_sql
    refute_includes legacy, 'is_system_actor'
    assert_includes legacy, "'pg_catalog.uuid'::pg_catalog.regtype"
  end

  def test_only_tables_with_scope_get_the_system_policy_and_it_is_permissive_and_all_commands
    %w[mini_crm mini_crm_revendas].each do |example|
      with_app(example) do |_root, compiler|
        schema = Vetra::SQL::Schema.new(compiler.build.document).generate
        sql = Vetra::SQL::Security.new(schema).generate.statements.join("\n")
        system = sql.lines.select { |line| line.include?('"vt_system"') }
        if example == 'mini_crm'
          assert_empty system
        else
          assert_equal %w[dealers leads], system.map { |line| line[/"public"\."(\w+)"/, 1] }.sort
          system.each do |line|
            assert_includes line, 'AS PERMISSIVE FOR ALL TO "vetra_app"'
            assert_includes line, 'USING ((SELECT vetra.is_system_actor())) WITH CHECK ((SELECT vetra.is_system_actor()))'
          end
          # O isolamento de tenant continua restritivo em toda tabela com a política de sistema.
          system.each do |line|
            table = line[/ON ("public"\."\w+")/, 1]
            assert_includes sql, "ON #{table} AS RESTRICTIVE FOR ALL TO \"vetra_app\""
          end
        end
      end
    end
    with_app('blog') do |_root, compiler|
      schema = Vetra::SQL::Schema.new(compiler.build.document).generate
      refute_includes Vetra::SQL::Plan.initial(schema).render, 'is_system_actor'
    end
  end
end

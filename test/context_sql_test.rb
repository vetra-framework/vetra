require_relative 'test_helper'

class ContextSQLTest < GraphTest
  def test_every_example_has_complete_classified_context_and_explicit_owners_without_secrets
    %w[blog chat mini_crm mini_crm_revendas].each do |example|
      with_app(example) do |_root, compiler|
        schema = Vetra::SQL::Schema.new(compiler.build.document).generate
        plan = Vetra::SQL::Plan.initial(schema)
        sql = plan.render
        assert_equal sql, Vetra::SQL::Plan.parse(sql, file: plan.file_name).render
        assert_equal 2, sql.scan(/CREATE FUNCTION "vetra"\."current_/).size
        assert_equal 2, sql.scan('SECURITY DEFINER PARALLEL UNSAFE').size
        assert_includes sql, Vetra::SQL::Context.role_guard
        refute_includes sql, '$vetra_context_installer$'
        assert_includes sql, 'CREATE EXTENSION "pgcrypto" WITH SCHEMA "vetra_private"'
        assert_includes sql, 'REVOKE ALL ON SCHEMA "vetra", "vetra_private" FROM PUBLIC, "vetra_app"'
        refute_match(/(?:REVOKE|GRANT).*ON (?:ALL FUNCTIONS|FUNCTION "vetra_private"\.)/, sql)
        assert_includes sql, 'ALTER SCHEMA "public" OWNER TO "vetra_owner"'
        assert_includes sql, 'REVOKE CREATE, TEMPORARY ON DATABASE %I FROM PUBLIC, "vetra_app"'
        assert_includes sql, 'GRANT CREATE ON DATABASE %I TO "vetra_owner"'
        refute_match(/CREATE ROLE|ALTER ROLE|DROP ROLE|PASSWORD|GRANT "vetra_owner"/, sql)
        refute_includes sql, 'INSERT INTO "vetra_private"."keys"'
        schema.tables.each do |table|
          relation = table.values_at('schema', 'table').map { |v| %Q{"#{v}"} }.join('.')
          assert_includes sql, "ALTER TABLE #{relation} OWNER TO \"vetra_owner\""
          assert_includes sql, "GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE #{relation} TO \"vetra_app\""
        end
        plan.steps.each do |step|
          assert_includes Vetra::SQL::Plan::PHASES, step.phase
          assert_includes Vetra::SQL::Plan::LOCKS, step.lock
          assert_includes Vetra::SQL::Plan::COSTS, step.cost
        end
      end
    end
  end

  def test_bootstrap_is_separate_and_checks_all_attributes_and_memberships
    sql = Vetra::SQL::Context.roles_sql
    assert_equal 3, sql.scan('CREATE ROLE').size
    assert_equal 3, sql.scan('IF NOT EXISTS').size
    assert_includes sql, 'WITH ADMIN FALSE, INHERIT TRUE, SET TRUE'
    assert_includes sql, 'NOLOGIN INHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS'
    assert_includes sql, 'LOGIN INHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION BYPASSRLS'
    assert_includes sql, Vetra::SQL::Context.role_guard
    refute_match(/PASSWORD|ALTER ROLE|DROP ROLE/, sql)
    assert sql.start_with?("BEGIN;\n")
    assert sql.end_with?("COMMIT;\n")
  end

  def test_identifiers_are_validated_even_at_the_context_boundary
    ['', 'UPPER', 'a' * 64, 'x";drop', nil, "a\0b"].each do |name|
      assert_graph_error('context_identifier') { Vetra::SQL::Context.quote(name) }
      assert_graph_error('context_identifier') { Vetra::SQL::Context.suffix([{ 'schema' => 'public', 'table' => name }]) }
    end
    assert_equal '"sales_1"', Vetra::SQL::Context.quote('sales_1')
    assert_raises(ArgumentError) { Vetra::SQL::Context.body('arbitrary_sql') }
  end

  def test_guard_hashes_the_exact_generated_bodies_and_checks_security_attributes
    guard = Vetra::SQL::Context.trusted_routine_sql
    prefix = Vetra::SQL::Context.prefix.join("\n")
    Vetra::SQL::Context::FUNCTIONS.each do |name, claim|
      body = Vetra::SQL::Context.body(claim)
      assert_includes prefix, "$vetra_context$#{body}$vetra_context$"
      assert_includes guard, "p.proname = '#{name}'"
      assert_includes guard, Digest::SHA256.hexdigest(body)
      refute_includes guard, Digest::SHA256.hexdigest(body.sub('RETURN NULL;', "RETURN '00000000-0000-0000-0000-000000000001'::uuid;"))
    end
    ["nspname = 'vetra' AND nspowner", "rolname = 'vetra_owner'", "lanname = 'plpgsql'",
     "p.provolatile = 's'", "p.proparallel = 'u'", 'p.prosecdef', 'NOT p.proleakproof', 'NOT p.proretset',
     'p.pronargs = 0', 'p.prosupport = 0', "'pg_catalog.uuid'::pg_catalog.regtype", 'p.prosqlbody IS NULL',
     "p.proconfig = ARRAY['search_path=pg_catalog, pg_temp']::text[]"].each { |check| assert_includes guard, check }
    assert guard.start_with?('COALESCE(')
  end

  def test_context_checks_signature_before_claims_and_does_not_cache_a_verified_result
    body = Vetra::SQL::Context.body('tenant_id')
    assert_equal 1, body.scan('FROM "vetra_private"."keys"').size
    assert_includes body, 'FOR i IN 0..31 LOOP'
    assert_includes body, 'difference := difference | (pg_catalog.get_byte(supplied, i) # pg_catalog.get_byte(expected, i))'
    assert_operator body.index('IF difference <> 0'), :<, body.index('payload :=')
    assert_includes body, "k.status IN ('active', 'verify_only')"
    assert_includes body, 'expires > issued + 120'
    assert_includes body, 'now_epoch < issued - 5 OR now_epoch > expires'
    assert_includes body, 'key_not_before > pg_catalog.to_timestamp(issued::double precision)'
    assert_includes body, "EXCEPTION WHEN OTHERS THEN\n  RETURN NULL;"
    refute_match(/set_config|SET LOCAL|clock_timestamp|EXECUTE /, body)
  end

  def test_authorization_uses_the_same_exact_exception_in_both_guards
    with_app('mini_crm_revendas') do |_root, compiler|
      sql = Vetra::SQL::Authorization.new(compiler.build.document).generate.sql
      assert_equal 3, sql.scan(Vetra::SQL::Context.trusted_routine_sql).size
      assert_includes sql, "Schema vetra existente deve pertencer a vetra_owner"
      assert_includes sql, 'CREATE TABLE "vetra"."authz_revisions"'
      refute_includes sql, 'CREATE TABLE IF NOT EXISTS'
      assert_includes sql, "p.prosecdef AND p.prokind IN ('f', 'p')\n      AND NOT COALESCE("
    end
  end

  def test_snapshot_retains_owners_and_grants_as_security_information
    _, args = Vetra::SQL::ScratchDatabase.pg_dump_invocation({ 'dbname' => 'temporary' })
    refute_includes args, '--no-owner'
    dump = "ALTER TABLE public.x OWNER TO vetra_owner;\nGRANT SELECT ON TABLE public.x TO vetra_app;\n"
    assert_equal dump, Vetra::SQL::ScratchDatabase.normalize_dump(dump)
    refute_equal dump, Vetra::SQL::ScratchDatabase.normalize_dump(dump.sub('vetra_owner', 'other_owner'))
  end
end

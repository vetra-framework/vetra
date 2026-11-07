require_relative 'test_helper'

class SecuritySQLTest < GraphTest
  def document(example = 'mini_crm_revendas')
    JSON.parse(File.read(File.join(PROJECT, 'examples', example, '.vetra/graph.json')))
  end

  def schema(doc)
    doc['digest'] = Vetra::Graph::Canonical.digest(doc)
    Vetra::SQL::Schema.new(doc).generate
  end

  def security(doc = document)
    Vetra::SQL::Security.new(schema(doc)).generate
  end

  def test_all_tenant_tables_and_root_have_both_rls_flags_and_restrictive_checks
    %w[mini_crm mini_crm_revendas].each do |example|
      model = schema(document(example))
      result = Vetra::SQL::Security.new(model).generate
      sql = result.statements.join("\n")
      model.tables.each do |table|
        path = table.values_at('schema', 'table').map { |name| %Q{"#{name}"} }.join('.')
        assert_includes sql, "ALTER TABLE #{path} ENABLE ROW LEVEL SECURITY"
        assert_includes sql, "ALTER TABLE #{path} FORCE ROW LEVEL SECURITY"
        assert_includes sql, "ON #{path} AS RESTRICTIVE FOR ALL TO \"vetra_app\" USING (\"#{table['tenant_column']}\" = (SELECT vetra.current_tenant())) WITH CHECK (\"#{table['tenant_column']}\" = (SELECT vetra.current_tenant()))"
      end
      assert_includes sql, 'ON "public"."companies" AS PERMISSIVE FOR ALL'
      assert result.frozen?
      assert result.statements.frozen?
    end
  end

  def test_scope_correlates_only_the_unit_and_binds_tenant_and_actor_with_initplans
    sql = security.statements.join("\n")
    assert_match(/FROM "public"\."memberships" AS "vt_scope_\d+" WHERE \("vt_scope_\d+"\."company_id" = \(SELECT vetra.current_tenant\(\)\)\)/, sql)
    assert_match(/"vt_scope_\d+"\."user_id" = \(SELECT vetra.current_actor\(\)\)/, sql)
    assert_match(/"vt_scope_\d+"\."dealer_id" = "leads"\."dealer_id"/, sql)
    refute_match(/FROM "public"\."dealers"/, sql)
    refute_includes sql, '"leads"."company_id"'
    %w[SELECT INSERT UPDATE DELETE].each { |action| assert_includes sql, "AS PERMISSIVE FOR #{action}" }
    insert = sql.lines.find { |line| line.include?('"vt_scope_create" ON "public"."leads"') }
    refute_includes insert, 'USING'
    assert_includes insert, 'WITH CHECK'
    update = sql.lines.find { |line| line.include?('"vt_scope_update" ON "public"."leads"') }
    assert_includes update, 'USING'
    assert_includes update, 'WITH CHECK'
    delete = sql.lines.find { |line| line.include?('"vt_scope_delete" ON "public"."leads"') }
    assert_includes delete, "E'gerente'"
    refute_includes delete, "E'vendedor'"
    refute_includes sql, '"vt_access" ON "public"."leads"'
    refute_includes sql, '"vt_scope_create" ON "public"."dealers"'
  end

  def test_membership_scope_requires_index_starting_with_tenant_and_actor
    doc = document
    node(doc, 'entity', 'crm.membership')['indexes'].reject! { |index| index['fields'][1] == 'user_id' }
    # Uma FK de user forneceria o índice automaticamente; este vínculo conserva só a identidade tipada.
    node(doc, 'entity', 'crm.membership')['relations'].reject! { |link| link['name'] == 'user' }
    assert_graph_error('security_scope_index') { security(doc) }
  end

  def test_rls_cycles_are_rejected_before_generating_an_unusable_plan
    doc = document
    policy = node(doc, 'policy', 'crm.gerente.permission_5')
    policy['predicate'] = { 'op' => 'exists', 'relation' => ['dealer'], 'where' => { 'op' => 'true' } }
    policy['reads'] << { 'kind' => 'entity', 'id' => 'crm.dealer' }
    assert_graph_error('security_policy_cycle') { security(doc) }
  end

  def test_non_sql_predicate_is_recorded_and_does_not_remove_tenant_barrier
    doc = document
    policy = node(doc, 'policy', 'crm.gerente.permission_1')
    policy['predicate'] = { 'op' => 'eq', 'left' => { 'kind' => 'field', 'path' => ['valor'] },
                            'right' => { 'kind' => 'literal', 'value' => nil } }
    result = security(doc)
    assert_includes result.artifact, 'crm.gerente.permission_1: predicado fora do subconjunto SQL'
    assert_includes result.artifact, 'AS RESTRICTIVE'
    assert_includes result.artifact, 'WITH CHECK'
  end

  def test_predicate_boolean_operators_literals_null_and_in_have_no_raw_sql
    doc = document
    policy = node(doc, 'policy', 'crm.gerente.permission_1')
    field = { 'kind' => 'field', 'path' => ['name'] }
    policy['predicate'] = { 'op' => 'or', 'terms' => [
      { 'op' => 'not', 'term' => { 'op' => 'eq', 'left' => field, 'right' => { 'kind' => 'literal', 'value' => "x'\\\n" } } },
      { 'op' => 'in', 'left' => field, 'right' => { 'kind' => 'literal', 'value' => ['a', 'b'] } },
      { 'op' => 'eq', 'left' => field, 'right' => { 'kind' => 'literal', 'value' => nil } }
    ] }
    sql = security(doc).artifact
    assert_includes sql, 'NOT ('
    assert_includes sql, "IN (E'a', E'b')"
    assert_includes sql, 'IS NOT DISTINCT FROM NULL'
    assert_includes sql, "E'x''" + ('\\' * 3) + "x0a'"
    policy['predicate']['terms'][0]['term']['right']['value'] = "bad\0value"
    assert_graph_error('security_literal') { security(doc) }
  end

  def test_transitions_validate_the_whole_token_before_reading_command_and_revoke_execution
    sql = security(document('mini_crm')).artifact
    assert_includes sql, 'SECURITY INVOKER'
    refute_includes sql, 'SECURITY DEFINER'
    assert_includes sql, "IF current_user = 'vetra_migrator' THEN RETURN NEW"
    assert_operator sql.index('IF vetra.current_tenant() IS NULL'), :<, sql.index("::jsonb->>'cmd'")
    assert_includes sql, 'SET search_path = pg_catalog, pg_temp'
    assert_includes sql, 'BEFORE INSERT OR UPDATE'
    assert_includes sql, 'ENABLE ALWAYS TRIGGER'
    assert_includes sql, "NEW.\"status\" = E'won' OR OLD.\"status\" = E'won'"
    assert_includes sql, 'NEW."status" IS DISTINCT FROM OLD."status"'
    assert_includes sql, "command_name NOT IN (E'crm.win_lead')"
    assert_includes sql, 'OWNER TO "vetra_owner"'
    assert_includes sql, 'FROM PUBLIC, "vetra_app"'
    refute_includes sql, 'vetra.cmd'
  end

  def test_set_by_compares_insert_to_default_and_update_to_old_including_nulls
    with_app('mini_crm') do |root, compiler|
      edit(root, 'app/domains/crm/lead.rb') { |text| text.sub('email :email', 'email :email, set_by: :win_lead') }
      doc = Vetra::Graph::Data.copy(compiler.build.document)
      field = node(doc, 'entity', 'crm.lead')['fields'].find { |item| item['name'] == 'email' }
      sql = security(doc).artifact
      assert_includes sql, "TG_OP = 'INSERT' AND ROW(NEW.\"email\") IS DISTINCT FROM ROW(NULL)"
      assert_includes sql, "TG_OP = 'UPDATE' AND ROW(NEW.\"email\") IS DISTINCT FROM ROW(OLD.\"email\")"
      field['type'] = { 'name' => 'id' }
      field['default'] = { 'kind' => 'context', 'name' => 'current_actor' }
      assert_graph_error('security_transition_default') { security(doc) }
    end
  end

  def test_plan_contains_authz_statements_once_with_guards_after_all_revokes
    model = schema(document)
    plan = Vetra::SQL::Plan.initial(model)
    statements = plan.steps.map(&:sql)
    authz = Vetra::SQL::Authorization.new(model.document).generate
    assert_equal 15, statements.count { |sql| sql.start_with?('CREATE TRIGGER "vt_authz_') }
    assert statements.none? { |sql| sql.match?(/\A(?:BEGIN|COMMIT|SET LOCAL)/) }
    assert_equal authz.statements, statements.last(authz.statements.size)
    plan.steps.each do |step|
      expected = case step.sql
      when /\ACREATE POLICY /, /\AALTER TABLE \S+ (ENABLE|FORCE) ROW LEVEL SECURITY/ then 'AccessExclusive'
      when /\ACREATE TRIGGER /, /\AALTER TABLE \S+ ENABLE ALWAYS TRIGGER / then 'ShareRowExclusive'
      when /\AINSERT INTO / then 'RowExclusive'
      end
      assert_equal expected, step.lock if expected
    end
    last_revoke = statements.rindex { |sql| sql.start_with?('REVOKE') }
    assert_operator statements.index { |sql| sql.start_with?('DO $vetra_privileges$') }, :>, last_revoke
    assert_operator statements.index { |sql| sql.start_with?('DO $vetra_routines$') }, :>, last_revoke
    assert_equal plan.render, Vetra::SQL::Plan.parse(plan.render, file: plan.file_name).render
    assert_equal authz.statements, Vetra::SQL::StatementScanner.statements(authz.statements.join("\n"))
    assert_raises(ArgumentError) { Vetra::SQL::StatementScanner.statements("SELECT 'unfinished") }
  end

  def test_global_examples_do_not_invent_tenants_or_revisions
    %w[blog chat].each do |example|
      model = schema(document(example))
      result = Vetra::SQL::Security.new(model).generate
      assert_empty result.statements
      assert_includes result.artifact, 'Aplicação sem tenant'
      sql = Vetra::SQL::Plan.initial(model).render
      refute_includes sql, 'authz_revisions'
      # Numa aplicação global, as políticas são só as da outbox (ADR-040): a de INSERT da aplicação, que exige tenant
      # nulo, e as do relay e do dono. Nenhuma tabela da aplicação tem política.
      policies = sql.scan(/^CREATE POLICY .*$/)
      refute policies.any? { |policy| !policy.include?(' ON "vetra".') }
      app = policies.select { |policy| policy.include?('TO "vetra_app"') }
      assert_equal(example == 'blog' ? ['CREATE POLICY "vt_outbox_insert" ON "vetra"."outbox" AS PERMISSIVE FOR INSERT TO "vetra_app" WITH CHECK ("tenant_id" IS NULL);'] : [], app)
      assert_equal(example == 'blog' ? 10 : 0, policies.size)
    end
  end

  def test_policy_artifact_is_checked_before_any_database_access_and_repeated_plan_is_unchanged
    with_app('mini_crm_revendas') do |root, compiler|
      compiler.write
      planner = Vetra::SQL::Planner.new(root: root)
      planner.plan
      path = File.join(root, Vetra::SQL::Planner::POLICIES)
      original = File.binread(path)
      assert_equal :unchanged, planner.plan.status
      assert_equal original, File.binread(path)
      File.write(path, original + "-- editado\n")
      %i[plan check snapshot].each { |method| assert_graph_error('db_policies_stale') { planner.public_send(method) } }
      File.unlink(path)
      assert_graph_error('db_policies_stale') { planner.check }
      File.binwrite(path, original)
      write(root, 'db/policies/extra.sql', '-- extra')
      assert_graph_error('db_policies_stale') { planner.check }
    end
  end

  def test_security_is_deterministic_under_node_field_and_relation_reordering
    doc = document
    original = security(doc)
    doc['nodes'].reverse!
    doc['nodes'].select { |item| item['kind'] == 'entity' }.each do |entity|
      entity['fields'].reverse!
      entity['relations'].reverse!
    end
    assert_equal original.artifact, security(doc).artifact
  end
end

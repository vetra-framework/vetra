require_relative 'test_helper'

class AuthorizationSQLTest < GraphTest
  def generate(document, **options)
    Vetra::SQL::Authorization.new(document, **options).generate
  end

  def redigest(document)
    document['digest'] = Vetra::Graph::Canonical.digest(document)
    document
  end

  def test_selection_includes_policy_dependencies_junctions_and_the_tenant_root
    with_app('mini_crm_revendas') do |_root, compiler|
      document = compiler.build.document
      result = generate(document)
      assert_equal %w[crm.company crm.dealer crm.lead crm.membership crm.user], result.tables.map { |table| table['entity'] }
      assert_equal 'id', result.tables.first['tenant_column']
      assert_equal ['company_id'], result.tables.drop(1).map { |table| table['tenant_column'] }.uniq
      assert_includes result.sql, document['digest']
      assert_includes result.sql, '"public"."memberships"'
      assert_includes result.sql, 'SELECT DISTINCT "company_id"::text'
      assert_includes result.sql, "SET LOCAL lock_timeout = '3s'"
      assert_includes result.sql, 'SECURITY DEFINER SET search_path = pg_catalog, pg_temp'
      assert result.sql.end_with?("COMMIT;\n")
      assert result.frozen?
      assert result.sql.frozen?
      assert result.tables.all?(&:frozen?)
      assert_raises(FrozenError) { result.tables.first['table'].replace('other') }
    end
  end

  def test_maps_physical_schema_and_table_names_from_the_ir
    with_app('mini_crm_revendas') do |_root, compiler|
      document = Vetra::Graph::Data.copy(compiler.build.document)
      node(document, 'entity', 'crm.membership')['storage'].merge!('schema' => 'sales', 'table' => 'member_links')
      result = generate(redigest(document), schema: 'infra', owner_role: 'data_owner', app_role: 'web_app')
      assert_includes result.sql, 'ON "sales"."member_links"'
      assert_includes result.sql, 'CREATE SCHEMA "infra" AUTHORIZATION "data_owner"'
      assert_includes result.sql, 'GRANT SELECT ON "infra"."authz_revisions" TO "web_app"'
      refute_includes result.sql, 'ON "public"."memberships"'
    end
  end

  def test_tenant_root_is_watched_and_seeded_even_without_policies
    with_app('mini_crm_revendas') do |root, compiler|
      File.unlink(File.join(root, 'app/domains/crm/roles.rb'))
      result = generate(compiler.build.document)
      assert_equal ['crm.company'], result.tables.map { |table| table['entity'] }
      assert_includes result.sql, 'SELECT "id"::text, 0 FROM "public"."companies"'
      assert_includes result.sql, 'AFTER DELETE ON "public"."companies"'
      refute_includes result.sql, 'FOREIGN KEY'
      refute_empty result.warnings
    end
  end

  def test_statements_use_old_and_new_tenants_and_atomic_increment
    with_app('mini_crm_revendas') do |_root, compiler|
      sql = generate(compiler.build.document).sql
      assert_equal 15, sql.scan('CREATE TRIGGER ').size
      assert_includes sql, 'SELECT "company_id"::text AS tenant_id FROM vt_old UNION SELECT "company_id"::text AS tenant_id FROM vt_new ORDER BY tenant_id'
      assert_includes sql, 'SET revision = stored.revision + 1'
      assert_includes sql, "pg_notify('vetra_authz', affected_tenant)"
      assert_includes sql, 'REVOKE TRUNCATE, TRIGGER, REFERENCES ON'
      assert_equal 15, sql.scan(/ENABLE ALWAYS TRIGGER "vt_authz_/).size
      refute_includes sql, 'CREATE ROLE'
      refute_includes sql, 'CREATE OR REPLACE'
      refute_includes sql, 'DROP '
      refute_includes sql, 'CREATE TABLE IF NOT EXISTS'
    end
  end

  def test_privilege_guards_cover_roles_reachable_by_set_role
    with_app('mini_crm_revendas') do |_root, compiler|
      sql = generate(compiler.build.document, app_role: 'web_app').sql
      # Atributos dos papéis, cinco tabelas protegidas, schema, revisões e funções.
      assert_equal 9, sql.scan("pg_roles r WHERE pg_has_role('web_app', r.oid, 'SET')").size
      assert_includes sql, %q{has_table_privilege(r.oid, '"public"."memberships"', 'TRUNCATE,TRIGGER')}
      assert_includes sql, %q{has_any_column_privilege(r.oid, '"public"."memberships"', 'REFERENCES')}
      assert_includes sql, 'AND (r.rolsuper OR r.rolbypassrls OR r.rolcreaterole)'
      usable = ->(role) { "EXISTS (SELECT 1 FROM pg_roles a WHERE pg_has_role('web_app', a.oid, 'SET') AND pg_has_role(a.oid, #{role}, 'USAGE'))" }
      assert_includes sql, "FROM pg_auth_members m WHERE m.admin_option AND #{usable['m.member']}"
      assert_includes sql, "IF #{usable["'pg_create_subscription'::regrole"]}"
      assert_includes sql, "FROM pg_subscription s WHERE #{usable['s.subowner']}"
      assert_includes sql, "'pg_execute_server_program', 'pg_write_server_files', 'pg_read_server_files'"
      refute_includes sql, 'MEMBER WITH ADMIN OPTION'
      %w[has_table_privilege has_any_column_privilege has_schema_privilege has_function_privilege].each do |check|
        refute_includes sql, "#{check}('web_app'"
      end
    end
  end

  def test_apps_without_tenants_fail_audibly
    with_app('chat') do |_root, compiler|
      error = assert_graph_error('authz_tenant') { generate(compiler.build.document) }
      assert_equal '/app/tenant', error.diagnostics.first.pointer
    end
  end

  def test_global_policy_dependency_is_not_silently_skipped
    with_app('mini_crm_revendas') do |root, compiler|
      write(root, 'app/domains/crm/catalog.rb', "entity :catalog do\n  tenant false\n  string :name\nend\n")
      write(root, 'app/domains/crm/catalog_roles.rb', "roles do\n  authenticated do\n    can :read, on: :catalog\n  end\nend\n")
      error = assert_graph_error('tenant_missing') { generate(compiler.build.document) }
      assert_equal 'app/domains/crm/catalog.rb', error.diagnostics.first.source['path']
    end
  end

  def test_invalid_sql_names_are_rejected_before_any_sql_is_returned
    with_app('mini_crm_revendas') do |_root, compiler|
      document = compiler.build.document
      ['', 'Upper', 'x;drop_table', "x\0y", 'a' * 64, nil].each do |name|
        assert_graph_error('authz_identifier') { generate(document, schema: name) }
      end
      assert_graph_error('authz_roles') { generate(document, owner_role: 'same', app_role: 'same') }
      %w[pg_temp information_schema].each do |schema|
        assert_graph_error('authz_roles') { generate(document, schema: schema) }
      end
    end
  end

  def test_duplicate_or_conflicting_storage_is_rejected
    with_app('mini_crm_revendas') do |_root, compiler|
      original = compiler.build.document
      document = Vetra::Graph::Data.copy(original)
      node(document, 'entity', 'crm.user')['storage'] = Vetra::Graph::Data.copy(node(document, 'entity', 'crm.dealer')['storage'])
      assert_graph_error('authz_storage') { generate(redigest(document)) }
      assert_graph_error('authz_storage') { generate(original, schema: 'public') }
      document = Vetra::Graph::Data.copy(original)
      node(document, 'entity', 'crm.user')['storage']['table'] = 'a' * 64
      assert_graph_error('authz_identifier') { generate(redigest(document)) }
    end
  end

  def test_invalid_ir_is_validated_before_generation
    with_app('mini_crm_revendas') do |_root, compiler|
      document = Vetra::Graph::Data.copy(compiler.build.document)
      document['digest'] = 'sha256:' + '0' * 64
      assert_graph_error('digest_mismatch') { generate(document) }
    end
  end

  def test_generation_copies_input_and_is_deterministic_across_node_order
    with_app('mini_crm_revendas') do |_root, compiler|
      document = Vetra::Graph::Data.copy(compiler.build.document)
      generator = Vetra::SQL::Authorization.new(document)
      result = generator.generate
      document['nodes'].reverse!
      reordered = generate(redigest(document))
      assert_equal result.tables, reordered.tables
      without_digest = ->(sql) { sql.lines.reject { |line| line.start_with?('-- Grafo ') } }
      assert_equal without_digest.call(result.sql), without_digest.call(reordered.sql)
      assert_equal result.sql, generator.generate.sql
    end
  end

  def test_older_ir_formats_can_generate_without_conversion
    with_app('mini_crm_revendas') do |root, _compiler|
      %w[0.1 0.2].each do |version|
        manifest = Vetra::Graph::Manifest.new(Pathname.new(root))
        registry = Vetra::Graph::DeclarationLoader.new(manifest).load
        document = Vetra::Graph::Normalizer.new(registry, manifest, ir_version: version).document
        assert_equal 5, generate(document).tables.size
        assert_equal version, document['ir_version']
      end
    end
  end

  def test_cli_reads_the_artifact_without_evaluating_the_dsl_again
    with_app('mini_crm_revendas') do |root, compiler|
      marker = File.join(root, 'registered')
      edit(root, 'config/app.rb') { |text| text + "\n::File.write(#{marker.inspect}, 'evaluated')\n" }
      compiler.write
      File.unlink(marker)
      out, err = StringIO.new, StringIO.new
      assert_equal 0, Vetra::CLI.run(['db:authz:sql', '--root', root], out: out, err: err), err.string
      assert_empty err.string
      assert_includes out.string, 'CREATE TRIGGER'
      refute File.exist?(marker)
      refute Dir.exist?(File.join(root, 'db'))
      assert compiler.read_artifact.document.frozen?
    end
  end

  def test_cli_options_do_not_leak_to_graph_commands
    with_app('mini_crm_revendas') do |root, compiler|
      compiler.write
      [%w[--sources], %w[--format json], %w[--fail-on-breaking], ['extra.json']].each do |extra|
        out = StringIO.new
        assert_equal 2, Vetra::CLI.run(['db:authz:sql', '--root', root, *extra], out: out, err: StringIO.new)
        assert_empty out.string
      end
      assert_equal 2, Vetra::CLI.run(['graph:check', '--root', root, '--sql-schema', 'infra'], out: StringIO.new, err: StringIO.new)
      out = StringIO.new
      assert_equal 0, Vetra::CLI.run(['db:authz:sql', '--root', root, '--sql-schema', 'infra'], out: out, err: StringIO.new)
      assert_includes out.string, 'CREATE SCHEMA "infra"'
    end
  end

  def test_cli_rejects_missing_noncanonical_stale_and_incompatible_packages_without_partial_sql
    with_app('mini_crm_revendas') do |root, compiler|
      out, err = StringIO.new, StringIO.new
      assert_equal 1, Vetra::CLI.run(['db:authz:sql', '--root', root], out: out, err: err)
      assert_empty out.string
      assert_includes err.string, '[graph_missing]'
      result = compiler.write
      compiler.artifact.write(JSON.pretty_generate(result.document))
      out, err = StringIO.new, StringIO.new
      assert_equal 1, Vetra::CLI.run(['db:authz:sql', '--root', root], out: out, err: err)
      assert_empty out.string
      assert_includes err.string, '[graph_not_canonical]'
      document = Vetra::Graph::Data.copy(result.document)
      document['producer']['version'] = '99.0.0'
      compiler.artifact.write(Vetra::Graph::Canonical.dump(redigest(document)) + "\n")
      out, err = StringIO.new, StringIO.new
      assert_equal 1, Vetra::CLI.run(['db:authz:sql', '--root', root], out: out, err: err)
      assert_empty out.string
      assert_includes err.string, '[producer_mismatch]'
      compiler.artifact.write(result.bytes)
      edit(root, 'config/app.rb') { |text| text + "\n# source changed\n" }
      out, err = StringIO.new, StringIO.new
      assert_equal 1, Vetra::CLI.run(['db:authz:sql', '--root', root], out: out, err: err)
      assert_empty out.string
      refute_empty err.string
    end
  end
end

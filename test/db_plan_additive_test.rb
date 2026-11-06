require_relative 'test_helper'
require_relative '../script/support/casos_plano_aditivo'

class DBPlanAdditiveTest < GraphTest
  def planner(root, database = nil)
    Vetra::SQL::Planner.new(root: root, database: database)
  end

  def incremental(root)
    path = File.join(root, 'db/plans/0002_expand.sql')
    Vetra::SQL::Plan.parse(File.read(path), file: path)
  end

  def scenario(name)
    with_app(AdditivePlanCases::CASES.fetch(name)) do |root, compiler|
      AdditivePlanCases.prepare(root, name)
      AdditivePlanCases.compile(compiler, name)
      planner(root).plan
      first = Dir.glob(File.join(root, 'db/**/*')).select { |p| File.file?(p) }.to_h { |p| [p, File.binread(p)] }
      AdditivePlanCases.change(root, name)
      AdditivePlanCases.compile(compiler, name, changed: true)
      yield root, compiler, first
    end
  end

  AdditivePlanCases::CASES.each_key do |name|
    define_method("test_#{name}_is_classified_filtered_and_regenerated_byte_for_byte") do
      scenario(name) do |root, compiler, first|
        result = planner(root).plan
        assert_equal :written, result.status
        assert_equal '0002_expand.sql', File.basename(result.path)
        plan = incremental(root)
        assert_equal 'por_passo', plan.transaction
        assert_equal ['expand'], plan.steps.map(&:phase).uniq
        assert_equal (1..plan.steps.size).to_a, plan.steps.map(&:number)
        plan.steps.each do |step|
          assert_nil Vetra::SQL::Plan.check_step!(step, plan.transaction, plan.file_name)
          assert_equal Vetra::SQL::Plan.classify(step.sql, existing: step.cost != 'tabela_vazia'), [step.lock, step.cost]
        end
        if name == :coluna
          assert_equal 'ALTER TABLE "public"."posts" ADD COLUMN "nota" text;', plan.steps.first.sql
          assert_equal 3, plan.steps.size
          assert_match(/ADD CONSTRAINT .* CHECK \(pg_catalog\.char_length\("nota"\) <= 40\) NOT VALID;/, plan.steps[1].sql)
          assert_match(/VALIDATE CONSTRAINT/, plan.steps[2].sql)
        elsif name == :constante
          assert_equal ['ALTER TABLE "public"."posts" ADD COLUMN "score" bigint NOT NULL DEFAULT 0;'], plan.steps.map(&:sql)
        elsif name == :indice
          assert_equal 1, plan.steps.size
          assert_match(/CREATE INDEX CONCURRENTLY .* ON "public"\."posts" \("title"\);/, plan.steps.first.sql)
        elsif name == :unica
          assert_equal 2, plan.steps.size
          assert_match(/CREATE UNIQUE INDEX CONCURRENTLY .* \("title"\);/, plan.steps[0].sql)
          assert_match(/ADD CONSTRAINT .* UNIQUE USING INDEX/, plan.steps[1].sql)
        end
        schema = Vetra::SQL::Schema.new(compiler.read_artifact.document).generate
        model = Vetra::SQL::Model.new(file: '0001_inicial.json', text: first.fetch(File.join(root, 'db/models/0001_inicial.json')))
        assert_equal plan.render, Vetra::SQL::Differ.call(base: model, schema: schema, number: '0002').render
        # As formas novas também têm identidade no modelo; nenhum SQL fica sem classificação/tipo.
        assert_equal plan.steps.size, Vetra::SQL::Model.state(schema, plan)['statements'].size
        assert_equal :unchanged, planner(root).plan.status
        first.each { |path, bytes| assert_equal bytes, File.binread(path) unless path.end_with?('0001_seguranca.sql') }
        generated = [result.path, File.join(root, 'db/models/0002_expand.json'), File.join(root, 'db/policies/0001_seguranca.sql')].to_h { |p| [p, File.binread(p)] }
        generated.each_key { |p| FileUtils.rm(p) }
        first.each { |p, bytes| File.binwrite(p, bytes) }
        planner(root).plan
        generated.each { |p, bytes| assert_equal bytes, File.binread(p) }
      end
    end
  end

  def test_combined_plan_builds_all_support_before_foreign_keys_and_keeps_enum_constrained
    scenario(:combinado) do |root|
      planner(root).plan
      steps = incremental(root).steps
      sql = steps.map(&:sql)
      create = sql.index { |s| s.start_with?('CREATE UNIQUE INDEX CONCURRENTLY') }
      attach = sql.index { |s| s.include?('UNIQUE USING INDEX') }
      fk = sql.index { |s| s.include?('FOREIGN KEY') }
      assert_operator create, :<, attach
      assert_operator attach, :<, fk
      assert_equal 'nao', steps[create].transaction
      assert_equal ['ShareUpdateExclusive', 'varre_tabela'], [steps[create].lock, steps[create].cost]
      assert sql[fk].end_with?('NOT VALID;')
      assert sql[fk + 1].include?('VALIDATE CONSTRAINT')
      assert_equal ['ShareRowExclusive', 'catalogo'], [steps[fk].lock, steps[fk].cost]
      assert_equal ['ShareUpdateExclusive', 'varre_tabela'], [steps[fk + 1].lock, steps[fk + 1].cost]
      swap = sql.index { |s| s.include?('RENAME CONSTRAINT') }
      assert sql[swap - 2].include?('CHECK')
      assert sql[swap - 2].end_with?('NOT VALID;')
      assert sql[swap - 1].include?('VALIDATE CONSTRAINT')
      assert sql[swap].start_with?('ALTER TABLE "public"."posts" DROP CONSTRAINT')
      assert_equal 'sim', steps[swap].transaction
    end
  end

  def test_policy_switch_is_one_atomic_step_and_mirror_is_the_current_empty_database_definition
    scenario(:politica) do |root, compiler|
      planner(root).plan
      swaps = incremental(root).steps.select { |step| step.sql.start_with?('DROP POLICY') }
      assert_equal 1, swaps.size
      step = swaps.first
      assert_includes step.sql, 'CREATE POLICY "vt_access"'
      assert_includes step.sql, 'DROP POLICY "vt_scope_read"'
      assert_equal ['AccessExclusive', 'catalogo', 'sim'], [step.lock, step.cost, step.transaction]
      schema = Vetra::SQL::Schema.new(compiler.read_artifact.document).generate
      assert_equal Vetra::SQL::Security.new(schema).generate.artifact, File.read(File.join(root, Vetra::SQL::Planner::POLICIES))
      touched = Object.new
      def touched.replay(*) = raise('não deve acessar o banco')
      edit(root, Vetra::SQL::Planner::POLICIES) { |s| s + '-- adulterado\n' }
      assert_graph_error('db_policies_stale') { planner(root, touched).snapshot }
      assert_graph_error('db_policies_stale') { planner(root, touched).check }
      assert_graph_error('db_policies_stale') { planner(root, touched).plan }
    end
  end

  def test_composite_fk_builds_and_attaches_the_new_unique_support_before_the_key
    scenario(:composta) do |root|
      planner(root).plan
      sql = incremental(root).steps.map(&:sql)
      create = sql.index { |s| s.start_with?('CREATE UNIQUE INDEX CONCURRENTLY') && s.include?('("company_id", "code")') }
      attach = sql.index { |s| s.include?('UNIQUE USING INDEX') }
      fk = sql.index { |s| s.include?('FOREIGN KEY ("company_id", "category_code")') }
      assert_operator create, :<, attach
      assert_operator attach, :<, fk
      assert sql[fk].include?('("company_id", "code")')
      assert sql[fk].end_with?('NOT VALID;')
      assert sql[fk + 1].include?('VALIDATE CONSTRAINT')
    end
  end

  def test_revision_guards_are_reapplied_after_new_routines_and_revokes_without_reseeding
    scenario(:revisao) do |root|
      planner(root).plan
      steps = incremental(root).steps
      install = steps.find { |step| step.sql.start_with?('LOCK TABLE ') }
      assert_equal ['ShareRowExclusive', 'catalogo', 'sim'], [install.lock, install.cost, install.transaction]
      sql = install.sql
      assert_includes sql, 'CREATE FUNCTION "vetra"."vt_authz_'
      assert_operator sql.rindex('DO $vetra_routines$'), :>, sql.rindex('REVOKE')
      refute steps.any? { |s| s.sql.start_with?('INSERT INTO', 'CREATE TABLE "vetra"') }
    end
  end

  def test_new_table_keeps_the_complete_initial_definition_security_and_revision
    scenario(:tabela) do |root|
      planner(root).plan
      sql = incremental(root).steps.map(&:sql).join("\n")
      ['CREATE TABLE "public"."notes"', 'PRIMARY KEY', 'CHECK', 'UNIQUE', 'CREATE INDEX', 'FOREIGN KEY',
       'ALTER TABLE "public"."notes" OWNER TO "vetra_owner"', 'GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE "public"."notes"',
       'ALTER TABLE "public"."notes" ENABLE ROW LEVEL SECURITY', 'ALTER TABLE "public"."notes" FORCE ROW LEVEL SECURITY',
       'CREATE POLICY "vt_tenant" ON "public"."notes"', 'CREATE POLICY "vt_access" ON "public"."notes"',
       '$vetra_transition$', '$vetra_authz$', 'CREATE TRIGGER', 'ENABLE ALWAYS TRIGGER'].each do |part|
        assert_includes sql, part
      end
      steps = incremental(root).steps.map(&:sql)
      grant = steps.index { |s| s.start_with?('GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE "public"."notes"') }
      # Antes do GRANT já estão instalados RLS, políticas, transições e a revisão. Cada passo tem commit próprio.
      assert_operator grant, :>, steps.rindex { |s| s.start_with?('CREATE POLICY') }
      assert_operator grant, :>, steps.rindex { |s| s.include?('ENABLE ALWAYS TRIGGER') }
      assert_equal steps.size - 1, grant
    end
  end

  def test_false_and_escaped_constants_and_enum_literals_are_safe_and_deterministic
    with_app('blog') do |root, compiler|
      compiler.write
      planner(root).plan
      edit(root, 'app/domains/blog/post.rb') do |s|
        s.sub('  crud', "  boolean :enabled, default: false\n  json :meta, default: { text: \"COPY; set_config('x', 'y');\" }\n  crud")
         .sub('%w[draft published]', '["draft", "published", "a\'b", "a\\\\b"]')
      end
      compiler.write
      planner(root).plan
      sql = incremental(root).steps.map(&:sql).join("\n")
      assert_includes sql, '"enabled" boolean NOT NULL DEFAULT FALSE'
      assert_includes sql, "E'a''b'"
      assert_equal :unchanged, planner(root).plan.status
    end
  end

  def test_transition_function_is_replaced_with_same_signature
    scenario(:transicao) do |root|
      planner(root).plan
      steps = incremental(root).steps
      replacement = steps.find { |s| s.sql.start_with?('CREATE OR REPLACE FUNCTION') }
      assert_includes replacement.sql, 'NEW."closed_at"'
      assert_equal ['nenhum', 'catalogo'], [replacement.lock, replacement.cost]
      refute steps.any? { |s| s.sql.start_with?('CREATE TRIGGER') }
    end
  end

  def test_new_schema_precedes_its_table_and_receives_owner_and_minimum_privileges
    scenario(:schema) do |root|
      planner(root).plan
      sql = incremental(root).steps.map(&:sql)
      assert_operator sql.index('CREATE SCHEMA "archive";'), :<, sql.index { |s| s.start_with?('CREATE TABLE "archive"."notes"') }
      assert_includes sql, 'ALTER SCHEMA "archive" OWNER TO "vetra_owner";'
      assert_includes sql, 'REVOKE ALL ON SCHEMA "archive" FROM PUBLIC, "vetra_app";'
      assert_includes sql, 'GRANT USAGE ON SCHEMA "archive" TO "vetra_app";'
      assert_includes sql, 'ALTER TABLE "archive"."notes" OWNER TO "vetra_owner";'
    end
  end

  def test_replacing_a_generated_trigger_preserves_always_in_the_same_transaction
    scenario(:transicao) do |root, compiler|
      model = Vetra::SQL::Model.new(file: '0001_inicial.json', text: File.read(File.join(root, 'db/models/0001_inicial.json')))
      doc = Vetra::Graph::Data.copy(model.document)
      trigger = doc['state']['statements'].find { |item| item['kind'] == 'trigger' && item['object'].include?('vt_transition_') }
      trigger['sha256'] = '0' * 64
      before = Vetra::SQL::Model.new(file: model.file, text: Vetra::SQL::Model.render(doc))
      schema = Vetra::SQL::Schema.new(compiler.read_artifact.document).generate
      plan = Vetra::SQL::Differ.call(base: before, schema: schema, number: '0002')
      step = plan.steps.find { |item| item.sql.start_with?('CREATE OR REPLACE TRIGGER') }
      assert_includes step.sql, 'ENABLE ALWAYS TRIGGER'
      assert_equal ['ShareRowExclusive', 'catalogo', 'sim'], [step.lock, step.cost, step.transaction]
      assert_equal 2, Vetra::SQL::StatementScanner.statements(step.sql).size
    end
  end

  def test_three_plans_regenerate_the_latest_from_its_actual_base_without_changing_history
    scenario(:indice) do |root, compiler|
      planner(root).plan
      second = %w[db/plans/0002_expand.sql db/models/0002_expand.json].to_h { |p| [p, File.binread(File.join(root, p))] }
      AdditivePlanCases.change(root, :constante)
      compiler.write
      result = planner(root).plan
      assert_equal %w[0001_inicial.sql 0002_expand.sql 0003_expand.sql], result.plans.map(&:file_name)
      assert_equal :unchanged, planner(root).plan.status
      second.each { |p, bytes| assert_equal bytes, File.binread(File.join(root, p)) }
      model = Vetra::SQL::Model.new(file: '0003_expand.json', text: File.read(File.join(root, 'db/models/0003_expand.json')))
      assert_equal '0002_expand.json', model.document.dig('previous', 'file')
      assert_equal 3, model.document['plans'].size
      assert_equal 1, result.plans.last.steps.size
      assert_includes result.plans.last.steps.first.sql, 'ADD COLUMN "score"'
    end
  end

  def refuse_change(code, example: 'blog', prepare: nil)
    with_app(example) do |root, compiler|
      prepare&.call(root)
      compiler.write
      planner(root).plan
      original = Dir.glob(File.join(root, 'db/**/*')).select { |p| File.file?(p) }.to_h { |p| [p, File.binread(p)] }
      yield root
      compiler.write
      assert_graph_error(code) { planner(root).plan }
      assert_equal original.keys.sort, Dir.glob(File.join(root, 'db/**/*')).select { |p| File.file?(p) }.sort
      original.each { |p, bytes| assert_equal bytes, File.binread(p) }
    end
  end

  def test_removal_and_renaming_are_refused_without_partial_artifacts
    refuse_change('db_plan_remove') { |r| edit(r, 'app/domains/blog/post.rb') { |s| s.sub('  index :status, :published_at', '') } }
    refuse_change('db_plan_remove', prepare: ->(r) { edit(r, 'app/domains/blog/post.rb') { |s| s.sub('  crud', "  string :note, optional: true\n  crud") } }) { |r| edit(r, 'app/domains/blog/post.rb') { |s| s.sub('  string :note, optional: true', '') } }
    refuse_change('db_plan_rename') { |r| edit(r, 'app/domains/blog/post.rb') { |s| s.sub('entity :post do', 'entity :post, table: :articles do') } }
    refuse_change('db_plan_rename', prepare: ->(r) { edit(r, 'app/domains/blog/post.rb') { |s| s.sub('  crud', "  string :note, optional: true\n  crud") } }) do |r|
      edit(r, 'app/domains/blog/post.rb') { |s| s.sub('string :note, optional: true', 'string :memo, was: :note, optional: true') }
    end
  end

  def test_type_nullability_default_backfill_enum_and_tenant_have_specific_codes
    refuse_change('db_plan_type') { |r| edit(r, 'app/domains/blog/post.rb') { |s| s.sub('timestamp :published_at, set_by: :publish_post', 'date :published_at, optional: true, set_by: :publish_post') } }
    refuse_change('db_plan_change') { |r| edit(r, 'app/domains/blog/post.rb') { |s| s.sub('string :title, required: true, max: 200', 'string :title, optional: true, max: 200') } }
    ["string :note", "id :editor_id, default: :current_actor"].each do |declaration|
      refuse_change('db_plan_backfill') { |r| edit(r, 'app/domains/blog/post.rb') { |s| s.sub('  crud', "  #{declaration}\n  crud") } }
    end
    refuse_change('db_plan_enum') { |r| edit(r, 'app/domains/blog/post.rb') { |s| s.sub('%w[draft published]', '%w[draft]') .sub('       guarded: { "published" => :publish_post }', '') .sub('default: "draft",', 'default: "draft"') } }
    refuse_change('db_plan_tenant', example: 'mini_crm') do |root|
      write(root, 'app/domains/crm/organization.rb', "entity :organization do\n  string :name\nend\n")
      edit(root, 'config/app.rb') { |s| s.sub('tenant :company', 'tenant :organization') }
      edit(root, 'app/domains/crm/lead.rb') do |s|
        s.sub('tenant :company', 'tenant :organization').sub('belongs_to :company', 'belongs_to :company, same_tenant: true')
         .sub('index :company_id, :status', 'index :organization_id, :status')
      end
    end
  end

  def test_compound_fields_distinguish_declared_renames_and_type_changes_from_removal
    refuse_change('db_plan_rename', example: 'mini_crm') do |root|
      edit(root, 'app/domains/crm/lead.rb') { |s| s.sub('money :valor, optional: true', 'money :total, was: :valor, optional: true') }
    end
    refuse_change('db_plan_type', example: 'mini_crm') do |root|
      edit(root, 'app/domains/crm/lead.rb') { |s| s.sub('money :valor, optional: true', 'decimal :valor, optional: true') }
    end
    prepare_scalar = ->(root) { write(root, 'app/domains/blog/loose.rb', "entity :loose do\n  decimal :budget, optional: true\nend\n") }
    refuse_change('db_plan_type', prepare: prepare_scalar) do |root|
      edit(root, 'app/domains/blog/loose.rb') { |s| s.sub('decimal :budget', 'money :budget') }
    end
  end

  def test_changed_checks_and_untranslated_instructions_are_refused
    refuse_change('db_plan_change') { |r| edit(r, 'app/domains/blog/post.rb') { |s| s.sub('max: 200', 'max: 300') } }
    scenario(:indice) do |root, compiler|
      model = Vetra::SQL::Model.new(file: '0001_inicial.json', text: File.read(File.join(root, 'db/models/0001_inicial.json')))
      doc = Vetra::Graph::Data.copy(model.document)
      doc['state']['statements'].find { |item| item['object'] == 'vetra.current_tenant()' && item['kind'] == 'function' }['sha256'] = '0' * 64
      changed = Vetra::SQL::Model.new(file: model.file, text: Vetra::SQL::Model.render(doc))
      schema = Vetra::SQL::Schema.new(compiler.read_artifact.document).generate
      assert_graph_error('db_plan_statement') { Vetra::SQL::Differ.call(base: changed, schema: schema, number: '0002') }
      %w[vetra_private.vt_keys_active public.posts].each do |object|
        doc = Vetra::Graph::Data.copy(model.document)
        doc['state']['statements'].find { |item| item['object'] == object }['sha256'] = '0' * 64
        changed = Vetra::SQL::Model.new(file: model.file, text: Vetra::SQL::Model.render(doc))
        assert_graph_error('db_plan_statement') { Vetra::SQL::Differ.call(base: changed, schema: schema, number: '0002') }
      end
    end
  end

  def test_a_safe_addition_cannot_hide_a_contract_or_an_assignment_change
    refuse_change('db_plan_type') do |root|
      AdditivePlanCases.change(root, :indice)
      edit(root, 'app/domains/blog/post.rb') { |s| s.sub('timestamp :published_at, set_by: :publish_post', 'date :published_at, optional: true, set_by: :publish_post') }
    end
    prepare_default = ->(root) { AdditivePlanCases.change(root, :constante) }
    refuse_change('db_plan_change', prepare: prepare_default) do |root|
      AdditivePlanCases.change(root, :indice)
      edit(root, 'app/domains/blog/post.rb') { |s| s.sub('integer :score, default: 0', 'integer :score, default: 1') }
    end
    refuse_change('db_plan_remove', example: 'mini_crm') do |root|
      edit(root, 'app/domains/crm/lead.rb') { |s| s.sub('  transitions enforce: :db', '') }
    end
    prepare_table = ->(root) { write(root, 'app/domains/blog/loose.rb', "entity :loose do\n  string :body\nend\n") }
    refuse_change('db_plan_rename', prepare: prepare_table) do |root|
      edit(root, 'app/domains/blog/loose.rb') { |s| s.sub('entity :loose do', 'entity :renamed, was: :loose do') }
    end
  end

  def test_removing_tables_unique_keys_foreign_keys_checks_and_policies_is_contract
    prepare_table = ->(root) { AdditivePlanCases.write(root, 'app/domains/blog/loose.rb', "entity :loose do\n  string :label\nend\n") }
    refuse_change('db_plan_remove', prepare: prepare_table) { |root| FileUtils.rm(File.join(root, 'app/domains/blog/loose.rb')) }
    prepare_unique = ->(root) { AdditivePlanCases.change(root, :unica) }
    refuse_change('db_plan_remove', prepare: prepare_unique) { |root| edit(root, 'app/domains/blog/post.rb') { |s| s.sub('  index :title, unique: true', '') } }
    prepare_fk = ->(root) { AdditivePlanCases.prepare(root, :fk); AdditivePlanCases.change(root, :fk) }
    refuse_change('db_plan_remove', prepare: prepare_fk) { |root| edit(root, 'app/domains/blog/post.rb') { |s| s.sub('belongs_to :category, optional: true', 'id :category_id, optional: true') } }
    refuse_change('db_plan_remove') { |root| edit(root, 'app/domains/blog/post.rb') { |s| s.sub(', max: 200', '') } }
    refuse_change('db_plan_remove', example: 'mini_crm_revendas') do |root|
      edit(root, 'app/domains/crm/roles.rb') { |s| s.sub('can :manage, on: :lead', 'can :read, :create, :update, on: :lead') }
    end
  end

  def test_missing_or_extra_policy_mirrors_refuse_a_pending_plan_without_writing_it
    scenario(:indice) do |root|
      path = File.join(root, Vetra::SQL::Planner::POLICIES)
      original = File.binread(path)
      FileUtils.rm(path)
      assert_graph_error('db_policies_stale') { planner(root).plan }
      refute File.exist?(File.join(root, 'db/plans/0002_expand.sql'))
      File.binwrite(path, original)
      File.write(File.join(root, 'db/policies/extra.sql'), '')
      assert_graph_error('db_policies_stale') { planner(root).plan }
      refute File.exist?(File.join(root, 'db/plans/0002_expand.sql'))
    end
  end
end

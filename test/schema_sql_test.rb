require_relative 'test_helper'

class SchemaSQLTest < GraphTest
  EXAMPLES = %w[mini_crm mini_crm_revendas blog chat].freeze

  def example(name)
    JSON.parse(File.read(File.join(PROJECT, 'examples', name, '.vetra/graph.json')))
  end

  def field(name, type = 'string', **attributes)
    { 'name' => name, 'type' => type.is_a?(Hash) ? type : { 'name' => type },
      'required' => true, 'nullable' => false, 'privacy' => { 'personal' => false } }.merge(attributes.transform_keys(&:to_s))
  end

  def sample(name = 'sample', fields: [])
    source = node(example('blog'), 'entity', 'blog.post')
    source.merge('id' => "blog.#{name}", 'storage' => { 'schema' => 'public', 'table' => "#{name}s", 'primary_key' => ['id'] },
      'fields' => [field('id', { 'name' => 'id', 'entity' => { 'kind' => 'entity', 'id' => "blog.#{name}" } }),
                   field('created_at', 'timestamp', generate: { 'kind' => 'timestamp', 'on' => 'create' }), *fields],
      'relations' => [], 'indexes' => [])
  end

  def document(*entities)
    original = example('blog')
    original['app']['tenant'] = nil
    original['requires'] = %w[vetra.core vetra.timestamps]
    original['nodes'] = [node(original, 'domain'), *(entities.empty? ? [sample] : entities)]
    original
  end

  def generate(doc, **options)
    doc['digest'] = Vetra::Graph::Canonical.digest(doc)
    Vetra::SQL::Schema.new(doc, **options).generate
  end

  def column(result, name, table = result.tables.first)
    table['columns'].find { |entry| entry['name'] == name } || raise('Coluna não encontrada')
  end

  def relation_to(target, local: ['target_id'], remote: ['id'], name: 'target')
    { 'name' => name, 'kind' => 'belongs_to', 'target' => { 'kind' => 'entity', 'id' => "blog.#{target}" },
      'local_fields' => local, 'target_fields' => remote, 'same_tenant' => false }
  end

  EXAMPLES.each do |name|
    define_method("test_#{name}_ddl_matches_the_complete_review_fixture") do
      result = Vetra::SQL::Schema.new(example(name)).generate
      expected = File.read(File.join(PROJECT, 'test/fixtures/sql', "#{name}.sql"))
      assert_equal expected, result.sql
      assert_equal %w[schemas tables foreign_keys], result.blocks.map { |block| block['kind'] }
      assert_equal result.sql, result.blocks.map { |block| block['sql'] }.join
      assert_equal result.tables.size, result.sql.scan('CREATE TABLE ').size
      assert_equal result.tables.sum { |table| table['foreign_keys'].size }, result.blocks.last['statements'].size
    end
  end

  def test_id_uses_uuid_v4_default_only_on_the_primary_key
    result = generate(document(sample(fields: [field('actor_id', 'id')])))
    assert_equal 'uuid', column(result, 'id')['type']
    assert_equal 'pg_catalog.gen_random_uuid()', column(result, 'id')['default']
    assert_nil column(result, 'actor_id')['default']
    assert_equal ['id'], result.tables.first.dig('primary_key', 'columns')
    assert_includes result.sql, '"id" uuid NOT NULL DEFAULT pg_catalog.gen_random_uuid()'
    assert_includes result.sql, 'PRIMARY KEY ("id")'
  end

  def test_string_text_email_and_slug_have_no_implicit_length_or_uniqueness
    result = generate(document(sample(fields: [field('name'), field('body', 'text'), field('email', 'email'),
      field('slug', 'string', generate: { 'kind' => 'slug', 'from' => 'name' })])))
    %w[name body email slug].each { |name| assert_equal 'text', column(result, name)['type'] }
    assert_empty result.tables.first['checks']
    assert_empty result.tables.first['unique_keys']
    assert_nil column(result, 'slug')['default']
    assert_equal 'slug', result.tables.first.dig('assignments', 'slug', 'generate', 'kind')
  end

  def test_lengths_use_character_checks_and_nullable_does_not_follow_required
    result = generate(document(sample(fields: [
      field('label', constraints: { 'min_length' => 2, 'max_length' => 63 }, required: false),
      field('optional', 'text', nullable: true), field('empty', constraints: { 'max_length' => 0 })
    ])))
    refute column(result, 'label')['nullable']
    assert column(result, 'optional')['nullable']
    assert_includes result.sql, '"optional" text,'
    assert_includes result.sql, 'pg_catalog.char_length("label") >= 2'
    assert_includes result.sql, 'pg_catalog.char_length("label") <= 63'
    assert_includes result.sql, 'pg_catalog.char_length("empty") <= 0'
  end

  def test_integer_decimal_boolean_date_timestamp_and_json_types
    fields = [field('count', 'integer'), field('price', { 'name' => 'decimal', 'precision' => 12, 'scale' => 4 }),
              field('enabled', 'boolean'), field('day', 'date'), field('instant', 'timestamp'), field('data', 'json')]
    result = generate(document(sample(fields: fields)))
    { 'count' => 'bigint', 'price' => 'numeric(12, 4)', 'enabled' => 'boolean', 'day' => 'date',
      'instant' => 'timestamp(6) with time zone', 'data' => 'jsonb' }.each do |name, type|
      assert_equal type, column(result, name)['type']
      assert_nil column(result, name)['default']
    end
    assert_includes result.sql, %q{"price" <> 'NaN'::numeric}
  end

  def test_enum_and_money_checks_and_money_index_expansion
    entity = sample(fields: [field('status', { 'name' => 'enum', 'values' => %w[won new] }),
      field('value', { 'name' => 'money', 'precision' => 19, 'scale' => 2 }, nullable: true)])
    entity['indexes'] << { 'name' => 'value_index', 'fields' => ['value'], 'unique' => true }
    result = generate(document(entity))
    assert_equal %w[value_amount value_currency], result.tables.first['columns'].select { |col| col['field'] == 'value' }.map { |col| col['name'] }
    assert_equal 'numeric(19, 2)', column(result, 'value_amount')['type']
    assert column(result, 'value_amount')['nullable']
    assert column(result, 'value_currency')['nullable']
    assert_includes result.sql, %q{"status" IN (E'new', E'won')}
    assert_includes result.sql, '("value_amount" IS NULL) = ("value_currency" IS NULL)'
    assert_includes result.sql, "E'BRL'"
    refute_includes result.sql, "E'BHD'"
    assert_equal [%w[value_amount value_currency]], result.tables.first['unique_keys'].map { |key| key['columns'] }
  end

  def test_money_currency_checks_follow_the_field_scale
    result = generate(document(sample(fields: [field('value', { 'name' => 'money', 'precision' => 12, 'scale' => 4 })])))
    refute column(result, 'value_amount')['nullable']
    refute column(result, 'value_currency')['nullable']
    assert_includes result.sql, "E'BHD'"
    assert_includes result.sql, "E'CLF'"
  end

  def test_literal_defaults_are_typed_and_text_is_escaped_without_session_assumptions
    literal = ->(value) { { 'kind' => 'literal', 'value' => value } }
    fields = [field('label', default: literal.call("O'Reilly\\docs; --")),
      field('count', 'integer', default: literal.call(12)), field('price', { 'name' => 'decimal', 'precision' => 9, 'scale' => 2 }, default: literal.call('-12.30')),
      field('enabled', 'boolean', default: literal.call(false)), field('day', 'date', default: literal.call('2026-11-03')),
      field('instant', 'timestamp', default: literal.call('2026-11-03T12:00:00.123456-03:00')),
      field('actor', 'id', default: literal.call('ABCDEF01-0000-4000-8000-000000000001')),
      field('data', 'json', default: literal.call({ 'z' => "a'b\\c", 'a' => [true, 3] })),
      field('nothing', nullable: true, default: literal.call(nil)),
      field('money', { 'name' => 'money', 'precision' => 19, 'scale' => 2 }, default: literal.call({ 'amount' => '10.20', 'currency' => 'BRL' }))]
    result = generate(document(sample(fields: fields)))
    assert_equal "E'O''Reilly\\\\docs; --'", column(result, 'label')['default']
    assert_equal '12', column(result, 'count')['default']
    assert_equal '-12.30', column(result, 'price')['default']
    assert_equal 'FALSE', column(result, 'enabled')['default']
    assert_equal "E'2026-11-03'::date", column(result, 'day')['default']
    assert_equal "E'2026-11-03T15:00:00.123456Z'::timestamp(6) with time zone", column(result, 'instant')['default']
    assert_equal "E'abcdef01-0000-4000-8000-000000000001'::uuid", column(result, 'actor')['default']
    assert column(result, 'data')['default'].start_with?(%q|E'{"a":[true,3],"z":|)
    assert column(result, 'data')['default'].end_with?('::jsonb')
    assert_equal 'NULL', column(result, 'nothing')['default']
    assert_equal '10.20', column(result, 'money_amount')['default']
    assert_equal "E'BRL'", column(result, 'money_currency')['default']
  end

  def test_context_defaults_and_created_at_remain_assignments_in_the_repository
    result = generate(document(sample(fields: [field('actor', 'id', default: { 'kind' => 'context', 'name' => 'current_actor' }),
      field('tenant_id', 'id', default: { 'kind' => 'context', 'name' => 'current_tenant' })])))
    %w[actor tenant_id created_at].each { |name| assert_nil column(result, name)['default'] }
    assert_equal 'current_tenant', result.tables.first.dig('assignments', 'tenant_id', 'default', 'name')
    assert_equal({ 'kind' => 'timestamp', 'on' => 'create' }, result.tables.first.dig('assignments', 'created_at', 'generate'))
    refute_includes result.sql, 'now()'
    refute_includes result.sql, 'current_setting'
  end

  def test_transition_columns_and_owners_survive_without_claiming_trigger_enforcement
    result = generate(example('mini_crm_revendas'))
    lead = result.tables.find { |table| table['table'] == 'leads' }
    assert_equal 'db', lead.dig('transitions', 'enforce')
    assert_equal 'crm.win_lead', lead.dig('assignments', 'status', 'guarded', 0, 'commands', 0, 'id')
    assert_equal "E'new'", column(result, 'status', lead)['default']
    blog = generate(example('blog'))
    post = blog.tables.find { |table| table['table'] == 'posts' }
    assert column(blog, 'published_at', post)['nullable']
    assert_equal 'blog.publish_post', post.dig('assignments', 'published_at', 'set_by', 0, 'id')
    refute_includes result.sql + blog.sql, 'TRIGGER'
  end

  def test_downcase_is_checked_and_uniqueness_is_explicit_and_deduplicated
    result = generate(example('chat'))
    user = result.tables.find { |table| table['table'] == 'users' }
    assert_includes result.sql, '"email" = pg_catalog.lower("email")'
    assert_equal [['email']], user['unique_keys'].map { |key| key['columns'] }
    entity = sample(fields: [field('email', 'email', constraints: { 'unique' => true })])
    assert_equal [['email']], generate(document(entity)).tables.first['unique_keys'].map { |key| key['columns'] }
  end

  def test_explicit_names_at_63_bytes_are_quoted_and_custom_schemas_are_created_first
    entity = sample(fields: [field('c' * 63)])
    entity['storage'].merge!('schema' => 's' * 63, 'table' => 't' * 63)
    result = generate(document(entity))
    assert_equal ["CREATE SCHEMA \"#{'s' * 63}\";"], result.blocks.first['statements']
    assert_includes result.sql, "\"#{'c' * 63}\" text NOT NULL"
    assert result.tables.first['primary_key']['name'].bytesize <= 63
    assert_operator result.sql.index('CREATE SCHEMA'), :<, result.sql.index('CREATE TABLE')
  end

  def test_oversized_explicit_and_expanded_names_are_rejected
    %w[schema table].each do |part|
      entity = sample
      entity['storage'][part] = 'x' * 64
      assert_graph_error('schema_identifier') { generate(document(entity)) }
    end
    assert_graph_error('schema_identifier') { generate(document(sample(fields: [field('c' * 64)]))) }
    assert_graph_error('schema_identifier') do
      generate(document(sample(fields: [field('m' * 55, { 'name' => 'money', 'precision' => 19, 'scale' => 2 })])))
    end
    entity = sample
    entity['indexes'] << { 'name' => 'x' * 64, 'fields' => ['id'], 'unique' => false }
    assert_graph_error('schema_identifier') { generate(document(entity)) }
  end

  def test_reserved_schemas_and_system_columns_are_rejected
    %w[pg_temp information_schema vetra vetra_private].each do |name|
      entity = sample
      entity['storage']['schema'] = name
      assert_graph_error('schema_reserved') { generate(document(entity)) }
    end
    %w[xmin ctid tableoid].each do |name|
      assert_graph_error('schema_reserved') { generate(document(sample(fields: [field(name)]))) }
    end
  end

  def test_table_money_column_and_index_namespace_collisions_are_rejected
    entity, other = sample, sample('other')
    other['storage']['table'] = entity['storage']['table']
    assert_graph_error('schema_collision') { generate(document(entity, other)) }
    assert_graph_error('schema_collision') do
      generate(document(sample(fields: [field('value', { 'name' => 'money', 'precision' => 19, 'scale' => 2 }), field('value_currency')])))
    end
    entity = sample
    name = generate(document(entity)).tables.first['primary_key']['name']
    other = sample('other')
    other['storage']['table'] = name
    assert_graph_error('schema_collision') { generate(document(entity, other)) }
  end

  def test_derived_name_hash_collision_is_refused_instead_of_adding_an_ordinal
    entity = sample(fields: [field('label', constraints: { 'min_length' => 1, 'max_length' => 10 })])
    Digest::SHA256.stub(:hexdigest, '0' * 64) do
      assert_graph_error('schema_collision') { generate(document(entity)) }
    end
  end

  def test_generated_names_do_not_depend_on_ir_index_names_or_declaration_order
    entity = sample(fields: [field('email', 'email'), field('name')])
    entity['indexes'] = [{ 'name' => 'ordinal_one', 'fields' => ['email'], 'unique' => true }]
    original = generate(document(entity))
    entity['indexes'].first['name'] = 'ordinal_ten'
    entity['fields'].reverse!
    assert_equal original.sql, generate(document(entity)).sql
    assert_equal original.tables, generate(document(entity)).tables
  end

  def test_optional_seller_fk_uses_match_simple_and_tenant_unique_support
    result = generate(example('mini_crm_revendas'))
    lead = result.tables.find { |table| table['table'] == 'leads' }
    key = lead['foreign_keys'].find { |fk| fk['columns'] == %w[company_id seller_id] }
    assert_equal %w[company_id id], key['target_columns']
    assert_equal 'SIMPLE', key['match']
    assert_equal 'NO ACTION', key['on_delete']
    assert_equal 'NO ACTION', key['on_update']
    assert key['deferrable']
    assert_equal 'IMMEDIATE', key['initially']
    assert column(result, 'seller_id', lead)['nullable']
    refute column(result, 'company_id', lead)['nullable']
    user = result.tables.find { |table| table['table'] == 'users' }
    assert_includes user['unique_keys'].map { |unique| unique['columns'] }, %w[company_id id]
    assert_includes result.blocks.last['sql'], 'MATCH SIMPLE ON DELETE NO ACTION ON UPDATE NO ACTION DEFERRABLE INITIALLY IMMEDIATE'
    # A FK e seu índice começam pelo tenant.
    assert_includes lead['indexes'].map { |index| index['columns'] }, %w[company_id seller_id]
  end

  def test_implicit_tenant_foreign_keys_and_explicit_tenant_relation_are_not_lost_or_duplicated
    result = generate(example('mini_crm_revendas'))
    %w[dealers users leads memberships].each do |name|
      table = result.tables.find { |entry| entry['table'] == name }
      assert_equal 1, table['foreign_keys'].count { |key| key['columns'] == ['company_id'] && key['target'] == %w[public companies] }
      assert_equal 'tenant', table['scope']
      assert_equal 'company_id', table['tenant_column']
    end
    simple = generate(example('mini_crm'))
    assert_equal 1, simple.tables.find { |table| table['table'] == 'leads' }['foreign_keys'].size
  end

  def test_tenant_root_is_explicitly_classified_and_global_app_does_not_invent_a_tenant
    root = generate(example('mini_crm')).tables.find { |table| table['table'] == 'companies' }
    assert_equal 'tenant_root', root['scope']
    assert_equal 'id', root['tenant_column']
    assert_empty root['foreign_keys']
    %w[blog chat].each do |name|
      result = generate(example(name))
      assert result.tables.all? { |table| table['scope'] == 'global' && table['tenant_column'].nil? }
      refute_includes result.sql, 'company_id'
      refute_includes result.sql, 'POLICY'
    end
  end

  def test_junctions_and_has_many_do_not_add_duplicate_foreign_keys_or_tables
    crm = generate(example('mini_crm_revendas'))
    assert_equal 5, crm.tables.size
    dealer = crm.tables.find { |table| table['table'] == 'dealers' }
    assert_equal 1, dealer['foreign_keys'].size
    junction = crm.tables.find { |table| table['table'] == 'memberships' }
    assert_equal 3, junction['foreign_keys'].size
    chat = generate(example('chat'))
    assert_equal 4, chat.tables.size
    junction = chat.tables.find { |table| table['table'] == 'room_memberships' }
    assert_equal 2, junction['foreign_keys'].size
    assert_equal [%w[room_id user_id]], junction['unique_keys'].map { |unique| unique['columns'] }
  end

  def test_tenant_support_unique_is_derived_even_if_absent_in_valid_external_ir
    doc = example('mini_crm_revendas')
    doc['nodes'].select { |entry| entry['kind'] == 'entity' }.each { |entity| entity['indexes'].reject! { |index| index['fields'] == %w[company_id id] } }
    result = generate(doc)
    result.tables.select { |table| table['scope'] == 'tenant' }.each do |table|
      assert_includes table['unique_keys'].map { |key| key['columns'] }, %w[company_id id]
      assert table['indexes'].all? { |index| index['columns'].first == 'company_id' }
    end
  end

  def test_cycles_are_created_after_every_table_and_unique_key_and_can_be_deferred
    left, right = sample('left', fields: [field('right_id', 'id')]), sample('right', fields: [field('left_id', 'id')])
    left['relations'] << relation_to('right', local: ['right_id'])
    right['relations'] << relation_to('left', local: ['left_id'])
    result = generate(document(right, left))
    assert_equal %w[lefts rights], result.tables.map { |table| table['table'] }
    assert_equal 2, result.blocks.last['statements'].size
    refute_includes result.blocks[1]['sql'], 'FOREIGN KEY'
    assert_operator result.sql.rindex('CREATE TABLE'), :<, result.sql.index('FOREIGN KEY')
    assert result.tables.all? { |table| table['foreign_keys'].first['deferrable'] }
  end

  def test_nonunique_and_incompatible_foreign_key_targets_are_rejected
    target = sample('target', fields: [field('name')])
    owner = sample(fields: [field('target_id')])
    owner['relations'] << relation_to('target', remote: ['name'])
    assert_graph_error('schema_fk_target') { generate(document(owner, target)) }
    target['indexes'] << { 'name' => 'name_unique', 'fields' => ['name'], 'unique' => true }
    result = generate(document(owner, target))
    assert_equal ['name'], result.tables.find { |table| table['table'] == 'samples' }['foreign_keys'].first['target_columns']
    owner['fields'].find { |entry| entry['name'] == 'target_id' }['type'] = { 'name' => 'integer' }
    assert_graph_error('schema_fk_type') { generate(document(owner, target)) }
  end

  def test_partial_indexes_are_refused_instead_of_silently_changing_uniqueness
    entity = sample
    entity['indexes'] << { 'name' => 'partial', 'fields' => ['id'], 'unique' => true, 'where' => { 'op' => 'true' } }
    assert_graph_error('schema_partial_index') { generate(document(entity)) }
  end

  def test_primary_key_forms_not_supported_by_the_mapping_are_refused
    entity = sample(fields: [field('code')])
    entity['storage']['primary_key'] = ['code']
    assert_graph_error('schema_primary_key') { generate(document(entity)) }
    entity = sample
    entity['fields'].find { |entry| entry['name'] == 'id' }['nullable'] = true
    assert_graph_error('schema_primary_key') { generate(document(entity)) }
  end

  def test_unsupported_length_and_normalization_are_refused
    assert_graph_error('schema_constraints') { generate(document(sample(fields: [field('count', 'integer', constraints: { 'max_length' => 3 })]))) }
    assert_graph_error('schema_normalize') { generate(document(sample(fields: [field('count', 'integer', normalize: ['downcase'])]))) }
  end

  def test_physically_invalid_defaults_are_refused_with_their_own_diagnostic
    cases = [field('actor', 'id', default: { 'kind' => 'literal', 'value' => 'actor-123' }),
      field('day', 'date', default: { 'kind' => 'literal', 'value' => '0000-01-01' }),
      field('instant', 'timestamp', default: { 'kind' => 'literal', 'value' => '2026-11-03T12:00:00' }),
      field('instant', 'timestamp', default: { 'kind' => 'literal', 'value' => '2026-11-03T12:00:00.1234567Z' }),
      field('instant', 'timestamp', default: { 'kind' => 'literal', 'value' => '0001-01-01T00:00:00+03:00' }),
      field('label', constraints: { 'max_length' => 2 }, default: { 'kind' => 'literal', 'value' => 'long' }),
      field('email', 'email', normalize: ['downcase'], default: { 'kind' => 'literal', 'value' => 'UPPER@example.test' })]
    cases.each { |entry| assert_graph_error('schema_default') { generate(document(sample(fields: [entry]))) } }
  end

  def test_postgresql_unrepresentable_nul_literals_are_refused_even_inside_json
    [field('label', default: { 'kind' => 'literal', 'value' => "a\0b" }),
     field('data', 'json', default: { 'kind' => 'literal', 'value' => { "a\0" => 1 } }),
     field('data', 'json', default: { 'kind' => 'literal', 'value' => ["a\0"] }),
     field('status', { 'name' => 'enum', 'values' => ["a\0"] })].each do |entry|
      assert_graph_error('schema_literal') { generate(document(sample(fields: [entry]))) }
    end
  end

  def test_input_is_validated_copied_and_result_is_deeply_frozen_and_repeatable
    doc = document
    doc['digest'] = Vetra::Graph::Canonical.digest(doc)
    generator = Vetra::SQL::Schema.new(doc)
    doc['nodes'].clear
    result = generator.generate
    assert_equal result, generator.generate
    assert Ractor.shareable?(result)
    assert_raises(FrozenError) { result.sql.replace('changed') }
    assert_raises(FrozenError) { result.tables.first['columns'].first['name'].replace('changed') }
    assert_raises(FrozenError) { result.blocks.last['statements'] << 'SQL' }
    assert_raises(FrozenError) { result.tables.first['assignments'].clear }
    doc = example('blog')
    doc['digest'] = 'sha256:' + '0' * 64
    assert_graph_error('digest_mismatch') { Vetra::SQL::Schema.new(doc).generate }
  end

  def test_all_examples_are_deterministic_across_node_field_relation_and_index_order
    EXAMPLES.each do |name|
      doc = example(name)
      expected = generate(doc)
      doc['nodes'].reverse!
      doc['nodes'].select { |entry| entry['kind'] == 'entity' }.each do |entity|
        %w[fields relations indexes].each { |key| entity[key].reverse! }
        entity['fields'].each { |entry| entry['type']['values']&.reverse! }
      end
      actual = generate(doc)
      assert_equal expected.sql, actual.sql, name
      assert_equal expected.tables, actual.tables, name
    end
  end

  def test_older_ir_is_mapped_without_retroactively_adding_created_at
    %w[blog mini-crm].each do |name|
      doc = JSON.parse(File.read(File.join(PROJECT, 'docs/ir/exemplos', "#{name}.v0.1.json")))
      result = Vetra::SQL::Schema.new(doc).generate
      assert_equal '0.1', doc['ir_version']
      refute_includes result.sql, 'created_at'
    end
  end
end

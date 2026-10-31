require_relative 'test_helper'

class DiffTest < GraphTest
  def setup
    @before = Vetra::Graph::Canonical.parse(File.read(File.join(PROJECT, 'examples/blog/.vetra/graph.json')))
    @after = Vetra::Graph::Data.copy(@before)
  end

  def compare
    @before['digest'] = Vetra::Graph::Canonical.digest(@before)
    @after['digest'] = Vetra::Graph::Canonical.digest(@after)
    Vetra::Graph::Diff.new.compare(@before, @after)
  end

  def change_at(report, kind, id, path)
    report.data['changes'].find { |change| change.values_at('kind', 'id', 'path') == [kind, id, path] } || raise("Mudança não encontrada: #{kind} #{id} #{path}")
  end

  def custom_input(document = @after)
    node(document, 'contract', 'blog.publish_post.input')
  end

  def text_field(name, required: false)
    { 'name' => name, 'type' => { 'name' => 'string' }, 'required' => required, 'nullable' => false, 'privacy' => { 'personal' => false } }
  end

  def rename_node(document, kind, old_id, new_id)
    target = node(document, kind, old_id)
    target['id'] = new_id
    target['previous_ids'] = [old_id]
    target['implementation']['ref'] = "#{new_id}#call" if target.dig('implementation', 'kind') == 'ruby'
    Vetra::Graph::Data.references(document) do |reference, _path|
      reference['id'] = new_id if reference == { 'kind' => kind, 'id' => old_id }
    end
    target
  end

  def test_identical_graphs_are_unchanged_and_inputs_are_not_mutated
    original = Vetra::Graph::Canonical.dump(@before)
    report = compare
    refute report.changed?
    refute report.breaking?
    assert_empty report.data['changes']
    assert_includes report.to_text, 'Sem alterações'
    assert_equal original, Vetra::Graph::Canonical.dump(@before)
    assert_raises(FrozenError) { report.data['changes'] << {} }
    assert_equal report.data, JSON.parse(report.to_json)
  end

  def test_node_field_and_reference_order_are_ignored_but_enum_order_is_preserved
    @after['nodes'].reverse!
    @after['inputs'].reverse!
    @after['nodes'].each do |entry|
      %w[fields uses reads actions].each { |key| entry[key].reverse! if entry[key].is_a?(Array) }
    end
    refute compare.changed?
    status = node(@after, 'entity')['fields'].find { |field| field['name'] == 'status' }
    status['type']['values'].reverse!
    report = compare
    change = change_at(report, 'entity', 'blog.post', '/fields/status/type')
    assert_equal 'review', change['impact']
    assert_equal %w[draft published], change['before']['values']
    assert_equal %w[published draft], change['after']['values']
  end

  def test_positional_index_keys_and_literal_arrays_are_not_treated_as_sets
    node(@after, 'entity')['indexes'].first['fields'].reverse!
    report = compare
    assert_equal ['storage'], change_at(report, 'entity', 'blog.post', '/indexes/posts_idx_1')['categories']
    node(@before, 'policy')['predicate'] = { 'op' => 'eq', 'left' => { 'kind' => 'field', 'path' => ['title'] }, 'right' => { 'kind' => 'literal', 'value' => %w[a b] } }
    node(@after, 'policy')['predicate'] = Vetra::Graph::Data.copy(node(@before, 'policy')['predicate'])
    node(@after, 'policy')['predicate']['right']['value'].reverse!
    report = compare
    assert_equal 'indeterminate', change_at(report, 'policy', node(@after, 'policy')['id'], '/predicate')['permission_impact']
  end

  def test_only_source_and_build_changes_remain_metadata_and_code_is_not_certified_equivalent
    node(@after, 'entity')['source']['line'] += 1
    @after['producer']['version'] = '0.1.0-alpha.2'
    @after['annotations'] = { 'example.note' => 'review info' }
    implementation = node(@after, 'command', 'blog.publish_post')['implementation']
    implementation['digest'] = 'sha256:' + '1' * 64
    @after['inputs'].find { |input| input['path'] == implementation['path'] }['digest'] = implementation['digest']
    report = compare
    assert report.changed?
    refute report.breaking?
    assert report.data['changes'].all? { |change| change['impact'] == 'metadata' }
    assert_includes report.to_text, 'não avalia equivalência do código Ruby'
    assert_equal 0, report.data.dig('summary', 'requires_review')
  end

  def test_policy_changes_show_both_sides_and_never_claim_access_direction
    policy = node(@after, 'policy')
    policy['actions'].delete('delete')
    report = compare
    change = change_at(report, 'policy', policy['id'], '/actions')
    assert_equal 'indeterminate', change['permission_impact']
    assert change['requires_review']
    assert_includes change['before'], 'delete'
    refute_includes change['after'], 'delete'
    assert_includes report.to_text, 'IMPACTO DE PERMISSÃO INDETERMINADO'
    assert_includes report.to_text, 'antes:'
    assert_includes report.to_text, 'depois:'
    refute report.breaking?
  end

  def test_policy_and_anonymous_role_additions_are_flagged_for_review
    role = Vetra::Graph::Data.copy(node(@after, 'role')).merge('id' => 'blog.visitor', 'anonymous' => true)
    policy = Vetra::Graph::Data.copy(node(@after, 'policy')).merge('id' => 'blog.visitor_posts', 'role' => { 'kind' => 'role', 'id' => role['id'] })
    @after['nodes'].concat([role, policy])
    report = compare
    %w[role policy].each do |kind|
      change = report.data['changes'].find { |entry| entry['kind'] == kind && entry['change'] == 'added' }
      assert_equal 'additive', change['impact']
      assert_equal 'indeterminate', change['permission_impact']
      assert change['requires_review']
    end
  end

  def test_required_input_addition_breaks_but_optional_input_addition_is_additive
    custom_input['fields'] << text_field('reason')
    report = compare
    assert_equal 'additive', change_at(report, 'contract', custom_input['id'], '/fields/reason')['impact']
    refute report.breaking?
    custom_input['fields'].last['required'] = true
    report = compare
    assert_equal 'breaking', change_at(report, 'contract', custom_input['id'], '/fields/reason')['impact']
    assert report.breaking?
  end

  def test_requiredness_and_nullability_respect_input_and_output_direction
    field = custom_input['fields'].first
    field['required'] = false
    assert_equal 'additive', change_at(compare, 'contract', custom_input['id'], '/fields/post_id/required')['impact']
    field['required'] = true
    field['nullable'] = true
    assert_equal 'additive', change_at(compare, 'contract', custom_input['id'], '/fields/post_id/nullable')['impact']
    output = node(@after, 'contract', 'blog.post.record')
    output['fields'].find { |item| item['name'] == 'title' }['nullable'] = true
    assert_equal 'breaking', change_at(compare, 'contract', output['id'], '/fields/title/nullable')['impact']
    output['fields'].find { |item| item['name'] == 'title' }['required'] = false
    assert_equal 'breaking', change_at(compare, 'contract', output['id'], '/fields/title/required')['impact']
  end

  def test_input_and_output_field_removal_and_type_change_break
    custom_input['fields'] << text_field('reason')
    @before = Vetra::Graph::Data.copy(@after)
    custom_input['fields'].pop
    assert_equal 'breaking', change_at(compare, 'contract', custom_input['id'], '/fields/reason')['impact']
    output = node(@after, 'contract', 'blog.post.record')
    output['fields'].reject! { |field| field['name'] == 'title' }
    assert_equal 'breaking', change_at(compare, 'contract', output['id'], '/fields/title')['impact']
    output['fields'].find { |field| field['name'] == 'author_id' }['type'] = { 'name' => 'string' }
    assert_equal 'breaking', change_at(compare, 'contract', output['id'], '/fields/author_id/type')['impact']
  end

  def test_enum_widening_in_input_is_additive_and_in_output_can_break_consumers
    custom_input['fields'] << text_field('reason').merge('type' => { 'name' => 'enum', 'values' => %w[a b] })
    @before = Vetra::Graph::Data.copy(@after)
    custom_input['fields'].last['type']['values'] << 'c'
    assert_equal 'additive', change_at(compare, 'contract', custom_input['id'], '/fields/reason/type')['impact']
    custom_input['fields'].last['type']['values'].delete('a')
    assert_equal 'breaking', change_at(compare, 'contract', custom_input['id'], '/fields/reason/type')['impact']
    output = node(@after, 'contract', 'blog.post.record')
    output['fields'].find { |field| field['name'] == 'status' }['type']['values'] << 'archived'
    assert_equal 'breaking', change_at(compare, 'contract', output['id'], '/fields/status/type')['impact']
  end

  def test_input_length_constraints_narrow_and_output_constraints_widen
    custom_input['fields'] << text_field('reason').merge('constraints' => { 'max_length' => 100 })
    @before = Vetra::Graph::Data.copy(@after)
    custom_input['fields'].last['constraints']['max_length'] = 50
    assert_equal 'breaking', change_at(compare, 'contract', custom_input['id'], '/fields/reason/constraints')['impact']
    output = node(@after, 'contract', 'blog.post.record')
    title = output['fields'].find { |field| field['name'] == 'title' }
    title['constraints'] = { 'max_length' => 100 }
    node(@before, 'contract', 'blog.post.record')['fields'].find { |field| field['name'] == 'title' }['constraints'] = { 'max_length' => 50 }
    assert_equal 'breaking', change_at(compare, 'contract', output['id'], '/fields/title/constraints')['impact']
  end

  def test_explicit_node_rename_normalizes_typed_references_without_inventing_more_changes
    renamed = rename_node(@after, 'contract', 'blog.post.record', 'blog.post.result')
    report = compare
    changes = report.data['changes'].reject { |change| change['impact'] == 'metadata' }
    assert_equal 1, changes.size
    assert_equal ['renamed', 'blog.post.result', 'blog.post.record', 'blog.post.result'], changes.first.values_at('change', 'id', 'before', 'after')
    assert report.breaking?
    refute renamed.frozen?
  end

  def test_explicit_field_rename_and_absence_of_hint_have_different_results
    custom_input['fields'] << text_field('reason')
    @before = Vetra::Graph::Data.copy(@after)
    custom_input['fields'].last.merge!('name' => 'note', 'previous_names' => ['reason'])
    change = change_at(compare, 'contract', custom_input['id'], '/fields/note/name')
    assert_equal 'renamed', change['change']
    assert_equal 'breaking', change['impact']
    custom_input['fields'].last.delete('previous_names')
    report = compare
    assert_equal 'removed', change_at(report, 'contract', custom_input['id'], '/fields/reason')['change']
    assert_equal 'added', change_at(report, 'contract', custom_input['id'], '/fields/note')['change']
  end

  def test_matching_two_previous_nodes_is_an_ambiguous_merge_not_a_rename
    first = Vetra::Graph::Data.copy(custom_input).merge('id' => 'blog.unused_one')
    second = Vetra::Graph::Data.copy(custom_input).merge('id' => 'blog.unused_two')
    @before['nodes'].concat([first, second])
    @after['nodes'] << Vetra::Graph::Data.copy(first).merge('id' => 'blog.merged', 'previous_ids' => %w[blog.unused_one blog.unused_two])
    assert_graph_error('diff_rename_ambiguous') { compare }
  end

  def test_capabilities_transitions_privacy_routes_and_isolation_are_visible
    command = node(@after, 'command', 'blog.publish_post')
    command['uses'].reject! { |reference| reference['id'] == 'blog.clock' }
    node(@after, 'entity')['transitions']['enforce'] = 'db'
    node(@after, 'contract', 'blog.post.record')['fields'].find { |field| field['name'] == 'title' }['privacy'] = { 'personal' => true, 'classification' => 'personal' }
    route = node(@after, 'route', 'blog.publish_post.http_1')
    route['config']['path'] = '/posts/:post_id/publish_now'
    report = compare
    assert_equal ['capabilities'], change_at(report, 'command', command['id'], '/uses')['categories']
    assert_equal ['transitions'], change_at(report, 'entity', 'blog.post', '/transitions')['categories']
    assert_equal ['privacy'], change_at(report, 'contract', 'blog.post.record', '/fields/title/privacy')['categories']
    assert_equal 'indeterminate', change_at(report, 'route', route['id'], '/config')['permission_impact']
    assert report.breaking?
  end

  def test_handler_calls_are_a_permission_change_and_a_handler_without_calls_is_not
    before = Vetra::Graph::Canonical.parse(File.read(File.join(PROJECT, 'examples/mini_crm/.vetra/graph.json')))
    after = Vetra::Graph::Data.copy(before)
    node(after, 'handler', 'crm.notify_sales')['calls'] << { 'kind' => 'command', 'id' => 'crm.win_lead' }
    before['digest'] = Vetra::Graph::Canonical.digest(before)
    after['digest'] = Vetra::Graph::Canonical.digest(after)
    report = Vetra::Graph::Diff.new.compare(before, after)
    change = change_at(report, 'handler', 'crm.notify_sales', '/calls')
    assert_equal ['permissions'], change['categories']
    assert_equal 'review', change['impact']
    assert change['requires_review']
    [[], [{ 'kind' => 'command', 'id' => 'crm.win_lead' }]].each do |calls|
      added = Vetra::Graph::Data.copy(before)
      handler = Vetra::Graph::Data.copy(node(added, 'handler', 'crm.notify_sales')).merge('id' => 'crm.notify_other', 'calls' => calls)
      handler['implementation']['ref'] = 'crm.notify_other#call' if handler.dig('implementation', 'kind') == 'ruby'
      added['nodes'] << handler
      added['digest'] = Vetra::Graph::Canonical.digest(added)
      categories = change_at(Vetra::Graph::Diff.new.compare(before, added), 'handler', 'crm.notify_other', '/')['categories']
      assert_equal !calls.empty?, categories.include?('permissions')
    end
  end

  def test_removing_unused_query_is_breaking_and_new_surface_is_reviewable
    @after['nodes'].reject! { |entry| (entry['kind'] == 'query' && entry['id'] == 'blog.find_post') || entry['generated_from'] == { 'kind' => 'query', 'id' => 'blog.find_post' } }
    report = compare
    assert_equal 'breaking', change_at(report, 'query', 'blog.find_post', '/')['impact']
    @after = Vetra::Graph::Data.copy(@before)
    route = Vetra::Graph::Data.copy(node(@after, 'route', 'blog.publish_post.http_1')).merge('id' => 'blog.publish_post.cli', 'surface' => 'cli', 'config' => { 'name' => 'publish' })
    @after['nodes'] << route
    change = change_at(compare, 'route', route['id'], '/')
    assert_includes change['categories'], 'surface'
    assert change['requires_review']
  end

  def test_absent_default_and_literal_null_are_distinct
    custom_input['fields'] << text_field('reason').merge('nullable' => true)
    @before = Vetra::Graph::Data.copy(@after)
    custom_input['fields'].last['default'] = { 'kind' => 'literal', 'value' => nil }
    change = change_at(compare, 'contract', custom_input['id'], '/fields/reason/default')
    refute change['before_present']
    assert change['after_present']
    assert_nil change['before']
    assert_equal({ 'kind' => 'literal', 'value' => nil }, change['after'])
  end

  def test_invalid_unknown_and_tampered_graphs_cannot_receive_a_report
    @after['ir_version'] = '0.2'
    error = assert_graph_error('ir_version') { compare }
    assert_includes error.message, 'Grafo posterior'
    @after['ir_version'] = '0.1'
    @before['requires'] << 'vetra.live'
    error = assert_graph_error('ir_feature') { compare }
    assert_includes error.message, 'Grafo anterior'
    @before['requires'].pop
    @after['digest'] = 'sha256:' + '0' * 64
    assert_graph_error('digest_mismatch') { Vetra::Graph::Diff.new.compare(@before, @after) }
  end

  def test_report_is_deterministic_and_diff_instance_can_be_reused
    node(@after, 'policy')['actions'].delete('delete')
    first = compare
    @before['digest'] = Vetra::Graph::Canonical.digest(@before)
    @after['digest'] = Vetra::Graph::Canonical.digest(@after)
    differ = Vetra::Graph::Diff.new
    assert_equal first.to_json, differ.compare(@before, @after).to_json
    assert_equal first.to_json, differ.compare(@before, @after).to_json
  end

  def test_shared_input_and_output_contract_uses_the_stricter_direction
    reference = { 'kind' => 'contract', 'id' => custom_input['id'] }
    node(@before, 'command', 'blog.publish_post')['output'] = Vetra::Graph::Data.copy(reference)
    node(@after, 'command', 'blog.publish_post')['output'] = reference
    custom_input['fields'].first['nullable'] = true
    assert_equal 'breaking', change_at(compare, 'contract', custom_input['id'], '/fields/post_id/nullable')['impact']
  end

  def test_required_event_payload_addition_is_breaking_for_persisted_history
    field = text_field('note', required: true)
    node(@after, 'entity')['fields'] << field.merge('default' => { 'kind' => 'literal', 'value' => 'new' })
    payload = node(@after, 'contract', 'blog.post.published.payload')
    payload['fields'] << field
    node(@after, 'command', 'blog.publish_post')['emits'].first['fields'] << 'note'
    assert_equal 'breaking', change_at(compare, 'contract', payload['id'], '/fields/note')['impact']
  end

  def test_enum_group_changes_are_not_hidden_by_an_input_value_addition
    type = { 'name' => 'enum', 'values' => %w[a b], 'groups' => { 'closed' => ['b'] } }
    custom_input['fields'] << text_field('reason').merge('type' => type)
    @before = Vetra::Graph::Data.copy(@after)
    type['values'] << 'c'
    type['groups']['closed'] = ['c']
    assert_equal 'review', change_at(compare, 'contract', custom_input['id'], '/fields/reason/type')['impact']
    type['values'].delete('a')
    assert_equal 'breaking', change_at(compare, 'contract', custom_input['id'], '/fields/reason/type')['impact']
  end

  def test_ambiguous_field_rename_is_rejected
    custom_input['fields'].concat([text_field('reason'), text_field('comment')])
    @before = Vetra::Graph::Data.copy(@after)
    custom_input['fields'].reject! { |field| %w[reason comment].include?(field['name']) }
    custom_input['fields'] << text_field('note').merge('previous_names' => %w[reason comment])
    assert_graph_error('diff_rename_ambiguous') { compare }
  end

  def test_identity_includes_kind_when_two_nodes_have_the_same_id
    contract = Vetra::Graph::Data.copy(node(@before, 'contract', 'blog.post.record')).merge('id' => 'blog.post')
    @before['nodes'] << contract
    @after['nodes'] << Vetra::Graph::Data.copy(contract)
    node(@after, 'contract', 'blog.post')['fields'].find { |field| field['name'] == 'title' }['nullable'] = true
    report = compare
    assert_equal 1, report.data['changes'].size
    assert_equal ['contract', 'blog.post'], report.data['changes'].first.values_at('kind', 'id')
  end

  def test_text_output_highlights_personal_data_even_when_the_field_addition_is_structural
    custom_input['fields'] << text_field('email').merge('privacy' => { 'personal' => true, 'classification' => 'personal' })
    report = compare
    change = change_at(report, 'contract', custom_input['id'], '/fields/email')
    assert_equal 'additive', change['impact']
    assert change['requires_review']
    assert_includes report.to_text, 'PRIVACIDADE'
    assert_includes report.to_text, 'REVISÃO NECESSÁRIA'
    assert_includes report.to_text, '"personal":true'
    assert_includes report.to_text, 'antes: (ausente)'
  end
end

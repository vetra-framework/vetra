require_relative 'test_helper'

class ValidatorTest < GraphTest
  def setup
    @document = Vetra::Graph::Canonical.parse(File.read(File.join(PROJECT, 'docs/ir/exemplos/mini-crm.v0.1.json')))
  end

  def validate
    @document['digest'] = Vetra::Graph::Canonical.digest(@document)
    Vetra::Graph::Validator.new.validate!(@document)
  end

  def lead
    node(@document, 'entity', 'crm.lead')
  end

  def test_future_versions_features_and_unknown_properties_are_rejected
    %w[0.2 1.0].each do |version|
      original = @document['ir_version']
      @document['ir_version'] = version
      assert_graph_error('ir_version') { validate }
      @document['ir_version'] = original
    end
    @document['requires'] << 'vetra.live'
    assert_graph_error('ir_feature') { validate }
    @document['requires'].pop
    lead['disable_rls'] = true
    assert_graph_error('schema') { validate }
  end

  def test_unknown_nodes_and_wrong_reference_kinds_are_rejected
    node(@document, 'query')['kind'] = 'future_query'
    assert_graph_error('node_kind') { validate }
    node(@document, 'future_query')['kind'] = 'query'
    node(@document, 'command')['uses'].first['kind'] = 'entity'
    assert_graph_error('schema') { validate }
  end

  def test_dangling_references_are_diagnosed_with_origin_and_json_pointer
    node(@document, 'command')['uses'].first['id'] = 'crm.missing'
    error = assert_graph_error('reference_missing') { validate }
    diagnostic = error.diagnostics.find { |item| item.code == 'reference_missing' }
    assert_match %r{\A/nodes/\d+/uses/0\z}, diagnostic.pointer
    assert_equal 'app/domains/crm/win_lead.rb', diagnostic.source['path']
  end

  def test_application_tenant_reference_must_exist
    @document['app']['tenant']['entity']['id'] = 'crm.missing'
    assert_graph_error('reference_missing') { validate }
  end

  def test_duplicate_id_namespace_and_historical_collisions_are_rejected
    duplicate = Vetra::Graph::Data.copy(lead)
    duplicate['source']['line'] = 2
    @document['nodes'] << duplicate
    assert_graph_error('duplicate_id') { validate }
    @document['nodes'].pop
    target = lead
    target['id'] = 'other.lead'
    assert_graph_error('node_namespace') { validate }
    target['id'] = 'crm.lead'
    lead['previous_ids'] = ['crm.company']
    assert_graph_error('identity_rename') { validate }
  end

  def test_duplicate_field_names_and_invalid_defaults_are_rejected
    duplicate = Vetra::Graph::Data.copy(lead['fields'].first)
    duplicate['nullable'] = !duplicate['nullable']
    lead['fields'] << duplicate
    assert_graph_error('duplicate_field') { validate }
    lead['fields'].pop
    status = lead['fields'].find { |field| field['name'] == 'status' }
    status['default']['value'] = 'won'
    assert_graph_error('guard_default') { validate }
    status['default']['value'] = 'missing'
    assert_graph_error('field_default') { validate }
  end

  def test_exact_money_precision_and_nulllability_are_checked
    money = lead['fields'].find { |field| field['name'] == 'valor' }
    money['default'] = { 'kind' => 'literal', 'value' => { 'amount' => '1.001', 'currency' => 'BRL' } }
    assert_graph_error('field_default') { validate }
    money['default']['value']['amount'] = '1.00'
    assert validate
    money['nullable'] = false
    money['default']['value'] = nil
    assert_graph_error('field_default') { validate }
  end

  def fresh_document
    Vetra::Graph::Canonical.parse(File.read(File.join(PROJECT, 'docs/ir/exemplos/mini-crm.v0.1.json')))
  end

  # ADR-001, critério 1: a falta de uma propriedade obrigatória falha estruturalmente, no envelope e nos nós.
  def test_missing_required_properties_fail_structurally
    {
      'fields da entidade' => ->(document) { node(document, 'entity', 'crm.lead').delete('fields') },
      'app na raiz' => ->(document) { document.delete('app') },
      'authorize do comando' => ->(document) { node(document, 'command', 'crm.win_lead').delete('authorize') }
    }.each do |label, remove|
      @document = fresh_document
      remove.call(@document)
      error = assert_raises(Vetra::Graph::Error, label) { validate }
      assert_includes error.diagnostics.map(&:code), 'schema', label
    end
  end

  # ADR-001, critério 1: decimal e money só aceitam o valor como string. Um número JSON falha estruturalmente
  # (inteiro) ou já na camada canônica (ponto flutuante), e o mesmo valor em string é aceito.
  def test_decimal_and_money_literals_must_not_be_json_numbers
    field = lead['fields'].find { |item| item['name'] == 'valor' }
    field['default'] = { 'kind' => 'literal', 'value' => { 'amount' => 12, 'currency' => 'BRL' } }
    assert_graph_error('schema') { validate }
    field['default']['value']['amount'] = '12.00'
    assert validate
    field['type'] = { 'name' => 'decimal', 'precision' => 12, 'scale' => 2 }
    field['default'] = { 'kind' => 'literal', 'value' => 12 }
    assert_graph_error('schema') { validate }
    field['default']['value'] = 12.5
    assert_graph_error('invalid_data') { validate }
    field['default']['value'] = '12.00'
    assert validate
  end

  # ADR-001, critério 1: o schema da IR é um documento válido no Draft 2020-12. A segunda verificação mostra que o
  # metaschema recusa de fato um schema inválido, senão a primeira passaria sem testar nada.
  def test_schema_is_a_valid_draft_2020_12_document
    schema = JSON.parse(File.read(Vetra::Graph::Schema::PATH, encoding: Encoding::UTF_8))
    assert_equal 'https://json-schema.org/draft/2020-12/schema', schema['$schema']
    assert JSONSchemer.valid_schema?(schema)
    refute JSONSchemer.valid_schema?(schema.merge('type' => 'nonexistent_type')), 'o metaschema deveria recusar'
  end

  def test_field_presence_is_independent_of_nullability
    field = lead['fields'].find { |item| item['name'] == 'email' }
    field['required'] = true
    field['nullable'] = true
    assert validate
    field.delete('required')
    assert_graph_error('schema') { validate }
  end

  def test_unknown_predicates_paths_and_missing_authz_dependencies_are_rejected
    policy = node(@document, 'policy')
    policy['predicate'] = { 'op' => 'ruby', 'code' => 'true' }
    assert_graph_error('schema') { validate }
    policy['predicate'] = { 'op' => 'eq', 'left' => { 'kind' => 'field', 'path' => ['nonexistent'] }, 'right' => { 'kind' => 'literal', 'value' => 1 } }
    assert_graph_error('predicate_field') { validate }
    policy['predicate']['left']['path'] = ['company', 'name']
    assert_graph_error('policy_reads') { validate }
    policy['reads'] << { 'kind' => 'entity', 'id' => 'crm.company' }
    assert validate
  end

  def test_unmapped_actor_attributes_do_not_gain_implicit_trust
    node(@document, 'policy')['predicate'] = { 'op' => 'eq', 'left' => { 'kind' => 'field', 'path' => ['id'] }, 'right' => { 'kind' => 'actor', 'path' => ['company_id'] } }
    assert_graph_error('actor_binding') { validate }
  end

  def test_tenant_and_composite_relation_requirements_are_checked
    lead['tenant'] = nil
    assert_graph_error('tenant_missing') { validate }
    lead['tenant'] = Vetra::Graph::Data.copy(@document['app']['tenant'])
    lead['relations'].first['same_tenant'] = true
    assert_graph_error('same_tenant') { validate }
  end

  def test_external_command_capability_and_writable_query_are_rejected
    command = node(@document, 'command')
    command['uses'] = [{ 'kind' => 'capability', 'id' => 'crm.mailer' }]
    assert_graph_error('capability_boundary') { validate }
    node(@document, 'query')['uses'] = [{ 'kind' => 'capability', 'id' => 'crm.leads' }]
    assert_graph_error('capability_boundary') { validate }
  end

  def test_handler_cannot_write_by_repository
    node(@document, 'handler')['uses'] = [{ 'kind' => 'capability', 'id' => 'crm.leads' }]
    assert_graph_error('capability_boundary') { validate }
  end

  def test_payload_type_and_privacy_must_match_projection
    payload = node(@document, 'contract', 'crm.won_payload')
    payload['fields'].first['type'] = { 'name' => 'string' }
    assert_graph_error('event_payload') { validate }
  end

  def test_http_methods_and_webhook_idempotency_are_checked
    route = node(@document, 'route')
    route['config']['method'] = 'GET'
    assert_graph_error('route_target') { validate }
    route['config']['method'] = 'POST'
    route['surface'] = 'webhook'
    assert_graph_error('webhook_idempotency') { validate }
    route['idempotency'] = 'required'
    assert validate
  end

  def test_ambiguous_parameter_names_collide
    route = node(@document, 'route')
    duplicate = Vetra::Graph::Data.copy(route)
    duplicate['id'] = 'crm.other_route'
    @document['nodes'] << duplicate
    assert_graph_error('route_collision') { validate }
  end

  def test_manifest_origin_and_implementation_hash_must_agree
    node(@document, 'command')['source']['path'] = 'app/undeclared.rb'
    assert_graph_error('source_manifest') { validate }
    node(@document, 'command')['source']['path'] = 'app/domains/crm/win_lead.rb'
    node(@document, 'command')['implementation']['digest'] = 'sha256:' + '1' * 64
    assert_graph_error('implementation_manifest') { validate }
  end

  def test_declared_domain_dependencies_and_cycles_are_checked
    domain = node(@document, 'domain')
    other = Vetra::Graph::Data.copy(domain).merge('id' => 'identity', 'depends_on' => [{ 'kind' => 'domain', 'id' => 'crm' }])
    @document['nodes'] << other
    domain['depends_on'] = [{ 'kind' => 'domain', 'id' => 'identity' }]
    assert_graph_error('domain_cycle') { validate }
    other['depends_on'] = []
    assert validate
    other['generated_from'] = { 'kind' => 'entity', 'id' => 'crm.company' }
    assert_graph_error('domain_dependency') { validate }
  end

  def test_mutating_policy_invalidates_digest
    node(@document, 'policy')['actions'] << 'delete'
    assert_graph_error('digest_mismatch') { Vetra::Graph::Validator.new.validate!(@document) }
  end

  def test_annotations_do_not_introduce_graph_edges
    @document['annotations']['example.future'] = { 'kind' => 'entity', 'id' => 'future.nonexistent' }
    assert validate
  end
end

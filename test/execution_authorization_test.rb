require_relative 'test_helper'
require 'vetra/execution'

class ExecutionAuthorizationTest < GraphTest
  def id(number) = format('00000000-0000-4000-8000-%012x', number)
  def tenant = id(1)
  def actor = id(2)

  def document(example)
    Vetra::Graph::Data.copy(Vetra::Graph::Compiler.new(root: File.join(PROJECT, 'examples', example)).read_artifact.document)
  end

  def evaluator(example = 'mini_crm_revendas')
    Vetra::Execution::Authorization.new(document(example))
  end

  def context(operation, example: 'mini_crm_revendas', actor_id: actor, tenant_id: tenant, **extra)
    scoped = example.start_with?('mini_crm')
    Vetra::Data::Context.new(scope: scoped ? :tenant : :global, tenant_id: scoped ? tenant_id : nil,
                            actor_id: actor_id, op_id: id(3), cmd: operation, **extra)
  end

  def records
    {
      'crm.lead' => [10, 11, 12].map.with_index do |number, index|
        { id: id(number), company_id: index == 2 ? id(99) : tenant, dealer_id: id(20 + index),
          name: 'Cliente', seller_id: nil, email: nil, status: 'new', valor: nil }
      end,
      'crm.dealer' => [20, 21, 22].map.with_index do |number, index|
        { id: id(number), company_id: index == 2 ? id(99) : tenant, name: 'Revenda' }
      end,
      'crm.membership' => [
        { id: id(30), company_id: tenant, dealer_id: id(20), user_id: actor, role: 'gerente' },
        { id: id(31), company_id: tenant, dealer_id: id(21), user_id: actor, role: 'vendedor' },
        { id: id(32), company_id: id(99), dealer_id: id(22), user_id: actor, role: 'gerente' }
      ]
    }
  end

  def check(engine, operation, input, roles: [], facts: records, example: 'mini_crm_revendas',
            ctx: nil, revision: 4, reader: ->(_context) { 4 }, fields: nil)
    ctx ||= context(operation, example: example)
    snapshot = engine.snapshot(context: ctx, roles: roles, revision: revision, records: facts)
    engine.check(operation, input: input, context: ctx, snapshot: snapshot, current_revision: reader, fields: fields)
  end

  def assert_denied(code, result)
    refute result.allowed?
    assert_equal code, result.code
    assert_nil result.input
    assert_empty result.policy_ids
    assert result.diagnostics.all? { |diagnostic| diagnostic.severity == :error }
  end

  def test_valid_inputs_from_all_four_real_graphs_are_immutable_and_keep_optional_absence
    %w[mini_crm mini_crm_revendas].each do |example|
      input = { name: +'Cliente', status: 'contacted', valor: { amount: '123.45' }, email: nil }
      input[:dealer_id] = id(20) if example.end_with?('revendas')
      validated = evaluator(example).validate_input('crm.create_lead', input)
      assert_equal 'contacted', validated['status']
      assert_nil validated['email']
      assert_equal BigDecimal('123.45'), validated['valor'].amount
      assert_equal 'BRL', validated['valor'].currency
      assert Ractor.shareable?(validated)
      input[:name].replace('Alterado')
      assert_equal 'Cliente', validated['name']
      refute validated.key?('seller_id')
    end
    normalized = evaluator('chat').validate_input('chat.add_member_by_email', room_id: id(10), email: 'USER@EXAMPLE.TEST')
    assert_equal 'user@example.test', normalized['email']
    assert_equal({ 'title' => 'Título' }, evaluator('blog').validate_input('blog.create_post', title: 'Título'))
  end

  def test_invalid_values_nullability_limits_enum_and_money_reuse_data_value_without_payloads
    engine = evaluator
    base = { name: 'Cliente', dealer_id: id(20) }
    [base.except(:name), base.merge(name: nil), base.merge(name: 1), base.merge(name: 'x'),
     base.merge(name: 'a' * 161), base.merge(status: 'won'), base.merge(dealer_id: 'segredo'),
     base.merge(valor: 1.0), base.merge(valor: { amount: '1.001' }),
     base.merge(valor: { amount: '100000000000000000' }), base.merge(valor: { amount: 'NaN' }),
     base.merge(valor: { amount: '1.00', currency: 'XXX' }), base.merge(valor: { amount: '1.00', extra: 'segredo' }),
     base.merge(valor: Sequel.lit('segredo')), base.merge(name: "segredo\0")].each do |input|
      error = assert_raises(Vetra::Data::Error) { engine.validate_input('crm.create_lead', input) }
      assert_equal 'data_value', error.code
      assert error.diagnostics.first.pointer.start_with?('/input/')
      refute_includes error.message, 'segredo'
      assert_nil error.cause
    end
  end

  def test_unknown_duplicate_and_transition_fields_are_refused_without_echoing_the_keys
    engine = evaluator('blog')
    [{ title: 'Olá', published_at: Time.now }, { title: 'Olá', secret_key: 'segredo' },
     { title: 'Olá', 'title' => 'Duplicado' }, [], { 4 => 'segredo' }].each do |input|
      error = assert_raises(Vetra::Data::Error) { engine.validate_input('blog.create_post', input) }
      assert_equal 'data_input_fields', error.code
      refute_includes error.message, 'secret_key'
      refute_includes error.message, 'segredo'
    end
    assert_raises(Vetra::Data::Error) { engine.validate_input('blog.create_post', title: 'Olá', status: 'published') }
  end

  def test_nested_contracts_from_real_chat_outputs_are_validated_recursively_without_changing_ir
    doc = document('chat')
    validator = Vetra::Execution::Input.new(doc)
    room = { id: id(10), name: 'Sala', owner_id: actor, created_at: '2026-11-10T12:00:00-03:00' }
    message = { id: id(11), room_id: id(10), author_id: actor, body: 'Olá', created_at: Time.utc(2026, 11, 10) }
    result = validator.validate('chat.room_page.output', { room: room, messages: [message] })
    assert Ractor.shareable?(result)
    assert result['room']['created_at'].utc?
    assert_equal 15, result['room']['created_at'].hour
    assert_equal [result['room']], validator.validate('chat.my_rooms.output', [room])
    [nil, {}, [nil], [message.merge(body: nil)], [message.merge(extra: 'segredo')]].each do |messages|
      assert_raises(Vetra::Data::Error) { validator.validate('chat.room_page.output', { room: room, messages: messages }) }
    end
    error = assert_raises(Vetra::Data::Error) { validator.validate('chat.room_page.output', { room: room.merge(name: 5), messages: [] }) }
    assert_equal '/input/room/name', error.diagnostics.first.pointer
    assert_raises(Vetra::Data::Error) { validator.validate('chat.my_rooms.output', {}) }
    assert_raises(Vetra::Data::Error) { validator.validate('chat.room_page.output', { room: nil, messages: [] }) }
    # A IR atual reserva record/collection à saída de queries; não há comando aninhado nesses exemplos.
    assert doc['nodes'].select { |n| n['kind'] == 'contract' && n['id'].end_with?('.input') }
      .all? { |n| n['fields'].none? { |field| %w[record collection].include?(field.dig('type', 'name')) } }
  end

  def test_contract_scalar_types_use_values_and_never_coerce_strings_to_boolean_or_integer
    doc = document('blog')
    contract = node(doc, 'contract', 'blog.create_post.input')
    # Fixture de contrato em memória para os tipos sem entrada nos exemplos; não altera nem emite IR.
    contract['fields'] = %w[boolean integer date timestamp json decimal].map do |name|
      type = { 'name' => name }
      type.merge!('precision' => 8, 'scale' => 2) if name == 'decimal'
      { 'name' => name, 'type' => type, 'required' => true, 'nullable' => false }
    end
    validator = Vetra::Execution::Input.new(doc)
    values = { boolean: false, integer: 42, date: '2026-11-10', timestamp: '2026-11-10T12:00:00Z',
               json: { 'a' => [true, nil, 1.5] }, decimal: '123.45' }
    result = validator.validate(contract['id'], values)
    assert_equal Date.new(2026, 11, 10), result['date']
    assert_equal BigDecimal('123.45'), result['decimal']
    assert Ractor.shareable?(result)
    { boolean: 'false', integer: '42', date: 'segredo', timestamp: '2026-11-10',
      json: { a: 1 }, decimal: 1.2 }.each do |name, invalid|
      assert_raises(Vetra::Data::Error) { validator.validate(contract['id'], values.merge(name => invalid)) }
    end
  end

  def test_manager_seller_mixed_roles_and_actor_without_links_follow_dealer_scope_for_every_action
    engine = evaluator
    %w[read create update delete].each do |action|
      operation = "crm.#{action}_lead"
      [20, 21, 22].each_with_index do |dealer, index|
        input = action == 'create' ? { name: 'Cliente', dealer_id: id(dealer) } : { id: id(10 + index) }
        { ['crm.gerente'] => index == 0,
          ['crm.vendedor'] => index == 1 && action != 'delete',
          %w[crm.gerente crm.vendedor] => index == 0 || (index == 1 && action != 'delete'),
          [] => false }.each do |roles, expected|
          result = check(engine, operation, input, roles: roles)
          assert_equal expected, result.allowed?, [action, index, roles, result.code].inspect
          assert_denied('data_authorization_denied', result) unless expected
        end
      end
      input = action == 'create' ? { name: 'Cliente', dealer_id: id(20) } : { id: id(10) }
      empty = records.merge('crm.membership' => [])
      assert_denied('data_authorization_denied', check(engine, operation, input, roles: %w[crm.gerente crm.vendedor], facts: empty))
    end
  end

  def test_other_actor_and_broken_relation_never_reuse_a_managers_grant
    engine = evaluator
    ctx = context('crm.delete_lead', actor_id: id(88))
    assert_denied('data_authorization_denied', check(engine, 'crm.delete_lead', { id: id(10) }, roles: ['crm.gerente'], ctx: ctx))
    broken = records.merge('crm.dealer' => [])
    assert_denied('data_authorization_denied', check(engine, 'crm.delete_lead', { id: id(10) }, roles: ['crm.gerente'], facts: broken))
    # Um vínculo de outro tenant com o mesmo dealer/ator não confere autoridade.
    foreign = records
    foreign['crm.membership'].first[:company_id] = id(99)
    assert_denied('data_authorization_denied', check(engine, 'crm.delete_lead', { id: id(10) }, roles: ['crm.gerente'], facts: foreign))
  end

  def test_nested_exists_agrees_with_the_equivalent_relation_path
    doc = document('mini_crm_revendas')
    policy = node(doc, 'policy', 'crm.gerente.permission_1')
    policy['predicate'] = { 'op' => 'exists', 'relation' => ['dealer'],
                            'where' => policy['predicate'].merge('relation' => ['memberships']) }
    doc['digest'] = Vetra::Graph::Canonical.digest(doc)
    engine = Vetra::Execution::Authorization.new(doc)
    assert check(engine, 'crm.delete_lead', { id: id(10) }, roles: ['crm.gerente']).allowed?
    assert_denied('data_authorization_denied', check(engine, 'crm.delete_lead', { id: id(11) }, roles: ['crm.gerente']))
  end

  def test_arbitrary_commands_without_record_do_not_gain_fabricated_ownership_from_defaults
    doc = document('blog')
    operation = node(doc, 'command', 'blog.publish_post')
    operation['authorize'].delete('record')
    doc['digest'] = Vetra::Graph::Canonical.digest(doc)
    engine = Vetra::Execution::Authorization.new(doc)
    assert_denied('data_authorization_snapshot', check(engine, 'blog.publish_post', { post_id: id(10) },
      example: 'blog', roles: ['blog.autor'], facts: blog_records))
  end

  def test_referenced_record_is_selected_by_the_authorize_parameter_and_never_by_client_attributes
    engine = evaluator
    assert check(engine, 'crm.win_lead', { lead_id: id(10) }, roles: ['crm.gerente']).allowed?
    assert_denied('data_authorization_denied', check(engine, 'crm.win_lead', { lead_id: id(11) }, roles: ['crm.gerente']))
    assert_denied('data_authorization_denied', check(engine, 'crm.win_lead', { lead_id: id(999) }, roles: ['crm.gerente']))
    assert_denied('data_input_fields', check(engine, 'crm.win_lead', { lead_id: id(11), dealer_id: id(20) }, roles: ['crm.gerente']))
  end

  def test_simple_crm_has_application_rbac_even_with_permissive_rls
    engine = evaluator('mini_crm')
    assert check(engine, 'crm.create_lead', { name: 'Cliente' }, roles: ['crm.vendedor'], example: 'mini_crm', facts: {}).allowed?
    assert_denied('data_authorization_denied', check(engine, 'crm.delete_lead', { id: id(10) }, roles: ['crm.vendedor'], example: 'mini_crm'))
  end

  def blog_records
    { 'blog.post' => [{ id: id(10), author_id: actor, status: 'draft' }], 'blog.comment' => [{ id: id(11), approved: false }] }
  end

  def test_blog_authorize_checks_ownership_for_publish_and_admin_for_approval
    engine = evaluator('blog')
    assert check(engine, 'blog.publish_post', { post_id: id(10) }, roles: ['blog.autor'], example: 'blog', facts: blog_records).allowed?
    assert_denied('data_authorization_denied', check(engine, 'blog.publish_post', { post_id: id(10) }, roles: ['blog.autor'],
      example: 'blog', facts: blog_records, ctx: context('blog.publish_post', example: 'blog', actor_id: id(88))))
    assert check(engine, 'blog.approve_comment', { comment_id: id(11) }, roles: ['blog.admin'], example: 'blog', facts: blog_records).allowed?
    assert_denied('data_authorization_denied', check(engine, 'blog.approve_comment', { comment_id: id(11) }, roles: ['blog.autor'], example: 'blog', facts: blog_records))
    created = check(engine, 'blog.create_post', { title: 'Olá' }, roles: ['blog.autor'], example: 'blog', facts: {})
    assert created.allowed? # current_actor do default está presente ao avaliar a política.
    assert_denied('data_authorization_denied', check(engine, 'blog.create_post', { title: 'Olá', author_id: id(88) }, roles: ['blog.autor'], example: 'blog', facts: {}))
  end

  def test_blog_anonymous_role_applies_without_explicit_roles_and_is_not_a_wildcard
    engine = evaluator('blog')
    ctx = context('blog.read_comment', example: 'blog', actor_id: nil)
    facts = { 'blog.comment' => [{ id: id(11), approved: true }] }
    assert check(engine, 'blog.read_comment', { id: id(11) }, example: 'blog', ctx: ctx, facts: facts).allowed?
    assert_denied('data_authorization_denied', check(engine, 'blog.read_comment', { id: id(11) }, example: 'blog', ctx: ctx, facts: blog_records))
    assert_denied('data_authorization_context', check(engine, 'blog.read_comment', { id: id(11) }, roles: ['blog.admin'], example: 'blog', ctx: ctx, facts: facts))
  end

  def test_rate_limited_grant_is_refused_but_an_applicable_unlimited_grant_still_permits
    engine = evaluator('blog')
    input = { post_id: id(10), author_name: 'Visitante', author_email: 'user@example.test', body: 'Olá' }
    result = check(engine, 'blog.create_comment', input, example: 'blog', facts: {})
    assert_denied('data_authorization_rate_limit', result)
    result = check(engine, 'blog.create_comment', input, example: 'blog', facts: {}, roles: ['blog.admin'])
    assert result.allowed?
    assert_equal ['blog.admin.permission_2'], result.policy_ids
  end

  def test_chat_owner_commands_are_authorized_but_uses_does_not_grant_read_to_users
    engine = evaluator('chat')
    facts = { 'chat.room' => [{ id: id(10), owner_id: actor }] }
    { 'add_member' => { room_id: id(10), user_id: id(88) },
      'remove_member' => { room_id: id(10), user_id: id(88) },
      'add_member_by_email' => { room_id: id(10), email: 'USER@EXAMPLE.TEST' } }.each do |name, input|
      operation = "chat.#{name}"
      assert check(engine, operation, input, example: 'chat', roles: ['chat.authenticated'], facts: facts).allowed?
      ctx = context(operation, example: 'chat', actor_id: id(88))
      assert_denied('data_authorization_denied', check(engine, operation, input, example: 'chat', roles: ['chat.authenticated'], facts: facts, ctx: ctx))
    end
    doc = document('chat')
    refute doc['nodes'].any? { |n| n['kind'] == 'policy' && n.dig('entity', 'id') == 'chat.user' }
    assert_equal %w[chat.rooms chat.users_read], node(doc, 'command', 'chat.add_member_by_email')['uses'].map { |n| n['id'] }
    # A aprovação da etapa 3 não concede os acessos adicionais do call; K18 aplica esse contrato.
    assert check(engine, 'chat.create_room', { name: 'Sala' }, example: 'chat', roles: ['chat.authenticated'], facts: {}).allowed?
    facts = { 'chat.message' => [{ id: id(11), author_id: actor }] }
    assert check(engine, 'chat.delete_message', { id: id(11) }, example: 'chat', roles: ['chat.authenticated'], facts: facts).allowed?
  end

  def chat_records
    {
      'chat.room' => [{ id: id(10), owner_id: actor }, { id: id(11), owner_id: id(90) }],
      'chat.user' => [actor, id(88), id(89), id(90)].map { |user| { id: user, name: nil } },
      'chat.room_membership' => [
        { id: id(30), room_id: id(10), user_id: actor },
        { id: id(31), room_id: id(10), user_id: id(88) },
        { id: id(32), room_id: id(11), user_id: id(89) }
      ],
      'chat.message' => [{ id: id(40), room_id: id(10), author_id: id(89) },
                         { id: id(41), room_id: id(11), author_id: actor }]
    }
  end

  def chat_check(operation, input, actor_id: actor, facts: chat_records, **options)
    check(evaluator('chat'), operation, input, example: 'chat', roles: ['chat.authenticated'], facts: facts,
          ctx: context(operation, example: 'chat', actor_id: actor_id), **options)
  end

  def test_chat_real_policies_read_room_read_message_and_create_message_require_membership_in_that_room
    { actor => [true, false], id(88) => [true, false], id(89) => [false, true], id(90) => [false, false] }.each do |user, expected|
      [10, 11].each_with_index do |room, index|
        { 'chat.read_room' => { id: id(room) }, 'chat.read_message' => { id: id(40 + index) },
          'chat.create_message' => { room_id: id(room), body: 'Olá' } }.each do |operation, input|
          result = chat_check(operation, input, actor_id: user)
          assert_equal expected[index], result.allowed?, [operation, user, room, result.code].inspect
          assert_denied('data_authorization_denied', result) unless expected[index]
        end
      end
    end
    # Nem ser autor da mensagem nem dono sem vínculo substitui a política members.
    assert_denied('data_authorization_fields', chat_check('chat.create_message', { room_id: id(10), body: 'Olá', author_id: actor }))
    assert_denied('data_authorization_denied', chat_check('chat.read_room', { id: id(999) }))
    assert_denied('data_authorization_denied', chat_check('chat.create_message', { room_id: id(999), body: 'Olá' }))
  end

  def test_chat_null_or_orphan_junction_keys_do_not_match_and_message_with_null_room_is_denied
    [{ room_id: nil, user_id: actor }, { room_id: id(10), user_id: nil },
     { room_id: id(10), user_id: id(999) }, { room_id: nil, user_id: nil }].each do |keys|
      facts = chat_records.merge('chat.room_membership' => [keys.merge(id: id(30))])
      facts['chat.user'] << { id: nil }
      assert_denied('data_authorization_denied', chat_check('chat.read_room', { id: id(10) }, facts: facts))
    end
    facts = chat_records
    facts['chat.message'].first[:room_id] = nil
    assert_denied('data_authorization_denied', chat_check('chat.read_message', { id: id(40) }, facts: facts))
  end

  def test_chat_junction_and_target_must_be_present_even_when_a_previous_hop_has_no_rows
    %w[chat.room_membership chat.user].each do |entity|
      facts = chat_records.merge('chat.room_membership' => []).except(entity)
      assert_denied('data_authorization_snapshot', chat_check('chat.read_room', { id: id(10) }, facts: facts))
      facts['chat.room'] = []
      assert_denied('data_authorization_snapshot', chat_check('chat.create_message', { room_id: id(10), body: 'Olá' }, facts: facts))
    end
    %w[chat.room_membership chat.user].each do |entity|
      assert_denied('data_authorization_denied', chat_check('chat.read_room', { id: id(10) }, facts: chat_records.merge(entity => [])))
    end
    facts = chat_records
    facts['chat.room_membership'].first.delete(:user_id)
    assert_denied('data_authorization_snapshot', chat_check('chat.read_room', { id: id(10) }, facts: facts))
  end

  # Variações só em memória para percursos que o chat não declara: sem alterar modelos, planos ou artefatos.
  def chat_predicate
    schema = Vetra::SQL::Schema.new(document('chat')).generate
    entities = Vetra::Graph::Data.copy(schema.document)['nodes'].select { |entry| entry['kind'] == 'entity' }.to_h { |entry| [entry['id'], entry] }
    tables = Vetra::Graph::Data.copy(schema.tables).to_h { |table| [table['entity'], table] }
    yield entities, tables if block_given?
    Vetra::Execution::Predicate.new(entities, tables)
  end

  def exists(path, tree = eq(field('id'), { 'kind' => 'actor', 'path' => ['id'] }))
    { 'op' => 'exists', 'relation' => Array(path), 'where' => tree }
  end

  def evaluate_chat_predicate(predicate, tree, facts: chat_records, row: { 'id' => id(10) }, ctx: context('chat.read_room', example: 'chat'))
    snapshot = evaluator('chat').snapshot(context: ctx, roles: ['chat.authenticated'], revision: 4, records: facts)
    predicate.validate!(tree, 'chat.room')
    predicate.evaluate(tree, 'chat.room', row, ctx, snapshot)
  end

  def test_many_to_many_scopes_both_hops_by_tenant_and_matches_the_whole_composite_key
    predicate = chat_predicate do |entities, tables|
      tables.each_value { |table| table['tenant_column'] = 'company_id' }
      entities['chat.room']['relations'].find { |link| link['name'] == 'members' }.merge!(
        'same_tenant' => true, 'local_fields' => %w[company_id id], 'target_fields' => %w[company_id id])
      entities['chat.room_membership']['relations'].each do |link|
        link['same_tenant'] = true
        link['local_fields'].unshift('company_id')
        link['target_fields'].unshift('company_id')
      end
    end
    facts = chat_records
    facts.each_value { |rows| rows.each { |row| row[:company_id] = tenant } }
    ctx = context('crm.read_lead')
    row = { 'id' => id(10), 'company_id' => tenant }
    assert evaluate_chat_predicate(predicate, exists('members'), facts: facts, row: row, ctx: ctx)
    ['chat.room_membership', 'chat.user'].each do |entity|
      foreign = Marshal.load(Marshal.dump(facts))
      foreign[entity].each { |entry| entry[:company_id] = id(99) }
      refute evaluate_chat_predicate(predicate, exists('members'), facts: foreign, row: row, ctx: ctx)
    end
    # IDs iguais não bastam: mesmo com candidatos do tenant certo a chave composta do dono deve casar inteira.
    refute evaluate_chat_predicate(predicate, exists('members'), facts: facts, row: row.merge('company_id' => id(99)), ctx: ctx)
    refute evaluate_chat_predicate(predicate, exists('members'), facts: facts, row: row.merge('company_id' => nil), ctx: ctx)
  end

  def test_many_to_many_can_be_followed_by_more_hops_and_two_many_to_many_can_share_a_tree
    predicate = chat_predicate do |entities, _tables|
      entities['chat.user']['relations'] << {
        'name' => 'rooms', 'kind' => 'many_to_many', 'target' => { 'id' => 'chat.room' },
        'through' => { 'id' => 'chat.room_membership' }, 'local_fields' => ['id'], 'target_fields' => ['id']
      }
    end
    path = exists(%w[members rooms owner])
    nested = exists('members', exists('rooms', exists('owner')))
    [path, nested].each do |tree|
      assert evaluate_chat_predicate(predicate, tree)
      refute evaluate_chat_predicate(predicate, tree, row: { 'id' => id(11) })
      assert_includes predicate.traversed(tree, 'chat.room'), 'chat.room_membership'
    end
    tree = { 'op' => 'and', 'terms' => [exists('members'), exists('members', eq(field('id'), literal(id(88))))] }
    assert evaluate_chat_predicate(predicate, tree)
    facts = chat_records
    facts['chat.room_membership'].delete_at(1)
    refute evaluate_chat_predicate(predicate, tree, facts: facts)
  end

  def test_many_to_many_preserves_null_logic_under_not_in_and_exists_and_validates_unreachable_branches
    predicate = chat_predicate
    comparison = eq(field('name'), literal('Ana'))
    list = { 'op' => 'in', 'left' => field('name'), 'right' => literal(['Ana', nil]) }
    [comparison, list].each do |tree|
      refute evaluate_chat_predicate(predicate, exists('members', { 'op' => 'not', 'term' => tree }))
    end
    assert evaluate_chat_predicate(predicate, exists('members', eq(field('name'), literal(nil))))
    assert evaluate_chat_predicate(predicate, { 'op' => 'not', 'term' => exists('members') }, facts: chat_records.merge('chat.room_membership' => []))
    [eq({ 'kind' => 'field', 'path' => %w[name value] }, literal(nil)),
     eq({ 'kind' => 'actor', 'path' => ['email'] }, literal(nil)),
     { 'op' => 'in', 'left' => field('id'), 'right' => field('id') },
     { 'op' => 'unsupported' }].each do |unsupported|
      tree = { 'op' => 'or', 'terms' => [{ 'op' => 'true' }, exists('members', unsupported)] }
      error = assert_raises(Vetra::Data::Error) { predicate.validate!(tree, 'chat.room') }
      assert_equal 'data_authorization_predicate', error.code
    end
  end

  def modified_engine
    doc = document('mini_crm')
    policy = node(doc, 'policy', 'crm.gerente.permission_1')
    yield doc, policy
    doc['digest'] = Vetra::Graph::Canonical.digest(doc)
    Vetra::Execution::Authorization.new(doc)
  end

  def test_field_grants_are_unioned_only_after_predicate_and_role_checks
    engine = modified_engine do |doc, policy|
      policy['fields'] = ['name']
      second = Marshal.load(Marshal.dump(policy))
      second['id'] = 'crm.gerente.permission_extra'
      second['fields'] = ['email']
      doc['nodes'] << second
    end
    result = check(engine, 'crm.update_lead', { id: id(10), name: 'Outro', email: 'user@example.test' }, example: 'mini_crm', roles: ['crm.gerente'])
    assert result.allowed?
    assert_denied('data_authorization_fields', check(engine, 'crm.update_lead', { id: id(10), status: 'lost' }, example: 'mini_crm', roles: ['crm.gerente']))
    # A borda não pode omitir um campo fornecido no CRUD reduzindo fields.
    assert_denied('data_authorization_fields', check(engine, 'crm.update_lead', { id: id(10), status: 'lost' }, fields: [], example: 'mini_crm', roles: ['crm.gerente']))
    assert_denied('data_authorization_fields', check(engine, 'crm.read_lead', { id: id(10) }, example: 'mini_crm', roles: ['crm.gerente']))
    assert check(engine, 'crm.read_lead', { id: id(10) }, fields: [:name], example: 'mini_crm', roles: ['crm.gerente']).allowed?
    assert_denied('data_authorization_fields', check(engine, 'crm.read_lead', { id: id(10) }, fields: [:unknown], example: 'mini_crm', roles: ['crm.gerente']))
  end

  def test_limited_grants_cannot_supply_fields_missing_from_unlimited_grants
    engine = modified_engine do |doc, policy|
      policy['fields'] = ['name']
      limited = Marshal.load(Marshal.dump(policy))
      limited.merge!('id' => 'crm.gerente.permission_extra', 'fields' => ['email'],
                     'rate_limit' => { 'key' => 'actor_tenant', 'limit' => 5, 'window_seconds' => 60 })
      doc['requires'] << 'vetra.rate_limit'
      doc['requires'] = doc['requires'].uniq.sort
      doc['nodes'] << limited
    end
    assert_denied('data_authorization_rate_limit', check(engine, 'crm.update_lead', { id: id(10), name: 'Outro', email: nil }, example: 'mini_crm', roles: ['crm.gerente']))
    assert check(engine, 'crm.update_lead', { id: id(10), name: 'Outro' }, example: 'mini_crm', roles: ['crm.gerente']).allowed?
  end

  def field(name) = { 'kind' => 'field', 'path' => [name] }
  def literal(value) = { 'kind' => 'literal', 'value' => value }
  def eq(left, right) = { 'op' => 'eq', 'left' => left, 'right' => right }

  def predicate_result(tree, row)
    engine = modified_engine { |_doc, policy| policy['predicate'] = tree }
    check(engine, 'crm.read_lead', { id: id(10) }, roles: ['crm.gerente'], example: 'mini_crm', facts: { 'crm.lead' => [row.merge(id: id(10), company_id: tenant)] })
  end

  def test_and_or_not_in_equality_and_sql_null_semantics
    comparison = eq(field('email'), literal('user@example.test'))
    assert predicate_result(comparison, email: 'user@example.test').allowed?
    refute predicate_result(comparison, email: nil).allowed?
    refute predicate_result({ 'op' => 'not', 'term' => comparison }, email: nil).allowed?
    assert predicate_result(eq(field('email'), literal(nil)), email: nil).allowed?
    assert predicate_result({ 'op' => 'or', 'terms' => [comparison, { 'op' => 'true' }] }, email: nil).allowed?
    refute predicate_result({ 'op' => 'and', 'terms' => [comparison, { 'op' => 'true' }] }, email: nil).allowed?
    list = { 'op' => 'in', 'left' => field('status'), 'right' => literal(['new', nil]) }
    assert predicate_result(list, status: 'new').allowed?
    refute predicate_result({ 'op' => 'not', 'term' => list }, status: 'lost').allowed?
    refute predicate_result(list, status: nil).allowed?
    list['right'] = literal([])
    assert predicate_result({ 'op' => 'not', 'term' => list }, status: nil).allowed?
    assert predicate_result({ 'op' => 'not', 'term' => comparison }, email: 'outro').allowed?
  end

  def test_unsupported_operand_is_not_hidden_by_true_or_by_an_unlimited_grant
    unsupported = eq(field('valor'), literal(nil))
    result = predicate_result({ 'op' => 'or', 'terms' => [{ 'op' => 'true' }, unsupported] }, valor: nil)
    assert_denied('data_authorization_predicate', result)
  end

  def test_typed_predicate_literals_match_sql_and_incompatible_comparisons_fail_closed_under_not
    upper_uuid = id(10).upcase
    assert predicate_result(eq(field('id'), literal(upper_uuid)), {}).allowed?
    bad = { 'op' => 'not', 'term' => eq(field('email'), literal(42)) }
    assert_denied('data_authorization_predicate', predicate_result(bad, email: '42'))

    # Tipos escalares que os modelos têm apenas em saída/defaults: mesmo avaliador, sem emitir outra IR.
    entities = { 'probe' => { 'fields' => [{ 'name' => 'value', 'type' => { 'name' => 'timestamp' } }] } }
    predicate = Vetra::Execution::Predicate.new(entities, {})
    ctx = context('crm.read_lead')
    { 'timestamp' => [Time.utc(2026, 11, 10, 15), '2026-11-10T12:00:00-03:00'],
      'date' => [Date.new(2026, 11, 10), '2026-11-10'],
      'decimal' => [BigDecimal('1.23'), '1.230'], 'integer' => [42, '042'] }.each do |type, (value, text)|
      entities['probe']['fields'].first['type']['name'] = type
      tree = eq(field('value'), literal(text))
      predicate.validate!(tree, 'probe')
      assert predicate.evaluate(tree, 'probe', { 'value' => value }, ctx, nil)
      list = { 'op' => 'in', 'left' => field('value'), 'right' => literal([nil, text]) }
      predicate.validate!(list, 'probe')
      assert predicate.evaluate(list, 'probe', { 'value' => value }, ctx, nil)
    end
    entities['probe']['fields'].first['type']['name'] = 'boolean'
    tree = { 'op' => 'not', 'term' => eq(field('value'), literal('segredo')) }
    error = assert_raises(Vetra::Data::Error) { predicate.validate!(tree, 'probe') }
    assert_equal 'data_authorization_predicate', error.code
    assert_nil error.cause
    refute_includes error.message, 'segredo'
  end

  def test_absent_relation_facts_cannot_be_mistaken_for_a_false_exists_under_not
    doc = document('mini_crm_revendas')
    policy = node(doc, 'policy', 'crm.gerente.permission_1')
    policy['predicate'] = { 'op' => 'not', 'term' => policy['predicate'] }
    doc['digest'] = Vetra::Graph::Canonical.digest(doc)
    engine = Vetra::Execution::Authorization.new(doc)
    assert_denied('data_authorization_snapshot', check(engine, 'crm.delete_lead', { id: id(10) }, roles: ['crm.gerente'], facts: records.except('crm.membership')))
    assert check(engine, 'crm.delete_lead', { id: id(10) }, roles: ['crm.gerente'], facts: records.merge('crm.membership' => [])).allowed?
    assert_denied('data_authorization_snapshot', predicate_result(eq(field('email'), literal(nil)), {}))
  end

  def test_snapshots_are_immutable_bound_to_catalog_actor_tenant_and_revision_and_redacted
    engine = evaluator
    ctx = context('crm.delete_lead')
    mutable = records
    snapshot = engine.snapshot(context: ctx, roles: ['crm.gerente'], revision: 4, records: mutable)
    mutable['crm.membership'].clear
    options = { input: { id: id(10) }, context: ctx, snapshot: snapshot, current_revision: ->(_) { 4 } }
    result = engine.check('crm.delete_lead', **options)
    assert result.allowed?
    refute_includes snapshot.inspect, actor
    refute_includes result.inspect, id(10)
    assert snapshot.rows('crm.membership').frozen?
    assert_denied('data_authorization_snapshot', evaluator.check('crm.delete_lead', **options))
    [context('crm.delete_lead', actor_id: id(88)), context('crm.delete_lead', tenant_id: id(99))].each do |different|
      assert_denied('data_authorization_snapshot', engine.check('crm.delete_lead', **options.merge(context: different)))
    end
    [->(_) { 5 }, ->(_) { nil }, ->(_) { raise 'segredo' }, nil].each do |reader|
      assert_denied('data_authorization_snapshot', engine.check('crm.delete_lead', **options.merge(current_revision: reader)))
    end
    revisions = [4, 5]
    assert_denied('data_authorization_snapshot', engine.check('crm.delete_lead', **options.merge(current_revision: ->(_) { revisions.shift })))
  end

  def test_invalid_snapshot_unknown_role_wrong_command_and_system_actor_have_clear_diagnostics
    engine = evaluator
    assert_raises(Vetra::Data::Error) { engine.snapshot(context: nil, roles: [], revision: 4, records: {}) }
    assert_raises(Vetra::Data::Error) { engine.snapshot(context: context('crm.delete_lead'), roles: [], revision: nil, records: {}) }
    duplicate = records
    duplicate['crm.lead'] << duplicate['crm.lead'].first.dup
    assert_raises(Vetra::Data::Error) { engine.snapshot(context: context('crm.delete_lead'), roles: [], revision: 4, records: duplicate) }
    assert_denied('data_authorization_context', check(engine, 'crm.delete_lead', { id: id(10) }, roles: ['crm.inexistente']))
    assert_denied('data_authorization_context', check(engine, 'crm.delete_lead', { id: id(10) }, roles: ['crm.gerente'], ctx: context('crm.read_lead')))
    assert_denied('data_execution_operation', check(engine, 'crm.inexistente', {}, facts: {}))
    ctx = context('crm.delete_lead', actor_id: nil, system_actor: 'crm.handler')
    assert_denied('data_authorization_system_actor', check(engine, 'crm.delete_lead', { id: id(10) }, ctx: ctx, roles: []))
  end

  # ---- K18: ator de sistema, consulta de coleção e decisão por linha -------------------------------------------------

  def engine_with_handler_calls(*commands)
    doc = document('mini_crm')
    node(doc, 'handler', 'crm.notify_sales')['calls'] = commands.map { |id| { 'id' => id, 'kind' => 'command' } }
    doc['digest'] = Vetra::Graph::Canonical.digest(doc)
    Vetra::Execution::Authorization.new(doc)
  end

  def system_context(operation, handler: 'crm.notify_sales')
    Vetra::Data::Context.new(scope: :tenant, tenant_id: tenant, system_actor: handler, op_id: id(3), cmd: operation)
  end

  def test_a_system_actor_is_authorized_only_by_the_calls_of_its_handler_without_roles_facts_or_revision
    engine = engine_with_handler_calls('crm.win_lead')
    result = engine.check('crm.win_lead', input: { lead_id: id(10) }, context: system_context('crm.win_lead'))
    assert result.allowed?
    assert_equal ['calls:crm.notify_sales'], result.policy_ids
    assert_equal({ 'lead_id' => id(10) }, result.input)
    # Fora dos calls, handler desconhecido ou nó que não é handler: recusa, com o mesmo código.
    assert_denied('data_authorization_system_actor', engine.check('crm.update_lead', input: { id: id(10), name: 'Nome' }, context: system_context('crm.update_lead')))
    assert_denied('data_authorization_system_actor', engine.check('crm.win_lead', input: { lead_id: id(10) }, context: system_context('crm.win_lead', handler: 'crm.nada')))
    assert_denied('data_authorization_system_actor', engine.check('crm.win_lead', input: { lead_id: id(10) }, context: system_context('crm.win_lead', handler: 'crm.lead')))
    # A entrada continua validada e o contexto continua conferido antes da concessão.
    assert_denied('data_value', engine.check('crm.win_lead', input: { lead_id: 'x' }, context: system_context('crm.win_lead')))
    assert_denied('data_authorization_context', engine.check('crm.win_lead', input: { lead_id: id(10) }, context: system_context('crm.read_lead')))
    # Um visitante não é um ator de sistema: sem snapshot, a admissão por papéis recusa.
    assert_denied('data_authorization_snapshot', evaluator.check('crm.read_lead', input: { id: id(10) }, context: context('crm.read_lead')))
  end

  def test_a_collection_query_is_admitted_by_the_role_without_a_row_and_the_plan_asks_for_no_facts
    engine = evaluator('chat')
    ctx = context('chat.my_rooms', example: 'chat')
    snapshot = engine.snapshot(context: ctx, roles: ['chat.authenticated'], revision: 4, records: {})
    result = engine.check('chat.my_rooms', input: {}, context: ctx, snapshot: snapshot, current_revision: ->(_) { 4 })
    assert result.allowed?, result.diagnostics.map(&:to_s).join
    assert_equal({ principal: nil, entities: [], record: nil }, engine.fact_plan('chat.my_rooms', ['chat.authenticated']))
    # Sem concessão de leitura para os papéis, a coleção é recusada.
    no_role = engine.snapshot(context: ctx, roles: [], revision: 4, records: {})
    assert_denied('data_authorization_denied', engine.check('chat.my_rooms', input: {}, context: ctx, snapshot: no_role, current_revision: ->(_) { 4 }))
    # A leitura de registro inteiro exige todos os campos: concessão limitada a um campo recusa a coleção.
    limited = Vetra::Graph::Data.copy(document('chat'))
    node(limited, 'policy', 'chat.authenticated.permission_2')['fields'] = ['name']
    limited['digest'] = Vetra::Graph::Canonical.digest(limited)
    narrow = Vetra::Execution::Authorization.new(limited)
    narrow_snapshot = narrow.snapshot(context: ctx, roles: ['chat.authenticated'], revision: 4, records: {})
    assert_denied('data_authorization_fields', narrow.check('chat.my_rooms', input: {}, context: ctx, snapshot: narrow_snapshot, current_revision: ->(_) { 4 }))
  end

  def test_decide_judges_one_row_for_an_entity_and_action_with_the_given_facts
    engine = evaluator('chat')
    ctx = context('chat.read_room', example: 'chat')
    snapshot = engine.snapshot(context: ctx, roles: ['chat.authenticated'], revision: 'in_unit', records: chat_records)
    row = { 'id' => id(10), 'owner_id' => actor }
    ids = engine.decide('chat.room', 'read', row, context: ctx, roles: ['chat.authenticated'], snapshot: snapshot, fields: engine.field_names('chat.room'))
    assert_equal 1, ids.size
    outsider = { 'id' => id(11), 'owner_id' => id(90) }
    error = assert_raises(Vetra::Data::Error) { engine.decide('chat.room', 'read', outsider, context: ctx, roles: ['chat.authenticated'], snapshot: snapshot, fields: []) }
    assert_equal 'data_authorization_denied', error.code
    assert engine.granted?('chat.room', 'read', ['chat.authenticated'])
    refute engine.granted?('chat.user', 'read', ['chat.authenticated'])
    refute engine.granted?('chat.room', 'read', [])
    assert_equal %w[id name owner_id created_at].sort, engine.field_names('chat.room').sort
    assert_nil engine.tenant_column('chat.room')
  end

  def test_the_principal_record_is_resolved_only_after_the_candidate_policies
    # Sem papéis e com fatos que não têm o registro: a recusa é a da política, não a do registro ausente.
    result = check(evaluator, 'crm.read_lead', { id: id(10) }, roles: [], facts: {})
    assert_denied('data_authorization_denied', result)
  end

  def test_all_refusals_and_validation_happen_before_any_mock_sql_or_transaction
    engine = evaluator
    db = Sequel.mock(host: :postgres)
    issuer = Vetra::Data::ContextIssuer.new(kid: 'test', secret: 'x' * 32)
    work = Vetra::Data::UnitOfWork.new(db, limits: false, issuer: issuer)
    db.sqls
    [check(engine, 'crm.delete_lead', { id: id(10) }),
     check(engine, 'crm.create_lead', { name: 'x', dealer_id: id(20) }, roles: ['crm.gerente']),
     check(engine, 'crm.delete_lead', { id: id(11) }, roles: ['crm.gerente']),
     check(engine, 'crm.delete_lead', { id: id(10) }, roles: ['crm.gerente'], revision: 3)].each do |result|
      work.transaction(tenant_id: tenant, actor_id: actor, op_id: id(3), cmd: 'crm.delete_lead') { flunk 'Recusa chegou à transação' } if result.allowed?
      refute result.allowed?
    end
    assert_empty db.sqls
    # Controle positivo: o mock conta a transação quando a etapa 4 é de fato chamada.
    work.transaction(tenant_id: tenant, actor_id: actor, op_id: id(3), cmd: 'crm.delete_lead') { nil }
    assert_equal 1, db.sqls.count { |sql| sql.start_with?('BEGIN') }
  end
end

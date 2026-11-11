require_relative 'test_helper'
require 'vetra/execution'
require 'securerandom'

# Guarda de acesso dos repositórios, reautorização do estado final e ramo de sistema (K18, ADR-046), sem banco: um banco
# simulado que responde por tabela, para que os fatos lidos na unidade venham das mesmas linhas que o call lê.
class ExecutionGuardTest < GraphTest
  def self.linked(example)
    (@linked ||= {})[example] ||= Vetra::Graph::Compiler.new(root: File.join(PROJECT, 'examples', example)).link
  end

  def id = SecureRandom.uuid

  def setup
    @actor, @other = id, id
    @now = Time.now.utc.floor(6)
  end

  # tabela => linhas; um valor chamável recebe o SQL e devolve as linhas. Honra LIMIT e OFFSET, e deixa UPDATE mudar o estado.
  def routed_db(tables)
    Sequel.mock(host: :postgres).tap do |db|
      db.fetch = lambda do |sql|
        next [] if sql.include?('set_config') || sql.include?('current_setting')
        table = sql[/(?:FROM|INTO|UPDATE) "public"\."(\w+)"/, 1]
        rows = tables[table]
        rows = rows.call(sql) if rows.respond_to?(:call)
        rows = Array(rows)
        if (offset = sql[/OFFSET (\d+)/, 1]) then rows = rows.drop(offset.to_i) end
        if (limit = sql[/LIMIT (\d+)/, 1]) then rows = rows.first(limit.to_i) end
        rows
      end
    end
  end

  def post(author, status: 'draft', title: 'Título')
    { id: id, title: title, author_id: author, status: status, published_at: nil, created_at: @now }
  end

  def blog_unit(tables = {}, roles: ['blog.autor'], actor: @actor, **more)
    tables = tables.merge(more)
    linked = self.class.linked('blog')
    @catalog = Vetra::Data::Repositories.new(linked.document)
    @authorization = Vetra::Execution::Authorization.new(linked.document)
    @db = routed_db(tables)
    @unit = Vetra::Data::UnitOfWork.new(@db, scope: :global, limits: false)
    @guard = Vetra::Execution::AccessGuard.new(authorization: @authorization, catalog: @catalog, unit: @unit, roles: roles)
    @claims = { actor_id: actor, op_id: id, cmd: 'blog.update_post', guard: @guard }
  end

  def within
    @unit.transaction(**@claims) { |unit| yield unit, @catalog.bind('blog.posts', unit: unit) }
  end

  def refusal_code(&block)
    assert_raises(Vetra::Data::Error, &block).code
  end

  def test_a_row_the_role_cannot_read_looks_missing_like_under_rls_and_a_readable_one_passes
    mine, theirs = post(@actor), post(@other)
    blog_unit('posts' => [mine])
    within { |_, posts| assert_equal mine[:id], posts.find!(mine[:id]).id }
    blog_unit('posts' => [theirs])
    within { |_, posts| assert_equal 'data_record_not_found', refusal_code { posts.find!(theirs[:id]) } }
    blog_unit('posts' => [theirs])
    within { |_, posts| assert_equal 'data_record_not_found', refusal_code { posts.lock!(theirs[:id]) } }
  end

  def test_without_any_grant_for_the_role_the_refusal_is_explicit_even_for_an_empty_collection
    chat = self.class.linked('chat')
    catalog = Vetra::Data::Repositories.new(chat.document)
    user = { id: id, name: 'Ana', email: 'ana@probe.invalid', created_at: @now }
    unit = Vetra::Data::UnitOfWork.new(routed_db('users' => [user]), scope: :global, limits: false)
    guard = Vetra::Execution::AccessGuard.new(authorization: Vetra::Execution::Authorization.new(chat.document), catalog: catalog,
                                              unit: unit, roles: ['chat.authenticated'])
    unit.transaction(actor_id: @actor, op_id: id, cmd: 'chat.add_member_by_email', guard: guard) do |active|
      users = catalog.bind('chat.users_read', unit: active)
      assert_equal 'data_authorization_denied', refusal_code { users.where(email: 'a@b.invalid').first(2) }
      assert_empty(@seen_sql = unit.instance_variable_get(:@db).sqls.grep(/SELECT/), 'a coleção é recusada antes de consultar')
      assert_equal 'data_authorization_denied', refusal_code { users.find!(user[:id]) }
    end
  end

  def test_a_collection_keeps_only_the_rows_the_role_can_read_and_pages_until_the_limit_is_met
    rows = [post(@other), post(@actor, title: 'A'), post(@other), post(@actor, title: 'B'), post(@actor, title: 'C')]
    blog_unit('posts' => rows)
    within do |_, posts|
      assert_equal %w[A B C], posts.order(:title).all.map(&:title)
    end
    original = Vetra::Data::Repository::PAGE_SIZE
    Vetra::Data::Repository.send(:remove_const, :PAGE_SIZE)
    Vetra::Data::Repository.const_set(:PAGE_SIZE, 2)
    begin
      blog_unit('posts' => rows)
      within do |_, posts|
        assert_equal %w[A B], posts.order(:title).first(2).map(&:title)
      end
      statements = @db.sqls
      assert(statements.any? { |sql| sql.include?('OFFSET 0') })
      assert(statements.any? { |sql| sql.include?('OFFSET 2') })
      refute(statements.any? { |sql| sql.include?('OFFSET 4') }, 'o limite já estava completo')
    ensure
      Vetra::Data::Repository.send(:remove_const, :PAGE_SIZE)
      Vetra::Data::Repository.const_set(:PAGE_SIZE, original)
    end
  end

  def test_create_update_and_delete_are_decided_by_action_row_and_fields
    mine, theirs = post(@actor), post(@other)
    blog_unit('posts' => [mine])
    within do |_, posts|
      assert_equal mine[:id], posts.create!(title: 'Novo', author_id: @actor).id
      assert_equal mine[:id], posts.update!(mine[:id], title: 'Outro').id
      assert_equal mine[:id], posts.delete!(mine[:id]).id
    end
    blog_unit('posts' => [mine])
    within { |_, posts| assert_equal 'data_authorization_denied', refusal_code { posts.create!(title: 'Alheio', author_id: @other) } }
    blog_unit('posts' => [theirs])
    within do |_, posts|
      assert_equal 'data_record_not_found', refusal_code { posts.update!(theirs[:id], title: 'x') }
      assert_equal 'data_record_not_found', refusal_code { posts.delete!(theirs[:id]) }
    end
    assert(@db.sqls.none? { |sql| sql.start_with?('UPDATE') || sql.start_with?('DELETE') }, 'a recusa vem antes da escrita')
  end

  def test_visitor_has_no_grant_for_writes_and_the_comment_policy_fields_are_checked
    blog_unit({ 'posts' => [post(@actor)] }, roles: [])
    within { |_, posts| assert_equal 'data_authorization_denied', refusal_code { posts.create!(title: 'x', author_id: @actor) } }
  end

  def test_final_state_is_reauthorized_with_fresh_facts_and_catches_the_change_of_owner
    mine = post(@actor)
    state = mine.dup
    tables = { 'posts' => lambda do |sql|
      state = state.merge(author_id: @other) if sql.start_with?('UPDATE')
      [state]
    end }
    blog_unit(tables)
    error = assert_raises(Vetra::Data::Error) do
      within do |_, posts|
        posts.update!(mine[:id], author_id: @other)
        @guard.reauthorize!
      end
    end
    assert_equal 'data_authorization_final', error.code
    assert_nil error.cause
    assert_includes @db.sqls, 'ROLLBACK'
    # Sem mudar o dono, o estado final passa.
    state = mine.dup
    blog_unit('posts' => lambda { |_| [state] })
    within do |_, posts|
      posts.update!(mine[:id], title: 'Novo título')
      assert_nil @guard.reauthorize!
    end
  end

  def test_reauthorization_covers_created_rows_skips_deleted_ones_and_refuses_a_row_that_vanished
    mine = post(@actor)
    blog_unit('posts' => [mine])
    within do |_, posts|
      created = posts.create!(title: 'Novo', author_id: @actor)
      assert_nil @guard.reauthorize!
      assert_equal mine[:id], created.id
    end
    blog_unit('posts' => [mine])
    within do |_, posts|
      posts.update!(mine[:id], title: 'Outro')
      posts.delete!(mine[:id])
      assert_nil @guard.reauthorize!, 'linha apagada não é reautorizada'
    end
    # A linha criada some das leituras seguintes (por exemplo, invisível depois da escrita): recusa.
    rows = [mine]
    blog_unit('posts' => lambda { |sql| sql.start_with?('INSERT') ? [mine] : rows })
    gone = assert_raises(Vetra::Data::Error) do
      within do |_, posts|
        posts.create!(title: 'Novo', author_id: @actor)
        rows = []
        @guard.reauthorize!
      end
    end
    assert_equal 'data_authorization_final', gone.code
  end

  def chat_unit(tables, roles: ['chat.authenticated'])
    linked = self.class.linked('chat')
    @catalog = Vetra::Data::Repositories.new(linked.document)
    @db = routed_db(tables)
    @unit = Vetra::Data::UnitOfWork.new(@db, scope: :global, limits: false)
    @guard = Vetra::Execution::AccessGuard.new(authorization: Vetra::Execution::Authorization.new(linked.document), catalog: @catalog,
                                               unit: @unit, roles: roles)
    @claims = { actor_id: @actor, op_id: id, cmd: 'chat.add_member', guard: @guard }
  end

  def chat_fixture(owner:, member: true)
    room = { id: id, owner_id: owner, name: 'Sala', created_at: @now }
    user = { id: id, name: 'Ana', email: 'ana@probe.invalid', created_at: @now }
    memberships = member ? [{ id: id, room_id: room[:id], user_id: @actor, created_at: @now }] : []
    me = { id: @actor, name: 'Eu', email: 'eu@probe.invalid', created_at: @now }
    [room, user, { 'rooms' => [room], 'users' => [user, me], 'room_memberships' => memberships }]
  end

  def test_a_link_action_is_decided_on_the_owner_and_the_target_and_junction_are_part_of_it
    room, user, tables = chat_fixture(owner: @actor)
    chat_unit(tables)
    @unit.transaction(**@claims) do |unit|
      rooms = @catalog.bind('chat.rooms', unit: unit)
      assert_equal room[:id], rooms.add_member!(room[:id], user[:id]).id
    end
    statements = @db.sqls
    assert(statements.any? { |sql| sql.start_with?('INSERT INTO "public"."room_memberships"') })

    room, user, tables = chat_fixture(owner: @other)
    chat_unit(tables)
    @unit.transaction(**@claims) do |unit|
      rooms = @catalog.bind('chat.rooms', unit: unit)
      assert_equal 'data_authorization_denied', refusal_code { rooms.add_member!(room[:id], user[:id]) }
    end
    refute(@db.sqls.any? { |sql| sql.start_with?('INSERT INTO "public"."room_memberships"') })

    # Quem não é membro nem enxerga a sala: o dono do vínculo precisa poder ler o registro que trava.
    room, user, tables = chat_fixture(owner: @actor, member: false)
    chat_unit(tables)
    @unit.transaction(**@claims) do |unit|
      assert_equal 'data_record_not_found', refusal_code { @catalog.bind('chat.rooms', unit: unit).add_member!(room[:id], user[:id]) }
    end
  end

  def test_creating_a_room_links_the_owner_without_a_second_decision_and_the_final_state_passes
    room, _user, tables = chat_fixture(owner: @actor, member: false)
    tables['users'] = [{ id: @actor, name: 'Eu', email: 'eu@probe.invalid', created_at: @now }]
    chat_unit(tables)
    @claims[:cmd] = 'chat.create_room'
    @unit.transaction(**@claims) do |unit|
      created = @catalog.bind('chat.rooms', unit: unit).create!(name: 'Nova')
      assert_equal room[:id], created.id
      assert_nil @guard.reauthorize!
    end
    assert(@db.sqls.any? { |sql| sql.start_with?('INSERT INTO "public"."room_memberships"') }, 'o vínculo do dono foi gravado')
  end

  def test_a_system_actor_skips_role_policies_and_the_final_reauthorization
    context = Struct.new(:system_actor?).new(true)
    unit = Struct.new(:context).new(context)
    guard = Vetra::Execution::AccessGuard.new(authorization: nil, catalog: nil, unit: unit, roles: [])
    assert_nil guard.authorize_write!('crm.lead', 'delete', { 'id' => 'x' }, [])
    assert_nil guard.authorize_read!('crm.lead', { 'id' => 'x' })
    assert_equal [1, 2], guard.visible('crm.lead', [1, 2])
    assert_nil guard.reauthorize!
    assert_equal '#<Vetra::Execution::AccessGuard>', guard.inspect
  end

  # ---- pelo Runner ------------------------------------------------------------------------------------------------

  def build_runner(example, ops_tables, facts_tables = ops_tables, scoped: false)
    linked = example.is_a?(String) ? self.class.linked(example) : example
    catalog = Vetra::Data::Repositories.new(linked.document)
    @authority = Vetra::Execution::InProcessAuthority.new
    @ops_db, @facts_db = routed_db(ops_tables), routed_db(facts_tables)
    options = scoped ? { issuer: Vetra::Data::ContextIssuer.new(kid: 'k', secret: SecureRandom.random_bytes(32)) } : { scope: :global }
    facts = Vetra::Execution::DatabaseFacts.new(catalog: catalog, authority: @authority,
                                                unit: Vetra::Data::UnitOfWork.new(@facts_db, limits: false, **options))
    edge = Vetra::Execution::Edge.new(identity: ->(c) { c }, facts: facts, authority: @authority)
    Vetra::Execution::Runner.new(linked: linked, catalog: catalog, edge: edge, unit: Vetra::Data::UnitOfWork.new(@ops_db, limits: false, **options))
  end

  def test_a_collection_query_is_admitted_by_the_role_and_filtered_row_by_row
    mine, other = chat_fixture(owner: @actor)[0], chat_fixture(owner: @other)[0]
    tables = { 'rooms' => [mine.merge(name: 'Minha'), other.merge(name: 'Alheia')], 'users' => [{ id: @actor, name: 'Eu', email: 'e@probe.invalid', created_at: @now }],
               'room_memberships' => [{ id: id, room_id: mine[:id], user_id: @actor, created_at: @now }] }
    runner = build_runner('chat', tables, { 'rooms' => [], 'users' => [], 'room_memberships' => [] })
    outcome = runner.run('chat.my_rooms', {}, credentials: Vetra::Execution::Identity.new(actor_id: @actor, roles: ['chat.authenticated']))
    assert outcome.ok?, outcome.diagnostics.map(&:to_s).join
    assert_equal ['Minha'], outcome.value.map(&:name)
    assert_equal 0, @facts_db.sqls.count { |sql| sql.include?('room_memberships') }, 'a admissão de uma coleção não lê fatos'
  end

  def test_add_member_by_email_is_refused_in_the_body_because_uses_grants_no_data
    room, _user, tables = chat_fixture(owner: @actor)
    runner = build_runner('chat', tables)
    identity = Vetra::Execution::Identity.new(actor_id: @actor, roles: ['chat.authenticated'])
    error = assert_raises(Vetra::Data::Error) { runner.run('chat.add_member_by_email', { room_id: room[:id], email: 'ana@probe.invalid' }, credentials: identity) }
    assert_equal 'data_authorization_denied', error.code
    assert_includes @ops_db.sqls, 'ROLLBACK'
    refute(@ops_db.sqls.any? { |sql| sql.start_with?('INSERT') })
  end

  def test_add_member_runs_end_to_end_for_the_owner_and_publishes_the_generation
    room, user, tables = chat_fixture(owner: @actor)
    runner = build_runner('chat', tables)
    identity = Vetra::Execution::Identity.new(actor_id: @actor, roles: ['chat.authenticated'])
    before = @authority.call
    outcome = runner.run('chat.add_member', { room_id: room[:id], user_id: user[:id] }, credentials: identity)
    assert outcome.ok?, outcome.diagnostics.map(&:to_s).join
    assert(@ops_db.sqls.any? { |sql| sql.start_with?('INSERT INTO "public"."room_memberships"') })
    assert_equal before + 1, @authority.call
  end

  def test_create_room_runs_through_the_final_reauthorization
    room, _user, tables = chat_fixture(owner: @actor, member: false)
    tables['users'] = [{ id: @actor, name: 'Eu', email: 'eu@probe.invalid', created_at: @now }]
    runner = build_runner('chat', tables)
    outcome = runner.run('chat.create_room', { name: 'Nova' }, credentials: Vetra::Execution::Identity.new(actor_id: @actor, roles: ['chat.authenticated']))
    assert outcome.ok?, outcome.diagnostics.map(&:to_s).join
    assert_equal room[:id], outcome.value.id
  end

  def test_the_runner_refuses_a_final_state_the_policies_do_not_authorize_and_still_publishes
    mine = post(@actor)
    state = mine.dup
    tables = { 'posts' => lambda do |sql|
      state = state.merge(author_id: @other) if sql.start_with?('UPDATE')
      [state]
    end }
    runner = build_runner('blog', tables)
    before = @authority.call
    error = assert_raises(Vetra::Data::Error) do
      runner.run('blog.update_post', { id: mine[:id], author_id: @other }, credentials: Vetra::Execution::Identity.new(actor_id: @actor, roles: ['blog.autor']))
    end
    assert_equal 'data_authorization_final', error.code
    assert_includes @ops_db.sqls, 'ROLLBACK'
    refute_includes @ops_db.sqls, 'COMMIT'
    assert_equal before + 1, @authority.call
  end

  def lead_row(tenant, status: 'new')
    { id: id, company_id: tenant, name: 'Cliente', email: nil, status: status, valor_amount: nil, valor_currency: nil, created_at: @now }
  end

  def test_a_system_actor_is_admitted_only_by_the_calls_of_its_handler_and_needs_no_facts
    tenant = id
    runner = build_runner('mini_crm', {}, {}, scoped: true)
    system = Vetra::Execution::Identity.new(tenant_id: tenant, system_actor: 'crm.notify_sales')
    outcome = runner.run('crm.win_lead', { lead_id: id }, credentials: system)
    assert_equal :denied, outcome.status
    assert_equal 'data_authorization_system_actor', outcome.code
    assert_empty @ops_db.sqls
    assert_empty @facts_db.sqls

    with_app('mini_crm') do |root, compiler|
      edit(root, 'app/domains/crm/notify_sales.rb') { |source| source.sub("  uses :mailer\n", "  uses :mailer\n  calls :win_lead\n") }
      compiler.write
      lead = lead_row(tenant)
      state = lead.dup
      tables = { 'leads' => lambda do |sql|
        state = state.merge(status: 'won') if sql.start_with?('UPDATE')
        [state]
      end }
      allowed = build_runner(compiler.link, tables, {}, scoped: true)
      outcome = allowed.run('crm.win_lead', { lead_id: lead[:id] }, credentials: system)
      assert outcome.ok?, outcome.diagnostics.map(&:to_s).join
      assert_equal 'won', outcome.value.status
      assert_empty @facts_db.sqls, 'o ator de sistema não lê fatos de papéis'
      assert_equal 'data_authorization_system_actor',
                   allowed.run('crm.update_lead', { id: lead[:id], name: 'Outro nome' }, credentials: system).code
      other = Vetra::Execution::Identity.new(tenant_id: tenant, system_actor: 'crm.inexistente')
      assert_equal 'data_authorization_system_actor', allowed.run('crm.win_lead', { lead_id: lead[:id] }, credentials: other).code
    end
  end

  # ---- rodada 1 da auditoria -------------------------------------------------------------------------------------------

  def test_a_rolled_back_savepoint_takes_the_recorded_writes_and_cached_facts_with_it
    mine = post(@actor)
    state = mine.dup
    blog_unit('posts' => lambda { |sql| state = state.merge(author_id: @other) if sql.start_with?('UPDATE'); [state] })
    error = assert_raises(Vetra::Data::Error) do
      within do |unit, posts|
        begin
          unit.compose do
            posts.delete!(mine[:id])
            raise Sequel::Rollback, 'desfeito'
          end
        rescue Sequel::Rollback
          nil
        end
        # A linha apagada dentro do savepoint voltou: transferi-la para outro autor precisa ser pego no estado final.
        posts.update!(mine[:id], author_id: @other)
        @guard.reauthorize!
      end
    end
    assert_equal 'data_authorization_final', error.code
  end

  def test_a_completed_savepoint_keeps_what_the_guard_recorded
    mine = post(@actor)
    state = mine.dup
    blog_unit('posts' => lambda { |sql| state = state.merge(author_id: @other) if sql.start_with?('UPDATE'); [state] })
    error = assert_raises(Vetra::Data::Error) do
      within do |unit, posts|
        unit.compose { posts.update!(mine[:id], author_id: @other) }
        @guard.reauthorize!
      end
    end
    assert_equal 'data_authorization_final', error.code
  end

  def test_recreating_a_deleted_id_makes_the_row_existing_again_for_the_final_state
    mine = post(@actor)
    state = mine.dup
    blog_unit('posts' => lambda { |sql| state = state.merge(author_id: @other) if sql.start_with?('UPDATE'); [state] })
    error = assert_raises(Vetra::Data::Error) do
      within do |_, posts|
        posts.delete!(mine[:id])
        posts.create!(title: 'Recriado', author_id: @actor)
        posts.update!(mine[:id], author_id: @other)
        @guard.reauthorize!
      end
    end
    assert_equal 'data_authorization_final', error.code
    assert_includes @db.sqls, 'ROLLBACK'
  end

  def test_without_a_static_grant_the_answer_does_not_depend_on_the_row_existing
    chat = self.class.linked('chat')
    catalog = Vetra::Data::Repositories.new(chat.document)
    user = { id: id, name: 'Ana', email: 'ana@probe.invalid', created_at: @now }
    room = { id: id, owner_id: @actor, name: 'Sala', created_at: @now }
    [[[user], [room]], [[], []]].each do |users, rooms|
      unit = Vetra::Data::UnitOfWork.new(routed_db('users' => users, 'rooms' => rooms), scope: :global, limits: false)
      guard = Vetra::Execution::AccessGuard.new(authorization: Vetra::Execution::Authorization.new(chat.document), catalog: catalog,
                                                unit: unit, roles: ['chat.authenticated'])
      unit.transaction(actor_id: @actor, op_id: id, cmd: 'chat.add_member', guard: guard) do |active|
        users_read = catalog.bind('chat.users_read', unit: active)
        rooms_repo = catalog.bind('chat.rooms', unit: active)
        assert_equal 'data_authorization_denied', refusal_code { users_read.find!(user[:id]) }
        assert_equal 'data_authorization_denied', refusal_code { users_read.find!(id) }
        # O papel não tem `update` nem `delete` na sala: a recusa é estática, exista a sala ou não.
        assert_equal 'data_authorization_denied', refusal_code { rooms_repo.update!(room[:id], name: 'x') }
        assert_equal 'data_authorization_denied', refusal_code { rooms_repo.update!(id, name: 'x') }
        assert_equal 'data_authorization_denied', refusal_code { rooms_repo.delete!(id) }
      end
    end
  end

  def test_create_is_authorized_before_its_transition_is_checked
    blog_unit('posts' => [post(@actor)])
    within do |_, posts|
      # Em nome de outro autor E com um valor protegido: a recusa de permissão vem primeiro.
      assert_equal 'data_authorization_denied', refusal_code { posts.create!(title: 'x', author_id: @other, status: 'published') }
    end
  end

  def test_facts_read_before_a_junction_write_in_the_same_operation_are_not_reused_after_it
    room, _user, tables = chat_fixture(owner: @actor, member: false)
    memberships = []
    tables['room_memberships'] = lambda do |sql|
      memberships << { id: id, room_id: room[:id], user_id: @actor, created_at: @now } if sql.start_with?('INSERT INTO "public"."room_memberships"')
      memberships
    end
    tables['users'] = [{ id: @actor, name: 'Eu', email: 'eu@probe.invalid', created_at: @now }]
    chat_unit(tables)
    @claims[:cmd] = 'chat.create_room'
    @unit.transaction(**@claims) do |unit|
      rooms = @catalog.bind('chat.rooms', unit: unit)
      # Aquece o cache dos fatos (a junção vazia): nenhuma sala é legível ainda.
      assert_empty rooms.order(:name).all
      created = rooms.create!(name: 'Nova')
      assert_equal room[:id], created.id
      # O vínculo do dono acabou de entrar: ler a sala nova só passa se os fatos antigos foram descartados.
      assert_equal room[:id], rooms.find!(created.id).id
    end
  end

  def test_a_junction_write_without_its_invalidation_would_be_read_stale
    room, _user, tables = chat_fixture(owner: @actor, member: false)
    chat_unit(tables)
    @unit.transaction(**@claims) do |unit|
      rooms = @catalog.bind('chat.rooms', unit: unit)
      assert_empty rooms.order(:name).all
      tables['room_memberships'] << { id: id, room_id: room[:id], user_id: @actor, created_at: @now }
      assert_empty rooms.order(:name).all, 'sem invalidar, a guarda ainda usa o fato lido antes'
      @guard.touched!('chat.room_membership')
      assert_equal [room[:id]], rooms.order(:name).all.map(&:id)
    end
  end

  def test_leaving_compose_by_break_return_or_throw_keeps_what_the_guard_recorded
    mine = post(@actor)
    state = mine.dup
    exits = {
      break: ->(unit, posts) { unit.compose { posts.update!(mine[:id], author_id: @other); break } },
      throw: ->(unit, posts) { catch(:sai) { unit.compose { posts.update!(mine[:id], author_id: @other); throw :sai } } }
    }
    exits.each do |name, leave|
      state = mine.dup
      blog_unit('posts' => lambda { |sql| state = state.merge(author_id: @other) if sql.start_with?('UPDATE'); [state] })
      error = assert_raises(Vetra::Data::Error, name.to_s) do
        within do |unit, posts|
          leave.call(unit, posts)
          @guard.reauthorize!
        end
      end
      assert_equal 'data_authorization_final', error.code, name.to_s
      assert_includes @db.sqls, 'ROLLBACK', name.to_s
    end
  end

  def test_a_call_that_leaves_by_throw_never_commits_and_skips_neither_the_rollback_nor_the_publication
    with_app('blog') do |root, compiler|
      edit(root, 'app/domains/blog/publish_post.rb') do |source|
        source.sub(/^(\s*)fail! :status.*$/) { "#{Regexp.last_match(1)}posts.update!(post, author_id: #{@other.inspect})\n#{Regexp.last_match(1)}throw :sair" }
      end
      compiler.write
      mine = post(@actor)
      state = mine.dup
      tables = { 'posts' => lambda do |sql|
        state = state.merge(author_id: @other) if sql.start_with?('UPDATE')
        [state]
      end }
      runner = build_runner(compiler.link, tables)
      before = @authority.call
      catch(:sair) do
        runner.run('blog.publish_post', { post_id: mine[:id] }, credentials: Vetra::Execution::Identity.new(actor_id: @actor, roles: ['blog.autor']))
        flunk 'o throw devia sair do Runner'
      end
      statements = @ops_db.sqls
      assert_includes statements, 'ROLLBACK'
      refute_includes statements, 'COMMIT'
      assert_equal before + 1, @authority.call, 'a geração é publicada mesmo na saída não local'
    end
  end

  def test_repositories_outside_the_runner_keep_their_behavior_without_a_guard
    blog_unit('posts' => [post(@other)])
    @unit.transaction(actor_id: @actor, op_id: id, cmd: 'blog.update_post') do |unit|
      posts = @catalog.bind('blog.posts', unit: unit)
      assert_nil unit.guard
      assert posts.find!(id)
      assert_equal 1, posts.order(:title).all.size
    end
  end
end

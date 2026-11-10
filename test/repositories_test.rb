require_relative 'test_helper'
require 'vetra/data'
require 'securerandom'
require 'minitest/mock'

class RepositoriesTest < GraphTest
  EXAMPLES = %w[blog chat mini_crm mini_crm_revendas].freeze

  def document(example = 'blog')
    JSON.parse(File.read(File.join(PROJECT, 'examples', example, '.vetra/graph.json')))
  end

  def setup
    @db = Sequel.mock(host: :postgres)
    @time = Time.iso8601('2026-11-06T12:34:56.123456Z')
    @actor, @tenant, @id = Array.new(3) { SecureRandom.uuid }
    @claims = { op_id: SecureRandom.uuid, actor_id: @actor, cmd: 'blog.create_post' }
    @work = Vetra::Data::UnitOfWork.new(@db, limits: false, scope: :global, clock: -> { @time })
    @catalog = Vetra::Data::Repositories.new(document)
    @posts = @catalog.bind('blog.posts', unit: @work)
  end

  def transaction(cmd = 'blog.create_post', &block)
    @work.transaction(**@claims.merge(cmd: cmd), &block)
  end

  def post(**changes)
    { id: @id, title: 'Post', author_id: @actor, status: 'draft', published_at: nil, created_at: @time }.merge(changes)
  end

  def crm
    @catalog = Vetra::Data::Repositories.new(document('mini_crm'))
    issuer = Vetra::Data::ContextIssuer.new(kid: 'test', secret: SecureRandom.random_bytes(32))
    @work = Vetra::Data::UnitOfWork.new(@db, limits: false, issuer: issuer, clock: -> { @time })
    @claims.merge!(tenant_id: @tenant, cmd: 'crm.update_lead')
    @leads = @catalog.bind('crm.leads', unit: @work)
  end

  def lead(**changes)
    { id: @id, company_id: @tenant, name: 'Lead', status: 'new', email: nil,
      valor_amount: nil, valor_currency: nil, created_at: @time }.merge(changes)
  end

  def chat
    @catalog = Vetra::Data::Repositories.new(document('chat'))
    @rooms = @catalog.bind('chat.rooms', unit: @work)
    @users = @catalog.bind('chat.users', unit: @work)
  end

  def test_generates_a_distinct_repository_and_data_type_for_every_entity_of_all_examples
    EXAMPLES.each do |example|
      doc = document(example)
      factory = Vetra::Data::Repositories.new(doc)
      entities = doc['nodes'].select { |node| node['kind'] == 'entity' }
      assert_equal entities.map { |node| node['id'] }.sort, factory.entity_ids
      assert_equal entities.size, entities.map { |node| factory.record_type(node['id']) }.uniq.size
      entities.each do |entity|
        type = factory.record_type(entity['id'])
        assert_operator type, :<, ::Data
        assert_equal entity['fields'].map { |field| field['name'].to_sym }.sort, type.members.sort
        capability = doc['nodes'].find { |node| node.dig('config', 'entity', 'id') == entity['id'] }
        repository = factory.bind(capability['id'], unit: @work)
        %i[find! lock! create! update! delete! where order first last all].each { |method| assert_respond_to repository, method }
        %i[dataset db pool sql prepare call join select].each { |method| refute_respond_to repository, method }
      end
    end
    assert_graph_error('data_repository') { @catalog.bind('blog.unknown', unit: @work) }
    assert_graph_error('data_repository') { @catalog.record_type('blog.missing') }
  end

  def test_factory_copies_the_ir_and_never_connects_or_alters_it
    input = document
    original = Marshal.dump(input)
    factory = Vetra::Data::Repositories.new(input)
    assert_equal original, Marshal.dump(input)
    input['nodes'].clear
    assert_equal %w[blog.comment blog.post], factory.entity_ids
    assert_empty @db.sqls
  end

  def test_every_example_entity_is_decoded_into_its_shareable_data_type
    EXAMPLES.each do |example|
      doc = document(example)
      catalog = Vetra::Data::Repositories.new(doc)
      issuer = Vetra::Data::ContextIssuer.new(kid: 'test', secret: SecureRandom.random_bytes(32))
      work = Vetra::Data::UnitOfWork.new(@db, limits: false, scope: doc['app']['tenant'] ? :tenant : :global, issuer: issuer)
      claims = @claims.merge(tenant_id: doc['app']['tenant'] ? @tenant : nil)
      doc['nodes'].select { |entry| entry['kind'] == 'entity' }.each do |entity|
        row = entity['fields'].each_with_object({}) do |field, values|
          name = field['name'].to_sym
          case field.dig('type', 'name')
          when 'id' then values[name] = @id
          when 'timestamp' then values[name] = field['nullable'] ? nil : @time
          when 'enum' then values[name] = field.dig('type', 'values').first
          when 'money' then values.merge!("#{name}_amount".to_sym => BigDecimal('1.23'), "#{name}_currency".to_sym => 'BRL')
          when 'boolean' then values[name] = false
          else values[name] = 'Valor'
          end
        end
        @db.fetch = ->(sql) { sql.include?('set_config') ? [] : [row] }
        capability = doc['nodes'].find { |entry| entry.dig('config', 'entity', 'id') == entity['id'] }
        record = work.read(**claims) { catalog.bind(capability['id'], unit: work).find!(@id) }
        assert_instance_of catalog.record_type(entity['id']), record
        assert Ractor.shareable?(record), entity['id']
        assert Ractor.shareable?(record.with)
      end
    end
  end

  def test_find_and_lock_return_records_and_parameterized_qualified_sql
    @db.fetch = post
    record = transaction { @posts.find!(@id) }
    assert_instance_of @catalog.record_type('blog.post'), record
    assert_equal @id, record.id
    sql = @db.sqls.find { |statement| statement.start_with?('SELECT') }
    assert_match(/FROM "public"\."posts" WHERE \("id" = \$1\)/, sql)
    refute_includes sql.split(' -- args:').first, @id
    transaction { @posts.lock!(@id) }
    assert @db.sqls.any? { |statement| statement.include?('FOR UPDATE') }
    assert_empty @db.prepared_statements
  end

  def test_absent_records_are_indistinguishable_across_find_lock_update_delete
    [-> { @posts.find!(@id) }, -> { @posts.lock!(@id) },
     -> { @posts.update!(@id, title: 'Another') }, -> { @posts.delete!(@id) }].each do |operation|
      error = assert_raises(Vetra::Data::RecordNotFound) { transaction { operation.call } }
      assert_equal 'data_record_not_found', error.code
      assert_nil error.cause
      refute_includes error.full_message, @id
    end
  end

  def test_create_applies_context_defaults_and_the_operation_clock_and_returns_persisted_record
    @db.fetch = post
    result = transaction do |unit|
      @time += 60
      unit.compose { @posts.create!(title: 'Post') }
    end
    sql = @db.sqls.find { |statement| statement.start_with?('INSERT') }
    assert_includes sql, 'RETURNING *'
    assert_includes sql, @actor
    assert_includes sql, 'draft'
    assert_includes sql, '12:34:56.123456'
    refute_match(/\("id",/, sql)
    assert_equal @id, result.id
  end

  def test_update_by_id_and_record_reloads_old_and_preserves_created_at
    @db.fetch = lambda { |sql| [sql.start_with?('UPDATE') ? post(title: 'Updated') : post] }
    transaction do
      original = @posts.find!(@id)
      stale = original.with(status: 'published', author_id: SecureRandom.uuid)
      updated = @posts.update!(stale, title: 'Updated')
      assert_equal 'draft', updated.status
      assert_equal @actor, updated.author_id
      assert_equal original.created_at, updated.created_at
      refute_same original, updated
      assert_equal 'Updated', @posts.update!(@id, title: 'Updated').title
    end
    sql = @db.sqls
    assert_equal 2, sql.count { |statement| statement.include?('FOR UPDATE') }
    assert_equal 2, sql.count { |statement| statement.start_with?('UPDATE') }
    sql.grep(/^UPDATE/).each { |statement| refute_match(/SET.*created_at/, statement) }
  end

  def test_delete_accepts_id_and_record_and_returns_the_deleted_value
    @db.fetch = post
    transaction do
      assert_equal @id, @posts.delete!(@id).id
      record = @catalog.record_type('blog.post').new(**post)
      assert_equal record, @posts.delete!(record)
    end
    assert_equal 2, @db.sqls.count { |statement| statement.start_with?('DELETE') && statement.include?('RETURNING *') }
  end

  def test_every_terminal_requires_the_unit_in_the_current_fiber
    query = @posts.where(title: 'Post')
    [-> { @posts.find!(@id) }, -> { @posts.lock!(@id) }, -> { @posts.create!(title: 'Post') },
     -> { @posts.update!(@id, title: 'Post') }, -> { @posts.delete!(@id) },
     -> { query.first(2) }, -> { query.last(2) }, -> { query.all }].each do |operation|
      assert_graph_error('data_transaction_required', &operation)
    end
    assert_empty @db.sqls
    transaction do
      Fiber.new { assert_graph_error('data_transaction_required') { query.all } }.resume
    end
    @db.sqls
    @db.transaction { assert_graph_error('data_transaction_required') { query.all } }
    refute @db.sqls.any? { |sql| sql.include?('posts') }
  end

  def test_read_capability_and_read_only_unit_refuse_all_writes_before_sql
    chat
    read = @catalog.bind('chat.rooms_read', unit: @work)
    [read, @rooms].each do |repository|
      execute = repository == read ? :transaction : :read
      @work.public_send(execute, **@claims) do
        @db.sqls
        [-> { repository.lock!(@id) }, -> { repository.create!(name: 'Room') },
         -> { repository.update!(@id, name: 'Room') }, -> { repository.delete!(@id) },
         -> { repository.add_member!(@id, @actor) }, -> { repository.remove_member!(@id, @actor) }].each do |operation|
          assert_graph_error('data_read_only', &operation)
        end
        assert_empty @db.sqls
      end
    end
  end

  def test_tenant_and_root_are_always_scoped_and_assigned_from_the_context
    crm
    @db.fetch = lambda { |sql| sql.include?('set_config') ? [] : [sql.include?('companies') ? { id: @tenant, name: 'Company', created_at: @time } : lead] }
    transaction('crm.create_lead') do
      @leads.create!(name: 'Lead')
      @leads.find!(@id)
      @leads.lock!(@id)
      @leads.update!(@id, name: 'Lead')
      @leads.delete!(@id)
      @leads.all
      companies = @catalog.bind('crm.companies', unit: @work)
      assert_equal @tenant, companies.create!(name: 'Company').id
      companies.find!(@tenant)
      assert_graph_error('data_assignment') { @leads.create!(company_id: SecureRandom.uuid, name: 'Lead') }
      assert_graph_error('data_assignment') { @leads.update!(@id, company_id: @tenant) }
      assert_graph_error('data_assignment') { companies.create!(id: @tenant, name: 'Company') }
    end
    sql = @db.sqls
    sql.grep(/^(SELECT|UPDATE|DELETE).*"leads"/).each { |statement| assert_match(/"company_id" = \$\d/, statement) }
    assert sql.grep(/^INSERT/).any? { |statement| statement.include?(@tenant) }
    assert sql.any? { |statement| statement.match?(/FROM "public"\."companies" WHERE.*"id" = \$1/) }
    global = Vetra::Data::UnitOfWork.new(@db, limits: false, scope: :global)
    global.read(**@claims.except(:tenant_id)) do
      repository = @catalog.bind('crm.companies_read', unit: global)
      assert_graph_error('data_scope') { repository.all }
    end
  end

  def test_update_does_not_trust_the_tenant_or_status_of_a_forged_record
    crm
    @db.fetch = lambda { |sql| sql.include?('set_config') ? [] : [lead(status: 'won')] }
    forged = @catalog.record_type('crm.lead').new(**lead.except(:valor_amount, :valor_currency).merge(valor: nil, company_id: SecureRandom.uuid))
    transaction('crm.update_lead') do
      assert_graph_error('data_transition') { @leads.update!(forged, status: 'new') }
    end
    refute @db.sqls.any? { |sql| sql.start_with?('UPDATE') }
  end

  def test_guarded_checks_both_old_and_new_values_and_allows_unchanged_values
    crm
    @db.fetch = lambda { |sql| sql.include?('set_config') ? [] : [lead] }
    transaction('crm.create_lead') { assert_graph_error('data_transition') { @leads.create!(name: 'Lead', status: 'won') } }
    transaction('crm.update_lead') do
      error = assert_graph_error('data_transition') { @leads.update!(@id, status: 'won') }
      assert_includes error.message, 'status'
      assert_includes error.message, 'crm.win_lead'
    end
    refute @db.sqls.any? { |sql| sql.start_with?('INSERT', 'UPDATE') }
    @db.fetch = lambda { |sql| sql.include?('set_config') ? [] : [lead(status: 'won')] }
    transaction('crm.update_lead') { assert_equal 'won', @leads.update!(@id, status: 'won').status }
    transaction('crm.win_lead') { assert_equal 'won', @leads.update!(@id, status: 'won').status }
  end

  def test_set_by_allows_creation_default_and_owner_command_but_rejects_other_commands
    comments = @catalog.bind('blog.comments', unit: @work)
    row = { id: @id, post_id: SecureRandom.uuid, author_name: 'Author', author_email: 'a@b', body: 'Body', approved: false, created_at: @time }
    @db.fetch = row
    transaction('blog.create_comment') do
      comments.create!(post_id: row[:post_id], author_name: 'Author', author_email: 'a@b', body: 'Body')
      assert_graph_error('data_transition') { comments.create!(**row.except(:id, :created_at).merge(approved: true)) }
      assert_graph_error('data_transition') { comments.update!(@id, approved: true) }
    end
    @db.fetch = lambda { |sql| [row.merge(approved: sql.start_with?('UPDATE'))] }
    transaction('blog.approve_comment') { assert comments.update!(@id, approved: true).approved }
  end

  def test_creation_time_and_identity_cannot_be_reassigned
    @db.fetch = post
    transaction do
      assert_graph_error('data_assignment') { @posts.create!(title: 'Post', created_at: @time) }
      assert_graph_error('data_assignment') { @posts.update!(@id, created_at: @time) }
      assert_graph_error('data_assignment') { @posts.update!(@id, id: SecureRandom.uuid) }
    end
    refute @db.sqls.any? { |sql| sql.start_with?('SELECT', 'INSERT', 'UPDATE') }
  end

  def test_set_by_defaults_are_compared_as_typed_values_including_context_and_money
    with_app do |root, compiler|
      edit(root, 'app/domains/blog/post.rb') do |source|
        source.sub('  crud scope: :author', <<~RUBY)
          decimal :tax, precision: 6, scale: 2, default: "1.23", set_by: :publish_post
          money :price, default: { amount: "2.50", currency: "BRL" }, set_by: :publish_post
          date :day, default: "2026-11-06", set_by: :publish_post
          timestamp :scheduled_at, default: "2026-11-06T12:34:56.123456Z", set_by: :publish_post
          id :assigned_id, default: :current_actor, set_by: :publish_post
          crud scope: :author
        RUBY
      end
      catalog = Vetra::Data::Repositories.new(compiler.build.document)
      posts = catalog.bind('blog.posts', unit: @work)
      @db.fetch = post.merge(tax: BigDecimal('1.23'), price_amount: BigDecimal('2.50'), price_currency: 'BRL',
                            day: Date.new(2026, 11, 6), scheduled_at: @time, assigned_id: @actor)
      transaction do
        record = posts.create!(title: 'Post')
        assert_equal BigDecimal('1.23'), record.tax
        assert_equal BigDecimal('2.50'), record.price.amount
        assert_equal @time, record.scheduled_at
        assert_equal @actor, record.assigned_id
        assert Ractor.shareable?(record)
        assert_equal record, posts.create!(title: 'Post', tax: '1.23', price: { amount: '2.50' },
                                          day: '2026-11-06', scheduled_at: @time, assigned_id: @actor)
        assert_graph_error('data_transition') { posts.create!(title: 'Post', tax: '1.24') }
        assert_graph_error('data_transition') { posts.create!(title: 'Post', assigned_id: SecureRandom.uuid) }
      end
    end
  end

  def test_restricted_query_is_immutable_ands_equalities_and_keeps_last_in_declared_order
    chat
    messages = @catalog.bind('chat.messages_read', unit: @work)
    message = { id: @id, room_id: SecureRandom.uuid, author_id: @actor, body: 'Body', created_at: @time }
    ids = Array.new(3) { SecureRandom.uuid }.sort
    @db.fetch = ids.reverse.map { |id| message.merge(id: id) }
    room = message[:room_id].dup
    base = messages.where(room_id: room)
    query = base.where(body: 'Body').order(:created_at, :id)
    room.replace(SecureRandom.uuid)
    assert base.frozen?
    assert query.frozen?
    refute_respond_to query, :dataset
    result = transaction { query.last(3) }
    assert_equal ids, result.map(&:id)
    assert result.frozen?
    sql = @db.sqls.find { |statement| statement.start_with?('SELECT') }
    assert_match(/"room_id" = \$1.*AND.*"body" = \$2/, sql)
    assert_includes sql, message[:room_id]
    assert_match(/ORDER BY "created_at" DESC, "id" DESC LIMIT/, sql)
    transaction { base.first(2) }
    assert_match(/ORDER BY "id" LIMIT/, @db.sqls.find { |statement| statement.start_with?('SELECT') })
    transaction { messages.order(:body).all }
    assert_match(/ORDER BY "body", "id"/, @db.sqls.find { |statement| statement.start_with?('SELECT') })
  end

  def test_queries_reject_unknown_fields_sql_expressions_collections_blocks_and_invalid_limits
    assert_graph_error('data_field') { @posts.where(unknown: 'x') }
    assert_graph_error('data_field') { @posts.order(:unknown) }
    assert_graph_error('data_field') { @posts.order(Sequel.lit('id DESC')) }
    [Sequel.lit('true'), ['draft'], { gt: 'draft' }].each do |value|
      assert_graph_error('data_value') { @posts.where(status: value) }
    end
    [0, -1, 1.5, '1', nil].each do |n|
      assert_graph_error('data_query') { @posts.first(n) }
      assert_graph_error('data_query') { @posts.last(n) }
    end
    [-> { @posts.where { true } }, -> { @posts.order(:id) {} }, -> { @posts.all {} },
     -> { @posts.first(1) {} }, -> { @posts.last(1) {} }].each { |operation| assert_graph_error('data_query', &operation) }
    transaction { assert_graph_error('data_field') { @posts.create!(unknown: 'x') } }
    refute @db.sqls.any? { |statement| statement.include?('posts') }
  end

  def test_records_with_and_money_are_deeply_immutable_shareable_and_have_no_persistence
    crm
    @db.fetch = lambda { |sql| sql.include?('set_config') ? [] : [lead(valor_amount: BigDecimal('123.45'), valor_currency: 'BRL')] }
    record = transaction { @leads.find!(@id) }
    assert Ractor.shareable?(record)
    assert_equal BigDecimal('123.45'), record.valor.amount
    assert_equal 'BRL', record.valor.currency
    assert record.valor.frozen?
    assert record.valor.currency.frozen?
    assert record.created_at.frozen?
    assert_raises(FrozenError) { record.name.replace('changed') }
    name = +'Outra'
    changed = record.with(name: name, status: 'won')
    name.replace('changed')
    assert_equal 'Outra', changed.name
    assert Ractor.shareable?(changed)
    assert changed.closed?
    refute record.closed?
    %i[name= status= save save! update! delete! destroy!].each { |method| refute_respond_to record, method }
    assert_raises(NoMethodError) { record.missing_field }
  end

  def test_nested_json_dates_and_decimal_are_immutable_in_construction_and_with
    type = ::Data.define(:payload, :date, :decimal) { include Vetra::Data::Record }
    payload = { 'nested' => [+'text'] }
    record = type.new(payload: payload, date: Date.new(2026, 11, 6), decimal: BigDecimal('1.23'))
    payload['nested'].first.replace('changed')
    assert_equal 'text', record.payload['nested'].first
    assert Ractor.shareable?(record)
    changed = record.with(payload: { 'x' => ['new'] })
    assert Ractor.shareable?(changed)
    assert_raises(FrozenError) { changed.payload['x'] << 'other' }
  end

  def test_normalization_slug_generation_context_defaults_and_physical_types
    with_app do |root, compiler|
      edit(root, 'app/domains/blog/post.rb') do |text|
        text.sub('crud scope:', 'slug :slug, from: :title\n  decimal :tax, precision: 6, scale: 2, default: "1.23"\n  json :payload, optional: true\n  date :day, optional: true\n  email :email, optional: true, normalize: :downcase\n  crud scope:'.gsub('\\n', "\n"))
      end
      doc = compiler.build.document
      catalog = Vetra::Data::Repositories.new(doc)
      posts = catalog.bind('blog.posts', unit: @work)
      row = post.merge(slug: 'acao-no-cafe', tax: BigDecimal('1.23'), payload: Sequel.pg_jsonb({ 'list' => ['nested'] }), day: Date.new(2026, 11, 6), email: 'a@b')
      @db.fetch = row
      transaction do
        record = posts.create!(title: 'Ação no café!', payload: { 'list' => ['nested'] }, day: '2026-11-06', email: 'A@B')
        assert_equal 'acao-no-cafe', record.slug
        assert_equal 'a@b', record.email
        assert_equal BigDecimal('1.23'), record.tax
        assert Ractor.shareable?(record)
        assert_equal({ 'list' => ['nested'] }, record.payload)
      end
      sql = @db.sqls.find { |statement| statement.start_with?('INSERT') }
      assert_includes sql, 'acao-no-cafe'
      assert_includes sql, 'a@b'
      assert_match(/::jsonb/, sql)
    end
  end

  def test_value_contract_refuses_float_money_excess_scale_overflow_and_invalid_timestamps
    crm
    transaction do
      [{ amount: 1.2 }, { amount: '1.234' }, { amount: 'NaN' }, { amount: '1', currency: 'XXX' },
       { amount: '1', currency: 'BHD' }, { amount: '100000000000000000.00' }, { amount: '1', sql: 'x' }].each do |value|
        assert_graph_error('data_value') { @leads.create!(name: 'Lead', valor: value) }
      end
      assert_graph_error('data_value') { @leads.create!(name: "bad\0name") }
      assert_graph_error('data_value') { @leads.create!(name: 'A') }
    end
    field = { 'nullable' => false, 'type' => { 'name' => 'timestamp' } }
    ['2026-11-06T12:00:00', '2026-11-06T12:00:00.1234567Z', 'invalid', Time.at(1, 1, :nanosecond)].each do |value|
      assert_graph_error('data_value') { Vetra::Data::Values.coerce(value, field, currency: 'BRL') }
    end
    [Object.new, Sequel.lit('x')].each { |value| assert_graph_error('data_value') { Vetra::Data::Values.immutable(value) } }
  end

  def test_value_contract_accepts_exact_values_and_does_not_mutate_input_times
    currency = 'BRL'
    decimal = { 'nullable' => false, 'type' => { 'name' => 'decimal', 'precision' => 6, 'scale' => 2 } }
    assert_equal BigDecimal('1.20'), Vetra::Data::Values.coerce('1.20', decimal, currency: currency)
    time = Time.iso8601('2026-11-06T10:00:00.123456-03:00')
    result = Vetra::Data::Values.timestamp(time)
    assert_equal(-10_800, time.utc_offset)
    assert_equal 0, result.utc_offset
    assert result.frozen?
    integer = { 'nullable' => false, 'type' => { 'name' => 'integer' } }
    assert_equal 2**63 - 1, Vetra::Data::Values.coerce(2**63 - 1, integer, currency: currency)
    assert_graph_error('data_value') { Vetra::Data::Values.coerce(2**63, integer, currency: currency) }
  end

  def test_money_is_split_for_writes_and_equalities_and_supports_nullable_pairs
    crm
    @db.fetch = ->(sql) { sql.include?('set_config') ? [] : [lead(valor_amount: BigDecimal('12.30'), valor_currency: 'BRL')] }
    transaction do
      created = @leads.create!(name: 'Lead', valor: { amount: '12.30' })
      @leads.update!(created, valor: created.valor.with(amount: BigDecimal('2.50')))
      @leads.where(valor: created.valor).all
      @leads.update!(@id, valor: nil)
    end
    sql = @db.sqls
    assert sql.any? { |statement| statement.match?(/^INSERT.*"valor_amount", "valor_currency"/) }
    assert sql.any? { |statement| statement.match?(/^SELECT.*"valor_amount" = \$\d.*"valor_currency" = \$\d/) }
    assert sql.any? { |statement| statement.match?(/^UPDATE.*"valor_amount" = NULL, "valor_currency" = NULL/) }
  end

  def test_json_array_decode_and_with_freeze_nested_values
    with_app do |root, compiler|
      edit(root, 'app/domains/blog/post.rb') { |text| text.sub('  crud', "  json :payload, optional: true\n  crud") }
      catalog = Vetra::Data::Repositories.new(compiler.build.document)
      @db.fetch = post.merge(payload: Sequel.pg_jsonb(['nested', { 'key' => 'value' }]))
      record = transaction { catalog.bind('blog.posts', unit: @work).find!(@id) }
      assert_equal ['nested', { 'key' => 'value' }], record.payload
      assert Ractor.shareable?(record)
      assert Ractor.shareable?(record.with(payload: { 'array' => ['other'] }))
      ['text', 42, true, false].each do |value|
        @db.fetch = post.merge(payload: value)
        created = transaction { catalog.bind('blog.posts', unit: @work).create!(title: 'Post', payload: value) }
        assert_equal value, created.payload
      end
    end
  end

  def test_links_check_owner_target_preserve_required_members_and_use_atomic_idempotent_insert
    chat
    member = SecureRandom.uuid
    room = { id: @id, owner_id: @actor, name: 'Room', created_at: @time }
    @db.fetch = lambda do |sql|
      if sql.include?('"rooms"') then [room]
      elsif sql.include?('"users"') then [{ id: member, name: 'Member', email: 'm@b', created_at: @time }]
      else []
      end
    end
    transaction('chat.add_member') { assert_equal @id, @rooms.add_member!(@id, member).id }
    insert = @db.sqls.find { |statement| statement.start_with?('INSERT') }
    assert_match(/ON CONFLICT \("room_id", "user_id"\) DO NOTHING/, insert)
    transaction('chat.remove_member') { @rooms.remove_member!(@id, member) }
    assert @db.sqls.any? { |statement| statement.start_with?('DELETE') && statement.include?('room_memberships') }
    assert_graph_error('data_transaction_required') { @rooms.add_member!(@id, member) }
    assert_graph_error('data_transaction_required') { @rooms.remove_member!(@id, member) }
    assert_empty @db.sqls
    @db.fetch = lambda { |sql| [sql.include?('"rooms"') ? room : { id: @actor, name: 'Owner', email: 'o@b', created_at: @time }] }
    transaction do
      assert_graph_error('data_required_link') { @rooms.remove_member!(@id, @actor) }
    end
    refute @db.sqls.any? { |statement| statement.start_with?('DELETE') }
  end

  def test_room_creation_includes_its_owner_via_the_generated_repository_method
    chat
    room = { id: @id, owner_id: @actor, name: 'Room', created_at: @time }
    @db.fetch = lambda { |sql| sql.include?('"rooms"') ? [room] : [{ id: @actor, name: 'Owner', email: 'o@b', created_at: @time }] }
    transaction('chat.create_room') { @rooms.create!(name: 'Room') }
    sql = @db.sqls
    assert_equal 2, sql.count { |statement| statement.start_with?('INSERT') }
    assert sql.any? { |statement| statement.include?('ON CONFLICT') && statement.include?(@actor) }
  end

  def test_record_type_refuses_field_collisions_before_generating_any_types
    %w[hash class with public_send to_h freeze members inspect dup send object_id].each do |name|
      doc = document('chat')
      fields = node(doc, 'entity', 'chat.user')['fields']
      fields << fields.find { |field| field['name'] == 'name' }.merge('name' => name)
      doc['digest'] = Vetra::Graph::Canonical.digest(doc)
      ::Data.stub(:define, ->(*) { flunk 'Gerou tipo antes de conferir os campos de todas as entidades.' }) do
        error = assert_graph_error('data_record_type') { Vetra::Data::Repositories.new(doc) }
        assert_equal 'Nome do campo colide com método do registro.', error.diagnostics.first.message
      end
    end
    assert_empty @db.sqls
  end

  def test_record_type_accepts_business_fields_without_method_collisions
    doc = document('chat')
    fields = node(doc, 'entity', 'chat.user')['fields']
    fields << fields.find { |field| field['name'] == 'name' }.merge('name' => 'status')
    doc['digest'] = Vetra::Graph::Canonical.digest(doc)
    catalog = Vetra::Data::Repositories.new(doc)
    record = catalog.record_type('chat.user').new(id: @id, name: 'User', email: 'u@b', created_at: @time, status: 'active')
    assert_equal 'active', record.status
    assert_equal [record], [record, record.with].uniq
    assert_equal 1, { record => 1 }[record.with]
  end

  def test_record_type_refuses_enum_predicate_collisions_and_ineligible_relations
    doc = document('mini_crm')
    node(doc, 'entity', 'crm.lead')['fields'].find { |field| field['name'] == 'status' }['type']['groups'] = { 'frozen' => ['won'] }
    doc['digest'] = Vetra::Graph::Canonical.digest(doc)
    assert_graph_error('data_record_type') { Vetra::Data::Repositories.new(doc) }
    doc = document('chat')
    node(doc, 'entity', 'chat.room_membership')['indexes'].clear
    doc['digest'] = Vetra::Graph::Canonical.digest(doc)
    assert_graph_error('data_relation') { Vetra::Data::Repositories.new(doc) }
  end

  def driver_error(klass, state = nil)
    error = klass.new('SECRET value and SELECT private SQL')
    if state
      result = Object.new
      result.define_singleton_method(:error_field) { |_field| state }
      wrapped = Object.new
      wrapped.define_singleton_method(:result) { result }
      error.wrapped_exception = wrapped
    end
    error
  end

  def test_public_conflicts_classify_constraints_serialization_and_deadlocks_without_driver_details
    [[Sequel::UniqueConstraintViolation, nil, :unique], [Sequel::ForeignKeyConstraintViolation, nil, :foreign_key],
     [Sequel::SerializationFailure, '40001', :serialization], [Sequel::SerializationFailure, '40P01', :deadlock],
     [Sequel::DatabaseError, '40P01', :deadlock]].each do |klass, state, kind|
      failure = driver_error(klass, state)
      @db.fetch = ->(_sql) { raise failure }
      error = assert_raises(Vetra::Data::Conflict) { transaction { @posts.create!(title: 'Post') } }
      assert_equal(kind == :serialization ? 'data_serialization' : 'data_conflict', error.code)
      assert_equal kind, error.kind
      assert_nil error.cause
      refute_includes error.full_message, 'SECRET'
      refute_includes error.full_message, 'SELECT private'
      assert_equal 'ROLLBACK', @db.sqls.last
    end
  end

  def test_database_access_denial_and_other_failures_are_sanitized_and_not_conflicts
    [['42501', 'data_access_denied'], ['23514', 'data_database']].each do |state, code|
      failure = driver_error(Sequel::DatabaseError, state)
      @db.fetch = ->(_sql) { raise failure }
      error = assert_graph_error(code) { transaction { @posts.find!(@id) } }
      refute_kind_of Vetra::Data::Conflict, error
      assert_nil error.cause
      refute_includes error.full_message, 'SECRET'
      refute_includes error.full_message, 'SELECT private'
    end
  end
end

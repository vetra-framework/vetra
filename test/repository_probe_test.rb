require_relative 'test_helper'
require_relative '../script/sonda_repositorios'

class RepositoryProbeTest < GraphTest
  def setup
    @actor, @tenant, @id = Array.new(3) { SecureRandom.uuid }
    @time = Time.iso8601('2026-11-06T12:00:00.123456Z')
  end

  def prepare(example)
    probe = RepositoriesProbe.new('unused')
    db = Sequel.mock(host: :postgres)
    tenant = example.start_with?('mini_crm')
    options = tenant ? { issuer: Vetra::Data::ContextIssuer.new(kid: 'test', secret: SecureRandom.random_bytes(32)) } : { scope: :global }
    work = Vetra::Data::UnitOfWork.new(db, **options, clock: -> { @time })
    linked = Vetra::Graph::Compiler.new(root: File.join(PROJECT, 'examples', example)).link
    { example: example, actor: @actor, tenants: [@tenant], actors: [@actor], work: work,
      runtime: db, catalog: Vetra::Data::Repositories.new(linked.document), linked: linked, executed: [] }.each do |name, value|
      probe.instance_variable_set("@#{name}", value)
    end
    yield probe, db, linked
    expected = linked.bindings.select { |binding| binding['kind'] == 'ruby' && %w[command query].include?(binding.dig('operation', 'kind')) }
      .map { |binding| binding.dig('operation', 'id') }.sort
    assert_equal expected, probe.instance_variable_get(:@executed).uniq.sort
    assert_empty db.prepared_statements
  end

  def invoke(probe, kind, id, attributes = {})
    probe.send(:invoke, kind, id, attributes)
  end

  def test_probe_executes_the_verified_call_of_both_crms_with_signed_context_and_real_repositories
    %w[mini_crm mini_crm_revendas].each do |example|
      prepare(example) do |probe, db, _linked|
        row = { id: @id, company_id: @tenant, name: 'Lead', email: nil, status: 'new',
                valor_amount: BigDecimal('1.23'), valor_currency: 'BRL', created_at: @time }
        row.merge!(dealer_id: SecureRandom.uuid, seller_id: nil) if example.end_with?('revendas')
        db.fetch = ->(sql) { sql.include?('set_config') ? [] : [row.merge(status: sql.start_with?('UPDATE') ? 'won' : 'new')] }
        assert invoke(probe, 'command', 'crm.win_lead', lead_id: @id).closed?
        db.fetch = ->(sql) { sql.include?('set_config') ? [] : [row.merge(status: 'won')] }
        error = assert_raises(RepositoriesProbe::BusinessRefusal) { invoke(probe, 'command', 'crm.win_lead', lead_id: @id) }
        assert_equal :status, error.field
        assert db.sqls.any? { |sql| sql.include?('set_config') }
      end
    end
  end

  def test_probe_executes_blog_calls_including_clock_and_update_by_id
    prepare('blog') do |probe, db, _linked|
      row = { id: @id, title: 'Post', status: 'draft', author_id: @actor, published_at: nil, created_at: @time }
      comment = { id: SecureRandom.uuid, post_id: @id, body: 'Body', author_name: 'Author', author_email: 'a@b', approved: true, created_at: @time }
      db.fetch = lambda do |sql|
        if sql.include?('"comments"') then [comment]
        else [sql.start_with?('UPDATE') ? row.merge(status: 'published', published_at: @time) : row]
        end
      end
      published = invoke(probe, 'command', 'blog.publish_post', post_id: @id)
      assert_equal 'published', published.status
      assert_equal @time, published.published_at
      assert_equal @id, invoke(probe, 'query', 'blog.find_post', post_id: @id).id
      assert invoke(probe, 'command', 'blog.approve_comment', comment_id: comment[:id]).approved
      refute db.sqls.any? { |sql| sql.include?('set_config') }
    end
  end

  def test_probe_executes_every_chat_call_with_linker_capability_order_and_read_downgrade
    prepare('chat') do |probe, db, linked|
      room = { id: @id, name: 'Room', owner_id: @actor, created_at: @time }
      member = { id: SecureRandom.uuid, name: 'Member', email: 'm@b', created_at: @time }
      message = { id: SecureRandom.uuid, room_id: @id, author_id: @actor, body: 'Body', created_at: @time }
      db.fetch = lambda do |sql|
        if sql.include?('"rooms"') then [room]
        elsif sql.include?('"users"') then [member]
        elsif sql.include?('"messages"') then [message]
        else []
        end
      end
      %w[add_member remove_member].each { |id| assert_equal @id, invoke(probe, 'command', "chat.#{id}", room_id: @id, user_id: member[:id]).id }
      assert_equal @id, invoke(probe, 'command', 'chat.add_member_by_email', room_id: @id, email: 'm@b').id
      page = invoke(probe, 'query', 'chat.room_page', room_id: @id)
      assert_equal [message[:id]], page[:messages].map(&:id)
      assert_equal [@id], invoke(probe, 'query', 'chat.my_rooms').map(&:id)
      assert_equal %w[chat.rooms_read chat.messages_read], linked.binding_for('query', 'chat.room_page')['arguments'].map { |argument| argument.dig('capability', 'id') }
      sql = db.sqls
      assert sql.any? { |statement| statement.include?('ON CONFLICT') }
      assert sql.any? { |statement| statement.include?('ORDER BY "created_at" DESC, "id" DESC LIMIT') }
    end
  end
end

require_relative 'test_helper'

class ManyToManyTest < GraphTest
  def with_chat(&block)
    with_app('chat', &block)
  end

  def members(document)
    node(document, 'entity', 'chat.room')['relations'].find { |relation| relation['name'] == 'members' }
  end

  def policy(document, entity, action)
    document.fetch('nodes').find do |entry|
      entry['kind'] == 'policy' && entry.dig('entity', 'id') == "chat.#{entity}" && entry['actions'].include?(action)
    end || raise('Política não encontrada')
  end

  def revalidate(document)
    document['digest'] = Vetra::Graph::Canonical.digest(document)
    Vetra::Graph::Validator.new.validate!(document)
  end

  def test_example_declares_the_junction_and_keeps_only_the_expected_warnings
    with_chat do |_root, compiler|
      result = compiler.build
      assert_equal %w[entity_no_policy entity_no_policy], result.warnings.map(&:code)
      relation = members(result.document)
      assert_equal 'many_to_many', relation['kind']
      assert_equal 'chat.user', relation.dig('target', 'id')
      assert_equal 'chat.room_membership', relation.dig('through', 'id')
      assert_equal ['id'], relation['local_fields']
      assert_equal ['id'], relation['target_fields']
      assert_equal ['owner'], relation['include_on_create']
      refute relation['same_tenant']
    end
  end

  def test_policies_traverse_the_relation_and_read_the_junction
    with_chat do |_root, compiler|
      document = compiler.build.document
      room = policy(document, 'room', 'read')
      actor_is_member = {
        'op' => 'exists', 'relation' => ['members'],
        'where' => { 'op' => 'eq', 'left' => { 'kind' => 'field', 'path' => ['id'] }, 'right' => { 'kind' => 'actor', 'path' => ['id'] } }
      }
      assert_equal actor_is_member, room['predicate']
      assert_equal %w[chat.room chat.room_membership chat.user], room['reads'].map { |reference| reference['id'] }
      message = policy(document, 'message', 'read')
      assert_equal({ 'op' => 'exists', 'relation' => ['room'], 'where' => actor_is_member }, message['predicate'])
      assert_equal %w[chat.message chat.room chat.room_membership chat.user], message['reads'].map { |reference| reference['id'] }
      assert_equal ['author_id'], policy(document, 'message', 'delete').dig('predicate', 'left', 'path')
    end
  end

  def test_tenant_application_uses_composite_keys_and_same_tenant
    with_app('mini_crm_revendas') do |root, compiler|
      edit(root, 'app/domains/crm/dealer.rb') { |text| text.sub("  has_many", "  many_to_many :staff, entity: :user, through: :membership\n  has_many") }
      relation = node(compiler.build.document, 'entity', 'crm.dealer')['relations'].find { |item| item['name'] == 'staff' }
      assert_equal %w[company_id id], relation['local_fields']
      assert_equal %w[company_id id], relation['target_fields']
      assert relation['same_tenant']
      refute relation.key?('include_on_create')
    end
  end

  def test_through_must_name_a_declared_entity
    with_chat do |root, compiler|
      edit(root, 'app/domains/chat/room.rb') { |text| text.sub('through: :room_membership', 'through: :missing') }
      assert_graph_error('reference_missing') { compiler.build }
    end
  end

  # Sem `through:`, o compilador gera a entidade de junção com o formato que a aplicação declararia à mão
  # (docs/fase-0.md, "Relações muitos-para-muitos"). O nome é <dono>_<relação no singular>.
  def test_omitting_through_generates_a_registered_junction
    with_chat do |root, compiler|
      FileUtils.rm(File.join(root, 'app/domains/chat/room_membership.rb'))
      edit(root, 'app/domains/chat/room.rb') { |text| text.sub(', through: :room_membership', '') }
      document = compiler.build.document
      relation = members(document)
      assert_equal 'chat.room_member', relation.dig('through', 'id')
      assert_equal ['owner'], relation['include_on_create']
      junction = node(document, 'entity', 'chat.room_member')
      assert_equal({ 'kind' => 'entity', 'id' => 'chat.room' }, junction['generated_from'])
      assert_equal 'room_members', junction.dig('storage', 'table')
      assert_equal %w[id room_id user_id], junction['fields'].map { |field| field['name'] }.sort
      assert_equal %w[room user], junction['relations'].map { |item| item['name'] }.sort
      assert junction['indexes'].any? { |index| index['unique'] && index['fields'] == %w[room_id user_id] }
      assert_nil junction['tenant']
      assert_equal %w[chat.room chat.room_member chat.user], policy(document, 'room', 'read')['reads'].map { |item| item['id'] }
    end
  end

  def test_target_is_inferred_from_the_relation_name_in_the_singular
    with_app('blog') do |root, compiler|
      write(root, 'app/domains/blog/tag.rb', "entity :tag do\n  string :name, required: true, unique: true, normalize: :downcase\nend\n")
      edit(root, 'app/domains/blog/post.rb') { |text| text.sub('  crud', "  many_to_many :tags\n  crud") }
      document = compiler.build.document
      relation = node(document, 'entity', 'blog.post')['relations'].find { |item| item['name'] == 'tags' }
      assert_equal 'blog.tag', relation.dig('target', 'id')
      assert_equal 'blog.post_tag', relation.dig('through', 'id')
      assert_equal %w[id post_id tag_id], node(document, 'entity', 'blog.post_tag')['fields'].map { |field| field['name'] }.sort
    end
  end

  def test_generated_junction_follows_the_application_tenant
    with_app('mini_crm_revendas') do |root, compiler|
      edit(root, 'app/domains/crm/lead.rb') { |text| text.sub('  crud', "  many_to_many :watchers, entity: :user\n  crud") }
      document = compiler.build.document
      junction = node(document, 'entity', 'crm.lead_watcher')
      assert_equal 'crm.company', junction.dig('tenant', 'entity', 'id')
      assert junction['relations'].all? { |item| item['same_tenant'] }
      assert junction['indexes'].any? { |index| index['unique'] && index['fields'] == %w[company_id lead_id user_id] }
      relation = node(document, 'entity', 'crm.lead')['relations'].find { |item| item['name'] == 'watchers' }
      assert_equal %w[company_id id], relation['local_fields']
      assert relation['same_tenant']
    end
  end

  def test_implicit_junction_refuses_what_it_cannot_infer_safely
    with_chat do |root, compiler|
      edit(root, 'app/domains/chat/room.rb') { |text| text.sub('  crud', "  many_to_many :gizmos\n  crud") }
      error = assert_graph_error('relation_target') { compiler.build }
      assert_includes error.message, 'chat.gizmo'
    end
    with_chat do |root, compiler|
      write(root, 'app/domains/chat/room_member.rb', "entity :room_member do\n  belongs_to :room\n  belongs_to :user\nend\n")
      edit(root, 'app/domains/chat/room.rb') { |text| text.sub(', through: :room_membership', '') }
      error = assert_graph_error('relation_through') { compiler.build }
      assert_includes error.message, 'chat.room_member'
    end
    with_chat do |root, compiler|
      edit(root, 'app/domains/chat/user.rb') { |text| text.sub("end\n", "  many_to_many :friends, entity: :user\nend\n") }
      error = assert_graph_error('relation_through') { compiler.build }
      assert_match(/auto-relações/, error.message)
    end
    with_app('mini_crm_revendas') do |root, compiler|
      edit(root, 'app/domains/crm/lead.rb') { |text| text.sub('  crud', "  many_to_many :partners, entity: :company\n  crud") }
      error = assert_graph_error('relation_through') { compiler.build }
      assert_match(/mesmo tratamento de tenant/, error.message)
    end
  end

  def test_junction_needs_exactly_one_belongs_to_per_side
    with_chat do |root, compiler|
      edit(root, 'app/domains/chat/room_membership.rb') { |text| text.sub("  belongs_to :room\n", '') }
      assert_graph_error('relation_through') { compiler.build }
    end
    with_chat do |root, compiler|
      edit(root, 'app/domains/chat/room_membership.rb') { |text| text.sub("  belongs_to :user\n", "  belongs_to :user\n  belongs_to :invited_by, entity: :user\n") }
      assert_graph_error('relation_through') { compiler.build }
    end
  end

  def test_self_relations_are_not_supported
    with_chat do |root, compiler|
      write(root, 'app/domains/chat/friendship.rb', "entity :friendship do\n  belongs_to :requester, entity: :user\n  belongs_to :addressee, entity: :user\nend\n")
      edit(root, 'app/domains/chat/user.rb') { |text| text.sub("end\n", "  many_to_many :friends, entity: :user, through: :friendship\nend\n") }
      error = assert_graph_error('relation_through') { compiler.build }
      assert_match(/auto-relações/, error.message)
    end
  end

  def test_include_must_be_a_belongs_to_of_the_entity_toward_the_target
    with_chat do |root, compiler|
      edit(root, 'app/domains/chat/room.rb') { |text| text.sub('include: :owner', 'include: :missing') }
      assert_graph_error('relation_include') { compiler.build }
    end
    with_chat do |root, compiler|
      write(root, 'app/domains/chat/topic.rb', "entity :topic do\n  string :title, required: true\nend\n")
      edit(root, 'app/domains/chat/room.rb') { |text| text.sub("  crud", "  belongs_to :topic, optional: true\n  crud").sub('include: :owner', 'include: :topic') }
      assert_graph_error('relation_include') { compiler.build }
    end
  end

  def test_validator_checks_the_junction_keys_and_include_list_in_the_ir
    with_chat do |_root, compiler|
      original = compiler.build.document

      document = Vetra::Graph::Data.copy(original)
      node(document, 'entity', 'chat.room_membership')['relations'].reject! { |relation| relation['name'] == 'user' }
      assert_graph_error('relation_through') { revalidate(document) }

      document = Vetra::Graph::Data.copy(original)
      members(document)['local_fields'] = ['owner_id']
      assert_graph_error('relation_through') { revalidate(document) }

      document = Vetra::Graph::Data.copy(original)
      members(document)['include_on_create'] = ['room']
      assert_graph_error('relation_include') { revalidate(document) }

      document = Vetra::Graph::Data.copy(original)
      node(document, 'entity', 'chat.room')['relations'].find { |relation| relation['name'] == 'owner' }['include_on_create'] = ['owner']
      assert_graph_error('relation_include') { revalidate(document) }

      document = Vetra::Graph::Data.copy(original)
      node(document, 'entity', 'chat.room')['relations'].find { |relation| relation['name'] == 'owner' }['through'] = Vetra::Graph::Data.reference('entity', 'chat.room_membership')
      assert_graph_error('relation_through') { revalidate(document) }

      document = Vetra::Graph::Data.copy(original)
      members(document).delete('through')
      assert_graph_error('relation_join') { revalidate(document) }
    end
  end

  def test_validator_requires_the_junction_among_the_policy_reads
    with_chat do |_root, compiler|
      document = Vetra::Graph::Data.copy(compiler.build.document)
      policy(document, 'room', 'read')['reads'].reject! { |reference| reference['id'] == 'chat.room_membership' }
      assert_graph_error('policy_reads') { revalidate(document) }
    end
  end

  def test_example_links_and_builds_reproducibly
    with_chat do |_root, compiler|
      expected = compiler.write
      linked = compiler.link
      assert_equal expected.document, linked.document
      assert_equal 8, linked.builtin_bindings.size
      assert_equal expected.bytes, compiler.build.bytes
    end
  end

  def test_diff_reports_a_changed_relation_for_review
    with_chat do |root, compiler|
      before = compiler.build.document
      edit(root, 'app/domains/chat/room.rb') { |text| text.sub(', include: :owner', '') }
      after = Vetra::Graph::Compiler.new(root: root).build.document
      changes = Vetra::Graph::Diff.new.compare(before, after).data['changes'].select { |change| change['id'] == 'chat.room' }
      assert_equal ['/relations/members'], changes.map { |change| change['path'] }
      assert_equal ['review'], changes.map { |change| change['impact'] }
    end
  end
end

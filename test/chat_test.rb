require_relative 'test_helper'

class ChatTest < GraphTest
  Room = ::Data.define(:id, :owner_id)
  Input = ::Data.define(:room_id, :user_id)

  class BodyFailure < StandardError
    attr_reader :field

    def initialize(field, message)
      @field = field
      super(message)
    end
  end

  class BodyContext
    def fail!(field, message)
      raise BodyFailure.new(field, message)
    end
  end

  # A body unit test, not an executor: authorization, transactions and RLS do not run here.
  class MemoryRooms
    attr_reader :members, :mutations

    def initialize(room, members:)
      @room = room
      @members = members.dup
      @mutations = []
      @locked = false
    end

    def lock!(id)
      raise KeyError, id unless id == @room.id
      @locked = true
      @room
    end

    def add_member!(room_id, user_id)
      check_lock(room_id)
      @members << user_id unless @members.include?(user_id)
      @mutations << [:add, room_id, user_id]
      nil
    end

    def remove_member!(room_id, user_id)
      check_lock(room_id)
      @members.delete(user_id)
      @mutations << [:remove, room_id, user_id]
      nil
    end

    def check_lock(id)
      raise 'A sala precisa ser travada antes de alterar os membros.' unless @locked && id == @room.id
    end
  end

  def run_body(root, name, input, rooms)
    manifest = Vetra::Graph::Manifest.new(Pathname.new(root))
    registry = Vetra::Graph::DeclarationLoader.new(manifest).load
    body = registry.bindings.fetch("chat.#{name}#call")
    BodyContext.new.instance_exec(input, rooms, &body)
  end

  def test_membership_commands_have_typed_ids_room_authorization_and_only_the_rooms_capability
    with_app('chat') do |_root, compiler|
      document = compiler.build.document
      %w[add_member remove_member].each do |name|
        command = node(document, 'command', "chat.#{name}")
        assert_equal({ 'action' => name, 'entity' => { 'kind' => 'entity', 'id' => 'chat.room' }, 'record' => 'room_id' }, command['authorize'])
        assert_equal [{ 'kind' => 'capability', 'id' => 'chat.rooms' }], command['uses']
        assert_equal({ 'kind' => 'contract', 'id' => 'chat.room.record' }, command['output'])
        assert_empty command['emits']
        assert_equal 'complete', command.dig('implementation', 'analysis', 'status')
        input = node(document, 'contract', command.dig('input', 'id'))
        assert_equal %w[room_id user_id], input['fields'].map { |field| field['name'] }
        input['fields'].each do |field|
          entity = field['name'] == 'room_id' ? 'chat.room' : 'chat.user'
          assert_equal({ 'name' => 'id', 'entity' => { 'kind' => 'entity', 'id' => entity } }, field['type'])
          assert field['required']
          refute field['nullable']
        end
      end
    end
  end

  def test_only_the_room_owner_is_granted_the_two_membership_actions
    with_app('chat') do |_root, compiler|
      document = compiler.build.document
      policies = document['nodes'].select do |entry|
        entry['kind'] == 'policy' && (entry['actions'] & %w[add_member remove_member]).any?
      end
      assert_equal 1, policies.size
      policy = policies.first
      assert_equal %w[add_member remove_member], policy['actions']
      assert_equal 'chat.authenticated', policy.dig('role', 'id')
      assert_equal 'chat.room', policy.dig('entity', 'id')
      assert_equal({
        'op' => 'eq', 'left' => { 'kind' => 'field', 'path' => ['owner_id'] },
        'right' => { 'kind' => 'actor', 'path' => ['id'] }
      }, policy['predicate'])
      assert_equal [{ 'kind' => 'entity', 'id' => 'chat.room' }], policy['reads']
      assert_equal %w[entity_no_policy entity_no_policy], compiler.build.warnings.map(&:code)
    end
  end

  def test_membership_routes_are_explicit_and_reference_the_shared_input_ids
    with_app('chat') do |_root, compiler|
      document = compiler.build.document
      {
        'add_member' => ['POST', '/rooms/:room_id/members'],
        'remove_member' => ['DELETE', '/rooms/:room_id/members/:user_id']
      }.each do |name, (method, path)|
        route = node(document, 'route', "chat.#{name}.http_1")
        assert_equal 'http', route['surface']
        assert_equal({ 'method' => method, 'path' => path }, route['config'])
        assert_equal({ 'kind' => 'command', 'id' => "chat.#{name}" }, route['target'])
      end
    end
  end

  def test_compilation_and_linking_register_both_bodies_without_running_them
    with_app('chat') do |root, compiler|
      %w[add_member remove_member].each do |name|
        edit(root, "app/domains/chat/#{name}.rb") do |text|
          text.sub('rooms.lock!(input.room_id)', '(::Kernel.raise "call executado")')
        end
      end
      built = compiler.write
      linked = compiler.link
      assert_equal %w[chat.add_member#call chat.remove_member#call], linked.implementation_ids
      assert_equal 8, linked.builtin_bindings.size
      assert_equal built.document, linked.document
      assert_equal built.bytes, compiler.check.bytes
    end
  end

  def test_bodies_add_and_remove_the_requested_member_and_return_the_room
    with_app('chat') do |root, _compiler|
      room = Room.new(id: 'room-1', owner_id: 'owner-1')
      input = Input.new(room_id: room.id, user_id: 'guest-1')
      rooms = MemoryRooms.new(room, members: [room.owner_id])
      assert_same room, run_body(root, 'add_member', input, rooms)
      assert_equal [room.owner_id, input.user_id], rooms.members
      assert_same room, run_body(root, 'remove_member', input, rooms)
      assert_equal [room.owner_id], rooms.members
      assert_equal [[:add, room.id, input.user_id], [:remove, room.id, input.user_id]], rooms.mutations
    end
  end

  def test_remove_body_refuses_the_owner_without_mutating_members
    with_app('chat') do |root, _compiler|
      room = Room.new(id: 'room-1', owner_id: 'owner-1')
      rooms = MemoryRooms.new(room, members: [room.owner_id, 'guest-1'])
      error = assert_raises(BodyFailure) do
        run_body(root, 'remove_member', Input.new(room_id: room.id, user_id: room.owner_id), rooms)
      end
      assert_equal :user_id, error.field
      assert_includes error.message, 'dono da sala'
      assert_equal [room.owner_id, 'guest-1'], rooms.members
      assert_empty rooms.mutations
    end
  end

  def test_queries_cannot_mutate_members_through_the_rooms_repository
    %w[add_member remove_member].each do |name|
      with_app('chat') do |root, compiler|
        edit(root, "app/domains/chat/#{name}.rb") { |text| text.sub("command :#{name}", "query :#{name}") }
        error = assert_graph_error('write_boundary') { compiler.build }
        diagnostic = error.diagnostics.find { |item| item.code == 'write_boundary' }
        assert_equal "app/domains/chat/#{name}.rb", diagnostic.source['path']
      end
    end
  end

  def test_room_authorization_cannot_be_bound_to_a_user_id
    with_app('chat') do |root, compiler|
      edit(root, 'app/domains/chat/remove_member.rb') { |text| text.sub('record: :room_id', 'record: :user_id') }
      error = assert_graph_error('authorize_record') { compiler.build }
      diagnostic = error.diagnostics.find { |item| item.code == 'authorize_record' }
      assert_match %r{/authorize/record\z}, diagnostic.pointer
      assert_equal 'app/domains/chat/remove_member.rb', diagnostic.source['path']
    end
  end

  def test_weakening_the_owner_policy_is_reported_as_a_permission_change
    with_app('chat') do |root, compiler|
      before = compiler.build.document
      edit(root, 'app/domains/chat/roles.rb') { |text| text.sub('where: { owner: :current_actor }', 'where: {}') }
      after = compiler.build.document
      changes = Vetra::Graph::Diff.new.compare(before, after).data['changes'].select do |change|
        change['kind'] == 'policy' && change['path'] == '/predicate'
      end
      assert_equal 1, changes.size
      change = changes.first
      assert_equal ['permissions'], change['categories']
      assert change['requires_review']
      assert_equal 'indeterminate', change['permission_impact']
      assert_equal 'eq', change['before']['op']
      assert_equal 'true', change['after']['op']
    end
  end
end

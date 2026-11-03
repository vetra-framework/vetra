require_relative 'test_helper'

class QueryOutputTest < GraphTest
  def output(document, name = 'room_page')
    node(document, 'contract', "chat.#{name}.output")
  end

  def validate(document)
    document['digest'] = Vetra::Graph::Canonical.digest(document)
    Vetra::Graph::Validator.new.validate!(document)
  end

  def personal_query(root)
    write(root, 'app/domains/chat/user_directory.rb', <<~RUBY)
      query :user_directory do
        returns do
          collection :users, entity: :user
        end
        authorize :read, :user
        uses :users
        call do |_input, users|
          { users: users.all }
        end
      end
    RUBY
  end

  def test_root_collection_reuses_record_fields_and_read_only_capabilities
    with_app('chat') do |_root, compiler|
      document = compiler.build.document
      assert_equal Vetra::Graph::Schema::VERSION, document['ir_version']
      assert_equal %w[vetra.core vetra.live vetra.structured_outputs vetra.timestamps], document['requires']
      contract = output(document, 'my_rooms')
      assert contract['collection']
      assert_equal node(document, 'contract', 'chat.room.record')['fields'], contract['fields']
      query = node(document, 'query', 'chat.my_rooms')
      assert_equal 'chat.my_rooms.output', query.dig('output', 'id')
      assert_equal ['chat.rooms_read'], query['uses'].map { |reference| reference['id'] }
      assert_equal({ 'action' => 'read', 'entity' => { 'kind' => 'entity', 'id' => 'chat.room' } }, query['authorize'])
      assert_equal({ 'method' => 'GET', 'path' => '/rooms' }, node(document, 'route', 'chat.my_rooms.http_1')['config'])
    end
  end

  def test_composite_output_has_typed_room_and_message_collection
    with_app('chat') do |_root, compiler|
      document = compiler.build.document
      fields = output(document)['fields'].to_h { |field| [field['name'], field] }
      assert_equal %w[messages room], fields.keys
      assert_equal({ 'name' => 'record', 'contract' => { 'kind' => 'contract', 'id' => 'chat.room.record' } }, fields['room']['type'])
      assert_equal({ 'name' => 'collection', 'contract' => { 'kind' => 'contract', 'id' => 'chat.message.record' } }, fields['messages']['type'])
      assert fields.values.all? { |field| field['required'] && !field['nullable'] }
      query = node(document, 'query', 'chat.room_page')
      assert_equal %w[chat.messages_read chat.rooms_read], query['uses'].map { |reference| reference['id'] }
      assert_equal 'room_id', query.dig('authorize', 'record')
      input = node(document, 'contract', query.dig('input', 'id'))
      assert_equal({ 'kind' => 'entity', 'id' => 'chat.room' }, input['fields'].first.dig('type', 'entity'))
      assert_equal({ 'method' => 'GET', 'path' => '/rooms/:room_id/page' }, node(document, 'route', 'chat.room_page.http_1')['config'])
    end
  end

  def test_link_preserves_declared_capability_order_and_never_calls_query_bodies
    with_app('chat') do |root, compiler|
      edit(root, 'app/domains/chat/my_rooms.rb') { |text| text.sub('rooms.order(:name).all', '::Kernel.raise "consulta executada"') }
      edit(root, 'app/domains/chat/room_page.rb') { |text| text.sub('rooms.find!(input.room_id)', '::Kernel.raise "consulta executada"') }
      built = compiler.write
      linked = compiler.link
      assert_equal built.document, linked.document
      assert_equal built.bytes, compiler.check.bytes
      binding = linked.bindings.find { |entry| entry['ref'] == 'chat.room_page#call' }
      assert_equal %w[input rooms messages], binding['parameters']
      assert_equal %w[chat.rooms_read chat.messages_read], binding['arguments'].map { |argument| argument.dig('capability', 'id') }
    end
  end

  def test_optional_structured_fields_and_primitive_outputs_are_explicit
    with_app('chat') do |root, compiler|
      edit(root, 'app/domains/chat/room_page.rb') do |text|
        text.sub('record :room, entity: :room', 'record :room, entity: :room, optional: true')
            .sub('    collection :messages', "    integer :count\n    collection :messages")
      end
      fields = output(compiler.build.document)['fields'].to_h { |field| [field['name'], field] }
      refute fields['room']['required']
      assert fields['room']['nullable']
      assert_equal({ 'name' => 'integer' }, fields['count']['type'])
      assert fields['count']['required']
    end
  end

  def test_compound_money_fields_keep_currency_scale_validation
    with_app('chat') do |root, compiler|
      edit(root, 'config/app.rb') { |text| text.sub('"BRL"', '"BHD"') }
      edit(root, 'app/domains/chat/room_page.rb') { |text| text.sub('    record :room', "    money :balance\n    record :room") }
      balance = output(compiler.build.document)['fields'].find { |field| field['name'] == 'balance' }
      assert_equal 3, balance.dig('type', 'scale')
      edit(root, 'app/domains/chat/room_page.rb') { |text| text.sub('money :balance', 'money :balance, scale: 2') }
      assert_graph_error('money_scale') { compiler.build }
    end
  end

  def test_personal_and_sensitive_classifications_propagate_to_containers
    with_app('chat') do |root, compiler|
      personal_query(root)
      users = output(compiler.build.document, 'user_directory')['fields'].first
      assert_equal({ 'personal' => true, 'classification' => 'personal' }, users['privacy'])
      edit(root, 'app/domains/chat/user.rb') { |text| text.sub('personal: true', 'personal: true, classification: :sensitive') }
      users = output(compiler.build.document, 'user_directory')['fields'].first
      assert_equal({ 'personal' => true, 'classification' => 'sensitive' }, users['privacy'])
    end
  end

  def test_external_ir_cannot_downgrade_compound_privacy
    with_app('chat') do |root, compiler|
      personal_query(root)
      document = Vetra::Graph::Data.copy(compiler.build.document)
      output(document, 'user_directory')['fields'].first['privacy'] = { 'personal' => false }
      error = assert_graph_error('output_privacy') { validate(document) }
      diagnostic = error.diagnostics.find { |entry| entry.code == 'output_privacy' }
      assert_match %r{/fields/0/privacy\z}, diagnostic.pointer
      assert_equal 'app/domains/chat/user_directory.rb', diagnostic.source['path']
    end
  end

  def test_missing_feature_and_old_schema_do_not_accept_structured_shapes
    with_app('chat') do |_root, compiler|
      original = compiler.build.document
      document = Vetra::Graph::Data.copy(original)
      document['requires'].delete('vetra.structured_outputs')
      assert_graph_error('ir_feature') { validate(document) }
      document = Vetra::Graph::Data.copy(original)
      document['ir_version'] = '0.2'
      assert_graph_error('ir_feature') { validate(document) }
      document['requires'].delete('vetra.structured_outputs')
      document['requires'].delete('vetra.live')
      document['requires'].delete('vetra.money_rounding')
      document['app'].delete('rounding')
      assert_graph_error('schema') { validate(document) }
    end
  end

  def test_dangling_contract_references_fail_before_graph_traversal
    with_app('chat') do |_root, compiler|
      document = Vetra::Graph::Data.copy(compiler.build.document)
      output(document)['fields'].first['type']['contract']['id'] = 'chat.missing'
      error = assert_graph_error('reference_missing') { validate(document) }
      assert error.diagnostics.any? { |entry| entry.pointer.end_with?('/type/contract') }
    end
  end

  def test_unknown_entity_in_a_return_names_the_source
    with_app('chat') do |root, compiler|
      edit(root, 'app/domains/chat/room_page.rb') { |text| text.sub('entity: :message', 'entity: :missing') }
      error = assert_graph_error('reference_missing') { compiler.build }
      assert_equal 'app/domains/chat/room_page.rb', error.diagnostics.first.source['path']
    end
  end

  def test_contract_cycles_are_rejected_without_recursion_errors
    with_app('chat') do |_root, compiler|
      original = compiler.build.document
      document = Vetra::Graph::Data.copy(original)
      contract = output(document)
      contract['fields'].first['type']['contract']['id'] = contract['id']
      assert_graph_error('contract_cycle') { validate(document) }
      document = Vetra::Graph::Data.copy(original)
      first = output(document)
      second = Vetra::Graph::Data.copy(first).merge('id' => 'chat.other.output')
      document['nodes'] << second
      first['fields'].first['type']['contract']['id'] = second['id']
      second['fields'].first['type']['contract']['id'] = first['id']
      assert_graph_error('contract_cycle') { validate(document) }
    end
  end

  def test_collection_fields_cannot_reference_root_collection_contracts
    with_app('chat') do |_root, compiler|
      document = Vetra::Graph::Data.copy(compiler.build.document)
      output(document)['fields'].first['type']['contract']['id'] = 'chat.my_rooms.output'
      assert_graph_error('output_shape') { validate(document) }
    end
  end

  def test_structured_contracts_cannot_be_used_as_inputs_events_or_command_outputs
    mutations = [
      ->(document) { node(document, 'command', 'chat.add_member')['input']['id'] = 'chat.room_page.output' },
      ->(document) { node(document, 'command', 'chat.add_member')['output']['id'] = 'chat.my_rooms.output' },
      ->(document) do
        document['nodes'] << {
          'kind' => 'event', 'id' => 'chat.room.changed', 'domain' => { 'kind' => 'domain', 'id' => 'chat' },
          'source' => { 'path' => 'app/domains/chat/room_page.rb', 'line' => 1 },
          'version' => 1, 'visibility' => 'public', 'consumer_required' => false,
          'payload' => { 'kind' => 'contract', 'id' => 'chat.room_page.output' }
        }
      end
    ]
    with_app('chat') do |_root, compiler|
      original = compiler.build.document
      mutations.each do |mutation|
        document = Vetra::Graph::Data.copy(original)
        mutation.call(document)
        assert_graph_error('output_shape') { validate(document) }
      end
    end
  end

  def test_entities_cannot_persist_structured_output_types
    with_app('chat') do |_root, compiler|
      document = Vetra::Graph::Data.copy(compiler.build.document)
      field = Vetra::Graph::Data.copy(output(document)['fields'].last).merge('name' => 'details')
      node(document, 'entity', 'chat.user')['fields'] << field
      assert_graph_error('output_shape') { validate(document) }
    end
  end

  def test_structured_fields_do_not_accept_write_defaults
    with_app('chat') do |_root, compiler|
      document = Vetra::Graph::Data.copy(compiler.build.document)
      field = output(document)['fields'].last
      field['nullable'] = true
      field['default'] = { 'kind' => 'literal', 'value' => nil }
      assert_graph_error('output_shape') { validate(document) }
    end
  end

  def test_commands_keep_the_existing_single_record_return_contract
    with_app('chat') do |root, compiler|
      edit(root, 'app/domains/chat/add_member.rb') { |text| text.sub('returns :room', 'returns :room, collection: true') }
      assert_graph_error('output_shape') { compiler.build }
    end
  end

  def test_invalid_or_duplicate_return_declarations_fail_audibly
    ['returns :room, collection: :yes', "returns :room\n  returns :room"].each do |declaration|
      with_app('chat') do |root, compiler|
        edit(root, 'app/domains/chat/my_rooms.rb') { |text| text.sub('returns :room, collection: true', declaration) }
        assert_graph_error('output_contract') { compiler.build }
      end
    end
    with_app('chat') do |root, compiler|
      edit(root, 'app/domains/chat/room_page.rb') { |text| text.sub('    collection :messages', "    record :room, entity: :room\n    collection :messages") }
      assert_graph_error('duplicate_field') { compiler.build }
    end
  end

  def test_read_only_queries_still_reject_repository_writes
    with_app('chat') do |root, compiler|
      edit(root, 'app/domains/chat/room_page.rb') { |text| text.sub('rooms.find!(input.room_id)', 'rooms.delete!(input.room_id)') }
      assert_graph_error('write_boundary') { compiler.build }
    end
  end

  def test_nested_output_usage_is_propagated_to_diff_guarantees
    with_app('chat') do |root, compiler|
      personal_query(root)
      before = compiler.build.document
      after = Vetra::Graph::Data.copy(before)
      email = node(after, 'contract', 'chat.user.record')['fields'].find { |field| field['name'] == 'email' }
      email['nullable'] = true
      after['digest'] = Vetra::Graph::Canonical.digest(after)
      report = Vetra::Graph::Diff.new.compare(before, after)
      change = report.data['changes'].find { |entry| entry['id'] == 'chat.user.record' && entry['path'] == '/fields/email/nullable' }
      assert_equal 'breaking', change['impact']
      assert change['requires_review']
    end
  end

  def test_changing_root_collection_shape_is_a_breaking_change
    with_app('chat') do |_root, compiler|
      before = compiler.build.document
      after = Vetra::Graph::Data.copy(before)
      output(after, 'my_rooms').delete('collection')
      after['digest'] = Vetra::Graph::Canonical.digest(after)
      change = Vetra::Graph::Diff.new.compare(before, after).data['changes'].find { |entry| entry['path'] == '/collection' }
      assert_equal 'breaking', change['impact']
    end
  end

  def test_previous_formats_still_link_without_conversion
    with_app do |root, compiler|
      %w[0.1 0.2 0.3].each do |version|
        manifest = Vetra::Graph::Manifest.new(Pathname.new(root))
        registry = Vetra::Graph::DeclarationLoader.new(manifest).load
        document = Vetra::Graph::Normalizer.new(registry, manifest, ir_version: version).document
        compiler.artifact.dirname.mkpath
        bytes = "#{Vetra::Graph::Canonical.dump(document)}\n"
        compiler.artifact.binwrite(bytes)
        assert_equal version, compiler.validate_file(compiler.artifact, sources: true).document['ir_version']
        assert_equal version, compiler.link.document['ir_version']
        assert_equal bytes, compiler.artifact.binread
        assert_graph_error('graph_stale') { compiler.check }
      end
    end
  end

  def test_structured_graphs_are_reproducible_in_different_directories
    with_app('chat') do |root, compiler|
      Dir.mktmpdir('vetra-query-copy-') do |copy|
        FileUtils.cp_r("#{root}/.", copy)
        assert_equal compiler.build.bytes, Vetra::Graph::Compiler.new(root: copy).build.bytes
      end
    end
  end
end

class ChatQueryBodyTest < GraphTest
  Room = ::Data.define(:id, :name, :owner_id, :created_at)
  Message = ::Data.define(:id, :room_id, :author_id, :body, :created_at)
  Input = ::Data.define(:room_id)

  # The repositories already represent a scoped read view. These tests do not run authorization or SQL.
  class ReadView
    attr_reader :lookups

    def initialize(items, lookups = [])
      @items, @lookups = items, lookups
    end

    def find!(id)
      @lookups << [:find, id]
      @items.find { |item| item.id == id } || raise(KeyError, id)
    end

    def where(**filters)
      @lookups << [:where, filters]
      self.class.new(@items.select { |item| filters.all? { |field, value| item.public_send(field) == value } }, @lookups)
    end

    def order(*fields)
      self.class.new(@items.sort_by { |item| fields.map { |field| item.public_send(field) } }, @lookups)
    end

    def all
      @items.dup
    end

    def last(size)
      @items.last(size)
    end
  end

  def run_body(root, name, input, *capabilities)
    manifest = Vetra::Graph::Manifest.new(Pathname.new(root))
    registry = Vetra::Graph::DeclarationLoader.new(manifest).load
    Object.new.instance_exec(input, *capabilities, &registry.bindings.fetch("chat.#{name}#call"))
  end

  def room(id, name)
    Room.new(id: id, name: name, owner_id: 'owner-1', created_at: '2026-11-02T00:00:00Z')
  end

  def test_my_rooms_returns_a_name_ordered_collection_and_accepts_empty_results
    with_app('chat') do |root, _compiler|
      first, last = room('room-1', 'Alpha'), room('room-2', 'Zeta')
      assert_equal [first, last], run_body(root, 'my_rooms', nil, ReadView.new([last, first]))
      assert_empty run_body(root, 'my_rooms', nil, ReadView.new([]))
    end
  end

  def test_room_page_filters_messages_and_limits_them_with_a_stable_tie_break
    with_app('chat') do |root, _compiler|
      current = room('room-1', 'Sala')
      messages = (1..150).map do |index|
        Message.new(id: format('m-%03d', index), room_id: current.id, author_id: 'author-1', body: "Mensagem #{index}", created_at: current.created_at)
      end
      other = Message.new(id: 'other', room_id: 'other-room', author_id: 'author-1', body: 'Outra sala', created_at: current.created_at)
      result = run_body(root, 'room_page', Input.new(room_id: current.id), ReadView.new([current]), ReadView.new([other, *messages.reverse]))
      assert_same current, result[:room]
      assert_equal 100, result[:messages].size
      assert_equal 'm-051', result[:messages].first.id
      assert_equal 'm-150', result[:messages].last.id
      assert result[:messages].all? { |message| message.room_id == current.id }
    end
  end

  def test_room_page_checks_the_room_before_querying_messages
    with_app('chat') do |root, _compiler|
      messages = ReadView.new([])
      assert_raises(KeyError) { run_body(root, 'room_page', Input.new(room_id: 'missing'), ReadView.new([]), messages) }
      assert_empty messages.lookups
    end
  end
end

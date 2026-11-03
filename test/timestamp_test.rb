require_relative 'test_helper'

class TimestampTest < GraphTest
  def created_at(document, kind, id)
    node(document, kind, id)['fields'].find { |field| field['name'] == 'created_at' }
  end

  def validate(document)
    document['digest'] = Vetra::Graph::Canonical.digest(document)
    Vetra::Graph::Validator.new.validate!(document)
  end

  def legacy_document(root)
    manifest = Vetra::Graph::Manifest.new(Pathname.new(root))
    registry = Vetra::Graph::DeclarationLoader.new(manifest).load
    Vetra::Graph::Normalizer.new(registry, manifest, ir_version: '0.1').document
  end

  def test_entities_include_created_at_in_records_but_not_in_crud_inputs
    %w[blog mini_crm mini_crm_revendas chat].each do |name|
      with_app(name) do |_root, compiler|
        document = compiler.build.document
        assert_equal Vetra::Graph::Schema::VERSION, document['ir_version']
        assert_equal %w[vetra.core vetra.timestamps], document['requires'] & %w[vetra.core vetra.timestamps]
        document['nodes'].select { |entry| entry['kind'] == 'entity' }.each do |entity|
          timestamp = created_at(document, 'entity', entity['id'])
          assert_equal({ 'name' => 'timestamp' }, timestamp['type'])
          assert timestamp['required']
          refute timestamp['nullable']
          assert_equal({ 'kind' => 'timestamp', 'on' => 'create' }, timestamp['generate'])
          record = created_at(document, 'contract', "#{entity['id']}.record")
          assert_equal timestamp.reject { |key, _| key == 'generate' }, record
        end
        document['nodes'].select { |entry| %w[crud.create crud.update].include?(entry.dig('implementation', 'name')) }.each do |operation|
          refute created_at(document, 'contract', operation.dig('input', 'id'))
        end
      end
    end
  end

  def test_implicit_junctions_also_have_a_creation_timestamp
    with_app('chat') do |root, compiler|
      FileUtils.rm(File.join(root, 'app/domains/chat/room_membership.rb'))
      edit(root, 'app/domains/chat/room.rb') { |text| text.sub(', through: :room_membership', '') }
      document = compiler.build.document
      assert_equal({ 'kind' => 'timestamp', 'on' => 'create' }, created_at(document, 'entity', 'chat.room_member')['generate'])
    end
  end

  def test_chat_message_index_preserves_room_then_creation_time_order
    with_app('chat') do |_root, compiler|
      message = node(compiler.build.document, 'entity', 'chat.message')
      assert_equal %w[room_id created_at], message['indexes'].first['fields']
    end
  end

  def test_created_at_cannot_be_redeclared_in_an_entity
    ['timestamp :created_at', 'string :created_at, optional: true'].each do |declaration|
      with_app do |root, compiler|
        edit(root, 'app/domains/blog/post.rb') { |text| text.sub('  crud', "  #{declaration}\n  crud") }
        error = assert_graph_error('reserved_field') { compiler.build }
        assert_equal 'app/domains/blog/post.rb', error.diagnostics.first.source['path']
        assert_includes error.message, 'created_at'
      end
    end
  end

  def test_commands_cannot_assign_the_generated_time_during_create_or_update
    ['posts.create!(title: "x", created_at: clock.now)', 'posts.update!(post, created_at: clock.now)'].each do |expression|
      with_app do |root, compiler|
        edit(root, 'app/domains/blog/publish_post.rb') do |text|
          text.sub('posts.update!(post, status: "published", published_at: clock.now)', expression)
        end
        error = assert_graph_error('generated_field_write') { compiler.build }
        assert_equal 'app/domains/blog/publish_post.rb', error.diagnostics.first.source['path']
      end
    end
  end

  def test_external_ir_requires_the_feature_and_the_entity_timestamp
    with_app do |_root, compiler|
      original = compiler.build.document
      document = Vetra::Graph::Data.copy(original)
      document['requires'].delete('vetra.timestamps')
      assert_graph_error('ir_feature') { validate(document) }
      document = Vetra::Graph::Data.copy(original)
      node(document, 'entity', 'blog.post')['fields'].reject! { |field| field['name'] == 'created_at' }
      error = assert_graph_error('timestamp_field') { validate(document) }
      diagnostic = error.diagnostics.find { |item| item.code == 'timestamp_field' }
      assert_match %r{/fields\z}, diagnostic.pointer
      assert_equal 'app/domains/blog/post.rb', diagnostic.source['path']
    end
  end

  def test_external_ir_cannot_change_the_type_presence_or_assignment_rules
    mutations = [
      ->(field) { field['type'] = { 'name' => 'string' } },
      ->(field) { field['required'] = false },
      ->(field) { field['nullable'] = true },
      ->(field) { field['default'] = { 'kind' => 'literal', 'value' => '2026-11-02T00:00:00Z' } },
      ->(field) { field['set_by'] = [{ 'kind' => 'command', 'id' => 'blog.publish_post' }] },
      ->(field) { field['normalize'] = ['downcase'] }
    ]
    with_app do |_root, compiler|
      original = compiler.build.document
      mutations.each do |mutation|
        document = Vetra::Graph::Data.copy(original)
        mutation.call(created_at(document, 'entity', 'blog.post'))
        assert_graph_error('timestamp_field') { validate(document) }
      end
      document = Vetra::Graph::Data.copy(original)
      created_at(document, 'entity', 'blog.post')['generate']['on'] = 'update'
      assert_graph_error('schema') { validate(document) }
    end
  end

  def test_generation_cannot_be_copied_into_a_record_contract
    with_app do |_root, compiler|
      document = Vetra::Graph::Data.copy(compiler.build.document)
      created_at(document, 'contract', 'blog.post.record')['generate'] = { 'kind' => 'timestamp', 'on' => 'create' }
      assert_graph_error('timestamp_field') { validate(document) }
    end
  end

  def test_external_ir_cannot_make_created_at_writable_in_crud
    with_app do |_root, compiler|
      original = compiler.build.document
      %w[create update].each do |action|
        document = Vetra::Graph::Data.copy(original)
        field = Vetra::Graph::Data.copy(created_at(document, 'contract', 'blog.post.record'))
        node(document, 'contract', "blog.#{action}_post.input")['fields'] << field
        assert_graph_error('crud_contract') { validate(document) }
      end
    end
  end

  def test_old_schema_does_not_accept_timestamp_generation_or_the_feature
    with_app do |_root, compiler|
      document = Vetra::Graph::Data.copy(compiler.build.document)
      document['ir_version'] = '0.1'
      assert_graph_error('ir_feature') { validate(document) }
      document['requires'].delete('vetra.timestamps')
      assert_graph_error('schema') { validate(document) }
    end
  end

  def test_old_artifacts_still_link_with_old_semantics_and_check_requires_rebuilding
    with_app do |root, compiler|
      legacy = legacy_document(root)
      assert_empty validate(legacy)
      compiler.artifact.dirname.mkpath
      original_bytes = "#{Vetra::Graph::Canonical.dump(legacy)}\n"
      compiler.artifact.binwrite(original_bytes)
      linked = compiler.link
      assert_equal '0.1', linked.document['ir_version']
      refute created_at(linked.document, 'entity', 'blog.post')
      assert_graph_error('graph_stale') { compiler.check }
      assert_equal original_bytes, compiler.artifact.binread
      current = compiler.write
      assert_equal Vetra::Graph::Schema::VERSION, current.document['ir_version']
      assert_equal current.document, compiler.link.document
    end
  end

  def test_diff_reports_version_and_generated_fields_without_breaking_inputs
    with_app do |root, compiler|
      before = legacy_document(root)
      report = Vetra::Graph::Diff.new.compare(before, compiler.build.document)
      refute report.breaking?
      version = report.data['changes'].find { |change| change['path'] == '/ir_version' }
      assert_equal '0.1', version['before']
      assert_equal Vetra::Graph::Schema::VERSION, version['after']
      assert_equal 'review', version['impact']
      assert version['requires_review']
      field_changes = report.data['changes'].select { |change| change['path'] == '/fields/created_at' }
      assert_equal %w[contract entity], field_changes.map { |change| change['kind'] }.sort
      assert field_changes.all? { |change| change['impact'] == 'additive' }
      refute report.data['changes'].any? { |change| change['id'].end_with?('.input') }
    end
  end

  def test_build_is_deterministic_without_reading_the_clock
    with_app do |_root, compiler|
      Time.stub(:now, -> { raise 'O compilador consultou o relógio.' }) do
        assert_equal compiler.build.bytes, compiler.build.bytes
      end
    end
  end

  def test_events_can_project_created_at_without_copying_generation_metadata
    with_app('mini_crm') do |root, compiler|
      edit(root, 'app/domains/crm/events.rb') { |text| text.sub('fields: %i[id]', 'fields: %i[id created_at]') }
      edit(root, 'app/domains/crm/win_lead.rb') { |text| text.sub('with: %i[id]', 'with: %i[id created_at]') }
      document = compiler.build.document
      event = node(document, 'event', 'crm.lead.won')
      timestamp = created_at(document, 'contract', event.dig('payload', 'id'))
      assert_equal({ 'name' => 'timestamp' }, timestamp['type'])
      refute timestamp.key?('generate')
    end
  end
end

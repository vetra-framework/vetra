require_relative 'test_helper'

class LiveTest < GraphTest
  DEPENDENCIES = %w[chat.message chat.room chat.room_membership chat.user].freeze
  EXPLICIT = 'live true, depends_on: %i[room message room_membership user]'.freeze

  def live_query(document)
    node(document, 'query', 'chat.room_page')
  end

  def change_live(root, declaration)
    edit(root, 'app/domains/chat/room_page.rb') { |text| text.sub('live true', declaration) }
  end

  def validate(document)
    document['digest'] = Vetra::Graph::Canonical.digest(document)
    Vetra::Graph::Validator.new.validate!(document)
  end

  def test_live_defaults_to_strict_and_derives_repository_output_and_policy_dependencies
    with_app('chat') do |_root, compiler|
      document = compiler.build.document
      query = live_query(document)
      assert_includes document['requires'], 'vetra.live'
      assert_equal 'strict', query.dig('live', 'mode')
      assert_equal DEPENDENCIES, query.dig('live', 'depends_on').map { |reference| reference['id'] }
      assert_equal %w[chat.messages_read chat.rooms_read], query['uses'].map { |reference| reference['id'] }
      refute query['uses'].any? { |reference| reference['id'].include?('membership') }
      assert query['live'].frozen?
      assert query.dig('live', 'depends_on').all?(&:frozen?)
    end
  end

  def test_complete_explicit_dependencies_are_sorted_and_match_inference
    with_app('chat') do |root, compiler|
      before = compiler.build.document
      change_live(root, 'live true, depends_on: %i[user room_membership room message]')
      after = compiler.build.document
      assert_equal live_query(before)['live'], live_query(after)['live']
      report = Vetra::Graph::Diff.new.compare(before, after)
      assert report.data['changes'].all? { |change| change['impact'] == 'metadata' }
    end
  end

  def test_explicit_dependencies_cannot_omit_the_authorization_junction
    with_app('chat') do |root, compiler|
      change_live(root, 'live true, depends_on: %i[room message user]')
      error = assert_graph_error('live_dependencies') { compiler.build }
      assert_includes error.message, 'chat.room_membership'
      assert_equal 'app/domains/chat/room_page.rb', error.diagnostics.first.source['path']
    end
  end

  def test_extra_entities_also_require_their_policy_dependencies
    with_app('chat') do |root, compiler|
      write(root, 'app/domains/chat/category.rb', "entity :category do\n  string :name\nend\n")
      write(root, 'app/domains/chat/topic.rb', "entity :topic do\n  belongs_to :category\nend\n")
      edit(root, 'app/domains/chat/roles.rb') do |text|
        text.sub('  authenticated do', '  authenticated do' + "\n    can :read, on: :topic, where: { category: { name: 'allowed' } }")
      end
      change_live(root, 'live true, depends_on: %i[room message room_membership user topic]')
      error = assert_graph_error('live_dependencies') { compiler.build }
      assert_includes error.message, 'chat.category'
      edit(root, 'app/domains/chat/room_page.rb') do |text|
        text.sub('user topic]', 'user topic category]')
      end
      dependencies = live_query(compiler.build.document).dig('live', 'depends_on').map { |reference| reference['id'] }
      assert_equal (DEPENDENCIES + %w[chat.topic chat.category]).sort, dependencies
    end
  end

  def test_output_contract_entities_are_included_even_without_a_direct_repository
    with_app('chat') do |root, compiler|
      write(root, 'app/domains/chat/category.rb', "entity :category do\n  string :name\nend\n")
      edit(root, 'app/domains/chat/room_page.rb') do |text|
        text.sub('    record :room', "    record :category, entity: :category\n    record :room")
      end
      dependencies = live_query(compiler.build.document).dig('live', 'depends_on').map { |reference| reference['id'] }
      assert_includes dependencies, 'chat.category'
    end
  end

  def test_live_false_removes_metadata_and_is_reported_as_a_breaking_change
    with_app('chat') do |root, compiler|
      before = compiler.build.document
      change_live(root, 'live false')
      after = compiler.build.document
      refute live_query(after).key?('live')
      refute_includes after['requires'], 'vetra.live'
      report = Vetra::Graph::Diff.new.compare(before, after)
      change = report.data['changes'].find { |entry| entry['kind'] == 'query' && entry['path'] == '/live' }
      assert_equal 'breaking', change['impact']
      assert_equal %w[dependencies permissions], change['categories']
      assert report.breaking?
    end
  end

  def test_balanced_is_explicit_and_requires_permission_review
    with_app('chat') do |root, compiler|
      before = compiler.build.document
      change_live(root, 'live true, mode: :balanced')
      after = compiler.build.document
      assert_equal 'balanced', live_query(after).dig('live', 'mode')
      report = Vetra::Graph::Diff.new.compare(before, after)
      change = report.data['changes'].find { |entry| entry['kind'] == 'query' && entry['path'] == '/live' }
      assert_equal %w[dependencies permissions], change['categories']
      assert change['requires_review']
      assert_equal 'indeterminate', change['permission_impact']
      refute report.breaking?
    end
  end

  def test_adding_or_removing_a_live_query_highlights_dependencies_and_permissions
    with_app('chat') do |root, compiler|
      with_live = compiler.build.document
      File.unlink(File.join(root, 'app/domains/chat/room_page.rb'))
      without_live = compiler.build.document
      [[without_live, with_live, 'added'], [with_live, without_live, 'removed']].each do |before, after, change|
        report = Vetra::Graph::Diff.new.compare(before, after)
        entry = report.data['changes'].find { |item| item['kind'] == 'query' && item['id'] == 'chat.room_page' }
        assert_equal change, entry['change']
        assert_includes entry['categories'], 'dependencies'
        assert_includes entry['categories'], 'permissions'
        assert entry['requires_review']
      end
    end
  end

  def test_invalid_values_modes_and_repeated_declarations_are_audible_at_the_live_line
    ['live nil', 'live :yes', 'live true, mode: :eventual', 'live false, mode: :strict', "live true\n  live false"].each do |declaration|
      with_app('chat') do |root, compiler|
        change_live(root, declaration)
        error = assert_graph_error('live_declaration') { compiler.build }
        diagnostic = error.diagnostics.first
        assert_equal 'app/domains/chat/room_page.rb', diagnostic.source['path']
        expected_line = File.readlines(File.join(root, diagnostic.source['path'])).rindex { |line| line.strip.start_with?('live ') } + 1
        assert_equal expected_line, diagnostic.source['line']
      end
    end
  end

  def test_unknown_options_and_invalid_dependency_lists_are_rejected
    with_app('chat') do |root, compiler|
      change_live(root, 'live true, interval: 5')
      error = assert_graph_error('unsupported_option') { compiler.build }
      assert_includes error.message, 'live'
    end
    ['[]', ':room', 'nil', '[42]'].each do |list|
      with_app('chat') do |root, compiler|
        change_live(root, "live true, depends_on: #{list}")
        assert_graph_error('live_dependencies') { compiler.build }
      end
    end
  end

  def test_duplicate_and_unknown_entities_fail
    with_app('chat') do |root, compiler|
      change_live(root, 'live true, depends_on: %i[room chat.room]')
      assert_graph_error('live_dependencies') { compiler.build }
    end
    with_app('chat') do |root, compiler|
      change_live(root, 'live true, depends_on: %i[missing]')
      assert_graph_error('reference_missing') { compiler.build }
    end
  end

  def test_commands_and_handlers_cannot_declare_live_even_when_disabled
    with_app('chat') do |root, compiler|
      edit(root, 'app/domains/chat/add_member.rb') { |text| text.sub('  returns :room', "  live false\n  returns :room") }
      assert_graph_error('unsupported_declaration') { compiler.build }
    end
    with_app('mini_crm') do |root, compiler|
      edit(root, 'app/domains/crm/notify_sales.rb') { |text| text.sub('  uses :mailer', "  live true\n  uses :mailer") }
      assert_graph_error('unsupported_declaration') { compiler.build }
    end
  end

  def test_dynamic_analysis_requires_explicit_dependencies_and_keeps_the_warning
    with_app('chat') do |root, compiler|
      edit(root, 'app/domains/chat/room_page.rb') { |text| text.sub('rooms.find!(input.room_id)', 'lookup_room(input.room_id, rooms)') }
      assert_graph_error('live_dependencies') { compiler.build }
      change_live(root, EXPLICIT)
      result = compiler.write
      assert_includes result.warnings.map(&:code), 'analysis_incomplete'
      assert_equal 'incomplete', live_query(result.document).dig('implementation', 'analysis', 'status')
      assert_equal result.document, compiler.link.document
    end
  end

  def test_unsafe_effect_is_incompatible_with_live
    with_app('chat') do |root, compiler|
      edit(root, 'app/domains/chat/room_page.rb') { |text| text.sub('  live true', "  unsafe_effect 'exceção de teste'\n  #{EXPLICIT}") }
      assert_graph_error('live_boundary') { compiler.build }
    end
  end

  def test_deterministic_capabilities_are_allowed_without_becoming_entity_dependencies
    with_app('chat') do |root, compiler|
      edit(root, 'app/domains/chat/room_page.rb') do |text|
        text.sub('uses :rooms, :messages', 'uses :rooms, :messages, :clock')
            .sub('|input, rooms, messages|', '|input, rooms, messages, clock|')
      end
      query = live_query(compiler.build.document)
      assert_equal DEPENDENCIES, query.dig('live', 'depends_on').map { |reference| reference['id'] }
      assert query['uses'].any? { |reference| reference['id'] == 'chat.clock' }
    end
  end

  def test_external_ir_requires_the_feature_and_known_authorization_dependencies
    with_app('chat') do |_root, compiler|
      original = compiler.build.document
      document = Vetra::Graph::Data.copy(original)
      document['requires'].delete('vetra.live')
      assert_graph_error('ir_feature') { validate(document) }
      document = Vetra::Graph::Data.copy(original)
      live_query(document).dig('live', 'depends_on').reject! { |reference| reference['id'] == 'chat.room_membership' }
      error = assert_graph_error('live_dependencies') { validate(document) }
      diagnostic = error.diagnostics.find { |entry| entry.code == 'live_dependencies' }
      assert_match %r{/live/depends_on\z}, diagnostic.pointer
      assert_equal 'app/domains/chat/room_page.rb', diagnostic.source['path']
    end
  end

  def test_external_ir_rejects_unsafe_effects_and_sql_capabilities
    with_app('chat') do |_root, compiler|
      original = compiler.build.document
      document = Vetra::Graph::Data.copy(original)
      live_query(document)['unsafe_effect'] = 'exceção de teste'
      assert_graph_error('live_boundary') { validate(document) }
      document = Vetra::Graph::Data.copy(original)
      sql = Vetra::Graph::Data.copy(node(document, 'capability', 'chat.rooms_read'))
      sql['id'] = 'chat.sql'
      sql['config'] = { 'type' => 'sql', 'access' => 'read' }
      document['nodes'] << sql
      live_query(document)['uses'] << { 'kind' => 'capability', 'id' => 'chat.sql' }
      assert_graph_error('live_boundary') { validate(document) }
    end
  end

  def test_external_ir_cannot_hide_policy_reads
    with_app('chat') do |_root, compiler|
      document = Vetra::Graph::Data.copy(compiler.build.document)
      policy = document['nodes'].find { |entry| entry['kind'] == 'policy' && entry.dig('entity', 'id') == 'chat.room' && entry['actions'].include?('read') }
      policy['reads'].reject! { |reference| reference['id'] == 'chat.room_membership' }
      assert_graph_error('policy_reads') { validate(document) }
    end
  end

  def test_invalid_raw_modes_and_dependency_shapes_fail_in_the_schema
    mutations = [
      ->(live) { live['mode'] = 'eventual' },
      ->(live) { live['depends_on'] = [] },
      ->(live) { live['depends_on'].first['kind'] = 'contract' }
    ]
    with_app('chat') do |_root, compiler|
      original = compiler.build.document
      mutations.each do |mutation|
        document = Vetra::Graph::Data.copy(original)
        mutation.call(live_query(document)['live'])
        assert_graph_error('schema') { validate(document) }
      end
      document = Vetra::Graph::Data.copy(original)
      live_query(document).dig('live', 'depends_on').first['id'] = 'chat.missing'
      assert_graph_error('reference_missing') { validate(document) }
    end
  end

  def test_previous_formats_still_refuse_live_as_an_unsupported_feature
    with_app('chat') do |_root, compiler|
      original = compiler.build.document
      %w[0.1 0.2].each do |version|
        document = Vetra::Graph::Data.copy(original)
        document['ir_version'] = version
        assert_graph_error('ir_feature') { validate(document) }
      end
    end
  end

  def test_link_keeps_live_metadata_without_executing_the_query
    with_app('chat') do |root, compiler|
      edit(root, 'app/domains/chat/room_page.rb') { |text| text.sub('rooms.find!(input.room_id)', '::Kernel.raise "consulta executada"') }
      result = compiler.write
      linked = compiler.link
      assert_equal live_query(result.document)['live'], live_query(linked.document)['live']
      assert_equal result.bytes, compiler.check.bytes
      assert_includes linked.implementation_ids, 'chat.room_page#call'
    end
  end
end

require_relative 'test_helper'

class RelationCommandsTest < GraphTest
  def with_generated_chat
    with_app('chat') do |root, compiler|
      %w[add_member remove_member].each { |name| File.unlink(File.join(root, "app/domains/chat/#{name}.rb")) }
      edit(root, 'app/domains/chat/room.rb') { |text| text.sub(', commands: false', '') }
      yield root, compiler
    end
  end

  def validate(document)
    document['digest'] = Vetra::Graph::Canonical.digest(document)
    Vetra::Graph::Validator.new.validate!(document)
  end

  def generated(document)
    document['nodes'].select { |entry| entry.dig('implementation', 'name')&.start_with?('many_to_many.') }
  end

  def test_generates_typed_commands_authorized_by_the_owner_without_routes_or_grants
    with_generated_chat do |_root, compiler|
      document = compiler.build.document
      assert_equal '0.4', document['ir_version']
      assert_includes document['requires'], 'vetra.relation_commands'
      assert_equal %w[chat.add_member chat.remove_member], generated(document).map { |entry| entry['id'] }
      generated(document).each do |command|
        action = command['id'].split('.').last
        verb = action.split('_').first
        assert_equal({ 'kind' => 'builtin', 'name' => "many_to_many.#{verb}.members" }, command['implementation'])
        assert_equal({ 'action' => action, 'entity' => { 'kind' => 'entity', 'id' => 'chat.room' }, 'record' => 'room_id' }, command['authorize'])
        assert_equal command.dig('authorize', 'entity'), command['generated_from']
        assert_equal 'app/domains/chat/room.rb', command.dig('source', 'path')
        assert_equal [{ 'kind' => 'capability', 'id' => 'chat.rooms' }], command['uses']
        assert_equal({ 'kind' => 'contract', 'id' => 'chat.room.record' }, command['output'])
        assert_empty command['emits']
        fields = node(document, 'contract', command.dig('input', 'id'))['fields']
        assert_equal %w[room_id user_id], fields.map { |field| field['name'] }
        assert_equal %w[chat.room chat.user], fields.map { |field| field.dig('type', 'entity', 'id') }
        assert fields.all? { |field| field['required'] && !field['nullable'] }
        refute document['nodes'].any? { |entry| entry['kind'] == 'route' && entry.dig('target', 'id') == command['id'] }
      end
      policies = document['nodes'].select { |entry| entry['kind'] == 'policy' && entry['actions'].include?('add_member') }
      assert_equal 1, policies.size
      assert_equal ['owner_id'], policies.first.dig('predicate', 'left', 'path')
    end
  end

  def test_implicit_junction_and_default_generation_are_reproducible_and_link_without_execution
    with_generated_chat do |root, compiler|
      File.unlink(File.join(root, 'app/domains/chat/room_membership.rb'))
      edit(root, 'app/domains/chat/room.rb') { |text| text.sub(', through: :room_membership', '') }
      first = compiler.write
      assert_equal first.bytes, compiler.build.bytes
      linked = compiler.link
      assert_equal first.document, linked.document
      %w[add_member remove_member].each do |name|
        binding = linked.binding_for('command', "chat.#{name}")
        assert_equal 'builtin', binding['kind']
        assert_equal 'pending', binding['executor']
        assert binding.frozen?
        refute_includes linked.implementation_ids, "chat.#{name}#call"
      end
      assert_equal 10, linked.builtin_bindings.size
      relation = node(linked.document, 'entity', 'chat.room')['relations'].find { |item| item['name'] == 'members' }
      assert_equal 'chat.room_member', relation.dig('through', 'id')
      assert_equal ['owner'], relation['include_on_create']
    end
  end

  def test_generation_does_not_grant_permission_when_the_owner_has_no_matching_policy
    with_generated_chat do |root, compiler|
      edit(root, 'app/domains/chat/roles.rb') { |text| text.lines.reject { |line| line.include?('can :add_member') }.join }
      document = compiler.build.document
      assert_equal 2, generated(document).size
      refute document['nodes'].any? { |entry| entry['kind'] == 'policy' && (entry['actions'] & %w[add_member remove_member]).any? }
    end
  end

  def test_explicit_opt_out_preserves_chat_commands_and_the_rest_of_the_relation
    with_app('chat') do |_root, compiler|
      document = compiler.write.document
      assert_empty generated(document)
      refute_includes document['requires'], 'vetra.relation_commands'
      %w[add_member remove_member].each do |name|
        assert_equal 'ruby', node(document, 'command', "chat.#{name}").dig('implementation', 'kind')
      end
      assert_equal 'ruby', compiler.link.binding_for('command', 'chat.remove_member')['kind']
      relation = node(document, 'entity', 'chat.room')['relations'].find { |item| item['name'] == 'members' }
      assert_equal 'chat.room_membership', relation.dig('through', 'id')
      assert_equal ['owner'], relation['include_on_create']
    end
  end

  def test_only_booleans_are_accepted_for_commands_with_the_declaration_location
    ['nil', ':auto', '{}', '"false"'].each do |value|
      with_app('chat') do |root, compiler|
        edit(root, 'app/domains/chat/room.rb') { |text| text.sub('commands: false', "commands: #{value}") }
        error = assert_graph_error('relation_commands_option') { compiler.build }
        assert_equal 'app/domains/chat/room.rb', error.diagnostics.first.source['path']
        assert_equal 4, error.diagnostics.first.source['line']
      end
    end
  end

  def test_explicit_operations_collide_instead_of_overriding_generation
    %w[command query handler].each do |kind|
      with_app('chat') do |root, compiler|
        edit(root, 'app/domains/chat/room.rb') { |text| text.sub('commands: false', 'commands: true') }
        edit(root, 'app/domains/chat/add_member.rb') { |text| text.sub('command :add_member', "#{kind} :add_member") }
        error = assert_graph_error('relation_command_collision') { compiler.build }
        assert_includes error.message, 'chat.add_member'
        assert_includes error.message, 'commands: false'
        assert_equal 'app/domains/chat/room.rb', error.diagnostics.first.source['path']
      end
    end
  end

  def test_relations_on_different_owners_cannot_generate_the_same_command_name
    with_generated_chat do |root, compiler|
      write(root, 'app/domains/chat/team.rb', "entity :team do\n  many_to_many :members, entity: :user\nend\n")
      error = assert_graph_error('relation_command_collision') { compiler.build }
      assert_includes error.message, 'chat.add_member'
    end
  end

  def test_custom_repository_and_renamed_junction_links_are_resolved_from_the_owner
    with_generated_chat do |root, compiler|
      edit(root, 'app/domains/chat/room.rb') { |text| text.sub('entity :room do', 'entity :room, repository: :spaces do') }
      # Os comandos Ruby restantes usam rooms; desligue-os para isolar o repositório customizado.
      %w[add_member_by_email my_rooms room_page].each { |name| File.unlink(File.join(root, "app/domains/chat/#{name}.rb")) }
      edit(root, 'app/domains/chat/room_membership.rb') { |text| text.sub('belongs_to :room', 'belongs_to :space, entity: :room').sub('belongs_to :user', 'belongs_to :person, entity: :user').sub(':room_id, :user_id', ':space_id, :person_id') }
      document = compiler.write.document
      assert_equal ['chat.spaces'], node(document, 'command', 'chat.add_member')['uses'].map { |reference| reference['id'] }
      assert_equal 'pending', compiler.link.binding_for('command', 'chat.add_member')['executor']
    end
  end

  def test_tenant_is_derived_from_context_and_not_exposed_in_the_input
    with_app('mini_crm_revendas') do |root, compiler|
      edit(root, 'app/domains/crm/lead.rb') { |text| text.sub('  crud', "  many_to_many :watchers, entity: :user, commands: true\n  crud") }
      document = compiler.write.document
      assert_equal %w[lead_id user_id], node(document, 'contract', 'crm.add_watcher.input')['fields'].map { |field| field['name'] }
      junction = node(document, 'entity', 'crm.lead_watcher')
      assert junction['relations'].all? { |relation| relation['same_tenant'] }
      assert junction['indexes'].any? { |index| index['unique'] && index['fields'] == %w[company_id lead_id user_id] }
      assert_equal 'pending', compiler.link.binding_for('command', 'crm.remove_watcher')['executor']
    end
  end

  def test_singular_names_follow_the_junction_rule
    { 'categories' => 'category', 'tags' => 'tag', 'staff' => 'staff', 'glass' => 'glass' }.each do |relation, singular|
      with_generated_chat do |root, compiler|
        edit(root, 'app/domains/chat/room.rb') { |text| text.sub('many_to_many :members', "many_to_many :#{relation}") }
        # A política de membros deve acompanhar a relação renomeada.
        edit(root, 'app/domains/chat/roles.rb') { |text| text.gsub('members:', "#{relation}:") }
        assert_equal "many_to_many.add.#{relation}", node(compiler.build.document, 'command', "chat.add_#{singular}").dig('implementation', 'name')
      end
    end
  end

  def test_generated_commands_require_a_unique_pair_nonnullable_links_and_satisfiable_extra_fields
    changes = [
      ->(text) { text.sub('unique: true', 'unique: false') },
      ->(text) { text.sub('  index', "  string :reason, required: true\n  index") },
      ->(text) { text.sub('  index', "  string :reason, required: true, nullable: true\n  index") },
      ->(text) { text.sub('  index', "  string :reason, required: false, nullable: false\n  index") },
      ->(text) { text.sub('belongs_to :user', 'belongs_to :user, optional: true') },
      ->(text) { text.sub(':room_id, :user_id', ':room_id, :user_id, :id') }
    ]
    changes.each do |change|
      with_generated_chat do |root, compiler|
        edit(root, 'app/domains/chat/room_membership.rb', &change)
        error = assert_graph_error('relation_command_junction') { compiler.build }
        assert_includes error.message, 'commands: false'
        edit(root, 'app/domains/chat/room.rb') { |text| text.sub('include: :owner', 'include: :owner, commands: false') }
        assert_empty generated(compiler.build.document)
      end
    end
  end

  def test_additional_fields_with_defaults_or_optional_fields_do_not_block_generation
    with_generated_chat do |root, compiler|
      edit(root, 'app/domains/chat/room_membership.rb') { |text| text.sub('  index', "  string :reason, required: true, default: \"convite\"\n  string :note, optional: true\n  index") }
      assert_equal 2, generated(compiler.build.document).size
    end
  end

  def test_same_local_entity_names_across_domains_need_explicit_commands
    with_app('blog') do |root, compiler|
      write(root, 'app/domains/other/domain.rb', 'domain :other do; depends_on; end')
      write(root, 'app/domains/other/post.rb', 'entity :post do; string :title; end')
      write(root, 'app/domains/blog/mirror.rb', "entity :mirror do\n  belongs_to :source, entity: :post\n  belongs_to :destination, entity: 'other.post'\n  index :source_id, :destination_id, unique: true\nend\n")
      edit(root, 'app/domains/blog/domain.rb') { |text| text.sub('depends_on', 'depends_on :other') }
      edit(root, 'app/domains/blog/post.rb') { |text| text.sub('  crud', "  many_to_many :mirrors, entity: 'other.post', through: :mirror\n  crud") }
      assert_graph_error('relation_command_contract') { compiler.build }
    end
  end

  def test_external_ir_requires_the_feature_and_known_command_primitives
    with_generated_chat do |_root, compiler|
      original = compiler.build.document
      document = Vetra::Graph::Data.copy(original)
      document['requires'].delete('vetra.relation_commands')
      assert_graph_error('ir_feature') { validate(document) }
      document = Vetra::Graph::Data.copy(original)
      node(document, 'command', 'chat.add_member')['implementation']['name'] = 'many_to_many.link.members'
      assert_graph_error('builtin_implementation') { validate(document) }
      %w[0.1 0.2 0.3].each do |version|
        document = Vetra::Graph::Data.copy(original)
        document['ir_version'] = version
        assert_graph_error('ir_feature') { validate(document) }
      end
    end
  end

  def test_external_ir_rejects_changes_to_the_typed_contract_authorization_and_effects
    mutations = [
      ->(doc, command) { node(doc, 'contract', command.dig('input', 'id'))['fields'].first['required'] = false },
      ->(doc, command) { node(doc, 'contract', command.dig('input', 'id'))['fields'].last['nullable'] = true },
      ->(doc, command) { node(doc, 'contract', command.dig('input', 'id'))['fields'].last['type']['entity']['id'] = 'chat.message' },
      ->(_doc, command) { command['authorize']['action'] = 'update' },
      ->(_doc, command) { command['authorize']['record'] = 'user_id' },
      ->(_doc, command) { command['authorize']['entity']['id'] = 'chat.user' },
      ->(_doc, command) { command['output']['id'] = 'chat.user.record' },
      ->(_doc, command) { command['uses'].first['id'] = 'chat.rooms_read' },
      ->(_doc, command) { command['uses'].first['id'] = 'chat.room_memberships' },
      ->(_doc, command) { command.delete('generated_from') },
      ->(_doc, command) { command['unsafe_effect'] = 'não permitido' },
      ->(_doc, command) { command['implementation']['name'] = 'many_to_many.add.owner' },
      ->(_doc, command) { command['implementation']['name'] = 'many_to_many.add.missing' }
    ]
    with_generated_chat do |_root, compiler|
      original = compiler.build.document
      mutations.each do |mutation|
        document = Vetra::Graph::Data.copy(original)
        mutation.call(document, node(document, 'command', 'chat.add_member'))
        error = assert_graph_error('relation_command_contract') { validate(document) }
        diagnostic = error.diagnostics.find { |item| item.code == 'relation_command_contract' }
        assert_equal 'app/domains/chat/room.rb', diagnostic.source['path']
        assert_match %r{\A/nodes/\d+}, diagnostic.pointer
      end
    end
  end

  def test_external_ir_cannot_add_effects_or_weaken_the_junction
    with_generated_chat do |_root, compiler|
      original = compiler.build.document
      document = Vetra::Graph::Data.copy(original)
      # Use uma emissão válida criada no próprio documento.
      document['nodes'] << { 'kind' => 'event', 'id' => 'chat.member_changed', 'domain' => { 'kind' => 'domain', 'id' => 'chat' },
        'source' => node(document, 'entity', 'chat.room')['source'], 'payload' => { 'kind' => 'contract', 'id' => 'chat.room.record' },
        'version' => 1, 'visibility' => 'internal', 'consumer_required' => false }
      node(document, 'command', 'chat.add_member')['emits'] = [{ 'event' => { 'kind' => 'event', 'id' => 'chat.member_changed' },
        'from' => { 'kind' => 'entity', 'id' => 'chat.room' }, 'fields' => node(document, 'entity', 'chat.room')['fields'].map { |field| field['name'] } }]
      assert_graph_error('relation_command_contract') { validate(document) }
      document = Vetra::Graph::Data.copy(original)
      node(document, 'entity', 'chat.room_membership')['indexes'].clear
      assert_graph_error('relation_command_junction') { validate(document) }
      document = Vetra::Graph::Data.copy(original)
      node(document, 'entity', 'chat.room_membership')['relations'].first['same_tenant'] = true
      assert_graph_error('relation_command_junction') { validate(document) }
      document = Vetra::Graph::Data.copy(original)
      node(document, 'entity', 'chat.room_membership')['fields'].find { |field| field['name'] == 'user_id' }['type'] = { 'name' => 'string' }
      assert_graph_error('relation_command_junction') { validate(document) }
    end
  end

  def test_older_artifacts_still_link_and_rebuild_adopts_generation_explicitly
    with_generated_chat do |root, compiler|
      %w[my_rooms room_page].each { |name| File.unlink(File.join(root, "app/domains/chat/#{name}.rb")) }
      edit(root, 'app/domains/chat/message.rb') { |text| text.sub('index :room_id, :created_at', 'index :room_id') }
      %w[0.1 0.2 0.3].each do |version|
        manifest = Vetra::Graph::Manifest.new(root)
        registry = Vetra::Graph::DeclarationLoader.new(manifest).load
        document = Vetra::Graph::Normalizer.new(registry, manifest, ir_version: version).document
        validate(document)
        FileUtils.mkdir_p(compiler.artifact.dirname)
        bytes = "#{Vetra::Graph::Canonical.dump(document)}\n"
        File.write(compiler.artifact, bytes)
        assert_equal document, compiler.validate_file(compiler.artifact, sources: true).document
        assert_equal document, compiler.link.document
        assert_empty generated(document)
        refute_includes document['requires'], 'vetra.relation_commands'
        assert_graph_error('graph_stale') { compiler.check }
        assert_equal bytes, compiler.artifact.binread
        assert_equal 2, generated(compiler.build.document).size
      end
    end
  end

  def test_ir_0_3_rejects_relation_primitives_even_without_the_requirement
    with_generated_chat do |_root, compiler|
      document = Vetra::Graph::Data.copy(compiler.build.document)
      document['ir_version'] = '0.3'
      document['requires'].delete('vetra.relation_commands')
      error = assert_graph_error('ir_feature') { validate(document) }
      assert_equal 2, error.diagnostics.count { |diagnostic| diagnostic.pointer.end_with?('/implementation') }
      assert_graph_error('ir_feature') { Vetra::Graph::Diff.new.compare(document, document) }
    end
  end

  def test_ir_0_3_links_structured_outputs_and_live_without_generating_relation_commands
    with_generated_chat do |root, compiler|
      manifest = Vetra::Graph::Manifest.new(root)
      registry = Vetra::Graph::DeclarationLoader.new(manifest).load
      document = Vetra::Graph::Normalizer.new(registry, manifest, ir_version: '0.3').document
      assert_includes document['requires'], 'vetra.structured_outputs'
      assert_includes document['requires'], 'vetra.live'
      refute_includes document['requires'], 'vetra.relation_commands'
      assert_empty generated(document)
      compiler.artifact.dirname.mkpath
      bytes = "#{Vetra::Graph::Canonical.dump(document)}\n"
      compiler.artifact.binwrite(bytes)
      assert_equal document, compiler.validate_file(compiler.artifact, sources: true).document
      assert_equal document, compiler.link.document
      assert_graph_error('graph_stale') { compiler.check }
      assert_equal bytes, compiler.artifact.binread
      assert_equal 2, generated(compiler.build.document).size
    end
  end

  def test_diff_reviews_ir_0_3_to_0_4_in_all_examples_without_breaking_changes
    %w[blog mini_crm mini_crm_revendas chat].each do |name|
      with_app(name) do |root, compiler|
        manifest = Vetra::Graph::Manifest.new(root)
        registry = Vetra::Graph::DeclarationLoader.new(manifest).load
        before = Vetra::Graph::Normalizer.new(registry, manifest, ir_version: '0.3').document
        report = Vetra::Graph::Diff.new.compare(before, compiler.build.document)
        refute report.breaking?, name
        version = report.data['changes'].find { |change| change['path'] == '/ir_version' }
        assert_equal '0.3', version['before']
        assert_equal '0.4', version['after']
        assert_equal 'review', version['impact']
        assert version['requires_review']
        assert_equal 1, report.data['summary']['total']
      end
    end
  end

  def test_diff_requires_permission_review_for_addition_and_reports_removal_as_breaking
    with_generated_chat do |root, compiler|
      enabled = compiler.build.document
      edit(root, 'app/domains/chat/room.rb') { |text| text.sub('include: :owner', 'include: :owner, commands: false') }
      disabled = compiler.build.document
      addition = Vetra::Graph::Diff.new.compare(disabled, enabled)
      refute addition.breaking?
      commands = addition.data['changes'].select { |change| change['kind'] == 'command' }
      assert_equal 2, commands.size
      assert commands.all? { |change| change['impact'] == 'additive' && change['requires_review'] && change['categories'].include?('permissions') }
      removal = Vetra::Graph::Diff.new.compare(enabled, disabled)
      assert removal.breaking?
      assert_equal 2, removal.data['changes'].count { |change| change['kind'] == 'command' && change['impact'] == 'breaking' }
    end
  end

  def test_diff_reviews_replacing_a_primitive_with_explicit_ruby_without_claiming_equivalence
    with_app('chat') do |root, compiler|
      explicit = compiler.build.document
      %w[add_member remove_member].each { |name| File.unlink(File.join(root, "app/domains/chat/#{name}.rb")) }
      edit(root, 'app/domains/chat/room.rb') { |text| text.sub(', commands: false', '') }
      automatic = compiler.build.document
      report = Vetra::Graph::Diff.new.compare(automatic, explicit)
      changes = report.data['changes'].select { |change| change['kind'] == 'command' && change['path'] == '/implementation' }
      assert_equal 2, changes.size
      assert changes.all? { |change| change['impact'] == 'review' && change['categories'].include?('implementation') }, changes.inspect
      assert report.data['changes'].none? { |change| change['kind'] == 'command' && change['path'] == '/' && %w[added removed].include?(change['change']) }
    end
  end

  def test_diff_reviews_permission_and_implementation_when_required_membership_changes
    with_generated_chat do |root, compiler|
      before = compiler.build.document
      edit(root, 'app/domains/chat/room.rb') { |text| text.sub(', include: :owner', '') }
      report = Vetra::Graph::Diff.new.compare(before, compiler.build.document)
      relation = report.data['changes'].find { |change| change['id'] == 'chat.room' && change['path'] == '/relations/members' }
      assert_equal 'review', relation['impact']
      assert_equal %w[implementation permissions storage], relation['categories']
      assert_equal 'indeterminate', relation['permission_impact']
      refute report.breaking?
    end
  end
end

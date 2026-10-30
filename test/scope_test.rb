require_relative 'test_helper'

class ScopeTest < GraphTest
  EXAMPLE = 'mini_crm_revendas'

  def with_dealers(&block)
    with_app(EXAMPLE, &block)
  end

  def policy_for(document, role, entity)
    document.fetch('nodes').find do |entry|
      entry['kind'] == 'policy' && entry.dig('role', 'id') == "crm.#{role}" && entry.dig('entity', 'id') == "crm.#{entity}"
    end || raise('Política não encontrada')
  end

  def membership_predicate(role, path)
    {
      'op' => 'exists', 'relation' => path,
      'where' => { 'op' => 'and', 'terms' => [
        { 'op' => 'eq', 'left' => { 'kind' => 'field', 'path' => ['user_id'] }, 'right' => { 'kind' => 'actor', 'path' => ['id'] } },
        { 'op' => 'eq', 'left' => { 'kind' => 'field', 'path' => ['role'] }, 'right' => { 'kind' => 'literal', 'value' => role } }
      ] }
    }
  end

  def test_example_compiles_without_warnings_and_derives_the_inverse_relation
    with_dealers do |_root, compiler|
      result = compiler.build
      assert_empty result.warnings
      document = result.document
      dealer = node(document, 'entity', 'crm.dealer')
      memberships = dealer['relations'].find { |relation| relation['name'] == 'memberships' }
      assert_equal 'has_many', memberships['kind']
      assert_equal 'crm.membership', memberships.dig('target', 'id')
      assert_equal %w[company_id id], memberships['local_fields']
      assert_equal %w[company_id dealer_id], memberships['target_fields']
      assert memberships['same_tenant']
      holder = node(document, 'entity', 'crm.membership')
      assert_equal %w[dealer user], holder['relations'].map { |relation| relation['name'] }
      refute document['nodes'].any? { |entry| entry.key?('memberships') }
    end
  end

  def test_scope_becomes_a_membership_predicate_with_the_role_name
    with_dealers do |_root, compiler|
      document = compiler.build.document
      %w[vendedor gerente].each do |role|
        lead = policy_for(document, role, 'lead')
        assert_equal membership_predicate(role, %w[dealer memberships]), lead['predicate']
        assert_equal %w[crm.dealer crm.lead crm.membership], lead['reads'].map { |reference| reference['id'] }
        dealer = policy_for(document, role, 'dealer')
        assert_equal membership_predicate(role, %w[memberships]), dealer['predicate']
        assert_equal %w[crm.dealer crm.membership], dealer['reads'].map { |reference| reference['id'] }
      end
      assert_equal %w[create delete read update], policy_for(document, 'gerente', 'lead')['actions']
      assert_equal %w[create read update], policy_for(document, 'vendedor', 'lead')['actions']
    end
  end

  def test_explicit_nil_scope_keeps_the_tenant_wide_policy
    with_dealers do |_root, compiler|
      document = compiler.build.document
      %w[company user membership].each do |entity|
        assert_equal({ 'op' => 'true' }, policy_for(document, 'gerente', entity)['predicate'])
      end
    end
  end

  def test_legacy_actor_scopes_are_unchanged
    with_app('mini_crm') do |_root, compiler|
      document = compiler.build.document
      assert_equal({ 'op' => 'true' }, node(document, 'policy', 'crm.vendedor.permission_1')['predicate'])
    end
    with_app do |_root, compiler|
      predicate = node(compiler.build.document, 'policy')['predicate']
      assert_equal %w[eq field actor], [predicate['op'], predicate.dig('left', 'kind'), predicate.dig('right', 'kind')]
      assert_equal ['author_id'], predicate.dig('left', 'path')
    end
  end

  def test_scope_without_memberships_declaration_is_rejected
    with_dealers do |root, compiler|
      edit(root, 'app/domains/crm/membership.rb') { |text| text.sub(/^  memberships .*\n/, '') }
      error = assert_graph_error('scope_unsupported') { compiler.build }
      assert_match(/memberships of: :dealer/, error.message)
    end
  end

  def test_role_missing_from_the_membership_enum_is_rejected
    with_dealers do |root, compiler|
      edit(root, 'app/domains/crm/roles.rb') { |text| text.sub('role :gerente do', 'role :supervisor do') }
      error = assert_graph_error('memberships_role') { compiler.build }
      assert_match(/supervisor/, error.message)
    end
  end

  def test_scope_requires_the_has_many_inverse_on_the_scope_entity
    with_dealers do |root, compiler|
      edit(root, 'app/domains/crm/dealer.rb') { |text| text.sub(/^  has_many .*\n/, '') }
      assert_graph_error('scope_inverse') { compiler.build }
    end
  end

  def test_record_must_reach_the_scope_entity_through_its_own_relation
    with_dealers do |root, compiler|
      write(root, 'app/domains/crm/note.rb', "entity :note do\n  tenant :company\n  string :text, required: true\nend\n")
      edit(root, 'app/domains/crm/roles.rb') { |text| text.sub('can :read, on: :dealer', "can :read, on: :dealer\n    can :read, on: :note") }
      error = assert_graph_error('scope_unsupported') { compiler.build }
      assert_match(/crm\.note não declara belongs_to :dealer/, error.message)
    end
  end

  def test_anonymous_roles_cannot_use_a_membership_scope
    with_dealers do |root, compiler|
      edit(root, 'app/domains/crm/roles.rb') { |text| text.sub('role :gerente do', "visitor do\n    can :read, on: :lead\n  end\n  role :gerente do") }
      assert_graph_error('scope_anonymous') { compiler.build }
    end
  end

  def test_membership_declaration_is_checked
    with_dealers do |root, compiler|
      edit(root, 'app/domains/crm/membership.rb') { |text| text.sub('actor: :user', 'actor: :owner') }
      assert_graph_error('memberships_relation') { compiler.build }
    end
    with_dealers do |root, compiler|
      edit(root, 'app/domains/crm/membership.rb') { |text| text.sub('role: :role', 'role: :user_id') }
      assert_graph_error('memberships_role') { compiler.build }
    end
    with_dealers do |root, compiler|
      edit(root, 'app/domains/crm/membership.rb') { |text| text.sub('enum :role, %w[vendedor gerente]', 'string :role, required: true') }
      assert_graph_error('memberships_role') { compiler.build }
    end
  end

  def test_membership_scope_declared_twice_is_rejected
    with_dealers do |root, compiler|
      edit(root, 'app/domains/crm/membership.rb') { |text| text.sub(/^  memberships .*\n/) { |line| line * 2 } }
      assert_graph_error('duplicate_memberships') { compiler.build }
    end
    with_dealers do |root, compiler|
      write(root, 'app/domains/crm/second.rb', <<~RUBY)
        entity :second do
          tenant :company
          belongs_to :user, same_tenant: true
          belongs_to :dealer, same_tenant: true
          enum :role, %w[vendedor gerente]
          memberships of: :dealer, actor: :user, role: :role
        end
      RUBY
      assert_graph_error('memberships_ambiguous') { compiler.build }
    end
  end

  def test_has_many_needs_a_matching_belongs_to
    with_dealers do |root, compiler|
      edit(root, 'app/domains/crm/dealer.rb') { |text| text.sub('by: :dealer', 'by: :company') }
      assert_graph_error('relation_inverse') { compiler.build }
    end
    with_dealers do |root, compiler|
      edit(root, 'app/domains/crm/dealer.rb') { |text| text.sub('has_many :memberships, entity: :membership, by: :dealer', 'has_many :memberships, entity: :membership, by: :user') }
      assert_graph_error('relation_inverse') { compiler.build }
    end
  end

  def test_validator_rejects_a_has_many_without_the_inverse_key
    with_dealers do |_root, compiler|
      document = Vetra::Graph::Data.copy(compiler.build.document)
      node(document, 'entity', 'crm.membership')['relations'].reject! { |relation| relation['name'] == 'dealer' }
      document['digest'] = Vetra::Graph::Canonical.digest(document)
      assert_graph_error('relation_inverse') { Vetra::Graph::Validator.new.validate!(document) }

      document = Vetra::Graph::Data.copy(compiler.build.document)
      relation = node(document, 'entity', 'crm.dealer')['relations'].find { |item| item['name'] == 'memberships' }
      relation['target_fields'] = %w[company_id user_id]
      document['digest'] = Vetra::Graph::Canonical.digest(document)
      assert_graph_error('relation_inverse') { Vetra::Graph::Validator.new.validate!(document) }
    end
  end

  def test_validator_requires_reads_to_cover_the_membership_path
    with_dealers do |_root, compiler|
      document = Vetra::Graph::Data.copy(compiler.build.document)
      policy_for(document, 'vendedor', 'lead')['reads'].reject! { |reference| reference['id'] == 'crm.membership' }
      document['digest'] = Vetra::Graph::Canonical.digest(document)
      assert_graph_error('policy_reads') { Vetra::Graph::Validator.new.validate!(document) }
    end
  end

  def test_example_links_and_builds_reproducibly
    with_dealers do |_root, compiler|
      expected = compiler.write
      linked = compiler.link
      assert_equal expected.document, linked.document
      assert_equal %w[crm.notify_seller#call crm.win_lead#call], linked.implementation_ids
      assert_equal 4, linked.builtin_bindings.size
      assert_empty linked.warnings
      assert_equal expected.bytes, compiler.build.bytes
    end
  end

  def test_changing_a_role_scope_shows_up_as_a_permission_change_in_the_diff
    with_dealers do |root, compiler|
      before = compiler.build.document
      edit(root, 'app/domains/crm/roles.rb') { |text| text.sub('can :manage, on: :lead', 'can :read, on: :lead') }
      after = Vetra::Graph::Compiler.new(root: root).build.document
      report = Vetra::Graph::Diff.new.compare(before, after)
      changes = report.data['changes'].select { |change| change['id'] == 'crm.gerente.permission_1' }
      assert_equal ['/actions'], changes.map { |change| change['path'] }
      assert_equal ['indeterminate'], changes.map { |change| change['permission_impact'] }
    end
  end
end

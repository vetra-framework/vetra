require_relative 'test_helper'

class RateLimitTest < GraphTest
  FEATURE = 'vetra.rate_limit'
  POLICY = 'blog.autor.permission_1'

  def set_limit(root, expression)
    edit(root, 'app/domains/blog/roles.rb') do |text|
      text.sub('scope: :author', "scope: :author, rate_limit: #{expression}")
    end
  end

  def normalize(root, version)
    manifest = Vetra::Graph::Manifest.new(root)
    registry = Vetra::Graph::DeclarationLoader.new(manifest).load
    Vetra::Graph::Normalizer.new(registry, manifest, ir_version: version).document
  end

  def validate(document)
    document['digest'] = Vetra::Graph::Canonical.digest(document)
    Vetra::Graph::Validator.new.validate!(document)
  end

  def descriptor(document)
    node(document, 'policy', POLICY).fetch('rate_limit')
  end

  def test_omission_does_not_require_the_feature_with_or_without_tenant
    %w[mini_crm chat].each do |name|
      with_app(name) do |_root, compiler|
        document = compiler.write.document
        assert_equal '0.6', document['ir_version']
        refute_includes document['requires'], FEATURE
        refute document['nodes'].any? { |entry| entry.key?('rate_limit') }
        assert_equal document, compiler.check.document
        assert_equal document, compiler.validate_file(compiler.artifact, sources: true).document
        assert_equal document, compiler.link.document
      end
    end
  end

  def test_explicit_units_and_positive_windows_normalize_and_link_without_execution
    { '5/s' => [5, 1], '5/min' => [5, 60], '5/2min' => [5, 120], '2/h' => [2, 3600],
      '3/2h' => [3, 7200], '1/30s' => [1, 30] }.each do |text, (limit, seconds)|
      with_app do |root, compiler|
        set_limit(root, text.inspect)
        edit(root, 'app/domains/blog/find_post.rb') { |source| source.sub('posts.find!(input.post_id)', '::Kernel.raise "call executed"') }
        document = compiler.write.document
        assert_equal({ 'limit' => limit, 'window_seconds' => seconds, 'key' => 'actor_tenant' }, descriptor(document))
        assert_includes document['requires'], FEATURE
        assert_equal 1, document['requires'].count(FEATURE)
        assert_equal document, compiler.validate_file(compiler.artifact, sources: true).document
        assert_equal document, compiler.check.document
        assert_equal document, compiler.link.document
        assert_equal compiler.artifact.binread, compiler.build.bytes
      end
    end
  end

  def test_equivalent_units_have_identical_policy_and_no_semantic_diff
    with_app do |root, compiler|
      set_limit(root, '"5/min"')
      before = compiler.build.document
      edit(root, 'app/domains/blog/roles.rb') { |text| text.sub('"5/min"', '"5/60s"') }
      after = compiler.build.document
      assert_equal node(before, 'policy', POLICY), node(after, 'policy', POLICY)
      report = Vetra::Graph::Diff.new.compare(before, after)
      refute report.breaking?
      assert report.data['changes'].all? { |change| change['impact'] == 'metadata' }
    end
  end

  def test_invalid_syntax_types_units_and_nonpositive_values_have_source_and_pointer
    ['nil', 'true', 'false', '5', ':minute', '[]', '{}', '""', '"5"', '"5/"', '"5/1"',
     '"0/min"', '"-5/min"', '"1.5/min"', '"5/0min"', '"5/-1min"', '"5/1.5min"',
     '"05/min"', '"5/01min"', '"5/MIN"', '"5/day"', '"5/ms"', '" 5/min"', '"5/min "',
     '"5/min\n"', '"9007199254740992/s"', '"1/9007199254740992s"', '"1/9007199254740991h"'].each do |expression|
      with_app do |root, compiler|
        set_limit(root, expression)
        line = File.readlines(File.join(root, 'app/domains/blog/roles.rb')).index { |text| text.include?('scope: :author') } + 1
        error = assert_graph_error('rate_limit') { compiler.build }
        diagnostic = error.diagnostics.find { |entry| entry.code == 'rate_limit' }
        assert_equal '/rate_limit', diagnostic.pointer
        assert_equal({ 'path' => 'app/domains/blog/roles.rb', 'line' => line }, diagnostic.source)
        assert_includes diagnostic.message, '5/min'
        refute_includes error.diagnostics.map(&:code), 'dsl_error'
      end
    end
  end

  def test_unknown_can_options_remain_audible
    with_app do |root, compiler|
      set_limit(root, '"5/min", rate_limt: "1/s"')
      error = assert_graph_error('unsupported_option') { compiler.build }
      assert_includes error.message, 'rate_limt'
    end
  end

  def test_limit_does_not_change_predicate_fields_actions_or_dependencies
    with_app do |root, compiler|
      original = compiler.build.document
      set_limit(root, '"5/min"')
      current = compiler.build.document
      assert_equal node(original, 'policy', POLICY), node(current, 'policy', POLICY).reject { |key, _| key == 'rate_limit' }
      assert_equal original['nodes'].reject { |entry| entry['kind'] == 'policy' }, current['nodes'].reject { |entry| entry['kind'] == 'policy' }
    end
  end

  def test_multiple_actions_share_a_policy_and_multiple_entities_have_separate_policies
    with_app do |root, compiler|
      edit(root, 'app/domains/blog/post.rb') { |text| text.sub('crud scope: :author', 'crud') }
      write(root, 'app/domains/blog/topic.rb', "entity :topic do\n  string :title\nend\n")
      write(root, 'app/domains/blog/roles.rb', <<~RUBY)
        roles do
          authenticated do
            can :read, :create, on: %i[post topic], fields: [:title], rate_limit: "5/min"
          end
        end
      RUBY
      document = compiler.build.document
      policies = document['nodes'].select { |entry| entry['kind'] == 'policy' }
      assert_equal 2, policies.size
      assert_equal %w[blog.authenticated.permission_1 blog.authenticated.permission_2], policies.map { |entry| entry['id'] }
      assert_equal %w[blog.post blog.topic], policies.map { |entry| entry.dig('entity', 'id') }
      policies.each do |policy|
        assert_equal %w[create read], policy['actions']
        assert_equal ['title'], policy['fields']
        assert_equal({ 'op' => 'true' }, policy['predicate'])
        assert_equal({ 'limit' => 5, 'window_seconds' => 60, 'key' => 'actor_tenant' }, policy['rate_limit'])
      end
      assert_equal 1, document['requires'].count(FEATURE)
    end
  end

  def test_external_ir_requires_the_feature_and_diff_refuses_it_without_requirement
    with_app do |root, compiler|
      set_limit(root, '"5/min"')
      document = Vetra::Graph::Data.copy(compiler.build.document)
      document['requires'].delete(FEATURE)
      error = assert_graph_error('ir_feature') { validate(document) }
      policy = node(document, 'policy', POLICY)
      diagnostic = error.diagnostics.find { |entry| entry.source == policy['source'] }
      assert diagnostic.pointer.end_with?('/rate_limit')
      assert_graph_error('ir_feature') { Vetra::Graph::Diff.new.compare(document, document) }
    end
  end

  def test_external_ir_rejects_invalid_or_incomplete_descriptors
    with_app do |root, compiler|
      set_limit(root, '"5/min"')
      original = compiler.build.document
      invalid = [nil, false, 5, '5/min', [], {},
                 { 'limit' => 5, 'window_seconds' => 60 },
                 { 'limit' => 5, 'key' => 'actor_tenant' },
                 { 'window_seconds' => 60, 'key' => 'actor_tenant' }]
      %w[limit window_seconds].each do |key|
        [0, -1, '5', true, nil, [], {}, 9007199254740992].each do |value|
          invalid << descriptor(original).merge(key => value)
        end
      end
      [nil, 'actor', 'tenant', ['actor', 'tenant']].each { |key| invalid << descriptor(original).merge('key' => key) }
      invalid << descriptor(original).merge('burst' => 10)
      invalid.each do |value|
        document = Vetra::Graph::Data.copy(original)
        node(document, 'policy', POLICY)['rate_limit'] = value
        error = assert_graph_error('schema') { Vetra::Graph::Validator.new.validate!(document, verify_digest: false) }
        assert error.diagnostics.any? { |entry| entry.pointer.include?('/rate_limit') }
      end
    end
  end

  def test_external_ir_refuses_fractional_values_and_rejects_rate_limit_outside_policy
    with_app do |root, compiler|
      set_limit(root, '"5/min"')
      original = compiler.build.document
      %w[limit window_seconds].each do |key|
        document = Vetra::Graph::Data.copy(original)
        descriptor(document)[key] = 1.5
        assert_graph_error('schema') { Vetra::Graph::Validator.new.validate!(document, verify_digest: false) }
      end
      %w[entity command route role].each do |kind|
        document = Vetra::Graph::Data.copy(original)
        node(document, kind)['rate_limit'] = descriptor(document)
        assert_graph_error('schema') { validate(document) }
      end
    end
  end

  def test_external_ir_may_require_the_feature_without_using_it
    with_app('mini_crm') do |_root, compiler|
      document = Vetra::Graph::Data.copy(compiler.build.document)
      document['requires'] << FEATURE
      assert validate(document)
    end
  end

  def test_previous_formats_refuse_field_and_feature_independently
    with_app('mini_crm') do |root, _compiler|
      %w[0.1 0.2 0.3 0.4 0.5].each do |version|
        original = normalize(root, version)
        document = Vetra::Graph::Data.copy(original)
        document['requires'] << FEATURE
        assert_graph_error('ir_feature') { validate(document) }
        document = Vetra::Graph::Data.copy(original)
        node(document, 'policy')['rate_limit'] = { 'limit' => 5, 'window_seconds' => 60, 'key' => 'actor_tenant' }
        assert_graph_error('schema') { validate(document) }
        assert_graph_error('schema') { Vetra::Graph::Diff.new.compare(document, document) }
      end
    end
  end

  def test_previous_formats_cannot_silently_discard_an_explicit_limit
    with_app do |root, _compiler|
      set_limit(root, '"5/min"')
      %w[0.1 0.2 0.3 0.4 0.5].each do |version|
        assert_graph_error('ir_feature') { normalize(root, version) }
      end
    end
  end

  def test_previous_artifacts_validate_and_link_without_new_fields_or_requirements
    with_app('mini_crm') do |root, compiler|
      %w[0.1 0.2 0.3 0.4 0.5].each do |version|
        document = normalize(root, version)
        refute_includes document['requires'], FEATURE
        refute document['nodes'].any? { |entry| entry.key?('rate_limit') }
        compiler.artifact.dirname.mkpath
        bytes = "#{Vetra::Graph::Canonical.dump(document)}\n"
        compiler.artifact.binwrite(bytes)
        assert_equal document, compiler.validate_file(compiler.artifact, sources: true).document
        assert_equal document, compiler.link.document
        assert_equal bytes, compiler.artifact.binread
        assert_graph_error('graph_stale') { compiler.check }
        report = Vetra::Graph::Diff.new.compare(document, compiler.build.document)
        refute report.breaking?
        refute report.data['changes'].any? { |entry| entry['path'] == '/rate_limit' }
      end
    end
  end

  def test_ir_0_5_preserves_explicit_rounding_on_link
    with_app('mini_crm_revendas') do |root, compiler|
      document = normalize(root, '0.5')
      assert_equal 'half_up', document.dig('app', 'rounding')
      assert_includes document['requires'], 'vetra.money_rounding'
      refute_includes document['requires'], FEATURE
      compiler.artifact.dirname.mkpath
      compiler.artifact.binwrite("#{Vetra::Graph::Canonical.dump(document)}\n")
      assert_equal document, compiler.link.document
    end
  end

  def test_link_refuses_valid_but_tampered_limits_instead_of_rebuilding
    with_app do |root, compiler|
      set_limit(root, '"5/min"')
      document = Vetra::Graph::Data.copy(compiler.write.document)
      descriptor(document)['limit'] = 6
      validate(document)
      bytes = "#{Vetra::Graph::Canonical.dump(document)}\n"
      compiler.artifact.binwrite(bytes)
      assert_graph_error('graph_model_mismatch') { compiler.link }
      assert_equal bytes, compiler.artifact.binread
    end
  end

  def test_link_refuses_missing_requirement_before_evaluating_project_sources
    with_app do |root, compiler|
      set_limit(root, '"5/min"')
      edit(root, 'config/app.rb') { |text| "::Thread.current[:vetra_rate_limit_loads] = true\n#{text}" }
      document = Vetra::Graph::Data.copy(compiler.write.document)
      document['requires'].delete(FEATURE)
      document['digest'] = Vetra::Graph::Canonical.digest(document)
      compiler.artifact.binwrite("#{Vetra::Graph::Canonical.dump(document)}\n")
      Thread.current[:vetra_rate_limit_loads] = false
      assert_graph_error('ir_feature') { compiler.link }
      refute Thread.current[:vetra_rate_limit_loads]
    ensure
      Thread.current[:vetra_rate_limit_loads] = nil
    end
  end

  def test_diff_reviews_addition_and_tightening_and_marks_relaxation_removal_and_incomparable_changes_as_breaking
    with_app do |root, compiler|
      set_limit(root, '"5/min"')
      original = compiler.build.document
      [nil, [4, 60], [5, 120], [4, 120], [6, 60], [5, 30], [6, 30], [10, 120], [4, 30]].each do |values|
        document = Vetra::Graph::Data.copy(original)
        if values
          descriptor(document).merge!('limit' => values.first, 'window_seconds' => values.last)
        else
          node(document, 'policy', POLICY).delete('rate_limit')
        end
        validate(document)
        [[original, document], [document, original]].each do |before, after|
          old_limit = node(before, 'policy', POLICY)['rate_limit']
          new_limit = node(after, 'policy', POLICY)['rate_limit']
          tightening = old_limit.nil? || (new_limit && new_limit['limit'] <= old_limit['limit'] && new_limit['window_seconds'] >= old_limit['window_seconds'])
          report = Vetra::Graph::Diff.new.compare(before, after)
          change = report.data['changes'].find { |entry| entry['id'] == POLICY && entry['path'] == '/rate_limit' }
          assert_equal tightening ? 'review' : 'breaking', change['impact']
          assert_equal !tightening, report.breaking?
          assert_equal ['permissions'], change['categories']
          assert_equal 'indeterminate', change['permission_impact']
          assert change['requires_review']
          assert_equal old_limit.nil?, !change['before_present']
          assert_equal new_limit.nil?, !change['after_present']
        end
      end
    end
  end

  def test_example_uses_the_proposal_limit_on_visitor_comment_creation_only
    with_app do |_root, compiler|
      document = compiler.write.document
      limited = document['nodes'].select { |entry| entry.key?('rate_limit') }
      assert_equal 1, limited.size
      policy = limited.first
      assert_equal 'blog.comment', policy.dig('entity', 'id')
      assert_equal 'blog.visitor', policy.dig('role', 'id')
      assert_equal ['create'], policy['actions']
      assert_equal %w[author_email author_name body post_id], policy['fields']
      assert_equal({ 'limit' => 5, 'window_seconds' => 60, 'key' => 'actor_tenant' }, policy['rate_limit'])
      assert node(document, 'role', 'blog.visitor')['anonymous']
      admin = node(document, 'policy', 'blog.admin.permission_2')
      assert_equal 'blog.comment', admin.dig('entity', 'id')
      assert_includes admin['actions'], 'create'
      assert_equal '*', admin['fields']
      assert_equal({ 'op' => 'true' }, admin['predicate'])
      refute admin.key?('rate_limit')
      assert node(document, 'contract', 'blog.create_comment.input')['fields'].none? { |field| field['name'] == 'approved' }
      assert_equal [{ 'kind' => 'command', 'id' => 'blog.approve_comment' }], node(document, 'entity', 'blog.comment')['fields'].find { |field| field['name'] == 'approved' }['set_by']
      assert_equal document, compiler.link.document
    end
  end

  def test_removing_an_entire_limited_policy_is_a_potential_security_break
    with_app do |root, compiler|
      set_limit(root, '"5/min"')
      before = compiler.build.document
      after = Vetra::Graph::Data.copy(before)
      after['nodes'].reject! { |entry| entry['kind'] == 'policy' && entry['id'] == POLICY }
      validate(after)
      report = Vetra::Graph::Diff.new.compare(before, after)
      assert report.breaking?
      change = report.data['changes'].find { |entry| entry['id'] == POLICY }
      assert_equal 'removed', change['change']
      assert_equal 'breaking', change['impact']
      assert_equal ['permissions'], change['categories']
      assert change['requires_review']
      assert_equal 'indeterminate', change['permission_impact']
    end
  end

  def test_limits_on_tenant_policies_use_the_same_actor_tenant_key
    with_app('mini_crm') do |root, compiler|
      edit(root, 'app/domains/crm/roles.rb') { |text| text.sub('on: :lead', 'on: :lead, rate_limit: "5/min"') }
      document = compiler.write.document
      assert document.dig('app', 'tenant')
      assert_equal({ 'limit' => 5, 'window_seconds' => 60, 'key' => 'actor_tenant' }, node(document, 'policy', 'crm.vendedor.permission_1')['rate_limit'])
      assert_equal document, compiler.link.document
    end
  end

  def test_largest_safe_integers_are_accepted
    with_app do |root, compiler|
      set_limit(root, '"9007199254740991/9007199254740991s"')
      assert_equal({ 'limit' => 9007199254740991, 'window_seconds' => 9007199254740991, 'key' => 'actor_tenant' }, descriptor(compiler.build.document))
    end
  end
end

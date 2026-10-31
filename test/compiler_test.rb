require_relative 'test_helper'

class CompilerTest < GraphTest
  def test_examples_compile_with_and_without_tenant_and_real_input_digests
    %w[blog mini_crm].each do |name|
      with_app(name) do |root, compiler|
        result = compiler.build
        assert_empty result.warnings
        assert result.document.frozen?
        assert_equal Vetra::Graph::Canonical.digest(result.document), result.document['digest']
        result.document['inputs'].each do |input|
          assert_equal "sha256:#{Digest::SHA256.file(File.join(root, input['path'])).hexdigest}", input['digest']
        end
        result.document['nodes'].each do |entry|
          refute entry['source']['path'].start_with?('/')
          assert entry.frozen?
        end
        assert_equal(name == 'mini_crm', !result.document.dig('app', 'tenant').nil?)
      end
    end
  end

  def test_repeated_builds_in_different_directories_have_identical_bytes
    with_app do |first_root, first_compiler|
      first = first_compiler.build
      Dir.mktmpdir('vetra-copy-') do |second_root|
        FileUtils.cp_r("#{first_root}/.", second_root)
        second = Vetra::Graph::Compiler.new(root: second_root).build
        assert_equal first.bytes, second.bytes
        assert_equal first.bytes, first_compiler.build.bytes
      end
    end
  end

  def test_registry_is_evaluated_once_and_call_is_never_executed
    with_app do |root, compiler|
      Thread.current[:vetra_test_loads] = 0
      edit(root, 'config/app.rb') { |text| "::Thread.current[:vetra_test_loads] += 1\n#{text}" }
      edit(root, 'app/domains/blog/find_post.rb') { |text| text.sub('posts.find!(input.post_id)', '::Kernel.raise "call executed"') }
      assert compiler.build
      assert_equal 1, Thread.current[:vetra_test_loads]
      assert_graph_error('dsl_context') { Vetra.app(:outside) {} }
    ensure
      Thread.current[:vetra_test_loads] = nil
    end
  end

  def test_crud_contracts_exclude_owned_fields_protected_values_and_tenant
    with_app do |_root, compiler|
      document = compiler.build.document
      create = node(document, 'contract', 'blog.create_post.input')
      update = node(document, 'contract', 'blog.update_post.input')
      refute create['fields'].any? { |field| field['name'] == 'published_at' }
      assert_equal ['draft'], create['fields'].find { |field| field['name'] == 'status' }.dig('type', 'values')
      refute update['fields'].any? { |field| field.key?('default') }
      assert_equal ['id'], update['fields'].select { |field| field['required'] }.map { |field| field['name'] }
      policy = node(document, 'policy')
      assert_equal 'eq', policy.dig('predicate', 'op')
      assert_equal ['author_id'], policy.dig('predicate', 'left', 'path')
    end
    with_app('mini_crm') do |_root, compiler|
      create = node(compiler.build.document, 'contract', 'crm.create_lead.input')
      refute create['fields'].any? { |field| field['name'] == 'company_id' }
    end
  end

  def test_queries_get_read_only_repositories
    with_app do |_root, compiler|
      document = compiler.build.document
      query = node(document, 'query', 'blog.find_post')
      assert_equal ['blog.posts_read'], query['uses'].map { |ref| ref['id'] }
      assert_equal 'read', node(document, 'capability', 'blog.posts_read').dig('config', 'access')
    end
  end

  def test_call_metadata_and_registration_remain_outside_ir
    with_app do |_root, compiler|
      result = compiler.build
      assert_equal %w[blog.find_post#call blog.publish_post#call], result.implementation_ids
      assert_equal 'ruby', node(result.document, 'command', 'blog.publish_post').dig('implementation', 'kind')
      assert_raises(FrozenError) { result.document['nodes'] << {} }
      assert_raises(FrozenError) { result.document['app']['name'].replace('changed') }
      assert Ractor.make_shareable(result.document)
    end
    registry = Vetra::Graph::Registry.new
    registry.seal!
    assert_graph_error('registry_frozen') { registry.add({}) }
  end

  def test_check_detects_missing_edited_and_noncanonical_artifacts_without_overwriting
    with_app do |_root, compiler|
      assert_graph_error('graph_stale') { compiler.check }
      result = compiler.write
      assert_equal result.bytes, compiler.artifact.binread
      assert compiler.check
      compiler.artifact.write(JSON.pretty_generate(result.document))
      before = compiler.artifact.binread
      assert_graph_error('graph_stale') { compiler.check }
      assert_equal before, compiler.artifact.binread
    end
  end

  def test_helpers_lockfile_additions_and_removals_invalidate_sources
    %w[helper lock addition removal].each do |change|
      with_app do |root, compiler|
        write(root, 'lib/helper.rb', '# version one')
        compiler.write
        case change
        when 'helper' then write(root, 'lib/helper.rb', '# version two')
        when 'lock' then edit(root, 'Gemfile.lock') { |text| "#{text}\n" }
        when 'addition' then write(root, 'lib/new_helper.rb', '# new')
        when 'removal' then File.unlink(File.join(root, 'lib/helper.rb'))
        end
        assert_graph_error('graph_stale') { compiler.check }
        assert_graph_error('inputs_changed') { compiler.validate_file(compiler.artifact, sources: true) }
      end
    end
  end

  def test_loss_of_discardable_cache_preserves_graph
    with_app do |root, compiler|
      expected = compiler.write.bytes
      write(root, '.vetra/cache/broken.bin', 'not a cache')
      assert_equal expected, compiler.check.bytes
      FileUtils.rm_rf(File.join(root, '.vetra/cache'))
      assert_equal expected, compiler.check.bytes
    end
  end

  def test_secrets_are_excluded_and_input_symlink_cannot_escape_project
    with_app do |root, compiler|
      write(root, 'config/secrets.enc', 'secret value')
      write(root, 'config/credentials.yml.enc', 'secret value')
      refute compiler.build.document['inputs'].any? { |input| input['path'].match?(/secrets|credentials/) }
      File.symlink(File.join(PROJECT, 'README.md'), File.join(root, 'app/leak.rb'))
      assert_graph_error('input_path') { compiler.build }
    end
  end

  def test_bad_declarations_fail_with_source_and_cleanup_loader_context
    with_app do |root, compiler|
      edit(root, 'app/domains/blog/post.rb') { |text| text.sub('crud scope: :author', 'crud ui: :admin') }
      error = assert_graph_error('unsupported_option') { compiler.build }
      assert_includes error.message, 'app/domains/blog/post.rb'
      assert_graph_error('dsl_context') { Vetra.app(:outside) {} }
    end
    # Um erro de argumentos que não é de palavra-chave continua sendo dsl_error.
    with_app do |root, compiler|
      edit(root, 'app/domains/blog/post.rb') { |text| text.sub('crud scope: :author', 'crud :author') }
      assert_graph_error('dsl_error') { compiler.build }
    end
  end

  def test_unsupported_constructs_duplicate_declarations_and_unresolved_return_are_rejected
    with_app do |root, compiler|
      write(root, 'app/domains/blog/unsupported.rb', "page '/posts'\n")
      assert_graph_error('unsupported_declaration') { compiler.build }
    end
    with_app do |root, compiler|
      write(root, 'app/domains/blog/duplicate.rb', "entity :post do\n string :other\nend\n")
      assert_graph_error('duplicate_id') { compiler.build }
    end
    with_app do |root, compiler|
      edit(root, 'app/domains/blog/find_post.rb') { |text| text.sub("  returns :post\n", '') }
      assert_graph_error('output_contract') { compiler.build }
    end
  end

  def test_known_direct_effects_are_rejected_and_exceptions_remain_visible
    with_app do |root, compiler|
      edit(root, 'app/domains/blog/find_post.rb') { |text| text.sub('posts.find!(input.post_id)', 'Time.now') }
      assert_graph_error('direct_effect') { compiler.build }
      edit(root, 'app/domains/blog/find_post.rb') { |text| text.sub('  uses :posts', "  unsafe_effect 'legacy clock'\n  uses :posts") }
      result = compiler.build
      assert_includes result.warnings.map(&:code), 'unsafe_effect'
      assert_equal 'legacy clock', node(result.document, 'query', 'blog.find_post')['unsafe_effect']
    end
  end

  def test_direct_database_access_is_rejected_like_other_direct_effects
    {
      'Sequel.connect("postgres://x/y")' => 'Sequel.connect',
      'Sequel::Database.new' => 'Sequel::Database.new',
      'ActiveRecord::Base.connection' => 'ActiveRecord::Base.connection',
      'PG.connect("postgres://x/y")' => 'PG.connect'
    }.each do |expression, label|
      with_app do |root, compiler|
        edit(root, 'app/domains/blog/find_post.rb') { |text| text.sub('posts.find!(input.post_id)', expression) }
        error = assert_graph_error('direct_effect') { compiler.build }
        assert_includes error.message, label
      end
    end
    with_app do |root, compiler|
      edit(root, 'app/domains/blog/find_post.rb') { |text| text.sub('posts.find!(input.post_id)', 'Sequel.connect("postgres://x/y")') }
      edit(root, 'app/domains/blog/find_post.rb') { |text| text.sub('  uses :posts', "  unsafe_effect 'legacy connection'\n  uses :posts") }
      result = compiler.build
      assert_includes result.warnings.map(&:code), 'unsafe_effect'
      assert_equal 'legacy connection', node(result.document, 'query', 'blog.find_post')['unsafe_effect']
    end
  end

  def test_names_that_only_start_like_database_constants_are_not_direct_effects
    with_app do |root, compiler|
      edit(root, 'app/domains/blog/find_post.rb') { |text| text.sub('posts.find!(input.post_id)', 'Sequelizer.run(input.post_id)') }
      result = compiler.build
      assert_includes node(result.document, 'query', 'blog.find_post').dig('implementation', 'analysis', 'constants'), 'Sequelizer'
    end
  end

  def test_dynamic_calls_are_recorded_without_executing_them
    with_app do |root, compiler|
      edit(root, 'app/domains/blog/find_post.rb') { |text| text.sub('posts.find!(input.post_id)', 'posts.public_send(input.post_id)') }
      result = compiler.build
      assert_includes result.warnings.map(&:code), 'analysis_incomplete'
      assert_equal 'incomplete', node(result.document, 'query', 'blog.find_post').dig('implementation', 'analysis', 'status')
    end
  end

  def test_static_repository_writes_respect_query_and_transition_boundaries
    with_app do |root, compiler|
      edit(root, 'app/domains/blog/find_post.rb') { |text| text.sub('posts.find!(input.post_id)', 'posts.update!(input.post_id, title: "changed")') }
      assert_graph_error('write_boundary') { compiler.build }
    end
    with_app do |root, compiler|
      edit(root, 'app/domains/blog/find_post.rb') { |text| text.sub('query :find_post', 'command :find_post').sub('posts.find!(input.post_id)', 'posts.update!(input.post_id, status: "published")') }
      assert_graph_error('transition_owner') { compiler.build }
    end
  end

  def test_missing_event_consumer_fails_before_writing_artifact
    with_app('mini_crm') do |root, compiler|
      File.unlink(File.join(root, 'app/domains/crm/notify_sales.rb'))
      error = assert_graph_error('event_consumer') { compiler.write }
      assert_includes error.message, '/nodes/'
      refute compiler.artifact.exist?
    end
  end

  def test_declared_relations_generate_composite_tenant_foreign_keys
    with_app('mini_crm') do |root, compiler|
      write(root, 'app/domains/crm/dealer.rb', "entity :dealer do\n string :name\nend\n")
      edit(root, 'app/domains/crm/lead.rb') { |text| text.sub('  belongs_to :company', "  belongs_to :company\n  belongs_to :dealer, same_tenant: true") }
      relation = node(compiler.build.document, 'entity', 'crm.lead')['relations'].find { |entry| entry['name'] == 'dealer' }
      assert_equal %w[company_id dealer_id], relation['local_fields']
      assert_equal %w[company_id id], relation['target_fields']
    end
  end

  def test_tampered_crud_contract_cannot_restore_a_transition_or_weaken_its_type
    with_app do |_root, compiler|
      document = Vetra::Graph::Data.copy(compiler.build.document)
      status = node(document, 'contract', 'blog.update_post.input')['fields'].find { |field| field['name'] == 'status' }
      status['type']['values'] << 'published'
      document['digest'] = Vetra::Graph::Canonical.digest(document)
      assert_graph_error('crud_contract') { Vetra::Graph::Validator.new.validate!(document) }
      status['type'] = { 'name' => 'string' }
      document['digest'] = Vetra::Graph::Canonical.digest(document)
      assert_graph_error('crud_contract') { Vetra::Graph::Validator.new.validate!(document) }
    end
  end

  def test_unknown_builtin_and_mismatched_crud_authorization_are_rejected
    with_app do |_root, compiler|
      document = Vetra::Graph::Data.copy(compiler.build.document)
      command = node(document, 'command', 'blog.update_post')
      command['implementation']['name'] = 'unknown.execute'
      document['digest'] = Vetra::Graph::Canonical.digest(document)
      assert_graph_error('builtin_implementation') { Vetra::Graph::Validator.new.validate!(document) }
      command['implementation']['name'] = 'crud.update'
      command['authorize']['action'] = 'read'
      document['digest'] = Vetra::Graph::Canonical.digest(document)
      assert_graph_error('crud_authorization') { Vetra::Graph::Validator.new.validate!(document) }
    end
  end
end

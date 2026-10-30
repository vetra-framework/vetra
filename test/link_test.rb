require_relative 'test_helper'

class LinkTest < GraphTest
  LOADS = :vetra_test_link_loads
  HOOK = :vetra_test_link_hook

  def with_counted_app
    with_app do |root, compiler|
      edit(root, 'config/app.rb') do |text|
        "::Thread.current[:#{LOADS}] = (::Thread.current[:#{LOADS}] || 0) + 1\n::Thread.current[:#{HOOK}]&.call\n#{text}"
      end
      Thread.current[HOOK] = nil
      compiler.write
      Thread.current[LOADS] = 0
      yield root, compiler
    ensure
      Thread.current[HOOK] = nil
      Thread.current[LOADS] = nil
    end
  end

  def change_artifact(compiler)
    document = Vetra::Graph::Canonical.parse(compiler.artifact.binread)
    yield document
    document['digest'] = Vetra::Graph::Canonical.digest(document)
    compiler.artifact.write(Vetra::Graph::Canonical.dump(document) + "\n")
  end

  def test_examples_link_ruby_blocks_and_inventory_builtin_descriptors_without_exposing_execution
    %w[blog mini_crm].each do |name|
      with_app(name) do |_root, compiler|
        expected = compiler.write
        linked = compiler.link
        assert_equal expected.document, linked.document
        assert_equal expected.bytes, compiler.artifact.binread
        assert_equal expected.implementation_ids, linked.implementation_ids
        assert_empty linked.warnings
        assert_equal 4, linked.builtin_bindings.size
        assert linked.builtin_bindings.all? { |binding| binding['executor'] == 'pending' }
        assert linked.frozen?
        refute linked.respond_to?(:call)
        refute linked.respond_to?(:implementations)
        assert Vetra::Graph::Canonical.dump(linked.bindings)
        assert Ractor.make_shareable(linked.document)
        assert Ractor.make_shareable(linked.bindings)
        assert_raises(FrozenError) { linked.bindings.first['operation']['id'].replace('changed') }
        assert_graph_error('binding_missing') { linked.binding_for('command', 'unknown.operation') }
      end
    end
  end

  def test_parameter_order_is_kept_even_when_ir_uses_is_sorted
    with_app do |_root, compiler|
      compiler.write
      linked = compiler.link
      operation = node(linked.document, 'command', 'blog.publish_post')
      assert_equal %w[blog.clock blog.posts], operation['uses'].map { |reference| reference['id'] }
      binding = linked.binding_for('command', 'blog.publish_post')
      assert_equal %w[input posts clock], binding['parameters']
      assert_equal [1, 2], binding['arguments'].map { |argument| argument['position'] }
      assert_equal %w[posts clock], binding['arguments'].map { |argument| argument['parameter'] }
      assert_equal %w[blog.posts blog.clock], binding['arguments'].map { |argument| argument.dig('capability', 'id') }
      read = linked.binding_for('query', 'blog.find_post')
      assert_equal 'posts', read['arguments'].first['parameter']
      assert_equal 'blog.posts_read', read['arguments'].first.dig('capability', 'id')
    end
    with_app('mini_crm') do |_root, compiler|
      compiler.write
      binding = compiler.link.binding_for('handler', 'crm.notify_sales')
      assert_equal %w[event mailer], binding['parameters']
      assert_equal 'crm.mailer', binding['arguments'].first.dig('capability', 'id')
    end
  end

  def test_declarations_load_once_and_call_bodies_remain_unexecuted
    with_counted_app do |root, compiler|
      edit(root, 'app/domains/blog/find_post.rb') { |text| text.sub('posts.find!(input.post_id)', '::Kernel.raise "call executed"') }
      compiler.write
      Thread.current[LOADS] = 0
      linked = compiler.link
      assert_equal 1, Thread.current[LOADS]
      assert_includes linked.implementation_ids, 'blog.find_post#call'
      assert_graph_error('dsl_context') { Vetra.app(:outside) {} }
    end
  end

  def test_missing_or_noncanonical_artifact_fails_before_registration_and_is_not_rebuilt
    with_counted_app do |_root, compiler|
      original = compiler.artifact.binread
      File.unlink(compiler.artifact)
      assert_graph_error('graph_missing') { compiler.link }
      assert_equal 0, Thread.current[LOADS]
      refute compiler.artifact.exist?
      pretty = JSON.pretty_generate(Vetra::Graph::Canonical.parse(original))
      compiler.artifact.write(pretty)
      assert_graph_error('graph_not_canonical') { compiler.link }
      assert_equal 0, Thread.current[LOADS]
      assert_equal pretty, compiler.artifact.binread
    end
  end

  def test_future_format_unknown_features_and_invalid_json_fail_before_registration
    mutations = [
      ['ir_version', ->(document) { document['ir_version'] = '0.2' }],
      ['ir_feature', ->(document) { document['requires'] << 'vetra.live' }],
      ['schema', ->(document) { document['skip_authorization'] = true }],
      ['reference_missing', ->(document) { node(document, 'command', 'blog.publish_post')['uses'].first['id'] = 'blog.missing' }]
    ]
    with_counted_app do |_root, compiler|
      original = compiler.artifact.binread
      mutations.each do |code, mutation|
        compiler.artifact.write(original)
        change_artifact(compiler) { |document| mutation.call(document) }
        assert_graph_error(code) { compiler.link }
        assert_equal 0, Thread.current[LOADS]
      end
      compiler.artifact.write('{invalid')
      assert_graph_error('invalid_json') { compiler.link }
      assert_equal 0, Thread.current[LOADS]
    end
  end

  def test_artifact_integrity_and_producer_versions_are_checked_before_registration
    with_counted_app do |_root, compiler|
      original = compiler.artifact.binread
      bad = Vetra::Graph::Canonical.parse(original)
      bad['digest'] = 'sha256:' + '0' * 64
      compiler.artifact.write(Vetra::Graph::Canonical.dump(bad) + "\n")
      assert_graph_error('digest_mismatch') { compiler.link }
      assert_equal 0, Thread.current[LOADS]
      { 'version' => '0.1.0-alpha.99', 'ruby_version' => '4.0.0' }.each do |key, value|
        compiler.artifact.write(original)
        change_artifact(compiler) { |document| document['producer'][key] = value }
        assert_graph_error('producer_mismatch') { compiler.link }
        assert_equal 0, Thread.current[LOADS]
      end
    end
  end

  def test_source_changes_additions_and_removals_fail_before_loading_declarations
    %w[helper lock addition removal config].each do |change|
      with_counted_app do |root, compiler|
        write(root, 'lib/helper.rb', '# baseline')
        compiler.write
        original = compiler.artifact.binread
        Thread.current[LOADS] = 0
        case change
        when 'helper' then write(root, 'lib/helper.rb', '# changed')
        when 'lock' then edit(root, 'Gemfile.lock') { |text| "#{text}\n" }
        when 'addition' then write(root, 'lib/new.rb', '# new')
        when 'removal' then File.unlink(File.join(root, 'lib/helper.rb'))
        when 'config' then edit(root, 'config/app.rb') { |text| "#{text}\n" }
        end
        assert_graph_error('inputs_changed') { compiler.link }
        assert_equal 0, Thread.current[LOADS]
        assert_equal original, compiler.artifact.binread
      end
    end
  end

  def test_validly_rehashed_but_forged_model_is_rejected_without_replacing_it
    with_counted_app do |_root, compiler|
      change_artifact(compiler) { |document| node(document, 'policy')['actions'].delete('delete') }
      forged = compiler.artifact.binread
      assert_graph_error('graph_model_mismatch') { compiler.link }
      assert_equal 1, Thread.current[LOADS]
      assert_equal forged, compiler.artifact.binread
    end
  end

  def test_source_changed_during_registration_prevents_publication
    with_counted_app do |root, compiler|
      write(root, 'lib/helper.rb', '# baseline')
      compiler.write
      original = compiler.artifact.binread
      Thread.current[HOOK] = -> { write(root, 'lib/helper.rb', '# changed during registration') }
      assert_graph_error('inputs_changed') { compiler.link }
      assert_equal original, compiler.artifact.binread
    end
  end

  def test_artifact_changed_during_registration_is_not_silently_overwritten
    with_counted_app do |_root, compiler|
      Thread.current[HOOK] = -> { compiler.artifact.write('changed during registration') }
      assert_graph_error('graph_changed') { compiler.link }
      assert_equal 'changed during registration', compiler.artifact.binread
    end
  end

  def test_discardable_cache_has_no_authority_over_linking
    with_counted_app do |root, compiler|
      expected = compiler.artifact.binread
      write(root, '.vetra/cache/implementations.bin', 'not trusted code')
      assert compiler.link
      FileUtils.rm_rf(File.join(root, '.vetra/cache'))
      assert compiler.link
      assert_equal expected, compiler.artifact.binread
    end
  end

  def test_failed_relink_keeps_previously_returned_graph_unchanged
    with_app do |root, compiler|
      original = compiler.write
      linked = compiler.link
      edit(root, 'app/domains/blog/post.rb') { |text| "#{text}\n# new build\n" }
      assert_graph_error('inputs_changed') { compiler.link }
      assert_equal original.document, linked.document
      compiler.write
      replacement = compiler.link
      refute_same linked, replacement
      refute_equal linked.document['digest'], replacement.document['digest']
      assert_equal original.document, linked.document
    end
  end

  def test_dsl_context_is_restored_after_registration_error
    with_counted_app do |root, compiler|
      edit(root, 'config/app.rb') { |text| "::Kernel.raise ::NameError, 'registration error' if ::Thread.current[:vetra_test_link_error]\n#{text}" }
      compiler.write
      previous = Thread.current[:vetra_graph_context]
      sentinel = Object.new
      Thread.current[:vetra_graph_context] = sentinel
      Thread.current[:vetra_test_link_error] = true
      assert_graph_error('dsl_error') { compiler.link }
      assert_same sentinel, Thread.current[:vetra_graph_context]
    ensure
      Thread.current[:vetra_test_link_error] = nil
      Thread.current[:vetra_graph_context] = previous
    end
  end

  def test_artifact_symlinks_cannot_redirect_linking
    with_app do |root, compiler|
      expected = compiler.write.bytes
      copy = File.join(root, 'other.json')
      File.write(copy, expected)
      File.unlink(compiler.artifact)
      File.symlink(copy, compiler.artifact)
      assert_graph_error('graph_missing') { compiler.link }
    end
  end
end

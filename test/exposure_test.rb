require_relative 'test_helper'

class ExposureTest < GraphTest
  def expose(root, declaration, operation = 'publish_post')
    edit(root, "app/domains/blog/#{operation}.rb") do |text|
      text.sub(/\nend\s*\z/, "\n  #{declaration}\nend\n")
    end
  end

  def routes(document, target = 'blog.publish_post')
    document['nodes'].select { |entry| entry['kind'] == 'route' && entry.dig('target', 'id') == target }
  end

  def validate(document)
    document['digest'] = Vetra::Graph::Canonical.digest(document)
    Vetra::Graph::Validator.new.validate!(document)
  end

  def test_four_surfaces_share_one_operation_contract_policy_and_binding_without_execution
    with_app do |root, compiler|
      original = node(compiler.build.document, 'command', 'blog.publish_post')
      expose(root, 'expose cli: :publish_post, job: "posts.publish", idempotency: :required')
      expose(root, 'expose webhook: "POST /webhooks/posts/:post_id/publish", idempotency: :required')
      edit(root, 'app/domains/blog/publish_post.rb') do |text|
        text.sub('posts.lock!(input.post_id)', '(::Kernel.raise "call executado")')
      end
      document = compiler.write.document
      operation = node(document, 'command', 'blog.publish_post')
      assert_equal original.slice('input', 'output', 'authorize', 'uses', 'emits'), operation.slice('input', 'output', 'authorize', 'uses', 'emits')
      declared = routes(document).to_h { |route| [route['surface'], route] }
      assert_equal %w[cli http job webhook], declared.keys.sort
      assert_equal({ 'name' => 'publish_post' }, declared['cli']['config'])
      assert_equal({ 'name' => 'posts.publish' }, declared['job']['config'])
      assert_equal({ 'method' => 'POST', 'path' => '/webhooks/posts/:post_id/publish' }, declared['webhook']['config'])
      assert_equal 'optional', declared['http']['idempotency']
      assert declared.values_at('cli', 'job', 'webhook').all? { |route| route['idempotency'] == 'required' }
      declared.each_value do |route|
        assert_equal({ 'kind' => 'command', 'id' => operation['id'] }, route['target'])
        assert_equal route['target'], route['generated_from']
      end
      linked = compiler.link
      assert_equal document, linked.document
      assert_equal 1, linked.implementation_ids.count('blog.publish_post#call')
      assert_equal 1, linked.bindings.count { |binding| binding.dig('operation', 'id') == operation['id'] }
    end
  end

  def test_query_can_be_exposed_by_cli_with_a_read_only_repository
    with_app do |root, compiler|
      expose(root, 'expose cli: "posts.find"', 'find_post')
      document = compiler.build.document
      route = routes(document, 'blog.find_post').fetch(0)
      assert_equal 'cli', route['surface']
      assert_equal 'query', route.dig('target', 'kind')
      assert_equal 'optional', route['idempotency']
      assert_equal ['blog.posts_read'], node(document, 'query', 'blog.find_post')['uses'].map { |reference| reference['id'] }
    end
  end

  def test_queries_reject_jobs_webhooks_and_post_requests
    [
      ['expose job: "posts.find"', 'route_target'],
      ['expose webhook: "POST /webhooks/find", idempotency: :required', 'webhook_idempotency'],
      ['expose http: "POST /posts/find"', 'route_target']
    ].each do |declaration, code|
      with_app do |root, compiler|
        expose(root, declaration, 'find_post')
        error = assert_graph_error(code) { compiler.build }
        diagnostic = error.diagnostics.find { |item| item.code == code }
        assert_equal 'app/domains/blog/find_post.rb', diagnostic.source['path']
        assert_match %r{\A/nodes/\d+}, diagnostic.pointer
      end
    end
  end

  def test_webhooks_require_explicit_required_idempotency_before_artifact_is_written
    ['', ', idempotency: :optional'].each do |option|
      with_app do |root, compiler|
        expose(root, "expose webhook: \"POST /webhooks/publish\"#{option}")
        assert_graph_error('webhook_idempotency') { compiler.write }
        refute compiler.artifact.exist?
      end
    end
  end

  def test_webhooks_cannot_expose_commands_by_safe_http_methods
    %w[GET HEAD OPTIONS].each do |method|
      with_app do |root, compiler|
        expose(root, "expose webhook: \"#{method} /webhooks/publish\", idempotency: :required")
        assert_graph_error('route_target') { compiler.build }
      end
    end
  end

  def test_webhook_path_parameters_must_exist_in_the_shared_input_contract
    with_app do |root, compiler|
      expose(root, 'expose webhook: "POST /webhooks/:missing", idempotency: :required')
      error = assert_graph_error('field_missing') { compiler.build }
      diagnostic = error.diagnostics.find { |item| item.code == 'field_missing' }
      assert_match %r{/config/path\z}, diagnostic.pointer
      assert_includes diagnostic.message, 'missing'
    end
  end

  def test_named_routes_are_unique_per_surface_even_for_different_operations
    %w[cli job].each do |surface|
      with_app do |root, compiler|
        expose(root, "expose #{surface}: :duplicate")
        expose(root, "expose #{surface}: \"duplicate\"", 'find_post')
        if surface == 'job'
          edit(root, 'app/domains/blog/find_post.rb') { |text| text.sub('query :find_post', 'command :find_post') }
        end
        assert_graph_error('route_collision') { compiler.build }
      end
    end
  end

  def test_repeated_exposure_of_the_same_operation_is_also_a_collision
    with_app do |root, compiler|
      2.times { expose(root, 'expose cli: :duplicate') }
      assert_graph_error('route_collision') { compiler.build }
    end
  end

  def test_cli_and_job_may_use_the_same_name_in_one_exposure_declaration
    with_app do |root, compiler|
      expose(root, 'expose cli: :publish, job: :publish')
      declared = routes(compiler.build.document).reject { |route| route['surface'] == 'http' }
      assert_equal %w[cli job], declared.map { |route| route['surface'] }.sort
      assert declared.all? { |route| route['config'] == { 'name' => 'publish' } && route['idempotency'] == 'optional' }
    end
  end

  def test_http_and_webhook_share_collision_detection_including_head_and_parameters
    ['POST /posts/:post_id/publish', 'POST /posts/:other_id/publish'].each do |http|
      with_app do |root, compiler|
        expose(root, "expose webhook: #{http.inspect}, idempotency: :required")
        assert_graph_error('route_collision') { compiler.build }
      end
    end
    with_app do |root, compiler|
      expose(root, 'expose http: "HEAD /posts/:id"', 'find_post')
      assert_graph_error('route_collision') { compiler.build }
    end
  end

  def test_adding_a_surface_preserves_existing_http_identities
    with_app do |root, compiler|
      expose(root, 'expose http: "POST /posts/:post_id/republish"')
      before = compiler.build.document
      edit(root, 'app/domains/blog/publish_post.rb') do |text|
        text.sub('  expose http:', "  expose cli: :publish\n  expose http:")
      end
      after = compiler.build.document
      assert_equal routes(before), routes(after).select { |route| route['surface'] == 'http' }
      assert_equal %w[blog.publish_post.http_1 blog.publish_post.http_2], routes(before).map { |route| route['id'] }
      report = Vetra::Graph::Diff.new.compare(before, after)
      added = report.data['changes'].select { |change| change['kind'] == 'route' && change['change'] == 'added' }
      assert_equal ['blog.publish_post.cli_1'], added.map { |change| change['id'] }
      assert_includes added.first['categories'], 'surface'
      assert added.first['requires_review']
      assert_equal 'indeterminate', added.first['permission_impact']
    end
  end

  def test_missing_unknown_and_projection_options_name_the_expose_declaration
    [
      ['expose', 'missing_option', 'http'],
      ['expose idempotency: :required', 'missing_option', 'webhook'],
      ['expose ui: { button: "Publicar" }', 'unsupported_option', 'ui'],
      ['expose cli: :publish, fields: [:post_id]', 'unsupported_option', 'fields']
    ].each do |declaration, code, option|
      with_app do |root, compiler|
        expose(root, declaration)
        path = 'app/domains/blog/publish_post.rb'
        line = File.readlines(File.join(root, path)).index { |text| text.strip == declaration } + 1
        error = assert_graph_error(code) { compiler.build }
        diagnostic = error.diagnostics.find { |item| item.code == code }
        assert_equal({ 'path' => path, 'line' => line }, diagnostic.source)
        assert_includes diagnostic.message, 'em expose:'
        assert_includes diagnostic.message, option
      end
    end
  end

  def test_invalid_surface_values_fail_audibly_at_the_expose_line
    [
      'expose cli: ""', 'expose job: "  "', 'expose cli: nil', 'expose job: false',
      'expose cli: 123', 'expose cli: { name: "publish" }', 'expose job: [:publish]',
      'expose http: nil', 'expose webhook: 123', 'expose http: "POST"',
      'expose webhook: "POST", idempotency: :required'
    ].each do |declaration|
      with_app do |root, compiler|
        expose(root, declaration)
        path = 'app/domains/blog/publish_post.rb'
        line = File.readlines(File.join(root, path)).index { |text| text.strip == declaration } + 1
        error = assert_graph_error('route_format') { compiler.build }
        diagnostic = error.diagnostics.find { |item| item.code == 'route_format' }
        assert_equal({ 'path' => path, 'line' => line }, diagnostic.source)
      end
    end
  end

  def test_handlers_cannot_declare_surface_exposures
    with_app('mini_crm') do |root, compiler|
      edit(root, 'app/domains/crm/notify_sales.rb') { |text| text.sub('  on ', "  expose job: :notify_sales\n  on ") }
      assert_graph_error('unsupported_declaration') { compiler.build }
    end
  end

  def test_external_ir_cannot_expose_query_as_job_or_use_a_blank_name
    with_app do |root, compiler|
      expose(root, 'expose cli: :find', 'find_post')
      original = compiler.build.document
      document = Vetra::Graph::Data.copy(original)
      routes(document, 'blog.find_post').first['surface'] = 'job'
      assert_graph_error('route_target') { validate(document) }
      document = Vetra::Graph::Data.copy(original)
      routes(document, 'blog.find_post').first['config']['name'] = '  '
      assert_graph_error('route_format') { validate(document) }
    end
  end
end

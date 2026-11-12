require_relative 'test_helper'
require 'vetra/http'
require 'securerandom'
require 'stringio'

# Adaptador HTTP (K24, ADR-050), sem servidor nem banco: `app.call(env)` direto, com um Runner de mentira para a tradução e a segurança da
# entrada, e com o Runner real e bancos simulados para a leitura de ponta a ponta.
class HttpAppTest < GraphTest
  def self.linked(example)
    (@linked ||= {})[example] ||= Vetra::Graph::Compiler.new(root: File.join(PROJECT, 'examples', example)).link
  end

  Outcome = Vetra::Execution::Runner::Outcome

  # Runner de mentira: guarda o que recebeu e devolve o resultado combinado.
  class FakeRunner
    attr_reader :calls
    attr_accessor :outcome, :serialized

    def initialize(outcome = Outcome.new(status: :ok, value: :registro))
      @outcome = outcome
      @calls = []
      @serialized = { 'id' => 'x' }
    end

    def run(operation, input, credentials: nil, idempotency_key: nil, **)
      @calls << { operation: operation, input: input, credentials: credentials, key: idempotency_key }
      raise 'segredo do banco' if @outcome == :raise
      @outcome
    end

    def serialize(_operation, _value) = @serialized
  end

  def setup
    @blog = self.class.linked('blog')
    @crm = self.class.linked('mini_crm')
    @runner = FakeRunner.new
    @app = Vetra::Http::App.new(linked: @blog, runner: @runner)
    @id = SecureRandom.uuid
  end

  def env(verb, path, body: nil, query: nil, type: 'application/json', headers: {})
    base = { 'REQUEST_METHOD' => verb, 'PATH_INFO' => path, 'QUERY_STRING' => query.to_s, 'rack.input' => StringIO.new(body.to_s) }
    base['CONTENT_TYPE'] = type if body
    base['CONTENT_LENGTH'] = body.bytesize.to_s if body
    base.merge(headers)
  end

  def call(*args, app: @app, **options)
    status, headers, body = app.call(env(*args, **options))
    [status, headers, body.empty? ? nil : JSON.parse(body.join)]
  end

  def error_code(response) = response[2].dig('error', 'code')

  # ---- tradução da entrada ---------------------------------------------------------------------------------------------------

  def test_a_query_route_reads_the_path_and_returns_the_serialized_value
    status, headers, body = call('GET', "/posts/#{@id}")
    assert_equal 200, status
    assert_equal({ 'id' => 'x' }, body)
    assert_equal({ operation: 'blog.read_post', input: { 'id' => @id }, key: nil }, @runner.calls.first.slice(:operation, :input, :key))
    assert_equal 'application/json; charset=utf-8', headers['content-type']
    assert_equal 'no-store', headers['cache-control']
    assert_equal 'nosniff', headers['x-content-type-options']
    assert_equal headers['content-length'].to_i, JSON.generate(body).bytesize
  end

  def test_a_command_reads_path_and_json_body_and_the_caller_never_supplies_identity
    call('POST', "/posts/#{@id}/publish", body: '{}', headers: { 'HTTP_AUTHORIZATION' => 'Bearer t', 'HTTP_COOKIE' => 'sid=1', 'HTTP_X_ACTOR_ID' => 'admin', 'HTTP_X_ROLES' => 'blog.admin' })
    sent = @runner.calls.first
    assert_equal 'blog.publish_post', sent[:operation]
    assert_equal({ 'post_id' => @id }, sent[:input])
    assert_instance_of Vetra::Http::Credentials, sent[:credentials]
    assert_equal ['Bearer t', 'sid=1', {}], [sent[:credentials].authorization, sent[:credentials].cookie, sent[:credentials].headers], 'cabeçalhos de identidade que ninguém configurou não chegam ao resolvedor'
    refute_includes sent[:credentials].inspect, 'Bearer'
  end

  def test_configured_credential_headers_reach_the_resolver_and_nothing_else
    app = Vetra::Http::App.new(linked: @blog, runner: @runner, credential_headers: ['X-Api-Key'])
    call('GET', "/posts/#{@id}", app: app, headers: { 'HTTP_X_API_KEY' => 'k', 'HTTP_X_ACTOR_ID' => 'admin' })
    assert_equal({ 'x-api-key' => 'k' }, @runner.calls.first[:credentials].headers)
  end

  def test_path_and_query_text_follows_the_contract_types_and_a_bad_value_goes_to_the_contract
    crm = Vetra::Http::App.new(linked: @crm, runner: @runner)
    id = SecureRandom.uuid
    call('GET', "/leads/#{id}", app: crm)
    assert_equal({ 'id' => id }, @runner.calls.last[:input])
    status, = call('GET', "/leads/#{id}", query: 'x=1', app: crm)
    assert_equal 200, status, 'a consulta aceita parâmetro de consulta; o contrato é quem recusa o que não conhece'
    assert_equal({ 'x' => '1', 'id' => id }, @runner.calls.last[:input])
  end

  def test_an_integer_and_a_boolean_path_or_query_value_are_typed_by_the_contract
    app = Vetra::Http::App.new(linked: @crm, runner: @runner)
    route = app.instance_variable_get(:@routes).first
    typed = ->(field_type, value) { app.send(:convert, Struct.new(:fields).new({ 'f' => field_type }), 'f', value) }
    assert_equal 42, typed.call('integer', '42')
    assert_equal(-7, typed.call('integer', '-7'))
    assert_equal '4x', typed.call('integer', '4x')
    assert_equal '99999999999999999999', typed.call('integer', '99999999999999999999')
    assert_equal true, typed.call('boolean', 'true')
    assert_equal 'yes', typed.call('boolean', 'yes')
    assert_equal '1.50', typed.call('decimal', '1.50')
    refute_nil route
  end

  # ---- limites e entrada hostil ----------------------------------------------------------------------------------------------

  def test_unknown_route_and_wrong_method
    assert_equal 404, call('GET', '/nada').first
    status, headers, = call('PUT', "/posts/#{@id}")
    assert_equal 405, status
    assert_includes headers['allow'], 'GET'
    assert_equal 404, call('GET', "/posts/#{@id}/extra").first
    assert_empty @runner.calls
  end

  def test_the_body_is_read_with_a_limit_whatever_the_content_length_says
    app = Vetra::Http::App.new(linked: @blog, runner: @runner, max_body: 64)
    big = '{"a":"' + ('x' * 200) + '"}'
    assert_equal 413, call('POST', "/posts/#{@id}/publish", body: big, app: app).first
    lying = env('POST', "/posts/#{@id}/publish", body: big)
    lying['CONTENT_LENGTH'] = '10'
    assert_equal 413, app.call(lying).first, 'o Content-Length mente: a leitura é limitada do mesmo jeito'
    chunked = env('POST', "/posts/#{@id}/publish", body: big)
    chunked.delete('CONTENT_LENGTH')
    assert_equal 413, app.call(chunked).first
    assert_equal 413, call('POST', "/posts/#{@id}/publish", body: '{}', app: app, headers: { 'CONTENT_LENGTH' => '1000' }).first
    assert_equal 400, call('POST', "/posts/#{@id}/publish", body: '{}', headers: { 'CONTENT_LENGTH' => '12abc' }).first
    assert_empty @runner.calls
  end

  def test_json_is_strict_object_only_without_duplicates_nan_or_deep_nesting
    path = "/posts/#{@id}/publish"
    ['{"a":1,"a":2}', '[1]', '"texto"', '{"a":NaN}', '{"a"', "{\"a\":\"\xFF\"}", '{"a":' * 12 + '1' + '}' * 12].each do |bad|
      assert_equal 400, call('POST', path, body: bad).first, bad[0, 30]
    end
    many = '{' + (1..201).map { |index| "\"k#{index}\":1" }.join(',') + '}'
    assert_equal 400, call('POST', path, body: many).first, 'mais campos que o limite'
    assert_equal 415, call('POST', path, body: '{}', type: 'text/plain').first
    assert_equal 415, call('POST', path, body: '{}', type: 'application/x-www-form-urlencoded').first
    assert_equal 200, call('POST', path, body: '{}', type: 'Application/JSON; charset=utf-8').first
    assert_empty @runner.calls.select { |entry| entry[:input].size > 1 }
  end

  def test_the_field_limit_counts_every_level_of_the_body
    app = Vetra::Http::App.new(linked: @blog, runner: @runner, max_fields: 10)
    nested = '{"meta":{' + (1..11).map { |index| "\"k#{index}\":1" }.join(',') + '}}'
    assert_equal 400, call('POST', "/posts/#{@id}/publish", body: nested, app: app).first
    in_list = '{"lista":[' + (1..11).map { |index| "{\"k#{index}\":1}" }.join(',') + ']}'
    assert_equal 400, call('POST', "/posts/#{@id}/publish", body: in_list, app: app).first
    assert_equal 200, call('POST', "/posts/#{@id}/publish", body: '{"a":{"b":1}}', app: app).first
  end

  def test_head_is_served_only_where_the_graph_declares_it_and_without_a_body
    with_app('blog') do |root, compiler|
      edit(root, 'app/domains/blog/find_post.rb') { |text| text.sub(/^(\s*)call do/, "\\1expose http: \"HEAD /find/:post_id\"\n\\1call do") }
      compiler.write
      app = Vetra::Http::App.new(linked: compiler.link, runner: @runner)
      status, headers, body = app.call(env('HEAD', "/find/#{@id}"))
      assert_equal [200, []], [status, body]
      assert_operator headers['content-length'].to_i, :>, 0, 'o content-length é o do GET equivalente'
      assert_equal 'no-store', headers['cache-control']
      assert_equal 405, app.call(env('HEAD', "/posts/#{@id}")).first, 'um GET sem HEAD declarado não responde a HEAD'
      [env('HEAD', "/find/#{@id}", query: 'a=1&a=2'), env('HEAD', '/find/%FF'), env('HEAD', "/find/#{@id}", query: 'a=' + ('x' * 9000)), env('HEAD', '/nada'), env('HEAD', '/find/x/y')].each do |request|
        status, response_headers, response_body = app.call(request)
        assert_operator status, :>=, 400
        assert_equal [], response_body, "HEAD #{request['PATH_INFO']}: nenhuma resposta leva corpo"
        assert_equal 'no-store', response_headers['cache-control']
      end
    end
  end

  def test_path_query_and_body_cannot_conflict_or_mix
    assert_equal 400, call('POST', "/posts/#{@id}/publish", body: %({"post_id":"#{SecureRandom.uuid}"})).first, 'o corpo não redefine um parâmetro do caminho'
    assert_equal 400, call('POST', "/posts/#{@id}/publish", query: 'a=1', body: '{}').first, 'comando não aceita consulta'
    assert_equal 400, call('GET', "/posts/#{@id}", body: '{"a":1}').first, 'consulta não aceita corpo'
    assert_equal 400, call('GET', "/posts/#{@id}", query: 'id=outro').first, 'a consulta não redefine o caminho'
    assert_equal 400, call('GET', "/posts/#{@id}", query: 'a=1&a=2').first
    assert_equal 400, call('GET', "/posts/#{@id}", query: 'a=%FF').first
    assert_equal 414, call('GET', "/posts/#{@id}", query: 'a=' + ('x' * 9000)).first
    assert_equal 400, call('GET', "/posts/#{@id}", query: (1..60).map { |index| "k#{index}=1" }.join('&')).first
    assert_empty @runner.calls
  end

  def test_path_segments_are_decoded_once_and_hostile_ones_are_refused
    assert_equal 400, call('GET', '/posts/%2F').first
    assert_equal 400, call('GET', '/posts/%00').first
    assert_equal 400, call('GET', '/posts/%FF').first
    assert_equal 400, call('GET', '/posts//').first, 'segmento vazio'
    assert_equal 414, call('GET', '/posts/' + ('a' * 3000)).first
    assert_equal 400, call('GET', 'sem-barra').first
    call('GET', '/posts/a%20b')
    assert_equal({ 'id' => 'a b' }, @runner.calls.last[:input], 'decodifica uma vez; o contrato recusa o que não é UUID')
  end

  def test_a_command_without_the_json_media_type_is_refused_even_with_an_empty_body
    path = "/posts/#{@id}/publish"
    session = { 'HTTP_COOKIE' => 'sid=1', 'HTTP_ORIGIN' => 'https://outro-site.example', 'HTTP_SEC_FETCH_SITE' => 'cross-site' }
    assert_equal 415, call('POST', path, headers: session).first, 'POST vazio de outro site, sem Content-Type'
    assert_equal 415, call('POST', path, type: 'text/plain', body: '', headers: session).first
    assert_equal 415, call('POST', path, type: 'application/x-www-form-urlencoded', body: '', headers: session).first
    assert_equal 415, call('POST', path, type: 'multipart/form-data; boundary=x', body: '', headers: session).first
    assert_empty @runner.calls
    assert_equal 200, call('POST', path, type: 'application/json', body: '', headers: session).first, 'com o tipo certo e corpo vazio, o comando segue'
  end

  def test_the_origin_and_fetch_site_reach_the_resolver_so_a_session_resolver_can_refuse_cross_site
    app = Vetra::Http::App.new(linked: @blog, runner: @runner)
    call('POST', "/posts/#{@id}/publish", body: '{}', app: app, headers: { 'HTTP_ORIGIN' => 'https://app.example', 'HTTP_SEC_FETCH_SITE' => 'same-origin' })
    credentials = @runner.calls.last[:credentials]
    assert_equal ['https://app.example', 'same-origin'], [credentials.origin, credentials.fetch_site]
    refute_includes credentials.inspect, 'app.example'
    require 'pp'
    assert_equal '#<Vetra::Http::Credentials [REDACTED]>', PP.pp(credentials, +'').strip, 'nem o pp imprime a credencial'
  end

  def test_the_idempotency_key_header
    path = "/posts/#{@id}/publish"
    call('POST', path, body: '{}', headers: { 'HTTP_IDEMPOTENCY_KEY' => 'chave-1' })
    assert_equal 'chave-1', @runner.calls.last[:key]
    ['com espaço', 'é', 'x' * 300, "a\nb"].each do |bad|
      assert_equal 400, call('POST', path, body: '{}', headers: { 'HTTP_IDEMPOTENCY_KEY' => bad }).first, bad[0, 12]
    end
    call('POST', path, body: '{}')
    assert_nil @runner.calls.last[:key], 'a rota com chave opcional aceita a ausência'
    # Nenhum exemplo declara uma rota HTTP com chave obrigatória (as do mini_crm são do job e do webhook): confere a regra direto.
    required = Struct.new(:idempotency).new('required')
    error = assert_raises(StandardError) { @app.send(:idempotency_key, { 'REQUEST_METHOD' => 'POST' }, required) }
    assert_equal 'idempotency_key_required', error.code
    assert_equal 'k', @app.send(:idempotency_key, { 'HTTP_IDEMPOTENCY_KEY' => 'k' }, required)
  end

  # ---- as saídas ----------------------------------------------------------------------------------------------------------------

  def respond_with(status, **fields)
    @runner.outcome = Outcome.new(status: status, **fields)
    call('GET', "/posts/#{@id}")
  end

  def diagnostic(code, pointer = '/') = Vetra::Graph::Diagnostic.new(code: code, message: 'texto interno com segredo', pointer: pointer, severity: :error)

  def test_every_outcome_has_a_public_status_and_a_fixed_error_code
    assert_equal [401, 'unauthenticated'], respond_with(:unresolved, diagnostics: [diagnostic('execution_identity')]).then { |r| [r[0], error_code(r)] }
    invalid = respond_with(:invalid, diagnostics: [diagnostic('data_value', '/input/title'), diagnostic('data_value', '/input/title'), diagnostic('data_value', 'não é ponteiro')])
    assert_equal [422, 'invalid_input', ['/input/title']], [invalid[0], error_code(invalid), invalid[2].dig('error', 'fields')]
    failed = respond_with(:failed, diagnostics: [diagnostic('execution_failure', '/status')])
    assert_equal [422, 'business_rule', ['/status']], [failed[0], error_code(failed), failed[2].dig('error', 'fields')]
    assert_equal [422, 'idempotency_key_reused'], respond_with(:failed, diagnostics: [diagnostic('data_idempotency_key_reuse')]).then { |r| [r[0], error_code(r)] }
    assert_equal [422, 'rejected'], respond_with(:failed, diagnostics: [diagnostic('data_value')]).then { |r| [r[0], error_code(r)] }
    conflict = respond_with(:conflict, retryable: true, diagnostics: [diagnostic('data_conflict')])
    assert_equal [409, 'conflict', '1'], [conflict[0], error_code(conflict), conflict[1]['retry-after']]
    assert_nil respond_with(:conflict, retryable: false)[1]['retry-after']
    limited = respond_with(:rate_limited, retry_after: 37)
    assert_equal [429, 'rate_limited', '37'], [limited[0], error_code(limited), limited[1]['retry-after']]
    error = respond_with(:error, retryable: true, diagnostics: [diagnostic('execution_unexpected')])
    assert_equal [500, 'internal_error', '1'], [error[0], error_code(error), error[1]['retry-after']]
  end

  def test_a_pointer_only_names_declared_fields_never_a_name_the_client_chose
    invalid = respond_with(:invalid, diagnostics: [diagnostic('data_value', '/input/title'), diagnostic('data_value', '/TOKEN_SECRETO_ABC123'),
                                                  diagnostic('data_value', '/input/TOKEN_SECRETO'), diagnostic('data_value', '/input/items/0/title')])
    assert_equal ['/input/title', '/input/items/0/title'].first(1), invalid[2].dig('error', 'fields').first(1)
    refute_includes JSON.generate(invalid[2]), 'SECRETO'
    failed = respond_with(:failed, diagnostics: [diagnostic('execution_failure', '/TOKEN_SECRETO_ABC123')])
    assert_equal [], failed[2].dig('error', 'fields')
    assert_equal ['/status'], respond_with(:failed, diagnostics: [diagnostic('execution_failure', '/status')])[2].dig('error', 'fields')
  end

  def test_unavailable_facts_are_a_retryable_503_not_a_denial_or_a_missing_record
    %w[data_rate_limit_unavailable data_authorization_snapshot data_connection data_database data_access_denied data_limits data_context_install data_statement_timeout data_lock_timeout data_serialization data_conflict data_timeout].each do |code|
      unavailable = respond_with(:denied, diagnostics: [diagnostic(code)])
      assert_equal [503, 'unavailable', '1'], [unavailable[0], error_code(unavailable), unavailable[1]['retry-after']], code
    end
    %w[data_authorization_denied data_authorization_fields data_authorization_final data_authorization_context data_authorization_system_actor].each do |code|
      assert_equal 404, respond_with(:denied, diagnostics: [diagnostic(code)])[0], "#{code} é uma decisão: 404 numa operação com registro"
    end
    %w[data_authorization_predicate data_context data_execution_operation data_input_fields data_repository].each do |code|
      defect = respond_with(:denied, diagnostics: [diagnostic(code)])
      assert_equal [500, 'internal_error', nil], [defect[0], error_code(defect), defect[1]['retry-after']], "#{code} é um defeito, e não uma negação"
    end
  end

  def test_no_internal_text_reaches_the_response
    [respond_with(:error, diagnostics: [diagnostic('execution_unexpected')]), respond_with(:unresolved, diagnostics: [diagnostic('execution_identity')]),
     respond_with(:invalid, diagnostics: [diagnostic('data_value', '/input/x')])].each do |response|
      refute_includes JSON.generate(response[2]), 'segredo'
      refute_includes JSON.generate(response[2]), 'texto interno'
    end
  end

  def test_a_denied_operation_on_a_referenced_record_looks_like_a_missing_one
    assert_equal 'not_found', error_code(respond_with(:denied, diagnostics: [diagnostic('data_authorization_denied')])), 'read_post aponta um registro: negado e inexistente são iguais'
    denied = respond_with(:denied)
    missing = respond_with(:not_found)
    assert_equal [denied[0], denied[2]], [missing[0], missing[2]]
    create = Vetra::Http::App.new(linked: @blog, runner: @runner)
    @runner.outcome = Outcome.new(status: :denied)
    status, _, body = call('POST', '/posts', body: '{"title":"T"}', app: create)
    assert_equal [403, 'forbidden'], [status, body.dig('error', 'code')], 'criar não aponta um registro: 403'
  end

  def test_a_replay_is_marked_and_a_nil_output_has_no_body
    @runner.outcome = Outcome.new(status: :ok, value: { 'id' => 'guardado' }, replayed: true)
    status, headers, body = call('GET', "/posts/#{@id}")
    assert_equal [200, 'true', { 'id' => 'guardado' }], [status, headers['idempotent-replayed'], body], 'o resultado repetido já é o JSON guardado'
    @runner.outcome = Outcome.new(status: :ok, value: :x)
    @runner.serialized = nil
    status, headers, body = call('GET', "/posts/#{@id}")
    assert_equal [204, nil, false], [status, body, headers.key?('content-type')], 'sem saída declarada, 204 e nenhum corpo'
  end

  def test_an_unexpected_error_of_the_runner_is_a_generic_500_without_text
    @runner.outcome = :raise
    status, _, body = call('GET', "/posts/#{@id}")
    assert_equal [500, 'internal_error'], [status, body.dig('error', 'code')]
    refute_includes JSON.generate(body), 'segredo'
  end

  def test_cors_is_closed_and_every_response_carries_safe_headers
    [call('GET', "/posts/#{@id}"), call('GET', '/nada'), call('POST', "/posts/#{@id}/publish", body: 'lixo')].each do |status, headers, _|
      refute(headers.keys.any? { |name| name.start_with?('access-control') }, "#{status}: nenhum cabeçalho CORS")
      assert_equal 'no-store', headers['cache-control']
      assert_equal 'nosniff', headers['x-content-type-options']
    end
    status, headers, = call('OPTIONS', "/posts/#{@id}")
    assert_equal 405, status
    refute headers.key?('access-control-allow-origin')
  end

  # ---- a montagem ---------------------------------------------------------------------------------------------------------------

  def test_a_route_profile_replaces_only_that_routes_runner
    special = FakeRunner.new(Outcome.new(status: :ok, value: :x))
    app = Vetra::Http::App.new(linked: @blog, runner: @runner, runners: { 'blog.read_post.http' => special })
    call('GET', "/posts/#{@id}", app: app)
    call('POST', "/posts/#{@id}/publish", body: '{}', app: app)
    assert_equal ['blog.read_post'], special.calls.map { |entry| entry[:operation] }
    assert_equal ['blog.publish_post'], @runner.calls.map { |entry| entry[:operation] }
  end

  def test_the_app_refuses_a_bad_setup_and_inspects_without_state
    bad = [{ linked: @blog.document, runner: @runner }, { linked: @blog, runner: Object.new }, { linked: @blog, runner: @runner, runners: { 'x' => Object.new } },
           { linked: @blog, runner: @runner, credential_headers: ['bad header'] }, { linked: @blog, runner: @runner, max_body: 0 },
           { linked: @blog, runner: @runner, desconhecido: 1 }]
    bad.each { |options| assert_equal 'http_app', assert_raises(Vetra::Data::Error) { Vetra::Http::App.new(**options) }.code, options.keys.to_s }
    assert_equal '#<Vetra::Http::App>', @app.inspect
    assert @app.frozen?
  end

  # ---- com o Runner real -----------------------------------------------------------------------------------------------------------

  def real_app(identity)
    linked = @blog
    catalog = Vetra::Data::Repositories.new(linked.document)
    row = { id: @id, title: 'Título', author_id: @actor_id ||= SecureRandom.uuid, status: 'published', published_at: Time.now.utc.floor(6), created_at: Time.now.utc.floor(6) }
    make = -> { Sequel.mock(host: :postgres).tap { |db| db.fetch = ->(sql) { sql.include?('set_config') ? [] : [row] } } }
    authority = Vetra::Execution::InProcessAuthority.new
    facts = Vetra::Execution::DatabaseFacts.new(catalog: catalog, authority: authority, unit: Vetra::Data::UnitOfWork.new(make.call, scope: :global, limits: false))
    resolver = Vetra::Execution::PublicIdentity.new(resolver: ->(credentials) { identity.call(credentials) }, linked: linked)
    edge = Vetra::Execution::Edge.new(identity: resolver, facts: facts, authority: authority)
    runner = Vetra::Execution::Runner.new(linked: linked, catalog: catalog, edge: edge, unit: Vetra::Data::UnitOfWork.new(make.call, scope: :global, limits: false))
    Vetra::Http::App.new(linked: linked, runner: runner)
  end

  def test_end_to_end_with_the_real_runner_a_public_identity_and_mock_databases
    author = ->(credentials) { Vetra::Execution::Identity.new(actor_id: @actor_id ||= SecureRandom.uuid, roles: ['blog.autor']) if credentials.authorization == 'Bearer autor' }
    app = real_app(author)
    status, _, body = call('GET', "/posts/#{@id}", headers: { 'HTTP_AUTHORIZATION' => 'Bearer autor' }, app: app)
    assert_equal [200, 'Título'], [status, body['title']]
    assert_equal %w[author_id created_at id published_at status title], body.keys.sort
    anonymous = call('GET', "/posts/#{@id}", app: app)
    assert_equal [401, 'unauthenticated'], [anonymous[0], error_code(anonymous)], 'sem credencial, o resolvedor devolve nada: 401'
    assert_equal 422, call('GET', '/posts/nao-e-uuid', headers: { 'HTTP_AUTHORIZATION' => 'Bearer autor' }, app: app).first
    forged = call('GET', "/posts/#{@id}", headers: { 'HTTP_X_ACTOR_ID' => @actor_id.to_s, 'HTTP_X_ROLES' => 'blog.admin' }, app: app)
    assert_equal 401, forged[0], 'cabeçalhos de identidade não autenticam ninguém'
  end
end

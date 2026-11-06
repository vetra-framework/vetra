require_relative 'test_helper'
require 'vetra/data'
require 'securerandom'
require 'digest'
require 'open3'
require 'rbconfig'

class DataTest < GraphTest
  def setup
    @secret = SecureRandom.random_bytes(32)
    @now = 1_800_000_000
    @claims = { tenant_id: SecureRandom.uuid, actor_id: SecureRandom.uuid,
                op_id: SecureRandom.uuid, cmd: 'crm.create_lead' }
    @issuer = issuer
    @db = Sequel.mock(host: :postgres)
    @work = Vetra::Data::UnitOfWork.new(@db, issuer: @issuer)
  end

  def issuer(**options)
    Vetra::Data::ContextIssuer.new(kid: 'ephemeral', secret: @secret, clock: -> { @now }, **options)
  end

  def decode(value)
    (value.tr('-_', '+/') + '=' * ((4 - value.length % 4) % 4)).unpack1('m0')
  end

  def payload(token)
    JSON.parse(decode(token.value.split('.')[2]))
  end

  # HMAC por SHA-256 e ipad/opad (RFC 2104), independente do OpenSSL usado pelo emissor.
  # Cada vetor usa chave aleatória em memória; nenhuma chave é fixture versionada.
  def reference_hmac(key, message)
    key = Digest::SHA256.digest(key) if key.bytesize > 64
    bytes = key.ljust(64, "\0").bytes
    inner = bytes.map { |b| b ^ 0x36 }.pack('C*')
    outer = bytes.map { |b| b ^ 0x5c }.pack('C*')
    Digest::SHA256.digest(outer + Digest::SHA256.digest(inner + message))
  end

  def test_token_vectors_match_the_database_algorithm_and_exact_json_bytes
    [32, 100].each do |length|
      @secret = SecureRandom.random_bytes(length)
      token = issuer.issue(**@claims, operator_id: @claims[:actor_id])
      version, kid, encoded, mac = token.value.split('.')
      expected = %({"tenant_id":"#{@claims[:tenant_id]}","actor_id":"#{@claims[:actor_id]}","op_id":"#{@claims[:op_id]}","cmd":"crm.create_lead","iat":1800000000,"exp":1800000030,"operator_id":"#{@claims[:actor_id]}"})
      assert_equal expected, decode(encoded)
      assert_equal 'v1', version
      assert_equal 'ephemeral', kid
      assert_match(/\A[A-Za-z0-9_-]+\z/, encoded)
      assert_match(/\A[A-Za-z0-9_-]{43}\z/, mac)
      assert_equal reference_hmac(@secret, [version, kid, encoded].join('.')), decode(mac)
      assert_operator token.value.bytesize, :<=, 8192
    end
  end

  def test_validity_default_and_boundaries
    assert_equal 30, payload(@issuer.issue(**@claims)).then { |p| p['exp'] - p['iat'] }
    [1, 120].each do |ttl|
      assert_equal ttl, payload(issuer(ttl: ttl).issue(**@claims)).then { |p| p['exp'] - p['iat'] }
    end
    [0, -1, 121, 30.0, '30', nil].each { |ttl| assert_graph_error('data_validity') { issuer(ttl: ttl) } }
    [-1, 1_000_000_000_000, 999_999_999_980, nil, 'oops', 30.5].each do |now|
      @now = now
      assert_graph_error('data_context') { @issuer.issue(**@claims) }
    end
  end

  def test_key_configuration_and_environment
    [nil, '', 'short'].each do |key|
      assert_graph_error('data_key') { Vetra::Data::ContextIssuer.new(kid: 'ephemeral', secret: key) }
    end
    [nil, '', 'bad.kid', 'a' * 65, 'kid'.encode('UTF-16LE')].each do |kid|
      assert_graph_error('data_key') { Vetra::Data::ContextIssuer.new(kid: kid, secret: @secret) }
    end
    [nil, '', 'x' * 64, @secret.unpack1('H*') + '1', 'aa' * 31].each do |hex|
      assert_graph_error('data_key') { Vetra::Data::ContextIssuer.from_env({ 'VETRA_CONTEXT_SECRET_HEX' => hex }) }
    end
    env = { 'VETRA_CONTEXT_KID' => 'ephemeral', 'VETRA_CONTEXT_SECRET_HEX' => @secret.unpack1('H*') }
    from_env = Vetra::Data::ContextIssuer.from_env(env, clock: -> { @now })
    assert_equal @issuer.issue(**@claims).value, from_env.issue(**@claims).value
  end

  def test_claims_are_strict_and_never_echo_invalid_values
    invalid = [{ tenant_id: nil }, { actor_id: nil }, { op_id: 'SENSITIVE' },
               { actor_id: @claims[:actor_id].upcase }, { operator_id: false },
               { actor_id: @claims[:actor_id].encode('UTF-16LE') },
               { cmd: '' }, { cmd: 'a' * 256 }, { cmd: "bad\0value" }, { cmd: "\xFF".b }]
    invalid.each do |changes|
      error = assert_graph_error('data_context') { @issuer.issue(**@claims.merge(changes)) }
      refute_includes error.full_message, 'SENSITIVE'
    end
    assert_equal 'ação.🚀', payload(@issuer.issue(**@claims.merge(cmd: 'ação.🚀')))['cmd']
    assert_equal '🚀' * 255, payload(@issuer.issue(**@claims.merge(cmd: '🚀' * 255)))['cmd']
    refute payload(@issuer.issue(**@claims)).key?('operator_id')
  end

  def test_inspection_and_validation_errors_do_not_expose_secrets
    token = @issuer.issue(**@claims)
    text = [@issuer, token, @work].map { |item| [item.inspect, item.to_s].join }.join
    text += assert_graph_error('data_key') { Vetra::Data::ContextIssuer.new(kid: @secret.unpack1('H*') + '.', secret: @secret) }.full_message
    [@secret, @secret.unpack1('H*'), token.value].each { |value| refute_includes text.b, value.b }
    assert token.frozen?
    assert token.value.frozen?
  end

  def test_outer_transaction_installs_parameterized_context_once_and_composes_savepoints
    assert_equal :result, @work.transaction(**@claims) {
      assert_equal @claims[:tenant_id], @work.context.tenant_id
      refute @work.context.read_only?
      @work.compose { @work.compose { @work.access(multi_tenant: true) { |db| db[:leads].where(name: 'private-name').all } } }
      :result
    }
    sql = @db.sqls
    assert_equal 1, sql.count { |s| s.include?('set_config') }
    assert_equal 2, sql.count { |s| s.start_with?('SAVEPOINT') }
    assert_match(/set_config\(\$1, \$2, true\)/, sql.find { |s| s.include?('set_config') })
    assert_equal 'COMMIT', sql.last
    assert_match(/"name" = \$1/, sql.find { |s| s.include?('leads') })
    assert_empty @db.prepared_statements
  end

  def test_savepoint_exception_can_be_rescued_without_losing_outer_context
    @work.transaction(**@claims) do
      assert_raises(RuntimeError) { @work.compose { raise 'test failure' } }
      assert_equal @claims[:op_id], @work.context.op_id
    end
    sql = @db.sqls
    assert_includes sql, 'ROLLBACK TO SAVEPOINT autopoint_1'
    assert_equal 'COMMIT', sql.last
    assert_equal 1, sql.count { |s| s.include?('set_config') }
  end

  def test_uncaught_exception_and_explicit_rollback_are_not_swallowed
    assert_raises(RuntimeError) { @work.transaction(**@claims) { @work.compose { raise 'test failure' } } }
    assert_equal 'ROLLBACK', @db.sqls.last
    assert_graph_error('data_transaction_required') { @work.context }
    assert_raises(Sequel::Rollback) { @work.transaction(**@claims) { @work.rollback! } }
    assert_equal 'ROLLBACK', @db.sqls.last
    @work.transaction(**@claims) do
      assert_raises(Sequel::Rollback) { @work.compose { @work.rollback! } }
    end
    assert_equal 'COMMIT', @db.sqls.last
  end

  def test_read_only_transaction_and_composition
    @work.read(**@claims) { @work.compose { assert @work.context.read_only? } }
    assert_includes @db.sqls, 'SET TRANSACTION ISOLATION LEVEL READ COMMITTED READ ONLY'
    assert_graph_error('data_context') { @work.transaction(**@claims, read_only: nil) {} }
  end

  def test_repository_guard_refuses_access_without_the_unit_even_in_an_external_begin
    # A C10 envolverá cada execução terminal nesta mesma guarda.
    access = -> { @work.access(multi_tenant: true) { |db| db[:leads].all } }
    assert_graph_error('data_transaction_required', &access)
    assert_empty @db.sqls
    @db.transaction do
      assert_graph_error('data_transaction_required', &access)
      assert_graph_error('data_transaction_nested') { @work.transaction(**@claims) {} }
    end
    refute @db.sqls.any? { |sql| sql.include?('leads') || sql.include?('set_config') }
    assert_graph_error('data_transaction_required') { @work.compose {} }
    assert_graph_error('data_transaction_required') { @work.rollback! }
  end

  def test_nested_entry_and_other_unit_cannot_replace_context
    other = Vetra::Data::UnitOfWork.new(@db, issuer: @issuer)
    @work.transaction(**@claims) do
      assert_graph_error('data_transaction_nested') { @work.read(**@claims.merge(tenant_id: SecureRandom.uuid)) {} }
      assert_graph_error('data_transaction_nested') { other.transaction(**@claims) {} }
      assert_graph_error('data_transaction_required') { other.access(multi_tenant: true) {} }
    end
  end

  def test_context_is_copied_and_state_is_local_to_the_fiber
    tenant = @claims[:tenant_id].dup
    fiber = Fiber.new do
      @work.transaction(**@claims.merge(tenant_id: tenant)) do
        Fiber.yield @work.context
        assert_equal @claims[:tenant_id], @work.context.tenant_id
      end
    end
    context = fiber.resume
    tenant.replace(SecureRandom.uuid)
    assert context.frozen?
    assert context.tenant_id.frozen?
    refute @db.in_transaction?
    assert_equal Fiber.current, Sequel.current
    assert_graph_error('data_transaction_required') { @work.context }
    @work.transaction(**@claims.merge(tenant_id: tenant)) { assert_equal tenant, @work.context.tenant_id }
    fiber.resume
    assert_equal 2, @db.sqls.count { |s| s.include?('set_config') }
  end

  def test_global_authenticated_and_visitor_have_only_ruby_identity
    work = Vetra::Data::UnitOfWork.new(@db, scope: :global)
    [nil, @claims[:actor_id]].each do |actor|
      work.read(op_id: @claims[:op_id], cmd: 'blog.find_post', actor_id: actor) do
        assert_nil work.context.tenant_id
        assert_equal actor, work.context.actor_id unless actor.nil?
        assert_nil work.context.actor_id if actor.nil?
        work.compose { work.access(multi_tenant: false) { |db| db[:posts].all } }
        assert_graph_error('data_scope') { work.access(multi_tenant: true) { flunk 'Não pode executar SQL' } }
      end
    end
    refute @db.sqls.any? { |s| s.include?('set_config') }
    assert_graph_error('data_scope') { work.transaction(**@claims) {} }
    assert_graph_error('data_scope') { Vetra::Data::UnitOfWork.new(@db) }
    assert_graph_error('data_scope') { Vetra::Data::UnitOfWork.new(@db, scope: :invalid) }
    assert_graph_error('data_context') { work.transaction(op_id: 'bad', cmd: 'blog.find_post') {} }
  end

  def test_sensitive_sql_never_reaches_logger_even_on_driver_error
    messages = []
    logger = Object.new
    %i[info error warn debug].each { |level| logger.define_singleton_method(level) { |message| messages << message } }
    @db.loggers << logger
    @work.transaction(**@claims) {}
    refute messages.any? { |message| message.include?('set_config') || message.include?('v1.') }
    assert messages.any? { |message| message.include?('COMMIT') }
    @db.fetch = lambda do |sql|
      if sql.include?('set_config')
        raise Sequel::DatabaseError, "sensitive driver error: #{@issuer.issue(**@claims).value}"
      end
      []
    end
    error = assert_graph_error('data_context_install') { @work.transaction(**@claims) {} }
    assert_nil error.cause
    refute_includes error.full_message, 'sensitive driver'
    refute_includes error.full_message, 'v1.'
    refute messages.any? { |message| message.include?('sensitive driver') || message.include?('v1.') }
    assert_equal 'ROLLBACK', @db.sqls.last
    assert_nil Thread.current[:vetra_data_installing_context]
    assert_graph_error('data_transaction_required') { @work.context }
  end

  def test_no_named_statements_and_wrong_adapter_is_rejected
    assert_graph_error('data_named_statement') { @db[:leads].prepare(:select, :leads) }
    assert_graph_error('data_named_statement') { @db[:leads].call(:select) }
    assert_graph_error('data_connection') { Vetra::Data.configure(Sequel.mock) }
    assert_graph_error('data_connection') { Vetra::Data::UnitOfWork.new(Sequel.mock, scope: :global) }
    assert_graph_error('data_connection') { Vetra::Data.connect('mock://unused') }
  end

  def test_factory_forces_app_role_and_configures_each_new_connection_without_a_real_database
    received = nil
    Sequel.stub(:connect, ->(url, **opts) { received = [url, opts]; @db }) do
      assert_same @db, Vetra::Data.connect('postgres://vetra_migrator:secret@unused/test', max_connections: 1)
    end
    assert @db.is_a?(Vetra::Data::RuntimeDatabase)
    assert_equal 'vetra_app', received.last[:user]
    assert_equal 1, received.last[:max_connections]
    callback = received.last[:after_connect]
    result = Struct.new(:value) { def getvalue(*) = value }
    connection_result = result.new('t')
    connection = Object.new
    connection.define_singleton_method(:exec) { |_sql| connection_result }
    callback.call(connection)
    connection_result.value = 'f'
    assert_graph_error('data_connection') { callback.call(connection) }
    token = @issuer.issue(**@claims)
    Sequel.stub(:connect, ->(*) { raise "#{token.value}: password" }) do
      error = assert_graph_error('data_connection') { Vetra::Data.connect('postgres://unused') }
      assert_nil error.cause
      refute_includes error.full_message, token.value
    end
  end

  def test_runtime_dependencies_load_without_development_and_compiler_stays_independent
    compiler = <<~RUBY
      require 'vetra'
      raise 'Sequel/pg carregado pelo compilador' if defined?(Sequel) || defined?(PG)
      raise 'Conexão carregada' if $LOADED_FEATURES.any? { |f| f.match?(%r{/(?:sequel|pg)(?:/|\.rb)}) }
    RUBY
    runtime = <<~RUBY
      require 'vetra/data'
      require 'pg'
      raise 'Versão inesperada' unless Sequel::VERSION == '5.110.0' && PG::VERSION == '1.7.0'
      raise 'Conectou no require' unless Sequel::DATABASES.empty?
    RUBY
    [compiler, runtime].each do |script|
      out, err, status = Open3.capture3({ 'BUNDLE_WITHOUT' => 'development' }, RbConfig.ruby,
                                      '-I', File.join(PROJECT, 'lib'), '-rbundler/setup', '-e', script)
      assert status.success?, err
      assert_empty out
      assert_empty err
    end
  end
end

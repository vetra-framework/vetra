require_relative 'test_helper'
require 'vetra/data'
require 'securerandom'

class DataLimitsTest < GraphTest
  def setup
    @db = Sequel.mock(host: :postgres)
    @settings = { transaction_timeout: '30s', idle_in_transaction_session_timeout: '10s' }
    @row = { id: SecureRandom.uuid, title: 'Privado', author_id: SecureRandom.uuid, status: 'draft',
             published_at: nil, created_at: Time.now.utc.floor(6) }
    @failure = nil
    @db.fetch = ->(sql) do
      if sql.include?('current_setting')
        [@settings]
      elsif sql.include?('set_config')
        []
      elsif @failure
        raise @failure
      else
        [@row]
      end
    end
    @work = Vetra::Data::UnitOfWork.new(@db, scope: :global)
    @claims = { op_id: SecureRandom.uuid, cmd: 'blog.publish_post', actor_id: @row[:author_id] }
    @catalog = Vetra::Data::Repositories.new(JSON.parse(File.read(File.join(PROJECT, 'examples/blog/.vetra/graph.json'))))
    @posts = @catalog.bind('blog.posts', unit: @work)
  end

  def failure(state, klass = Sequel::DatabaseError)
    wrapped = Struct.new(:state) do
      def result = self
      def error_field(field)
        # O pg só aceita o inteiro PG_DIAG_*; um literal como 'C' lança TypeError num PG::Result real.
        raise 'Campo inesperado' unless field == PG::PG_DIAG_SQLSTATE
        state
      end
    end.new(state)
    klass.new('SQL SELECT segredo, senha e parâmetros').tap { |error| error.wrapped_exception = wrapped }
  end

  def assert_sanitized(error)
    assert_nil error.cause
    refute_includes error.full_message, 'segredo'
    refute_includes error.full_message, 'SELECT'
    refute_includes error.full_message, 'senha'
  end

  def test_default_verifies_both_settings_once_in_each_outer_transaction_never_in_savepoints
    2.times do
      @work.transaction(**@claims) do
        @work.compose { @posts.find!(@row[:id]) }
        @posts.find!(@row[:id])
      end
    end
    sqls = @db.sqls
    reads = sqls.select { |sql| sql.include?('current_setting') }
    assert_equal 2, reads.size
    assert reads.all? { |sql| sql.include?('current_setting($1, true)') && sql.include?('current_setting($2, true)') }
    assert_operator sqls.index(reads.first), :>, sqls.index('BEGIN')
    assert_operator sqls.index(reads.first), :<, sqls.index('SAVEPOINT autopoint_1')
    # Sem argumentos não instala limites por operação; preserva os efetivos da conexão.
    refute sqls.any? { |sql| sql.include?('set_config') }
    assert_includes sqls, 'SET TRANSACTION ISOLATION LEVEL READ COMMITTED READ WRITE'
  end

  def test_settings_missing_zero_over_ceiling_and_malformed_refuse_before_context_and_call
    issuer = Vetra::Data::ContextIssuer.new(kid: 'test', secret: SecureRandom.random_bytes(32))
    work = Vetra::Data::UnitOfWork.new(@db, issuer: issuer)
    %i[transaction_timeout idle_in_transaction_session_timeout].each do |setting|
      original = @settings.fetch(setting)
      [nil, '', '0', '0ms', '0s', '121s', '-1', '30.0s', 'segredo', 30_000].each do |value|
        @settings[setting] = value
        error = assert_graph_error('data_limits') do
          work.transaction(**@claims, tenant_id: SecureRandom.uuid) { flunk 'Não deve abrir o corpo' }
        end
        assert_sanitized(error)
        sqls = @db.sqls
        assert_equal 'ROLLBACK', sqls.last
        refute sqls.any? { |sql| sql.include?('set_config') }
        assert_graph_error('data_transaction_required') { work.context }
      end
      @settings[setting] = original
    end
  end

  def test_settings_accept_postgresql_units_and_configurable_positive_ceilings
    limits = Vetra::Data::Limits.new(transaction_timeout: 120_000, idle_in_transaction_session_timeout: 60_000)
    work = Vetra::Data::UnitOfWork.new(@db, scope: :global, limits: limits)
    [['2min', '1min'], ['120000ms', '60s'], ['1', '1ms']].each do |transaction, idle|
      @settings = { transaction_timeout: transaction, idle_in_transaction_session_timeout: idle }
      assert_equal :ok, work.transaction(**@claims) { :ok }
    end
    @settings[:transaction_timeout] = '1h'
    assert_graph_error('data_limits') { work.transaction(**@claims) {} }
    @settings[:transaction_timeout] = '1d'
    assert_graph_error('data_limits') { work.transaction(**@claims) {} }
    [0, -1, 120_001, 30.0, nil, 'segredo'].each do |value|
      %i[transaction_timeout idle_in_transaction_session_timeout].each do |setting|
        assert_graph_error('data_timeout') { Vetra::Data::Limits.new(**{ setting => value }) }
      end
    end
  end

  def test_verification_can_only_be_disabled_explicitly_and_session_changes_are_not_cached
    @settings[:transaction_timeout] = '0'
    work = Vetra::Data::UnitOfWork.new(@db, scope: :global, limits: false)
    assert_equal :ok, work.transaction(**@claims) { :ok }
    refute @db.sqls.any? { |sql| sql.include?('current_setting') }
    [nil, true, {}, :disabled].each do |value|
      assert_graph_error('data_limits') { Vetra::Data::UnitOfWork.new(@db, scope: :global, limits: value) }
    end
    @settings[:transaction_timeout] = '30s'
    @work.transaction(**@claims) {}
    @settings[:transaction_timeout] = '0'
    assert_graph_error('data_limits') { @work.transaction(**@claims) { flunk 'Cache indevido' } }
  end

  def test_timeouts_are_parameterized_local_and_installed_once_with_the_tenant_context
    issuer = Vetra::Data::ContextIssuer.new(kid: 'test', secret: SecureRandom.random_bytes(32))
    work = Vetra::Data::UnitOfWork.new(@db, issuer: issuer)
    work.transaction(**@claims, tenant_id: SecureRandom.uuid, statement_timeout: 120_000, lock_timeout: 1) do
      work.compose { raise Sequel::Rollback } rescue Sequel::Rollback
      work.compose {}
    end
    sqls = @db.sqls
    settings = sqls.select { |sql| sql.include?('set_config') }
    assert_equal 3, settings.size
    assert settings.all? { |sql| sql.include?('set_config($1, $2, true)') }
    assert_operator sqls.rindex(settings.last), :<, sqls.index('SAVEPOINT autopoint_1')
    assert_equal 'COMMIT', sqls.last
    @work.read(**@claims, statement_timeout: 0, lock_timeout: 0, isolation: :serializable) { @work.compose {} }
    assert_includes @db.sqls, 'SET TRANSACTION ISOLATION LEVEL SERIALIZABLE READ ONLY'
  end

  def test_invalid_timeouts_and_isolation_are_refused_before_begin_without_echoing_input
    [nil, -1, 120_001, 1.5, 'segredo; SELECT', false, Object.new].each do |value|
      %i[statement_timeout lock_timeout].each do |setting|
        error = assert_graph_error('data_timeout') { @work.transaction(**@claims, **{ setting => value }) {} }
        assert_sanitized(error)
        assert_empty @db.sqls
      end
    end
    [nil, :committed, :repeatable, 'SERIALIZABLE', 'segredo'].each do |value|
      error = assert_graph_error('data_isolation') { @work.transaction(**@claims, isolation: value) {} }
      assert_sanitized(error)
      assert_empty @db.sqls
    end
    @work.transaction(**@claims) do
      assert_graph_error('data_transaction_nested') { @work.transaction(**@claims, lock_timeout: 1) {} }
      assert_raises(ArgumentError) { @work.compose(lock_timeout: 1) {} }
    end
  end

  def test_timeout_serialization_and_deadlock_doom_the_whole_unit_even_when_rescued_outside_compose
    [['55P03', Vetra::Data::Conflict, 'data_lock_timeout'], ['57014', Vetra::Data::StatementTimeout, 'data_statement_timeout'],
     ['40001', Vetra::Data::SerializationFailure, 'data_serialization'], ['40P01', Vetra::Data::Conflict, 'data_conflict']].each do |state, type, code|
      @failure = nil
      rescued = nil
      error = assert_graph_error(code) do
        @work.transaction(**@claims, isolation: :serializable) do
          @posts.create!(title: 'Antes da falha')
          begin
            @work.compose do
              @failure = failure(state)
              @posts.lock!(@row[:id])
            end
          rescue type => caught
            rescued = caught
          end
          assert_same rescued, assert_raises(type) { @posts.find!(@row[:id]) }
        end
      end
      assert_same rescued, error
      assert_kind_of type, error
      assert error.retryable?
      assert_sanitized(error)
      sqls = @db.sqls
      assert_includes sqls, 'ROLLBACK TO SAVEPOINT autopoint_1'
      assert_equal 'ROLLBACK', sqls.last
      refute_includes sqls, 'COMMIT'
      assert_equal 1, sqls.count { |sql| sql == 'BEGIN' } # nenhuma repetição nesta camada
      assert_graph_error('data_transaction_required') { @work.context }
    end
  end

  def test_rescued_timeout_followed_by_throw_still_rolls_back
    catch(:exit) do
      @work.transaction(**@claims) do
        @failure = failure('55P03')
        begin
          @work.compose { @posts.lock!(@row[:id]) }
        rescue Vetra::Data::Conflict
          throw :exit
        end
      end
    end
    assert_equal 'ROLLBACK', @db.sqls.last
  end

  def test_commit_failures_are_translated_after_rollback_without_retry_or_driver_cause
    ['55P03', '57014', '40001', '40P01'].each do |state|
      err = failure(state)
      @db.define_singleton_method(:commit_transaction) { |_conn, _opts| raise err }
      calls = 0
      error = assert_raises(Vetra::Data::Error) { @work.transaction(**@claims) { calls += 1 } }
      expected = { '55P03' => 'data_lock_timeout', '57014' => 'data_statement_timeout',
                   '40001' => 'data_serialization', '40P01' => 'data_conflict' }
      assert_equal expected.fetch(state), error.code
      assert_sanitized(error)
      assert_equal 1, calls
      assert_equal 'ROLLBACK', @db.sqls.last
      assert_graph_error('data_transaction_required') { @work.context }
    ensure
      @db.singleton_class.remove_method(:commit_transaction)
    end
  end

  def test_driver_error_in_compose_without_a_repository_also_dooms_the_outer_unit
    caught = nil
    error = assert_graph_error('data_statement_timeout') do
      @work.transaction(**@claims) do
        begin
          @work.compose { raise failure('57014') }
        rescue Vetra::Data::StatementTimeout => timeout
          caught = timeout
        end
      end
    end
    assert_same caught, error
    assert_sanitized(error)
    assert_equal 'ROLLBACK', @db.sqls.last
  end

  def test_other_sql_errors_in_infrastructure_keep_the_existing_propagation_contract
    original = failure('25006')
    error = assert_raises(Sequel::DatabaseError) do
      @work.transaction(**@claims) do
        @work.access(multi_tenant: false) { raise original }
      end
    end
    assert_same original, error
    assert_equal 'ROLLBACK', @db.sqls.last
  end

  def test_opening_limits_context_and_configuration_failures_are_sanitized
    @db.fetch = ->(_sql) { raise failure('57014') }
    error = assert_graph_error('data_statement_timeout') { @work.transaction(**@claims) { flunk } }
    assert_sanitized(error)
    assert_equal 'ROLLBACK', @db.sqls.last
    @db.fetch = ->(sql) { sql.include?('current_setting') ? [@settings] : (raise failure('55P03')) }
    error = assert_graph_error('data_lock_timeout') { @work.transaction(**@claims, lock_timeout: 10) { flunk } }
    assert_sanitized(error)
    issuer = Vetra::Data::ContextIssuer.new(kid: 'test', secret: SecureRandom.random_bytes(32))
    work = Vetra::Data::UnitOfWork.new(@db, issuer: issuer)
    assert_graph_error('data_lock_timeout') { work.transaction(**@claims, tenant_id: SecureRandom.uuid) { flunk } }
  end

  def test_idempotency_and_event_writes_use_the_same_timeout_types_and_total_rollback
    %w[55P03 57014 40001].each do |state|
      [:claim, :complete, :emit].each do |path|
        @failure = nil
        error = assert_raises(Vetra::Data::Error) do
          @work.transaction(**@claims) do |unit|
            if path == :emit
              record = @posts.find!(@row[:id])
              @failure = failure(state)
              @catalog.emit!(unit, record)
            else
              idempotency = Vetra::Data::Idempotency.new(unit)
              if path == :claim
                @failure = failure(state)
                idempotency.claim!(command: 'blog.publish_post', key: 'key', input: {})
              else
                claim = idempotency.claim!(command: 'blog.publish_post', key: 'key', input: {})
                @db.numrows = ->(_sql) { raise failure(state) }
                idempotency.complete!(claim, {})
              end
            end
          end
        end
        assert_equal({ '55P03' => 'data_lock_timeout', '57014' => 'data_statement_timeout', '40001' => 'data_serialization' }.fetch(state), error.code)
        assert error.retryable?
        assert_sanitized(error)
        assert_equal 'ROLLBACK', @db.sqls.last
      ensure
        @db.numrows = 1
      end
    end
  end
end

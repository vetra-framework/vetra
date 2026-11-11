require_relative 'test_helper'
require 'vetra/execution'
require_relative '../script/support/handlers_fixture'

class HandlerRunnerTest < GraphTest
  include HandlersFixture
  HANDLER = Vetra::Execution::HandlerRunner
  Crash = Class.new(Exception)

  # Relay com relógio controlado e fence por lease, para exercitar workers distintos sem esperar um minuto.
  class MemoryRelay
    attr_accessor :now, :crash
    attr_reader :entries, :failures, :reservations

    def initialize(deliveries)
      @now, @entries, @failures, @reservations = 0, deliveries.map { |d| { delivery: d, state: :pending, lease: nil } }, [], []
    end

    def reserve(handler, limit:, lease:)
      @reservations << [limit, lease]
      entry = @entries.find { |e| e[:delivery].handler == handler && e[:state] == :pending && e.fetch(:run_after, 0) <= now && (!e[:lease] || e[:lease] <= now) }
      return [] unless entry
      entry[:lease] = now + lease
      entry[:delivery] = entry[:delivery].with(leased_until: entry[:lease].to_s)
      [entry[:delivery]]
    end

    def complete(delivery)
      raise Crash if crash
      entry = fenced(delivery)
      return false unless entry
      entry[:state] = :done
      true
    end

    def failed(delivery, error, permanent: false, retain_lease: false)
      @failures << [error, permanent, retain_lease]
      entry = fenced(delivery)
      return false unless entry
      entry[:delivery] = delivery.with(attempts: delivery.attempts + 1)
      entry[:lease] = nil unless retain_lease
      entry[:run_after] = now + 0.5
      permanent ? (entry[:state] = :dead) : :retry
    end

    def fenced(delivery)
      @entries.find { |e| e[:delivery] == delivery && e[:state] == :pending }
    end
  end

  class Provider
    attr_reader :keys, :effects
    attr_accessor :failure, :wait
    def initialize
      @keys, @effects = [], {}
    end
    def deliver(_template, **kwargs)
      @keys << kwargs.fetch(:idempotency_key)
      sleep(wait) if wait
      raise failure if failure
      @effects[keys.last] ||= kwargs
    end
  end

  def setup
    @tenant, @lead, @other_tenant = Array.new(3) { SecureRandom.uuid }
    @now = Time.now.utc.floor(6)
    @provider = Provider.new
    @company = { id: @tenant, name: 'Empresa', created_at: @now }
    @row = { id: @lead, company_id: @tenant, name: 'Cliente', email: nil, status: 'won', valor_amount: nil, valor_currency: nil, created_at: @now }
    @records, @inserts, @commits, @writes, @emits = {}, [], 0, 0, 0
  end

  def delivery(handler = 'crm.notify_sales', **changes)
    Vetra::Data::Relay::Delivery.new(handler: handler, event_id: '11111111-1111-1111-1111-111111111111',
      event_created_at: @now.iso8601(6), event_xid8: '12', event_seq: 1, event: 'crm.lead.won', version: 1,
      tenant_id: @tenant, payload: { 'id' => @lead }, attempts: 0, leased_until: nil, **changes)
  end

  # Dois conjuntos de tabelas, com reivindicação, resultado e rollback reais no simulador, por parâmetros do Sequel.
  # O principal e a entrada não são inventados pelo teste: vêm do INSERT produzido pela biblioteca Idempotency.
  def command_runner(linked)
    @db = Sequel.mock(host: :postgres)
    @db.numrows = 1
    params = []
    owner = self
    @db.define_singleton_method(:_execute) do |connection, sql, opts = Sequel::OPTS, &block|
      params = opts[:arguments] || []
      owner.observe(sql, params)
      super(connection, sql, opts, &block)
    end
    @db.fetch = ->(sql) { fetch_table(sql, params) }
    @unit = Vetra::Data::UnitOfWork.new(@db, issuer: Vetra::Data::ContextIssuer.new(kid: 'k', secret: 's' * 32), limits: false)
    edge = Vetra::Execution::Edge.new(identity: ->(c) { c }, facts: ->(_) { raise 'sistema não deve ler fatos' }, authority: ->(_) { 0 })
    @runner = Vetra::Execution::Runner.new(linked: linked, catalog: Vetra::Data::Repositories.new(linked.document), unit: @unit, edge: edge)
  end

  def observe(sql, params)
    if sql.start_with?('BEGIN')
      @snapshot = Marshal.dump([@company, @records, @writes, @emits])
    elsif sql.start_with?('ROLLBACK')
      @company, @records, @writes, @emits = Marshal.load(@snapshot)
    elsif sql.start_with?('COMMIT')
      @commits += 1
      @commit_pause&.call
    elsif sql.start_with?('UPDATE "vetra"."idempotency"')
      row = @records.values.find { |record| record[:id] == params[1] }
      row[:result_text] = params[0]
    elsif sql.start_with?('INSERT INTO "vetra"."outbox"')
      @emits += 1
    end
  end

  def fetch_table(sql, params)
    return [] if sql.include?('set_config')
    case sql
    when /"vetra"\."idempotency"/
      if sql.start_with?('INSERT')
        @inserts << params.dup
        tenant, command, key, origin, principal, hash, handler, event_id, stamp = params
        scope = [tenant, command, key]
        return [] if @records.key?(scope)
        row = { id: @records.size + 1, principal: principal, input_hash: hash, result_text: nil,
                origin: origin, handler: handler, event_id: event_id, event_created_at: stamp }
        @records[scope] = row
        [row.slice(:id)]
      else
        [@records[params.take(3)]].compact
      end
    when /"public"\."leads"/
      # O tenant do WHERE é conferido, como no repositório e no RLS; um ID de outro tenant não aparece.
      params.include?(@row[:company_id]) && params.include?(@row[:id]) ? [@row] : []
    when /"public"\."companies"/
      if sql.start_with?('UPDATE')
        @writes += 1
        @company = @company.merge(name: params.first)
      end
      [@company]
    when /"vetra"\."outbox"/
      [{ seq: @emits, event_id: SecureRandom.uuid, xid8: '20', created_at: @now }]
    else []
    end
  end

  def worker(linked, relay = @relay, **options)
    HANDLER.new(linked: linked, relay: relay, runner: @runner, effects: { 'crm.mailer' => @provider }, **options)
  end

  def test_two_handlers_call_the_same_command_with_distinct_event_keys_and_the_provider_gets_the_same_key
    with_handlers_fixture do |linked|
      command_runner(linked)
      @relay = MemoryRelay.new([delivery, delivery('crm.notify_again')])
      %w[crm.notify_sales crm.notify_again].each do |handler|
        assert_equal 1, worker(linked).work(handler)[:done]
      end
      assert_equal [2, 2, 2], [@writes, @emits, @records.size]
      assert_equal 2, @inserts.map { |params| params[2] }.uniq.size
      assert_equal @inserts.map { |params| params[2] }, @provider.keys
      @records.each_value do |record|
        assert_equal 'event', record[:origin]
        assert_equal "system:#{record[:handler]}", record[:principal]
        assert_equal delivery.event_id, record[:event_id]
        assert_equal @now, Time.iso8601(record[:event_created_at])
      end
      assert_equal [[1, 60]], @relay.reservations.uniq
      assert_includes @db.sqls.join, 'CAST($9 AS timestamptz)'
    end
  end

  def test_crash_after_command_commit_before_complete_replays_without_another_write_or_event
    with_handlers_fixture do |linked|
      command_runner(linked)
      @relay = MemoryRelay.new([delivery])
      @relay.crash = true
      assert_raises(Crash) { worker(linked).work('crm.notify_sales') }
      assert_equal [1, 1, 1], [@commits, @writes, @emits]
      @relay.crash = false
      assert_equal 0, worker(linked).work('crm.notify_sales')[:done], 'lease ainda pertence ao worker que caiu'
      @relay.now = 61
      assert_equal 1, worker(linked).work('crm.notify_sales')[:done]
      assert_equal [2, 1, 1], [@commits, @writes, @emits]
      assert_equal 2, @provider.keys.size
      assert_equal 1, @provider.keys.uniq.size
      assert_equal 1, @provider.effects.size
      refute @db.in_transaction?
    end
  end

  def test_repeated_calls_to_the_same_command_and_effect_have_stable_occurrence_keys
    body = '2.times { call_command :touch_lead, { lead_id: event.id }; mailer.deliver :lead_won, lead_id: event.id }'
    with_handlers_fixture(body: body) do |linked|
      command_runner(linked)
      @relay = MemoryRelay.new([delivery, delivery])
      assert_equal 2, worker(linked).work('crm.notify_sales')[:done]
      assert_equal [2, 2, 2], [@writes, @emits, @records.size]
      assert_equal @inserts.map { |params| params[2] }, @provider.keys
      assert_equal @provider.keys.take(2), @provider.keys.drop(2)
      assert @provider.keys[1].end_with?(':2')
      assert Vetra::Data::Idempotency::KEY.match?(HANDLER.event_key('h' * 128, delivery.event_id))
    end
  end

  def test_command_outside_calls_is_permanently_refused_before_any_command_transaction
    with_handlers_fixture(body: 'call_command :win_lead, { lead_id: event.id }') do |linked|
      command_runner(linked)
      @relay = MemoryRelay.new([delivery])
      assert_equal 1, worker(linked).work('crm.notify_sales')[:dead]
      assert_equal 'data_authorization_system_actor', @relay.failures.first.first.code
      assert_empty @db.sqls
    end
  end

  def test_a_personal_output_is_a_permanent_failure_without_opening_the_command_unit
    with_handlers_fixture(body: 'call_command :touch_lead, { lead_id: event.id }') do |_, root|
      edit(root, 'app/domains/crm/notify_sales.rb') { |s| s.gsub('touch_lead', 'win_lead') }
      compiler = Vetra::Graph::Compiler.new(root: root)
      compiler.write
      linked = compiler.link
      command_runner(linked)
      @relay = MemoryRelay.new([delivery])
      assert_equal 1, worker(linked).work('crm.notify_sales')[:dead]
      assert_equal 'execution_idempotency_personal', @relay.failures.first.first.outcome.code
      assert_empty @db.sqls
    end
  end

  def test_permanent_and_retryable_failures_and_a_handler_with_empty_calls
    linked = Vetra::Graph::Compiler.new(root: File.join(PROJECT, 'examples/mini_crm')).link
    command_runner(linked)
    [RuntimeError.new('segredo'), Vetra::Data::Relay::PermanentFailure.new('segredo')].each do |error|
      @provider.failure = error
      @relay = MemoryRelay.new([delivery])
      result = worker(linked).work('crm.notify_sales')
      assert_equal 1, result[error.is_a?(Vetra::Data::Relay::PermanentFailure) ? :dead : :retry]
      assert_empty @db.sqls, 'calls vazio não impede o efeito e não abre unidade'
    end
    @provider.failure = nil
    @relay = MemoryRelay.new([delivery])
    assert_equal 1, worker(linked).work('crm.notify_sales')[:done]
  end

  def test_total_timeout_rolls_back_an_open_command_and_another_worker_recovers_after_the_lease
    with_handlers_fixture(command_body: '$c14_pause&.call') do |linked|
      command_runner(linked)
      $c14_pause = -> { sleep 0.15 }
      @relay = MemoryRelay.new([delivery])
      assert_equal 1, worker(linked, timeout: 0.02, lease: 1).work('crm.notify_sales')[:retry]
      assert_kind_of Vetra::Execution::HandlerTimeout, @relay.failures.first.first
      assert_equal [false, true], @relay.failures.first.drop(1)
      assert_equal [0, 0, 0], [@writes, @emits, @records.size], 'rollback desfaz escrita e claim'
      refute @db.in_transaction?
      assert_includes @db.sqls, 'ROLLBACK'
      assert_equal 0, worker(linked).work('crm.notify_sales')[:done]
      @relay.now = 2
      assert_equal 1, worker(linked, timeout: 1, lease: 2).work('crm.notify_sales')[:done]
      assert_equal [1, 1, 1], [@writes, @emits, @records.size]
    end
  ensure
    $c14_pause = nil
  end

  def test_total_timeout_also_covers_a_handler_without_commands_and_the_worker_continues
    linked = Vetra::Graph::Compiler.new(root: File.join(PROJECT, 'examples/mini_crm')).link
    command_runner(linked)
    @provider.wait = 0.1
    @relay = MemoryRelay.new([delivery, delivery(event_id: SecureRandom.uuid)])
    result = worker(linked, timeout: 0.01, lease: 1).work('crm.notify_sales')
    assert_equal 2, result[:retry]
    assert_empty @db.sqls
  end

  def test_a_timeout_during_commit_waits_for_transaction_cleanup_and_the_next_worker_replays
    with_handlers_fixture do |linked|
      command_runner(linked)
      @commit_pause = -> { sleep 0.1 }
      @relay = MemoryRelay.new([delivery])
      assert_equal 1, worker(linked, timeout: 0.02, lease: 1).work('crm.notify_sales')[:retry]
      assert_equal [1, 1, 1], [@commits, @writes, @emits], 'o commit em curso termina antes de propagar o timeout'
      refute @db.in_transaction?
      @commit_pause = nil
      @relay.now = 2
      assert_equal 1, worker(linked).work('crm.notify_sales')[:done]
      assert_equal [2, 1, 1], [@commits, @writes, @emits]
    end
  end

  def test_event_tenant_is_the_only_identity_and_cannot_reach_another_tenant
    with_handlers_fixture do |linked|
      command_runner(linked)
      @row[:company_id] = @other_tenant
      @relay = MemoryRelay.new([delivery])
      assert_equal 1, worker(linked).work('crm.notify_sales')[:dead]
      assert_equal :not_found, @relay.failures.first.first.outcome.status
      assert_equal 0, @writes
      assert_empty @records
      assert_equal @tenant, @inserts.first.first
      assert_includes @db.sqls.join, '"company_id" = $1'
    end
  end

  def test_origin_validation_preserves_adapter_contract_and_refuses_incoherent_event_metadata
    with_handlers_fixture do |linked|
      command_runner(linked)
      identity = Vetra::Execution::Identity.new(tenant_id: @tenant, system_actor: 'crm.notify_sales')
      event = { handler: 'crm.notify_sales', event_id: delivery.event_id, event_created_at: @now }
      [{ idempotency_origin: :unknown }, { idempotency_event: event }, { idempotency_origin: :event },
       { idempotency_origin: :event, idempotency_event: event.merge(handler: 'crm.notify_again') }].each do |options|
        outcome = @runner.run('crm.touch_lead', { lead_id: @lead }, credentials: identity, idempotency_key: 'k', **options)
        assert_equal [:invalid, 'execution_idempotency_origin'], [outcome.status, outcome.code]
      end
      assert_empty @db.sqls
      assert @runner.run!('crm.touch_lead', { lead_id: @lead }, credentials: identity, idempotency_key: 'adapter').ok?
      assert_equal 'adapter', @records.values.first[:origin]
      global = Vetra::Graph::Compiler.new(root: File.join(PROJECT, 'examples/chat')).link
      command_runner(global)
      outcome = @runner.run('chat.create_room', { name: 'Sala' }, credentials: Vetra::Execution::Identity.new,
                           idempotency_key: 'k', idempotency_origin: :event, idempotency_event: event)
      assert_equal 'execution_idempotency_origin', outcome.code
    end
  end

  def test_load_and_delivery_refusals_and_timeout_configuration_have_diagnostics
    linked = Vetra::Graph::Compiler.new(root: File.join(PROJECT, 'examples/blog')).link
    assert_graph_error('execution_handler') { worker(linked) }
    with_handlers_fixture do |linked|
      command_runner(linked)
      assert_graph_error('execution_handler_timeout') { worker(linked, timeout: 31) }
      assert_graph_error('execution_handler_capability') { HANDLER.new(linked: linked, relay: nil, runner: @runner) }
      @relay = MemoryRelay.new([delivery(version: 9)])
      assert_equal 1, worker(linked).work('crm.notify_sales')[:dead]
      assert_equal 'execution_handler_delivery', @relay.failures.first.first.code
      assert_graph_error('data_relay_handler') { worker(linked).work('crm.missing') }
      assert_graph_error('data_relay_limit') { worker(linked).work('crm.notify_sales', limit: 0) }
      assert_empty @db.sqls
    end
  end

  def test_timeout_failure_preserves_the_real_relay_lease_and_purge_retains_event_keys_including_dead
    document = Vetra::Graph::Compiler.new(root: File.join(PROJECT, 'examples/mini_crm')).link.document
    db = Sequel.mock(host: :postgres)
    relay = Vetra::Data::Relay.new(db, document: document)
    db.fetch = [{ v: 1 }]
    assert_equal :retry, relay.failed(delivery.with(leased_until: @now.iso8601), Vetra::Execution::HandlerTimeout.new, retain_lease: true)
    assert_includes db.sqls.join, 'leased_until = leased_until'
    # Exige os dois anti-joins e a chave da entrega; não há filtro por estado que deixaria de proteger done/dead.
    db.fetch = ->(sql) { sql.include?('AS cutoff') ? [{ cutoff: @now.iso8601 }] : [] }
    assert_equal({ 'adapter' => 0, 'event' => 0 }, relay.purge_idempotency)
    purge = db.sqls.find { |sql| sql.include?('NOT EXISTS') }
    assert_includes purge, 'vetra.deliveries d WHERE d.handler = i.handler AND d.event_id = i.event_id'
    assert_includes purge, 'd.event_created_at = i.event_created_at'
    assert_includes purge, 'vetra.dead_deliveries x WHERE x.handler = i.handler AND x.event_id = i.event_id'
    refute_includes purge, 'state ='
  end

  def test_the_derived_key_survives_pending_done_and_the_dead_copy_until_the_delivery_disappears
    with_handlers_fixture do |linked|
      command_runner(linked)
      @relay = MemoryRelay.new([delivery])
      @relay.crash = true
      assert_raises(Crash) { worker(linked).work('crm.notify_sales') }
      assert_equal 1, @records.size
      dead_copy = []
      db = Sequel.mock(host: :postgres)
      db.fetch = lambda do |sql|
        next [{ cutoff: (@now + 2 * 86400).iso8601 }] if sql.include?('AS cutoff')
        next [] unless sql.include?('NOT EXISTS')
        # O banco simulado responde à purga por metadados, sem conhecer a chave derivada. Todas as chaves já
        # passaram do prazo mínimo. O contrato SQL dos anti-joins, inclusive sem filtro de estado, é exigido acima.
        doomed = @records.select do |_, row|
          @relay.entries.none? do |entry|
            d = entry[:delivery]
            row[:handler] == d.handler && row[:event_id] == d.event_id &&
              Time.iso8601(row[:event_created_at]) == HANDLER.event_time(d.event_created_at)
          end && dead_copy.none? { |d| row[:handler] == d.handler && row[:event_id] == d.event_id }
        end
        doomed.each_key { |key| @records.delete(key) }
        doomed.values.map { { v: 1 } }
      end
      purger = Vetra::Data::Relay.new(db, document: linked.document)
      %i[pending done dead].each do |state|
        @relay.entries.first[:state] = state
        assert_equal 0, purger.purge_idempotency.fetch('event'), state.to_s
        assert_equal 1, @records.size
      end
      dead_copy << @relay.entries.first[:delivery]
      @relay.entries.clear
      assert_equal 0, purger.purge_idempotency.fetch('event'), 'a cópia dead também protege depois de descartar a partição'
      dead_copy.clear
      assert_equal 1, purger.purge_idempotency.fetch('event')
      assert_empty @records
    end
  end
end

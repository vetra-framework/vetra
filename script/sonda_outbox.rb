#!/usr/bin/env ruby
# PostgreSQL 17/18 descartável, bootstrap ADR-036 pronto; DATABASE_URL administrativa.
# VETRA_APP_PASSWORD: senha do login real vetra_app, se necessária.
# Aplica o 0001 e o 0002 de cada exemplo com eventos como vetra_migrator, com dados entre os dois, e grava
# eventos pela unidade de trabalho como vetra_app (ADR-040). Não altera papéis, CI ou artefatos.
require_relative 'sonda_repositorios'

class OutboxProbe < RepositoriesProbe
  EXAMPLES = %w[mini_crm mini_crm_revendas blog].freeze
  TABLES = Vetra::SQL::Outbox::TABLES

  def run
    @admin = PG.connect(@url)
    @admin.exec('SET client_min_messages = warning')
    @admin.exec(Vetra::SQL::Context.role_guard)
    before = roles
    EXAMPLES.each do |example|
      @example = example
      prepare_incremental(example)
      @catalog = Vetra::Data::Repositories.new(@linked.document)
      open_runtime
      if tenant?
        provision('runtime', @secret)
        issuer = Vetra::Data::ContextIssuer.new(kid: 'runtime', secret: @secret)
        @work = Vetra::Data::UnitOfWork.new(@runtime, issuer: issuer)
        @tenants, @actors = [@tenant, SecureRandom.uuid], [@actor, SecureRandom.uuid]
      else
        @work = Vetra::Data::UnitOfWork.new(@runtime, scope: :global)
      end
      emission_checks
      denial_checks
      check_case('nenhum statement nomeado e conexão devolvida sem contexto') do
        @runtime[:pg_prepared_statements].count.zero? && empty_context?
      end
      close_runtime
    end
    check('nenhum papel global mudou') { roles == before }
    puts "#{@results.count(true)}/#{@results.size} verificações passaram (PostgreSQL #{@admin.server_version})."
    @results.all?
  ensure
    close_runtime
    @listener&.close
    if @admin
      @databases.reverse_each { |name| @admin.exec("DROP DATABASE IF EXISTS #{PG::Connection.quote_ident(name)} WITH (FORCE)") }
      @admin.close
    end
  end

  private

  def tenant?
    @example.start_with?('mini_crm')
  end

  # O 0001 entra primeiro; uma linha da raiz (ou um post) é gravada antes do 0002, que cria a outbox sobre dados.
  def prepare_incremental(example)
    root = File.expand_path("../examples/#{example}", __dir__)
    @linked = Vetra::Graph::Compiler.new(root: root).link
    plans = Vetra::SQL::Planner.new(root: root).migration_plans
    @connection = create_database
    @database_name = @databases.last
    check_case('0001 aplica, recebe dados e o 0002 cria a outbox sem perder linhas') do
      @plans = plans.first(1)
      apply_as_migrator(@connection)
      table = tenant? ? 'public.companies' : 'public.posts'
      seed = tenant? ? "INSERT INTO public.companies (id, name, created_at) VALUES ('#{SecureRandom.uuid}', 'Antiga', now())" :
                       "INSERT INTO public.posts (author_id, title, created_at) VALUES ('#{SecureRandom.uuid}', 'Antigo', now())"
      @connection.exec(seed)
      @plans = plans.drop(1)
      apply_as_migrator(@connection)
      @plans = plans
      plans.map(&:file_name) == %w[0001_inicial.sql 0002_expand.sql] &&
        @connection.exec("SELECT count(*) FROM #{table}").getvalue(0, 0) == '1'
    end
    check_case('outbox e entregas particionadas com DEFAULT, entregas mortas fora da partição, todas com RLS forçado') do
      rows = @connection.exec(<<~SQL).to_a
        SELECT c.relname, c.relkind, c.relispartition, c.relrowsecurity, c.relforcerowsecurity,
               pg_get_userbyid(c.relowner) AS owner, pg_get_expr(c.relpartbound, c.oid) AS bound,
               (SELECT p.relname FROM pg_inherits i JOIN pg_class p ON p.oid = i.inhparent WHERE i.inhrelid = c.oid) AS parent
          FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
         WHERE n.nspname = 'vetra' AND c.relname IN (#{TABLES.map { |name| "'#{name}'" }.join(', ')})
         ORDER BY c.relname
      SQL
      shape = rows.to_h { |row| [row['relname'], row.values_at('relkind', 'relispartition', 'bound', 'parent')] }
      shape == { 'dead_deliveries' => ['r', 'f', nil, nil], 'deliveries' => ['p', 'f', nil, nil],
                 'deliveries_default' => ['r', 't', 'DEFAULT', 'deliveries'], 'outbox' => ['p', 'f', nil, nil],
                 'outbox_default' => ['r', 't', 'DEFAULT', 'outbox'] } &&
        rows.all? { |row| row.values_at('relrowsecurity', 'relforcerowsecurity', 'owner') == %w[t t vetra_owner] }
    end
  end

  def outbox_rows
    @connection.exec(<<~SQL).to_a
      SELECT tableoid::regclass::text AS partition, xid8::text, seq, event_id::text, event, version, tenant_id::text,
             actor_id::text, op_id::text, cmd, payload::text
        FROM vetra.outbox ORDER BY xid8, seq
    SQL
  end

  # Executa o corpo call real do comando, grava os eventos dele na mesma unidade e devolve o xid8 da transação.
  def command_with_events(id, attributes, rollback: false)
    binding = @linked.binding_for('command', id)
    input = ::Data.define(*attributes.keys).new(**attributes)
    xid = nil
    ids = within(id) do |unit|
      arguments = binding['arguments'].map do |argument|
        capability = argument.dig('capability', 'id')
        capability.end_with?('.clock') ? OperationClock.new(now: unit.now) : repository(capability, unit)
      end
      implementation = @linked.instance_variable_get(:@implementations).fetch(binding['ref'])
      record = CallHost.new.instance_exec(input, *arguments, &implementation)
      xid = unit.access(multi_tenant: tenant?) { |db| db.get(Sequel.function(:pg_current_xact_id)).to_s }
      emitted = @catalog.emit!(unit, record)
      unit.rollback! if rollback
      emitted
    end
    [ids, xid]
  end

  def listen
    @listener&.close
    @listener = PG.connect(connection_params(@database_name))
    @listener.exec('LISTEN vetra_outbox')
  end

  def notification
    received = nil
    # O pg devolve nil para um payload vazio.
    @listener.wait_for_notify(3) { |channel, _pid, payload| received = [channel, payload.to_s] }
    received
  end

  def prepare_records
    if tenant?
      within('crm.create_lead') do
        repository('crm.companies').create!(name: 'Empresa da sonda')
        repository('crm.users').create!(id: @actor, name: 'Vendedor', email: 'actor@probe.invalid') if revendas?
      end
      @dealer = seed_dealer(@tenant) if revendas?
      @leads = Array.new(3) do
        within('crm.create_lead') do
          attributes = { name: 'Lead da sonda' }
          if revendas?
            repository('crm.memberships').create!(user_id: @actor, dealer_id: @dealer, role: 'vendedor') unless @membership
            @membership = true
            attributes.merge!(dealer_id: @dealer, seller_id: @actor)
          end
          repository('crm.leads').create!(**attributes)
        end
      end
    else
      @posts = Array.new(3) { within('blog.create_post') { repository('blog.posts').create!(title: 'Post da sonda') } }
    end
  end

  def emit_one(index, rollback: false)
    if tenant?
      command_with_events('crm.win_lead', { lead_id: @leads[index].id }, rollback: rollback)
    else
      command_with_events('blog.publish_post', { post_id: @posts[index].id }, rollback: rollback)
    end
  end

  def emission_checks
    prepare_records
    listen
    first = nil
    check_case('comando real grava o evento na DEFAULT com xid8 da transação e o payload projetado') do
      ids, xid = emit_one(0)
      rows = outbox_rows
      first = rows.first
      record = tenant? ? @leads[0] : @posts[0]
      payload = { 'id' => record.id }
      payload['seller_id'] = @actor if revendas?
      expected = { 'partition' => 'vetra.outbox_default', 'xid8' => xid, 'event_id' => ids.first,
                   'event' => tenant? ? 'crm.lead.won' : 'blog.post.published', 'version' => '1',
                   'tenant_id' => tenant? ? @tenant : nil, 'actor_id' => @actor,
                   'cmd' => tenant? ? 'crm.win_lead' : 'blog.publish_post' }
      rows.size == 1 && ids.size == 1 && expected.all? { |key, value| first[key] == value } &&
        JSON.parse(first['payload']) == payload && first['op_id'].match?(Vetra::Data::Context::UUID)
    end
    check_case('a notificação só carrega o tenant, depois do commit') do
      notification == ['vetra_outbox', tenant? ? @tenant : '']
    end
    check_case('rollback depois da emissão não deixa evento nem notificação') do
      begin
        emit_one(1, rollback: true)
      rescue Sequel::Rollback
        nil
      end
      outbox_rows.size == 1 && notification.nil?
    end
    check_case('eventos seguintes têm xid8 e seq crescentes') do
      emit_one(2)
      rows = outbox_rows
      rows.size == 2 && rows.last['seq'].to_i > first['seq'].to_i &&
        @connection.exec_params('SELECT $1::xid8 > $2::xid8', [rows.last['xid8'], first['xid8']]).getvalue(0, 0) == 't'
    end
    personal_check if tenant?
  end

  # O email do lead é pessoal; projetá-lo no lead.won é aceito pela IR, mas não pela outbox sem a cifra do ADR-013.
  def personal_check
    check_case('payload com campo pessoal desfaz a unidade inteira, mesmo com o erro resgatado') do
      document = Vetra::Graph::Data.copy(@linked.document)
      nodes = document['nodes']
      email = nodes.find { |node| node['id'] == 'crm.lead' }['fields'].find { |item| item['name'] == 'email' }
      nodes.find { |node| node['id'] == 'crm.lead.won.payload' }['fields'] << email
      nodes.find { |node| node['id'] == 'crm.win_lead' }['emits'].first['fields'] << 'email'
      document['digest'] = Vetra::Graph::Canonical.digest(document)
      catalog = Vetra::Data::Repositories.new(document)
      before = outbox_rows.size
      refused = data_error('data_event_personal') do
        within('crm.win_lead') do |unit|
          begin
            catalog.emit!(unit, catalog.record_type('crm.lead').new(**@leads[1].to_h))
          rescue Vetra::Data::Error
            :resgatado
          end
        end
      end
      refused && outbox_rows.size == before
    end
  end

  def denial_checks
    tenant = tenant? ? "'#{@tenant}'" : 'NULL'
    columns = 'event_id, event, version, tenant_id, actor_id, op_id, cmd, payload'
    values = "gen_random_uuid(), 'sonda.evento', 1, #{tenant}, '#{@actor}', gen_random_uuid(), 'sonda', '{}'"
    check_case('a aplicação grava pela política: o próprio tenant entra, outro tenant e outro ator não') do
      allowed = within(tenant? ? 'crm.win_lead' : 'blog.publish_post') do |unit|
        unit.access(multi_tenant: tenant?) { |db| db.run("INSERT INTO vetra.outbox (#{columns}) VALUES (#{values})") }
        true
      end
      other = tenant? ? "'#{SecureRandom.uuid}'" : "'#{SecureRandom.uuid}'"
      foreign = denied_app("INSERT INTO vetra.outbox (#{columns}) VALUES (#{values.sub(tenant, other)})")
      actor = !tenant? || denied_app("INSERT INTO vetra.outbox (#{columns}) VALUES (#{values.sub("'#{@actor}'", "'#{SecureRandom.uuid}'")})")
      allowed && foreign && actor
    end
    check_case('a aplicação não define created_at, xid8 nem seq') do
      # seq é GENERATED ALWAYS: o reescritor recusa (428C9) antes da conferência de privilégio por coluna (42501).
      { 'created_at' => ['now()', '42501'], 'xid8' => ["'1'", '42501'], 'seq' => ['1', '428C9'] }.all? do |column, (value, state)|
        denied_app("INSERT INTO vetra.outbox (#{column}, #{columns}) VALUES (#{value}, #{values})", state)
      end
    end
    check_case('a aplicação não lê, altera, remove nem esvazia a outbox') do
      ['SELECT 1 FROM vetra.outbox', "UPDATE vetra.outbox SET cmd = 'x'", 'DELETE FROM vetra.outbox',
       'TRUNCATE vetra.outbox'].all? { |sql| denied_app(sql) }
    end
    check_case('a aplicação não alcança as partições, as entregas nem as entregas mortas') do
      (TABLES - ['outbox']).all? { |name| denied_app("SELECT 1 FROM vetra.#{name}") } &&
        denied_app("INSERT INTO vetra.outbox_default (#{columns}) VALUES (#{values})")
    end
  end

  def denied_app(sql, state = '42501')
    sqlstate(state) do
      within(tenant? ? 'crm.win_lead' : 'blog.publish_post') do |unit|
        unit.access(multi_tenant: tenant?) { |db| db.run(sql) }
      end
    end
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    exit(OutboxProbe.new(ENV.fetch('DATABASE_URL')).run ? 0 : 1)
  rescue StandardError => error
    warn "FALHA: sonda da outbox interrompida (#{error.class})."
    exit 1
  end
end

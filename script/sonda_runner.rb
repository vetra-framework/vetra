#!/usr/bin/env ruby
# PostgreSQL 17/18 descartável, superusuário e bootstrap do ADR-036 já executados (mais os dois ALTER ROLE da C15).
# DATABASE_URL administrativa; VETRA_APP_PASSWORD para o login real de vetra_app, se necessário.
# Aplica os planos como vetra_migrator; não altera papéis ou artefatos e não imprime segredos.
#
# K17 (ADR-045): um comando de cada exemplo pelo Runner, com a borda de referência (DatabaseFacts e a autoridade), em dois
# pools de vetra_app: o da operação e o da borda. Ainda sem eventos nem idempotência (K19). A contagem de transações é a
# de cada pool pelo logger do Sequel: a da operação é zero nas recusas; a da borda não é.
require_relative 'sonda_vetra_data'
require_relative '../lib/vetra/execution'
require 'tmpdir'
require 'fileutils'

class RunnerProbe < VetraDataProbe
  COMMIT = /\bCOMMIT\b/
  ROLLBACK = /\bROLLBACK\b/
  BEGIN_ = /\bBEGIN\b/

  Hooked = Struct.new(:inner, :hook, :calls) do
    def call(context)
      self.calls += 1
      hook.call(calls)
      inner.call(context)
    end
  end

  # Registra, no instante da publicação, se o pool da operação já tinha visto COMMIT ou ROLLBACK.
  Observed = Struct.new(:inner, :log, :seen) do
    def call(context) = inner.call(context)

    def publish!(context)
      seen << [log.any? { |statement| statement.match?(COMMIT) }, log.any? { |statement| statement.match?(ROLLBACK) }]
      inner.publish!(context)
    end
  end

  def run
    @admin = PG.connect(@url)
    @admin.exec('SET client_min_messages = warning')
    @admin.exec(Vetra::SQL::Context.role_guard)
    before = roles
    revendas
    blog
    chat
    check('nenhum papel global mudou') { roles == before }
    puts "#{@results.count(true)}/#{@results.size} verificações passaram (PostgreSQL #{@admin.server_version})."
    @results.all?
  ensure
    close_all
    if @admin
      @databases.reverse_each { |name| @admin.exec("DROP DATABASE IF EXISTS #{PG::Connection.quote_ident(name)} WITH (FORCE)") }
      @admin.close
    end
  end

  private

  def close_all
    @edge_db&.disconnect
    @edge_db = nil
    close_runtime
  end

  def open_edge
    @edge_db = Vetra::Data.connect({ adapter: :postgres, host: @admin.host, hostaddr: @admin.hostaddr,
                                    port: @admin.port, database: @database_name,
                                    password: ENV.fetch('VETRA_APP_PASSWORD', '') }, max_connections: 1)
  end

  # O logger do Sequel vê todo BEGIN, COMMIT e SAVEPOINT que o pool executa; é a contagem de transações de cada pool.
  def log_of(db)
    statements = []
    logger = Object.new
    %i[info error warn debug].each { |level| logger.define_singleton_method(level) { |message| statements << message.to_s } }
    db.loggers << logger
    statements
  end

  def migration
    @connection.exec('BEGIN; SET LOCAL SESSION AUTHORIZATION vetra_migrator')
    result = yield
    @connection.exec('COMMIT')
    result
  ensure
    @connection.exec('ROLLBACK') if @connection.transaction_status != PG::PQTRANS_IDLE
  end

  def sql_value(sql, params = [])
    migration { @connection.exec_params(sql, params).to_a }
  end

  def boot(example, scoped)
    prepare_example(example)
    @linked = Vetra::Graph::Compiler.new(root: File.expand_path("../examples/#{example}", __dir__)).link
    @catalog = Vetra::Data::Repositories.new(@linked.document)
    if scoped
      provision('runtime', @secret)
      @issuer = Vetra::Data::ContextIssuer.new(kid: 'runtime', secret: @secret)
    end
    open_runtime
    open_edge
    @ops_log, @edge_log = log_of(@runtime), log_of(@edge_db)
    options = scoped ? { issuer: @issuer } : { scope: :global }
    @ops_unit = Vetra::Data::UnitOfWork.new(@runtime, **options)
    @edge_unit = Vetra::Data::UnitOfWork.new(@edge_db, **options)
  end

  def edge_with(authority, facts_authority = authority)
    facts = Vetra::Execution::DatabaseFacts.new(catalog: @catalog, unit: @edge_unit, authority: facts_authority)
    Vetra::Execution::Edge.new(identity: ->(credentials) { credentials }, facts: facts, authority: authority)
  end

  def runner_for(edge)
    Vetra::Execution::Runner.new(linked: @linked, catalog: @catalog, unit: @ops_unit, edge: edge)
  end

  # O blog com um publish_post que grava e só depois falha, numa cópia temporária: o modelo e o plano são os mesmos.
  def with_failing_publish_post
    Dir.mktmpdir('vetra-sonda-') do |directory|
      FileUtils.cp_r("#{File.expand_path('../examples/blog', __dir__)}/.", directory)
      FileUtils.rm_rf(File.join(directory, '.vetra'))
      FileUtils.rm_rf(File.join(directory, 'db'))
      path = File.join(directory, 'app/domains/blog/publish_post.rb')
      original = File.read(path)
      changed = original.sub(/^(\s*)fail! :status.*$/) { "#{Regexp.last_match(1)}posts.update!(post, title: \"alterado antes da falha\")\n#{Regexp.last_match(1)}fail! :status, \"forçado pela sonda\"" }
      raise 'a sonda não reconheceu o corpo de publish_post' if changed == original
      File.write(path, changed)
      compiler = Vetra::Graph::Compiler.new(root: directory)
      compiler.write
      yield compiler.link
    end
  end

  def clear_logs
    @ops_log.clear
    @edge_log.clear
  end

  def begins(log) = log.count { |statement| statement.match?(BEGIN_) }
  def commits(log) = log.count { |statement| statement.match?(COMMIT) }

  # Resultado e as duas contagens de transações da chamada.
  def measured(runner, operation, input, identity)
    clear_logs
    outcome = runner.run(operation, input, credentials: identity)
    result = [outcome, begins(@ops_log), commits(@ops_log), begins(@edge_log)]
    # Só o estado, nunca valores: ajuda a ler uma falha da sonda.
    warn "  #{operation}: #{outcome.status} #{outcome.code} operação=#{result[1]}/#{result[2]} borda=#{result[3]}" if ENV['VETRA_SONDA_DEBUG']
    result
  end

  def refused_without_operation_transaction?(outcome, code, ops_begins, edge_begins)
    !outcome.ok? && outcome.code == code && ops_begins.zero? && @ops_log.empty? && edge_begins.positive?
  end

  # ---- CRM com revendas: tenant, RLS, revisão de vetra.authz_revisions -----------------------------------------------

  def revendas
    boot('mini_crm_revendas', true)
    @other = SecureRandom.uuid
    @m1, @m2, @unlinked = Array.new(3) { SecureRandom.uuid }
    @dealer, @lead = SecureRandom.uuid, SecureRandom.uuid
    migration do
      @connection.exec_params('INSERT INTO public.companies (id, name, created_at) VALUES ($1, $2, transaction_timestamp())', [@tenant, 'Empresa da sonda'])
      { @m1 => 'm1', @m2 => 'm2', @unlinked => 'unlinked' }.each do |id, name|
        @connection.exec_params('INSERT INTO public.users (id, company_id, name, email, created_at) VALUES ($1, $2, $3, $4, transaction_timestamp())',
                                [id, @tenant, 'Ator da sonda', "#{name}@probe.invalid"])
      end
      @connection.exec_params('INSERT INTO public.dealers (id, company_id, name, created_at) VALUES ($1, $2, $3, transaction_timestamp())', [@dealer, @tenant, 'Revenda'])
      @connection.exec_params('INSERT INTO public.leads (id, company_id, dealer_id, name, status, created_at) VALUES ($1, $2, $3, $4, $5, transaction_timestamp())',
                              [@lead, @tenant, @dealer, 'Cliente da sonda', 'new'])
      [@m1, @m2].each do |user|
        @connection.exec_params('INSERT INTO public.memberships (company_id, dealer_id, user_id, role, created_at) VALUES ($1, $2, $3, $4, transaction_timestamp())',
                                [@tenant, @dealer, user, 'gerente'])
      end
    end
    @authority = Vetra::Execution::DatabaseAuthority.new(db: @edge_db)
    @runner = runner_for(edge_with(@authority))
    manager = ->(actor) { Vetra::Execution::Identity.new(tenant_id: @tenant, actor_id: actor, roles: ['crm.gerente']) }

    check('crm: update_lead (crud.update) pelo gerente: a operação abre uma transação e a borda, a sua') do
      outcome, ops_begins, ops_commits, edge_begins = measured(@runner, 'crm.update_lead', { id: @lead, name: 'Cliente alterado' }, manager.call(@m1))
      outcome.ok? && ops_begins == 1 && ops_commits == 1 && edge_begins >= 1 &&
        sql_value('SELECT name FROM public.leads WHERE id = $1', [@lead]).first['name'] == 'Cliente alterado'
    end
    check('crm: consulta read_lead usa uma transação somente leitura') do
      outcome, ops_begins = measured(@runner, 'crm.read_lead', { id: @lead }, manager.call(@m1))
      outcome.ok? && outcome.value.id == @lead && ops_begins == 1 && @ops_log.any? { |statement| statement.include?('READ ONLY') }
    end
    check('crm: win_lead (call Ruby) conclui o lead e uma segunda tentativa vira Failure com a transação desfeita') do
      first, = measured(@runner, 'crm.win_lead', { lead_id: @lead }, manager.call(@m1))
      failed = begin
        @runner.run('crm.win_lead', { lead_id: @lead }, credentials: manager.call(@m1))
        nil
      rescue Vetra::Execution::Failure => error
        error
      end
      first.ok? && failed&.field == 'status' && sql_value('SELECT status FROM public.leads WHERE id = $1', [@lead]).first['status'] == 'won'
    end
    check('crm: ator sem vínculo é recusado sem transação da operação (a borda lê, e não é zero)') do
      outcome, ops_begins, _, edge_begins = measured(@runner, 'crm.update_lead', { id: @lead, name: 'Intruso' }, manager.call(@unlinked))
      refused_without_operation_transaction?(outcome, 'data_authorization_denied', ops_begins, edge_begins) &&
        sql_value('SELECT name FROM public.leads WHERE id = $1', [@lead]).first['name'] == 'Cliente alterado'
    end
    check('crm: entrada inválida e identidade não resolvida recusam antes de qualquer SQL em qualquer pool') do
      invalid, ops_a, _, edge_a = measured(@runner, 'crm.update_lead', { id: 'x' }, manager.call(@m1))
      raising = Vetra::Execution::Edge.new(identity: ->(_) { raise 'segredo' }, facts: ->(_) {}, authority: @authority)
      unresolved, ops_b, _, edge_b = measured(runner_for(raising), 'crm.update_lead', { id: @lead }, nil)
      invalid.status == :invalid && unresolved.status == :unresolved && [ops_a, edge_a, ops_b, edge_b].all?(&:zero?) &&
        unresolved.diagnostics.map(&:message).none? { |message| message.include?('segredo') }
    end
    check('crm: papel atribuído errado na borda recusa mesmo com vínculo de gerente') do
      # m1 é gerente da revenda; declarar só vendedor na borda não fabrica o vínculo de vendedor.
      outcome, ops_begins, = measured(@runner, 'crm.update_lead', { id: @lead, name: %q(Nome válido) },
                                      Vetra::Execution::Identity.new(tenant_id: @tenant, actor_id: @m1, roles: ['crm.vendedor']))
      !outcome.ok? && outcome.code == 'data_authorization_denied' && ops_begins.zero?
    end
    check('crm: a revogação durante a admissão é pega pela segunda conferência e nada abre na operação') do
      revoke = lambda do |call|
        migration { @connection.exec_params('DELETE FROM public.memberships WHERE user_id = $1', [@m2]) } if call == 3
      end
      hooked = Hooked.new(@authority, revoke, 0)
      outcome, ops_begins, _, edge_begins = measured(runner_for(edge_with(hooked)), 'crm.update_lead', { id: @lead, name: 'Revogado' }, manager.call(@m2))
      refused_without_operation_transaction?(outcome, 'data_authorization_snapshot', ops_begins, edge_begins) &&
        sql_value('SELECT name FROM public.leads WHERE id = $1', [@lead]).first['name'] == 'Cliente alterado'
    end
    check('crm: autoridade fora do ar recusa sem transportar a exceção e sem abrir a operação') do
      broken = Hooked.new(@authority, ->(call) { raise 'segredo-da-autoridade' if call >= 1 }, 0)
      outcome, ops_begins = measured(runner_for(edge_with(broken, @authority)), 'crm.update_lead', { id: @lead, name: %q(Nome válido) }, manager.call(@m1))
      !outcome.ok? && outcome.code == 'data_authorization_snapshot' && ops_begins.zero? &&
        outcome.diagnostics.map(&:message).none? { |message| message.include?('segredo') }
    end
    check('crm: depois do commit que revoga um vínculo o marcador avança e o snapshot antigo é recusado') do
      context = Vetra::Data::Context.new(scope: :tenant, tenant_id: @tenant, actor_id: @m1, op_id: SecureRandom.uuid, cmd: 'crm.update_lead')
      request = Vetra::Execution::FactsRequest.new(authorization: @runner.authorization, operation_id: 'crm.update_lead', context: context,
                                                  roles: ['crm.gerente'], input: { 'id' => @lead })
      old = edge_with(@authority).snapshot(request)
      marker = @authority.call(context)
      migration { @connection.exec_params('DELETE FROM public.memberships WHERE user_id = $1', [@m1]) }
      stale = @runner.authorization.check('crm.update_lead', input: { id: @lead, name: %q(Nome válido) }, context: context, snapshot: old,
                                          current_revision: @authority)
      new_marker = @authority.call(context)
      fresh, ops_begins, = measured(@runner, 'crm.update_lead', { id: @lead, name: %q(Nome válido) }, manager.call(@m1))
      !stale.allowed? && stale.code == 'data_authorization_snapshot' && new_marker.first > marker.first &&
        !fresh.ok? && fresh.code == 'data_authorization_denied' && ops_begins.zero?
    end
    check('crm: uma geração de identidade publicada pela borda também invalida o snapshot') do
      context = Vetra::Data::Context.new(scope: :tenant, tenant_id: @tenant, actor_id: @m2, op_id: SecureRandom.uuid, cmd: 'crm.read_lead')
      request = Vetra::Execution::FactsRequest.new(authorization: @runner.authorization, operation_id: 'crm.read_lead', context: context,
                                                  roles: ['crm.gerente'], input: { 'id' => @lead })
      old = edge_with(@authority).snapshot(request)
      @authority.identity_changed!
      stale = @runner.authorization.check('crm.read_lead', input: { id: @lead }, context: context, snapshot: old, current_revision: @authority)
      !stale.allowed? && stale.code == 'data_authorization_snapshot'
    end
    check('crm: a aplicação não chegou a abrir transação fora da unidade nem deixou contexto no pool da operação') do
      empty_context?
    end
    close_all
  end

  # ---- Blog: global, sem RLS, autoridade em processo ------------------------------------------------------------------

  def blog
    boot('blog', false)
    @authority = Vetra::Execution::InProcessAuthority.new
    @runner = runner_for(edge_with(@authority))
    author = SecureRandom.uuid
    identity = Vetra::Execution::Identity.new(actor_id: author, roles: ['blog.autor'])
    post = nil

    check('blog: create_post (crud.create) e publish_post (call Ruby), com uma geração publicada depois de cada commit') do
      generation = @authority.call
      created, ops_begins, = measured(@runner, 'blog.create_post', { title: 'Primeiro post' }, identity)
      post = created.value&.id
      published, = measured(@runner, 'blog.publish_post', { post_id: post }, identity)
      row = sql_value('SELECT status, published_at FROM public.posts WHERE id = $1', [post]).first
      created.ok? && published.ok? && ops_begins == 1 && row['status'] == 'published' && !row['published_at'].nil? &&
        @authority.call == generation + 2
    end
    check('blog: consulta não publica geração e lê o post do autor') do
      generation = @authority.call
      found, = measured(@runner, 'blog.find_post', { post_id: post }, identity)
      found.ok? && found.value.id == post && @authority.call == generation
    end
    check('blog: visitante é recusado sem transação da operação, e a borda lê') do
      outcome, ops_begins, _, edge_begins = measured(@runner, 'blog.find_post', { post_id: post }, Vetra::Execution::Identity.new)
      refused_without_operation_transaction?(outcome, 'data_authorization_denied', ops_begins, edge_begins)
    end
    check('blog: a segunda publicação vira Failure, desfaz tudo e ainda publica a geração (resultado do commit não presumido)') do
      generation = @authority.call
      failed = begin
        @runner.run('blog.publish_post', { post_id: post }, credentials: identity)
        nil
      rescue Vetra::Execution::Failure => error
        error
      end
      failed&.field == 'status' && @authority.call == generation + 1
    end
    check('blog: o snapshot lido antes de um comando é recusado depois dele') do
      context = Vetra::Data::Context.new(scope: :global, tenant_id: nil, actor_id: author, op_id: SecureRandom.uuid, cmd: 'blog.find_post')
      request = Vetra::Execution::FactsRequest.new(authorization: @runner.authorization, operation_id: 'blog.find_post', context: context,
                                                  roles: ['blog.autor'], input: { 'post_id' => post })
      old = edge_with(@authority).snapshot(request)
      measured(@runner, 'blog.update_post', { id: post, title: 'Renomeado' }, identity)
      stale = @runner.authorization.check('blog.find_post', input: { post_id: post }, context: context, snapshot: old, current_revision: @authority)
      !stale.allowed? && stale.code == 'data_authorization_snapshot'
    end
    check('blog: a geração só é publicada depois do COMMIT do comando') do
      seen = []
      observed = Observed.new(@authority, @ops_log, seen)
      runner = runner_for(edge_with(observed, @authority))
      outcome, = measured(runner, 'blog.update_post', { id: post, title: 'Observado' }, identity)
      outcome.ok? && seen == [[true, false]]
    end
    check('blog: um comando que escreve e depois falha desfaz a escrita e só publica a geração depois do ROLLBACK') do
      seen = []
      observed = Observed.new(@authority, @ops_log, seen)
      before_title = sql_value('SELECT title FROM public.posts WHERE id = $1', [post]).first['title']
      generation = @authority.call
      failed = nil
      with_failing_publish_post do |linked|
        runner = Vetra::Execution::Runner.new(linked: linked, catalog: Vetra::Data::Repositories.new(linked.document), unit: @ops_unit,
                                              edge: edge_with(observed, @authority))
        clear_logs
        failed = begin
          runner.run('blog.publish_post', { post_id: post }, credentials: identity)
          nil
        rescue Vetra::Execution::Failure => error
          error
        end
      end
      failed&.field == 'status' && @ops_log.any? { |statement| statement.match?(ROLLBACK) } && @ops_log.none? { |statement| statement.match?(COMMIT) } &&
        sql_value('SELECT title FROM public.posts WHERE id = $1', [post]).first['title'] == before_title &&
        seen == [[false, true]] && @authority.call == generation + 1
    end
    check('blog: delete_post (crud.delete) remove a linha') do
      deleted, = measured(@runner, 'blog.delete_post', { id: post }, identity)
      deleted.ok? && sql_value('SELECT count(*) AS n FROM public.posts WHERE id = $1', [post]).first['n'].to_i.zero?
    end
    close_all
  end

  # ---- Chat: global, sem RLS; read de sala depende do many_to_many (C16) ----------------------------------------------

  def chat
    boot('chat', false)
    @authority = Vetra::Execution::InProcessAuthority.new
    @runner = runner_for(edge_with(@authority))
    user = SecureRandom.uuid
    migration do
      @connection.exec_params('INSERT INTO public.users (id, name, email, created_at) VALUES ($1, $2, $3, transaction_timestamp())', [user, 'Ana', 'ana@probe.invalid'])
    end
    identity = Vetra::Execution::Identity.new(actor_id: user, roles: ['chat.authenticated'])
    room = nil

    check('chat: create_room cria a sala e o vínculo do dono pela primitiva, e publica geração') do
      generation = @authority.call
      created, ops_begins, = measured(@runner, 'chat.create_room', { name: 'Geral' }, identity)
      room = created.value&.id
      created.ok? && ops_begins == 1 && @authority.call == generation + 1 &&
        sql_value('SELECT owner_id FROM public.rooms WHERE id = $1', [room]).first['owner_id'] == user &&
        sql_value('SELECT count(*) AS n FROM public.room_memberships WHERE room_id = $1 AND user_id = $2', [room, user]).first['n'].to_i == 1
    end
    check('chat: read_room recusa com o predicado de many_to_many fora do subconjunto (C16) e sem transação da operação') do
      outcome, ops_begins = measured(@runner, 'chat.read_room', { id: room }, identity)
      !outcome.ok? && outcome.code == 'data_authorization_predicate' && ops_begins.zero?
    end
    check('chat: um papel desconhecido recusa antes de abrir a operação') do
      outcome, ops_begins = measured(@runner, 'chat.create_room', { name: %q(Nome válido) }, Vetra::Execution::Identity.new(actor_id: user, roles: ['chat.inexistente']))
      !outcome.ok? && ops_begins.zero?
    end
    close_all
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    exit(RunnerProbe.new(ENV.fetch('DATABASE_URL')).run ? 0 : 1)
  rescue StandardError => error
    warn "FALHA: sonda do Runner interrompida (#{error.class})."
    exit 1
  end
end

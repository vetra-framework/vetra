#!/usr/bin/env ruby
# PostgreSQL 17/18 descartável; DATABASE_URL administrativa e bootstrap ADR-036/C15 prontos.
# VETRA_APP_PASSWORD: senha do login real vetra_app, se necessária. Aplica os planos como vetra_migrator; não altera papéis.
#
# K19 (ADR-047): o fechamento transacional do Runner contra o banco real: os eventos do `emits` na etapa 7, a idempotência na unidade
# (claim, resultado e replay), o status do ADR-016 e a repetição depois de falha de serialização e de deadlock, com duas transações
# concorrentes de verdade, sem evento duplicado. As concorrentes são comandos de uma cópia temporária do blog (o modelo e o plano
# são os mesmos); a barreira entre as duas é um gancho global que o corpo chama (`$k19_gate`).
require_relative 'sonda_runner'
require 'timeout'
require 'json'

class ClosingProbe < RunnerProbe
  def run
    @admin = PG.connect(@url)
    @admin.exec('SET client_min_messages = warning')
    @admin.exec(Vetra::SQL::Context.role_guard)
    before = roles
    blog
    revendas
    check('nenhum papel global mudou') { roles == before }
    puts "#{@results.count(true)}/#{@results.size} verificações passaram (PostgreSQL #{@admin.server_version})."
    @results.all?
  ensure
    $k19_gate = nil
    close_all
    if @admin
      @databases.reverse_each { |name| @admin.exec("DROP DATABASE IF EXISTS #{PG::Connection.quote_ident(name)} WITH (FORCE)") }
      @admin.close
    end
  end

  private

  def close_all
    @second_db&.disconnect
    @second_db = nil
    super
  end

  # Superusuário da sonda (a sessão da criação do banco), para ler a outbox e o registro, que a aplicação não lê.
  def admin_rows(sql, params = [])
    @connection.exec_params(sql, params).to_a
  end

  def outbox_events(cmd = nil)
    rows = admin_rows('SELECT event, cmd, op_id, payload::text AS payload FROM vetra.outbox ORDER BY seq')
    cmd ? rows.select { |row| row['cmd'] == cmd } : rows
  end

  def open_second
    @second_db = Vetra::Data.connect({ adapter: :postgres, host: @admin.host, hostaddr: @admin.hostaddr, port: @admin.port,
                                      database: @database_name, password: ENV.fetch('VETRA_APP_PASSWORD', '') }, max_connections: 1)
    Vetra::Data::UnitOfWork.new(@second_db, scope: :global)
  end

  def wait(queue)
    queue.pop(timeout: 30) || raise('a barreira da sonda expirou')
  end

  # ---- Blog: eventos, idempotência e status ------------------------------------------------------------------------------

  def blog
    boot('blog', false)
    @authority = Vetra::Execution::InProcessAuthority.new
    runner = runner_for(edge_with(@authority))
    author = SecureRandom.uuid
    identity = Vetra::Execution::Identity.new(actor_id: author, roles: ['blog.autor'])
    new_post = lambda do |title|
      outcome, = measured(runner, 'blog.create_post', { title: title }, identity)
      outcome.value.id
    end
    post = new_post.call('Fechamento')

    check('blog: o evento do emits é gravado na etapa 7, pelo Runner, com o payload projetado do registro devolvido') do
      outcome = runner.run('blog.publish_post', { post_id: post }, credentials: identity)
      events = outbox_events
      outcome.ok? && events.size == 1 && events.first['event'] == 'blog.post.published' && events.first['cmd'] == 'blog.publish_post' &&
        JSON.parse(events.first['payload']) == { 'id' => post }
    end
    check('blog: fail! é 422, desfaz tudo e não deixa evento; o acesso negado é 403 e não abre transação') do
      failed = runner.run('blog.publish_post', { post_id: post }, credentials: identity)
      denied, ops_begins = measured(runner, 'blog.publish_post', { post_id: post }, Vetra::Execution::Identity.new)
      [failed.status, failed.http_status, failed.retryable?] == [:failed, 422, false] && outbox_events.size == 1 &&
        denied.status == :denied && denied.http_status == 403 && ops_begins.zero?
    end
    check('blog: com a chave, a primeira execução guarda o resultado e a repetição o devolve em JSON sem executar, escrever nem emitir') do
      draft = new_post.call('Com chave')
      first = runner.run('blog.publish_post', { post_id: draft }, credentials: identity, idempotency_key: 'sonda-chave-1')
      stored = admin_rows("SELECT result::text AS result FROM vetra.idempotency WHERE key = 'sonda-chave-1'")
      published_at = sql_value('SELECT published_at FROM public.posts WHERE id = $1', [draft]).first['published_at']
      events_before = outbox_events.size
      second = runner.run('blog.publish_post', { post_id: draft }, credentials: identity, idempotency_key: 'sonda-chave-1')
      first.ok? && !first.replayed? && second.ok? && second.replayed? && stored.size == 1 &&
        JSON.parse(stored.first['result']) == runner.serialize('blog.publish_post', first.value) && second.value == runner.serialize('blog.publish_post', first.value) &&
        outbox_events.size == events_before && events_before == 2 &&
        sql_value('SELECT published_at FROM public.posts WHERE id = $1', [draft]).first['published_at'] == published_at
    end
    check('blog: a mesma chave com outra entrada é 422, não revela o resultado e não executa nada') do
      other = new_post.call('Outra entrada')
      outcome = runner.run('blog.publish_post', { post_id: other }, credentials: identity, idempotency_key: 'sonda-chave-1')
      [outcome.status, outcome.code] == [:failed, 'data_idempotency_key_reuse'] &&
        sql_value('SELECT status FROM public.posts WHERE id = $1', [other]).first['status'] == 'draft'
    end
    check('blog: a chave é recusada antes de qualquer transação para uma consulta, uma chave ruim e um comando que devolve campo pessoal') do
      admin = Vetra::Execution::Identity.new(actor_id: author, roles: ['blog.admin'])
      clear_logs
      results = [
        runner.run('blog.find_post', { post_id: post }, credentials: identity, idempotency_key: 'k'),
        runner.run('blog.publish_post', { post_id: post }, credentials: identity, idempotency_key: 'com espaço'),
        runner.run('blog.approve_comment', { comment_id: SecureRandom.uuid }, credentials: admin, idempotency_key: 'k')
      ]
      results.map(&:code) == %w[execution_idempotency_query data_idempotency_key execution_idempotency_personal] &&
        results.all? { |outcome| outcome.status == :invalid } && begins(@ops_log).zero? && begins(@edge_log).zero?
    end

    concurrent_closing(post)
    close_all
  end

  # Duas transações concorrentes de verdade, nos comandos de uma cópia temporária do blog.
  def concurrent_closing(post)
    author = SecureRandom.uuid
    identity = Vetra::Execution::Identity.new(actor_id: author, roles: ['blog.autor'])
    with_closing_variant do |linked|
      catalog = Vetra::Data::Repositories.new(linked.document)
      edge = edge_with(@authority)
      make = lambda do |unit, options = {}|
        Vetra::Execution::Runner.new(linked: linked, catalog: catalog, unit: unit, edge: edge, unit_options: options)
      end
      second_unit = open_second
      own = make.call(@ops_unit)
      create_own = ->(title) { own.run('blog.create_post', { title: title }, credentials: identity).value.id }

      serialization = lambda do |operation|
        id = create_own.call("Serial #{operation}")
        a = make.call(@ops_unit, isolation: :serializable)
        b = make.call(second_unit, isolation: :serializable)
        read_by_b, a_done = Queue.new, Queue.new
        gated = { a: false, b: false }
        $k19_gate = lambda do
          who = Thread.current[:who]
          next if gated[who]
          gated[who] = true
          if who == :a
            wait(read_by_b)
          else
            read_by_b << true
            wait(a_done)
          end
        end
        events_before = outbox_events(operation).size
        outcomes = {}
        threads = { a: a, b: b }.map do |who, runner|
          Thread.new do
            Thread.current[:who] = who
            outcomes[who] = runner.run(operation, { post_id: id }, credentials: identity)
            a_done << true if who == :a
          end
        end
        threads.each(&:join)
        $k19_gate = nil
        [outcomes, id, outbox_events(operation).size - events_before]
      end

      check('blog: falha de serialização repete a operação inteira depois do rollback, sem evento duplicado (duas transações reais)') do
        outcomes, id, events = serialization.call('blog.slow_touch')
        title = sql_value('SELECT title FROM public.posts WHERE id = $1', [id]).first['title']
        outcomes[:a].ok? && outcomes[:a].attempts == 1 && outcomes[:b].ok? && outcomes[:b].attempts == 2 &&
          title.end_with?('++') && events == 2
      end
      check('blog: com unsafe_effect a falha de serialização não é repetida: 409 retentável, e só a outra escrita vale') do
        outcomes, id, events = serialization.call('blog.slow_touch_unsafe')
        title = sql_value('SELECT title FROM public.posts WHERE id = $1', [id]).first['title']
        outcomes[:a].ok? && outcomes[:b].status == :conflict && outcomes[:b].http_status == 409 && outcomes[:b].retryable? &&
          outcomes[:b].attempts == 1 && outcomes[:b].code == 'data_serialization' && title.end_with?('+') && !title.end_with?('++') && events == 1
      end
      check('blog: deadlock repete a operação do que foi escolhido como vítima, e as duas terminam, sem evento duplicado') do
        first, second = create_own.call('Trava 1'), create_own.call('Trava 2')
        a = make.call(@ops_unit)
        b = make.call(second_unit)
        locked = { a: Queue.new, b: Queue.new }
        gated = { a: false, b: false }
        $k19_gate = lambda do
          who = Thread.current[:who]
          next if gated[who]
          gated[who] = true
          other = who == :a ? :b : :a
          locked[who] << true
          wait(locked[other])
        end
        events_before = outbox_events('blog.swap_locks').size
        outcomes = {}
        threads = [[:a, a, first, second], [:b, b, second, first]].map do |who, runner, from, to|
          Thread.new do
            Thread.current[:who] = who
            outcomes[who] = runner.run('blog.swap_locks', { first_id: from, second_id: to }, credentials: identity)
          end
        end
        threads.each(&:join)
        $k19_gate = nil
        titles = [first, second].map { |post_id| sql_value('SELECT title FROM public.posts WHERE id = $1', [post_id]).first['title'] }
        outcomes.values.all?(&:ok?) && outcomes.values.map(&:attempts).sort == [1, 2] && titles.all? { |title| title.end_with?('!') } &&
          outbox_events('blog.swap_locks').size - events_before == 2
      end
    end
  end

  def with_closing_variant
    Dir.mktmpdir('vetra-sonda-') do |directory|
      FileUtils.cp_r("#{File.expand_path('../examples/blog', __dir__)}/.", directory)
      FileUtils.rm_rf(File.join(directory, '.vetra'))
      FileUtils.rm_rf(File.join(directory, 'db'))
      touch = lambda do |name, extra|
        <<~RUBY
          command :#{name} do
            input :post_id, :id
            returns :post
            authorize :update, :post, record: :post_id
            uses :posts
            #{extra}
            emits "blog.post.published", with: %i[id]

            call do |input, posts|
              post = posts.find!(input.post_id)
              $k19_gate&.call
              posts.update!(post, title: "\#{post.title}+")
            end
          end
        RUBY
      end
      File.write(File.join(directory, 'app/domains/blog/slow_touch.rb'), touch.call('slow_touch', ''))
      File.write(File.join(directory, 'app/domains/blog/slow_touch_unsafe.rb'), touch.call('slow_touch_unsafe', 'unsafe_effect "sonda: o corpo espera uma barreira externa"'))
      File.write(File.join(directory, 'app/domains/blog/swap_locks.rb'), <<~RUBY)
        command :swap_locks do
          input :first_id, :id
          input :second_id, :id
          returns :post
          authorize :update, :post, record: :first_id
          uses :posts
          emits "blog.post.published", with: %i[id]

          call do |input, posts|
            first = posts.lock!(input.first_id)
            $k19_gate&.call
            posts.lock!(input.second_id)
            posts.update!(first, title: "\#{first.title}!")
          end
        end
      RUBY
      compiler = Vetra::Graph::Compiler.new(root: directory)
      compiler.write
      yield compiler.link
    end
  end

  # ---- CRM com revendas: tenant, RLS, evento e idempotência no contexto de tenant -----------------------------------------

  def revendas
    boot('mini_crm_revendas', true)
    @authority = Vetra::Execution::DatabaseAuthority.new(db: @edge_db)
    runner = runner_for(edge_with(@authority))
    manager, dealer, lead = Array.new(3) { SecureRandom.uuid }
    migration do
      @connection.exec_params('INSERT INTO public.companies (id, name, created_at) VALUES ($1, $2, transaction_timestamp())', [@tenant, 'Empresa'])
      @connection.exec_params('INSERT INTO public.users (id, company_id, name, email, created_at) VALUES ($1, $2, $3, $4, transaction_timestamp())', [manager, @tenant, 'Pessoa', 'm@probe.invalid'])
      @connection.exec_params('INSERT INTO public.dealers (id, company_id, name, created_at) VALUES ($1, $2, $3, transaction_timestamp())', [dealer, @tenant, 'Revenda'])
      @connection.exec_params('INSERT INTO public.leads (id, company_id, dealer_id, name, status, created_at) VALUES ($1, $2, $3, $4, $5, transaction_timestamp())', [lead, @tenant, dealer, 'Cliente', 'new'])
      @connection.exec_params('INSERT INTO public.memberships (company_id, dealer_id, user_id, role, created_at) VALUES ($1, $2, $3, $4, transaction_timestamp())', [@tenant, dealer, manager, 'gerente'])
    end
    identity = Vetra::Execution::Identity.new(tenant_id: @tenant, actor_id: manager, roles: ['crm.gerente'])

    check('crm: win_lead grava o evento do emits no tenant do contexto, na mesma transação (RLS da outbox), com o payload do registro devolvido') do
      outcome, ops_begins, ops_commits = measured(runner, 'crm.win_lead', { lead_id: lead }, identity)
      events = outbox_events('crm.win_lead')
      payload = events.first && JSON.parse(events.first['payload'])
      tenant = events.first && admin_rows('SELECT tenant_id::text AS tenant FROM vetra.outbox WHERE cmd = $1', ['crm.win_lead']).first['tenant']
      outcome.ok? && ops_begins == 1 && ops_commits == 1 && events.size == 1 && events.first['event'] == 'crm.lead.won' &&
        payload.fetch('id') == lead && tenant == @tenant
    end
    check('crm: um comando cuja saída leva campo pessoal (o e-mail do lead) recusa a chave antes de abrir qualquer transação') do
      outcome, ops_begins, _, edge_begins = measured(runner, 'crm.update_lead', { id: lead, name: 'Cliente alterado' }, identity)
      refused, refused_ops, _, refused_edge = measured_with_key(runner, 'crm.update_lead', { id: lead, name: 'Outro' }, identity, 'crm-chave-2')
      outcome.ok? && ops_begins == 1 && edge_begins >= 1 &&
        [refused.status, refused.code, refused_ops, refused_edge] == [:invalid, 'execution_idempotency_personal', 0, 0]
    end
    close_all
  end

  def measured_with_key(runner, operation, input, identity, key)
    clear_logs
    outcome = runner.run(operation, input, credentials: identity, idempotency_key: key)
    [outcome, begins(@ops_log), commits(@ops_log), begins(@edge_log)]
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    exit(ClosingProbe.new(ENV.fetch('DATABASE_URL')).run ? 0 : 1)
  rescue StandardError => error
    warn "FALHA: sonda do fechamento interrompida (#{error.class})."
    exit 1
  end
end

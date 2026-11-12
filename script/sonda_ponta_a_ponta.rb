#!/usr/bin/env ruby
# PostgreSQL 17/18 descartável. DATABASE_URL administrativa; bootstrap ADR-036/C15 já aplicado.
# VETRA_APP_PASSWORD e VETRA_RELAY_PASSWORD: logins reais dos papéis de produção, se necessários.
# Aplica os planos commitados como vetra_migrator; os exemplos rodam como estão, sem cópia temporária nem fixture.
#
# K20: os quatro exemplos ponta a ponta pelo executor (Edge, Runner, guarda, fechamento e, nos dois CRMs, a outbox, o relay e
# o handler de sistema real, com a chave derivada). Inclui as duas recusas que a rodada assume: chat.add_member_by_email
# (o uses não concede dados) e o comentário do visitante do blog (reserva de taxa não configurada nesta sonda). No fim, a tabela com as duas
# contagens de transações de cada comando (teste 1 do ADR-016): a da operação e a da borda.
require_relative 'sonda_handlers'

class EndToEndProbe < HandlersProbe
  Row = Struct.new(:example, :operation, :outcome, :ops, :commits, :edge)

  def run
    @admin = PG.connect(@url)
    @admin.exec('SET client_min_messages = warning')
    @admin.exec(Vetra::SQL::Context.role_guard)
    @table = []
    before = roles
    crm
    revendas
    blog
    chat
    report
    check('nenhum papel global mudou') { roles == before }
    puts "#{@results.count(true)}/#{@results.size} verificações passaram (PostgreSQL #{@admin.server_version})."
    @results.all?
  ensure
    @relay_db&.disconnect
    close_all
    if @admin
      @databases.reverse_each { |name| @admin.exec("DROP DATABASE IF EXISTS #{PG::Connection.quote_ident(name)} WITH (FORCE)") }
      @admin.close
    end
  end

  private

  # Executa o comando, guarda as duas contagens e devolve só o resultado.
  def go(example, runner, operation, input, identity, **options)
    clear_logs
    outcome = runner.run(operation, input, credentials: identity, **options)
    @table << Row.new(example, operation, outcome.ok? ? 'ok' : outcome.code.to_s, begins(@ops_log), commits(@ops_log), begins(@edge_log))
    # Só o estado, nunca valores: ajuda a ler uma falha da sonda.
    warn "  #{operation}: #{outcome.status} #{outcome.code} replay=#{outcome.replayed?}" if ENV['VETRA_SONDA_DEBUG']
    outcome
  end

  def won_event(lead) = rows("SELECT event_id::text AS id FROM vetra.outbox WHERE event = 'crm.lead.won' AND payload->>'id' = $1", [lead]).first&.fetch('id')
  def outbox_count(lead) = count("SELECT count(*) AS n FROM vetra.outbox WHERE event = 'crm.lead.won' AND payload->>'id' = $1", [lead])
  def status_of(lead) = rows('SELECT status FROM public.leads WHERE id = $1', [lead]).first&.fetch('status')
  def open_transactions
    count("SELECT count(*) AS n FROM pg_stat_activity WHERE datname = current_database() AND usename IN ('vetra_app', 'vetra_relay') " \
          "AND (backend_xid IS NOT NULL OR state LIKE 'idle in transaction%')")
  end

  def start_relay
    @relay_db = relay_pool
    @relay = Vetra::Data::Relay.new(@relay_db, document: @linked.document)
    @provider = Provider.new
  end

  def stop_relay
    @relay_db&.disconnect
    @relay_db = nil
  end

  # ---- CRM (tenant, RLS): crud, comando com evento, idempotência, relay e o handler notify_sales -------------------------

  def crm
    boot('mini_crm', true)
    @authority = Vetra::Execution::DatabaseAuthority.new(db: @edge_db)
    @runner = runner_for(edge_with(@authority))
    start_relay
    seed
    seller = Vetra::Execution::Identity.new(tenant_id: @tenant, actor_id: SecureRandom.uuid, roles: ['crm.vendedor'])
    lead = nil

    check('crm: create_lead, read_lead e update_lead pelo Runner, como gerente, no tenant do contexto assinado') do
      created = go('mini_crm', @runner, 'crm.create_lead', { name: 'Cliente da sonda' }, @identity)
      lead = created.value&.id
      read = go('mini_crm', @runner, 'crm.read_lead', { id: lead }, @identity)
      updated = go('mini_crm', @runner, 'crm.update_lead', { id: lead, name: 'Cliente alterado' }, @identity)
      created.ok? && read.ok? && updated.ok? && rows('SELECT name FROM public.leads WHERE id = $1', [lead]).first['name'] == 'Cliente alterado'
    end
    check('crm: win_lead emite crm.lead.won na etapa 7; o relay o entrega e o handler real notify_sales chama o provedor com a chave derivada') do
      won = go('mini_crm', @runner, 'crm.win_lead', { lead_id: lead }, @identity)
      event = won_event(lead)
      @relay.relay!
      result = worker.work('crm.notify_sales', limit: 1)
      won.ok? && status_of(lead) == 'won' && event && outbox_count(lead) == 1 && result[:done] == 1 &&
        @provider.keys == [Vetra::Execution::HandlerRunner.event_key('crm.notify_sales', event)] && open_transactions.zero?
    end
    check('crm: reprocessar a fila não reentrega, e o handler sem calls não escreve em vetra.idempotency') do
      @relay.relay!
      worker.work('crm.notify_sales', limit: 5)[:done].zero? && @provider.keys.size == 1 &&
        count("SELECT count(*) AS n FROM vetra.idempotency WHERE handler = 'crm.notify_sales'").zero?
    end
    check('crm: win_lead com chave é recusado antes da etapa 4 (a saída do lead leva e-mail, dado pessoal, ADR-043, §4): sem unidade, sem evento, sem mudança') do
      pending = go('mini_crm', @runner, 'crm.create_lead', { name: 'Segundo cliente' }, @identity).value.id
      outcome = go('mini_crm', @runner, 'crm.win_lead', { lead_id: pending }, @identity, idempotency_key: 'k20-win-1')
      row = @table.last
      !outcome.ok? && outcome.code == 'execution_idempotency_personal' && outcome.http_status == 422 && row.ops.zero? && row.edge.zero? &&
        outbox_count(pending).zero? && status_of(pending) == 'new'
    end
    check('crm: o vendedor lê e atualiza, e não apaga; o gerente apaga') do
      read = go('mini_crm', @runner, 'crm.read_lead', { id: lead }, seller)
      updated = go('mini_crm', @runner, 'crm.update_lead', { id: lead, name: 'Alterado pelo vendedor' }, seller)
      renamed = rows('SELECT name FROM public.leads WHERE id = $1', [lead]).first['name'] == 'Alterado pelo vendedor'
      deleted = go('mini_crm', @runner, 'crm.delete_lead', { id: lead }, seller)
      removed = go('mini_crm', @runner, 'crm.delete_lead', { id: lead }, @identity)
      read.ok? && updated.ok? && renamed && !deleted.ok? && deleted.code == 'data_authorization_denied' && removed.ok? &&
        count('SELECT count(*) AS n FROM public.leads WHERE id = $1', [lead]).zero?
    end
    check('crm: o lead de outro tenant não é alcançado pelo gerente') do
      outcome = go('mini_crm', @runner, 'crm.update_lead', { id: @foreign_lead, name: 'Invasão' }, @identity)
      !outcome.ok? && rows('SELECT name FROM public.leads WHERE id = $1', [@foreign_lead]).first['name'] == 'Outro tenant'
    end
    stop_relay
    close_all
  end

  # ---- CRM com revendas (tenant, escopo por revenda): o handler notify_seller com e sem vendedor ----------------------------

  def revendas
    boot('mini_crm_revendas', true)
    @authority = Vetra::Execution::DatabaseAuthority.new(db: @edge_db)
    @runner = runner_for(edge_with(@authority))
    start_relay
    manager, seller, outsider = Array.new(3) { SecureRandom.uuid }
    dealer, other_dealer = SecureRandom.uuid, SecureRandom.uuid
    migration do
      @connection.exec_params('INSERT INTO public.companies (id, name, created_at) VALUES ($1, $2, transaction_timestamp())', [@tenant, 'Empresa'])
      { manager => 'g', seller => 's', outsider => 'o' }.each do |user, name|
        @connection.exec_params('INSERT INTO public.users (id, company_id, name, email, created_at) VALUES ($1, $2, $3, $4, transaction_timestamp())',
                                [user, @tenant, 'Pessoa', "#{name}@probe.invalid"])
      end
      [dealer, other_dealer].each do |id|
        @connection.exec_params('INSERT INTO public.dealers (id, company_id, name, created_at) VALUES ($1, $2, $3, transaction_timestamp())', [id, @tenant, 'Revenda'])
      end
      { manager => [dealer, 'gerente'], seller => [dealer, 'vendedor'], outsider => [other_dealer, 'vendedor'] }.each do |user, (revenda, role)|
        @connection.exec_params('INSERT INTO public.memberships (company_id, dealer_id, user_id, role, created_at) VALUES ($1, $2, $3, $4, transaction_timestamp())',
                                [@tenant, revenda, user, role])
      end
    end
    as = ->(user, role) { Vetra::Execution::Identity.new(tenant_id: @tenant, actor_id: user, roles: ["crm.#{role}"]) }
    lead = nil

    check('revendas: o vendedor da revenda cria o lead, o gerente o altera e o vendedor de outra revenda não o lê') do
      created = go('mini_crm_revendas', @runner, 'crm.create_lead', { name: 'Cliente da sonda', dealer_id: dealer, seller_id: seller }, as.call(seller, 'vendedor'))
      lead = created.value&.id
      updated = go('mini_crm_revendas', @runner, 'crm.update_lead', { id: lead, name: 'Cliente alterado' }, as.call(manager, 'gerente'))
      foreign = go('mini_crm_revendas', @runner, 'crm.read_lead', { id: lead }, as.call(outsider, 'vendedor'))
      created.ok? && updated.ok? && !foreign.ok? && foreign.code == 'data_authorization_denied'
    end
    check('revendas: win_lead emite o evento com o vendedor, e o handler notify_seller entrega ao provedor com a chave derivada') do
      won = go('mini_crm_revendas', @runner, 'crm.win_lead', { lead_id: lead }, as.call(manager, 'gerente'))
      event = won_event(lead)
      @relay.relay!
      result = worker.work('crm.notify_seller', limit: 1)
      won.ok? && result[:done] == 1 && @provider.keys == [Vetra::Execution::HandlerRunner.event_key('crm.notify_seller', event)] &&
        @provider.effects.values.first[:to] == seller && open_transactions.zero?
    end
    check('revendas: sem vendedor o handler conclui a entrega sem chamar o provedor') do
      bare = go('mini_crm_revendas', @runner, 'crm.create_lead', { name: 'Sem vendedor', dealer_id: dealer }, as.call(manager, 'gerente')).value.id
      go('mini_crm_revendas', @runner, 'crm.win_lead', { lead_id: bare }, as.call(manager, 'gerente'))
      @relay.relay!
      calls = @provider.keys.size
      worker.work('crm.notify_seller', limit: 1)[:done] == 1 && @provider.keys.size == calls
    end
    check('revendas: o vendedor não apaga o lead da revenda e o gerente apaga') do
      denied = go('mini_crm_revendas', @runner, 'crm.delete_lead', { id: lead }, as.call(seller, 'vendedor'))
      removed = go('mini_crm_revendas', @runner, 'crm.delete_lead', { id: lead }, as.call(manager, 'gerente'))
      !denied.ok? && removed.ok? && count('SELECT count(*) AS n FROM public.leads WHERE id = $1', [lead]).zero?
    end
    stop_relay
    close_all
  end

  # ---- Blog (global, sem RLS): o autor, a publicação e a recusa do comentário do visitante ---------------------------------

  def blog
    boot('blog', false)
    @authority = Vetra::Execution::InProcessAuthority.new
    @runner = runner_for(edge_with(@authority))
    author = SecureRandom.uuid
    autor = Vetra::Execution::Identity.new(actor_id: author, roles: ['blog.autor'])
    admin = Vetra::Execution::Identity.new(actor_id: SecureRandom.uuid, roles: ['blog.admin'])
    visitor = Vetra::Execution::Identity.new(actor_id: SecureRandom.uuid)
    post = nil

    check('blog: o autor cria, publica, lê e apaga o próprio post (a publicação usa o relógio e a guarda do estado final)') do
      created = go('blog', @runner, 'blog.create_post', { title: 'Post da sonda' }, autor)
      post = created.value&.id
      published = go('blog', @runner, 'blog.publish_post', { post_id: post }, autor)
      found = go('blog', @runner, 'blog.find_post', { post_id: post }, autor)
      row = rows('SELECT status, published_at FROM public.posts WHERE id = $1', [post]).first
      created.ok? && published.ok? && found.ok? && row['status'] == 'published' && !row['published_at'].nil?
    end
    check('blog: create_post com chave repete devolvendo o mesmo post sem segunda linha, e a mesma chave com outra entrada é recusada com 422') do
      first = go('blog', @runner, 'blog.create_post', { title: 'Com chave' }, autor, idempotency_key: 'k20-post-1')
      replay = go('blog', @runner, 'blog.create_post', { title: 'Com chave' }, autor, idempotency_key: 'k20-post-1')
      reused = go('blog', @runner, 'blog.create_post', { title: 'Outro título' }, autor, idempotency_key: 'k20-post-1')
      first.ok? && replay.ok? && replay.replayed? && replay.value == @runner.serialize('blog.create_post', first.value) &&
        count("SELECT count(*) AS n FROM public.posts WHERE title = 'Com chave'") == 1 &&
        !reused.ok? && reused.code == 'data_idempotency_key_reuse' && reused.http_status == 422 &&
        count("SELECT count(*) AS n FROM public.posts WHERE title = 'Outro título'").zero?
    end
    check('blog: publicar duas vezes vira Failure (422) e o estado não muda') do
      outcome = go('blog', @runner, 'blog.publish_post', { post_id: post }, autor)
      !outcome.ok? && outcome.http_status == 422 && rows('SELECT status FROM public.posts WHERE id = $1', [post]).first['status'] == 'published'
    end
    check('blog: o comentário do visitante é recusado por reserva de taxa não configurada nesta sonda, e nada é gravado (esperado; a sonda da C17 cobre a reserva configurada)') do
      outcome = go('blog', @runner, 'blog.create_comment',
                   { post_id: post, author_name: 'Visitante', author_email: 'v@probe.invalid', body: 'Texto do comentário' }, visitor)
      !outcome.ok? && outcome.code == 'data_rate_limit_unavailable' && count('SELECT count(*) AS n FROM public.comments').zero?
    end
    check('blog: o administrador comenta e aprova, e o comando aprova só o campo declarado') do
      created = go('blog', @runner, 'blog.create_comment',
                   { post_id: post, author_name: 'Admin', author_email: 'a@probe.invalid', body: 'Texto do comentário' }, admin)
      approved = go('blog', @runner, 'blog.approve_comment', { comment_id: created.value&.id }, admin)
      created.ok? && approved.ok? && rows('SELECT approved FROM public.comments WHERE id = $1', [created.value.id]).first['approved'] == 't'
    end
    check('blog: apagar o post com comentário é conflito 409 (chave estrangeira) e não muda nada; sem o comentário o autor apaga') do
      comment = rows('SELECT id FROM public.comments WHERE post_id = $1', [post]).first['id']
      blocked = go('blog', @runner, 'blog.delete_post', { id: post }, autor)
      cleared = go('blog', @runner, 'blog.delete_comment', { id: comment }, admin)
      deleted = go('blog', @runner, 'blog.delete_post', { id: post }, autor)
      !blocked.ok? && blocked.status == :conflict && blocked.http_status == 409 && cleared.ok? && deleted.ok? &&
        count('SELECT count(*) AS n FROM public.posts WHERE id = $1', [post]).zero?
    end
    check('blog: o visitante não lê nem o post publicado, porque crud scope: :author fecha a leitura (achado: o modelo do visitante é da rodada 6)') do
      published = go('blog', @runner, 'blog.create_post', { title: 'Publicado' }, autor).value.id
      go('blog', @runner, 'blog.publish_post', { post_id: published }, autor)
      hidden = go('blog', @runner, 'blog.find_post', { post_id: published }, visitor)
      !hidden.ok? && hidden.code == 'data_authorization_denied'
    end
    close_all
  end

  # ---- Chat (global, sem RLS): sala, vínculo por many_to_many, mensagens e a recusa de add_member_by_email ----------------

  def chat
    boot('chat', false)
    @authority = Vetra::Execution::InProcessAuthority.new
    @runner = runner_for(edge_with(@authority))
    ana, bia = SecureRandom.uuid, SecureRandom.uuid
    migration do
      { ana => 'ana', bia => 'bia' }.each do |user, name|
        @connection.exec_params('INSERT INTO public.users (id, name, email, created_at) VALUES ($1, $2, $3, transaction_timestamp())', [user, name, "#{name}@probe.invalid"])
      end
    end
    as = ->(user) { Vetra::Execution::Identity.new(actor_id: user, roles: ['chat.authenticated']) }
    room = nil

    check('chat: a dona cria a sala, escreve e lê a página da sala; a não membro é recusada') do
      created = go('chat', @runner, 'chat.create_room', { name: 'Geral' }, as.call(ana))
      room = created.value&.id
      posted = go('chat', @runner, 'chat.create_message', { room_id: room, body: 'Olá' }, as.call(ana))
      page = go('chat', @runner, 'chat.room_page', { room_id: room }, as.call(ana))
      denied = go('chat', @runner, 'chat.room_page', { room_id: room }, as.call(bia))
      created.ok? && posted.ok? && page.ok? && page.value[:messages].map(&:body) == ['Olá'] && !denied.ok? && denied.code == 'data_authorization_denied'
    end
    check('chat: add_member e remove_member mudam o que a Bia lê, e my_rooms mostra só as salas do ator (a sala reservada da Ana não aparece)') do
      reserved = go('chat', @runner, 'chat.create_room', { name: 'Reservada' }, as.call(ana)).value.id
      added = go('chat', @runner, 'chat.add_member', { room_id: room, user_id: bia }, as.call(ana))
      reads = go('chat', @runner, 'chat.read_room', { id: room }, as.call(bia))
      mine = go('chat', @runner, 'chat.my_rooms', {}, as.call(bia))
      hers = go('chat', @runner, 'chat.my_rooms', {}, as.call(ana))
      removed = go('chat', @runner, 'chat.remove_member', { room_id: room, user_id: bia }, as.call(ana))
      again = go('chat', @runner, 'chat.read_room', { id: room }, as.call(bia))
      added.ok? && reads.ok? && mine.ok? && mine.value.map(&:id) == [room] && hers.ok? && hers.value.map(&:id).sort == [room, reserved].sort &&
        removed.ok? && !again.ok?
    end
    check('chat: add_member_by_email é recusado no corpo, porque o uses não concede dados (esperado), e nada é gravado') do
      outcome = go('chat', @runner, 'chat.add_member_by_email', { room_id: room, email: 'bia@probe.invalid' }, as.call(ana))
      !outcome.ok? && outcome.code == 'data_authorization_denied' &&
        count('SELECT count(*) AS n FROM public.room_memberships WHERE room_id = $1', [room]) == 1
    end
    check('chat: a dona apaga a própria mensagem, e a sala não se apaga, porque o papel não concede delete de sala') do
      message = rows('SELECT id FROM public.messages WHERE room_id = $1', [room]).first['id']
      gone = go('chat', @runner, 'chat.delete_message', { id: message }, as.call(ana))
      closed = go('chat', @runner, 'chat.delete_room', { id: room }, as.call(ana))
      gone.ok? && !closed.ok? && closed.code == 'data_authorization_denied' && count('SELECT count(*) AS n FROM public.rooms WHERE id = $1', [room]) == 1
    end
    close_all
  end

  # As duas contagens do teste 1 do ADR-016 por comando: transações da operação (BEGIN do pool da aplicação) e da borda (pool
  # que lê os fatos antes da admissão). Uma recusa antes da operação tem zero na primeira e não tem zero na segunda.
  def report
    puts 'Contagens de transações por comando (ADR-016, teste 1): operação = BEGIN/COMMIT no pool da aplicação; borda = BEGIN no pool dos fatos'
    puts '| Exemplo | Comando | Resultado | BEGIN da operação | COMMIT da operação | BEGIN da borda |'
    puts '|---|---|---|---|---|---|'
    @table.each { |row| puts "| #{row.example} | #{row.operation} | #{row.outcome} | #{row.ops} | #{row.commits} | #{row.edge} |" }
    puts ''
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    exit(EndToEndProbe.new(ENV.fetch('DATABASE_URL')).run ? 0 : 1)
  rescue StandardError => error
    warn "FALHA: sonda ponta a ponta interrompida (#{error.class})."
    exit 1
  end
end

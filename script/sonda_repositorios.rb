#!/usr/bin/env ruby
# PostgreSQL 17/18 descartável, bootstrap ADR-036 pronto; DATABASE_URL administrativa.
# VETRA_APP_PASSWORD: senha do login real vetra_app, se necessária.
# Aplica os quatro planos como vetra_migrator. Não altera papéis, CI ou artefatos.
require_relative 'sonda_vetra_data'

class RepositoriesProbe < VetraDataProbe
  EXAMPLES = %w[mini_crm mini_crm_revendas blog chat].freeze
  OperationClock = ::Data.define(:now)

  class BusinessRefusal < StandardError
    attr_reader :field

    def initialize(field)
      @field = field
      super('Regra de negócio recusou a operação.')
    end
  end

  # Borda exclusiva da sonda: executa somente os corpos Ruby verificados pelo linker.
  # Não implementa authorize, primitivas builtin, eventos, histórico ou as oito etapas.
  class CallHost
    def fail!(field, _message)
      raise BusinessRefusal.new(field)
    end
  end

  def run
    @admin = PG.connect(@url)
    @admin.exec('SET client_min_messages = warning')
    @admin.exec(Vetra::SQL::Context.role_guard)
    before = roles
    EXAMPLES.each do |example|
      @example = example
      prepare_example(example)
      root = File.expand_path("../examples/#{example}", __dir__)
      @linked = Vetra::Graph::Compiler.new(root: root).link
      @catalog = Vetra::Data::Repositories.new(@linked.document)
      @executed = []
      open_runtime
      if example.start_with?('mini_crm')
        provision('runtime', @secret)
        issuer = Vetra::Data::ContextIssuer.new(kid: 'runtime', secret: @secret)
        @work = Vetra::Data::UnitOfWork.new(@runtime, issuer: issuer)
        crm_checks
      else
        @work = Vetra::Data::UnitOfWork.new(@runtime, scope: :global)
        example == 'blog' ? blog_checks : chat_checks
        check_case('contexto global não instalou token nem identidade SQL') do
          @runtime.context_installations.to_i.zero? && empty_context?
        end
      end
      check_case('todos os corpos call de comandos e consultas foram executados') do
        expected = @linked.bindings.select { |binding| binding['kind'] == 'ruby' && %w[command query].include?(binding.dig('operation', 'kind')) }
          .map { |binding| binding.dig('operation', 'id') }.sort
        @executed.uniq.sort == expected
      end
      check_case('nenhum statement nomeado foi criado no backend reutilizado') { @runtime[:pg_prepared_statements].count.zero? }
      check_case('conexão devolvida sem contexto após todas as operações') { empty_context? }
      close_runtime
    end
    check('nenhum papel global mudou') { roles == before }
    puts "#{@results.count(true)}/#{@results.size} verificações passaram (PostgreSQL #{@admin.server_version})."
    @results.all?
  ensure
    close_runtime
    if @admin
      @databases.reverse_each { |name| @admin.exec("DROP DATABASE IF EXISTS #{PG::Connection.quote_ident(name)} WITH (FORCE)") }
      @admin.close
    end
  end

  private

  def check_case(label, &block)
    check("#{@example}: #{label}", &block)
  end

  def within(cmd, tenant_index: 0, read: false, actor: @actor, &block)
    claims = { actor_id: actor, op_id: SecureRandom.uuid, cmd: cmd }
    if @example.start_with?('mini_crm')
      claims[:tenant_id] = @tenants.fetch(tenant_index)
      claims[:actor_id] = @actors.fetch(tenant_index) if actor == @actor
    end
    @work.public_send(read ? :read : :transaction, **claims, &block)
  end

  def repository(capability, unit = @work)
    @catalog.bind(capability, unit: unit)
  end

  def invoke(kind, id, attributes = {}, tenant_index: 0, actor: @actor)
    binding = @linked.binding_for(kind, id)
    raise 'A sonda executa apenas corpos Ruby' unless binding['kind'] == 'ruby'
    input = attributes.empty? ? nil : ::Data.define(*attributes.keys).new(**attributes)
    within(id, tenant_index: tenant_index, read: kind == 'query', actor: actor) do |unit|
      arguments = binding['arguments'].map do |argument|
        capability = argument.dig('capability', 'id')
        capability.end_with?('.clock') ? OperationClock.new(now: unit.now) : repository(capability, unit)
      end
      # O registro executável continua privado no produto. A sonda o acessa deliberadamente,
      # sem acrescentar uma porta pública de execução ao linker nesta entrega.
      implementation = @linked.instance_variable_get(:@implementations).fetch(binding['ref'])
      @executed << id
      CallHost.new.instance_exec(input, *arguments, &implementation)
    end
  end

  def business_refusal(field)
    yield
    false
  rescue BusinessRefusal => error
    error.field == field
  end

  def missing
    yield
    false
  rescue Vetra::Data::RecordNotFound => error
    error.code == 'data_record_not_found' && error.cause.nil?
  end

  def conflict(kind)
    yield
    false
  rescue Vetra::Data::Conflict => error
    error.code == 'data_conflict' && error.kind == kind && error.cause.nil?
  end

  def revendas?
    @example == 'mini_crm_revendas'
  end

  def crm_checks
    @tenants = [@tenant, SecureRandom.uuid]
    @actors = [@actor, SecureRandom.uuid]
    @leads, @dealers = [], []
    check_case('repositórios criam dois tenants e atribuem tenant/created_at sem entrada') do
      @tenants.each_index do |index|
        within('crm.create_lead', tenant_index: index) do
          company = repository('crm.companies').create!(name: 'Empresa da sonda')
          raise 'Tenant incorreto' unless company.id == @tenants[index]
          if revendas?
            repository('crm.users').create!(id: @actors[index], name: 'Vendedor', email: "actor#{index}@probe.invalid")
          end
        end
        @dealers[index] = seed_dealer(@tenants[index]) if revendas?
        within('crm.create_lead', tenant_index: index) do
          attributes = { name: 'Lead da sonda', valor: { amount: '123.45' } }
          if revendas?
            repository('crm.memberships').create!(user_id: @actors[index], dealer_id: @dealers[index], role: 'vendedor')
            attributes.merge!(dealer_id: @dealers[index], seller_id: @actors[index])
          end
          @leads[index] = repository('crm.leads').create!(**attributes)
          raise 'Tenant incorreto' unless @leads[index].company_id == @tenants[index]
        end
      end
      @leads.all? { |lead| lead.status == 'new' && lead.created_at.utc? && lead.valor.amount == BigDecimal('123.45') && Ractor.shareable?(lead) }
    end
    check_case('find, consulta e raiz só veem o tenant corrente nos dois sentidos') do
      @tenants.each_index.all? do |index|
        within('crm.read_lead', tenant_index: index, read: true) do
          repository('crm.leads_read').all.map(&:id) == [@leads[index].id] &&
            repository('crm.companies_read').all.map(&:id) == [@tenants[index]] &&
            missing { repository('crm.leads_read').find!(@leads[1 - index].id) }
        end
      end
    end
    check_case('ausente e invisível produzem o mesmo RecordNotFound') do
      within('crm.read_lead', read: true) do
        errors = [SecureRandom.uuid, @leads[1].id].map do |id|
          begin
            repository('crm.leads_read').find!(id)
          rescue Vetra::Data::RecordNotFound => error
            [error.class, error.code, error.message]
          end
        end
        errors.first && errors.first == errors.last
      end
    end
    check_case('update por objeto forjado não confia no tenant nem alcança outra empresa') do
      forged = @leads[1].with(company_id: @tenants[0])
      missing { within('crm.update_lead') { repository('crm.leads').update!(forged, name: 'Proibido') } }
    end
    check_case('tenant explícito e campo gerado são recusados') do
      within('crm.update_lead') do
        data_error('data_assignment') { repository('crm.leads').update!(@leads[0], company_id: @tenants[1]) } &&
          data_error('data_assignment') { repository('crm.leads').update!(@leads[0], created_at: Time.now) }
      end
    end
    check_case('transição fora do comando falha antes do UPDATE') do
      data_error('data_transition') { within('crm.update_lead') { repository('crm.leads').update!(@leads[0], status: 'won') } } &&
        within('crm.read_lead', read: true) { repository('crm.leads_read').find!(@leads[0].id).status == 'new' }
    end
    check_case('win_lead real trava e muda status com cmd assinado, e gera predicado closed?') do
      won = invoke('command', 'crm.win_lead', { lead_id: @leads[0].id })
      won.status == 'won' && won.closed? && Ractor.shareable?(won)
    end
    check_case('win_lead real recusa um lead já encerrado e desfaz a unidade') do
      business_refusal(:status) { invoke('command', 'crm.win_lead', { lead_id: @leads[0].id }) }
    end
    check_case('sair do valor guarded fora do comando também falha') do
      data_error('data_transition') { within('crm.update_lead') { repository('crm.leads').update!(@leads[0].id, status: 'new') } }
    end
    check_case('read e unidade READ ONLY recusam escrita e lock') do
      within('crm.read_lead', read: true) do
        data_error('data_read_only') { repository('crm.leads').update!(@leads[0].id, name: 'Proibido') } &&
          data_error('data_read_only') { repository('crm.leads_read').lock!(@leads[0].id) }
      end
    end
    check_case('unicidade da PK é Conflict sem detalhes do driver') do
      conflict(:unique) do
        within('crm.create_lead') do
          attributes = { id: @leads[0].id, name: 'Duplicado' }
          attributes[:dealer_id] = @dealers[0] if revendas?
          repository('crm.leads').create!(**attributes)
        end
      end
    end
    check_case('FK impede excluir raiz referenciada e vira Conflict') do
      conflict(:foreign_key) { within('crm.delete_company') { repository('crm.companies').delete!(@tenants[0]) } }
    end
    check_case('acesso fora da unidade é recusado') do
      data_error('data_transaction_required') { repository('crm.leads').all }
    end
    crm_scope_checks if revendas?
  end

  def seed_dealer(tenant_id)
    # O plano só concede SELECT em dealers: preparar a revenda é operação do migrador.
    # A raiz já foi confirmada; criar vínculos/leads e executar calls continua como vetra_app.
    id = SecureRandom.uuid
    @connection.exec('BEGIN; SET LOCAL SESSION AUTHORIZATION vetra_migrator')
    @connection.exec_params('INSERT INTO public.dealers (id, company_id, name, created_at) VALUES ($1, $2, $3, $4)',
                            [id, tenant_id, 'Revenda da sonda', Time.now.getutc.iso8601(6)])
    @connection.exec('COMMIT')
    id
  ensure
    @connection.exec('ROLLBACK') if @connection.transaction_status != PG::PQTRANS_IDLE
  end

  def crm_scope_checks
    outsider = SecureRandom.uuid
    hidden = nil
    check_case('escopo RLS: outro ator cria lead em revenda sem vínculo do primeiro') do
      within('crm.create_lead', actor: outsider) do
        repository('crm.users').create!(id: outsider, name: 'Outro vendedor', email: 'other@probe.invalid')
      end
      dealer_id = seed_dealer(@tenants.first)
      within('crm.create_lead', actor: outsider) do
        repository('crm.memberships').create!(user_id: outsider, dealer_id: dealer_id, role: 'vendedor')
        hidden = repository('crm.leads').create!(name: 'Lead oculto', dealer_id: dealer_id)
        hidden.id.is_a?(String)
      end
    end
    check_case('escopo RLS: find e update não alcançam lead de outra revenda no mesmo tenant') do
      missing { within('crm.read_lead', read: true) { repository('crm.leads_read').find!(hidden.id) } } &&
        missing { within('crm.update_lead') { repository('crm.leads').update!(hidden, name: 'Proibido') } }
    end
  end

  def blog_checks
    post = comment = nil
    check_case('create do blog atribui ator e defaults, mantendo published_at nulo') do
      within('blog.create_post') do
        post = repository('blog.posts').create!(title: 'Post da sonda')
        comment = repository('blog.comments').create!(post_id: post.id, author_name: 'Visitante', author_email: 'visitor@probe.invalid', body: 'Comentário')
        post.author_id == @actor && post.status == 'draft' && post.published_at.nil? && !comment.approved && Ractor.shareable?(post)
      end
    end
    check_case('find_post real consulta pelo repositório read em unidade READ ONLY de visitante') do
      invoke('query', 'blog.find_post', { post_id: post.id }, actor: nil) == post
    end
    check_case('set_by recusa aprovação e published_at fora dos comandos donos') do
      data_error('data_transition') { within('blog.update_comment') { repository('blog.comments').update!(comment.id, approved: true) } } &&
        data_error('data_transition') { within('blog.update_post') { repository('blog.posts').update!(post.id, published_at: Time.now.getutc.floor(6)) } }
    end
    check_case('publish_post real grava status e published_at usando o relógio da unidade') do
      published = invoke('command', 'blog.publish_post', { post_id: post.id })
      published.status == 'published' && published.published_at.is_a?(Time) && published.created_at == post.created_at && Ractor.shareable?(published)
    end
    check_case('publish_post real recusa segunda publicação') do
      business_refusal(:status) { invoke('command', 'blog.publish_post', { post_id: post.id }) }
    end
    check_case('approve_comment real usa update por ID e grava boolean protegido') do
      invoke('command', 'blog.approve_comment', { comment_id: comment.id }).approved
    end
    check_case('delete retorna valor removido e próxima busca é RecordNotFound') do
      removed = within('blog.delete_comment') { repository('blog.comments').delete!(comment) }
      removed.id == comment.id && removed.approved &&
        missing { within('blog.read_comment', read: true, actor: nil) { repository('blog.comments_read').find!(comment.id) } }
    end
    check_case('FK inexistente é Conflict, sem SQL ou valores na mensagem') do
      conflict(:foreign_key) do
        within('blog.create_comment', actor: nil) do
          repository('blog.comments').create!(post_id: SecureRandom.uuid, author_name: 'Visitante', author_email: 'visitor@probe.invalid', body: 'Sem post')
        end
      end
    end
  end

  def chat_checks
    room = owner = member = removable = nil
    check_case('usuários normalizam email e sala inclui o dono na mesma unidade') do
      within('chat.create_room') do
        owner = repository('chat.users').create!(id: @actor, name: 'Dono', email: 'OWNER@probe.invalid')
        member = repository('chat.users').create!(name: 'Membro', email: 'MEMBER@probe.invalid')
        removable = repository('chat.users').create!(name: 'Removível', email: 'other@probe.invalid')
        room = repository('chat.rooms').create!(name: 'Sala da sonda')
        owner.email == 'owner@probe.invalid' && room.owner_id == owner.id &&
          repository('chat.room_memberships_read').where(room_id: room.id, user_id: owner.id).all.size == 1
      end
    end
    check_case('add_member real cria vínculo e repetição é idempotente') do
      2.times { invoke('command', 'chat.add_member', { room_id: room.id, user_id: member.id }) }
      within('chat.read_room', read: true) { repository('chat.room_memberships_read').where(room_id: room.id, user_id: member.id).all.size == 1 }
    end
    check_case('add_member_by_email real usa where(email).first(2) e inclui usuário único') do
      invoke('command', 'chat.add_member_by_email', { room_id: room.id, email: 'other@probe.invalid' }).id == room.id
    end
    check_case('add_member_by_email real recusa email ausente') do
      business_refusal(:email) { invoke('command', 'chat.add_member_by_email', { room_id: room.id, email: 'absent@probe.invalid' }) }
    end
    check_case('remove_member real remove e repetição de vínculo ausente não falha') do
      2.times { invoke('command', 'chat.remove_member', { room_id: room.id, user_id: removable.id }) }
      within('chat.read_room', read: true) { repository('chat.room_memberships_read').where(room_id: room.id, user_id: removable.id).all.empty? }
    end
    check_case('remove_member real recusa remover o dono') do
      business_refusal(:user_id) { invoke('command', 'chat.remove_member', { room_id: room.id, user_id: owner.id }) }
    end
    check_case('repositório também preserva o vínculo obrigatório do dono') do
      data_error('data_required_link') { within('chat.remove_member') { repository('chat.rooms').remove_member!(room.id, owner.id) } }
    end
    check_case('alvo ausente é RecordNotFound antes de gravar vínculo') do
      missing { invoke('command', 'chat.add_member', { room_id: room.id, user_id: SecureRandom.uuid }) }
    end
    check_case('email normalizado duplicado é Conflict de unicidade') do
      conflict(:unique) { within('chat.create_user') { repository('chat.users').create!(name: 'Duplicado', email: 'OWNER@probe.invalid') } }
    end
    messages = []
    check_case('mensagens usam ator e relógio únicos por operação, com desempate pelo ID') do
      within('chat.create_message') do
        105.times do |index|
          messages << repository('chat.messages').create!(room_id: room.id, body: "Mensagem #{index}")
        end
        messages.map(&:created_at).uniq.size == 1 && messages.all? { |message| message.author_id == @actor }
      end
    end
    check_case('room_page real mantém ordem ascendente nas últimas 100 mensagens') do
      result = invoke('query', 'chat.room_page', { room_id: room.id })
      expected = messages.sort_by { |message| [message.created_at, message.id] }.last(100)
      result[:room] == room && result[:messages] == expected && result[:messages].frozen? && result[:messages].all? { |message| Ractor.shareable?(message) }
    end
    check_case('my_rooms real usa order(name).all com ID como desempate') do
      within('chat.create_room') do
        repository('chat.rooms').create!(name: 'AAA')
        repository('chat.rooms').create!(name: 'AAA')
      end
      rooms = invoke('query', 'chat.my_rooms')
      rooms.size == 3 && rooms == rooms.sort_by { |value| [value.name, value.id] }
    end
    check_case('consulta recusa campo desconhecido e bloco') do
      data_error('data_field') { repository('chat.messages_read').where(unknown: 'x') } &&
        data_error('data_query') { repository('chat.messages_read').where { true } }
    end
    check_case('capacidade read recusa vínculo mesmo em unidade gravável') do
      within('chat.add_member') do
        data_error('data_read_only') { repository('chat.rooms_read').add_member!(room.id, member.id) }
      end
    end
    check_case('vínculo e consulta guardam a unidade em cada terminal') do
      data_error('data_transaction_required') { repository('chat.rooms').add_member!(room.id, member.id) } &&
        data_error('data_transaction_required') { repository('chat.messages_read').where(room_id: room.id).last(1) }
    end
    concurrent_link_checks(room, member)
  end

  def concurrent_link_checks(room, member)
    check_case('duas conexões concorrentes incluem o mesmo vínculo sem duplicar') do
      within('chat.remove_member') { repository('chat.rooms').remove_member!(room.id, member.id) }
      race_link('add_member!', room, member) &&
        within('chat.read_room', read: true) { repository('chat.room_memberships_read').where(room_id: room.id, user_id: member.id).all.size == 1 }
    end
    check_case('duas conexões concorrentes removem o mesmo vínculo sem falhar') do
      race_link('remove_member!', room, member) &&
        within('chat.read_room', read: true) { repository('chat.room_memberships_read').where(room_id: room.id, user_id: member.id).all.empty? }
    end
  end

  def race_link(method, room, member)
    # A conexão principal segura o dono até o segundo backend entrar na operação.
    other = Vetra::Data.connect({ adapter: :postgres, host: @admin.host, hostaddr: @admin.hostaddr,
                                 port: @admin.port, database: @database_name,
                                 password: ENV.fetch('VETRA_APP_PASSWORD', '') }, max_connections: 1)
    ready = Queue.new
    thread = nil
    within("chat.#{method.delete_suffix('!')}") do
      repository('chat.rooms').lock!(room.id)
      thread = Thread.new do
        work = Vetra::Data::UnitOfWork.new(other, scope: :global)
        work.transaction(actor_id: @actor, op_id: SecureRandom.uuid, cmd: "chat.#{method.delete_suffix('!')}") do |unit|
          unit.access(multi_tenant: false) { |db| db.run("SET LOCAL lock_timeout = '5s'") }
          ready << other.get(Sequel.function(:pg_backend_pid))
          repository('chat.rooms', unit).public_send(method, room.id, member.id)
        end
        other[:pg_prepared_statements].count.zero?
      end
      thread.report_on_exception = false
      pid = ready.pop(timeout: 5)
      raise 'Segundo backend não iniciou a operação' unless pid
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 4
      loop do
        waiting = @connection.exec_params("SELECT wait_event_type = 'Lock' FROM pg_stat_activity WHERE pid = $1", [pid]).getvalue(0, 0) == 't'
        break if waiting
        raise 'Segundo backend não aguardou o lock do dono' if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        sleep 0.01
      end
      repository('chat.rooms').public_send(method, room.id, member.id)
    end
    thread.value
  ensure
    thread&.join(6)
    other&.disconnect
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    exit(RepositoriesProbe.new(ENV.fetch('DATABASE_URL')).run ? 0 : 1)
  rescue StandardError => error
    warn "FALHA: sonda de repositórios interrompida (#{error.class})."
    exit 1
  end
end

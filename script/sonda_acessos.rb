#!/usr/bin/env ruby
# PostgreSQL 17/18 descartável; DATABASE_URL administrativa e bootstrap ADR-036/C15 prontos.
# VETRA_APP_PASSWORD: senha do login real vetra_app, se necessária. Aplica os planos como vetra_migrator; não altera papéis.
#
# K18 (ADR-046): a autorização de cada acesso dos repositórios, a reautorização do estado final e o ramo de sistema, pelo
# Runner e em dois pools de vetra_app. O blog e o chat não têm RLS: dependem só desta guarda. Os CRMs têm RLS, e a guarda
# concorda com ele.
require_relative 'sonda_runner'

class AccessProbe < RunnerProbe
  def run
    @admin = PG.connect(@url)
    @admin.exec('SET client_min_messages = warning')
    @admin.exec(Vetra::SQL::Context.role_guard)
    before = roles
    chat
    blog
    revendas
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

  def count(sql, params = []) = sql_value(sql, params).first['n'].to_i

  def refused_with(runner, operation, input, identity)
    runner.run(operation, input, credentials: identity)
    nil
  rescue Vetra::Data::Error => error
    error
  end

  # ---- Chat: sem RLS, global ---------------------------------------------------------------------------------------

  def chat
    boot('chat', false)
    @authority = Vetra::Execution::InProcessAuthority.new
    runner = runner_for(edge_with(@authority))
    ana, bia = SecureRandom.uuid, SecureRandom.uuid
    rooms = [SecureRandom.uuid, SecureRandom.uuid]
    messages = [SecureRandom.uuid, SecureRandom.uuid]
    migration do
      { ana => 'ana', bia => 'bia' }.each do |user, name|
        @connection.exec_params('INSERT INTO public.users (id, name, email, created_at) VALUES ($1, $2, $3, transaction_timestamp())', [user, name, "#{name}@probe.invalid"])
      end
      [[rooms[0], ana, 'Sala da Ana'], [rooms[1], bia, 'Sala da Bia']].each do |room, owner, name|
        @connection.exec_params('INSERT INTO public.rooms (id, owner_id, name, created_at) VALUES ($1, $2, $3, transaction_timestamp())', [room, owner, name])
        @connection.exec_params('INSERT INTO public.room_memberships (room_id, user_id, created_at) VALUES ($1, $2, transaction_timestamp())', [room, owner])
      end
      [[messages[0], rooms[0], ana], [messages[1], rooms[1], bia]].each do |message, room, author|
        @connection.exec_params('INSERT INTO public.messages (id, room_id, author_id, body, created_at) VALUES ($1, $2, $3, $4, transaction_timestamp())', [message, room, author, 'Mensagem'])
      end
    end
    as = ->(user) { Vetra::Execution::Identity.new(actor_id: user, roles: ['chat.authenticated']) }

    check('chat: my_rooms devolve só as salas em que o ator é membro (a consulta é admitida pelo papel e filtrada por linha)') do
      outcome, ops_begins = measured(runner, 'chat.my_rooms', {}, as.call(ana))
      outcome.ok? && outcome.value.map(&:name) == ['Sala da Ana'] && ops_begins == 1
    end
    check('chat: room_page lê a sala e só as mensagens da sala; a sala alheia é recusada sem transação da operação') do
      own, = measured(runner, 'chat.room_page', { room_id: rooms[0] }, as.call(ana))
      outcome, ops_begins, _, edge_begins = measured(runner, 'chat.room_page', { room_id: rooms[1] }, as.call(ana))
      own.ok? && own.value[:messages].map(&:id) == [messages[0]] && own.value[:room].id == rooms[0] &&
        refused_without_operation_transaction?(outcome, 'data_authorization_denied', ops_begins, edge_begins)
    end
    check('chat: add_member_by_email é recusado no corpo, porque uses não concede leitura de chat.user, e nada é gravado') do
      error = refused_with(runner, 'chat.add_member_by_email', { room_id: rooms[0], email: 'bia@probe.invalid' }, as.call(ana))
      error&.code == 'data_authorization_denied' && count('SELECT count(*) AS n FROM public.room_memberships WHERE room_id = $1', [rooms[0]]) == 1
    end
    check('chat: add_member e remove_member mudam o que o membro novo lê (cada chamada é uma operação nova)') do
      denied_before, = measured(runner, 'chat.room_page', { room_id: rooms[0] }, as.call(bia))
      added, = measured(runner, 'chat.add_member', { room_id: rooms[0], user_id: bia }, as.call(ana))
      allowed, = measured(runner, 'chat.room_page', { room_id: rooms[0] }, as.call(bia))
      removed, = measured(runner, 'chat.remove_member', { room_id: rooms[0], user_id: bia }, as.call(ana))
      denied_after, = measured(runner, 'chat.room_page', { room_id: rooms[0] }, as.call(bia))
      !denied_before.ok? && added.ok? && allowed.ok? && removed.ok? && !denied_after.ok?
    end
    check('chat: quem não é dono não administra membros (a ação do vínculo é decidida sobre o dono)') do
      outcome, ops_begins = measured(runner, 'chat.add_member', { room_id: rooms[1], user_id: ana }, as.call(ana))
      !outcome.ok? && ops_begins.zero? && count('SELECT count(*) AS n FROM public.room_memberships WHERE room_id = $1', [rooms[1]]) == 1
    end
    check('chat: create_room cria a sala e o vínculo do dono, e o estado final é reautorizado') do
      outcome, ops_begins = measured(runner, 'chat.create_room', { name: 'Nova sala' }, as.call(ana))
      outcome.ok? && ops_begins == 1 &&
        count('SELECT count(*) AS n FROM public.room_memberships WHERE room_id = $1 AND user_id = $2', [outcome.value.id, ana]) == 1
    end
    with_chat_variant do |linked|
      variant = Vetra::Execution::Runner.new(linked: linked, catalog: Vetra::Data::Repositories.new(linked.document), unit: @ops_unit,
                                             edge: edge_with(@authority))
      check('chat: lida e escrita na mesma operação: depois de criar a sala e o vínculo do dono, os fatos lidos antes são descartados') do
        # O corpo lê a coleção (aquece o cache dos fatos), cria a sala (o vínculo do dono entra na junção) e relê a sala nova: só
        # passa se o cache da junção foi invalidado pela escrita da própria operação.
        outcome, = measured(variant, 'chat.create_and_read_room', { name: 'Lida na mesma operação' }, as.call(ana))
        outcome.ok? && outcome.value.name == 'Lida na mesma operação'
      end
    end
    close_all
  end

  # ---- Blog: sem RLS, global -----------------------------------------------------------------------------------------

  def blog
    boot('blog', false)
    @authority = Vetra::Execution::InProcessAuthority.new
    runner = runner_for(edge_with(@authority))
    author, other = SecureRandom.uuid, SecureRandom.uuid
    identity = Vetra::Execution::Identity.new(actor_id: author, roles: ['blog.autor'])
    created, = measured(runner, 'blog.create_post', { title: 'Post da sonda' }, identity)
    post = created.value&.id

    check('blog: o autor lê e altera o próprio post pelo Runner, com a guarda decidindo cada acesso') do
      read, = measured(runner, 'blog.read_post', { id: post }, identity)
      updated, = measured(runner, 'blog.update_post', { id: post, title: 'Renomeado' }, identity)
      created.ok? && read.ok? && updated.ok? && sql_value('SELECT title FROM public.posts WHERE id = $1', [post]).first['title'] == 'Renomeado'
    end
    check('blog: passar o post para outro autor é recusado no estado final, a escrita é desfeita e a geração é publicada') do
      generation = @authority.call
      clear_logs
      error = refused_with(runner, 'blog.update_post', { id: post, author_id: other }, identity)
      error&.code == 'data_authorization_final' && @ops_log.any? { |statement| statement.match?(ROLLBACK) } && @ops_log.none? { |statement| statement.match?(COMMIT) } &&
        sql_value('SELECT author_id FROM public.posts WHERE id = $1', [post]).first['author_id'] == author && @authority.call == generation + 1
    end
    check('blog: criar um post em nome de outro autor é recusado na admissão (linha candidata), sem transação da operação') do
      outcome, ops_begins, _, edge_begins = measured(runner, 'blog.create_post', { title: 'Em nome de outro', author_id: other }, identity)
      refused_without_operation_transaction?(outcome, 'data_authorization_denied', ops_begins, edge_begins) &&
        count('SELECT count(*) AS n FROM public.posts WHERE author_id = $1', [other]).zero?
    end
    check('blog: o post de outro autor não é lido pelo Runner (some, como sob RLS)') do
      migration do
        @connection.exec_params('INSERT INTO public.posts (id, author_id, title, status, created_at) VALUES ($1, $2, $3, $4, transaction_timestamp())',
                                [@foreign = SecureRandom.uuid, other, 'Alheio', 'draft'])
      end
      read, = measured(runner, 'blog.read_post', { id: @foreign }, identity)
      !read.ok? && read.code == 'data_authorization_denied'
    end
    close_all
  end

  # ---- CRM com revendas: RLS, revisão e ator de sistema ----------------------------------------------------------------

  def revendas
    boot('mini_crm_revendas', true)
    @authority = Vetra::Execution::DatabaseAuthority.new(db: @edge_db)
    runner = runner_for(edge_with(@authority))
    other_tenant = SecureRandom.uuid
    manager, seller = SecureRandom.uuid, SecureRandom.uuid
    dealer_a, dealer_b, lead, foreign_dealer, foreign_lead = Array.new(5) { SecureRandom.uuid }
    migration do
      [[@tenant, 'Empresa'], [other_tenant, 'Outra']].each do |tenant, name|
        @connection.exec_params('INSERT INTO public.companies (id, name, created_at) VALUES ($1, $2, transaction_timestamp())', [tenant, name])
      end
      [[manager, @tenant, 'm'], [seller, @tenant, 's']].each do |user, tenant, name|
        @connection.exec_params('INSERT INTO public.users (id, company_id, name, email, created_at) VALUES ($1, $2, $3, $4, transaction_timestamp())', [user, tenant, 'Pessoa', "#{name}@probe.invalid"])
      end
      [[dealer_a, @tenant], [dealer_b, @tenant], [foreign_dealer, other_tenant]].each do |dealer, tenant|
        @connection.exec_params('INSERT INTO public.dealers (id, company_id, name, created_at) VALUES ($1, $2, $3, transaction_timestamp())', [dealer, tenant, 'Revenda'])
      end
      [[lead, @tenant, dealer_a], [foreign_lead, other_tenant, foreign_dealer]].each do |id, tenant, dealer|
        @connection.exec_params('INSERT INTO public.leads (id, company_id, dealer_id, name, status, created_at) VALUES ($1, $2, $3, $4, $5, transaction_timestamp())',
                                [id, tenant, dealer, 'Cliente da sonda', 'new'])
      end
      @connection.exec_params('INSERT INTO public.memberships (company_id, dealer_id, user_id, role, created_at) VALUES ($1, $2, $3, $4, transaction_timestamp())', [@tenant, dealer_a, manager, 'gerente'])
      @connection.exec_params('INSERT INTO public.memberships (company_id, dealer_id, user_id, role, created_at) VALUES ($1, $2, $3, $4, transaction_timestamp())', [@tenant, dealer_a, seller, 'vendedor'])
    end
    as = ->(user, role) { Vetra::Execution::Identity.new(tenant_id: @tenant, actor_id: user, roles: ["crm.#{role}"]) }

    check('crm: trocar a revenda do lead para uma onde o gerente não tem vínculo é recusado, desfeito e o lead não muda (teste 4 do ADR-016)') do
      clear_logs
      error = refused_with(runner, 'crm.update_lead', { id: lead, dealer_id: dealer_b }, as.call(manager, 'gerente'))
      # O RLS (WITH CHECK) e a reautorização Ruby concordam; qualquer um dos dois recusa, e nada fica gravado.
      %w[data_access_denied data_authorization_final].include?(error&.code) && @ops_log.none? { |statement| statement.match?(COMMIT) } &&
        sql_value('SELECT dealer_id FROM public.leads WHERE id = $1', [lead]).first['dealer_id'] == dealer_a
    end
    check('crm: a alteração dentro da revenda do gerente passa pela guarda e pelo RLS') do
      outcome, ops_begins, ops_commits = measured(runner, 'crm.update_lead', { id: lead, name: 'Cliente alterado' }, as.call(manager, 'gerente'))
      outcome.ok? && ops_begins == 1 && ops_commits == 1
    end
    check('crm: o lead de outro tenant não é alcançado nem pelo comando com o id certo') do
      outcome, ops_begins = measured(runner, 'crm.update_lead', { id: foreign_lead, name: 'Invasão' }, as.call(manager, 'gerente'))
      !outcome.ok? && ops_begins.zero? && sql_value('SELECT name FROM public.leads WHERE id = $1', [foreign_lead]).first['name'] == 'Cliente da sonda'
    end
    check('crm: o vendedor lê o lead da revenda e não o apaga (a ação é decidida por papel e vínculo)') do
      read, = measured(runner, 'crm.read_lead', { id: lead }, as.call(seller, 'vendedor'))
      deleted, ops_begins = measured(runner, 'crm.delete_lead', { id: lead }, as.call(seller, 'vendedor'))
      read.ok? && !deleted.ok? && ops_begins.zero? && count('SELECT count(*) AS n FROM public.leads WHERE id = $1', [lead]) == 1
    end

    with_calling_handler do |linked|
      system_runner = Vetra::Execution::Runner.new(linked: linked, catalog: Vetra::Data::Repositories.new(linked.document), unit: @ops_unit,
                                                   edge: edge_with(@authority))
      system = Vetra::Execution::Identity.new(tenant_id: @tenant, system_actor: 'crm.notify_seller')
      check('crm: o ator de sistema executa o comando dos calls do seu handler, sem ler fatos de papéis, no tenant do evento') do
        outcome, ops_begins, _, edge_begins = measured(system_runner, 'crm.win_lead', { lead_id: lead }, system)
        outcome.ok? && ops_begins == 1 && edge_begins.zero? &&
          sql_value('SELECT status FROM public.leads WHERE id = $1', [lead]).first['status'] == 'won'
      end
      check('crm: o ator de sistema não alcança outro tenant (o RLS isola) nem comando fora dos calls') do
        error = refused_with(system_runner, 'crm.win_lead', { lead_id: foreign_lead }, system)
        outside, ops_begins = measured(system_runner, 'crm.delete_lead', { id: lead }, system)
        error&.code == 'data_record_not_found' && sql_value('SELECT status FROM public.leads WHERE id = $1', [foreign_lead]).first['status'] == 'new' &&
          !outside.ok? && outside.code == 'data_authorization_system_actor' && ops_begins.zero?
      end
    end
    close_all
  end

  # O chat numa cópia temporária com um comando que lê, escreve e relê na mesma operação: o modelo e o plano são os mesmos.
  def with_chat_variant
    Dir.mktmpdir('vetra-sonda-') do |directory|
      FileUtils.cp_r("#{File.expand_path('../examples/chat', __dir__)}/.", directory)
      FileUtils.rm_rf(File.join(directory, '.vetra'))
      FileUtils.rm_rf(File.join(directory, 'db'))
      File.write(File.join(directory, 'app/domains/chat/create_and_read_room.rb'), <<~RUBY)
        command :create_and_read_room do
          input :name, :string, max: 80
          returns :room
          authorize :create, :room
          uses :rooms

          call do |input, rooms|
            rooms.order(:name).all
            room = rooms.create!(name: input.name)
            rooms.find!(room.id)
          end
        end
      RUBY
      compiler = Vetra::Graph::Compiler.new(root: directory)
      compiler.write
      yield compiler.link
    end
  end

  # O CRM com revendas, numa cópia temporária cujo handler declara win_lead em calls: o modelo e o plano são os mesmos.
  def with_calling_handler
    Dir.mktmpdir('vetra-sonda-') do |directory|
      FileUtils.cp_r("#{File.expand_path('../examples/mini_crm_revendas', __dir__)}/.", directory)
      FileUtils.rm_rf(File.join(directory, '.vetra'))
      FileUtils.rm_rf(File.join(directory, 'db'))
      path = File.join(directory, 'app/domains/crm/notify_seller.rb')
      original = File.read(path)
      changed = original.sub(/^(\s*)uses :mailer\n/) { "#{Regexp.last_match(1)}uses :mailer\n#{Regexp.last_match(1)}calls :win_lead\n" }
      raise 'a sonda não reconheceu o handler notify_seller' if changed == original
      File.write(path, changed)
      compiler = Vetra::Graph::Compiler.new(root: directory)
      compiler.write
      yield compiler.link
    end
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    exit(AccessProbe.new(ENV.fetch('DATABASE_URL')).run ? 0 : 1)
  rescue StandardError => error
    warn "FALHA: sonda dos acessos interrompida (#{error.class})."
    exit 1
  end
end

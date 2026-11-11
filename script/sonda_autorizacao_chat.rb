#!/usr/bin/env ruby
# PostgreSQL 17/18 descartável; DATABASE_URL administrativa e bootstrap ADR-036/C15 prontos.
# VETRA_APP_PASSWORD: senha do login real vetra_app, se necessária. Não altera papéis ou artefatos.
# O chat não tem RLS: compara Ruby com EXISTS escrito à mão, sem usar o tradutor SQL de políticas.
require_relative 'sonda_runner'

class ChatAuthorizationProbe < RunnerProbe
  # As duas chaves são independentes: sala -> room_memberships.room_id -> users.id por user_id.
  ROOM_EXISTS = <<~SQL.freeze
    SELECT EXISTS (
      SELECT 1 FROM public.rooms AS room
      JOIN public.room_memberships AS membership ON membership.room_id = room.id
      JOIN public.users AS member ON member.id = membership.user_id
      WHERE room.id = ?::uuid AND member.id = ?::uuid
    ) AS allowed
  SQL
  MESSAGE_EXISTS = <<~SQL.freeze
    SELECT EXISTS (
      SELECT 1 FROM public.messages AS message
      JOIN public.rooms AS room ON room.id = message.room_id
      JOIN public.room_memberships AS membership ON membership.room_id = room.id
      JOIN public.users AS member ON member.id = membership.user_id
      WHERE message.id = ?::uuid AND member.id = ?::uuid
    ) AS allowed
  SQL

  def run
    @admin = PG.connect(@url)
    @admin.exec('SET client_min_messages = warning')
    @admin.exec(Vetra::SQL::Context.role_guard)
    before = roles
    boot('chat', false) # planos commitados, aplicados como vetra_migrator
    seed_chat
    @authority = Vetra::Execution::InProcessAuthority.new
    @edge = edge_with(@authority)
    @runner = runner_for(@edge)
    check('chat: login real vetra_app nos dois pools e tabelas sem RLS') do
      [@runtime, @edge_db].all? do |db|
        db.get(Sequel.lit('current_user')) == 'vetra_app' && db.get(Sequel.lit('session_user')) == 'vetra_app'
      end && @runtime.fetch(<<~SQL).all.all? { |row| !row[:relrowsecurity] && !row[:relforcerowsecurity] }
        SELECT relrowsecurity, relforcerowsecurity FROM pg_class
        WHERE oid IN ('public.rooms'::regclass, 'public.room_memberships'::regclass,
                      'public.users'::regclass, 'public.messages'::regclass)
      SQL
    end
    { owner: [true, false], member: [true, false], unlinked: [false, false], other: [false, true] }.each do |name, expected|
      %w[chat.read_room chat.read_message chat.create_message].each do |operation|
        @rooms.each_index do |index|
          check("chat: #{name}, #{operation}, sala #{index + 1}: Ruby e EXISTS SQL #{expected[index] ? 'permitem' : 'recusam'}") do
            ruby = ruby_decision(operation, name, index)
            sql = sql_decision(operation, name, index) # executa também quando Ruby recusa
            ruby.allowed? == expected[index] && sql == expected[index]
          end
        end
      end
    end
    check('chat: o provedor lê a junção inteira, incluindo os vínculos da outra sala') do
      request = request_for('chat.read_room', :member, 0)
      snapshot = @edge.snapshot(request)
      snapshot.rows('chat.room_membership').size == 3 && snapshot.rows('chat.user').size == 4
    end
    %w[chat.add_member chat.remove_member].each do |operation|
      check("chat: #{operation} publica depois do commit, invalida o snapshot e muda a decisão Ruby/SQL") do
        request = request_for('chat.read_room', :unlinked, 0)
        old = @edge.snapshot(request)
        marker = @authority.call
        seen = []
        observed = Observed.new(@authority, @ops_log, seen)
        runner = runner_for(edge_with(observed, @authority))
        outcome, = measured(runner, operation, { room_id: @rooms.first, user_id: @actors.fetch(:unlinked) }, identity(:owner))
        stale = @runner.authorization.check(request.operation_id, input: request.input, context: request.context,
                                             snapshot: old, current_revision: @edge.authority)
        expected = operation == 'chat.add_member'
        ruby = ruby_decision('chat.read_room', :unlinked, 0)
        sql = sql_decision('chat.read_room', :unlinked, 0)
        outcome.ok? && seen == [[true, false]] && @authority.call == marker + 1 &&
          stale.code == 'data_authorization_snapshot' && ruby.allowed? == expected && sql == expected
      end
    end
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

  def seed_chat
    @actors = %i[owner member unlinked other].to_h { |name| [name, SecureRandom.uuid] }
    @rooms, @messages = Array.new(2) { SecureRandom.uuid }, Array.new(2) { SecureRandom.uuid }
    migration do
      @actors.each do |name, actor|
        @connection.exec_params('INSERT INTO public.users (id, name, email, created_at) VALUES ($1, $2, $3, transaction_timestamp())',
                                [actor, 'Pessoa da sonda', "#{name}@probe.invalid"])
      end
      @rooms.each_with_index do |room, index|
        @connection.exec_params('INSERT INTO public.rooms (id, owner_id, name, created_at) VALUES ($1, $2, $3, transaction_timestamp())',
                                [room, @actors.fetch(:owner), "Sala #{index + 1}"])
        # Autor não membro da primeira sala: autoria não substitui members para ler/criar.
        @connection.exec_params('INSERT INTO public.messages (id, room_id, author_id, body, created_at) VALUES ($1, $2, $3, $4, transaction_timestamp())',
                                [@messages[index], room, @actors.fetch(:unlinked), 'Mensagem da sonda'])
      end
      [[:owner, 0], [:member, 0], [:other, 1]].each do |name, index|
        @connection.exec_params('INSERT INTO public.room_memberships (room_id, user_id, created_at) VALUES ($1, $2, transaction_timestamp())',
                                [@rooms[index], @actors.fetch(name)])
      end
    end
  end

  def identity(name)
    Vetra::Execution::Identity.new(actor_id: @actors.fetch(name), roles: ['chat.authenticated'])
  end

  def request_for(operation, name, index)
    input = case operation
    when 'chat.create_message' then { room_id: @rooms[index], body: 'Nova mensagem' }
    when 'chat.read_message' then { id: @messages[index] }
    else { id: @rooms[index] }
    end
    context = Vetra::Data::Context.new(scope: :global, tenant_id: nil, actor_id: @actors.fetch(name), op_id: SecureRandom.uuid, cmd: operation)
    Vetra::Execution::FactsRequest.new(authorization: @runner.authorization, operation_id: operation, context: context,
                                      roles: identity(name).roles, input: @runner.authorization.validate_input(operation, input))
  end

  def ruby_decision(operation, name, index)
    request = request_for(operation, name, index)
    @runner.authorization.check(operation, input: request.input, context: request.context,
                                 snapshot: @edge.snapshot(request), current_revision: @edge.authority)
  end

  # Somente SELECT pelo papel de produção; não depende do resultado Ruby e não altera as linhas comparadas.
  def sql_decision(operation, name, index)
    message = operation == 'chat.read_message'
    @ops_unit.read(actor_id: @actors.fetch(name), op_id: SecureRandom.uuid, cmd: operation) do |unit|
      unit.access(multi_tenant: false) do |db|
        db.fetch(message ? MESSAGE_EXISTS : ROOM_EXISTS, (message ? @messages : @rooms)[index], @actors.fetch(name)).get(:allowed)
      end
    end
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    exit(ChatAuthorizationProbe.new(ENV.fetch('DATABASE_URL')).run ? 0 : 1)
  rescue StandardError => error
    warn "FALHA: sonda de autorização do chat interrompida (#{error.class})."
    exit 1
  end
end

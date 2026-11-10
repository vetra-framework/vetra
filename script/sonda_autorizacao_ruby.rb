#!/usr/bin/env ruby
# PostgreSQL 17/18 descartável; DATABASE_URL administrativa e bootstrap ADR-036 prontos.
# VETRA_APP_PASSWORD: senha do login real vetra_app, se necessária.
# Aplica planos existentes como vetra_migrator. Não altera papéis, planos ou artefatos.
require_relative 'sonda_vetra_data'
require_relative '../lib/vetra/execution'

class RubyAuthorizationProbe < VetraDataProbe
  ACTIONS = %w[read create update delete].freeze
  # O RLS conhece os vínculos, não a atribuição externa de papéis Ruby. Nesta matriz, a borda fornece
  # exatamente os papéis desses vínculos, inclusive a união dos papéis do ator misto.
  SCENARIOS = {
    manager: { roles: ['crm.gerente'], allowed: [true, false, false] },
    seller: { roles: ['crm.vendedor'], allowed: [true, false, false] },
    mixed: { roles: %w[crm.gerente crm.vendedor], allowed: [true, true, false] },
    unlinked: { roles: %w[crm.gerente crm.vendedor], allowed: [false, false, false] }
  }.freeze

  def run
    @admin = PG.connect(@url)
    @admin.exec('SET client_min_messages = warning')
    @admin.exec(Vetra::SQL::Context.role_guard)
    before = roles
    prepare_example('mini_crm_revendas')
    provision('runtime', @secret)
    seed_authorization
    @engine = Vetra::Execution::Authorization.new(@schema.document)
    @catalog = Vetra::Data::Repositories.new(@schema.document)
    @issuer = Vetra::Data::ContextIssuer.new(kid: 'runtime', secret: @secret)
    open_runtime
    @work = Vetra::Data::UnitOfWork.new(@runtime, issuer: @issuer)
    check('login real de aplicação e contexto SQL com tenant e ator') do
      @runtime.get(Sequel.lit('current_user')) == 'vetra_app' &&
        @runtime.get(Sequel.lit('session_user')) == 'vetra_app' &&
        @work.read(**claims_for('read', :manager)) { identities == [@tenant, @actors.fetch(:manager)] }
    end
    load_facts
    SCENARIOS.each do |name, scenario|
      ACTIONS.each do |action|
        @leads.each_index do |index|
          expected = scenario[:allowed][index] && !(action == 'delete' && (name == :seller || (name == :mixed && index == 1)))
          check("#{name}, #{action}, revenda #{index + 1}: Ruby e RLS #{expected ? 'permitem' : 'recusam'}") do
            ruby_decision(action, name, index).allowed? == expected && sql_decision(action, name, index) == expected
          end
        end
      end
    end
    ACTIONS.each do |action|
      @leads.each_index do |index|
        expected = index == 2
        check("segundo tenant, #{action}, revenda #{index + 1}: Ruby e RLS #{expected ? 'permitem' : 'recusam'}") do
          ruby_decision(action, :foreign, index, tenant: @other_tenant).allowed? == expected &&
            sql_decision(action, :foreign, index, tenant: @other_tenant) == expected
        end
      end
    end
    check('atribuição de papel errada na borda é recusada em Ruby mesmo com vínculo de gerente') do
      # Não é comparação com RBAC SQL: o banco deliberadamente não conhece esses papéis (ADR-037).
      !ruby_decision('delete', :manager, 0, assigned_roles: ['crm.vendedor']).allowed?
    end
    transaction_checks
    revision_check
    check('nenhum papel global foi alterado') { roles == before }
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

  def migration
    @connection.exec('BEGIN; SET LOCAL SESSION AUTHORIZATION vetra_migrator')
    result = yield
    @connection.exec('COMMIT')
    result
  ensure
    @connection.exec('ROLLBACK') if @connection.transaction_status != PG::PQTRANS_IDLE
  end

  def seed_authorization
    @other_tenant = SecureRandom.uuid
    @actors = (SCENARIOS.keys + [:foreign]).to_h { |name| [name, SecureRandom.uuid] }
    @dealers, @leads = Array.new(3) { SecureRandom.uuid }, Array.new(3) { SecureRandom.uuid }
    migration do
      [@tenant, @other_tenant].each do |tenant|
        @connection.exec_params('INSERT INTO public.companies (id, name, created_at) VALUES ($1, $2, transaction_timestamp())', [tenant, 'Empresa da sonda'])
      end
      @actors.each do |name, actor|
        @connection.exec_params('INSERT INTO public.users (id, company_id, name, email, created_at) VALUES ($1, $2, $3, $4, transaction_timestamp())',
                                [actor, name == :foreign ? @other_tenant : @tenant, 'Ator da sonda', "#{name}@probe.invalid"])
      end
      [@tenant, @tenant, @other_tenant].each_with_index do |tenant, index|
        @connection.exec_params('INSERT INTO public.dealers (id, company_id, name, created_at) VALUES ($1, $2, $3, transaction_timestamp())',
                                [@dealers[index], tenant, 'Revenda da sonda'])
        @connection.exec_params('INSERT INTO public.leads (id, company_id, dealer_id, name, status, created_at) VALUES ($1, $2, $3, $4, $5, transaction_timestamp())',
                                [@leads[index], tenant, @dealers[index], 'Cliente da sonda', 'new'])
      end
      [[:manager, 0, 'gerente'], [:seller, 0, 'vendedor'], [:mixed, 0, 'gerente'],
       [:mixed, 1, 'vendedor'], [:foreign, 2, 'gerente']].each do |name, index, role|
        @connection.exec_params('INSERT INTO public.memberships (company_id, dealer_id, user_id, role, created_at) VALUES ($1, $2, $3, $4, transaction_timestamp())',
                                [name == :foreign ? @other_tenant : @tenant, @dealers[index], @actors.fetch(name), role])
      end
    end
  end

  # Resolução anterior à operação, isolada da medição de recusas. A sonda é sua própria borda confiável;
  # usar o migrador para preparar/ler fixtures não é uma recomendação de credencial para o runtime.
  def load_facts
    migration do
      @facts = {
        'crm.lead' => @connection.exec('SELECT id, company_id, dealer_id, name, status, seller_id FROM public.leads').to_a,
        'crm.dealer' => @connection.exec('SELECT id, company_id FROM public.dealers').to_a,
        'crm.membership' => @connection.exec('SELECT id, company_id, dealer_id, user_id, role FROM public.memberships').to_a
      }
      @revisions = @connection.exec('SELECT tenant_id, revision FROM vetra.authz_revisions').to_h { |row| [row['tenant_id'], row['revision'].to_i] }
    end
  end

  def claims_for(action, name, tenant: @tenant)
    { tenant_id: tenant, actor_id: @actors.fetch(name), op_id: SecureRandom.uuid, cmd: "crm.#{action}_lead" }
  end

  def ruby_decision(action, name, index, tenant: @tenant, assigned_roles: nil, input: nil)
    ctx = Vetra::Data::Context.new(scope: :tenant, **claims_for(action, name, tenant: tenant))
    assigned_roles ||= name == :foreign ? ['crm.gerente'] : SCENARIOS.fetch(name)[:roles]
    snapshot = @engine.snapshot(context: ctx, roles: assigned_roles, revision: @revisions.fetch(tenant), records: @facts)
    input ||= case action
    when 'create' then { name: 'Novo cliente', dealer_id: @dealers[index] }
    when 'update' then { id: @leads[index], name: 'Cliente alterado' }
    else { id: @leads[index] }
    end
    @engine.check(ctx.cmd, input: input, context: ctx, snapshot: snapshot, current_revision: ->(current) { @revisions.fetch(current.tenant_id) })
  end

  # Cada tentativa SQL é revertida, inclusive quando permitida: os dois avaliadores recebem os mesmos dados.
  # O teste executa também as tentativas recusadas pelo Ruby para comparar a barreira independente do banco.
  def sql_decision(action, name, index, tenant: @tenant)
    permitted = false
    @work.transaction(**claims_for(action, name, tenant: tenant)) do |unit|
      capability = action == 'read' ? 'crm.leads_read' : 'crm.leads'
      repo = @catalog.bind(capability, unit: unit)
      case action
      when 'read' then repo.find!(@leads[index])
      when 'create' then repo.create!(name: 'Novo cliente', dealer_id: @dealers[index])
      when 'update' then repo.update!(@leads[index], name: 'Cliente alterado')
      when 'delete' then repo.delete!(@leads[index])
      end
      permitted = true
      unit.rollback!
    end
    permitted
  rescue Sequel::Rollback
    permitted
  rescue Vetra::Data::Error => error
    raise unless %w[data_record_not_found data_access_denied].include?(error.code)
    false
  end

  # A contagem é a do pool do runtime, o único caminho de uma operação até o banco: o logger do Sequel vê todo BEGIN, COMMIT e
  # SAVEPOINT que a unidade abriria. O avaliador não recebe pool nem unidade, então qualquer SQL no pool durante as recusas
  # é uma violação. (O pg_stat_database foi descartado: as estatísticas são publicadas com atraso e não resolvem uma
  # transação isolada de forma confiável.)
  def transaction_checks
    statements = []
    logger = Object.new
    %i[info error warn debug].each { |level| logger.define_singleton_method(level) { |message| statements << message.to_s } }
    @runtime.loggers << logger
    check('recusas por papel, vínculo, revenda e entrada: zero SQL e zero transações da operação no pool') do
      statements.clear
      decisions = [ruby_decision('delete', :manager, 0, assigned_roles: []),
                   ruby_decision('read', :unlinked, 0), ruby_decision('update', :manager, 1),
                   ruby_decision('create', :manager, 0, input: { name: 'x', dealer_id: @dealers.first })]
      decisions.all? { |result| !result.allowed? } && statements.empty?
    end
    check('controle positivo: abrir a unidade acrescenta BEGIN e COMMIT ao pool') do
      statements.clear
      @work.transaction(**claims_for('update', :manager)) { nil }
      statements.any? { |message| message.include?('BEGIN') } && statements.any? { |message| message.include?('COMMIT') }
    end
  ensure
    @runtime.loggers.delete(logger) if logger
  end

  def revision_check
    ctx = Vetra::Data::Context.new(scope: :tenant, **claims_for('delete', :manager))
    previous = @revisions.fetch(@tenant)
    old_snapshot = @engine.snapshot(context: ctx, roles: ['crm.gerente'], revision: previous, records: @facts)
    migration do
      @connection.exec_params('DELETE FROM public.memberships WHERE company_id = $1 AND user_id = $2', [@tenant, @actors.fetch(:manager)])
    end
    load_facts
    check('commit da revogação incrementa revisão e recusa os fatos anteriores sem abrir unidade') do
      result = @engine.check(ctx.cmd, input: { id: @leads.first }, context: ctx, snapshot: old_snapshot,
                             current_revision: ->(current) { @revisions.fetch(current.tenant_id) })
      @revisions.fetch(@tenant) > previous && result.code == 'data_authorization_snapshot'
    end
    check('após atualizar os fatos, Ruby e RLS recusam o gerente revogado') do
      !ruby_decision('delete', :manager, 0).allowed? && !sql_decision('delete', :manager, 0)
    end
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    exit(RubyAuthorizationProbe.new(ENV.fetch('DATABASE_URL')).run ? 0 : 1)
  rescue StandardError => error
    warn "FALHA: sonda de autorização Ruby interrompida (#{error.class})."
    exit 1
  end
end

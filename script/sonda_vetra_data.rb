#!/usr/bin/env ruby
# PostgreSQL 17/18 descartável, superusuário e bootstrap do ADR-036 já executado.
# DATABASE_URL administrativa; VETRA_APP_PASSWORD para o login real de vetra_app, se necessário.
# Aplica os planos como vetra_migrator; não altera papéis ou artefatos e não imprime segredos.
require_relative 'sonda_contexto_assinado'
require_relative '../lib/vetra/data'

class VetraDataProbe < SignedContextProbe
  # Conta instruções, sem guardar SQL nem parâmetros sensíveis e sem ativar log do driver.
  module ContextCounter
    attr_reader :context_installations

    def execute(sql, opts = Sequel::OPTS, &block)
      @context_installations = context_installations.to_i + 1 if sql.include?('set_config')
      super
    end
  end

  def run
    @admin = PG.connect(@url)
    @admin.exec('SET client_min_messages = warning')
    @admin.exec(Vetra::SQL::Context.role_guard)
    before = roles
    prepare_example('mini_crm')
    provision('runtime', @secret)
    open_runtime
    @issuer = Vetra::Data::ContextIssuer.new(kid: 'runtime', secret: @secret)
    @work = Vetra::Data::UnitOfWork.new(@runtime, issuer: @issuer)
    tenant_checks
    close_runtime
    prepare_example('blog')
    open_runtime
    global_checks
    close_runtime
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

  def prepare_example(example)
    root = File.expand_path("../examples/#{example}", __dir__)
    document = Vetra::Graph::Compiler.new(root: root).read_artifact.document
    @schema = Vetra::SQL::Schema.new(document).generate
    # Os planos commitados, conferidos sem banco contra a IR e a cadeia: o inicial e os incrementais.
    @plans = Vetra::SQL::Planner.new(root: root).migration_plans
    @plan = @plans.first
    @connection = create_database
    @database_name = @databases.last
    check("#{example}: planos commitados aplicam como vetra_migrator sem poderes administrativos") do
      apply_as_migrator(@connection)
      true
    end
  end

  def open_runtime
    # Não herda usuário, senha, service/passfile nem options da conexão administrativa.
    @runtime = Vetra::Data.connect({ adapter: :postgres, host: @admin.host, hostaddr: @admin.hostaddr,
                                    port: @admin.port, database: @database_name,
                                    password: ENV.fetch('VETRA_APP_PASSWORD', '') }, max_connections: 1)
    @runtime.extend(ContextCounter)
  end

  def close_runtime
    @runtime&.disconnect
    @runtime = nil
    @connection&.close
    @connection = nil
  end

  def runtime_claims(**changes)
    { tenant_id: @tenant, actor_id: @actor, op_id: @operation, cmd: 'crm.create_lead' }.merge(changes)
  end

  def identities
    row = @runtime.select(Sequel.function(Sequel[:vetra][:current_tenant]).as(:tenant),
                          Sequel.function(Sequel[:vetra][:current_actor]).as(:actor)).first
    row.values_at(:tenant, :actor)
  end

  def empty_context?
    identities == [nil, nil] && [nil, ''].include?(@runtime.get(Sequel.function(:current_setting, 'vetra.ctx', true)))
  end

  def backend
    @runtime.get(Sequel.function(:pg_backend_pid))
  end

  def data_error(code)
    yield
    false
  rescue Vetra::Data::Error => error
    error.diagnostics.any? { |diagnostic| diagnostic.code == code }
  end

  def sqlstate(expected)
    yield
    false
  rescue Sequel::DatabaseError => error
    wrapped = error.wrapped_exception
    wrapped.respond_to?(:result) && wrapped.result&.error_field(PG::PG_DIAG_SQLSTATE) == expected
  end

  def tenant_checks
    check('pool conecta de fato como vetra_app, sem SET ROLE emprestado') do
      @runtime.get(Sequel.lit('current_user')) == 'vetra_app' &&
        @runtime.get(Sequel.lit('session_user')) == 'vetra_app'
    end
    check('sem unidade: identidades NULL e contexto ausente') { empty_context? }
    check('guarda recusa tabela multiempresa fora de transação antes de executar SQL') do
      data_error('data_transaction_required') { @work.access(multi_tenant: true) { raise 'Guarda não executada' } }
    end
    check('token emitido em Ruby tem MAC idêntico ao hmac das funções do banco') do
      token = @issuer.issue(**runtime_claims)
      parts = token.value.split('.')
      @connection.exec('BEGIN; SET LOCAL SESSION AUTHORIZATION vetra_migrator')
      expected = @connection.exec_params(<<~SQL, [parts.first(3).join('.'), @secret.unpack1('H*')]).getvalue(0, 0)
        SELECT encode(vetra_private.hmac(convert_to($1, 'UTF8'), decode($2, 'hex'), 'sha256'), 'hex')
      SQL
      supplied = (parts.last.tr('-_', '+/') + '=').unpack1('m0').unpack1('H*')
      @connection.exec('COMMIT')
      supplied == expected
    ensure
      @connection.exec('ROLLBACK') if @connection.transaction_status != PG::PQTRANS_IDLE
    end
    @backend = backend
    check('unidade instala tenant/ator assinados, na mesma conexão do pool de 1') do
      @work.transaction(**runtime_claims) { identities == [@tenant, @actor] && backend == @backend }
    end
    check('commit devolve a mesma conexão sem token e sem identidades') { backend == @backend && empty_context? }
    check('transação seguinte sem unidade na mesma conexão não herda contexto') do
      @runtime.transaction { backend == @backend && empty_context? }
    end
    @other_tenant = SecureRandom.uuid
    @leads = [SecureRandom.uuid, SecureRandom.uuid]
    check('duas unidades gravam raízes e leads de tenants distintos como aplicação') do
      [@tenant, @other_tenant].zip(@leads).all? do |tenant, lead|
        @work.transaction(**runtime_claims(tenant_id: tenant)) do |unit|
          unit.access(multi_tenant: true) do |db|
            db[:companies].insert(id: tenant, name: 'Sonda', created_at: Time.now)
            db[:leads].insert(id: lead, company_id: tenant, name: 'Lead da sonda', created_at: Time.now)
            db[:leads].select_map(:id) == [lead]
          end
        end
      end
    end
    check('RLS permite apenas o lead e a raiz do tenant corrente, nos dois sentidos') do
      [@tenant, @other_tenant].zip(@leads).all? do |tenant, lead|
        @work.read(**runtime_claims(tenant_id: tenant)) do |unit|
          unit.access(multi_tenant: true) { |db| db[:leads].select_map(:id) == [lead] && db[:companies].select_map(:id) == [tenant] }
        end
      end
    end
    check('RLS WITH CHECK recusa escrita com tenant alheio (42501)') do
      sqlstate('42501') do
        @work.transaction(**runtime_claims) do |unit|
          unit.access(multi_tenant: true) do |db|
            db[:leads].insert(id: SecureRandom.uuid, company_id: @other_tenant, name: 'Proibido', created_at: Time.now)
          end
        end
      end
    end
    check('savepoint faz rollback local, conserva contexto e não repete set_config') do
      initial = @runtime.context_installations
      @work.transaction(**runtime_claims) do |unit|
        begin
          unit.compose do
            unit.access(multi_tenant: true) { |db| db[:companies].where(id: @tenant).update(name: 'Desfazer') }
            unit.rollback!
          end
        rescue Sequel::Rollback
          # Resgate fora do savepoint: o bloco externo pode continuar.
        end
        unit.access(multi_tenant: true) { |db| db[:companies].get(:name) == 'Sonda' } &&
          identities == [@tenant, @actor] && @runtime.context_installations == initial + 1
      end
    end
    check('exceção desfaz a transação inteira e limpa o contexto') do
      failure = Class.new(StandardError)
      begin
        @work.transaction(**runtime_claims) do |unit|
          unit.access(multi_tenant: true) { |db| db[:companies].where(id: @tenant).update(name: 'Desfazer') }
          raise failure
        end
      rescue failure
        # A confirmação abaixo usa nova unidade na mesma conexão.
      end
      empty_context? && @work.read(**runtime_claims) { @runtime[:companies].get(:name) == 'Sonda' }
    end
    check('read_only é imposto pelo PostgreSQL e recusa UPDATE (25006)') do
      sqlstate('25006') do
        @work.read(**runtime_claims) { @runtime[:companies].where(id: @tenant).update(name: 'Proibido') }
      end && empty_context?
    end
    check('token expirado emitido pelo mesmo algoritmo retorna duas identidades NULL') do
      expired = Vetra::Data::ContextIssuer.new(kid: 'runtime', secret: @secret, clock: -> { Time.at(now - 60) })
      work = Vetra::Data::UnitOfWork.new(@runtime, issuer: expired)
      work.read(**runtime_claims) { identities == [nil, nil] && @runtime[:leads].count.zero? }
    end
    check('chave revogada retorna NULL na próxima instrução da unidade READ COMMITTED') do
      @work.transaction(**runtime_claims) do
        valid = identities == [@tenant, @actor]
        write_key("UPDATE vetra_private.keys SET status = 'revoked' WHERE kid = $1", ['runtime'])
        valid && identities == [nil, nil] && @runtime[:leads].count.zero?
      end
    ensure
      write_key("UPDATE vetra_private.keys SET status = 'active' WHERE kid = $1", ['runtime'])
    end
    check('protocolo não criou nenhum statement nomeado na conexão reutilizada') do
      backend == @backend && @runtime[:pg_prepared_statements].count.zero?
    end
  end

  def global_checks
    work = Vetra::Data::UnitOfWork.new(@runtime, scope: :global)
    post = SecureRandom.uuid
    check('blog global autenticado grava sem tenant, token ou chave provisionada') do
      work.transaction(actor_id: @actor, op_id: @operation, cmd: 'blog.create_post') do |unit|
        unit.access(multi_tenant: false) do |db|
          db[:posts].insert(id: post, author_id: unit.context.actor_id, title: 'Global', created_at: Time.now)
          db[:posts].get(:id) == post && identities == [nil, nil] && unit.context.tenant_id.nil?
        end
      end && @runtime.context_installations.to_i.zero? && empty_context?
    end
    check('visitante global consulta em read_only e compõe sem set_config') do
      work.read(op_id: @operation, cmd: 'blog.find_post') do |unit|
        unit.compose do
          unit.access(multi_tenant: false) do |db|
            db[:posts].get(:id) == post && unit.context.actor_id.nil? &&
              identities == [nil, nil] && db.get(Sequel.function(:current_setting, 'transaction_read_only')) == 'on'
          end
        end
      end && @runtime.context_installations.to_i.zero?
    end
    check('unidade global recusa tabela marcada como multiempresa') do
      work.read(op_id: @operation, cmd: 'blog.find_post') do |unit|
        data_error('data_scope') { unit.access(multi_tenant: true) { raise 'Escopo não conferido' } }
      end
    end
    check('global também não cria statement nomeado') { @runtime[:pg_prepared_statements].count.zero? }
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    exit(VetraDataProbe.new(ENV.fetch('DATABASE_URL')).run ? 0 : 1)
  rescue StandardError => error
    # Sem mensagem/cause do driver: podem carregar URL, token ou parâmetros.
    warn "FALHA: sonda Vetra Data interrompida (#{error.class})."
    exit 1
  end
end

#!/usr/bin/env ruby
# PostgreSQL 17+ descartável, superusuário e bootstrap Context.roles_sql já executado.
# Aplica planos como vetra_migrator, testa como vetra_app e remove somente seus bancos.
# DATABASE_URL=postgres://postgres@localhost/postgres bundle exec ruby script/sonda_rls_integridade.rb
require_relative 'sonda_contexto_assinado'
require 'tmpdir'
require 'fileutils'

class DatabaseSecurityProbe < SignedContextProbe
  def run
    @admin = PG.connect(@url)
    @admin.exec('SET client_min_messages = warning')
    @admin.exec(Vetra::SQL::Context.role_guard)
    before = roles
    %w[mini_crm mini_crm_revendas mini_crm_set_by].each do |example|
      @example = example
      prepare_plan(example)
      @connection = create_database
      check_case('plano aplica como migrador sem superusuário; guardas e REVOKEs são efetivos') do
        apply_as_migrator(@connection)
        @connection.exec(@authz)
        true
      end
      provision('first', @secret)
      seed
      isolation_checks
      transition_checks
      scope_checks if revendas?
      set_by_checks if example == 'mini_crm_set_by'
      @connection.close
      @connection = nil
    end
    check('nenhum papel global foi alterado pela aplicação dos três planos') { roles == before }
    puts "#{@results.count(true)}/#{@results.size} verificações passaram (PostgreSQL #{@admin.server_version})."
    @results.all?
  ensure
    @connection&.close
    if @admin
      @databases.reverse_each { |name| @admin.exec("DROP DATABASE IF EXISTS #{PG::Connection.quote_ident(name)} WITH (FORCE)") }
      @admin.close
    end
  end

  private

  def check_case(label, &block)
    check("#{@example}: #{label}", &block)
  end

  def prepare_plan(example)
    root = File.expand_path("../examples/#{example == 'mini_crm_set_by' ? 'mini_crm' : example}", __dir__)
    @document = if example == 'mini_crm_set_by'
      # Fixture adicional compilada, sem mudar os modelos versionados: set_by sem default e com default false.
      Dir.mktmpdir('vetra-set-by-') do |directory|
        FileUtils.cp_r("#{root}/.", directory)
        path = File.join(directory, 'app/domains/crm/lead.rb')
        source = File.read(path).sub('email :email', 'email :email, set_by: :win_lead')
          .sub('  crud', "  boolean :approved, default: false, set_by: :win_lead\n  crud")
        File.write(path, source)
        Vetra::Graph::Compiler.new(root: directory).build.document
      end
    else
      Vetra::Graph::Compiler.new(root: root).read_artifact.document
    end
    @schema = Vetra::SQL::Schema.new(@document).generate
    @plan = Vetra::SQL::Plan.initial(@schema)
    unless example == 'mini_crm_set_by'
      raise 'Plano versionado divergente' unless @plan.render == File.read(File.join(root, 'db/plans/0001_inicial.sql'), encoding: 'UTF-8')
    end
    @authz = Vetra::SQL::Authorization.new(@document).generate.statements
      .select { |sql| sql.match?(/\ADO \$vetra_(roles|tables|privileges|routines)\$/) }.join("\n")
    @other_tenant, @seller, @foreign_actor = Array.new(3) { SecureRandom.uuid }
    @dealers, @leads = Array.new(3) { SecureRandom.uuid }, Array.new(3) { SecureRandom.uuid }
  end

  def revendas?
    @example == 'mini_crm_revendas'
  end

  def migration
    @connection.exec('BEGIN; SET LOCAL SESSION AUTHORIZATION vetra_migrator')
    result = yield
    @connection.exec('COMMIT')
    result
  ensure
    @connection.exec('ROLLBACK') if @connection.transaction_status != PG::PQTRANS_IDLE
  end

  def seed
    migration do
      [@tenant, @other_tenant].each { |tenant| @connection.exec_params('INSERT INTO public.companies (id, name, created_at) VALUES ($1, $2, transaction_timestamp())', [tenant, 'Sonda']) }
      if revendas?
        [@tenant, @tenant, @other_tenant].zip(@dealers).each do |tenant, dealer|
          @connection.exec_params('INSERT INTO public.dealers (id, company_id, name, created_at) VALUES ($1, $2, $3, transaction_timestamp())', [dealer, tenant, 'Revenda'])
        end
        [@tenant, @tenant, @other_tenant].zip([@actor, @seller, @foreign_actor]).each do |tenant, actor|
          @connection.exec_params('INSERT INTO public.users (id, company_id, name, email, created_at) VALUES ($1, $2, $3, $4, transaction_timestamp())', [actor, tenant, 'Ator', 'ator@example.test'])
        end
        [[@actor, 'gerente'], [@seller, 'vendedor']].each do |actor, role|
          @connection.exec_params('INSERT INTO public.memberships (company_id, user_id, dealer_id, role, created_at) VALUES ($1, $2, $3, $4, transaction_timestamp())', [@tenant, actor, @dealers[0], role])
        end
        @connection.exec_params('INSERT INTO public.memberships (company_id, user_id, dealer_id, role, created_at) VALUES ($1, $2, $3, $4, transaction_timestamp())', [@other_tenant, @foreign_actor, @dealers[2], 'gerente'])
      end
      # O migrador pode inserir valores protegidos sem contexto, inclusive em enforce: db.
      [@tenant, @tenant, @other_tenant].zip(@leads, @dealers).each_with_index do |(tenant, lead, dealer), index|
        next if !revendas? && index == 1
        insert_lead(id: lead, tenant: tenant, dealer: dealer, status: index == 2 ? 'won' : 'new')
      end
    end
  end

  def app_context(changes = {})
    as_app do
      @connection.exec_params("SELECT set_config('vetra.ctx', $1, true)", [token(changes)])
      yield
    end
  end

  def insert_lead(id: SecureRandom.uuid, tenant: @tenant, dealer: @dealers[0], status: 'new', email: nil, seller: nil)
    columns = %w[id company_id name status email]
    values = [id, tenant, 'Lead da sonda', status, email]
    if revendas?
      columns += %w[dealer_id seller_id]
      values += [dealer, seller]
    end
    # Identificadores vêm da lista fixa acima; dados e segredos vão somente por parâmetros.
    quoted = columns.map { |name| PG::Connection.quote_ident(name) }.join(', ')
    params = (1..values.size).map { |index| "$#{index}" }.join(', ')
    @connection.exec_params("INSERT INTO public.leads (#{quoted}, created_at) VALUES (#{params}, transaction_timestamp())", values)
  end

  def scalar(sql, values = [])
    @connection.exec_params(sql, values).getvalue(0, 0)
  end

  def revision
    scalar('SELECT revision FROM vetra.authz_revisions WHERE tenant_id = $1', [@tenant]).to_i
  end

  def rejected_state(expected = '42501')
    yield
    false
  rescue PG::Error => error
    error.result&.error_field(PG::PG_DIAG_SQLSTATE) == expected
  end

  def isolation_checks
    check_case('todas as tabelas de tenant têm ENABLE e FORCE, inclusive companies') do
      scalar("SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'public' AND c.relkind = 'r' AND c.relrowsecurity AND c.relforcerowsecurity").to_i == @schema.tables.size
    end
    check_case('SELECT permitido vê lead próprio e raiz própria, sem outra revenda ou tenant') do
      app_context do
        scalar('SELECT count(*) FROM public.leads') == '1' &&
          scalar('SELECT id FROM public.leads') == @leads[0] && scalar('SELECT id FROM public.companies') == @tenant
      end
    end
    check_case('token do segundo tenant lê seu próprio lead e raiz, sem linhas do primeiro') do
      app_context('tenant_id' => @other_tenant, 'actor_id' => @foreign_actor) do
        scalar('SELECT id FROM public.leads') == @leads[2] && scalar('SELECT id FROM public.companies') == @other_tenant
      end
    end
    check_case('INSERT, UPDATE e DELETE permitidos incrementam a revisão uma vez cada') do
      app_context do
        initial = revision
        id = SecureRandom.uuid
        inserted = insert_lead(id: id).cmd_tuples == 1 && revision == initial + 1
        updated = @connection.exec_params('UPDATE public.leads SET name = $2 WHERE id = $1', [id, 'Nome atualizado']).cmd_tuples == 1 && revision == initial + 2
        deleted = @connection.exec_params('DELETE FROM public.leads WHERE id = $1', [id]).cmd_tuples == 1 && revision == initial + 3
        inserted && updated && deleted
      end
    end
    check_case('escrita na raiz própria é permitida e incrementa revisão') do
      app_context do
        initial = revision
        @connection.exec_params('UPDATE public.companies SET name = $2 WHERE id = $1', [@tenant, 'Raiz alterada']).cmd_tuples == 1 && revision == initial + 1
      end
    end
    check_case('outro tenant: SELECT vazio, UPDATE/DELETE zero linhas e revisão estável') do
      app_context do
        initial = revision
        scalar('SELECT count(*) FROM public.leads WHERE id = $1', [@leads[2]]) == '0' &&
          @connection.exec_params('UPDATE public.leads SET name = $2 WHERE id = $1', [@leads[2], 'Proibido']).cmd_tuples.zero? &&
          @connection.exec_params('DELETE FROM public.leads WHERE id = $1', [@leads[2]]).cmd_tuples.zero? && revision == initial
      end
    end
    check_case('INSERT com outro tenant falha 42501') { rejected_state { app_context { insert_lead(tenant: @other_tenant, dealer: @dealers[2]) } } }
    check_case('UPDATE que troca tenant falha 42501 pelo WITH CHECK') do
      rejected_state { app_context { @connection.exec_params('UPDATE public.leads SET company_id = $2 WHERE id = $1', [@leads[0], @other_tenant]) } }
    end
    check_case('raiz de outro tenant não é lida, alterada nem excluída') do
      app_context do
        scalar('SELECT count(*) FROM public.companies WHERE id = $1', [@other_tenant]) == '0' &&
          @connection.exec_params('UPDATE public.companies SET name = $2 WHERE id = $1', [@other_tenant, 'Proibido']).cmd_tuples.zero? &&
          @connection.exec_params('DELETE FROM public.companies WHERE id = $1', [@other_tenant]).cmd_tuples.zero?
      end
    end
    check_case('INSERT de raiz diferente falha 42501') do
      rejected_state { app_context { @connection.exec_params('INSERT INTO public.companies (id, name, created_at) VALUES ($1, $2, transaction_timestamp())', [SecureRandom.uuid, 'Proibida']) } }
    end
    [nil, 'v1.invalid.invalid.invalid'].each do |context|
      label = context ? 'token inválido' : 'sem contexto'
      check_case("#{label}: SELECT vazio em todas as tabelas; UPDATE e DELETE zero linhas") do
        as_app do
          @connection.exec_params("SELECT set_config('vetra.ctx', $1, true)", [context || ''])
          @schema.tables.all? do |table|
            path = table.values_at('schema', 'table').map { |part| PG::Connection.quote_ident(part) }.join('.')
            scalar("SELECT count(*) FROM #{path}") == '0'
          end && @connection.exec('UPDATE public.leads SET name = name').cmd_tuples.zero? &&
            @connection.exec('DELETE FROM public.leads').cmd_tuples.zero?
        end
      end
      check_case("#{label}: INSERT de lead e trigger recusam com 42501") do
        rejected_state do
          as_app do
            @connection.exec_params("SELECT set_config('vetra.ctx', $1, true)", [context || ''])
            insert_lead
          end
        end
      end
      check_case("#{label}: INSERT na raiz sem trigger também falha 42501") do
        rejected_state do
          as_app do
            @connection.exec_params("SELECT set_config('vetra.ctx', $1, true)", [context || ''])
            @connection.exec_params('INSERT INTO public.companies (id, name, created_at) VALUES ($1, $2, transaction_timestamp())', [SecureRandom.uuid, 'Proibida'])
          end
        end
      end
    end
    check_case('claim cmd adulterada sem reassinar não autoriza INSERT protegido') do
      parts = token.split('.')
      parts[2] = b64(JSON.generate(claims.merge('cmd' => 'crm.win_lead')))
      rejected_state do
        as_app do
          @connection.exec_params("SELECT set_config('vetra.ctx', $1, true)", [parts.join('.')])
          insert_lead(status: 'won')
        end
      end
    end
    check_case('rollback de escrita permitida desfaz também a revisão') do
      initial = scalar('SELECT revision FROM vetra.authz_revisions WHERE tenant_id = $1', [@tenant])
      app_context { insert_lead; true }
      scalar('SELECT revision FROM vetra.authz_revisions WHERE tenant_id = $1', [@tenant]) == initial
    end
    check_case('view security_invoker e função invoker preservam o isolamento e acesso permitido') do
      @connection.exec(<<~SQL)
        CREATE VIEW public.vt_probe_view WITH (security_invoker = true) AS SELECT id FROM public.leads;
        ALTER VIEW public.vt_probe_view OWNER TO vetra_owner;
        GRANT SELECT ON public.vt_probe_view TO vetra_app;
        CREATE FUNCTION public.vt_probe_read() RETURNS SETOF uuid LANGUAGE sql SECURITY INVOKER
          SET search_path = pg_catalog, pg_temp AS 'SELECT id FROM public.leads';
        ALTER FUNCTION public.vt_probe_read() OWNER TO vetra_owner;
        REVOKE ALL ON FUNCTION public.vt_probe_read() FROM PUBLIC;
        GRANT EXECUTE ON FUNCTION public.vt_probe_read() TO vetra_app;
      SQL
      app_context { scalar('SELECT id FROM public.vt_probe_view') == @leads[0] && scalar('SELECT count(*) FROM public.vt_probe_read()') == '1' }
    end
  end

  def transition_checks
    check_case('transição new -> contacted é permitida no comando genérico') do
      app_context { @connection.exec_params("UPDATE public.leads SET status = 'contacted' WHERE id = $1", [@leads[0]]).cmd_tuples == 1 }
    end
    check_case('INSERT won no comando genérico falha 42501') { rejected_state { app_context { insert_lead(status: 'won') } } }
    check_case('INSERT won pelo comando dono é permitido') { app_context('cmd' => 'crm.win_lead') { insert_lead(status: 'won').cmd_tuples == 1 } }
    check_case('UPDATE new -> won no comando genérico falha 42501') do
      rejected_state { app_context { @connection.exec_params("UPDATE public.leads SET status = 'won' WHERE id = $1", [@leads[0]]) } }
    end
    check_case('UPDATE new -> won pelo comando dono é permitido e incrementa revisão') do
      app_context('cmd' => 'crm.win_lead') do
        initial = revision
        @connection.exec_params("UPDATE public.leads SET status = 'won' WHERE id = $1", [@leads[0]]).cmd_tuples == 1 && revision == initial + 1
      end
    end
    check_case('sair de won pelo comando genérico falha 42501') do
      rejected_state do
        app_context('cmd' => 'crm.win_lead') do
          @connection.exec_params("UPDATE public.leads SET status = 'won' WHERE id = $1", [@leads[0]])
          @connection.exec_params("SELECT set_config('vetra.ctx', $1, true)", [token])
          @connection.exec_params("UPDATE public.leads SET status = 'lost' WHERE id = $1", [@leads[0]])
        end
      end
    end
    check_case('comando dono sai de won; não alterar status protegido permite edição comum') do
      app_context('cmd' => 'crm.win_lead') do
        @connection.exec_params("UPDATE public.leads SET status = 'won' WHERE id = $1", [@leads[0]])
        @connection.exec_params("SELECT set_config('vetra.ctx', $1, true)", [token])
        unchanged = @connection.exec_params("UPDATE public.leads SET status = 'won', name = $2 WHERE id = $1", [@leads[0], 'Edição comum']).cmd_tuples == 1
        @connection.exec_params("SELECT set_config('vetra.ctx', $1, true)", [token({ 'cmd' => 'crm.win_lead' })])
        unchanged && @connection.exec_params("UPDATE public.leads SET status = 'lost' WHERE id = $1", [@leads[0]]).cmd_tuples == 1
      end
    end
    check_case('somente o migrador pode gravar protegido sem contexto') do
      migration { @connection.exec_params("UPDATE public.leads SET status = 'won' WHERE id = $1", [@leads[0]]).cmd_tuples == 1 }
    ensure
      migration { @connection.exec_params("UPDATE public.leads SET status = 'new' WHERE id = $1", [@leads[0]]) }
    end
  end

  def scope_checks
    check_case('ator vendedor lê e insere na sua revenda') do
      app_context('actor_id' => @seller) { scalar('SELECT id FROM public.leads') == @leads[0] && insert_lead.cmd_tuples == 1 }
    end
    check_case('vendedor não exclui; gerente exclui na mesma revenda') do
      app_context('actor_id' => @seller) { @connection.exec_params('DELETE FROM public.leads WHERE id = $1', [@leads[0]]).cmd_tuples.zero? } &&
        app_context { @connection.exec_params('DELETE FROM public.leads WHERE id = $1', [@leads[0]]).cmd_tuples == 1 }
    end
    check_case('outra revenda do mesmo tenant: SELECT, UPDATE e DELETE sem acesso') do
      app_context do
        scalar('SELECT count(*) FROM public.leads WHERE id = $1', [@leads[1]]) == '0' &&
          @connection.exec_params('UPDATE public.leads SET name = name WHERE id = $1', [@leads[1]]).cmd_tuples.zero? &&
          @connection.exec_params('DELETE FROM public.leads WHERE id = $1', [@leads[1]]).cmd_tuples.zero?
      end
    end
    check_case('INSERT em outra revenda do mesmo tenant falha 42501') { rejected_state { app_context { insert_lead(dealer: @dealers[1]) } } }
    check_case('trocar lead para outra revenda falha 42501 pelo WITH CHECK') do
      rejected_state { app_context { @connection.exec_params('UPDATE public.leads SET dealer_id = $2 WHERE id = $1', [@leads[0], @dealers[1]]) } }
    end
    check_case('FK composta recusa seller de outro tenant com 23503; seller próprio é permitido') do
      app_context { insert_lead(seller: @seller).cmd_tuples == 1 } &&
        rejected_state('23503') { app_context { insert_lead(seller: @foreign_actor) } }
    end
    check_case('segundo vínculo amplia escopo no mesmo tenant e incrementa revisão; rollback desfaz') do
      app_context do
        initial = revision
        @connection.exec_params('INSERT INTO public.memberships (company_id, user_id, dealer_id, role, created_at) VALUES ($1, $2, $3, $4, transaction_timestamp())', [@tenant, @actor, @dealers[1], 'gerente'])
        revision == initial + 1 && scalar('SELECT count(*) FROM public.leads') == '2'
      end && app_context { scalar('SELECT count(*) FROM public.leads') == '1' }
    end
    check_case('ator sem vínculos não lê leads, mas contexto válido ainda lê a raiz') do
      app_context('actor_id' => SecureRandom.uuid) { scalar('SELECT count(*) FROM public.leads') == '0' && scalar('SELECT id FROM public.companies') == @tenant }
    end
  end

  def set_by_checks
    check_case('set_by: INSERT aceita ausência, NULL e default false') { app_context { insert_lead.cmd_tuples == 1 } }
    check_case('set_by: INSERT de email protegido no comando genérico falha 42501') { rejected_state { app_context { insert_lead(email: 'novo@example.test') } } }
    check_case('set_by: INSERT de email pelo dono é permitido') { app_context('cmd' => 'crm.win_lead') { insert_lead(email: 'novo@example.test').cmd_tuples == 1 } }
    check_case('set_by: INSERT true no genérico falha 42501') do
      rejected_state { app_context { @connection.exec_params('INSERT INTO public.leads (company_id, name, approved, created_at) VALUES ($1, $2, true, transaction_timestamp())', [@tenant, 'Protegido']) } }
    end
    check_case('set_by: INSERT true pelo dono é permitido') do
      app_context('cmd' => 'crm.win_lead') { @connection.exec_params('INSERT INTO public.leads (company_id, name, approved, created_at) VALUES ($1, $2, true, transaction_timestamp())', [@tenant, 'Protegido']).cmd_tuples == 1 }
    end
    check_case('set_by: UPDATE de NULL para email no genérico falha 42501') do
      rejected_state { app_context { @connection.exec_params('UPDATE public.leads SET email = $2 WHERE id = $1', [@leads[0], 'novo@example.test']) } }
    end
    check_case('set_by: UPDATE para true no genérico falha 42501') do
      rejected_state { app_context { @connection.exec_params('UPDATE public.leads SET approved = true WHERE id = $1', [@leads[0]]) } }
    end
    check_case('set_by: dono altera email e boolean; genérico pode conservar ambos') do
      app_context('cmd' => 'crm.win_lead') do
        changed = @connection.exec_params('UPDATE public.leads SET email = $2, approved = true WHERE id = $1', [@leads[0], 'novo@example.test']).cmd_tuples == 1
        @connection.exec_params("SELECT set_config('vetra.ctx', $1, true)", [token])
        changed && @connection.exec_params('UPDATE public.leads SET email = email, approved = approved WHERE id = $1', [@leads[0]]).cmd_tuples == 1
      end
    end
    check_case('set_by: limpar email protegido para NULL no genérico falha 42501') do
      rejected_state do
        app_context('cmd' => 'crm.win_lead') do
          @connection.exec_params('UPDATE public.leads SET email = $2 WHERE id = $1', [@leads[0], 'novo@example.test'])
          @connection.exec_params("SELECT set_config('vetra.ctx', $1, true)", [token])
          @connection.exec_params('UPDATE public.leads SET email = NULL WHERE id = $1', [@leads[0]])
        end
      end
    end
    check_case('set_by: migrador altera campos protegidos sem contexto') do
      migration { @connection.exec_params('UPDATE public.leads SET email = $2, approved = true WHERE id = $1', [@leads[0], 'migracao@example.test']).cmd_tuples == 1 }
    end
  end
end

if $PROGRAM_NAME == __FILE__
  exit(DatabaseSecurityProbe.new(ENV.fetch('DATABASE_URL')).run ? 0 : 1)
end

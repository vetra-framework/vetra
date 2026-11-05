#!/usr/bin/env ruby
# Requer PostgreSQL 17+ descartável, superusuário e bootstrap Context.roles_sql já executado.
# Cria/remove dois bancos próprios; não cria, altera nem remove papéis globais. Não imprime segredos/tokens.
# DATABASE_URL=postgres://postgres@localhost/postgres bundle exec ruby script/sonda_contexto_assinado.rb
require 'bundler/setup'
require 'pg'
require 'openssl'
require 'securerandom'
require_relative '../lib/vetra'

class SignedContextProbe
  def initialize(url)
    @url, @databases, @results = url, [], []
    @tenant, @actor, @operation = Array.new(3) { SecureRandom.uuid }
    @secret = SecureRandom.random_bytes(32)
    @document = Vetra::Graph::Compiler.new(root: File.expand_path('../examples/mini_crm_revendas', __dir__)).read_artifact.document
    @schema = Vetra::SQL::Schema.new(@document).generate
    @plan = Vetra::SQL::Plan.initial(@schema)
    # A sonda confere também o artefato que será aplicado por --snapshot/--check.
    raise 'Plano do exemplo divergente' unless @plan.render == File.read(File.expand_path('../examples/mini_crm_revendas/db/plans/0001_inicial.sql', __dir__), encoding: 'UTF-8')
    # A infraestrutura já pertence ao plano; reexecuta somente as guardas, depois das mutações.
    @authz = Vetra::SQL::Authorization.new(@document).generate.statements
      .select { |sql| sql.match?(/\ADO \$vetra_(roles|tables|privileges|routines)\$/) }.join("\n")
  end

  def run
    @admin = PG.connect(@url)
    @admin.exec('SET client_min_messages = warning')
    @admin.exec(Vetra::SQL::Context.role_guard)
    before = roles
    @connection = create_database
    check('migrador aplica o plano inicial em dois bancos próprios sem superusuário nem mudanças globais') do
      apply_as_migrator(@connection)
      second = create_database
      begin
        apply_as_migrator(second)
        roles == before && @connection.exec('SELECT count(*) FROM vetra_private.keys').getvalue(0, 0) == '0'
      ensure
        second.close
      end
    end
    check('papéis têm todos os atributos e vínculos do ADR-036') { @connection.exec(Vetra::SQL::Context.role_guard); true }
    check('schemas e tabelas pertencem a vetra_owner; nenhuma tabela pertence à aplicação') do
      @connection.exec(<<~SQL).getvalue(0, 0) == 't'
        SELECT bool_and(pg_get_userbyid(nspowner) = 'vetra_owner')
          AND (SELECT bool_and(pg_get_userbyid(c.relowner) = 'vetra_owner')
            FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname IN ('public', 'vetra_private') AND c.relkind = 'r')
        FROM pg_namespace WHERE nspname IN ('public', 'vetra', 'vetra_private')
      SQL
    end
    check('funções geradas passam pela identidade exata da guarda C2') do
      @connection.exec("SELECT count(*) FROM pg_proc p WHERE #{Vetra::SQL::Context.trusted_routine_sql}").getvalue(0, 0) == '2'
    end
    check('vetra_app recebe os quatro privilégios DML e nenhum TRUNCATE/TRIGGER/REFERENCES') do
      @schema.tables.all? do |table|
        relation = table.values_at('schema', 'table').map { |part| PG::Connection.quote_ident(part) }.join('.')
        @connection.exec_params(<<~SQL, [relation]).getvalue(0, 0) == 't'
          SELECT has_table_privilege('vetra_app', $1, 'SELECT') AND has_table_privilege('vetra_app', $1, 'INSERT')
            AND has_table_privilege('vetra_app', $1, 'UPDATE') AND has_table_privilege('vetra_app', $1, 'DELETE')
            AND NOT has_table_privilege('vetra_app', $1, 'TRUNCATE,TRIGGER,REFERENCES')
            AND NOT has_any_column_privilege('vetra_app', $1, 'REFERENCES')
        SQL
      end
    end
    check('vetra_app usa public/vetra, sem CREATE ou TEMPORARY e sem vetra_private') do
      @connection.exec(<<~SQL).getvalue(0, 0) == 't'
        SELECT has_schema_privilege('vetra_app', 'public', 'USAGE') AND has_schema_privilege('vetra_app', 'vetra', 'USAGE')
          AND NOT has_schema_privilege('vetra_app', 'public', 'CREATE') AND NOT has_schema_privilege('vetra_app', 'vetra', 'CREATE')
          AND NOT has_schema_privilege('vetra_app', 'vetra_private', 'USAGE,CREATE')
          AND NOT has_database_privilege('vetra_app', current_database(), 'CREATE,TEMPORARY')
      SQL
    end
    check('vetra_app alcança somente as duas funções Vetra de contexto') do
      @connection.exec(<<~SQL).getvalue(0, 0) == '2'
        SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
          WHERE n.nspname IN ('vetra', 'vetra_private') AND has_schema_privilege('vetra_app', n.oid, 'USAGE')
            AND has_function_privilege('vetra_app', p.oid, 'EXECUTE')
      SQL
    end
    check('membros de pgcrypto conservam EXECUTE público, são invokers e estão no schema privado') do
      @connection.exec(<<~SQL).getvalue(0, 0) == 't'
        SELECT count(*) > 0 AND bool_and(NOT p.prosecdef AND n.nspname = 'vetra_private'
          AND has_function_privilege('vetra_app', p.oid, 'EXECUTE')
          AND has_function_privilege('vetra_owner', p.oid, 'EXECUTE')
          AND NOT has_schema_privilege('vetra_app', n.oid, 'USAGE'))
        FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
          JOIN pg_depend d ON d.classid = 'pg_proc'::regclass AND d.objid = p.oid AND d.deptype = 'e'
          JOIN pg_extension e ON d.refclassid = 'pg_extension'::regclass AND d.refobjid = e.oid
        WHERE e.extname = 'pgcrypto'
      SQL
    end
    check('DML de vetra_app funciona dentro do tenant com o RLS do plano') do
      provision('dml', @secret)
      as_app do
        @connection.exec_params("SELECT set_config('vetra.ctx', $1, true)", [token({}, kid: 'dml')])
        @connection.exec_params('INSERT INTO public.companies (id, name, created_at) VALUES ($1, $2, transaction_timestamp())', [@tenant, 'Sonda'])
        found = @connection.exec_params('SELECT id FROM public.companies WHERE id = $1', [@tenant]).getvalue(0, 0) == @tenant
        updated = @connection.exec_params('UPDATE public.companies SET name = $2 WHERE id = $1', [@tenant, 'Alterada']).cmd_tuples == 1
        deleted = @connection.exec_params('DELETE FROM public.companies WHERE id = $1', [@tenant]).cmd_tuples == 1
        found && updated && deleted
      end
    ensure
      write_key("DELETE FROM vetra_private.keys WHERE kid = 'dml'")
    end
    {
      'leitura de keys' => 'SELECT * FROM vetra_private.keys',
      'escrita de keys' => 'DELETE FROM vetra_private.keys',
      'EXECUTE de hmac' => "SELECT vetra_private.hmac('x'::bytea, 'y'::bytea, 'sha256')",
      'CREATE em public' => 'CREATE TABLE public.forbidden (id integer)',
      'CREATE temporário' => 'CREATE TEMP TABLE forbidden (id integer)',
      'TRUNCATE' => 'TRUNCATE public.companies',
      'DDL em tabela' => 'ALTER TABLE public.companies ADD COLUMN forbidden integer',
      'SET ROLE vetra_owner' => 'SET LOCAL ROLE vetra_owner',
      'SET ROLE vetra_migrator' => 'SET LOCAL ROLE vetra_migrator'
    }.each { |label, sql| check("vetra_app não consegue #{label}") { denied(sql) } }
    check('sem contexto retorna NULL para ambas as identidades') { identity(nil) == [nil, nil] }
    check('token assinado sem chave provisionada retorna NULL') { identity(token) == [nil, nil] }
    provision('first', @secret)
    check('token válido retorna tenant e ator assinados') { identity(token) == [@tenant, @actor] }
    check('emissão até cinco segundos no futuro é aceita') { identity(token({ 'iat' => now + 4, 'exp' => now + 34 })) == [@tenant, @actor] }
    check('validade de 120 segundos é aceita') { identity(token({ 'exp' => now + 120 })) == [@tenant, @actor] }
    check('token expirado retorna NULL') { identity(token({ 'iat' => now - 31, 'exp' => now - 1 })) == [nil, nil] }
    check('token futuro além da tolerância retorna NULL') { identity(token({ 'iat' => now + 20, 'exp' => now + 50 })) == [nil, nil] }
    check('validade maior que 120 segundos retorna NULL') do
      issued = now
      identity(token({ 'iat' => issued, 'exp' => issued + 121 })) == [nil, nil]
    end
    check('exp anterior a iat retorna NULL') { identity(token({ 'exp' => now - 1 })) == [nil, nil] }
    check('kid desconhecido retorna NULL') { identity(token({}, kid: 'unknown')) == [nil, nil] }
    [0, 15, 31].each do |index|
      check("MAC adulterado no byte #{index} retorna NULL") do
        parts = token.split('.')
        mac = (parts.last.tr('-_', '+/') + '=').unpack1('m0')
        mac.setbyte(index, mac.getbyte(index) ^ 1)
        parts[-1] = b64(mac)
        identity(parts.join('.')) == [nil, nil]
      end
    end
    check('payload adulterado sem reassinar retorna NULL') do
      parts = token.split('.')
      parts[2] = b64(JSON.generate(claims.merge('tenant_id' => SecureRandom.uuid)))
      identity(parts.join('.')) == [nil, nil]
    end
    ['', 'v2.x.y.z', 'v1.x.!.!', 'v1.x.a.a.extra', 'a' * 8193].each_with_index do |invalid, index|
      check("token malformado #{index + 1} retorna NULL") { identity(invalid) == [nil, nil] }
    end
    [{ 'tenant_id' => nil }, { 'actor_id' => 1 }, { 'op_id' => 'bad' }, { 'cmd' => '' }, { 'cmd' => nil },
     { 'iat' => now.to_s }, { 'iat' => now + 0.5 }, { 'exp' => nil }, { 'operator_id' => 'bad' }].each_with_index do |changes, index|
      check("claims assinados inválidos #{index + 1} retornam NULL") { identity(token(changes)) == [nil, nil] }
    end
    check('payload não JSON, mesmo assinado, retorna NULL') { identity(sign(b64('not json'))) == [nil, nil] }
    check('SET LOCAL não deixa contexto para a transação seguinte') do
      identity(token) == [@tenant, @actor] && identity(nil) == [nil, nil]
    end
    check('not_before posterior à emissão recusa token') do
      write_key("UPDATE vetra_private.keys SET not_before = to_timestamp($1) WHERE kid = 'first'", [now + 30])
      identity(token) == [nil, nil]
    ensure
      write_key("UPDATE vetra_private.keys SET not_before = to_timestamp($1) WHERE kid = 'first'", [now - 3600])
    end
    check('chave já vigente recusa emissão anterior ao seu not_before') do
      write_key("UPDATE vetra_private.keys SET not_before = to_timestamp($1) WHERE kid = 'first'", [now - 5])
      identity(token({ 'iat' => now - 10, 'exp' => now + 20 })) == [nil, nil]
    ensure
      write_key("UPDATE vetra_private.keys SET not_before = to_timestamp($1) WHERE kid = 'first'", [now - 3600])
    end
    check('rotação normal conserva verify_only e aceita a nova active') do
      @second_secret = SecureRandom.random_bytes(32)
      @connection.exec('BEGIN; SET LOCAL SESSION AUTHORIZATION vetra_migrator')
      @connection.exec("UPDATE vetra_private.keys SET status = 'verify_only' WHERE kid = 'first'")
      @connection.exec_params("INSERT INTO vetra_private.keys (kid, secret, status, not_before) VALUES ($1, decode($2, 'hex'), $3, to_timestamp($4))",
                              ['second', @second_secret.unpack1('H*'), 'active', now - 3600])
      @connection.exec('COMMIT')
      identity(token) == [@tenant, @actor] && identity(token({}, kid: 'second', secret: @second_secret)) == [@tenant, @actor]
    ensure
      @connection.exec('ROLLBACK') if @connection.transaction_status != PG::PQTRANS_IDLE
    end
    check('revogação de emergência recusa na instrução seguinte da transação aberta') do
      old = token
      @connection.exec('BEGIN')
      @connection.exec_params("SELECT set_config('vetra.ctx', $1, true)", [old])
      @connection.exec('SET LOCAL SESSION AUTHORIZATION vetra_app')
      first = read_identity == [@tenant, @actor]
      rotator = PG.connect(connection_params(@connection.db))
      begin
        rotator.exec('SET ROLE vetra_migrator')
        rotator.exec("UPDATE vetra_private.keys SET status = 'revoked' WHERE kid = 'first'")
        first && read_identity == [nil, nil]
      ensure
        rotator.close
        @connection.exec('ROLLBACK')
      end
    end
    check('remoção da chave ativa recusa tokens dessa chave') do
      active_token = token({}, kid: 'second', secret: @second_secret)
      write_key("DELETE FROM vetra_private.keys WHERE kid = 'second'")
      identity(active_token) == [nil, nil]
    end
    check('revisão de autorização aceita as funções exatas no schema compartilhado') do
      @connection.exec('BEGIN')
      @connection.exec(@authz)
      @connection.exec("SELECT count(*) FROM vetra.authz_revisions").getvalue(0, 0) == '0'
    ensure
      @connection.exec('ROLLBACK')
    end
    check('corpo parecido no mesmo nome é recusado pela revisão') do
      rejected do
        replacement = Vetra::SQL::Context.body('tenant_id').sub('RETURN NULL;', "RETURN '#{@tenant}'::uuid;")
        @connection.exec("CREATE OR REPLACE FUNCTION vetra.current_tenant() RETURNS uuid LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $body$#{replacement}$body$")
      end
    end
    check('cópia exata do corpo em outro schema continua recusada pela guarda de rotinas') do
      rejected(routine_guard: true) do
        @connection.exec("CREATE FUNCTION public.current_tenant() RETURNS uuid LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $body$#{Vetra::SQL::Context.body('tenant_id')}$body$")
        @connection.exec('ALTER FUNCTION public.current_tenant() OWNER TO vetra_owner; GRANT EXECUTE ON FUNCTION public.current_tenant() TO vetra_app')
      end
    end
    check('search_path alterado no mesmo corpo é recusado') do
      rejected { @connection.exec("ALTER FUNCTION vetra.current_tenant() SET search_path = public, pg_temp") }
    end
    check('dono alterado no mesmo corpo é recusado') do
      rejected { @connection.exec('ALTER FUNCTION vetra.current_tenant() OWNER TO vetra_migrator') }
    end
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

  def check(label)
    ok = yield == true
    @results << ok
    puts "#{ok ? 'OK' : 'FALHA'}: #{label}"
  rescue StandardError => error
    @results << false
    state = error.respond_to?(:result) ? error.result&.error_field(PG::PG_DIAG_SQLSTATE) : nil
    warn "FALHA: #{label} (#{error.class}, SQLSTATE #{state || '-'})"
  end

  def roles
    [@admin.exec('SELECT oid, rolname, rolsuper, rolcanlogin, rolcreatedb, rolcreaterole, rolreplication, rolbypassrls, rolinherit FROM pg_roles ORDER BY oid').to_a,
     @admin.exec('SELECT roleid, member, grantor, admin_option, inherit_option, set_option FROM pg_auth_members ORDER BY roleid, member, grantor').to_a]
  end

  def connection_params(name)
    @admin.conninfo_hash.transform_keys(&:to_s)
      .merge('dbname' => name, 'host' => @admin.host, 'hostaddr' => @admin.hostaddr.to_s, 'port' => @admin.port.to_s)
      .reject { |_key, value| value.nil? || value.empty? }
  end

  def create_database
    name = "vetra_ctx_#{SecureRandom.hex(8)}"
    @admin.exec("CREATE DATABASE #{PG::Connection.quote_ident(name)} OWNER vetra_migrator TEMPLATE template0 ENCODING 'UTF8' LOCALE 'C'")
    @databases << name
    PG.connect(connection_params(name)).tap { |connection| connection.exec('SET client_min_messages = warning') }
  end

  def apply_as_migrator(connection)
    connection.exec('SET SESSION AUTHORIZATION vetra_migrator')
    allowed = connection.exec(<<~SQL).getvalue(0, 0) == 't'
      SELECT current_user = 'vetra_migrator' AND session_user = 'vetra_migrator'
        AND NOT r.rolsuper AND NOT r.rolcreatedb AND NOT r.rolcreaterole
        AND d.datdba = r.oid
      FROM pg_roles r JOIN pg_database d ON d.datname = current_database()
      WHERE r.rolname = current_user
    SQL
    raise 'A sonda deve aplicar o plano como migrador sem poderes extras e dono do banco' unless allowed
    Vetra::SQL::PlanExecutor.new(connection).apply([@plan])
  ensure
    connection.exec('RESET SESSION AUTHORIZATION')
  end

  def now
    @connection.exec('SELECT floor(extract(epoch FROM clock_timestamp()))::bigint').getvalue(0, 0).to_i
  end

  def claims
    issued = now
    { 'tenant_id' => @tenant, 'actor_id' => @actor, 'op_id' => @operation, 'cmd' => 'crm.create_lead', 'iat' => issued, 'exp' => issued + 30 }
  end

  def b64(bytes)
    [bytes].pack('m0').tr('+/', '-_').delete('=')
  end

  def sign(payload, kid: 'first', secret: @secret)
    message = "v1.#{kid}.#{payload}"
    "#{message}.#{b64(OpenSSL::HMAC.digest('SHA256', secret, message))}"
  end

  def token(changes = {}, kid: 'first', secret: @secret)
    sign(b64(JSON.generate(claims.merge(changes))), kid: kid, secret: secret)
  end

  def provision(kid, secret)
    write_key('INSERT INTO vetra_private.keys (kid, secret, status, not_before) VALUES ($1, decode($2, \'hex\'), $3, to_timestamp($4))',
              [kid, secret.unpack1('H*'), 'active', now - 3600])
  end

  def write_key(sql, values = [])
    @connection.exec('BEGIN; SET LOCAL SESSION AUTHORIZATION vetra_migrator')
    @connection.exec_params(sql, values)
    @connection.exec('COMMIT')
  ensure
    @connection.exec('ROLLBACK') if @connection.transaction_status != PG::PQTRANS_IDLE
  end

  def as_app
    @connection.exec('BEGIN; SET LOCAL SESSION AUTHORIZATION vetra_app')
    yield
  ensure
    @connection.exec('ROLLBACK')
  end

  def identity(value)
    as_app do
      @connection.exec_params("SELECT set_config('vetra.ctx', $1, true)", [value || '']) if value
      read_identity
    end
  end

  def read_identity
    @connection.exec('SELECT vetra.current_tenant(), vetra.current_actor()').values.first
  end

  def denied(sql)
    as_app { @connection.exec(sql); false }
  rescue PG::InsufficientPrivilege
    true
  end

  def rejected(routine_guard: false)
    @connection.exec('BEGIN')
    yield
    @connection.exec(@authz)
    false
  rescue PG::RaiseException => error
    !routine_guard || error.message.include?('Rotinas SECURITY DEFINER executáveis pela aplicação com dono privilegiado')
  ensure
    @connection.exec('ROLLBACK')
  end
end

if $PROGRAM_NAME == __FILE__
  exit(SignedContextProbe.new(ENV.fetch('DATABASE_URL')).run ? 0 : 1)
end

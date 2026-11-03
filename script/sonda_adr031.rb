#!/usr/bin/env ruby
# Aplica o SQL de Vetra::SQL::Authorization num PostgreSQL descartável. Requer SUPERUSUÁRIO.
# Cria schemas/papéis exclusivos e remove tudo no ensure. Não usa tabelas existentes da aplicação.
#   DATABASE_URL=postgres://superusuario@localhost/descartavel ruby script/sonda_adr031.rb
require 'bundler/inline'
require 'securerandom'

gemfile do
  source 'https://rubygems.org'
  gem 'pg'
  gem 'vetra', path: File.expand_path('..', __dir__)
end
require 'vetra'

class GeneratedAuthorizationProbe
  def initialize(url)
    @url = url
    @prefix = "vt_sonda031_#{Process.pid}_#{SecureRandom.hex(3)}"
    @owner, @app, @extra = %w[owner app extra].map { |suffix| "#{@prefix}_#{suffix}" }
    @roles, @results = [], []
    @document = Vetra::Graph::Compiler.new(root: File.expand_path('../examples/mini_crm_revendas', __dir__)).build.document
  end

  def run
    @admin = connect
    version = @admin.exec('SHOW server_version').getvalue(0, 0)
    [@owner, @app, @extra].each do |role|
      @admin.exec("CREATE ROLE #{role} NOLOGIN NOSUPERUSER NOBYPASSRLS")
      @roles << role
    end
    check('instala o SQL gerado: 15 triggers e revisões iniciais') do
      install
      count = @admin.exec_params("SELECT count(*) FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = $1 AND NOT t.tgisinternal", [@data]).getvalue(0, 0).to_i
      functions = @admin.exec_params("SELECT bool_and(prosecdef AND proowner = (SELECT oid FROM pg_roles WHERE rolname = $2) AND NOT has_function_privilege($3, oid, 'EXECUTE')) FROM pg_proc WHERE pronamespace = (SELECT oid FROM pg_namespace WHERE nspname = $1)", [@infra, @owner, @app]).getvalue(0, 0)
      [count == 15 && revisions == { '1' => 0, '2' => 0 } && functions == 't', "triggers=#{count}; funções protegidas=#{functions}; revisões=#{revisions}"]
    end
    check('lote, troca de tenant, DELETE e zero linhas preservam o conjunto afetado') do
      install
      sessions(1) do |writer|
        writer.exec("INSERT INTO #{@data}.memberships SELECT g, 1 + g % 2 FROM generate_series(1, 200) g")
        inserted = revisions
        writer.exec("UPDATE #{@data}.memberships SET company_id = 2 WHERE id = 2")
        moved = revisions
        writer.exec("DELETE FROM #{@data}.memberships WHERE company_id = 1")
        deleted = revisions
        writer.exec("UPDATE #{@data}.memberships SET company_id = 1 WHERE false")
        ok = inserted == { '1' => 1, '2' => 1 } && moved == { '1' => 2, '2' => 2 } && deleted == { '1' => 3, '2' => 2 } && revisions == deleted
        [ok, "lote=#{inserted}; troca=#{moved}; exclusão=#{deleted}"]
      end
    end
    check('raiz cria revisão e mantém o contador após remover e recriar tenant') do
      install
      sessions(1) do |writer|
        writer.exec("INSERT INTO #{@data}.companies VALUES (3)")
        first = revisions['3']
        writer.exec("DELETE FROM #{@data}.companies WHERE id = 3")
        deleted = revisions['3']
        writer.exec("INSERT INTO #{@data}.companies VALUES (3)")
        [first == 1 && deleted == 2 && revisions['3'] == 3, "revisões=#{[first, deleted, revisions['3']]}"]
      end
    end
    check('rollback desfaz revisão e notificação; commit publica ambos') do
      install
      sessions(2) do |writer, reader|
        reader.exec('LISTEN vetra_authz')
        writer.exec('BEGIN')
        writer.exec("INSERT INTO #{@data}.memberships VALUES (1, 1)")
        own, invisible = revisions(writer), revisions(reader)
        writer.exec('ROLLBACK')
        reader.exec('SELECT 1')
        absent = reader.notifies.nil?
        reverted = revisions(reader)
        writer.exec("INSERT INTO #{@data}.memberships VALUES (1, 1)")
        received = nil
        reader.wait_for_notify(3) { |_channel, _pid, payload| received = payload }
        ok = own['1'] == 1 && invisible['1'] == 0 && reverted['1'] == 0 && absent && received == '1' && revisions['1'] == 1
        [ok, "local=#{own}; antes do commit=#{invisible}; rollback=#{reverted}; notificação=#{received.inspect}"]
      end
    end
    check('concorrência sob lock conserva os dois incrementos') do
      install
      sessions(3) do |a, b, reader|
        a.exec('BEGIN')
        a.exec("INSERT INTO #{@data}.memberships VALUES (1, 1)")
        b.exec('BEGIN')
        b.send_query("INSERT INTO #{@data}.memberships VALUES (2, 1)")
        blocked = false
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 3
        loop do
          blocked = reader.exec_params('SELECT $2::int = ANY(pg_blocking_pids($1::int))', [b.backend_pid, a.backend_pid]).getvalue(0, 0) == 't'
          break if blocked || Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
          sleep 0.01
        end
        a.exec('COMMIT')
        b.get_last_result
        b.exec('COMMIT')
        [blocked && revisions['1'] == 2, "lock observado=#{blocked}; revisão=#{revisions['1']}"]
      end
    end
    check('papel da aplicação mantém DML e perde poderes sobre a invalidação') do
      install
      sessions(1) do |writer|
        errors = ["UPDATE #{@infra}.authz_revisions SET revision = 9", "TRUNCATE #{@data}.memberships", "ALTER TABLE #{@data}.memberships DISABLE TRIGGER ALL"].map do |sql|
          begin
            writer.exec(sql)
            nil
          rescue PG::Error => error
            error.result&.error_field(PG::PG_DIAG_SQLSTATE)
          end
        end
        writer.exec("INSERT INTO #{@data}.memberships VALUES (1, 1)")
        [errors == ['42501'] * 3 && revisions['1'] == 1, "recusas=#{errors}; INSERT permitido e revisão=#{revisions['1']}"]
      end
    end
    check('recusa coluna de tenant nullable antes de criar infraestrutura') do
      @admin.exec("ALTER TABLE #{@data}.memberships ALTER COLUMN company_id DROP NOT NULL")
      rejection('Coluna de tenant')
    end
    check('recusa tipo físico de tenant incompatível') do
      @admin.exec("ALTER TABLE #{@data}.memberships ALTER COLUMN company_id TYPE text USING company_id::text")
      rejection('Coluna de tenant')
    end
    check('recusa tabela particionada') do
      @admin.exec("DROP TABLE #{@data}.memberships; CREATE TABLE #{@data}.memberships (id integer, company_id integer NOT NULL) PARTITION BY RANGE (company_id); ALTER TABLE #{@data}.memberships OWNER TO #{@owner}")
      rejection('particionadas')
    end
    check('privilégio perigoso herdado faz rollback inclusive dos REVOKEs') do
      @admin.exec("GRANT TRUNCATE ON #{@data}.memberships TO #{@extra}; GRANT #{@extra} TO #{@app}")
      begin
        ok, detail = rejection('Privilégios herdados')
        retained = @admin.exec_params('SELECT has_table_privilege($1, $2, $3)', [@app, "#{@data}.memberships", 'TRUNCATE']).getvalue(0, 0) == 't'
        [ok && retained, "#{detail}; privilégios anteriores preservados=#{retained}"]
      ensure
        @admin.exec("REVOKE #{@extra} FROM #{@app}")
      end
    end
    check('recusa proprietário com LOGIN') do
      @admin.exec("ALTER ROLE #{@owner} LOGIN")
      begin
        rejection('Proprietário deve existir')
      ensure
        @admin.exec("ALTER ROLE #{@owner} NOLOGIN")
      end
    end
    check('recusa aplicação que pertence ao papel proprietário') do
      @admin.exec("GRANT #{@owner} TO #{@app}")
      begin
        rejection('Aplicação não pode pertencer')
      ensure
        @admin.exec("REVOKE #{@owner} FROM #{@app}")
      end
    end
    check('recusa aplicação proprietária do schema de dados') do
      @admin.exec("ALTER SCHEMA #{@data} OWNER TO #{@app}")
      rejection('Aplicação não pode possuir')
    end
    check('recusa escrita de revisão herdada de privilégios padrão') do
      @admin.exec("ALTER DEFAULT PRIVILEGES GRANT UPDATE ON TABLES TO #{@extra}; GRANT #{@extra} TO #{@app}")
      begin
        rejection('escrita nas revisões')
      ensure
        @admin.exec("ALTER DEFAULT PRIVILEGES REVOKE UPDATE ON TABLES FROM #{@extra}; REVOKE #{@extra} FROM #{@app}")
      end
    end
    check('recusa execução de função herdada de privilégios padrão') do
      @admin.exec("ALTER DEFAULT PRIVILEGES GRANT EXECUTE ON FUNCTIONS TO #{@extra}; GRANT #{@extra} TO #{@app}")
      begin
        rejection('Execução herdada')
      ensure
        @admin.exec("ALTER DEFAULT PRIVILEGES REVOKE EXECUTE ON FUNCTIONS FROM #{@extra}; REVOKE #{@extra} FROM #{@app}")
      end
    end
    check('recusa CREATE herdado no schema de infraestrutura') do
      @admin.exec("ALTER DEFAULT PRIVILEGES FOR ROLE #{@owner} GRANT CREATE ON SCHEMAS TO #{@extra}; GRANT #{@extra} TO #{@app}")
      begin
        rejection('criar objetos na infraestrutura')
      ensure
        @admin.exec("ALTER DEFAULT PRIVILEGES FOR ROLE #{@owner} REVOKE CREATE ON SCHEMAS FROM #{@extra}; REVOKE #{@extra} FROM #{@app}")
      end
    end
    check('colisão de schema preserva objetos existentes') do
      @admin.exec("CREATE SCHEMA #{@infra}; CREATE TABLE #{@infra}.marker (id integer); INSERT INTO #{@infra}.marker VALUES (7)")
      error = begin
        install
        nil
      rescue PG::Error => failure
        failure.result&.error_field(PG::PG_DIAG_SQLSTATE)
      end
      kept = @admin.exec("SELECT id FROM #{@infra}.marker").getvalue(0, 0) == '7'
      [error == '42P06' && kept, "SQLSTATE=#{error}; objeto preservado=#{kept}"]
    end
    puts "PostgreSQL #{version} | pg #{PG::VERSION} | SQL gerado da IR"
    @results.each { |ok, name, detail| puts "  #{ok ? 'PASS' : 'FAIL'}  #{name} | #{detail}" }
    passed = @results.count { |ok, _, _| ok }
    puts "Resultado: #{passed}/#{@results.size} verificações passaram."
    passed == @results.size
  ensure
    if @admin && !@admin.finished?
      @roles.reverse_each { |role| @admin.exec("DROP ROLE #{role}") }
      @admin.close
    end
  end

  private

  def connect(role: nil)
    PG.connect(@url).tap do |connection|
      connection.exec("SET client_min_messages = warning; SET statement_timeout = '10s'; SET lock_timeout = '5s'")
      connection.exec("SET ROLE #{role}") if role
    end
  end

  def sessions(count)
    connections = []
    count.times { connections << connect(role: @app) }
    yield(*connections)
  ensure
    connections.each { |connection| connection.close unless connection.finished? }
  end

  def check(name)
    index = @results.size
    @data, @infra = "#{@prefix}_d#{index}", "#{@prefix}_f#{index}"
    document = Vetra::Graph::Data.copy(@document)
    document['nodes'].select { |node| node['kind'] == 'entity' }.each { |node| node['storage']['schema'] = @data }
    document['digest'] = Vetra::Graph::Canonical.digest(document)
    @generated = Vetra::SQL::Authorization.new(document, schema: @infra, owner_role: @owner, app_role: @app).generate
    @admin.exec("CREATE SCHEMA #{@data} AUTHORIZATION #{@owner}; GRANT USAGE ON SCHEMA #{@data} TO #{@app}")
    @generated.tables.each do |table|
      columns = table['tenant_column'] == 'id' ? 'id integer PRIMARY KEY' : 'id integer PRIMARY KEY, company_id integer NOT NULL'
      @admin.exec("CREATE TABLE #{@data}.#{table['table']} (#{columns}); ALTER TABLE #{@data}.#{table['table']} OWNER TO #{@owner}; GRANT ALL ON #{@data}.#{table['table']} TO #{@app}")
    end
    @admin.exec("INSERT INTO #{@data}.companies VALUES (1), (2)")
    ok, detail = yield
    @results << [ok, name, detail]
  rescue StandardError => error
    @results << [false, name, "#{error.class}: #{error.message.lines.first&.strip}"]
  ensure
    @admin.exec("DROP SCHEMA IF EXISTS #{@infra} CASCADE; DROP SCHEMA IF EXISTS #{@data} CASCADE")
  end

  def install
    @admin.exec(@generated.sql)
  rescue PG::Error
    @admin.exec('ROLLBACK') unless @admin.transaction_status == PG::PQTRANS_IDLE
    raise
  end

  def revisions(connection = @admin)
    connection.exec("SELECT tenant_id, revision FROM #{@infra}.authz_revisions ORDER BY tenant_id").to_h { |row| [row['tenant_id'], row['revision'].to_i] }
  end

  def rejection(message)
    error = begin
      install
      nil
    rescue PG::Error => failure
      failure.message
    end
    absent = @admin.exec_params('SELECT NOT EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = $1)', [@infra]).getvalue(0, 0) == 't'
    [error&.include?(message) && absent, "recusado=#{!!error&.include?(message)}; infraestrutura ausente=#{absent}"]
  end
end

exit(GeneratedAuthorizationProbe.new(ENV.fetch('DATABASE_URL', 'postgres://postgres@127.0.0.1:5432/postgres')).run ? 0 : 1)

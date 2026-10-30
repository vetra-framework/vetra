#!/usr/bin/env ruby
# Sonda do ADR-002: confere num PostgreSQL real os requisitos que o ADR lista (versão mínima 17, RLS com FORCE,
# views security_invoker, xid8 e xmin do snapshot, transaction_timeout, pgcrypto). É o embrião do `vetra doctor`
# e serve para repetir a verificação em cada versão da matriz. Não faz parte da suíte do compilador.
#
#   DATABASE_URL=postgres://superusuario@127.0.0.1:5432/descartavel ruby script/sonda_adr002.rb
#
# Exige um SUPERUSUÁRIO, porque cria papéis de teste (vetra_sonda_owner, vetra_sonda_app, vetra_sonda_bypass),
# o schema vetra_sonda e a extensão pgcrypto. Use um banco descartável. Os papéis e o schema são removidos no fim.
require "bundler/inline"

gemfile do
  source "https://rubygems.org"
  gem "pg"
end

URL = ENV.fetch("DATABASE_URL", "postgres://postgres@127.0.0.1:5432/postgres")
MINIMUM = 170_000
ROLES = %w[vetra_sonda_owner vetra_sonda_app vetra_sonda_bypass].freeze
RESULTS = []

def connect
  PG.connect(URL).tap { |conn| conn.exec("SET client_min_messages = warning") }
end

def check(name)
  ok, detail = yield
  RESULTS << [ok, name, detail]
rescue Exception => e
  RESULTS << [false, name, "#{e.class}: #{e.message.lines.first&.strip}"]
end

def terminated?(error)
  error.message =~ /terminat|timeout|connection/i
end

admin = connect
version = admin.exec("SHOW server_version").getvalue(0, 0)
version_num = admin.exec("SHOW server_version_num").getvalue(0, 0).to_i

def cleanup(conn)
  conn.exec("DROP SCHEMA IF EXISTS vetra_sonda CASCADE")
  ROLES.each do |role|
    begin
      conn.exec("DROP OWNED BY #{role}")
    rescue PG::Error
      nil
    end
    conn.exec("DROP ROLE IF EXISTS #{role}")
  end
end

cleanup(admin)
admin.exec("CREATE ROLE vetra_sonda_owner NOLOGIN")
admin.exec("CREATE ROLE vetra_sonda_app NOLOGIN")
admin.exec("CREATE ROLE vetra_sonda_bypass NOLOGIN BYPASSRLS")
admin.exec("CREATE SCHEMA vetra_sonda AUTHORIZATION vetra_sonda_owner")
admin.exec("GRANT USAGE ON SCHEMA vetra_sonda TO vetra_sonda_app, vetra_sonda_bypass")

%w[t t2].each do |table|
  admin.exec("SET ROLE vetra_sonda_owner")
  admin.exec("CREATE TABLE vetra_sonda.#{table} (id int, tenant int)")
  admin.exec("INSERT INTO vetra_sonda.#{table} VALUES (1, 1), (2, 2)")
  admin.exec("ALTER TABLE vetra_sonda.#{table} ENABLE ROW LEVEL SECURITY")
  admin.exec("CREATE POLICY isolamento ON vetra_sonda.#{table} USING (tenant = NULLIF(current_setting('vetra.tenant', true), '')::int)")
  admin.exec("GRANT SELECT ON vetra_sonda.#{table} TO vetra_sonda_app, vetra_sonda_bypass")
  admin.exec("RESET ROLE")
end

# Conta as linhas visíveis a um papel, com ou sem tenant no contexto da transação.
def visible_rows(conn, role, relation, tenant: nil)
  conn.exec("BEGIN")
  conn.exec("SET LOCAL ROLE #{role}")
  conn.exec_params("SELECT set_config('vetra.tenant', $1, true)", [tenant.to_s]) if tenant
  conn.exec("SELECT count(*) FROM #{relation}").getvalue(0, 0).to_i
ensure
  conn.exec("ROLLBACK")
end

check("versão mínima 17 (por causa do transaction_timeout)") do
  [version_num >= MINIMUM, "servidor: #{version} (mínimo exigido: 17)"]
end

check("o dono da tabela ignora a política sem FORCE ROW LEVEL SECURITY") do
  rows = visible_rows(admin, "vetra_sonda_owner", "vetra_sonda.t", tenant: 1)
  [rows == 2, "o dono viu #{rows} de 2 linhas, mesmo com tenant=1"]
end
check("com FORCE ROW LEVEL SECURITY, o dono também é filtrado") do
  admin.exec("ALTER TABLE vetra_sonda.t FORCE ROW LEVEL SECURITY")
  rows = visible_rows(admin, "vetra_sonda_owner", "vetra_sonda.t", tenant: 1)
  [rows == 1, "o dono viu #{rows} de 2 linhas com tenant=1"]
end
check("o papel de aplicação (sem BYPASSRLS) vê só o seu tenant") do
  rows = visible_rows(admin, "vetra_sonda_app", "vetra_sonda.t", tenant: 2)
  [rows == 1, "tenant=2: #{rows} linha"]
end
check("sem contexto de tenant, a negação é o padrão: nenhuma linha") do
  rows = visible_rows(admin, "vetra_sonda_app", "vetra_sonda.t")
  [rows.zero?, "sem tenant: #{rows} linhas"]
end
check("um papel com BYPASSRLS ignora a política (por isso o doctor o proíbe na aplicação)") do
  rows = visible_rows(admin, "vetra_sonda_bypass", "vetra_sonda.t", tenant: 1)
  [rows == 2, "BYPASSRLS viu #{rows} de 2 linhas"]
end

# --- Combinação de políticas e troca de política (ADR-005 e ADR-015) ---

def policy_table(admin, name, policies)
  admin.exec("SET ROLE vetra_sonda_owner")
  admin.exec("DROP TABLE IF EXISTS vetra_sonda.#{name}")
  admin.exec("CREATE TABLE vetra_sonda.#{name} (id int, tenant int, regiao text, grupo int)")
  admin.exec("INSERT INTO vetra_sonda.#{name} VALUES (1, 1, 'A', 1), (2, 1, 'B', 2), (3, 2, 'A', 3), (4, 2, 'B', 3)")
  admin.exec("ALTER TABLE vetra_sonda.#{name} ENABLE ROW LEVEL SECURITY")
  policies.each { |sql| admin.exec(sql) }
  admin.exec("GRANT SELECT ON vetra_sonda.#{name} TO vetra_sonda_app")
  admin.exec("RESET ROLE")
end

def visible_ids(conn, relation, tenant: 1)
  conn.exec("BEGIN")
  conn.exec("SET LOCAL ROLE vetra_sonda_app")
  conn.exec_params("SELECT set_config('vetra.tenant', $1, true)", [tenant.to_s])
  conn.exec("SELECT id FROM #{relation} ORDER BY id").map { |row| row["id"].to_i }
ensure
  conn.exec("ROLLBACK")
end

TENANT_USING = "tenant = NULLIF(current_setting('vetra.tenant', true), '')::int".freeze

check("isolamento PERMISSIVO somado a um escopo permissivo VAZA entre tenants (por isso o isolamento é RESTRICTIVE)") do
  policy_table(admin, "c1", ["CREATE POLICY isolamento ON vetra_sonda.c1 USING (#{TENANT_USING})", "CREATE POLICY escopo ON vetra_sonda.c1 USING (regiao = 'A')"])
  ids = visible_ids(admin, "vetra_sonda.c1")
  [ids.include?(3), "contexto tenant=1 viu #{ids.inspect}; a linha 3 é do tenant 2"]
end
check("isolamento RESTRICTIVE somado a um escopo permissivo respeita tenant e escopo") do
  policy_table(admin, "c2", ["CREATE POLICY isolamento ON vetra_sonda.c2 AS RESTRICTIVE USING (#{TENANT_USING})", "CREATE POLICY escopo ON vetra_sonda.c2 USING (regiao = 'A')"])
  ids = visible_ids(admin, "vetra_sonda.c2")
  [ids == [1], "contexto tenant=1 viu #{ids.inspect}"]
end
check("só políticas RESTRICTIVE, sem nenhuma permissiva, não concedem acesso a ninguém") do
  policy_table(admin, "c3", ["CREATE POLICY isolamento ON vetra_sonda.c3 AS RESTRICTIVE USING (#{TENANT_USING})"])
  ids = visible_ids(admin, "vetra_sonda.c3")
  [ids.empty?, "contexto tenant=1 viu #{ids.inspect}"]
end
check("RESTRICTIVE de tenant mais uma permissiva USING (true) dá acesso só ao tenant (entidade sem escopo)") do
  policy_table(admin, "c4", ["CREATE POLICY isolamento ON vetra_sonda.c4 AS RESTRICTIVE USING (#{TENANT_USING})", "CREATE POLICY acesso ON vetra_sonda.c4 USING (true)"])
  ids = visible_ids(admin, "vetra_sonda.c4")
  [ids == [1, 2], "contexto tenant=1 viu #{ids.inspect}"]
end

STATES = { [1, 2] => "ANTIGO", [2, 3, 4] => "NOVO", [1, 2, 3, 4] => "UNIAO", [] => "VAZIO" }.freeze

# Troca a política "antiga" (grupos 1 e 2) pela "nova" (grupos 2 e 3) enquanto um leitor consulta o tempo todo;
# devolve os estados que o leitor chegou a ver, na ordem. O grupo 1 deve ser revogado e o 3 concedido.
def states_during_swap(admin)
  policy_table(admin, "troca", ["CREATE POLICY antiga ON vetra_sonda.troca USING (grupo IN (1, 2))"])
  reader = connect
  reader.exec("SET ROLE vetra_sonda_app")
  seen = []
  stop = false
  watcher = Thread.new do
    until stop
      ids = reader.exec("SELECT id FROM vetra_sonda.troca ORDER BY id").map { |row| row["id"].to_i }
      seen << ids if seen.last != ids
    end
  end
  sleep 0.2
  yield
  sleep 0.2
  stop = true
  watcher.join
  reader.close
  seen.map { |ids| STATES.fetch(ids, ids.inspect) }
end

NEW_POLICY = "USING (grupo IN (2, 3))".freeze

check("criar a nova política antes de remover a antiga expõe a UNIÃO dos acessos (contraste do procedimento antigo)") do
  states = states_during_swap(admin) do
    admin.exec("CREATE POLICY nova ON vetra_sonda.troca #{NEW_POLICY}")
    sleep 0.4
    admin.exec("DROP POLICY antiga ON vetra_sonda.troca")
  end
  [states.include?("UNIAO"), "o leitor viu #{states.join(' -> ')}"]
end
check("DROP POLICY + CREATE POLICY na mesma transação: o leitor nunca vê a união nem o vazio") do
  states = states_during_swap(admin) do
    admin.exec("BEGIN")
    admin.exec("DROP POLICY antiga ON vetra_sonda.troca")
    admin.exec("CREATE POLICY nova ON vetra_sonda.troca #{NEW_POLICY}")
    sleep 0.5
    admin.exec("COMMIT")
  end
  [states == %w[ANTIGO NOVO], "o leitor viu #{states.join(' -> ')}"]
end
check("ALTER POLICY troca a política de uma vez: o leitor nunca vê a união nem o vazio") do
  states = states_during_swap(admin) { admin.exec("ALTER POLICY antiga ON vetra_sonda.troca #{NEW_POLICY}") }
  [states == %w[ANTIGO NOVO], "o leitor viu #{states.join(' -> ')}"]
end
check("uma falha no CREATE dentro da transação preserva a política anterior") do
  policy_table(admin, "falha", ["CREATE POLICY antiga ON vetra_sonda.falha USING (grupo IN (1, 2))"])
  message = begin
    admin.exec("BEGIN")
    admin.exec("DROP POLICY antiga ON vetra_sonda.falha")
    admin.exec("CREATE POLICY nova ON vetra_sonda.falha USING (coluna_que_nao_existe = 1)")
    admin.exec("COMMIT")
    nil
  rescue PG::Error => e
    admin.exec("ROLLBACK")
    e.message.lines.first.strip
  end
  kept = admin.exec("SELECT count(*) FROM pg_policies WHERE schemaname = 'vetra_sonda' AND tablename = 'falha' AND policyname = 'antiga'").getvalue(0, 0) == "1"
  ids = visible_ids(admin, "vetra_sonda.falha")
  [!message.nil? && kept && STATES[ids] == "ANTIGO", "erro: #{message}; a antiga continua? #{kept}; acesso: #{STATES.fetch(ids, ids.inspect)}"]
end
check("ALTER POLICY não muda PERMISSIVE/RESTRICTIVE nem o comando (isso exige DROP + CREATE)") do
  policy_table(admin, "alter", ["CREATE POLICY antiga ON vetra_sonda.alter USING (grupo IN (1, 2))"])
  refused = ["AS RESTRICTIVE", "FOR SELECT"].map do |clause|
    begin
      admin.exec("ALTER POLICY antiga ON vetra_sonda.alter #{clause}")
      nil
    rescue PG::Error => e
      e.message.lines.first.strip
    end
  end
  [refused.none?(&:nil?), "recusado: #{refused.inspect}"]
end

check("view comum contorna o RLS; view security_invoker o respeita") do
  admin.exec("SET ROLE vetra_sonda_owner")
  admin.exec("CREATE VIEW vetra_sonda.v_dono AS SELECT * FROM vetra_sonda.t2")
  admin.exec("CREATE VIEW vetra_sonda.v_invoker WITH (security_invoker = true) AS SELECT * FROM vetra_sonda.t2")
  admin.exec("GRANT SELECT ON vetra_sonda.v_dono, vetra_sonda.v_invoker TO vetra_sonda_app")
  admin.exec("RESET ROLE")
  common = visible_rows(admin, "vetra_sonda_app", "vetra_sonda.v_dono", tenant: 1)
  invoker = visible_rows(admin, "vetra_sonda_app", "vetra_sonda.v_invoker", tenant: 1)
  [common == 2 && invoker == 1, "view comum: #{common} linhas; security_invoker: #{invoker} linha"]
end

check("xid8 e o xmin do snapshot: uma escrita aberta prende o xmin, uma leitura não") do
  writer = connect
  reader = connect
  writer.exec("CREATE TABLE IF NOT EXISTS vetra_sonda.w (n int)")
  writer.exec("BEGIN")
  writer.exec("INSERT INTO vetra_sonda.w VALUES (1)")
  xid = writer.exec("SELECT pg_current_xact_id()::text").getvalue(0, 0).to_i
  type = writer.exec("SELECT pg_typeof(pg_current_xact_id())::text").getvalue(0, 0)
  held = reader.exec("SELECT pg_snapshot_xmin(pg_current_snapshot())::text").getvalue(0, 0).to_i
  writer.exec("COMMIT")
  released = reader.exec("SELECT pg_snapshot_xmin(pg_current_snapshot())::text").getvalue(0, 0).to_i
  reader.exec("BEGIN")
  assigned = reader.exec("SELECT pg_current_xact_id_if_assigned()::text").getvalue(0, 0)
  reader.exec("ROLLBACK")
  [type == "xid8" && held <= xid && released > xid && assigned.nil?,
   "tipo #{type}; durante a escrita xmin=#{held} (xid=#{xid}); depois do commit xmin=#{released}; leitura sem xid? #{assigned.nil?}"]
end

check("um FOR UPDATE atribui xid à transação (por isso o relay não segura a reserva aberta, ADR-014)") do
  conn = connect
  conn.exec("BEGIN")
  before = conn.exec("SELECT pg_current_xact_id_if_assigned()::text").getvalue(0, 0)
  conn.exec("SELECT * FROM vetra_sonda.t2 ORDER BY id LIMIT 1 FOR UPDATE SKIP LOCKED")
  after = conn.exec("SELECT pg_current_xact_id_if_assigned()::text").getvalue(0, 0)
  conn.exec("ROLLBACK")
  [before.nil? && !after.nil?, "antes do FOR UPDATE: #{before.inspect}; depois: #{after.inspect}"]
end

check("transaction_timeout derruba a transação longa (requisito do ADR-008 e do ADR-002)") do
  conn = connect
  message = begin
    conn.exec("SET transaction_timeout = '200ms'")
    conn.exec("BEGIN")
    conn.exec("SELECT pg_sleep(1)")
    nil
  rescue PG::Error => e
    e.message.lines.first.strip
  end
  [!message.nil? && message =~ /transaction timeout/i, message || "a transação longa não foi encerrada"]
end

check("idle_in_transaction_session_timeout encerra a sessão ociosa dentro de transação") do
  conn = connect
  conn.exec("SET idle_in_transaction_session_timeout = '200ms'")
  conn.exec("BEGIN")
  sleep 0.6
  message = begin
    conn.exec("SELECT 1")
    nil
  rescue PG::Error => e
    e.message.lines.first.strip
  end
  [!message.nil?, message || "a sessão ociosa não foi encerrada"]
end

check("SKIP LOCKED existe e pula a linha travada") do
  holder = connect
  other = connect
  holder.exec("BEGIN")
  holder.exec("SELECT * FROM vetra_sonda.t2 ORDER BY id LIMIT 1 FOR UPDATE")
  row = other.exec("SELECT id FROM vetra_sonda.t2 ORDER BY id LIMIT 1 FOR UPDATE SKIP LOCKED").to_a.first
  holder.exec("ROLLBACK")
  [row && row["id"] == "2", "a segunda sessão pegou id=#{row && row['id']}"]
end

check("pgcrypto está disponível e o HMAC-SHA256 confere com o vetor de teste conhecido") do
  admin.exec("CREATE EXTENSION IF NOT EXISTS pgcrypto")
  hex = admin.exec("SELECT encode(hmac('The quick brown fox jumps over the lazy dog', 'key', 'sha256'), 'hex')").getvalue(0, 0)
  expected = "f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8"
  [hex == expected, hex[0, 16] + "…"]
end

check("tabelas UNLOGGED existem") do
  admin.exec("CREATE UNLOGGED TABLE vetra_sonda.u (n int)")
  kind = admin.exec("SELECT relpersistence::text FROM pg_class WHERE oid = 'vetra_sonda.u'::regclass").getvalue(0, 0)
  [kind == "u", "relpersistence = #{kind}"]
end

cleanup(admin)

width = RESULTS.map { |_, name, _| name.size }.max
puts "PostgreSQL #{version} | pg #{PG::VERSION}"
RESULTS.each { |ok, name, detail| puts "  #{ok ? 'PASS' : 'FAIL'}  #{name.ljust(width)}  | #{detail}" }
puts RESULTS.all? { |ok, _, _| ok } ? "Resultado: o servidor cumpre os requisitos do ADR-002." : "Resultado: o servidor NÃO cumpre todos os requisitos do ADR-002."
exit(RESULTS.all? { |ok, _, _| ok } ? 0 : 1)

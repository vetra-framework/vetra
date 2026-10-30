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

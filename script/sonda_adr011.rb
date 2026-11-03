#!/usr/bin/env ruby
# Sonda do ADR-011: confere num PostgreSQL real o mecanismo que dá sentido a "revogar a delegação suspende o agente
# em andamento" (§2). A etapa 6 de uma operação do agente relê a linha da delegação dentro da transação, com
# FOR SHARE. Não faz parte da suíte do compilador.
#
#   DATABASE_URL=postgres://usuario@127.0.0.1:5432/descartavel ruby script/sonda_adr011.rb
#
# Use um banco descartável: cria e remove a tabela vetra_sonda_delegacoes. A gem pg é instalada por bundler/inline,
# fora do Gemfile do projeto. O veredito não depende de tempo de parede: cada espera é provada pelo que o servidor
# registra em pg_stat_activity (wait_event_type = 'Lock'), e o tempo só serve de limite para não travar a sonda.
require "bundler/inline"

gemfile do
  source "https://rubygems.org"
  gem "pg"
end

URL = ENV.fetch("DATABASE_URL", "postgres://postgres@127.0.0.1:5432/postgres")
TABELA = "vetra_sonda_delegacoes"
LER = "SELECT id FROM #{TABELA} WHERE id = 1 AND revoked_at IS NULL FOR SHARE"
REVOGAR = "UPDATE #{TABELA} SET revoked_at = now() WHERE id = 1"
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

def sqlstate(error)
  error.result&.error_field(PG::PG_DIAG_SQLSTATE)
end

# Espera até o servidor registrar que a sessão está bloqueada num lock. Devolve true ou false depois do limite.
def waiting_on_lock?(observer, pid, limit: 5.0)
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + limit
  while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
    type = observer.exec_params("SELECT wait_event_type FROM pg_stat_activity WHERE pid = $1", [pid]).getvalue(0, 0)
    return true if type == "Lock"
    sleep 0.02
  end
  false
end

def reset(admin)
  admin.exec("UPDATE #{TABELA} SET revoked_at = NULL WHERE id = 1")
end

admin = connect
version = admin.exec("SHOW server_version").getvalue(0, 0)
admin.exec("DROP TABLE IF EXISTS #{TABELA}")
admin.exec("CREATE TABLE #{TABELA} (id int PRIMARY KEY, revoked_at timestamptz)")
admin.exec("INSERT INTO #{TABELA} VALUES (1, NULL)")

check("duas operações da mesma delegação leem a linha com FOR SHARE sem esperar uma pela outra") do
  reset(admin)
  a = connect
  b = connect
  a.exec("BEGIN")
  a.exec(LER)
  b.exec("SET lock_timeout = '1s'")
  b.exec("BEGIN")
  rows = b.exec(LER).ntuples
  b.exec("COMMIT")
  a.exec("ROLLBACK")
  [rows == 1, "a segunda leitura voltou com #{rows} linha enquanto a primeira segurava o lock"]
end

check("a revogação (UPDATE) espera enquanto uma operação segura o FOR SHARE") do
  reset(admin)
  holder = connect
  revoker = connect
  holder.exec("BEGIN")
  holder.exec(LER)
  revoker.exec("SET lock_timeout = '500ms'")
  code = begin
    revoker.exec(REVOGAR)
    nil
  rescue PG::Error => e
    sqlstate(e)
  end
  holder.exec("ROLLBACK")
  [code == "55P03", "SQLSTATE #{code.inspect} (55P03 = lock_not_available)"]
end

check("a revogação espera a operação em andamento e vale depois que ela confirma") do
  reset(admin)
  holder = connect
  revoker = connect
  observer = connect
  holder.exec("BEGIN")
  holder.exec(LER)
  thread = Thread.new { revoker.exec(REVOGAR) }
  waiting = waiting_on_lock?(observer, revoker.backend_pid)
  still_waiting = thread.alive?
  holder.exec("COMMIT")
  finished = thread.join(5)
  revoked = admin.exec("SELECT revoked_at IS NOT NULL FROM #{TABELA} WHERE id = 1").getvalue(0, 0) == "t"
  detail = "esperou no lock: #{waiting}; ainda pendente com a operação aberta: #{still_waiting}; " \
           "concluiu depois do commit: #{!finished.nil?}; revogada: #{revoked}"
  [waiting && still_waiting && finished && revoked, detail]
end

check("uma operação que começa depois da revogação confirmada não obtém a linha e é desfeita") do
  reset(admin)
  admin.exec(REVOGAR)
  op = connect
  op.exec("BEGIN ISOLATION LEVEL READ COMMITTED")
  rows = op.exec(LER).ntuples
  op.exec("ROLLBACK")
  [rows.zero?, "#{rows} linha(s) com revoked_at IS NULL"]
end

check("uma operação que espera a revogação em andamento vê a revogação quando ela confirma") do
  reset(admin)
  revoker = connect
  op = connect
  observer = connect
  revoker.exec("BEGIN")
  revoker.exec(REVOGAR)
  op.exec("BEGIN ISOLATION LEVEL READ COMMITTED")
  thread = Thread.new { op.exec(LER).ntuples }
  waiting = waiting_on_lock?(observer, op.backend_pid)
  revoker.exec("COMMIT")
  rows = thread.value
  op.exec("ROLLBACK")
  [waiting && rows.zero?, "esperou no lock: #{waiting}; linhas depois do commit da revogação: #{rows}"]
end

admin.exec("DROP TABLE IF EXISTS #{TABELA}")
width = RESULTS.map { |_, name, _| name.size }.max
puts "PostgreSQL #{version} | pg #{PG::VERSION}"
RESULTS.each { |ok, name, detail| puts "  #{ok ? 'PASS' : 'FAIL'}  #{name.ljust(width)}  | #{detail}" }
puts RESULTS.all? { |ok, _, _| ok } ? "Resultado: todas as verificações passaram." : "Resultado: há verificações com falha."
exit(RESULTS.all? { |ok, _, _| ok } ? 0 : 1)

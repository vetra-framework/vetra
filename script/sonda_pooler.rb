#!/usr/bin/env ruby
# Sonda do pooler: confere o que os ADRs 003, 005 e 008 afirmam sobre o PgBouncer em modo de transação:
# contexto por set_config local não vaza, o SET de sessão vaza, statements nomeados dependem do suporte do
# pooler, e o LISTEN não funciona. Não faz parte da suíte do compilador.
#
#   POOLER_URL=postgres://postgres@127.0.0.1:6432/postgres ruby script/sonda_pooler.rb
#
# O pooler precisa estar em pool_mode = transaction com default_pool_size = 1: com um único backend, dois
# clientes são obrigados a reutilizá-lo, e é aí que um vazamento aparece. A sonda confere isso primeiro.
# Se o usuário for administrador do PgBouncer, ela lê max_prepared_statements pelo console; senão, só relata.
require "bundler/inline"

gemfile do
  source "https://rubygems.org"
  gem "pg"
  gem "sequel", "5.109.0"
end

URL = ENV.fetch("POOLER_URL", "postgres://postgres@127.0.0.1:6432/postgres")
RESULTS = []
CONNECTIONS = []

def connect
  PG.connect(URL).tap { |conn| CONNECTIONS << conn }
end

def check(name)
  ok, detail = yield
  RESULTS << [ok, name, detail]
rescue Exception => e
  RESULTS << [false, name, "#{e.class}: #{e.message.lines.first&.strip}"]
end

def value(conn, sql, *params)
  (params.empty? ? conn.exec(sql) : conn.exec_params(sql, params)).getvalue(0, 0)
end

def setting(conn)
  value(conn, "SELECT current_setting('vetra.ctx', true)")
end

def blank?(text)
  text.nil? || text.empty?
end

def release_all
  CONNECTIONS.each { |conn| conn.close unless conn.finished? }
  CONNECTIONS.clear
end

def max_prepared_statements
  admin_url = URL.sub(%r{/[^/]+\z}, "/pgbouncer")
  admin = PG.connect(admin_url)
  row = admin.exec("SHOW CONFIG").to_a.find { |entry| entry["key"] == "max_prepared_statements" }
  admin.close
  row && row["value"].to_i
rescue PG::Error
  nil
end

supported = max_prepared_statements

check("pré-condição: dois clientes reutilizam o mesmo backend (pool de uma conexão)") do
  first = connect
  second = connect
  pids = [value(first, "SELECT pg_backend_pid()"), value(second, "SELECT pg_backend_pid()")]
  [pids.uniq.size == 1, "backends: #{pids.inspect}; um teste de vazamento só vale se forem iguais"]
end
release_all

check("um SET de sessão VAZA para outro cliente (contraste: por isso o contexto não pode ser de sessão)") do
  first = connect
  second = connect
  first.exec("SET vetra.ctx = 'vazou'")
  seen = setting(second)
  first.exec("RESET vetra.ctx")
  [seen == "vazou", "o outro cliente viu #{seen.inspect}"]
end
release_all

check("o contexto por set_config(..., true) não vaza para o cliente seguinte") do
  first = connect
  second = connect
  first.transaction { |tx| tx.exec_params("SELECT set_config('vetra.ctx', $1, true)", ["token-123"]) }
  seen = setting(second)
  [blank?(seen), "o outro cliente viu #{seen.inspect}"]
end
release_all

check("durante a transação o contexto fica preso ao cliente, e o outro espera o backend") do
  first = connect
  second = connect
  inside = nil
  seen_by_second = nil
  waiter = nil
  first.exec("BEGIN")
  first.exec_params("SELECT set_config('vetra.ctx', $1, true)", ["so-do-primeiro"])
  waiter = Thread.new { seen_by_second = setting(second) }
  sleep 0.4
  still_waiting = waiter.alive?
  inside = setting(first)
  first.exec("COMMIT")
  waiter.join(5)
  [inside == "so-do-primeiro" && still_waiting && blank?(seen_by_second),
   "primeiro viu #{inside.inspect}; o segundo ficou esperando? #{still_waiting}; depois viu #{seen_by_second.inspect}"]
end
release_all

check("consultas parametrizadas (statement sem nome) funcionam alternando clientes") do
  clients = Array.new(3) { connect }
  results = Array.new(60) { |i| value(clients[i % 3], "SELECT $1::int + 1", i).to_i }
  [results == (1..60).to_a, "60 consultas em 3 clientes; corretas: #{results.each_with_index.count { |v, i| v == i + 1 }}/60"]
end
release_all

check("dois clientes preparam statements nomeados com o mesmo nome e cada um executa o seu") do
  first = connect
  second = connect
  outcome = begin
    first.prepare("sonda_s", "SELECT 1")
    second.prepare("sonda_s", "SELECT 2")
    [first.exec_prepared("sonda_s").getvalue(0, 0), second.exec_prepared("sonda_s").getvalue(0, 0)]
  rescue PG::Error => e
    e.message.lines.first.strip
  end
  works = outcome == %w[1 2]
  expected = supported.nil? ? works : (supported.positive? == works)
  note = supported.nil? ? "max_prepared_statements não lido" : "max_prepared_statements = #{supported}"
  [expected, "#{note}; resultado: #{outcome.inspect}"]
end
release_all

check("o Sequel com pg_auto_parameterize e set_config local funciona através do pooler, sem vazar") do
  db = Sequel.connect(URL, max_connections: 3)
  db.extension :pg_auto_parameterize
  other = Sequel.connect(URL, max_connections: 1)
  context = db.transaction do
    db.get(Sequel.function(:set_config, "vetra.ctx", "token-sequel", true))
    db.get(Sequel.function(:current_setting, "vetra.ctx", true))
  end
  rows = Array.new(30) { |i| db.get(Sequel.lit("?::int + 1", i)) }
  leaked = other.get(Sequel.function(:current_setting, "vetra.ctx", true))
  db.disconnect
  other.disconnect
  [context == "token-sequel" && rows == (1..30).to_a && blank?(leaked),
   "dentro da transação: #{context.inspect}; 30 consultas parametrizadas corretas: #{rows == (1..30).to_a}; outro cliente viu #{leaked.inspect}"]
end

check("o LISTEN não é confiável em modo de transação (o ouvinte não recebe)") do
  listener = connect
  sender = connect
  listener.exec("LISTEN vetra_pool")
  value(listener, "SELECT 1")
  sender.exec("SELECT pg_notify('vetra_pool', 'ola')")
  heard = []
  listener.wait_for_notify(1.0) { |_channel, _pid, payload| heard << payload }
  stray = []
  sender.wait_for_notify(0.3) { |_channel, _pid, payload| stray << payload }
  [heard.empty?, "o ouvinte recebeu #{heard.inspect}; o remetente recebeu #{stray.inspect}"]
end
release_all

width = RESULTS.map { |_, name, _| name.size }.max
puts "pooler: #{URL.sub(%r{//[^@]*@}, '//')} | pg #{PG::VERSION}"
RESULTS.each { |ok, name, detail| puts "  #{ok ? 'PASS' : 'FAIL'}  #{name.ljust(width)}  | #{detail}" }
puts RESULTS.all? { |ok, _, _| ok } ? "Resultado: todas as verificações passaram." : "Resultado: há verificações com falha."
exit(RESULTS.all? { |ok, _, _| ok } ? 0 : 1)

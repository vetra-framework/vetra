#!/usr/bin/env ruby
# Sonda do ADR-019: confere num PostgreSQL real as propriedades do NOTIFY e das tabelas UNLOGGED em que os
# sinais efêmeros (presença e "digitando") se apoiam. Não faz parte da suíte do compilador.
#
#   DATABASE_URL=postgres://usuario@127.0.0.1:5432/descartavel ruby script/sonda_adr019.rb
#
# Use um banco descartável: cria e remove duas tabelas vetra_sonda_*. O comportamento de uma tabela UNLOGGED
# depois de um crash não é testável por aqui, porque exige derrubar o servidor; veja o teste de aceitação 3 do ADR.
require "bundler/inline"

gemfile do
  source "https://rubygems.org"
  gem "pg"
end

URL = ENV.fetch("DATABASE_URL", "postgres://postgres@127.0.0.1:5432/postgres")
RESULTS = []

def connect
  PG.connect(URL)
end

def check(name)
  ok, detail = yield
  RESULTS << [ok, name, detail]
rescue Exception => e
  RESULTS << [false, name, "#{e.class}: #{e.message.lines.first&.strip}"]
end

# Recebe tudo o que chega ao canal em até `wait` segundos.
def drain(listener, wait: 0.5)
  received = []
  while (message = listener.wait_for_notify(wait) { |_channel, _pid, payload| received << payload })
    nil if message
  end
  received
end

def listener_for(channel)
  connect.tap { |conn| conn.exec("LISTEN #{channel}") }
end

check("o payload do NOTIFY tem limite: 7999 bytes passam, 8000 não") do
  conn = connect
  conn.exec_params("SELECT pg_notify('vetra_sonda', $1)", ["x" * 7999])
  refused = begin
    conn.exec_params("SELECT pg_notify('vetra_sonda', $1)", ["x" * 8000])
    nil
  rescue PG::Error => e
    e.message.lines.first.strip
  end
  [!refused.nil?, refused || "aceitou 8000 bytes"]
end

check("a notificação só chega no commit; um rollback não a entrega") do
  listener = listener_for("vetra_sonda_commit")
  sender = connect
  sender.transaction { |tx| tx.exec("SELECT pg_notify('vetra_sonda_commit', 'confirmado')") }
  begin
    sender.transaction do |tx|
      tx.exec("SELECT pg_notify('vetra_sonda_commit', 'desfeito')")
      raise "falha"
    end
  rescue RuntimeError
    nil
  end
  got = drain(listener)
  [got == ["confirmado"], "recebido: #{got.inspect}"]
end

check("notificações idênticas na mesma transação chegam uma só vez (úteis contra rajadas de 'digitando')") do
  listener = listener_for("vetra_sonda_dup")
  sender = connect
  sender.transaction do |tx|
    3.times { tx.exec("SELECT pg_notify('vetra_sonda_dup', 'digitando:sala1:usuario7')") }
    tx.exec("SELECT pg_notify('vetra_sonda_dup', 'digitando:sala1:usuario8')")
  end
  got = drain(listener)
  [got.sort == ["digitando:sala1:usuario7", "digitando:sala1:usuario8"], "recebido: #{got.inspect}"]
end

check("o LISTEN pertence à sessão: outra conexão do pool não recebe") do
  listener = listener_for("vetra_sonda_sessao")
  other = connect
  connect.exec("SELECT pg_notify('vetra_sonda_sessao', 'x')")
  heard_by_listener = drain(listener)
  heard_by_other = drain(other, wait: 0.2)
  [heard_by_listener == ["x"] && heard_by_other.empty?, "listener=#{heard_by_listener.inspect} outra=#{heard_by_other.inspect}"]
end

check("uma tabela UNLOGGED gera muito menos WAL que uma comum (presença não pesa no log)") do
  conn = connect
  conn.exec("DROP TABLE IF EXISTS vetra_sonda_u, vetra_sonda_l")
  conn.exec("CREATE UNLOGGED TABLE vetra_sonda_u (usuario int, dispositivo text, expira_em timestamptz)")
  conn.exec("CREATE TABLE vetra_sonda_l (usuario int, dispositivo text, expira_em timestamptz)")
  wal = lambda do |table|
    before = conn.exec("SELECT pg_current_wal_lsn()").getvalue(0, 0)
    conn.exec("INSERT INTO #{table} SELECT g, 'web', now() FROM generate_series(1, 50000) g")
    conn.exec("SELECT pg_wal_lsn_diff(pg_current_wal_lsn(), '#{before}')::bigint").getvalue(0, 0).to_i
  end
  unlogged = wal.call("vetra_sonda_u")
  logged = wal.call("vetra_sonda_l")
  conn.exec("DROP TABLE vetra_sonda_u, vetra_sonda_l")
  [unlogged * 10 < logged, "50 mil linhas: UNLOGGED #{unlogged} bytes de WAL, comum #{logged} bytes"]
end

width = RESULTS.map { |_, name, _| name.size }.max
puts "PostgreSQL #{connect.exec('SHOW server_version').getvalue(0, 0)} | pg #{PG::VERSION}"
RESULTS.each { |ok, name, detail| puts "  #{ok ? 'PASS' : 'FAIL'}  #{name.ljust(width)}  | #{detail}" }
puts RESULTS.all? { |ok, _, _| ok } ? "Resultado: todas as verificações passaram." : "Resultado: há verificações com falha."
exit(RESULTS.all? { |ok, _, _| ok } ? 0 : 1)

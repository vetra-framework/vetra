#!/usr/bin/env ruby
# Sonda do ADR-003: confere contra um PostgreSQL real os comportamentos do Sequel
# e do driver pg em que a decisão se apoia. Não faz parte da suíte do compilador.
#
#   DATABASE_URL=postgres://usuario@127.0.0.1:5432/descartavel ruby script/sonda_adr003.rb
#
# Use um banco descartável: cria e remove a tabela vetra_sonda_leads. As gems
# (sequel, pg, async) são instaladas por bundler/inline, fora do Gemfile do projeto.
require "bundler/inline"

gemfile do
  source "https://rubygems.org"
  gem "sequel", "5.109.0"
  gem "pg"
  gem "async"
  gem "logger" # deixou de ser gem padrão no Ruby 4.0
end

require "logger"
require "open3"
require "stringio"

URL = ENV.fetch("DATABASE_URL", "postgres://postgres@127.0.0.1:5432/postgres")
TABLE = :vetra_sonda_leads
MODE = ARGV.first

def check(results, name)
  ok, detail = yield
  results << [ok, name, detail]
rescue Exception => e
  results << [false, name, "#{e.class}: #{e.message.lines.first&.strip}"]
end

def connect(max: 4, auto: true)
  db = Sequel.connect(URL, max_connections: max)
  db.extension :pg_auto_parameterize if auto
  db
end

def setting(db)
  db.get(Sequel.function(:current_setting, "vetra.ctx", true))
end

def blank?(value)
  value.nil? || value.empty?
end

def report(results, title)
  width = results.map { |_, name, _| name.size }.max
  puts title
  results.each { |ok, name, detail| puts "  #{ok ? 'PASS' : 'FAIL'}  #{name.ljust(width)}  | #{detail.to_s[0, 150]}" }
  results.all? { |ok, _, _| ok }
end

def general
  results = []
  setup = connect(auto: false)
  setup.run("DROP TABLE IF EXISTS #{TABLE}")
  setup.run("CREATE TABLE #{TABLE} (id serial PRIMARY KEY, name text NOT NULL)")
  setup.run("INSERT INTO #{TABLE} (name) VALUES ('a'), ('b'), ('c')")

  check(results, "valores viram parâmetros (pg_auto_parameterize)") do
    io = StringIO.new
    db = connect
    db.loggers << Logger.new(io)
    db[TABLE].where(name: "x' OR '1'='1").all
    line = io.string.lines.grep(/#{TABLE}/).first.to_s
    sql = line[/(SELECT .*?)(?:; \[|\s*\z)/m, 1].to_s
    [sql.include?("$1") && !sql.include?("OR '1'='1"), sql]
  end
  check(results, "sem a extensão o Sequel literaliza o valor (contraste)") do
    io = StringIO.new
    db = connect(auto: false)
    db.loggers << Logger.new(io)
    db[TABLE].where(name: "abc").all
    sql = io.string.lines.grep(/#{TABLE}/).first.to_s
    [sql.include?("'abc'") && !sql.include?("$1"), sql.strip]
  end
  check(results, "consulta parametrizada não cria statement nomeado") do
    db = connect(max: 1)
    db[TABLE].where(name: "a").all
    count = db.get(Sequel.lit("count(*) FROM pg_prepared_statements"))
    [count.zero?, "statements nomeados: #{count}"]
  end
  check(results, "Dataset#prepare cria statement nomeado (por isso o núcleo não usa)") do
    db = connect(max: 1, auto: false)
    db[TABLE].where(name: :$n).prepare(:select, :por_nome).call(n: "a")
    count = db.get(Sequel.lit("count(*) FROM pg_prepared_statements"))
    [count >= 1, "statements nomeados: #{count}"]
  end
  check(results, "SET LOCAL não aceita parâmetro de protocolo") do
    db = connect(max: 1, auto: false)
    message = begin
      db.transaction { db.synchronize { |conn| conn.exec_params("SET LOCAL vetra.ctx = $1", ["tok"]) } }
      nil
    rescue Sequel::DatabaseError => e
      e.message.lines.first.strip
    end
    [!message.nil?, message || "aceitou (inesperado)"]
  end
  check(results, "set_config(..., true) vale na transação") do
    db = connect(max: 1)
    seen = db.transaction do
      db.get(Sequel.function(:set_config, "vetra.ctx", "token-123", true))
      setting(db)
    end
    [seen == "token-123", "visto: #{seen.inspect}"]
  end
  check(results, "conexão devolvida ao pool sem contexto (commit)") do
    db = connect(max: 1)
    db.transaction { db.get(Sequel.function(:set_config, "vetra.ctx", "token-123", true)) }
    [blank?(setting(db)), "depois: #{setting(db).inspect}"]
  end
  check(results, "conexão devolvida ao pool sem contexto (rollback)") do
    db = connect(max: 1)
    begin
      db.transaction do
        db.get(Sequel.function(:set_config, "vetra.ctx", "token-123", true))
        raise "falha"
      end
    rescue RuntimeError
      nil
    end
    [blank?(setting(db)), "depois: #{setting(db).inspect}"]
  end
  check(results, "set_config local é desfeito no rollback do savepoint") do
    db = connect(max: 1)
    inside = outside = nil
    db.transaction do
      db.transaction(savepoint: true) do
        db.get(Sequel.function(:set_config, "vetra.ctx", "dentro", true))
        inside = setting(db)
        raise Sequel::Rollback
      end
      outside = setting(db)
    end
    [inside == "dentro" && blank?(outside), "dentro=#{inside.inspect} depois=#{outside.inspect}"]
  end
  check(results, "hooks com savepoint: true respeitam o savepoint revertido") do
    db = connect(max: 1)
    log = []
    db.transaction do
      db.transaction(savepoint: true) do
        db.after_commit(savepoint: true) { log << :commit_do_savepoint }
        db.after_rollback(savepoint: true) { log << :rollback_do_savepoint }
        raise Sequel::Rollback
      end
      db.after_commit { log << :commit_externo }
      log << :fim_do_bloco
    end
    [log == %i[rollback_do_savepoint fim_do_bloco commit_externo], log.inspect]
  end
  check(results, "for_update.skip_locked gera FOR UPDATE SKIP LOCKED") do
    sql = connect(auto: false)[TABLE].for_update.skip_locked.sql
    [sql.end_with?("FOR UPDATE SKIP LOCKED"), sql]
  end
  check(results, "SKIP LOCKED pula a linha travada por outra transação") do
    db = connect
    ids = db.transaction do
      locked = db[TABLE].order(:id).limit(1).for_update.first
      other = Thread.new { db.transaction { db[TABLE].order(:id).limit(1).for_update.skip_locked.first } }.value
      [locked[:id], other && other[:id]]
    end
    [ids[1] && ids[1] != ids[0], "travou id=#{ids[0]}, a outra pegou id=#{ids[1]}"]
  end
  check(results, "transaction(read_only: true) recusa escrita") do
    db = connect(max: 1)
    message = begin
      db.transaction(read_only: true) { db[TABLE].insert(name: "z") }
      nil
    rescue Sequel::DatabaseError => e
      e.message.lines.first.strip
    end
    [message&.match?(/read-only/i), message || "aceitou escrita"]
  end
  check(results, "o Sequel não recusa consulta fora de transação (a recusa é do Vetra)") do
    [connect[TABLE].count == 3, "linhas: #{connect[TABLE].count}"]
  end

  setup.run("DROP TABLE IF EXISTS #{TABLE}")
  results
end

def fibers(with_extension)
  Sequel.extension :fiber_concurrency if with_extension
  results = []
  label = with_extension ? "COM" : "SEM"
  check(results, "#{label} fiber_concurrency: a fibra B #{with_extension ? 'não vê' : 'vê'} a transação da fibra A") do
    db = connect(max: 2)
    seen = nil
    a = Fiber.new { db.transaction { Fiber.yield } }
    a.resume
    Fiber.new { seen = db.in_transaction? }.resume
    a.resume
    [seen == !with_extension, "B.in_transaction? = #{seen.inspect}"]
  end
  check(results, "#{label} fiber_concurrency: o contexto da fibra A #{with_extension ? 'não aparece' : 'aparece'} na B") do
    db = connect(max: 2)
    leak = nil
    a = Fiber.new do
      db.transaction do
        db.get(Sequel.function(:set_config, "vetra.ctx", "so-da-A", true))
        Fiber.yield
      end
    end
    a.resume
    Fiber.new { leak = db.transaction { setting(db) } }.resume
    a.resume
    [with_extension ? blank?(leak) : leak == "so-da-A", "B enxergou: #{leak.inspect}"]
  end
  results
end

def scheduler
  require "async"
  Sequel.extension :fiber_concurrency
  results = []
  check(results, "pg cede a fibra durante a consulta (4 fibras x pg_sleep(1) sobrepostas no servidor)") do
    db = connect(max: 4)
    db.run("SELECT 1")
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    janelas = []
    Async do |task|
      # Cada fibra registra o início e o fim da sua espera no relógio do servidor. Se o pg bloqueasse a thread, a
      # segunda espera só começaria depois do fim da primeira, e as janelas não teriam um instante em comum.
      4.times.map do
        task.async do
          db.transaction do
            inicio = db.get(Sequel.function(:clock_timestamp))
            db.get(Sequel.function(:pg_sleep, 1))
            janelas << [inicio, db.get(Sequel.function(:clock_timestamp))]
          end
        end
      end.each(&:wait)
    end
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    comum = janelas.map(&:last).min - janelas.map(&:first).max # janela que as quatro esperas compartilham
    # O tempo total fica como indício: depende da máquina, e só a sobreposição no servidor decide o veredito.
    [janelas.size == 4 && comum.positive?, "janela comum de #{(comum * 1000).round} ms entre as 4 esperas; total #{elapsed.round(2)} s (serial seria ~4 s)"]
  end
  results
end

if MODE
  results = case MODE
            when "--fibras-sem" then fibers(false)
            when "--fibras-com" then fibers(true)
            when "--agendador" then scheduler
            else abort("modo desconhecido: #{MODE}")
            end
  puts results.map { |ok, name, detail| [ok ? "PASS" : "FAIL", name, detail].join("\t") }
  exit(results.all? { |ok, _, _| ok } ? 0 : 1)
end

db = connect(auto: false)
puts "ruby #{RUBY_VERSION} | sequel #{Sequel::VERSION} | pg #{PG::VERSION} (libpq #{PG.library_version}) | #{db.get(Sequel.function(:version))}"
db.disconnect
all_ok = report(general, "Comportamento geral")
%w[--fibras-sem --fibras-com --agendador].each do |mode|
  output, status = Bundler.with_unbundled_env { Open3.capture2e({ "DATABASE_URL" => URL }, RbConfig.ruby, __FILE__, mode) }
  rows = output.lines.select { |line| line.start_with?("PASS", "FAIL") }.map { |line| line.chomp.split("\t") }
  results = rows.map { |ok, name, detail| [ok == "PASS", name, detail] }
  results << [false, mode, output.lines.last(3).join.strip] if results.empty?
  all_ok &= report(results, "Fibras (#{mode.delete_prefix('--')})")
  all_ok &= status.success?
end
puts all_ok ? "Resultado: todas as verificações passaram." : "Resultado: há verificações com falha."
exit(all_ok ? 0 : 1)

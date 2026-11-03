#!/usr/bin/env ruby
# Sonda do ADR-015: mede num PostgreSQL real o nível de lock e o custo das operações de DDL em que a
# estratégia expand/contract se apoia. Não faz parte da suíte do compilador.
#
#   DATABASE_URL=postgres://usuario@127.0.0.1:5432/descartavel ruby script/sonda_adr015.rb
#
# Use um banco descartável: cria e remove as tabelas vetra_sonda_* (até 1 milhão de linhas) e o tipo
# vetra_sonda_estado. A gem pg é instalada por bundler/inline, fora do Gemfile do projeto.
require "bundler/inline"

gemfile do
  source "https://rubygems.org"
  gem "pg"
end

URL = ENV.fetch("DATABASE_URL", "postgres://postgres@127.0.0.1:5432/postgres")
PAI = "vetra_sonda_pai"
FILHO = "vetra_sonda_filho"
RANK = %w[AccessShareLock RowShareLock RowExclusiveLock ShareUpdateExclusiveLock ShareLock ShareRowExclusiveLock ExclusiveLock AccessExclusiveLock].freeze
RESULTS = []

def connect
  PG.connect(URL).tap { |conn| conn.exec("SET client_min_messages = warning") }
end

def clock
  Process.clock_gettime(Process::CLOCK_MONOTONIC)
end

def reset(conn)
  conn.exec("DROP TABLE IF EXISTS #{FILHO}, #{PAI} CASCADE")
  conn.exec("CREATE TABLE #{PAI} (id int PRIMARY KEY)")
  conn.exec("CREATE TABLE #{FILHO} (id int PRIMARY KEY, pai_id int, nome text, v int)")
  conn.exec("INSERT INTO #{PAI} SELECT g FROM generate_series(1, 1000) g")
  conn.exec("INSERT INTO #{FILHO} SELECT g, 1 + g % 1000, 'n' || g, g FROM generate_series(1, 1000000) g")
  conn.exec("ANALYZE")
end

def filenode(conn, table)
  conn.exec_params("SELECT pg_relation_filenode($1::regclass)::text", [table]).getvalue(0, 0)
end

# Varreduras sequenciais da tabela segundo as estatísticas do servidor. O que a sonda quer saber é se a operação
# varre a tabela; o tempo só acompanha e oscila com checkpoint, autovacuum e a carga da máquina, então não decide
# o veredito. pg_stat_force_next_flush() grava as estatísticas pendentes da sessão antes de a leitura seguinte.
def seq_scans(conn, table)
  conn.exec("SELECT pg_stat_force_next_flush()")
  conn.exec_params("SELECT seq_scan FROM pg_stat_user_tables WHERE relname = $1", [table]).getvalue(0, 0).to_i
end

# Executa o bloco e devolve [varreduras da tabela, segundos].
def scanned(conn, table)
  before = seq_scans(conn, table)
  t0 = clock
  yield
  elapsed = clock - t0
  [seq_scans(conn, table) - before, elapsed]
end

# Executa o DDL numa transação, lê os locks de tabela da sessão e desfaz tudo.
def strongest_locks(conn, sql)
  conn.exec("BEGIN")
  conn.exec(sql)
  rows = conn.exec_params(<<~SQL, [PAI, FILHO]).to_a
    SELECT c.relname AS tabela, l.mode
      FROM pg_locks l JOIN pg_class c ON c.oid = l.relation
     WHERE l.pid = pg_backend_pid() AND l.locktype = 'relation' AND c.relname IN ($1, $2)
  SQL
  rows.group_by { |row| row["tabela"] }.to_h do |table, list|
    [table.delete_prefix("vetra_sonda_"), list.map { |row| row["mode"] }.max_by { |mode| RANK.index(mode) || -1 }]
  end
ensure
  conn.exec("ROLLBACK")
end

def check(name)
  ok, detail = yield
  RESULTS << [ok, name, detail]
rescue Exception => e
  RESULTS << [false, name, "#{e.class}: #{e.message.lines.first&.strip}"]
end

conn = connect
version = conn.exec("SHOW server_version").getvalue(0, 0)
reset(conn)

lock_cases = {
  "ADD COLUMN nulo" => ["ALTER TABLE #{FILHO} ADD COLUMN extra int", { "filho" => "AccessExclusiveLock" }],
  "ADD COLUMN NOT NULL com default constante" => ["ALTER TABLE #{FILHO} ADD COLUMN extra int NOT NULL DEFAULT 0", { "filho" => "AccessExclusiveLock" }],
  "RENAME COLUMN" => ["ALTER TABLE #{FILHO} RENAME COLUMN nome TO titulo", { "filho" => "AccessExclusiveLock" }],
  "DROP COLUMN" => ["ALTER TABLE #{FILHO} DROP COLUMN nome", { "filho" => "AccessExclusiveLock" }],
  "CREATE INDEX (bloqueante)" => ["CREATE INDEX vetra_sonda_idx ON #{FILHO} (v)", { "filho" => "ShareLock" }],
  "ADD FOREIGN KEY (valida na hora)" => ["ALTER TABLE #{FILHO} ADD FOREIGN KEY (pai_id) REFERENCES #{PAI} (id)", { "filho" => "ShareRowExclusiveLock", "pai" => "ShareRowExclusiveLock" }],
  "ADD FOREIGN KEY NOT VALID" => ["ALTER TABLE #{FILHO} ADD FOREIGN KEY (pai_id) REFERENCES #{PAI} (id) NOT VALID", { "filho" => "ShareRowExclusiveLock", "pai" => "ShareRowExclusiveLock" }],
  "ADD CHECK NOT VALID" => ["ALTER TABLE #{FILHO} ADD CONSTRAINT vetra_sonda_ck CHECK (nome IS NOT NULL) NOT VALID", { "filho" => "AccessExclusiveLock" }],
  "ENABLE ROW LEVEL SECURITY" => ["ALTER TABLE #{FILHO} ENABLE ROW LEVEL SECURITY", { "filho" => "AccessExclusiveLock" }],
  "FORCE ROW LEVEL SECURITY" => ["ALTER TABLE #{FILHO} FORCE ROW LEVEL SECURITY", { "filho" => "AccessExclusiveLock" }],
  "CREATE POLICY" => ["CREATE POLICY vetra_sonda_pol ON #{FILHO} USING (v > 0)", { "filho" => "AccessExclusiveLock" }]
}
lock_cases.each do |name, (sql, expected)|
  check("lock: #{name}") do
    observed = strongest_locks(conn, sql)
    [expected.all? { |table, mode| observed[table] == mode }, observed.map { |table, mode| "#{table}=#{mode}" }.join(" ")]
  end
end

check("lock: ALTER POLICY e DROP POLICY pedem AccessExclusiveLock") do
  conn.exec("CREATE POLICY vetra_sonda_pol2 ON #{FILHO} USING (v > 0)")
  altered = strongest_locks(conn, "ALTER POLICY vetra_sonda_pol2 ON #{FILHO} USING (v > 1)")
  dropped = strongest_locks(conn, "DROP POLICY vetra_sonda_pol2 ON #{FILHO}")
  conn.exec("DROP POLICY vetra_sonda_pol2 ON #{FILHO}")
  [altered["filho"] == "AccessExclusiveLock" && dropped["filho"] == "AccessExclusiveLock", "ALTER=#{altered['filho']} DROP=#{dropped['filho']}"]
end

check("lock: VALIDATE CONSTRAINT só pede ShareUpdateExclusiveLock") do
  conn.exec("ALTER TABLE #{FILHO} ADD CONSTRAINT vetra_sonda_fk FOREIGN KEY (pai_id) REFERENCES #{PAI} (id) NOT VALID")
  observed = strongest_locks(conn, "ALTER TABLE #{FILHO} VALIDATE CONSTRAINT vetra_sonda_fk")
  conn.exec("ALTER TABLE #{FILHO} DROP CONSTRAINT vetra_sonda_fk")
  [observed["filho"] == "ShareUpdateExclusiveLock", observed.map { |table, mode| "#{table}=#{mode}" }.join(" ")]
end

check("lock: CREATE INDEX CONCURRENTLY pede ShareUpdateExclusiveLock e não ShareLock") do
  observer = connect
  seen = []
  done = false
  watcher = Thread.new do
    until done
      seen.concat(observer.exec_params(<<~SQL, [FILHO]).map { |row| row["mode"] })
        SELECT l.mode FROM pg_locks l JOIN pg_class c ON c.oid = l.relation
         WHERE c.relname = $1 AND l.locktype = 'relation' AND l.pid <> pg_backend_pid()
      SQL
      sleep 0.01
    end
  end
  conn.exec("CREATE INDEX CONCURRENTLY vetra_sonda_idx2 ON #{FILHO} (v)")
  done = true
  watcher.join
  modes = seen.uniq
  [modes.include?("ShareUpdateExclusiveLock") && !modes.include?("ShareLock"), "modos vistos de outra sessão: #{modes.sort.join(', ')}"]
ensure
  conn.exec("DROP INDEX IF EXISTS vetra_sonda_idx2")
end

check("CREATE INDEX CONCURRENTLY não roda dentro de transação") do
  conn.exec("BEGIN")
  message = begin
    conn.exec("CREATE INDEX CONCURRENTLY vetra_sonda_idx3 ON #{FILHO} (v)")
    nil
  rescue PG::Error => e
    e.message.lines.first.strip
  ensure
    conn.exec("ROLLBACK")
  end
  [!message.nil?, message || "aceitou (inesperado)"]
end

# Custo: reescrita de tabela e varredura.
check("ADD COLUMN com default constante não reescreve a tabela") do
  before = filenode(conn, FILHO)
  conn.exec("ALTER TABLE #{FILHO} ADD COLUMN c1 int NOT NULL DEFAULT 7")
  [filenode(conn, FILHO) == before, "filenode igual: #{filenode(conn, FILHO) == before}"]
end
check("ADD COLUMN com default volátil reescreve a tabela") do
  before = filenode(conn, FILHO)
  conn.exec("ALTER TABLE #{FILHO} ADD COLUMN c2 double precision DEFAULT random()")
  [filenode(conn, FILHO) != before, "filenode mudou: #{filenode(conn, FILHO) != before}"]
end
check("ALTER COLUMN TYPE int -> bigint reescreve a tabela") do
  before = filenode(conn, FILHO)
  conn.exec("ALTER TABLE #{FILHO} ALTER COLUMN v TYPE bigint")
  [filenode(conn, FILHO) != before, "filenode mudou: #{filenode(conn, FILHO) != before}"]
end
check("SET NOT NULL varre a tabela sem CHECK validado e não varre com ele") do
  conn.exec("ALTER TABLE #{FILHO} ADD COLUMN a int, ADD COLUMN b int")
  conn.exec("UPDATE #{FILHO} SET a = 1, b = 1")
  conn.exec("ANALYZE #{FILHO}")
  varre_sem, sem = scanned(conn, FILHO) { conn.exec("ALTER TABLE #{FILHO} ALTER COLUMN a SET NOT NULL") }
  conn.exec("ALTER TABLE #{FILHO} ADD CONSTRAINT vetra_sonda_b CHECK (b IS NOT NULL) NOT VALID")
  conn.exec("ALTER TABLE #{FILHO} VALIDATE CONSTRAINT vetra_sonda_b")
  varre_com, com = scanned(conn, FILHO) { conn.exec("ALTER TABLE #{FILHO} ALTER COLUMN b SET NOT NULL") }
  [varre_sem.positive? && varre_com.zero?,
   "sem CHECK: #{varre_sem} varredura(s), #{(sem * 1000).round} ms; com CHECK validado: #{varre_com} varredura(s), #{(com * 1000).round} ms"]
end
check("ADD FOREIGN KEY NOT VALID não varre a tabela; VALIDATE varre") do
  conn.exec("ALTER TABLE #{FILHO} DROP CONSTRAINT IF EXISTS vetra_sonda_fk")
  varre_rapido, rapido = scanned(conn, FILHO) do
    conn.exec("ALTER TABLE #{FILHO} ADD CONSTRAINT vetra_sonda_fk FOREIGN KEY (pai_id) REFERENCES #{PAI} (id) NOT VALID")
  end
  varre_lento, lento = scanned(conn, FILHO) { conn.exec("ALTER TABLE #{FILHO} VALIDATE CONSTRAINT vetra_sonda_fk") }
  [varre_rapido.zero? && varre_lento.positive?,
   "NOT VALID: #{varre_rapido} varredura(s), #{(rapido * 1000).round} ms; VALIDATE: #{varre_lento} varredura(s), #{(lento * 1000).round} ms"]
end

# Fila de locks: um DDL à espera bloqueia as leituras que chegam depois dele.
check("lock_timeout derruba o DDL que não consegue o lock (SQLSTATE 55P03)") do
  holder = connect
  holder.exec("BEGIN")
  holder.exec("SELECT count(*) FROM #{FILHO}")
  ddl = connect
  ddl.exec("SET lock_timeout = '200ms'")
  code = begin
    ddl.exec("ALTER TABLE #{FILHO} ADD COLUMN lt int")
    nil
  rescue PG::Error => e
    e.result.error_field(PG::PG_DIAG_SQLSTATE)
  end
  holder.exec("ROLLBACK")
  [code == "55P03", "SQLSTATE: #{code.inspect}"]
end
check("sem lock_timeout, um DDL à espera bloqueia leituras que chegam depois dele") do
  holder = connect
  holder.exec("BEGIN")
  holder.exec("SELECT count(*) FROM #{FILHO}")
  ddl_thread = Thread.new do
    ddl = connect
    ddl.exec("SET statement_timeout = '1500ms'")
    ddl.exec("ALTER TABLE #{FILHO} ADD COLUMN fila int") rescue nil
  end
  sleep 0.3
  reader = connect
  reader.exec("SET statement_timeout = '400ms'")
  code = begin
    reader.exec("SELECT 1 FROM #{FILHO} LIMIT 1")
    nil
  rescue PG::Error => e
    e.result.error_field(PG::PG_DIAG_SQLSTATE)
  end
  ddl_thread.join
  holder.exec("ROLLBACK")
  [code == "57014", "leitura comum expirou na fila do DDL (SQLSTATE #{code.inspect})"]
end

conn.exec("DROP TABLE IF EXISTS #{FILHO}, #{PAI} CASCADE")

# ADR-025, questões 3, 4 e 6: tabela particionada, chave composta por tenant e enum. O comportamento das tabelas
# particionadas muda com a versão; se o pai passar a aceitar NOT VALID ou CONCURRENTLY, o padrão do plano muda
# naquela versão (ADR-025, §3). Por isso essas verificações conferem o esperado para cada versão.
PART = "vetra_sonda_part"
EMPRESA = "vetra_sonda_empresa"
REF = "vetra_sonda_ref"
TENANT_FILHO = "vetra_sonda_tfilho"
ENUM_TABELA = "vetra_sonda_enum"
ENUM_TIPO = "vetra_sonda_estado"
MAJOR = conn.exec("SHOW server_version_num").getvalue(0, 0).to_i / 10_000

# Executa o SQL e devolve nil, ou o SQLSTATE do erro.
def sqlstate(conn, sql)
  conn.exec(sql)
  nil
rescue PG::Error => e
  e.result&.error_field(PG::PG_DIAG_SQLSTATE) || e.message.lines.first.strip
end

def index_valid?(conn, name)
  conn.exec_params("SELECT indisvalid FROM pg_index WHERE indexrelid = $1::regclass", [name]).getvalue(0, 0) == "t"
end

conn.exec("DROP TABLE IF EXISTS #{PART}, #{EMPRESA} CASCADE")
conn.exec("CREATE TABLE #{EMPRESA} (id int PRIMARY KEY)")
conn.exec("INSERT INTO #{EMPRESA} SELECT g FROM generate_series(1, 4) g")
conn.exec("CREATE TABLE #{PART} (company_id int NOT NULL, id int NOT NULL, v int) PARTITION BY LIST (company_id)")
(1..3).each { |n| conn.exec("CREATE TABLE #{PART}_#{n} PARTITION OF #{PART} FOR VALUES IN (#{n})") }
conn.exec("INSERT INTO #{PART} SELECT 1 + g % 3, g, g FROM generate_series(1, 30000) g")

check("particionada: CREATE INDEX CONCURRENTLY no pai é recusado") do
  code = sqlstate(conn, "CREATE INDEX CONCURRENTLY vetra_sonda_part_cic ON #{PART} (v)")
  conn.exec("DROP INDEX IF EXISTS vetra_sonda_part_cic")
  [code == "0A000", code ? "recusado (SQLSTATE #{code})" : "aceito no #{MAJOR}: rever o ADR-025, §3, decisão 1"]
end
check("particionada: ON ONLY, CONCURRENTLY por partição e ATTACH validam o índice do pai; partição nova herda") do
  conn.exec("CREATE INDEX vetra_sonda_part_v ON ONLY #{PART} (v)")
  invalid_first = !index_valid?(conn, "vetra_sonda_part_v")
  (1..3).each do |n|
    conn.exec("CREATE INDEX CONCURRENTLY vetra_sonda_part_#{n}_v ON #{PART}_#{n} (v)")
    conn.exec("ALTER INDEX vetra_sonda_part_v ATTACH PARTITION vetra_sonda_part_#{n}_v")
  end
  valid_after = index_valid?(conn, "vetra_sonda_part_v")
  conn.exec("CREATE TABLE #{PART}_4 PARTITION OF #{PART} FOR VALUES IN (4)")
  inherited = conn.exec_params(<<~SQL, ["#{PART}_4", "vetra_sonda_part_v"]).getvalue(0, 0).to_i == 1
    SELECT count(*) FROM pg_inherits i JOIN pg_index x ON x.indexrelid = i.inhrelid
     WHERE i.inhparent = $2::regclass AND x.indrelid = $1::regclass AND x.indisvalid
  SQL
  [invalid_first && valid_after && inherited,
   "inválido depois do ON ONLY=#{invalid_first}; válido depois dos ATTACH=#{valid_after}; partição nova com índice=#{inherited}"]
end
check("particionada: FOREIGN KEY NOT VALID no pai conforme a versão; na partição e a chave completa no pai valem") do
  parent = sqlstate(conn, "ALTER TABLE #{PART} ADD CONSTRAINT vetra_sonda_part_fk FOREIGN KEY (company_id) REFERENCES #{EMPRESA} (id) NOT VALID")
  conn.exec("ALTER TABLE #{PART} DROP CONSTRAINT IF EXISTS vetra_sonda_part_fk")
  partition = sqlstate(conn, "ALTER TABLE #{PART}_1 ADD CONSTRAINT vetra_sonda_part1_fk FOREIGN KEY (company_id) REFERENCES #{EMPRESA} (id) NOT VALID")
  conn.exec("ALTER TABLE #{PART}_1 DROP CONSTRAINT IF EXISTS vetra_sonda_part1_fk")
  full = sqlstate(conn, "ALTER TABLE #{PART} ADD CONSTRAINT vetra_sonda_part_fk2 FOREIGN KEY (company_id) REFERENCES #{EMPRESA} (id)")
  conn.exec("ALTER TABLE #{PART} DROP CONSTRAINT IF EXISTS vetra_sonda_part_fk2")
  # O PostgreSQL 18 passou a aceitar NOT VALID em chave estrangeira de tabela particionada; o 17 recusa com 42809.
  [(MAJOR >= 18 ? parent.nil? : parent == "42809") && partition.nil? && full.nil?,
   "pai: #{parent ? "recusado (SQLSTATE #{parent})" : 'aceito'}; partição: #{partition ? "recusado (#{partition})" : 'aceito'}; " \
   "chave completa no pai: #{full ? "recusada (#{full})" : 'aceita'}"]
end
check("particionada: CHECK NOT VALID e VALIDATE no pai") do
  added = sqlstate(conn, "ALTER TABLE #{PART} ADD CONSTRAINT vetra_sonda_part_ck CHECK (v > 0) NOT VALID")
  validated = added ? :pulado : sqlstate(conn, "ALTER TABLE #{PART} VALIDATE CONSTRAINT vetra_sonda_part_ck")
  [added.nil? && validated.nil?, "NOT VALID: #{added || 'aceito'}; VALIDATE: #{validated || 'aceito'}"]
end
conn.exec("DROP TABLE IF EXISTS #{PART}, #{EMPRESA} CASCADE")

# Chave composta por tenant (ADR-025, §4): o índice único de apoio na tabela referenciada vem antes da chave, e
# a validação não bloqueia escrita na filha.
conn.exec("DROP TABLE IF EXISTS #{TENANT_FILHO}, #{REF} CASCADE")
conn.exec("CREATE TABLE #{REF} (id int PRIMARY KEY, company_id int NOT NULL)")
conn.exec("CREATE TABLE #{TENANT_FILHO} (id int PRIMARY KEY, company_id int NOT NULL, ref_id int NOT NULL)")
conn.exec("INSERT INTO #{REF} SELECT g, 1 + g % 10 FROM generate_series(1, 100000) g")
conn.exec("INSERT INTO #{TENANT_FILHO} SELECT g, 1 + (1 + g % 100000) % 10, 1 + g % 100000 FROM generate_series(1, 1000000) g")
conn.exec("ANALYZE #{REF}, #{TENANT_FILHO}")

check("chave composta por tenant exige o índice único (company_id, id) antes da chave") do
  fk = "ALTER TABLE #{TENANT_FILHO} ADD CONSTRAINT vetra_sonda_tfk FOREIGN KEY (company_id, ref_id) REFERENCES #{REF} (company_id, id) NOT VALID"
  without = sqlstate(conn, fk)
  conn.exec("CREATE UNIQUE INDEX CONCURRENTLY vetra_sonda_ref_tenant ON #{REF} (company_id, id)")
  with = sqlstate(conn, fk)
  [without == "42830" && with.nil?, "sem o índice: SQLSTATE #{without.inspect}; com o índice: #{with || 'aceita'}"]
end
check("VALIDATE da chave composta não bloqueia INSERT concorrente na filha") do
  validator = connect
  validator.exec("BEGIN")
  t0 = clock
  validator.exec("ALTER TABLE #{TENANT_FILHO} VALIDATE CONSTRAINT vetra_sonda_tfk")
  validate_ms = ((clock - t0) * 1000).round
  # Com a transação do VALIDATE aberta e seus locks mantidos, outra sessão tenta gravar na filha.
  held = validator.exec_params(<<~SQL, [TENANT_FILHO]).map { |row| row["mode"] }
    SELECT l.mode FROM pg_locks l JOIN pg_class c ON c.oid = l.relation
     WHERE l.pid = pg_backend_pid() AND l.locktype = 'relation' AND c.relname = $1
  SQL
  writer = connect
  writer.exec("SET lock_timeout = '1s'")
  t1 = clock
  code = sqlstate(writer, "INSERT INTO #{TENANT_FILHO} VALUES (2000001, 2, 1)")
  insert_ms = ((clock - t1) * 1000).round
  [code.nil? && held.include?("ShareUpdateExclusiveLock") && !held.include?("ShareLock"),
   "locks do VALIDATE na filha: #{held.uniq.sort.join(', ')}; INSERT concorrente: #{code ? "falhou (SQLSTATE #{code})" : "#{insert_ms} ms"}; VALIDATE: #{validate_ms} ms"]
ensure
  # Encerra a transação do VALIDATE mesmo numa falha, para que a remoção das tabelas não espere pelos locks dela.
  validator&.close
  writer&.close
end
conn.exec("DROP TABLE IF EXISTS #{TENANT_FILHO}, #{REF} CASCADE")

# enum (ADR-025, §6): coluna text com CHECK, nunca o tipo ENUM nativo.
conn.exec("DROP TABLE IF EXISTS #{ENUM_TABELA}")
conn.exec("DROP TYPE IF EXISTS #{ENUM_TIPO}")
conn.exec("CREATE TABLE #{ENUM_TABELA} (id int PRIMARY KEY, estado text NOT NULL CONSTRAINT vetra_sonda_estado_ck CHECK (estado IN ('aberto', 'fechado')))")
conn.exec("INSERT INTO #{ENUM_TABELA} SELECT g, CASE WHEN g % 2 = 0 THEN 'aberto' ELSE 'fechado' END FROM generate_series(1, 10000) g")

check("enum: ampliar o CHECK com NOT VALID e VALIDATE aceita os valores antigos e o novo") do
  conn.exec("ALTER TABLE #{ENUM_TABELA} ADD CONSTRAINT vetra_sonda_estado_ck2 CHECK (estado IN ('aberto', 'fechado', 'arquivado')) NOT VALID")
  conn.exec("ALTER TABLE #{ENUM_TABELA} VALIDATE CONSTRAINT vetra_sonda_estado_ck2")
  conn.exec("ALTER TABLE #{ENUM_TABELA} DROP CONSTRAINT vetra_sonda_estado_ck")
  old_value = sqlstate(conn, "INSERT INTO #{ENUM_TABELA} VALUES (10001, 'aberto')")
  new_value = sqlstate(conn, "INSERT INTO #{ENUM_TABELA} VALUES (10002, 'arquivado')")
  outside = sqlstate(conn, "INSERT INTO #{ENUM_TABELA} VALUES (10003, 'outro')")
  [old_value.nil? && new_value.nil? && outside == "23514",
   "valor antigo: #{old_value || 'aceito'}; novo: #{new_value || 'aceito'}; fora do conjunto: SQLSTATE #{outside.inspect}"]
end
check("enum: estreitar o CHECK só valida depois de migrar as linhas com o valor removido") do
  conn.exec("ALTER TABLE #{ENUM_TABELA} ADD CONSTRAINT vetra_sonda_estado_ck3 CHECK (estado IN ('aberto', 'arquivado')) NOT VALID")
  early = sqlstate(conn, "ALTER TABLE #{ENUM_TABELA} VALIDATE CONSTRAINT vetra_sonda_estado_ck3")
  conn.exec("UPDATE #{ENUM_TABELA} SET estado = 'arquivado' WHERE estado = 'fechado'")
  late = sqlstate(conn, "ALTER TABLE #{ENUM_TABELA} VALIDATE CONSTRAINT vetra_sonda_estado_ck3")
  [early == "23514" && late.nil?, "VALIDATE com linhas antigas: SQLSTATE #{early.inspect}; depois de migrar: #{late || 'aceito'}"]
end
check("enum: o tipo ENUM nativo não tem DROP VALUE nem usa na mesma transação o valor acrescentado") do
  conn.exec("CREATE TYPE #{ENUM_TIPO} AS ENUM ('aberto', 'fechado')")
  drop = sqlstate(conn, "ALTER TYPE #{ENUM_TIPO} DROP VALUE 'fechado'")
  conn.exec("BEGIN")
  conn.exec("ALTER TYPE #{ENUM_TIPO} ADD VALUE 'arquivado'")
  same_tx = sqlstate(conn, "SELECT 'arquivado'::#{ENUM_TIPO}")
  [drop == "0A000" && same_tx == "55P04", "DROP VALUE: SQLSTATE #{drop.inspect}; uso na mesma transação: SQLSTATE #{same_tx.inspect}"]
ensure
  conn.exec("ROLLBACK") unless conn.transaction_status == PG::PQTRANS_IDLE
end
conn.exec("DROP TABLE IF EXISTS #{ENUM_TABELA}")
conn.exec("DROP TYPE IF EXISTS #{ENUM_TIPO}")
width = RESULTS.map { |_, name, _| name.size }.max
puts "PostgreSQL #{version} | pg #{PG::VERSION}"
RESULTS.each { |ok, name, detail| puts "  #{ok ? 'PASS' : 'FAIL'}  #{name.ljust(width)}  | #{detail}" }
puts RESULTS.all? { |ok, _, _| ok } ? "Resultado: todas as verificações passaram." : "Resultado: há verificações com falha."
exit(RESULTS.all? { |ok, _, _| ok } ? 0 : 1)

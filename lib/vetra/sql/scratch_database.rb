# frozen_string_literal: true

require 'open3'
require 'securerandom'
require 'tmpdir'

module Vetra
  module SQL
    # Banco descartável para aplicar planos e tirar o retrato (ADR-025, §1). Cria um banco novo a partir do
    # template0 no servidor de DATABASE_URL, com vetra_migrator como dono, aplica os planos numa conexão que entra como
    # vetra_migrator (ADR-038, §3), roda o pg_dump depois de cada plano e remove o banco, mesmo numa falha. Nunca altera
    # o banco nomeado na URL, e confere que o catálogo dos papéis Vetra é o mesmo antes e depois.
    class ScratchDatabase
      MIGRATOR = 'vetra_migrator'
      ROLES = %w[vetra_app vetra_migrator vetra_owner].freeze
      # O que o vetra_migrator ainda alcança fora do banco temporário: os atributos, vínculos e parâmetros dos papéis, os
      # bancos e tablespaces do servidor (dono, ACL e opções) e as ACLs de parâmetros. $1 é o banco temporário, que sai
      # da comparação.
      ROLE_CATALOG = <<~SQL
        WITH vetra AS (SELECT oid, rolname FROM pg_catalog.pg_roles WHERE rolname IN ('vetra_app', 'vetra_migrator', 'vetra_owner'))
        SELECT pg_catalog.jsonb_build_object(
          'roles', (SELECT pg_catalog.jsonb_agg(pg_catalog.to_jsonb(r) - 'oid' ORDER BY r.rolname) FROM pg_catalog.pg_roles r
                    WHERE r.oid IN (SELECT oid FROM vetra)),
          'members', (SELECT pg_catalog.jsonb_agg(pg_catalog.jsonb_build_array(m.roleid::regrole::text, m.member::regrole::text,
                        m.grantor::regrole::text, m.admin_option, m.inherit_option, m.set_option)
                        ORDER BY m.roleid::regrole::text, m.member::regrole::text, m.grantor::regrole::text)
                      FROM pg_catalog.pg_auth_members m WHERE m.roleid IN (SELECT oid FROM vetra) OR m.member IN (SELECT oid FROM vetra)),
          'settings', (SELECT pg_catalog.jsonb_agg(pg_catalog.jsonb_build_array(d.datname, s.setrole::regrole::text, s.setconfig)
                         ORDER BY d.datname, s.setrole::regrole::text)
                       FROM pg_catalog.pg_db_role_setting s LEFT JOIN pg_catalog.pg_database d ON d.oid = s.setdatabase
                       WHERE d.datname IS DISTINCT FROM $1::text),
          'databases', (SELECT pg_catalog.jsonb_agg(pg_catalog.jsonb_build_array(d.datname, d.datdba::regrole::text, d.datacl::text,
                          d.datconnlimit, d.datallowconn, d.datistemplate) ORDER BY d.datname)
                        FROM pg_catalog.pg_database d WHERE d.datname <> $1::text),
          'tablespaces', (SELECT pg_catalog.jsonb_agg(pg_catalog.jsonb_build_array(t.spcname, t.spcowner::regrole::text, t.spcacl::text,
                            t.spcoptions::text) ORDER BY t.spcname) FROM pg_catalog.pg_tablespace t),
          'parameters', (SELECT pg_catalog.jsonb_agg(pg_catalog.jsonb_build_array(p.parname, p.paracl::text) ORDER BY p.parname)
                         FROM pg_catalog.pg_parameter_acl p),
          'all_roles', (SELECT pg_catalog.jsonb_agg(pg_catalog.jsonb_build_array(r.rolname, r.rolsuper, r.rolcreaterole, r.rolcreatedb,
                          r.rolreplication, r.rolbypassrls, r.rolcanlogin) ORDER BY r.rolname) FROM pg_catalog.pg_roles r))::text
      SQL
      # O hash da senha só é legível com superusuário; sem ele, a comparação não inclui a senha.
      PASSWORDS = <<~SQL
        SELECT pg_catalog.jsonb_agg(pg_catalog.jsonb_build_array(a.rolname, a.rolpassword, a.rolvaliduntil) ORDER BY a.rolname)::text
        FROM pg_catalog.pg_authid a WHERE a.rolname IN ('vetra_app', 'vetra_migrator', 'vetra_owner')
      SQL
      SUPERUSER = 'SELECT rolsuper FROM pg_catalog.pg_roles WHERE rolname = current_user'
      # Objetos globais que o vetra_migrator administraria: bancos e tablespaces de que um papel que ele exerce seja dono
      # ou em que tenha privilégio com GRANT OPTION, e parâmetros com qualquer privilégio (SET ou ALTER SYSTEM num
      # parâmetro alcança o servidor). Os papéis que ele exerce são ele mesmo, os que herda ou assume por SET, PUBLIC e
      # pg_database_owner, que o dono do banco temporário recebe implicitamente. O banco temporário precisa ser a única
      # coisa que ele administra, ou a contenção não vale.
      ADMINISTERED = <<~SQL
        WITH acting AS (
          SELECT r.oid FROM pg_catalog.pg_roles r
          WHERE r.rolname = 'pg_database_owner'
             OR pg_catalog.pg_has_role('vetra_migrator', r.oid, 'USAGE') OR pg_catalog.pg_has_role('vetra_migrator', r.oid, 'SET')
          UNION ALL SELECT 0::oid
        )
        SELECT 'banco ' || d.datname FROM pg_catalog.pg_database d
        WHERE d.datdba IN (SELECT oid FROM acting)
           OR EXISTS (SELECT 1 FROM pg_catalog.aclexplode(d.datacl) a WHERE a.is_grantable AND a.grantee IN (SELECT oid FROM acting))
        UNION ALL
        SELECT 'tablespace ' || t.spcname FROM pg_catalog.pg_tablespace t
        WHERE t.spcowner IN (SELECT oid FROM acting)
           OR EXISTS (SELECT 1 FROM pg_catalog.aclexplode(t.spcacl) a WHERE a.is_grantable AND a.grantee IN (SELECT oid FROM acting))
        UNION ALL
        SELECT 'parâmetro ' || p.parname FROM pg_catalog.pg_parameter_acl p
        WHERE EXISTS (SELECT 1 FROM pg_catalog.aclexplode(p.paracl) a WHERE a.grantee IN (SELECT oid FROM acting))
        ORDER BY 1
      SQL
      # Identidade e poderes da conexão que vai aplicar os planos, conferidos por código do executor, nunca pelo plano.
      IDENTITY = <<~SQL
        SELECT session_user::text, current_user::text, r.rolsuper, r.rolcreaterole, r.rolcreatedb, r.rolreplication
        FROM pg_catalog.pg_roles r WHERE r.rolname = session_user
      SQL
      EXPECTED_IDENTITY = ['vetra_migrator', 'vetra_migrator', 'f', 'f', 'f', 'f'].freeze
      # Sessões do vetra_migrator abertas no servidor: o papel pode encerrar ou cancelar as próprias sessões em qualquer
      # banco (pg_terminate_backend), sem privilégio e sem mudar catálogo. Num servidor descartável não há nenhuma.
      SESSIONS = "SELECT count(*) FROM pg_catalog.pg_stat_activity WHERE usename = 'vetra_migrator'"
      # Variáveis que a libpq usaria para completar o login do migrador com credenciais do administrador.
      LOGIN_ENV = %w[PGPASSWORD PGPASSFILE PGSERVICE PGSERVICEFILE PGUSER].freeze
      # Parâmetros efetivos da conexão temporária que o pg_dump recebe em --dbname; a senha vai só pelo ambiente.
      DUMP_KEYS = %w[host hostaddr port user dbname options target_session_attrs sslmode sslrootcert sslcert sslkey sslcrl
                     sslnegotiation gssencmode channel_binding require_auth krbsrvname connect_timeout].freeze
      # Variáveis herdadas que poderiam levar o pg_dump a outro servidor ou banco (PGSERVICE completa o que falta).
      CLEARED_ENV = %w[PGSERVICE PGSERVICEFILE PGHOST PGHOSTADDR PGPORT PGDATABASE PGUSER PGPASSWORD PGOPTIONS PGSSLMODE
                       PGSSLROOTCERT PGSSLCERT PGSSLKEY PGTARGETSESSIONATTRS PGREQUIRESSL].freeze
      DROPPED = [/\A--/, /\ASET /, /\ASELECT pg_catalog\.set_config\(/, /\A\\(restrict|unrestrict) /].freeze

      def initialize(url:, pg_dump: 'pg_dump', migrator_password: nil, driver: -> { require 'pg' }, connector: ->(target) { PG.connect(target) })
        @url, @pg_dump, @migrator_password, @driver, @connector = url, pg_dump, migrator_password, driver, connector
      end

      # Aplica os planos em ordem num banco novo e devolve o dump normalizado depois de cada um.
      def replay(plans)
        load_driver!
        admin = connect(@url)
        admin.exec('SET client_min_messages = warning')
        self.class.check_pg_dump!(pg_dump_version, admin.server_version / 10_000)
        name = "vetra_plan_#{SecureRandom.hex(6)}"
        # Os atributos e vínculos dos papéis são conferidos pela guarda do gerador atual, rodada pela conexão
        # administrativa antes de qualquer texto dos planos: a guarda que o plano inicial traz é editável.
        begin
          admin.exec(Context.role_guard)
        rescue PG::Error => e
          raise Graph::Error.single('db_plan_role', "Papéis Vetra ausentes ou com poderes a mais no servidor de DATABASE_URL (#{sqlstate(e)}); " \
                                                    'execute e confira o bootstrap operacional do ADR-036 antes de aplicar planos.')
        end
        sessions = admin.exec(SESSIONS).getvalue(0, 0).to_i
        if sessions.positive?
          raise Graph::Error.single('db_plan_role', "O servidor de DATABASE_URL tem #{sessions} sessão(ões) de #{MIGRATOR} abertas; um plano poderia " \
                                                    'encerrá-las, porque o papel sinaliza as próprias sessões. Use um servidor descartável, sem outro uso do migrador.')
        end
        administered = admin.exec(ADMINISTERED).column_values(0)
        unless administered.empty?
          raise Graph::Error.single('db_plan_role', "O servidor de DATABASE_URL tem objetos globais que #{MIGRATOR} administra (#{administered.first(5).join(', ')}); " \
                                                    'os planos rodam como esse papel, então use um servidor descartável em que ele não administre outro banco, tablespace ou parâmetro.')
        end
        before = role_catalog(admin, name)
        begin
          admin.exec("CREATE DATABASE #{name} OWNER \"#{MIGRATOR}\" TEMPLATE template0 ENCODING 'UTF8' LOCALE 'C'")
        rescue PG::Error => e
          raise Graph::Error.single('db_plan_role', "Não foi possível criar o banco temporário com #{MIGRATOR} como dono (#{sqlstate(e)}); execute o " \
                                                    "bootstrap dos papéis (ADR-036) e use em DATABASE_URL um papel que possa assumir #{MIGRATOR}.")
        end
        created = true
        begin
          # O banco temporário só existe no servidor em que a conexão administrativa entrou: com vários hosts na URL,
          # as conexões a ele e o pg_dump ficam fixos nesse servidor.
          pinned = params.merge('dbname' => name, 'host' => admin.host, 'port' => admin.port.to_s, 'hostaddr' => admin.hostaddr.to_s)
          # O pg_dump usa os parâmetros que a conexão administrativa ao banco temporário de fato resolveu, para ler o mesmo banco.
          inspector = connect(pinned)
          effective = inspector.conninfo_hash.transform_keys(&:to_s)
          effective.merge!('host' => inspector.host, 'port' => inspector.port.to_s, 'hostaddr' => inspector.hostaddr.to_s)
          inspector.close
          # Os planos rodam numa conexão que entra como vetra_migrator, nunca por SET ROLE, que o próprio plano desfaria.
          migrator = connect_migrator(pinned)
          migrator.exec('SET client_min_messages = warning')
          identity = migrator.exec(IDENTITY).values.first
          unless identity == EXPECTED_IDENTITY
            raise Graph::Error.single('db_plan_role', "A conexão que aplicaria os planos não é #{MIGRATOR} sem poderes administrativos " \
                                                      "(#{identity&.first(2)&.join('/') || 'sem papel'}); confira o bootstrap e DATABASE_URL.")
          end
          executor = PlanExecutor.new(migrator)
          begin
            dumps = plans.map do |plan|
              executor.apply([plan])
              self.class.normalize_dump(dump(effective))
            end
          ensure
            # Conferido também quando um plano falha: um passo fora de transação pode ter ficado aplicado.
            migrator.close
            migrator = nil
            unless role_catalog(admin, name) == before
              raise Graph::Error.single('db_plan_global', 'Aplicar os planos alterou o catálogo dos papéis Vetra ou de outro banco do servidor ' \
                                                          '(atributos, vínculos, parâmetros, ACL ou senha); um plano não altera objetos fora do banco. ' \
                                                          'Confira o papel vetra_migrator e os bancos do servidor.')
            end
          end
          dumps
        ensure
          migrator&.close
          admin.exec("DROP DATABASE IF EXISTS #{name} WITH (FORCE)") if created
        end
      ensure
        admin&.close
      end

      # O pg_dump precisa ser da mesma versão principal do servidor: um mais antigo recusa o servidor, e um mais novo
      # pode escrever o mesmo esquema de outro jeito, o que faria o retrato depender de quem o gerou.
      def self.check_pg_dump!(version_output, server_major)
        client_major = version_output[/\Apg_dump \(PostgreSQL\) (\d+)/, 1]&.to_i
        return if client_major == server_major
        raise Graph::Error.single('db_pg_dump', "pg_dump #{client_major || 'desconhecido'} não corresponde ao servidor PostgreSQL #{server_major}; " \
                                                "aponte VETRA_PG_DUMP para o pg_dump #{server_major}.")
      end

      # Tira do dump o que depende de quem e quando o gerou (comentários com versões, SET de sessão e as linhas
      # \restrict com chave aleatória) e junta linhas vazias repetidas, mas só entre instruções: uma linha dentro de um
      # literal ou corpo de função fica intacta, para que o retrato não esconda diferença de esquema, privilégio ou RLS.
      # O pg_dump 18 escreve numa partição o nome do NOT NULL herdado do pai (`CONSTRAINT outbox_seq_not_null NOT NULL`);
      # o 17 não tem NOT NULL nomeado. Só o nome padrão do pai, `<pai>_<coluna>_not_null`, sai do retrato, numa coluna
      # de uma tabela `<pai>_...` (a partição, como outbox_default): o retrato fica igual nas duas versões sem esconder
      # outro nome.
      INHERITED_NOT_NULL = /\A(    ([a-z_][a-z0-9_]*) .*) CONSTRAINT ([a-z_][a-z0-9_]*)_\2_not_null NOT NULL(,?)\z/
      CREATE_TABLE = /\ACREATE TABLE [a-z_][a-z0-9_]*\.([a-z_][a-z0-9_]*) \(\z/

      def self.normalize_dump(text)
        kept, scanner, statement = [], StatementScanner.new, nil
        # Tira só o LF de cada linha: um CR dentro de um literal é dado e precisa sobreviver no retrato.
        text.each_line do |raw|
          line = raw.delete_suffix("\n")
          if scanner.boundary?
            next if DROPPED.any? { |pattern| pattern.match?(line) }
            next if line.strip.empty? && (kept.empty? || kept.last.empty?)
            next kept << '' if line.strip.empty?
            statement = line
          elsif (table = CREATE_TABLE.match(statement.to_s)&.[](1)) && !scanner.literal? && (match = INHERITED_NOT_NULL.match(line)) &&
                table.start_with?("#{match[3]}_") && !StatementScanner.new.feed(match[1]).literal?
            # Só uma cláusula de topo: a linha começa fora de literal e o CONSTRAINT não está num literal aberto nela.
            line = "#{match[1]} NOT NULL#{match[4]}"
          end
          kept << line
          scanner.feed(line)
        end
        kept.pop while kept.last&.empty?
        "#{kept.join("\n")}\n"
      end

      private

      def load_driver!
        @driver.call
      rescue LoadError
        raise Graph::Error.single('db_driver', 'db:plan --check e --snapshot exigem a gem pg; acrescente-a ao Gemfile da aplicação.')
      end

      # A mensagem do driver pode repetir trechos da URL, inclusive a senha; o diagnóstico só diz a classe e o SQLSTATE.
      def connect(target)
        @connector.call(target)
      rescue PG::Error => e
        raise Graph::Error.single('db_connection', "Não foi possível conectar ao servidor de DATABASE_URL (#{sqlstate(e)}); confira a URL.")
      end

      # Mesmo servidor e banco da conexão administrativa, com outro usuário. A senha do administrador nunca é
      # reaproveitada: nem pela URL, nem pelos defaults da libpq (PGPASSWORD, ~/.pgpass ou um service).
      def connect_migrator(pinned)
        # Um passfile que não existe: a libpq o ignora sem aviso e não cai no ~/.pgpass de quem roda o comando.
        target = pinned.reject { |key, _| %w[user password passfile service].include?(key) }
                       .merge('user' => MIGRATOR, 'passfile' => File.join(Dir.tmpdir, "vetra-sem-pgpass-#{SecureRandom.hex(8)}"))
        target['password'] = @migrator_password if @migrator_password && !@migrator_password.empty?
        saved = LOGIN_ENV.to_h { |key| [key, ENV.fetch(key, nil)] }
        LOGIN_ENV.each { |key| ENV.delete(key) }
        begin
          @connector.call(target)
        ensure
          saved.each { |key, value| value.nil? ? ENV.delete(key) : ENV.store(key, value) }
        end
      rescue PG::Error => e
        raise Graph::Error.single('db_plan_role', "#{MIGRATOR} não entrou no servidor de DATABASE_URL (#{sqlstate(e)}); os planos são aplicados como " \
                                                  "#{MIGRATOR} (ADR-038). Defina VETRA_MIGRATOR_PASSWORD se o servidor pedir senha.")
      end

      def role_catalog(connection, scratch)
        @superuser = connection.exec(SUPERUSER).getvalue(0, 0) == 't' if @superuser.nil?
        [connection.exec_params(ROLE_CATALOG, [scratch]).getvalue(0, 0), (@superuser ? connection.exec(PASSWORDS).getvalue(0, 0) : nil)]
      end

      def sqlstate(error)
        state = error.result&.error_field(PG::PG_DIAG_SQLSTATE) if error.respond_to?(:result) && error.result
        "#{error.class}#{" #{state}" if state}"
      end

      def params
        PG::Connection.conninfo_parse(@url).each_with_object({}) { |option, out| out[option[:keyword]] = option[:val] if option[:val] }
      rescue PG::Error => e
        raise Graph::Error.single('db_connection', "DATABASE_URL inválida (#{e.class}); confira a URL.")
      end

      def pg_dump_version
        output, status = Open3.capture2e(@pg_dump, '--version')
        raise Graph::Error.single('db_pg_dump', "#{@pg_dump} --version falhou: #{output.lines.first&.strip}") unless status.success?
        output
      rescue SystemCallError
        raise Graph::Error.single('db_pg_dump', "pg_dump não encontrado (#{@pg_dump}); instale o cliente do PostgreSQL ou defina VETRA_PG_DUMP.")
      end

      def dump(effective)
        environment, arguments = self.class.pg_dump_invocation(effective)
        output, errors, status = Open3.capture3(environment, @pg_dump, *arguments)
        raise Graph::Error.single('db_pg_dump', "pg_dump falhou: #{errors.lines.first&.strip}") unless status.success?
        output.force_encoding(Encoding::UTF_8)
      end

      # Ambiente e argumentos do pg_dump: o banco e o servidor vêm explícitos em --dbname (string de conexão com valores
      # entre aspas), as variáveis PG* herdadas são removidas e a senha, se houver, vai só em PGPASSWORD.
      def self.pg_dump_invocation(effective)
        conninfo = DUMP_KEYS.filter_map do |key|
          value = effective[key]
          "#{key}='#{value.gsub(/['\\]/) { |character| "\\#{character}" }}'" if value && !value.empty?
        end.join(' ')
        environment = CLEARED_ENV.to_h { |name| [name, nil] }
        environment['PGPASSWORD'] = effective['password'] if effective['password'] && !effective['password'].empty?
        [environment, ['--schema-only', '--dbname', conninfo]]
      end
    end

    # Aplica planos numa conexão com lock_timeout de 3 s (ADR-015, §5). Um plano `unica` roda numa transação; num plano
    # `por_passo`, cada passo `sim` roda na sua e cada passo `nao`, fora de transação (ADR-038, §2). É o executor do
    # banco descartável; o db:migrate acrescenta o registro, o lock consultivo e as novas tentativas.
    class PlanExecutor
      def initialize(connection)
        @connection = connection
      end

      def apply(plans)
        plans.each { |plan| plan.transaction == 'unica' ? apply_single(plan) : plan.steps.each { |step| apply_step(plan, step) } }
      end

      private

      def apply_single(plan)
        step = nil
        @connection.exec('BEGIN')
        @connection.exec("SET LOCAL lock_timeout = '3s'")
        plan.steps.each do |current|
          step = current
          @connection.exec(current.sql)
        end
        @connection.exec('COMMIT')
      rescue StandardError => e
        @connection.exec('ROLLBACK') rescue nil
        failed!(plan, step, e)
      end

      def apply_step(plan, step)
        if step.transaction == 'sim'
          @connection.exec('BEGIN')
          @connection.exec("SET LOCAL lock_timeout = '3s'")
          @connection.exec(step.sql)
          @connection.exec('COMMIT')
        else
          # CREATE INDEX CONCURRENTLY não roda em transação: o limite vale para a sessão só durante o passo.
          @connection.exec("SET lock_timeout = '3s'")
          begin
            @connection.exec(step.sql)
          ensure
            @connection.exec('RESET lock_timeout') rescue nil
          end
        end
      rescue StandardError => e
        @connection.exec('ROLLBACK') rescue nil if step.transaction == 'sim'
        failed!(plan, step, e)
      end

      def failed!(plan, step, error)
        raise Graph::Error.single('db_plan_apply', "Plano #{plan.file_name}, passo #{step&.number || 0}: #{error.message.lines.first&.strip}")
      end
    end
  end
end

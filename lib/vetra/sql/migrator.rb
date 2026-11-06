# frozen_string_literal: true

require 'digest'
require 'open3'

module Vetra
  module SQL
    # `vetra db:migrate` (ADR-015, §1 e §5, e ADR-025, §1 e §2): aplica num banco de verdade os planos que a IR gera,
    # um migrador por vez, e registra cada plano com o hash do texto em vetra.migrations, na mesma transação do plano.
    # Antes de aplicar, reconhece o estado: banco vazio, planos já registrados (com o hash conferido) e, quando nada
    # falta, o esquema igual ao retrato db/schema.sql. A lógica não fala com o PostgreSQL: o adaptador faz isso.
    class Migrator
      # Espera antes de cada nova tentativa quando o lock_timeout estoura (55P03): 1, 2, 4, 8 e 16 s, com variação.
      BACKOFF = [1, 2, 4, 8, 16].freeze
      JITTER = 0.25

      Result = Struct.new(:status, :applied, :attempts, keyword_init: true)

      # differ é a diferença entre modelos do Planner, que recalcula o último plano (ADR-038, §3).
      def initialize(root:, database:, sleeper: ->(seconds) { sleep(seconds) }, random: Random.new, differ: Planner::REFUSE)
        @root, @database, @sleeper, @random, @differ = File.expand_path(root), database, sleeper, random, differ
      end

      def self.digest(plan)
        Digest::SHA256.hexdigest(plan.render)
      end

      def migrate
        @database.ensure_migrator!
        unless @database.try_lock
          raise Graph::Error.single('db_migrate_locked', 'Outro db:migrate está em execução neste banco; espere ele terminar.')
        end
        begin
          run
        ensure
          # Com a conexão perdida o PostgreSQL já soltou o lock de sessão; não se esconde o erro original.
          begin
            @database.unlock
          rescue StandardError
            nil
          end
        end
      end

      private

      def run
        plans = Planner.new(root: @root, differ: @differ).migration_plans
        snapshot = read_snapshot
        applied = @database.applied
        verify_applied!(applied, plans)
        pending = plans.drop(applied.size)
        if pending.empty?
          verify_state!(snapshot, before: true)
          return Result.new(status: :up_to_date, applied: [], attempts: 0)
        end
        # Planos depois do inicial, ou por passo, precisam da base conferida e do registro por passo (ADR-038, §4 e §5).
        # Recusa qualquer plano pendente além do inicial, seja qual for o modo de transação.
        incremental = pending.find { |plan| plan.number != Plan::INITIAL[:number] || plan.transaction != 'unica' }
        if incremental || !applied.empty?
          raise Graph::Error.single('db_migrate_incremental', "#{(incremental || pending.first).file_name} é um plano incremental; o db:migrate ainda só " \
                                                              'aplica o plano inicial (rodada 4, K10). Nada foi alterado.')
        end
        # Com o plano inicial pendente, a base precisa ser o banco vazio.
        unless (objects = @database.foreign_objects).empty?
          raise Graph::Error.single('db_migrate_not_empty', 'O banco não está vazio e não tem o registro de planos do Vetra ' \
                                                            "(#{objects.first(5).join(', ')}); o plano inicial só se aplica a um banco vazio. Nada foi alterado.")
        end
        attempts = pending.sum { |plan| apply_with_retries(plan) }
        verify_state!(snapshot, before: false)
        Result.new(status: :applied, applied: pending, attempts: attempts)
      end

      # O esquema precisa ser o do retrato e o banco, ter os privilégios que o plano deu (ADR-036): o pg_dump
      # --schema-only não inclui os privilégios do próprio banco, subscriptions nem large objects, então esses são
      # conferidos pelo catálogo.
      def verify_state!(snapshot, before:)
        problems = []
        problems << "o esquema difere de #{Planner::SCHEMA}" unless Planner.schema_body(snapshot) == @database.dump
        problems.concat(@database.database_privilege_problems)
        problems.concat(@database.undumped_objects.map { |object| "o banco tem #{object}" })
        return if problems.empty?
        detail = problems.join('; ')
        if before
          raise Graph::Error.single('db_migrate_drift', "O banco tem todos os planos registrados, mas #{detail}: houve mudança fora dos " \
                                                        'planos. Nada foi alterado; compare o banco com o retrato antes de seguir.')
        end
        raise Graph::Error.single('db_migrate_drift', "Os planos foram aplicados e registrados, mas #{detail}. O banco já tem o plano; " \
                                                      'corrija a diferença antes de liberar a aplicação.')
      end

      def read_snapshot
        path = File.join(@root, Planner::SCHEMA)
        raise Graph::Error.single('db_schema_missing', "#{Planner::SCHEMA} não existe; execute vetra db:plan --snapshot.") unless File.file?(path)
        File.binread(path).force_encoding(Encoding::UTF_8)
      end

      # Os registros precisam ser exatamente os primeiros planos, na ordem, com o mesmo hash: um plano editado depois de
      # aplicado ou um registro sem arquivo significa que o banco não é o que os planos descrevem.
      def verify_applied!(applied, plans)
        applied.each_with_index do |record, index|
          plan = plans[index]
          unless plan && record.fetch('plan') == plan.file_name.delete_suffix('.sql')
            raise Graph::Error.single('db_migrate_unknown', "vetra.migrations registra #{record.fetch('plan')}, que não está em #{Planner::PLANS} nessa posição.")
          end
          next if record.fetch('sha256') == self.class.digest(plan)
          raise Graph::Error.single('db_migrate_altered', "#{Planner::PLANS}/#{plan.file_name} mudou depois de aplicado; um plano aplicado não se edita, escreve-se outro.")
        end
      end

      def apply_with_retries(plan)
        attempt = 0
        begin
          attempt += 1
          @database.apply(plan, plan.file_name.delete_suffix('.sql'), self.class.digest(plan))
          attempt
        rescue MigrationDatabase::LockTimeout
          if attempt > BACKOFF.size
            raise Graph::Error.single('db_migrate_lock_timeout', "#{plan.file_name}: o lock_timeout de 3 s estourou em #{attempt} tentativas; " \
                                                                 'nada foi aplicado. Rode de novo quando a carga cair.')
          end
          wait = BACKOFF[attempt - 1]
          @sleeper.call(wait * (1 + (@random.rand * 2 - 1) * JITTER))
          retry
        end
      end
    end

    # Adaptador do PostgreSQL do db:migrate. Usa uma única conexão: o lock consultivo de sessão fica com ela do começo
    # ao fim, e cada plano roda numa transação que também grava o seu registro em vetra.migrations.
    class MigrationDatabase
      # Erro de lock_timeout (55P03) num plano, que o Migrator repete com espera.
      class LockTimeout < StandardError; end

      # Chave do lock consultivo do migrador: ('VETR', 'MIGR') em ASCII, fixa para todo banco Vetra.
      LOCK_KEY = [0x56455452, 0x4D494752].freeze
      FIRST_NORMAL_OID = 16_384
      MIGRATIONS = '"vetra"."migrations"'

      def initialize(connection:, pg_dump: 'pg_dump')
        @connection, @pg_dump = connection, pg_dump
      end

      # Conexão do db:migrate ao banco alvo de DATABASE_URL; a mensagem do driver pode conter a senha e não é repetida.
      def self.connect(url, driver: -> { require 'pg' })
        begin
          driver.call
        rescue LoadError
          raise Graph::Error.single('db_driver', 'db:migrate exige a gem pg; acrescente-a ao Gemfile da aplicação.')
        end
        begin
          connection = PG.connect(url)
        rescue PG::Error => e
          raise Graph::Error.single('db_connection', "Não foi possível conectar ao banco de DATABASE_URL (#{e.class}); confira a URL.")
        end
        connection.exec('SET client_min_messages = warning')
        connection
      end

      # O ADR-005 reserva a aplicação de planos ao vetra_migrator; nem a aplicação nem um superusuário a fazem.
      def ensure_migrator!
        user = @connection.exec('SELECT current_user').getvalue(0, 0)
        return if user == 'vetra_migrator'
        raise Graph::Error.single('db_migrate_role', "db:migrate roda como vetra_migrator (ADR-005); a conexão usa #{user}.")
      end

      def try_lock
        @connection.exec_params('SELECT pg_catalog.pg_try_advisory_lock($1::integer, $2::integer)', LOCK_KEY).getvalue(0, 0) == 't'
      end

      def unlock
        @connection.exec_params('SELECT pg_catalog.pg_advisory_unlock($1::integer, $2::integer)', LOCK_KEY)
      end

      def applied
        exists = @connection.exec("SELECT pg_catalog.to_regclass('vetra.migrations') IS NOT NULL").getvalue(0, 0) == 't'
        return [] unless exists
        @connection.exec("SELECT plan, sha256 FROM #{MIGRATIONS} ORDER BY plan").to_a
      end

      # Objetos que impedem tratar o banco como vazio. Tudo que se cria num banco depois do initdb recebe OID a partir de
      # FirstNormalObjectId (16384); conferir todos os catálogos locais com OID cobre tabelas, tipos, collations,
      # operadores, extensões, gatilhos de evento, privilégios padrão e qualquer outra espécie, sem lista à mão. O schema
      # public não tem OID novo, então seu dono e seus privilégios são conferidos contra o padrão do PostgreSQL 15+. O
      # migrador não lê pg_user_mapping, mas um mapeamento de usuário só existe com um servidor estrangeiro, visível em
      # pg_foreign_server.
      def foreign_objects
        catalogs = @connection.exec(<<~SQL).column_values(0)
          SELECT c.relname FROM pg_catalog.pg_class c
            JOIN pg_catalog.pg_attribute a ON a.attrelid = c.oid AND a.attname = 'oid' AND NOT a.attisdropped
           WHERE c.relnamespace = 'pg_catalog'::regnamespace AND c.relkind = 'r' AND NOT c.relisshared
             AND pg_catalog.has_table_privilege(c.oid, 'SELECT')
           ORDER BY c.relname
        SQL
        found = catalogs.select do |catalog|
          @connection.exec("SELECT EXISTS (SELECT 1 FROM pg_catalog.#{PG::Connection.quote_ident(catalog)} " \
                           "WHERE oid >= #{FIRST_NORMAL_OID})").getvalue(0, 0) == 't'
        end
        public_default = @connection.exec(<<~SQL).getvalue(0, 0) == 't'
          SELECT nspowner = 'pg_database_owner'::regrole
                 AND nspacl::text = '{pg_database_owner=UC/pg_database_owner,=U/pg_database_owner}'
            FROM pg_catalog.pg_namespace WHERE nspname = 'public'
        SQL
        found += ['schema public com dono ou privilégios alterados'] unless public_default
        found + undumped_objects
      end

      # Objetos e configurações do banco que o pg_dump --schema-only não mostra ao migrador e que a regra do OID não alcança:
      # subscriptions (pg_subscription é compartilhado e o pg_dump só as lê como superusuário), large objects (aceitam OID
      # explícito baixo), parâmetros por banco ou por papel no banco (ALTER DATABASE/ROLE ... SET, que só entram no dump com
      # --create e podem mudar o comportamento, como session_replication_role = replica) e rótulos de segurança, inclusive
      # em objetos do sistema e no próprio banco. Contam como objeto estranho antes de aplicar e como deriva depois; nenhum
      # plano os cria. Comentários em objetos do sistema ficam fora: não mudam execução nem permissões.
      def undumped_objects
        row = @connection.exec(<<~SQL).first
          WITH current AS (SELECT d.oid FROM pg_catalog.pg_database d WHERE d.datname = pg_catalog.current_database())
          SELECT EXISTS (SELECT 1 FROM pg_catalog.pg_subscription s, current WHERE s.subdbid = current.oid) AS subscriptions,
                 EXISTS (SELECT 1 FROM pg_catalog.pg_largeobject_metadata) AS large_objects,
                 EXISTS (SELECT 1 FROM pg_catalog.pg_db_role_setting r, current WHERE r.setdatabase = current.oid) AS settings,
                 EXISTS (SELECT 1 FROM pg_catalog.pg_seclabel)
                   OR EXISTS (SELECT 1 FROM pg_catalog.pg_shseclabel l, current
                               WHERE l.classoid = 'pg_catalog.pg_database'::regclass AND l.objoid = current.oid) AS labels
        SQL
        found = []
        found << 'subscription de replicação lógica (pg_subscription)' if row['subscriptions'] == 't'
        found << 'large object (pg_largeobject_metadata)' if row['large_objects'] == 't'
        found << 'parâmetro por banco ou por papel no banco (pg_db_role_setting)' if row['settings'] == 't'
        found << 'rótulo de segurança (pg_seclabel ou pg_shseclabel)' if row['labels'] == 't'
        found
      end

      # Privilégios do próprio banco que o plano inicial deixa (ADR-036) e que o pg_dump --schema-only não mostra.
      def database_privilege_problems
        row = @connection.exec(<<~SQL).first
          SELECT pg_catalog.has_database_privilege('vetra_app', pg_catalog.current_database(), 'CREATE') AS app_create,
                 pg_catalog.has_database_privilege('vetra_app', pg_catalog.current_database(), 'TEMPORARY') AS app_temporary,
                 pg_catalog.has_database_privilege('vetra_owner', pg_catalog.current_database(), 'CREATE') AS owner_create,
                 pg_catalog.pg_has_role('vetra_app', d.datdba, 'MEMBER') AS app_owner
            FROM pg_catalog.pg_database d WHERE d.datname = pg_catalog.current_database()
        SQL
        problems = []
        problems << 'vetra_app pode criar objetos no banco (CREATE)' if row['app_create'] == 't'
        problems << 'vetra_app pode criar tabelas temporárias no banco (TEMPORARY)' if row['app_temporary'] == 't'
        problems << 'vetra_owner não tem CREATE no banco' unless row['owner_create'] == 't'
        problems << 'vetra_app é dono do banco ou membro do dono' if row['app_owner'] == 't'
        problems
      end

      def apply(plan, name, digest)
        step = nil
        @connection.exec('BEGIN')
        @connection.exec("SET LOCAL lock_timeout = '3s'")
        plan.steps.each do |current|
          step = current
          @connection.exec(current.sql)
        end
        step = nil
        record(name, digest, plan.steps.size)
        @connection.exec('COMMIT')
      rescue PG::Error => e
        @connection.exec('ROLLBACK') rescue nil
        raise LockTimeout if e.result&.error_field(PG::PG_DIAG_SQLSTATE) == '55P03'
        where = step ? "passo #{step.number}" : 'registro em vetra.migrations'
        raise Graph::Error.single('db_plan_apply', "Plano #{plan.file_name}, #{where}: #{e.message.lines.first&.strip}")
      end

      # Retrato do banco alvo, normalizado como o do db:plan --snapshot e sem o registro de planos, que não é esquema.
      def dump
        ScratchDatabase.check_pg_dump!(pg_dump_version, @connection.server_version / 10_000)
        effective = @connection.conninfo_hash.transform_keys(&:to_s)
        effective.merge!('host' => @connection.host, 'port' => @connection.port.to_s, 'hostaddr' => @connection.hostaddr.to_s)
        environment, arguments = ScratchDatabase.pg_dump_invocation(effective)
        options, target = arguments[0...-2], arguments.last(2)
        output, errors, status = Open3.capture3(environment, @pg_dump, *options, '--exclude-table=vetra.migrations', *target)
        raise Graph::Error.single('db_pg_dump', "pg_dump falhou: #{errors.lines.first&.strip}") unless status.success?
        ScratchDatabase.normalize_dump(output.force_encoding(Encoding::UTF_8))
      end

      private

      # O registro nasce na transação do primeiro plano, depois que ele criou o schema vetra: plano e registro entram
      # juntos ou nenhum dos dois. A aplicação não lê nem grava o registro.
      def record(name, digest, steps)
        @connection.exec(<<~SQL)
          CREATE TABLE IF NOT EXISTS #{MIGRATIONS} (
            "plan" text PRIMARY KEY CHECK ("plan" ~ '^[0-9]{4}_[a-z][a-z0-9_]*$'),
            "sha256" text NOT NULL CHECK ("sha256" ~ '^[0-9a-f]{64}$'),
            "steps" integer NOT NULL CHECK ("steps" > 0),
            "applied_at" timestamp with time zone NOT NULL DEFAULT pg_catalog.now(),
            "applied_by" name NOT NULL DEFAULT CURRENT_USER
          )
        SQL
        @connection.exec("REVOKE ALL ON TABLE #{MIGRATIONS} FROM PUBLIC, \"vetra_app\"")
        @connection.exec_params("INSERT INTO #{MIGRATIONS} (plan, sha256, steps) VALUES ($1, $2, $3)", [name, digest, steps])
      end

      def pg_dump_version
        output, status = Open3.capture2e(@pg_dump, '--version')
        raise Graph::Error.single('db_pg_dump', "#{@pg_dump} --version falhou: #{output.lines.first&.strip}") unless status.success?
        output
      rescue SystemCallError
        raise Graph::Error.single('db_pg_dump', "pg_dump não encontrado (#{@pg_dump}); instale o cliente do PostgreSQL ou defina VETRA_PG_DUMP.")
      end
    end
  end
end

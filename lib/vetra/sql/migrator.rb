# frozen_string_literal: true

require 'digest'
require 'open3'

module Vetra
  module SQL
    # `vetra db:migrate` (ADR-015, §1 e §5, ADR-025, §1 e §2, e ADR-038, §4 e §5): aplica num banco de verdade os planos
    # que a IR gera, um migrador por vez, e registra cada plano com o hash do texto em vetra.migrations. Um plano de
    # transação única entra inteiro com o seu registro; um plano por passo registra cada passo em
    # vetra.migration_steps e retoma do passo seguinte ao último registrado. Antes de cada plano, confere a base: o
    # banco vazio para o primeiro e, para os seguintes, o SHA-256 do retrato depois do anterior. A lógica não fala com
    # o PostgreSQL: o adaptador faz isso.
    class Migrator
      # Espera antes de cada nova tentativa quando o lock_timeout estoura (55P03): 1, 2, 4, 8 e 16 s, com variação.
      BACKOFF = [1, 2, 4, 8, 16].freeze
      JITTER = 0.25

      # attempts conta cada execução das unidades aplicadas; retries, só as repetições por lock_timeout.
      Result = Struct.new(:status, :applied, :attempts, :retries, keyword_init: true)

      # differ é a diferença entre modelos do Planner, que recalcula o último plano (ADR-038, §3).
      def initialize(root:, database:, sleeper: ->(seconds) { sleep(seconds) }, random: Random.new, differ: Differ.method(:call))
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
        bases = read_bases(snapshot, plans)
        applied = @database.applied
        verify_applied!(applied, plans)
        pending = plans.drop(applied.size)
        verify_step_plans!(applied, pending)
        @retries = 0
        if pending.empty?
          verify_state!(snapshot, before: true)
          return Result.new(status: :up_to_date, applied: [], attempts: 0, retries: 0)
        end
        # Num banco já migrado, o que o pg_dump não mostra (privilégios do banco, parâmetros, subscriptions, large objects e
        # rótulos) é conferido antes de qualquer passo pendente, inclusive numa retomada, e não só no fim.
        verify_catalogs! unless applied.empty?
        attempts = pending.sum do |plan|
          previous = plans[plans.index(plan) - 1] if plans.index(plan).positive?
          plan.transaction == 'unica' ? apply_whole(plan, previous, bases) : apply_steps(plan, previous, bases)
        end
        verify_state!(snapshot, before: false)
        Result.new(status: :applied, applied: pending, attempts: attempts, retries: @retries)
      end

      # Um plano de transação única roda inteiro com o seu registro, como o plano inicial da K8.
      def apply_whole(plan, previous, bases)
        verify_base!(plan, previous, bases)
        with_retries("#{plan.file_name}: o lock_timeout de 3 s estourou em %<attempts>d tentativas; nada foi aplicado. " \
                     'Rode de novo quando a carga cair.') do
          @database.apply(plan, plan.file_name.delete_suffix('.sql'), self.class.digest(plan))
        end
      end

      # Um plano por passo (ADR-038, §5) retoma do passo seguinte ao último registrado. A base só é conferida antes do
      # primeiro passo: no meio do plano o banco está, por definição, entre dois retratos.
      #
      # O começo do plano fica registrado como o passo 0, com o SHA-256 do plano, logo depois da conferência da base. Com o
      # marcador presente, a retomada não confere a base de novo: um primeiro passo fora de transação pode ter criado o
      # índice e caído antes do registro, e o banco já não é o retrato anterior.
      def apply_steps(plan, previous, bases)
        name = plan.file_name.delete_suffix('.sql')
        digest = self.class.digest(plan)
        rows = @database.steps_done(name)
        marker, done = rows.partition { |row| row.fetch('step').to_i.zero? }
        if marker.any? && marker.first.fetch('sha256') != digest
          raise Graph::Error.single('db_migrate_altered', "#{Planner::PLANS}/#{plan.file_name} mudou depois de começar a ser aplicado; um plano em " \
                                                          'andamento não se edita.')
        end
        verify_progress!(plan, done)
        if marker.empty?
          raise Graph::Error.single('db_migrate_unknown', "vetra.migration_steps registra passos de #{plan.file_name} sem o começo do plano.") if done.any?
          verify_base!(plan, previous, bases)
          with_retries("#{plan.file_name}, registro do começo: o lock_timeout de 3 s estourou em %<attempts>d tentativas; nenhum passo " \
                       'foi aplicado. Rode de novo quando a carga cair.') do
            @database.mark_started(name, digest)
          end
        end
        plan.steps.drop(done.size).sum do |step|
          with_retries("#{plan.file_name}, passo #{step.number}: o lock_timeout de 3 s estourou em %<attempts>d tentativas; " \
                       'esse passo não ficou registrado. Rode de novo quando a carga cair, e o db:migrate retoma dele.') do
            @database.apply_step(plan, name, self.class.digest(plan), step, last: step.number == plan.steps.size)
          end
        end
      end

      # A base de um plano é o banco vazio, para o primeiro, ou o retrato depois do plano anterior, pelo SHA-256 da linha
      # -- vetra:base do retrato (ADR-038, §4, e ADR-025, §1, item 4).
      def verify_base!(plan, previous, bases)
        if previous.nil?
          unless (objects = @database.foreign_objects).empty?
            raise Graph::Error.single('db_migrate_not_empty', 'O banco não está vazio e não tem o registro de planos do Vetra ' \
                                                              "(#{objects.first(5).join(', ')}); o plano inicial só se aplica a um banco vazio. Nada foi alterado.")
          end
          return
        end
        expected = bases.fetch(previous.file_name.delete_suffix('.sql'))
        return if Digest::SHA256.hexdigest(@database.dump) == expected
        raise Graph::Error.single('db_migrate_drift', "O banco não está no estado que #{Planner::PLANS}/#{previous.file_name} deixa (a base " \
                                                      "de #{plan.file_name} no cabeçalho de #{Planner::SCHEMA}): houve mudança fora dos planos. " \
                                                      'Nada foi alterado; compare o banco com o retrato antes de seguir.')
      end

      def verify_catalogs!
        problems = @database.database_privilege_problems + @database.undumped_objects.map { |object| "o banco tem #{object}" }
        return if problems.empty?
        raise Graph::Error.single('db_migrate_drift', "Há planos pendentes, mas #{problems.join('; ')}: houve mudança fora dos planos. " \
                                                      'Nada foi alterado; corrija a diferença antes de aplicar.')
      end

      # As linhas -- vetra:base do retrato, uma por plano, na ordem dos planos.
      def read_bases(snapshot, plans)
        parsed = Planner.parse_schema(snapshot)
        names = plans.map { |plan| plan.file_name.delete_suffix('.sql') }
        unless parsed && parsed[:bases].map(&:first) == names
          raise Graph::Error.single('db_schema_stale', "#{Planner::SCHEMA} não tem uma linha -- vetra:base para cada plano de #{Planner::PLANS}; " \
                                                       'execute vetra db:plan --snapshot.')
        end
        parsed[:bases].to_h
      end

      # O progresso registrado de um plano é o começo dele, passo a passo, com o mesmo SHA-256 de cada instrução.
      def verify_progress!(plan, done)
        if done.size > plan.steps.size
          raise Graph::Error.single('db_migrate_unknown', "vetra.migration_steps registra mais passos de #{plan.file_name} do que o plano tem.")
        end
        done.each_with_index do |row, index|
          step = plan.steps[index]
          next if row.fetch('step').to_i == step.number && row.fetch('sha256') == Digest::SHA256.hexdigest(step.sql)
          raise Graph::Error.single('db_migrate_altered', "#{Planner::PLANS}/#{plan.file_name}, passo #{index + 1}, mudou depois de aplicado; " \
                                                          'um passo aplicado não se edita, escreve-se outro plano.')
        end
      end

      # Só o primeiro plano pendente pode ter passos registrados; os concluídos têm a sua linha em vetra.migrations.
      def verify_step_plans!(applied, pending)
        allowed = applied.map { |record| record.fetch('plan') } + pending.first(1).map { |plan| plan.file_name.delete_suffix('.sql') }
        stray = @database.step_plans - allowed
        return if stray.empty?
        raise Graph::Error.single('db_migrate_unknown', "vetra.migration_steps registra passos de #{stray.join(', ')}, que não é o próximo plano de " \
                                                        "#{Planner::PLANS}.")
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

      # Repete a unidade (um plano inteiro ou um passo) quando o lock_timeout estoura; devolve o número de tentativas.
      def with_retries(message)
        attempt = 0
        begin
          attempt += 1
          yield
          @retries += attempt - 1
          attempt
        rescue MigrationDatabase::LockTimeout
          raise Graph::Error.single('db_migrate_lock_timeout', format(message, attempts: attempt)) if attempt > BACKOFF.size
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
      # Progresso dos planos por passo (ADR-038, §5): uma linha por passo aplicado de um plano ainda em andamento.
      STEPS = '"vetra"."migration_steps"'
      # Índice que um passo fora de transação cria: nome, schema e tabela, para reconhecer o efeito de uma tentativa anterior.
      CONCURRENT_INDEX = /\ACREATE (?:UNIQUE )?INDEX CONCURRENTLY "([a-z][a-z0-9_]*)" ON "([a-z][a-z0-9_]*)"\."([a-z][a-z0-9_]*)" /

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
        return [] unless table?('vetra.migrations')
        @connection.exec("SELECT plan, sha256 FROM #{MIGRATIONS} ORDER BY plan").to_a
      end

      # Planos com algum passo registrado.
      def step_plans
        return [] unless table?('vetra.migration_steps')
        @connection.exec("SELECT DISTINCT plan FROM #{STEPS} ORDER BY plan").column_values(0)
      end

      def steps_done(name)
        return [] unless table?('vetra.migration_steps')
        @connection.exec_params("SELECT step, sha256 FROM #{STEPS} WHERE plan = $1 ORDER BY step", [name]).to_a
      end

      # Aplica um passo de um plano por passo e o registra. Um passo `sim` e o seu registro entram na mesma transação; um
      # passo `nao` roda fora de transação e é registrado logo depois, numa transação curta. Com o último passo, a linha
      # do plano em vetra.migrations entra junto com o registro do passo.
      def apply_step(plan, name, digest, step, last:)
        if step.transaction == 'sim'
          @connection.exec('BEGIN')
          @connection.exec("SET LOCAL lock_timeout = '3s'")
          @connection.exec(step.sql)
          finish_step(plan, name, digest, step, last)
          @connection.exec('COMMIT')
        else
          outside_transaction(step)
          @connection.exec('BEGIN')
          @connection.exec("SET LOCAL lock_timeout = '3s'")
          finish_step(plan, name, digest, step, last)
          @connection.exec('COMMIT')
        end
      rescue PG::Error => e
        @connection.exec('ROLLBACK') rescue nil
        @connection.exec('RESET lock_timeout') rescue nil
        raise LockTimeout if e.result&.error_field(PG::PG_DIAG_SQLSTATE) == '55P03'
        raise Graph::Error.single('db_plan_apply', "Plano #{plan.file_name}, passo #{step.number}: #{e.message.lines.first&.strip}")
      end

      # Registra o começo de um plano por passo (o passo 0, com o SHA-256 do plano), depois de conferida a base.
      def mark_started(name, digest)
        @connection.exec('BEGIN')
        @connection.exec("SET LOCAL lock_timeout = '3s'")
        ensure_steps_table
        @connection.exec_params("INSERT INTO #{STEPS} (plan, step, sha256) VALUES ($1, 0, $2)", [name, digest])
        @connection.exec('COMMIT')
      rescue PG::Error => e
        @connection.exec('ROLLBACK') rescue nil
        raise LockTimeout if e.result&.error_field(PG::PG_DIAG_SQLSTATE) == '55P03'
        raise Graph::Error.single('db_plan_apply', "Plano #{name}.sql, registro do começo: #{e.message.lines.first&.strip}")
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
        # O pg_dump pede ACCESS SHARE em cada tabela: com um DDL de outra sessão na fila, falha em vez de esperar sem limite.
        output, errors, status = Open3.capture3(environment, @pg_dump, *options, '--exclude-table=vetra.migrations',
                                                '--exclude-table=vetra.migration_steps', '--lock-wait-timeout=3s', *target)
        raise Graph::Error.single('db_pg_dump', "pg_dump falhou: #{errors.lines.first&.strip}") unless status.success?
        # As partições diárias da manutenção não estão no retrato; só saem do dump as que seguem exatamente as regras
        # do ADR-040, §4. Uma partição adulterada continua no dump e aparece como deriva.
        Outbox.without_operational_partitions(ScratchDatabase.normalize_dump(output.force_encoding(Encoding::UTF_8)))
      end

      private

      def table?(name)
        @connection.exec_params('SELECT pg_catalog.to_regclass($1) IS NOT NULL', [name]).getvalue(0, 0) == 't'
      end

      # Um passo fora de transação pode ter rodado numa tentativa anterior sem chegar ao registro: o índice válido já
      # criado na tabela do passo é o efeito dele e é aceito; um índice inválido (CONCURRENTLY interrompido) é removido
      # com DROP INDEX CONCURRENTLY e criado de novo; um índice com o mesmo nome em outra tabela é deriva.
      def outside_transaction(step)
        @connection.exec("SET lock_timeout = '3s'")
        begin
          if (match = CONCURRENT_INDEX.match(step.sql))
            name, schema, table = match.captures
            unique = step.sql.start_with?('CREATE UNIQUE ') ? 'UNIQUE ' : ''
            columns = step.sql[/ \(([^()]*)\);\z/, 1].to_s.scan(/"([a-z][a-z0-9_]*)"/).flatten
            row = index_definition(schema, name, table, unique, columns)
            if row
              # O índice de uma tentativa anterior é o do passo só com a definição inteira igual à que o passo pede, como o
              # próprio servidor a escreve: tabela, colunas-chave na ordem, btree e unicidade, e nenhum INCLUDE, classe de
              # operadores, collation, ordem, NULLS NOT DISTINCT, predicado ou parâmetro de armazenamento a mais.
              unless row['same'] == 't'
                raise Graph::Error.single('db_migrate_drift', "O passo #{step.number} cria o índice #{schema}.#{name}, que já existe com outra " \
                                                              'tabela ou definição: houve mudança fora dos planos.')
              end
              return if row['indisvalid'] == 't'
              @connection.exec("DROP INDEX CONCURRENTLY IF EXISTS #{PG::Connection.quote_ident(schema)}.#{PG::Connection.quote_ident(name)}")
            end
          end
          @connection.exec(step.sql)
        ensure
          @connection.exec('RESET lock_timeout') rescue nil
        end
      end

      # Validade do índice de mesmo nome e se pg_get_indexdef dele é a definição que o passo pede. Com search_path vazio, o
      # servidor qualifica todos os nomes, e a definição esperada é montada por ele mesmo, com quote_ident.
      def index_definition(schema, name, table, unique, columns)
        @connection.exec('BEGIN')
        @connection.exec("SET LOCAL search_path = ''")
        row = @connection.exec_params(<<~SQL, [schema, name, table, unique, "{#{columns.join(',')}}"]).first
          SELECT i.indisvalid,
                 pg_catalog.pg_get_indexdef(i.indexrelid) = pg_catalog.format('CREATE %sINDEX %s ON %s.%s USING btree (%s)', $4::text,
                   pg_catalog.quote_ident($2), pg_catalog.quote_ident($1), pg_catalog.quote_ident($3),
                   (SELECT pg_catalog.string_agg(pg_catalog.quote_ident(u.c), ', ' ORDER BY u.o)
                      FROM pg_catalog.unnest($5::text[]) WITH ORDINALITY AS u(c, o))) AS same
            FROM pg_catalog.pg_index i
            JOIN pg_catalog.pg_class c ON c.oid = i.indexrelid
            JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
           WHERE n.nspname = $1 AND c.relname = $2
        SQL
        @connection.exec('COMMIT')
        row
      end

      def finish_step(plan, name, digest, step, last)
        ensure_steps_table
        @connection.exec_params("INSERT INTO #{STEPS} (plan, step, sha256) VALUES ($1, $2, $3)",
                                [name, step.number, Digest::SHA256.hexdigest(step.sql)])
        record(name, digest, plan.steps.size) if last
      end

      # O passo 0 marca o começo do plano, com o SHA-256 do plano inteiro; os demais, cada instrução aplicada.
      def ensure_steps_table
        @connection.exec(<<~SQL)
          CREATE TABLE IF NOT EXISTS #{STEPS} (
            "plan" text NOT NULL CHECK ("plan" ~ '^[0-9]{4}_[a-z][a-z0-9_]*$'),
            "step" integer NOT NULL CHECK ("step" >= 0),
            "sha256" text NOT NULL CHECK ("sha256" ~ '^[0-9a-f]{64}$'),
            "applied_at" timestamp with time zone NOT NULL DEFAULT pg_catalog.now(),
            "applied_by" name NOT NULL DEFAULT CURRENT_USER,
            PRIMARY KEY ("plan", "step")
          )
        SQL
        @connection.exec("REVOKE ALL ON TABLE #{STEPS} FROM PUBLIC, \"vetra_app\"")
      end

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

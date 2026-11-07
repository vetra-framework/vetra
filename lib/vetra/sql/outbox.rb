# frozen_string_literal: true

require 'digest'
require 'time'

module Vetra
  module SQL
    # Outbox (ADR-024, §3, e ADR-040). O armazenamento (K11): tabelas particionadas por tempo, partições DEFAULT,
    # entregas mortas fora da purga e a concessão de INSERT por coluna para a aplicação. O relay (K12): papel
    # conferido, checkpoint, políticas e concessões do vetra_relay e a rotina fechada de manutenção. Só existe numa
    # aplicação com eventos.
    class Outbox
      TABLES = %w[outbox outbox_default deliveries deliveries_default dead_deliveries].freeze
      RELAY_TABLES = %w[relay_checkpoints].freeze
      MAINTAIN = '"vetra"."outbox_maintain"(integer,integer)'
      # Partição diária criada pela manutenção (ADR-040, §4).
      PARTITION = /\A(outbox|deliveries)_p(\d{4})(\d{2})(\d{2})\z/
      # Colunas que a aplicação grava. created_at, xid8 e seq vêm do banco (ADR-040, §1).
      APP_COLUMNS = %w[event_id event version tenant_id actor_id op_id cmd payload].freeze
      TIMESTAMP = 'timestamp(6) with time zone'
      NOW = 'pg_catalog.statement_timestamp()'
      NAME = %q{'^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$'}

      def self.needed?(document)
        document.is_a?(Hash) && document.fetch('nodes', []).any? { |node| node['kind'] == 'event' }
      end

      def initialize(schema)
        @document = schema.document
        @tenant = @document.dig('app', 'tenant')
        root = schema.tables.find { |table| table['scope'] == 'tenant_root' }
        @tenant_type = root ? root['columns'].find { |column| column['name'] == 'id' }.fetch('type') : 'uuid'
      end

      # Uma instrução por passo: o armazenamento e, depois, o relay.
      def statements
        storage + relay
      end

      # Armazenamento, na ordem: tabelas, partições, índices, donos, revogações, RLS, política e concessão. O texto é
      # o dos planos 0002 já integrados: mudá-lo é uma alteração que o Differ recusa.
      def storage
        return [] unless self.class.needed?(@document)
        tables + indexes + TABLES.flat_map { |name| protection(name) } + [policy, grant]
      end

      # Relay e manutenção (ADR-040, §§ 3 e 4): guarda do papel, checkpoint, políticas, concessões e a rotina.
      def relay
        return [] unless self.class.needed?(@document)
        [relay_guard, checkpoint_table, checkpoint_seed, *protection('relay_checkpoints'), *relay_policies, *relay_grants,
         maintain_function, "ALTER FUNCTION #{MAINTAIN} OWNER TO #{quote('vetra_owner')};",
         "REVOKE ALL ON FUNCTION #{MAINTAIN} FROM PUBLIC, #{quote('vetra_app')};",
         "GRANT EXECUTE ON FUNCTION #{MAINTAIN} TO #{quote('vetra_relay')};"]
      end

      # Os SHA-256 das instruções, que o Differ usa para separar a seção da outbox das demais.
      def digests
        statements.map { |sql| Digest::SHA256.hexdigest(sql) }
      end

      def storage_digests
        storage.map { |sql| Digest::SHA256.hexdigest(sql) }
      end

      # Tira do dump as partições diárias que a manutenção cria quando cada instrução delas é exatamente a da partição
      # DEFAULT do mesmo pai, com o nome trocado, e o intervalo é de um dia UTC (ADR-040, §4). Qualquer diferença,
      # inclusive uma concessão, uma política ou um índice a mais, sobra no dump e aparece como deriva.
      def self.without_operational_partitions(dump)
        chunks = top_level_chunks(dump)
        names = chunks.flat_map { |chunk| chunk.scan(/\bvetra\.((?:outbox|deliveries)_p\d{8})\b/).flatten }.uniq
        removed = []
        names.each do |name|
          match = PARTITION.match(name)
          day = (Time.utc(match[2].to_i, match[3].to_i, match[4].to_i) rescue nil)
          next unless day && day.strftime('%Y%m%d') == name[-8..]
          parent = match[1]
          # Só as formas da própria partição: a política do dono existe na DEFAULT e não nas diárias, e a rotina de
          # manutenção também cita a DEFAULT.
          own = /\A(CREATE TABLE vetra\.#{parent}_default \(|ALTER TABLE (ONLY )?vetra\.#{parent}_default[ \n]|CREATE (UNIQUE )?INDEX #{parent}_default_\w+ ON vetra\.#{parent}_default |ALTER INDEX vetra\.\w+ ATTACH PARTITION vetra\.#{parent}_default_\w+;\z)/
          template = chunks.select { |chunk| chunk.match?(own) }
          attach = "ALTER TABLE ONLY vetra.#{parent} ATTACH PARTITION vetra.#{parent}_default DEFAULT;"
          next unless chunks.include?(attach)
          expected = template.map { |chunk| chunk.gsub("#{parent}_default", name) }
          pattern = /\AALTER TABLE ONLY vetra\.#{parent} ATTACH PARTITION vetra\.#{name} FOR VALUES FROM \('([^']+)'\) TO \('([^']+)'\);\z/
          bound = chunks.find do |chunk|
            (found = pattern.match(chunk)) && (Time.parse(found[1]) rescue nil) == day && (Time.parse(found[2]) rescue nil) == day + 86_400
          end
          next unless bound && chunks.count(bound) == 1 && expected.all? { |chunk| chunks.count(chunk) == 1 }
          removed.concat(expected + [bound])
        end
        "#{(chunks - removed).join("\n\n")}#{"\n" if dump.end_with?("\n")}"
      end

      # Instruções de topo do dump normalizado, separadas por uma linha vazia fora de literais e corpos de função.
      def self.top_level_chunks(dump)
        chunks, current, scanner = [], [], StatementScanner.new
        # Tira só o LF de cada linha, como a normalização: um CR dentro de um literal é dado.
        dump.each_line do |raw|
          line = raw.delete_suffix("\n")
          if line.empty? && scanner.boundary?
            chunks << current.join("\n") unless current.empty?
            current = []
          else
            current << line
            scanner.feed(line)
          end
        end
        chunks << current.join("\n") unless current.empty?
        chunks
      end

      private

      def quote(name)
        Context.quote(name)
      end

      def relation(name)
        "#{quote('vetra')}.#{quote(name)}"
      end

      def tables
        [<<~SQL.chomp,
          CREATE TABLE #{relation('outbox')} (
            "created_at" #{TIMESTAMP} NOT NULL DEFAULT #{NOW},
            "xid8" pg_catalog.xid8 NOT NULL DEFAULT pg_catalog.pg_current_xact_id(),
            "seq" bigint GENERATED ALWAYS AS IDENTITY,
            "event_id" uuid NOT NULL,
            "event" text NOT NULL CHECK ("event" ~ #{NAME}),
            "version" integer NOT NULL CHECK ("version" > 0),
            "tenant_id" #{@tenant_type},
            "actor_id" uuid,
            "op_id" uuid NOT NULL,
            "cmd" text NOT NULL CHECK (pg_catalog.char_length("cmd") BETWEEN 1 AND 255),
            "payload" jsonb NOT NULL CHECK (pg_catalog.jsonb_typeof("payload") = 'object'),
            PRIMARY KEY ("created_at", "xid8", "seq")
          ) PARTITION BY RANGE ("created_at");
        SQL
         "CREATE TABLE #{relation('outbox_default')} PARTITION OF #{relation('outbox')} DEFAULT;",
         <<~SQL.chomp,
           CREATE TABLE #{relation('deliveries')} (
             "event_created_at" #{TIMESTAMP} NOT NULL,
             "event_xid8" pg_catalog.xid8 NOT NULL,
             "event_seq" bigint NOT NULL,
             "event_id" uuid NOT NULL,
             "handler" text NOT NULL CHECK ("handler" ~ #{NAME}),
             "tenant_id" #{@tenant_type},
             "state" text NOT NULL DEFAULT 'pending' CHECK ("state" IN ('pending', 'done', 'dead')),
             "attempts" integer NOT NULL DEFAULT 0 CHECK ("attempts" >= 0),
             "run_after" #{TIMESTAMP} NOT NULL DEFAULT #{NOW},
             "leased_until" #{TIMESTAMP},
             "last_error" text,
             "created_at" #{TIMESTAMP} NOT NULL DEFAULT #{NOW},
             "updated_at" #{TIMESTAMP} NOT NULL DEFAULT #{NOW},
             PRIMARY KEY ("handler", "event_id", "event_created_at")
           ) PARTITION BY RANGE ("event_created_at");
         SQL
         "CREATE TABLE #{relation('deliveries_default')} PARTITION OF #{relation('deliveries')} DEFAULT;",
         <<~SQL.chomp]
           CREATE TABLE #{relation('dead_deliveries')} (
             "handler" text NOT NULL CHECK ("handler" ~ #{NAME}),
             "event_id" uuid NOT NULL,
             "event_created_at" #{TIMESTAMP} NOT NULL,
             "event_xid8" pg_catalog.xid8 NOT NULL,
             "event_seq" bigint NOT NULL,
             "event" text NOT NULL CHECK ("event" ~ #{NAME}),
             "version" integer NOT NULL CHECK ("version" > 0),
             "tenant_id" #{@tenant_type},
             "payload" jsonb NOT NULL CHECK (pg_catalog.jsonb_typeof("payload") = 'object'),
             "attempts" integer NOT NULL CHECK ("attempts" >= 0),
             "last_error" text,
             "died_at" #{TIMESTAMP} NOT NULL DEFAULT #{NOW},
             PRIMARY KEY ("handler", "event_id")
           );
         SQL
      end

      def indexes
        # Nascem com as tabelas: o PostgreSQL não cria índice CONCURRENTLY numa tabela particionada (ADR-040, §1).
        ["CREATE INDEX #{quote('vt_outbox_relay')} ON #{relation('outbox')} (\"xid8\", \"seq\");",
         "CREATE INDEX #{quote('vt_deliveries_ready')} ON #{relation('deliveries')} (\"run_after\") WHERE \"state\" = 'pending';"]
      end

      # Dono, nenhuma concessão herdada de PUBLIC e RLS forçado sem política: nega tudo a quem não tiver política.
      def protection(name)
        ["ALTER TABLE #{relation(name)} OWNER TO #{quote('vetra_owner')};",
         "REVOKE ALL ON TABLE #{relation(name)} FROM PUBLIC, #{quote('vetra_app')};",
         "ALTER TABLE #{relation(name)} ENABLE ROW LEVEL SECURITY;",
         "ALTER TABLE #{relation(name)} FORCE ROW LEVEL SECURITY;"]
      end

      def policy
        check = if @tenant
          # IS NOT DISTINCT FROM: o ator de sistema de um handler não tem actor_id (ADR-024, §4, decisão 2).
          '"tenant_id" = (SELECT vetra.current_tenant()) AND "actor_id" IS NOT DISTINCT FROM (SELECT vetra.current_actor())'
        else
          '"tenant_id" IS NULL'
        end
        "CREATE POLICY #{quote('vt_outbox_insert')} ON #{relation('outbox')} AS PERMISSIVE FOR INSERT TO #{quote('vetra_app')} WITH CHECK (#{check});"
      end

      def grant
        columns = APP_COLUMNS.map { |name| quote(name) }.join(', ')
        "GRANT INSERT (#{columns}) ON TABLE #{relation('outbox')} TO #{quote('vetra_app')};"
      end

      # O papel vem do bootstrap operacional (ADR-036), nunca de um plano: sem ele, o plano falha antes de conceder.
      def relay_guard
        Context.relay_guard
      end

      def checkpoint_table
        <<~SQL.chomp
          CREATE TABLE #{relation('relay_checkpoints')} (
            "name" text PRIMARY KEY CHECK ("name" ~ '^[a-z][a-z0-9_]*$'),
            "next_xid8" pg_catalog.xid8 NOT NULL,
            "updated_at" #{TIMESTAMP} NOT NULL DEFAULT #{NOW}
          );
        SQL
      end

      def checkpoint_seed
        "INSERT INTO #{relation('relay_checkpoints')} (\"name\", \"next_xid8\") VALUES ('relay', '0');"
      end

      # O relay lê o cluster por faixa de xid8, sem tenant (ADR-024, §3). O dono só age pela rotina de manutenção, que
      # move linhas da DEFAULT e confere o checkpoint: com RLS forçado, precisa de política própria.
      def relay_policies
        relay = %w[outbox deliveries dead_deliveries relay_checkpoints].map do |name|
          command = name == 'outbox' ? 'FOR SELECT' : 'FOR ALL'
          check = name == 'outbox' ? '' : ' WITH CHECK (true)'
          "CREATE POLICY #{quote("vt_#{name}_relay")} ON #{relation(name)} AS PERMISSIVE #{command} TO #{quote('vetra_relay')} USING (true)#{check};"
        end
        owner = %w[outbox outbox_default deliveries deliveries_default relay_checkpoints].map do |name|
          "CREATE POLICY #{quote("vt_#{name}_owner")} ON #{relation(name)} AS PERMISSIVE FOR ALL TO #{quote('vetra_owner')} USING (true) WITH CHECK (true);"
        end
        relay + owner
      end

      def relay_grants
        ["GRANT USAGE ON SCHEMA #{quote('vetra')} TO #{quote('vetra_relay')};",
         "GRANT SELECT ON TABLE #{relation('outbox')} TO #{quote('vetra_relay')};",
         "GRANT SELECT, INSERT, UPDATE ON TABLE #{relation('deliveries')} TO #{quote('vetra_relay')};",
         "GRANT SELECT, INSERT ON TABLE #{relation('dead_deliveries')} TO #{quote('vetra_relay')};",
         "GRANT SELECT, UPDATE ON TABLE #{relation('relay_checkpoints')} TO #{quote('vetra_relay')};"]
      end

      # Cria as partições diárias de hoje até `ahead` dias adiante (e desde o dia mais antigo que estiver na DEFAULT,
      # movendo essas linhas sem perder nem duplicar), e remove por DETACH e DROP as mais antigas que `retention` dias
      # cujos eventos já passaram pelo relay e cujas entregas não estão pendentes (ADR-024, §3, e ADR-040, §4).
      def maintain_function
        <<~SQL.chomp
          CREATE FUNCTION "vetra"."outbox_maintain"(ahead integer, retention integer) RETURNS jsonb LANGUAGE plpgsql
            SECURITY DEFINER SET search_path = pg_catalog, pg_temp SET lock_timeout = '3s' AS $vetra_outbox$
          DECLARE
            today date := (pg_catalog.statement_timestamp() AT TIME ZONE 'UTC')::date;
            first_day date;
            day date;
            lo timestamp with time zone;
            hi timestamp with time zone;
            name text;
            moved_outbox "vetra"."outbox_default"[];
            moved_deliveries "vetra"."deliveries_default"[];
            created text[] := '{}';
            dropped text[] := '{}';
            kept text[] := '{}';
            recovered bigint := 0;
            item record;
            relayed pg_catalog.xid8;
          BEGIN
            IF ahead IS NULL OR retention IS NULL OR ahead NOT BETWEEN 0 AND 31 OR retention NOT BETWEEN 1 AND 3650 THEN
              RAISE EXCEPTION 'outbox_maintain: ahead entre 0 e 31 dias e retention entre 1 e 3650 dias';
            END IF;
            -- Antes de qualquer lock nas tabelas, trava o checkpoint como o relay o trava, na mesma ordem (checkpoint,
            -- depois outbox): uma materialização em curso termina antes, as entregas dela contam como pendências, e o
            -- relay seguinte pula a vez (SKIP LOCKED) até a manutenção terminar.
            SELECT c."next_xid8" INTO relayed FROM "vetra"."relay_checkpoints" c WHERE c."name" = 'relay' FOR UPDATE;
            -- Os locks mais fortes de que a rotina precisa, de uma vez e sempre na ordem outbox, depois entregas: os workers
            -- que tocam as duas também começam pela outbox, e nenhum lock é ampliado depois, então não há ciclo. O
            -- lock_timeout de 3 s limita só a espera da rotina por cada lock; obtidos os locks, quem grava espera a rotina terminar.
            LOCK TABLE "vetra"."outbox" IN ACCESS EXCLUSIVE MODE;
            LOCK TABLE "vetra"."deliveries" IN ACCESS EXCLUSIVE MODE;
            SELECT LEAST(
                (SELECT pg_catalog.min((o."created_at" AT TIME ZONE 'UTC')::date) FROM "vetra"."outbox_default" o),
                (SELECT pg_catalog.min((d."event_created_at" AT TIME ZONE 'UTC')::date) FROM "vetra"."deliveries_default" d),
                today) INTO first_day;
            FOR day IN SELECT g::date FROM pg_catalog.generate_series(first_day::timestamp, (today + ahead)::timestamp, interval '1 day') g LOOP
              lo := day::timestamp AT TIME ZONE 'UTC';
              hi := (day + 1)::timestamp AT TIME ZONE 'UTC';
              -- Um dia já fora da retenção só volta a ter partição se a DEFAULT tiver linhas dele para recuperar.
              CONTINUE WHEN day + 1 <= today - retention
                AND NOT EXISTS (SELECT 1 FROM "vetra"."outbox_default" o WHERE o."created_at" >= lo AND o."created_at" < hi)
                AND NOT EXISTS (SELECT 1 FROM "vetra"."deliveries_default" d WHERE d."event_created_at" >= lo AND d."event_created_at" < hi);
              name := 'outbox_p' || pg_catalog.to_char(day, 'YYYYMMDD');
              IF pg_catalog.to_regclass(pg_catalog.format('%I.%I', 'vetra', name)) IS NULL THEN
                -- As linhas do dia saem da DEFAULT e voltam pela partição nova na mesma transação.
                WITH d AS (DELETE FROM "vetra"."outbox_default" WHERE "created_at" >= lo AND "created_at" < hi RETURNING *)
                  SELECT pg_catalog.array_agg(ROW(d.*)::"vetra"."outbox_default") INTO moved_outbox FROM d;
                EXECUTE pg_catalog.format('CREATE TABLE %I.%I PARTITION OF %I.%I FOR VALUES FROM (%L) TO (%L)', 'vetra', name, 'vetra', 'outbox', lo, hi);
                EXECUTE pg_catalog.format('ALTER TABLE %I.%I ENABLE ROW LEVEL SECURITY', 'vetra', name);
                EXECUTE pg_catalog.format('ALTER TABLE %I.%I FORCE ROW LEVEL SECURITY', 'vetra', name);
                EXECUTE pg_catalog.format('REVOKE ALL ON TABLE %I.%I FROM PUBLIC, %I, %I', 'vetra', name, 'vetra_app', 'vetra_relay');
                IF moved_outbox IS NOT NULL THEN
                  INSERT INTO "vetra"."outbox" OVERRIDING SYSTEM VALUE SELECT * FROM pg_catalog.unnest(moved_outbox);
                  recovered := recovered + pg_catalog.cardinality(moved_outbox);
                END IF;
                created := created || name;
              END IF;
              name := 'deliveries_p' || pg_catalog.to_char(day, 'YYYYMMDD');
              IF pg_catalog.to_regclass(pg_catalog.format('%I.%I', 'vetra', name)) IS NULL THEN
                WITH d AS (DELETE FROM "vetra"."deliveries_default" WHERE "event_created_at" >= lo AND "event_created_at" < hi RETURNING *)
                  SELECT pg_catalog.array_agg(ROW(d.*)::"vetra"."deliveries_default") INTO moved_deliveries FROM d;
                EXECUTE pg_catalog.format('CREATE TABLE %I.%I PARTITION OF %I.%I FOR VALUES FROM (%L) TO (%L)', 'vetra', name, 'vetra', 'deliveries', lo, hi);
                EXECUTE pg_catalog.format('ALTER TABLE %I.%I ENABLE ROW LEVEL SECURITY', 'vetra', name);
                EXECUTE pg_catalog.format('ALTER TABLE %I.%I FORCE ROW LEVEL SECURITY', 'vetra', name);
                EXECUTE pg_catalog.format('REVOKE ALL ON TABLE %I.%I FROM PUBLIC, %I, %I', 'vetra', name, 'vetra_app', 'vetra_relay');
                IF moved_deliveries IS NOT NULL THEN
                  INSERT INTO "vetra"."deliveries" SELECT * FROM pg_catalog.unnest(moved_deliveries);
                  recovered := recovered + pg_catalog.cardinality(moved_deliveries);
                END IF;
                created := created || name;
              END IF;
            END LOOP;
            FOR item IN SELECT c.oid, c.relname, i.inhparent::regclass::text AS parent FROM pg_catalog.pg_inherits i
                JOIN pg_catalog.pg_class c ON c.oid = i.inhrelid
                WHERE i.inhparent IN ('"vetra"."deliveries"'::regclass, '"vetra"."outbox"'::regclass)
                  AND c.relname ~ '^(outbox|deliveries)_p[0-9]{8}$'
                ORDER BY 3, 2 LOOP
              day := pg_catalog.to_date(pg_catalog.right(item.relname, 8), 'YYYYMMDD');
              CONTINUE WHEN day + 1 > today - retention;
              lo := day::timestamp AT TIME ZONE 'UTC';
              hi := (day + 1)::timestamp AT TIME ZONE 'UTC';
              -- Uma entrega pendente nunca é descartada; um evento que o relay ainda não leu também não.
              IF EXISTS (SELECT 1 FROM "vetra"."deliveries" d WHERE d."state" = 'pending'
                    AND d."event_created_at" >= lo AND d."event_created_at" < hi)
                 OR (item.relname LIKE 'outbox_p%' AND EXISTS (SELECT 1 FROM "vetra"."outbox" o
                    WHERE o.tableoid = item.oid AND (relayed IS NULL OR o."xid8" >= relayed))) THEN
                kept := kept || item.relname::text;
                CONTINUE;
              END IF;
              EXECUTE pg_catalog.format('ALTER TABLE %s DETACH PARTITION %I.%I', item.parent, 'vetra', item.relname);
              EXECUTE pg_catalog.format('DROP TABLE %I.%I', 'vetra', item.relname);
              dropped := dropped || item.relname::text;
            END LOOP;
            RETURN pg_catalog.jsonb_build_object('criadas', created, 'recuperadas', recovered, 'removidas', dropped, 'mantidas', kept);
          END
          $vetra_outbox$;
        SQL
      end
    end
  end
end

# frozen_string_literal: true

require 'digest'

module Vetra
  module SQL
    # Admissões duráveis, fora da unidade da operação (ADR-051). A função só aceita um envelope r1 assinado
    # pela borda: o login da aplicação não escolhe identidade, políticas, limites nem relógio.
    class RateLimit
      TABLE = 'rate_limit'
      INDEX = 'vt_rate_limit_counter'
      PURGE_INDEX = 'vt_rate_limit_purge'
      FUNCTION = 'reserve_rate_limit'

      def self.needed?(document)
        Array(document&.fetch('requires', [])).include?('vetra.rate_limit')
      end

      def self.retention(document)
        document.fetch('nodes').filter_map { |node| node.dig('rate_limit', 'window_seconds') }.max || 0
      end

      # Reutiliza a verificação HMAC do ADR-036, com domínio r1, tenant opcional e retorno fechado.
      # Não instala GUC nem muda as rotinas de contexto dos bancos globais já aplicados.
      def self.body
        verification = Context.legacy_body('actor_id')
          .sub("token text := pg_catalog.current_setting('vetra.ctx', true);", 'token text := $1;')
          .sub("parts[1] <> 'v1'", "parts[1] <> 'r1'")
          .sub("OR pg_catalog.jsonb_typeof(payload->'tenant_id') IS DISTINCT FROM 'string'",
               "OR NOT (payload ? 'tenant_id') OR (payload->'tenant_id' <> 'null'::jsonb AND pg_catalog.jsonb_typeof(payload->'tenant_id') IS DISTINCT FROM 'string')")
          .sub("OR (payload->>'tenant_id') !~ uuid_pattern", "OR ((payload->>'tenant_id') IS NOT NULL AND (payload->>'tenant_id') !~ uuid_pattern)")
          .sub('  token text := $1;', <<~SQL.chomp)
              token text := $1;
              admission_namespace text;
              tenant uuid;
              actor uuid;
              policies jsonb;
              policy jsonb;
              lock_key bigint;
              instant timestamp with time zone;
              cutoff timestamp with time zone;
              used bigint;
              cap bigint;
              window_seconds bigint;
              wait_seconds bigint := 0;
              first_at timestamp with time zone;
          SQL
        verification = verification.sub("  RETURN (payload->>'actor_id')::uuid;", <<~SQL.chomp.gsub(/^/, '  '))
          IF pg_catalog.current_setting('transaction_isolation') <> 'read committed' THEN RETURN NULL; END IF;
          admission_namespace := payload->>'namespace';
          tenant := (payload->>'tenant_id')::uuid;
          actor := (payload->>'actor_id')::uuid;
          policies := payload->'policies';
          IF admission_namespace IS NULL OR pg_catalog.char_length(admission_namespace) NOT BETWEEN 1 AND 255
             OR pg_catalog.jsonb_typeof(policies) IS DISTINCT FROM 'array'
             OR pg_catalog.jsonb_array_length(policies) NOT BETWEEN 1 AND 1000 THEN RETURN NULL; END IF;
          IF (SELECT count(DISTINCT value->>'id') FROM pg_catalog.jsonb_array_elements(policies))
             <> pg_catalog.jsonb_array_length(policies) THEN RETURN NULL; END IF;
          FOR policy IN SELECT value FROM pg_catalog.jsonb_array_elements(policies) LOOP
            IF pg_catalog.jsonb_typeof(policy->'id') IS DISTINCT FROM 'string'
               OR pg_catalog.char_length(policy->>'id') NOT BETWEEN 1 AND 255
               OR (policy->>'limit') IS NULL OR (policy->>'limit') !~ '^[1-9][0-9]{0,15}$'
               OR (policy->>'window_seconds') IS NULL OR (policy->>'window_seconds') !~ '^[1-9][0-9]{0,15}$'
               OR (policy->>'limit')::bigint > 9007199254740991
               OR (policy->>'window_seconds')::bigint > 9007199254740991 THEN RETURN NULL; END IF;
          END LOOP;
          -- Ordem das próprias chaves de trava: colisões só serializam contadores independentes.
          FOR lock_key IN
            SELECT DISTINCT pg_catalog.hashtextextended(pg_catalog.jsonb_build_array(admission_namespace, value->>'id', tenant, actor)::text, 0) AS key
              FROM pg_catalog.jsonb_array_elements(policies) ORDER BY key
          LOOP
            PERFORM pg_catalog.pg_advisory_xact_lock(lock_key);
          END LOOP;
          -- Depois de todas as esperas: VOLATILE + READ COMMITTED relê admissões já confirmadas.
          instant := pg_catalog.clock_timestamp();
          FOR policy IN SELECT value FROM pg_catalog.jsonb_array_elements(policies) LOOP
            cap := (policy->>'limit')::bigint;
            window_seconds := (policy->>'window_seconds')::bigint;
            cutoff := instant - window_seconds * interval '1 second';
            SELECT count(*) INTO used FROM vetra.rate_limit r
              WHERE r.namespace = admission_namespace AND r.policy_id = policy->>'id'
                AND r.tenant_id IS NOT DISTINCT FROM tenant AND r.actor_id = actor AND r.admitted_at > cutoff;
            IF used >= cap THEN
              -- Se o limite diminuiu, é preciso vencer used-cap+1 admissões, não só a mais antiga.
              SELECT r.admitted_at INTO first_at FROM vetra.rate_limit r
                WHERE r.namespace = admission_namespace AND r.policy_id = policy->>'id'
                  AND r.tenant_id IS NOT DISTINCT FROM tenant AND r.actor_id = actor AND r.admitted_at > cutoff
                ORDER BY r.admitted_at, r.id OFFSET (used - cap) LIMIT 1;
              wait_seconds := greatest(wait_seconds, 1, ceil(EXTRACT(EPOCH FROM (first_at - cutoff)))::bigint);
            END IF;
          END LOOP;
          IF wait_seconds > 0 THEN RETURN wait_seconds; END IF;
          INSERT INTO vetra.rate_limit (namespace, policy_id, tenant_id, actor_id, admitted_at)
            SELECT admission_namespace, value->>'id', tenant, actor, instant FROM pg_catalog.jsonb_array_elements(policies);
          RETURN 0;
        SQL
        # Falhas de validação são NULL; falhas de SQL também recusam, sem liberar parcialmente a reserva.
        verification
      end

      def self.trusted_routine_sql
        <<~SQL.strip
          COALESCE((p.pronamespace = (SELECT oid FROM pg_catalog.pg_namespace WHERE nspname = 'vetra' AND nspowner = 'vetra_owner'::regrole)
            AND p.proname = '#{FUNCTION}' AND p.proowner = 'vetra_owner'::regrole
            AND p.prolang = (SELECT oid FROM pg_catalog.pg_language WHERE lanname = 'plpgsql')
            AND p.prokind = 'f' AND p.prosecdef AND p.provolatile = 'v' AND p.proparallel = 'u'
            AND NOT p.proleakproof AND NOT p.proisstrict AND NOT p.proretset
            AND p.pronargs = 1 AND p.proargtypes = '25'::pg_catalog.oidvector AND p.prorettype = 'pg_catalog.int8'::regtype
            AND p.pronargdefaults = 0 AND p.provariadic = 0 AND p.prosupport = 0
            AND p.proallargtypes IS NULL AND p.proargmodes IS NULL AND p.proargnames IS NULL
            AND p.proargdefaults IS NULL AND p.prosqlbody IS NULL AND p.probin IS NULL
            AND p.proconfig = ARRAY['search_path=pg_catalog, pg_temp']::text[]
            AND pg_catalog.encode(pg_catalog.sha256(pg_catalog.convert_to(p.prosrc, 'UTF8')), 'hex') = '#{Digest::SHA256.hexdigest(body)}'), false)
        SQL
      end

      def initialize(schema)
        @document = schema.document
      end

      def digests = statements.map { |sql| Digest::SHA256.hexdigest(sql) }

      def statements
        return [] unless self.class.needed?(@document)
        [<<~SQL.chomp,
          CREATE TABLE "vetra"."rate_limit" (
            "id" bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
            "namespace" text NOT NULL,
            "policy_id" text NOT NULL,
            "tenant_id" uuid,
            "actor_id" uuid NOT NULL,
            "admitted_at" timestamp(6) with time zone NOT NULL DEFAULT pg_catalog.clock_timestamp()
          );
        SQL
         'ALTER TABLE "vetra"."rate_limit" OWNER TO "vetra_owner";',
         'REVOKE ALL ON TABLE "vetra"."rate_limit" FROM PUBLIC, "vetra_app", "vetra_relay";',
         'CREATE INDEX "vt_rate_limit_counter" ON "vetra"."rate_limit" ("namespace", "policy_id", "tenant_id", "actor_id", "admitted_at", "id");',
         'CREATE INDEX "vt_rate_limit_purge" ON "vetra"."rate_limit" ("admitted_at", "id");',
         'ALTER TABLE "vetra"."rate_limit" ENABLE ROW LEVEL SECURITY;',
         'ALTER TABLE "vetra"."rate_limit" FORCE ROW LEVEL SECURITY;',
         'CREATE POLICY "vt_rate_limit_owner" ON "vetra"."rate_limit" AS PERMISSIVE FOR ALL TO "vetra_owner" USING (true) WITH CHECK (true);',
         'CREATE POLICY "vt_rate_limit_relay" ON "vetra"."rate_limit" AS PERMISSIVE FOR SELECT TO "vetra_relay" USING (true);',
         'CREATE POLICY "vt_rate_limit_purge" ON "vetra"."rate_limit" AS PERMISSIVE FOR DELETE TO "vetra_relay" USING (true);',
         'GRANT SELECT, DELETE ON TABLE "vetra"."rate_limit" TO "vetra_relay";',
         "CREATE FUNCTION \"vetra\".\"reserve_rate_limit\"(text) RETURNS bigint\nLANGUAGE plpgsql VOLATILE SECURITY DEFINER\nSET search_path = pg_catalog, pg_temp\nAS $vetra_rate_limit$#{self.class.body}$vetra_rate_limit$;",
         'ALTER FUNCTION "vetra"."reserve_rate_limit"(text) OWNER TO "vetra_owner";',
         'REVOKE ALL ON FUNCTION "vetra"."reserve_rate_limit"(text) FROM PUBLIC, "vetra_app", "vetra_relay";',
         'GRANT EXECUTE ON FUNCTION "vetra"."reserve_rate_limit"(text) TO "vetra_app";',
         <<~SQL.chomp]
           DO $vetra_rate_limit_routines$
           BEGIN
             IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_proc p WHERE #{self.class.trusted_routine_sql}) THEN
               RAISE EXCEPTION 'Rotina de reserva de taxa incompatível com o ADR-051';
             END IF;
           END $vetra_rate_limit_routines$;
         SQL
      end
    end
  end
end

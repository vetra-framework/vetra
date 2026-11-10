# frozen_string_literal: true

require 'digest'

module Vetra
  module SQL
    # Infraestrutura do ADR-036. Gera estrutura, nunca chaves, tokens ou dados de contexto.
    class Context
      # Rotinas de contexto: nome, claim e tipo de retorno. Uma aplicação global conserva as duas primeiras, como foram
      # instaladas; uma aplicação com tenant ganha o ator de sistema (ADR-024, §4): current_actor() passa a devolver NULL
      # quando o token traz system_actor em vez de actor_id, e is_system_actor() diz qual dos dois é.
      ROUTINES = [%w[current_tenant tenant_id uuid], %w[current_actor actor_id uuid]].freeze
      SYSTEM_ROUTINES = (ROUTINES + [%w[is_system_actor system_actor boolean]]).freeze
      FUNCTIONS = ROUTINES.to_h { |name, claim, _| [name, claim] }.freeze
      # Identificador do handler no claim system_actor: começa por letra, até 128 caracteres.
      SYSTEM_ACTOR_PATTERN = '^[A-Za-z][A-Za-z0-9_.:-]{0,127}$'

      def self.routines(system_actor)
        system_actor ? SYSTEM_ROUTINES : ROUTINES
      end

      def self.quote(name)
        unless name.is_a?(String) && name.match?(/\A[a-z][a-z0-9_]*\z/) && name.bytesize <= 63
          raise Graph::Error.single('context_identifier', 'Identificador do contexto deve usar minúsculas ASCII, números ou sublinhado, começar por letra e ter até 63 bytes.')
        end
        %Q{"#{name}"}
      end

      # Operação global explícita, separada dos planos e do executor de banco temporário.
      # Só os papéis ausentes são criados; nenhum segredo ou autenticação é configurado aqui.
      def self.roles_sql
        <<~SQL
          BEGIN;
          DO $vetra_bootstrap$
          BEGIN
            IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'vetra_owner') THEN
              CREATE ROLE "vetra_owner" NOLOGIN INHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
            END IF;
            IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'vetra_app') THEN
              CREATE ROLE "vetra_app" LOGIN INHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
            END IF;
            IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'vetra_migrator') THEN
              CREATE ROLE "vetra_migrator" LOGIN INHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION BYPASSRLS;
              GRANT "vetra_owner" TO "vetra_migrator" WITH ADMIN FALSE, INHERIT TRUE, SET TRUE;
            END IF;
            -- Relay e manutenção da outbox (ADR-040, §3): login próprio, sem vínculo com os demais papéis.
            IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'vetra_relay') THEN
              CREATE ROLE "vetra_relay" LOGIN INHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
            END IF;
          END $vetra_bootstrap$;
          #{role_guard}
          #{relay_guard}
          COMMIT;
        SQL
      end

      # O papel do relay vem do bootstrap operacional (ADR-036), nunca de um plano: o bootstrap e o plano de uma
      # aplicação com eventos o conferem, e o plano falha antes de conceder qualquer coisa (ADR-040, §3).
      def self.relay_guard
        <<~SQL.chomp
          DO $vetra_relay_role$
          BEGIN
            IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'vetra_relay' AND rolcanlogin
                AND NOT rolsuper AND NOT rolcreatedb AND NOT rolcreaterole AND NOT rolreplication AND NOT rolbypassrls) THEN
              RAISE EXCEPTION 'Papel vetra_relay ausente ou incompatível; execute o bootstrap operacional do ADR-036';
            END IF;
            IF EXISTS (SELECT 1 FROM pg_catalog.pg_auth_members m
                WHERE m.member = 'vetra_relay'::regrole OR m.roleid = 'vetra_relay'::regrole) THEN
              RAISE EXCEPTION 'vetra_relay não pode pertencer a outro papel nem ter membros (ADR-040, §3)';
            END IF;
          END $vetra_relay_role$;
        SQL
      end

      def self.role_guard
        <<~SQL.chomp
          DO $vetra_context_roles$
          BEGIN
            IF pg_catalog.current_setting('server_version_num')::integer < 170000 THEN
              RAISE EXCEPTION 'Vetra exige PostgreSQL 17 ou superior';
            END IF;
            IF (SELECT count(*) FROM pg_catalog.pg_roles
                WHERE rolname IN ('vetra_app', 'vetra_migrator', 'vetra_owner')
                  AND rolcanlogin = (rolname <> 'vetra_owner') AND rolinherit
                  AND NOT rolsuper AND NOT rolcreatedb AND NOT rolcreaterole AND NOT rolreplication
                  AND rolbypassrls = (rolname = 'vetra_migrator')) <> 3 THEN
              RAISE EXCEPTION 'Papéis Vetra ausentes ou incompatíveis; execute e confira o bootstrap operacional do ADR-036';
            END IF;
            IF EXISTS (SELECT 1 FROM pg_catalog.pg_auth_members m
                JOIN pg_catalog.pg_roles r ON r.oid = m.member
                JOIN pg_catalog.pg_roles target ON target.oid = m.roleid
                WHERE r.rolname IN ('vetra_app', 'vetra_owner', 'vetra_migrator')
                  AND NOT (r.rolname = 'vetra_migrator' AND target.rolname = 'vetra_owner'
                    AND m.inherit_option AND m.set_option AND NOT m.admin_option))
               OR NOT EXISTS (SELECT 1 FROM pg_catalog.pg_auth_members m
                JOIN pg_catalog.pg_roles r ON r.oid = m.member
                JOIN pg_catalog.pg_roles target ON target.oid = m.roleid
                WHERE r.rolname = 'vetra_migrator' AND target.rolname = 'vetra_owner'
                  AND m.inherit_option AND m.set_option AND NOT m.admin_option) THEN
              RAISE EXCEPTION 'Vínculos dos papéis Vetra incompatíveis com o ADR-036';
            END IF;
          END $vetra_context_roles$;
        SQL
      end

      def self.body(claim, system_actor: false)
        raise ArgumentError, 'Claim de identidade desconhecida' unless routines(system_actor).any? { |_, known, _| known == claim }
        base = legacy_body(claim)
        system_actor ? system_body(base, claim) : base
      end

      def self.legacy_body(claim)
        # A quebra inicial também pertence a prosrc e ao hash usado pela guarda de rotinas.
        "\n" + <<~SQL
          DECLARE
            token text := pg_catalog.current_setting('vetra.ctx', true);
            parts text[];
            payload_bytes bytea;
            payload jsonb;
            key_secret bytea;
            key_not_before timestamp with time zone;
            supplied bytea;
            expected bytea;
            issued bigint;
            expires bigint;
            now_epoch numeric := EXTRACT(EPOCH FROM pg_catalog.transaction_timestamp());
            difference integer := 0;
            uuid_pattern text := '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$';
          BEGIN
            IF token IS NULL OR pg_catalog.octet_length(token) = 0 OR pg_catalog.octet_length(token) > 8192 THEN
              RETURN NULL;
            END IF;
            parts := pg_catalog.string_to_array(token, '.');
            IF pg_catalog.cardinality(parts) <> 4 OR parts[1] <> 'v1'
               OR parts[2] !~ '^[A-Za-z0-9_-]{1,64}$' OR parts[3] !~ '^[A-Za-z0-9_-]+$'
               OR parts[4] !~ '^[A-Za-z0-9_-]{43}$' THEN
              RETURN NULL;
            END IF;
            SELECT k.secret, k.not_before INTO key_secret, key_not_before FROM "vetra_private"."keys" k
              WHERE k.kid = parts[2] AND k.status IN ('active', 'verify_only')
                AND k.not_before <= pg_catalog.transaction_timestamp();
            IF key_secret IS NULL THEN RETURN NULL; END IF;
            supplied := pg_catalog.decode(pg_catalog.translate(parts[4], '-_', '+/') || '=', 'base64');
            expected := "vetra_private"."hmac"(pg_catalog.convert_to(parts[1] || '.' || parts[2] || '.' || parts[3], 'UTF8'), key_secret, 'sha256');
            IF pg_catalog.octet_length(supplied) <> 32 THEN RETURN NULL; END IF;
            FOR i IN 0..31 LOOP
              difference := difference | (pg_catalog.get_byte(supplied, i) # pg_catalog.get_byte(expected, i));
            END LOOP;
            IF difference <> 0 OR pg_catalog.rtrim(pg_catalog.translate(pg_catalog.encode(supplied, 'base64'), '+/', '-_'), '=') <> parts[4] THEN
              RETURN NULL;
            END IF;
            payload_bytes := pg_catalog.decode(pg_catalog.translate(parts[3], '-_', '+/') || pg_catalog.repeat('=', (4 - pg_catalog.length(parts[3]) % 4) % 4), 'base64');
            IF pg_catalog.rtrim(pg_catalog.translate(pg_catalog.replace(pg_catalog.encode(payload_bytes, 'base64'), E'\\n', ''), '+/', '-_'), '=') <> parts[3] THEN
              RETURN NULL;
            END IF;
            payload := pg_catalog.convert_from(payload_bytes, 'UTF8')::jsonb;
            IF pg_catalog.jsonb_typeof(payload) IS DISTINCT FROM 'object'
               OR pg_catalog.jsonb_typeof(payload->'tenant_id') IS DISTINCT FROM 'string'
               OR pg_catalog.jsonb_typeof(payload->'actor_id') IS DISTINCT FROM 'string'
               OR pg_catalog.jsonb_typeof(payload->'op_id') IS DISTINCT FROM 'string'
               OR (payload->>'tenant_id') !~ uuid_pattern OR (payload->>'actor_id') !~ uuid_pattern
               OR (payload->>'op_id') !~ uuid_pattern
               OR pg_catalog.jsonb_typeof(payload->'cmd') IS DISTINCT FROM 'string'
               OR pg_catalog.char_length(payload->>'cmd') NOT BETWEEN 1 AND 255
               OR pg_catalog.jsonb_typeof(payload->'iat') IS DISTINCT FROM 'number'
               OR pg_catalog.jsonb_typeof(payload->'exp') IS DISTINCT FROM 'number'
               OR (payload->>'iat') !~ '^[0-9]{1,12}$' OR (payload->>'exp') !~ '^[0-9]{1,12}$' THEN
              RETURN NULL;
            END IF;
            IF payload ? 'operator_id' AND (pg_catalog.jsonb_typeof(payload->'operator_id') IS DISTINCT FROM 'string'
               OR (payload->>'operator_id') !~ uuid_pattern) THEN RETURN NULL; END IF;
            issued := (payload->>'iat')::bigint;
            expires := (payload->>'exp')::bigint;
            IF expires < issued OR expires > issued + 120 OR now_epoch < issued - 5 OR now_epoch > expires
               OR key_not_before > pg_catalog.to_timestamp(issued::double precision) THEN
              RETURN NULL;
            END IF;
            RETURN (payload->>'#{claim}')::uuid;
          EXCEPTION WHEN OTHERS THEN
            RETURN NULL;
          END
        SQL
      end

      # O corpo da aplicação com tenant deriva do corpo original por substituições conferidas, para que o corpo de uma
      # aplicação global (e o hash da guarda de rotinas) continue idêntico ao dos planos já aplicados.
      def self.system_body(base, claim)
        failure = claim == 'system_actor' ? 'false' : 'NULL'
        text = base.gsub('RETURN NULL;', "RETURN #{failure};")
        replace = lambda do |pattern, replacement|
          found = pattern.is_a?(Regexp) ? text.match?(pattern) : text.include?(pattern)
          raise ArgumentError, "Corpo de contexto sem #{pattern.inspect}" unless found
          text = text.sub(pattern) { replacement }
        end
        replace.call(/^\s*OR pg_catalog\.jsonb_typeof\(payload->'actor_id'\) IS DISTINCT FROM 'string'\n/, '')
        replace.call(" OR (payload->>'actor_id') !~ uuid_pattern\n", "\n")
        identity = <<~SQL.gsub(/^/, '  ')
          IF (payload ? 'actor_id') = (payload ? 'system_actor') THEN RETURN #{failure}; END IF;
          IF payload ? 'actor_id' AND (pg_catalog.jsonb_typeof(payload->'actor_id') IS DISTINCT FROM 'string'
             OR (payload->>'actor_id') !~ uuid_pattern) THEN RETURN #{failure}; END IF;
          IF payload ? 'system_actor' AND (pg_catalog.jsonb_typeof(payload->'system_actor') IS DISTINCT FROM 'string'
             OR (payload->>'system_actor') !~ '#{SYSTEM_ACTOR_PATTERN}') THEN RETURN #{failure}; END IF;
        SQL
        replace.call("  issued := (payload->>'iat')::bigint;\n", identity + "  issued := (payload->>'iat')::bigint;\n")
        result = claim == 'system_actor' ? "RETURN payload ? 'system_actor';" : "RETURN (payload->>'#{claim}')::uuid;"
        replace.call("RETURN (payload->>'#{claim}')::uuid;", result)
        text
      end

      # Predicado total (nunca NULL) sobre pg_proc. Apenas estas duas definições são terminais seguros no fecho C2.
      def self.trusted_routine_sql(system_actor: false)
        bodies = routines(system_actor).map do |name, claim, returns|
          # O tipo de retorno é conferido por rotina só na aplicação com tenant; a global mantém o texto original da guarda.
          catalog_type = returns == 'boolean' ? 'bool' : returns
          kind = system_actor ? " AND p.prorettype = 'pg_catalog.#{catalog_type}'::pg_catalog.regtype" : ''
          "(p.proname = '#{name}'#{kind} AND pg_catalog.encode(pg_catalog.sha256(pg_catalog.convert_to(p.prosrc, 'UTF8')), 'hex') = '#{Digest::SHA256.hexdigest(body(claim, system_actor: system_actor))}')"
        end.join(' OR ')
        returns = system_actor ? '' : "\n  AND p.prorettype = 'pg_catalog.uuid'::pg_catalog.regtype"
        <<~SQL.strip
          COALESCE((p.pronamespace = (SELECT oid FROM pg_catalog.pg_namespace WHERE nspname = 'vetra' AND nspowner = (SELECT oid FROM pg_catalog.pg_roles WHERE rolname = 'vetra_owner'))
            AND p.proowner = (SELECT oid FROM pg_catalog.pg_roles WHERE rolname = 'vetra_owner')
            AND p.prolang = (SELECT oid FROM pg_catalog.pg_language WHERE lanname = 'plpgsql')
            AND p.prokind = 'f' AND p.prosecdef AND p.provolatile = 's' AND p.proparallel = 'u'
            AND NOT p.proleakproof AND NOT p.proisstrict AND NOT p.proretset
            AND p.pronargs = 0 AND p.pronargdefaults = 0 AND p.provariadic = 0 AND p.prosupport = 0#{returns}
            AND p.proallargtypes IS NULL AND p.proargmodes IS NULL AND p.proargnames IS NULL
            AND p.proargdefaults IS NULL AND p.prosqlbody IS NULL AND p.probin IS NULL
            AND p.proconfig = ARRAY['search_path=pg_catalog, pg_temp']::text[]
            AND (#{bodies})), false)
        SQL
      end

      def self.prefix(system_actor: false)
        [role_guard, <<~SQL.chomp,
          DO $vetra_database_privileges$
          BEGIN
            EXECUTE pg_catalog.format('REVOKE CREATE, TEMPORARY ON DATABASE %I FROM PUBLIC, "vetra_app"', pg_catalog.current_database());
            EXECUTE pg_catalog.format('GRANT CREATE ON DATABASE %I TO "vetra_owner"', pg_catalog.current_database());
            IF pg_catalog.has_database_privilege('vetra_app', pg_catalog.current_database(), 'CREATE,TEMPORARY') THEN
              RAISE EXCEPTION 'vetra_app não pode criar objetos no banco, nem ser seu dono';
            END IF;
          END $vetra_database_privileges$;
        SQL
         'CREATE SCHEMA "vetra" AUTHORIZATION "vetra_owner";',
         'CREATE SCHEMA "vetra_private" AUTHORIZATION "vetra_owner";',
         'CREATE EXTENSION "pgcrypto" WITH SCHEMA "vetra_private";',
         <<~SQL.chomp,
           CREATE TABLE "vetra_private"."keys" (
             "kid" text PRIMARY KEY CHECK ("kid" ~ '^[A-Za-z0-9_-]{1,64}$'),
             "secret" bytea NOT NULL CHECK (pg_catalog.octet_length("secret") >= 32),
             "status" text NOT NULL CHECK ("status" IN ('active', 'verify_only', 'revoked')),
             "not_before" timestamp with time zone NOT NULL
           );
         SQL
         'ALTER TABLE "vetra_private"."keys" OWNER TO "vetra_owner";',
         'CREATE UNIQUE INDEX "vt_keys_active" ON "vetra_private"."keys" ("status") WHERE "status" = \'active\';',
         'REVOKE ALL ON SCHEMA "vetra", "vetra_private" FROM PUBLIC, "vetra_app";',
         'REVOKE ALL ON TABLE "vetra_private"."keys" FROM PUBLIC, "vetra_app";',
         'GRANT USAGE ON SCHEMA "vetra" TO "vetra_app";',
         *routines(system_actor).flat_map do |name, claim, returns|
           function = "#{quote('vetra')}.#{quote(name)}()"
           ["CREATE FUNCTION #{function} RETURNS #{returns} LANGUAGE plpgsql STABLE SECURITY DEFINER PARALLEL UNSAFE\n" \
            "  SET search_path = pg_catalog, pg_temp AS $vetra_context$#{body(claim, system_actor: system_actor)}$vetra_context$;",
            "ALTER FUNCTION #{function} OWNER TO #{quote('vetra_owner')};",
            "REVOKE ALL ON FUNCTION #{function} FROM PUBLIC, #{quote('vetra_app')};",
            "GRANT EXECUTE ON FUNCTION #{function} TO #{quote('vetra_app')};"]
         end]
      end

      def self.suffix(tables)
        schemas = (['public'] + tables.map { |table| table.fetch('schema') }).uniq.sort
        schemas.flat_map do |schema|
          ["ALTER SCHEMA #{quote(schema)} OWNER TO #{quote('vetra_owner')};",
           "REVOKE ALL ON SCHEMA #{quote(schema)} FROM PUBLIC, #{quote('vetra_app')};",
           "GRANT USAGE ON SCHEMA #{quote(schema)} TO #{quote('vetra_app')};"]
        end + tables.flat_map do |table|
          relation = table.values_at('schema', 'table').map { |name| quote(name) }.join('.')
          ["ALTER TABLE #{relation} OWNER TO #{quote('vetra_owner')};",
           "REVOKE ALL ON TABLE #{relation} FROM PUBLIC, #{quote('vetra_app')};",
           "GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE #{relation} TO #{quote('vetra_app')};"]
        end
      end
    end
  end
end

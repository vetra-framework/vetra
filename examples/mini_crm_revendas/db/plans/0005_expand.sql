-- vetra:plano 0005 expand
-- vetra:transacao por_passo
--
-- Gerado por `vetra db:plan` a partir de .vetra/graph.json. Revise antes de aplicar e confira com
-- `vetra db:plan --check`. Cada passo diz a fase, o lock que pede numa tabela existente e o custo.

-- vetra:passo 1 fase=expand lock=nenhum custo=catalogo transacao=sim
CREATE OR REPLACE FUNCTION "vetra"."current_tenant"() RETURNS uuid LANGUAGE plpgsql STABLE SECURITY DEFINER PARALLEL UNSAFE
  SET search_path = pg_catalog, pg_temp AS $vetra_context$
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
  IF pg_catalog.rtrim(pg_catalog.translate(pg_catalog.replace(pg_catalog.encode(payload_bytes, 'base64'), E'\n', ''), '+/', '-_'), '=') <> parts[3] THEN
    RETURN NULL;
  END IF;
  payload := pg_catalog.convert_from(payload_bytes, 'UTF8')::jsonb;
  IF pg_catalog.jsonb_typeof(payload) IS DISTINCT FROM 'object'
     OR pg_catalog.jsonb_typeof(payload->'tenant_id') IS DISTINCT FROM 'string'
     OR pg_catalog.jsonb_typeof(payload->'op_id') IS DISTINCT FROM 'string'
     OR (payload->>'tenant_id') !~ uuid_pattern
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
  IF (payload ? 'actor_id') = (payload ? 'system_actor') THEN RETURN NULL; END IF;
  IF payload ? 'actor_id' AND (pg_catalog.jsonb_typeof(payload->'actor_id') IS DISTINCT FROM 'string'
     OR (payload->>'actor_id') !~ uuid_pattern) THEN RETURN NULL; END IF;
  IF payload ? 'system_actor' AND (pg_catalog.jsonb_typeof(payload->'system_actor') IS DISTINCT FROM 'string'
     OR (payload->>'system_actor') !~ '^[A-Za-z][A-Za-z0-9_.:-]{0,127}$') THEN RETURN NULL; END IF;
  issued := (payload->>'iat')::bigint;
  expires := (payload->>'exp')::bigint;
  IF expires < issued OR expires > issued + 120 OR now_epoch < issued - 5 OR now_epoch > expires
     OR key_not_before > pg_catalog.to_timestamp(issued::double precision) THEN
    RETURN NULL;
  END IF;
  RETURN (payload->>'tenant_id')::uuid;
EXCEPTION WHEN OTHERS THEN
  RETURN NULL;
END
$vetra_context$;

-- vetra:passo 2 fase=expand lock=nenhum custo=catalogo transacao=sim
CREATE OR REPLACE FUNCTION "vetra"."current_actor"() RETURNS uuid LANGUAGE plpgsql STABLE SECURITY DEFINER PARALLEL UNSAFE
  SET search_path = pg_catalog, pg_temp AS $vetra_context$
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
  IF pg_catalog.rtrim(pg_catalog.translate(pg_catalog.replace(pg_catalog.encode(payload_bytes, 'base64'), E'\n', ''), '+/', '-_'), '=') <> parts[3] THEN
    RETURN NULL;
  END IF;
  payload := pg_catalog.convert_from(payload_bytes, 'UTF8')::jsonb;
  IF pg_catalog.jsonb_typeof(payload) IS DISTINCT FROM 'object'
     OR pg_catalog.jsonb_typeof(payload->'tenant_id') IS DISTINCT FROM 'string'
     OR pg_catalog.jsonb_typeof(payload->'op_id') IS DISTINCT FROM 'string'
     OR (payload->>'tenant_id') !~ uuid_pattern
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
  IF (payload ? 'actor_id') = (payload ? 'system_actor') THEN RETURN NULL; END IF;
  IF payload ? 'actor_id' AND (pg_catalog.jsonb_typeof(payload->'actor_id') IS DISTINCT FROM 'string'
     OR (payload->>'actor_id') !~ uuid_pattern) THEN RETURN NULL; END IF;
  IF payload ? 'system_actor' AND (pg_catalog.jsonb_typeof(payload->'system_actor') IS DISTINCT FROM 'string'
     OR (payload->>'system_actor') !~ '^[A-Za-z][A-Za-z0-9_.:-]{0,127}$') THEN RETURN NULL; END IF;
  issued := (payload->>'iat')::bigint;
  expires := (payload->>'exp')::bigint;
  IF expires < issued OR expires > issued + 120 OR now_epoch < issued - 5 OR now_epoch > expires
     OR key_not_before > pg_catalog.to_timestamp(issued::double precision) THEN
    RETURN NULL;
  END IF;
  RETURN (payload->>'actor_id')::uuid;
EXCEPTION WHEN OTHERS THEN
  RETURN NULL;
END
$vetra_context$;

-- vetra:passo 3 fase=expand lock=nenhum custo=catalogo transacao=sim
CREATE FUNCTION "vetra"."is_system_actor"() RETURNS boolean LANGUAGE plpgsql STABLE SECURITY DEFINER PARALLEL UNSAFE
  SET search_path = pg_catalog, pg_temp AS $vetra_context$
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
    RETURN false;
  END IF;
  parts := pg_catalog.string_to_array(token, '.');
  IF pg_catalog.cardinality(parts) <> 4 OR parts[1] <> 'v1'
     OR parts[2] !~ '^[A-Za-z0-9_-]{1,64}$' OR parts[3] !~ '^[A-Za-z0-9_-]+$'
     OR parts[4] !~ '^[A-Za-z0-9_-]{43}$' THEN
    RETURN false;
  END IF;
  SELECT k.secret, k.not_before INTO key_secret, key_not_before FROM "vetra_private"."keys" k
    WHERE k.kid = parts[2] AND k.status IN ('active', 'verify_only')
      AND k.not_before <= pg_catalog.transaction_timestamp();
  IF key_secret IS NULL THEN RETURN false; END IF;
  supplied := pg_catalog.decode(pg_catalog.translate(parts[4], '-_', '+/') || '=', 'base64');
  expected := "vetra_private"."hmac"(pg_catalog.convert_to(parts[1] || '.' || parts[2] || '.' || parts[3], 'UTF8'), key_secret, 'sha256');
  IF pg_catalog.octet_length(supplied) <> 32 THEN RETURN false; END IF;
  FOR i IN 0..31 LOOP
    difference := difference | (pg_catalog.get_byte(supplied, i) # pg_catalog.get_byte(expected, i));
  END LOOP;
  IF difference <> 0 OR pg_catalog.rtrim(pg_catalog.translate(pg_catalog.encode(supplied, 'base64'), '+/', '-_'), '=') <> parts[4] THEN
    RETURN false;
  END IF;
  payload_bytes := pg_catalog.decode(pg_catalog.translate(parts[3], '-_', '+/') || pg_catalog.repeat('=', (4 - pg_catalog.length(parts[3]) % 4) % 4), 'base64');
  IF pg_catalog.rtrim(pg_catalog.translate(pg_catalog.replace(pg_catalog.encode(payload_bytes, 'base64'), E'\n', ''), '+/', '-_'), '=') <> parts[3] THEN
    RETURN false;
  END IF;
  payload := pg_catalog.convert_from(payload_bytes, 'UTF8')::jsonb;
  IF pg_catalog.jsonb_typeof(payload) IS DISTINCT FROM 'object'
     OR pg_catalog.jsonb_typeof(payload->'tenant_id') IS DISTINCT FROM 'string'
     OR pg_catalog.jsonb_typeof(payload->'op_id') IS DISTINCT FROM 'string'
     OR (payload->>'tenant_id') !~ uuid_pattern
     OR (payload->>'op_id') !~ uuid_pattern
     OR pg_catalog.jsonb_typeof(payload->'cmd') IS DISTINCT FROM 'string'
     OR pg_catalog.char_length(payload->>'cmd') NOT BETWEEN 1 AND 255
     OR pg_catalog.jsonb_typeof(payload->'iat') IS DISTINCT FROM 'number'
     OR pg_catalog.jsonb_typeof(payload->'exp') IS DISTINCT FROM 'number'
     OR (payload->>'iat') !~ '^[0-9]{1,12}$' OR (payload->>'exp') !~ '^[0-9]{1,12}$' THEN
    RETURN false;
  END IF;
  IF payload ? 'operator_id' AND (pg_catalog.jsonb_typeof(payload->'operator_id') IS DISTINCT FROM 'string'
     OR (payload->>'operator_id') !~ uuid_pattern) THEN RETURN false; END IF;
  IF (payload ? 'actor_id') = (payload ? 'system_actor') THEN RETURN false; END IF;
  IF payload ? 'actor_id' AND (pg_catalog.jsonb_typeof(payload->'actor_id') IS DISTINCT FROM 'string'
     OR (payload->>'actor_id') !~ uuid_pattern) THEN RETURN false; END IF;
  IF payload ? 'system_actor' AND (pg_catalog.jsonb_typeof(payload->'system_actor') IS DISTINCT FROM 'string'
     OR (payload->>'system_actor') !~ '^[A-Za-z][A-Za-z0-9_.:-]{0,127}$') THEN RETURN false; END IF;
  issued := (payload->>'iat')::bigint;
  expires := (payload->>'exp')::bigint;
  IF expires < issued OR expires > issued + 120 OR now_epoch < issued - 5 OR now_epoch > expires
     OR key_not_before > pg_catalog.to_timestamp(issued::double precision) THEN
    RETURN false;
  END IF;
  RETURN payload ? 'system_actor';
EXCEPTION WHEN OTHERS THEN
  RETURN false;
END
$vetra_context$;

-- vetra:passo 4 fase=expand lock=nenhum custo=catalogo transacao=sim
ALTER FUNCTION "vetra"."is_system_actor"() OWNER TO "vetra_owner";

-- vetra:passo 5 fase=expand lock=nenhum custo=catalogo transacao=sim
REVOKE ALL ON FUNCTION "vetra"."is_system_actor"() FROM PUBLIC, "vetra_app";

-- vetra:passo 6 fase=expand lock=nenhum custo=catalogo transacao=sim
GRANT EXECUTE ON FUNCTION "vetra"."is_system_actor"() TO "vetra_app";

-- vetra:passo 7 fase=expand lock=AccessExclusive custo=catalogo transacao=sim
DROP POLICY "vt_tenant" ON "public"."dealers";
DROP POLICY "vt_scope_read" ON "public"."dealers";
CREATE POLICY "vt_tenant" ON "public"."dealers" AS RESTRICTIVE FOR ALL TO "vetra_app" USING ("company_id" = (SELECT vetra.current_tenant())) WITH CHECK ("company_id" = (SELECT vetra.current_tenant()));
CREATE POLICY "vt_scope_read" ON "public"."dealers" AS PERMISSIVE FOR SELECT TO "vetra_app" USING (("dealers"."id" = ANY (ARRAY(SELECT "vt_scope_1"."dealer_id" FROM "public"."memberships" AS "vt_scope_1" WHERE ("vt_scope_1"."company_id" = (SELECT vetra.current_tenant())) AND (("vt_scope_1"."role" IN (E'gerente', E'vendedor')) AND ("vt_scope_1"."user_id" = (SELECT vetra.current_actor())))))));
CREATE POLICY "vt_system" ON "public"."dealers" AS PERMISSIVE FOR ALL TO "vetra_app" USING ((SELECT vetra.is_system_actor())) WITH CHECK ((SELECT vetra.is_system_actor()));

-- vetra:passo 8 fase=expand lock=AccessExclusive custo=catalogo transacao=sim
DROP POLICY "vt_tenant" ON "public"."leads";
DROP POLICY "vt_scope_read" ON "public"."leads";
DROP POLICY "vt_scope_create" ON "public"."leads";
DROP POLICY "vt_scope_update" ON "public"."leads";
DROP POLICY "vt_scope_delete" ON "public"."leads";
CREATE POLICY "vt_tenant" ON "public"."leads" AS RESTRICTIVE FOR ALL TO "vetra_app" USING ("company_id" = (SELECT vetra.current_tenant())) WITH CHECK ("company_id" = (SELECT vetra.current_tenant()));
CREATE POLICY "vt_scope_read" ON "public"."leads" AS PERMISSIVE FOR SELECT TO "vetra_app" USING (("leads"."dealer_id" = ANY (ARRAY(SELECT "vt_scope_2"."dealer_id" FROM "public"."memberships" AS "vt_scope_2" WHERE ("vt_scope_2"."company_id" = (SELECT vetra.current_tenant())) AND (("vt_scope_2"."role" IN (E'gerente', E'vendedor')) AND ("vt_scope_2"."user_id" = (SELECT vetra.current_actor())))))));
CREATE POLICY "vt_scope_create" ON "public"."leads" AS PERMISSIVE FOR INSERT TO "vetra_app" WITH CHECK (("leads"."dealer_id" = ANY (ARRAY(SELECT "vt_scope_3"."dealer_id" FROM "public"."memberships" AS "vt_scope_3" WHERE ("vt_scope_3"."company_id" = (SELECT vetra.current_tenant())) AND (("vt_scope_3"."role" IN (E'gerente', E'vendedor')) AND ("vt_scope_3"."user_id" = (SELECT vetra.current_actor())))))));
CREATE POLICY "vt_scope_update" ON "public"."leads" AS PERMISSIVE FOR UPDATE TO "vetra_app" USING (("leads"."dealer_id" = ANY (ARRAY(SELECT "vt_scope_4"."dealer_id" FROM "public"."memberships" AS "vt_scope_4" WHERE ("vt_scope_4"."company_id" = (SELECT vetra.current_tenant())) AND (("vt_scope_4"."role" IN (E'gerente', E'vendedor')) AND ("vt_scope_4"."user_id" = (SELECT vetra.current_actor()))))))) WITH CHECK (("leads"."dealer_id" = ANY (ARRAY(SELECT "vt_scope_4"."dealer_id" FROM "public"."memberships" AS "vt_scope_4" WHERE ("vt_scope_4"."company_id" = (SELECT vetra.current_tenant())) AND (("vt_scope_4"."role" IN (E'gerente', E'vendedor')) AND ("vt_scope_4"."user_id" = (SELECT vetra.current_actor())))))));
CREATE POLICY "vt_scope_delete" ON "public"."leads" AS PERMISSIVE FOR DELETE TO "vetra_app" USING (("leads"."dealer_id" = ANY (ARRAY(SELECT "vt_scope_5"."dealer_id" FROM "public"."memberships" AS "vt_scope_5" WHERE ("vt_scope_5"."company_id" = (SELECT vetra.current_tenant())) AND (("vt_scope_5"."role" = E'gerente') AND ("vt_scope_5"."user_id" = (SELECT vetra.current_actor())))))));
CREATE POLICY "vt_system" ON "public"."leads" AS PERMISSIVE FOR ALL TO "vetra_app" USING ((SELECT vetra.is_system_actor())) WITH CHECK ((SELECT vetra.is_system_actor()));

-- vetra:passo 9 fase=expand lock=ShareRowExclusive custo=catalogo transacao=sim
LOCK TABLE ONLY "public"."companies", ONLY "public"."dealers", ONLY "public"."leads", ONLY "public"."memberships", ONLY "public"."users" IN SHARE ROW EXCLUSIVE MODE;
DO $vetra_privileges$
BEGIN
IF EXISTS (SELECT 1 FROM pg_roles r WHERE pg_has_role('vetra_app', r.oid, 'SET') AND (has_table_privilege(r.oid, '"public"."companies"', 'TRUNCATE,TRIGGER')
  OR has_any_column_privilege(r.oid, '"public"."companies"', 'REFERENCES'))) THEN
  RAISE EXCEPTION 'Privilégios herdados ou assumíveis por SET ROLE de TRUNCATE/TRIGGER/REFERENCES ainda permitem alterar a invalidação';
END IF;
IF EXISTS (SELECT 1 FROM pg_roles r WHERE pg_has_role('vetra_app', r.oid, 'SET') AND (has_table_privilege(r.oid, '"public"."dealers"', 'TRUNCATE,TRIGGER')
  OR has_any_column_privilege(r.oid, '"public"."dealers"', 'REFERENCES'))) THEN
  RAISE EXCEPTION 'Privilégios herdados ou assumíveis por SET ROLE de TRUNCATE/TRIGGER/REFERENCES ainda permitem alterar a invalidação';
END IF;
IF EXISTS (SELECT 1 FROM pg_roles r WHERE pg_has_role('vetra_app', r.oid, 'SET') AND (has_table_privilege(r.oid, '"public"."leads"', 'TRUNCATE,TRIGGER')
  OR has_any_column_privilege(r.oid, '"public"."leads"', 'REFERENCES'))) THEN
  RAISE EXCEPTION 'Privilégios herdados ou assumíveis por SET ROLE de TRUNCATE/TRIGGER/REFERENCES ainda permitem alterar a invalidação';
END IF;
IF EXISTS (SELECT 1 FROM pg_roles r WHERE pg_has_role('vetra_app', r.oid, 'SET') AND (has_table_privilege(r.oid, '"public"."memberships"', 'TRUNCATE,TRIGGER')
  OR has_any_column_privilege(r.oid, '"public"."memberships"', 'REFERENCES'))) THEN
  RAISE EXCEPTION 'Privilégios herdados ou assumíveis por SET ROLE de TRUNCATE/TRIGGER/REFERENCES ainda permitem alterar a invalidação';
END IF;
IF EXISTS (SELECT 1 FROM pg_roles r WHERE pg_has_role('vetra_app', r.oid, 'SET') AND (has_table_privilege(r.oid, '"public"."users"', 'TRUNCATE,TRIGGER')
  OR has_any_column_privilege(r.oid, '"public"."users"', 'REFERENCES'))) THEN
  RAISE EXCEPTION 'Privilégios herdados ou assumíveis por SET ROLE de TRUNCATE/TRIGGER/REFERENCES ainda permitem alterar a invalidação';
END IF;

  IF EXISTS (SELECT 1 FROM pg_roles r WHERE pg_has_role('vetra_app', r.oid, 'SET') AND has_schema_privilege(r.oid, 'vetra', 'CREATE')) THEN
    RAISE EXCEPTION 'Privilégio herdado ou assumível por SET ROLE permite criar objetos na infraestrutura';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_roles r WHERE pg_has_role('vetra_app', r.oid, 'SET')
    AND (has_table_privilege(r.oid, '"vetra"."authz_revisions"', 'INSERT,UPDATE,DELETE,TRUNCATE,TRIGGER,REFERENCES')
      OR has_any_column_privilege(r.oid, '"vetra"."authz_revisions"', 'INSERT,UPDATE,REFERENCES'))) THEN
    RAISE EXCEPTION 'Privilégio herdado ou assumível por SET ROLE permite escrita nas revisões';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'vetra' AND NOT COALESCE((p.pronamespace = (SELECT oid FROM pg_catalog.pg_namespace WHERE nspname = 'vetra' AND nspowner = (SELECT oid FROM pg_catalog.pg_roles WHERE rolname = 'vetra_owner'))
  AND p.proowner = (SELECT oid FROM pg_catalog.pg_roles WHERE rolname = 'vetra_owner')
  AND p.prolang = (SELECT oid FROM pg_catalog.pg_language WHERE lanname = 'plpgsql')
  AND p.prokind = 'f' AND p.prosecdef AND p.provolatile = 's' AND p.proparallel = 'u'
  AND NOT p.proleakproof AND NOT p.proisstrict AND NOT p.proretset
  AND p.pronargs = 0 AND p.pronargdefaults = 0 AND p.provariadic = 0 AND p.prosupport = 0
  AND p.proallargtypes IS NULL AND p.proargmodes IS NULL AND p.proargnames IS NULL
  AND p.proargdefaults IS NULL AND p.prosqlbody IS NULL AND p.probin IS NULL
  AND p.proconfig = ARRAY['search_path=pg_catalog, pg_temp']::text[]
  AND ((p.proname = 'current_tenant' AND p.prorettype = 'pg_catalog.uuid'::pg_catalog.regtype AND pg_catalog.encode(pg_catalog.sha256(pg_catalog.convert_to(p.prosrc, 'UTF8')), 'hex') = '9b9dea3eee0a770277b8299477a0b0dd4ffe5932b61258af0bc69c2482a11448') OR (p.proname = 'current_actor' AND p.prorettype = 'pg_catalog.uuid'::pg_catalog.regtype AND pg_catalog.encode(pg_catalog.sha256(pg_catalog.convert_to(p.prosrc, 'UTF8')), 'hex') = '6514a4c920f80fdcf89a05b3a0f53f48b091522ddd54d3d029fa63b17223ff17') OR (p.proname = 'is_system_actor' AND p.prorettype = 'pg_catalog.bool'::pg_catalog.regtype AND pg_catalog.encode(pg_catalog.sha256(pg_catalog.convert_to(p.prosrc, 'UTF8')), 'hex') = 'c113fed85d803a3a6da72badf5a7048edbd3287a6370b0446fc2202732278cdf'))), false)
      AND EXISTS (SELECT 1 FROM pg_roles r WHERE pg_has_role('vetra_app', r.oid, 'SET') AND has_function_privilege(r.oid, p.oid, 'EXECUTE'))) THEN
    RAISE EXCEPTION 'Execução herdada ou assumível por SET ROLE das funções de revisão não é permitida';
  END IF;
END $vetra_privileges$;
DO $vetra_routines$
DECLARE unsafe_routines text;
BEGIN
  WITH RECURSIVE definers AS MATERIALIZED (
    SELECT p.oid, p.proowner FROM pg_proc p WHERE p.prosecdef AND p.prokind IN ('f', 'p')
      AND NOT COALESCE((p.pronamespace = (SELECT oid FROM pg_catalog.pg_namespace WHERE nspname = 'vetra' AND nspowner = (SELECT oid FROM pg_catalog.pg_roles WHERE rolname = 'vetra_owner'))
  AND p.proowner = (SELECT oid FROM pg_catalog.pg_roles WHERE rolname = 'vetra_owner')
  AND p.prolang = (SELECT oid FROM pg_catalog.pg_language WHERE lanname = 'plpgsql')
  AND p.prokind = 'f' AND p.prosecdef AND p.provolatile = 's' AND p.proparallel = 'u'
  AND NOT p.proleakproof AND NOT p.proisstrict AND NOT p.proretset
  AND p.pronargs = 0 AND p.pronargdefaults = 0 AND p.provariadic = 0 AND p.prosupport = 0
  AND p.proallargtypes IS NULL AND p.proargmodes IS NULL AND p.proargnames IS NULL
  AND p.proargdefaults IS NULL AND p.prosqlbody IS NULL AND p.probin IS NULL
  AND p.proconfig = ARRAY['search_path=pg_catalog, pg_temp']::text[]
  AND ((p.proname = 'current_tenant' AND p.prorettype = 'pg_catalog.uuid'::pg_catalog.regtype AND pg_catalog.encode(pg_catalog.sha256(pg_catalog.convert_to(p.prosrc, 'UTF8')), 'hex') = '9b9dea3eee0a770277b8299477a0b0dd4ffe5932b61258af0bc69c2482a11448') OR (p.proname = 'current_actor' AND p.prorettype = 'pg_catalog.uuid'::pg_catalog.regtype AND pg_catalog.encode(pg_catalog.sha256(pg_catalog.convert_to(p.prosrc, 'UTF8')), 'hex') = '6514a4c920f80fdcf89a05b3a0f53f48b091522ddd54d3d029fa63b17223ff17') OR (p.proname = 'is_system_actor' AND p.prorettype = 'pg_catalog.bool'::pg_catalog.regtype AND pg_catalog.encode(pg_catalog.sha256(pg_catalog.convert_to(p.prosrc, 'UTF8')), 'hex') = 'c113fed85d803a3a6da72badf5a7048edbd3287a6370b0446fc2202732278cdf'))), false)
  ), owner_roles AS MATERIALIZED (
    SELECT p.proowner, r.oid FROM (SELECT DISTINCT proowner FROM definers) p
      JOIN pg_roles r ON pg_has_role(p.proowner, r.oid, 'SET')
  ), reachable_roles(oid) AS (
    SELECT r.oid FROM pg_roles r WHERE pg_has_role('vetra_app', r.oid, 'SET')
    UNION
    SELECT o.oid FROM reachable_roles a
      JOIN definers p ON has_function_privilege(a.oid, p.oid, 'EXECUTE')
      JOIN owner_roles o ON o.proowner = p.proowner
  ), routine_calls AS MATERIALIZED (
    SELECT a.oid AS caller, p.oid AS routine, p.proowner FROM reachable_roles a
      JOIN definers p ON has_function_privilege(a.oid, p.oid, 'EXECUTE')
  ), unsafe_roles(oid) AS (
    -- Avalia os poderes uma vez por papel alcançável, não a cada caminho até ele.
    SELECT r.oid FROM reachable_roles a JOIN pg_roles r ON r.oid = a.oid
      WHERE r.rolsuper OR r.rolbypassrls OR r.rolcreaterole
        OR pg_has_role(r.oid, 'vetra_owner', 'USAGE')
        OR EXISTS (SELECT 1 FROM pg_class c JOIN pg_namespace s ON s.oid = c.relnamespace
          WHERE c.oid IN ('"public"."companies"'::regclass, '"public"."dealers"'::regclass, '"public"."leads"'::regclass, '"public"."memberships"'::regclass, '"public"."users"'::regclass)
            AND (pg_has_role(r.oid, c.relowner, 'USAGE') OR pg_has_role(r.oid, s.nspowner, 'USAGE')
              OR has_table_privilege(r.oid, c.oid, 'TRUNCATE,TRIGGER')
              OR has_any_column_privilege(r.oid, c.oid, 'REFERENCES')))
        OR has_schema_privilege(r.oid, 'vetra', 'CREATE')
        OR has_table_privilege(r.oid, '"vetra"."authz_revisions"', 'INSERT,UPDATE,DELETE,TRUNCATE,TRIGGER,REFERENCES')
        OR has_any_column_privilege(r.oid, '"vetra"."authz_revisions"', 'INSERT,UPDATE,REFERENCES')
        OR EXISTS (SELECT 1 FROM pg_proc p WHERE p.pronamespace = 'vetra'::regnamespace
          AND NOT COALESCE((p.pronamespace = (SELECT oid FROM pg_catalog.pg_namespace WHERE nspname = 'vetra' AND nspowner = (SELECT oid FROM pg_catalog.pg_roles WHERE rolname = 'vetra_owner'))
  AND p.proowner = (SELECT oid FROM pg_catalog.pg_roles WHERE rolname = 'vetra_owner')
  AND p.prolang = (SELECT oid FROM pg_catalog.pg_language WHERE lanname = 'plpgsql')
  AND p.prokind = 'f' AND p.prosecdef AND p.provolatile = 's' AND p.proparallel = 'u'
  AND NOT p.proleakproof AND NOT p.proisstrict AND NOT p.proretset
  AND p.pronargs = 0 AND p.pronargdefaults = 0 AND p.provariadic = 0 AND p.prosupport = 0
  AND p.proallargtypes IS NULL AND p.proargmodes IS NULL AND p.proargnames IS NULL
  AND p.proargdefaults IS NULL AND p.prosqlbody IS NULL AND p.probin IS NULL
  AND p.proconfig = ARRAY['search_path=pg_catalog, pg_temp']::text[]
  AND ((p.proname = 'current_tenant' AND p.prorettype = 'pg_catalog.uuid'::pg_catalog.regtype AND pg_catalog.encode(pg_catalog.sha256(pg_catalog.convert_to(p.prosrc, 'UTF8')), 'hex') = '9b9dea3eee0a770277b8299477a0b0dd4ffe5932b61258af0bc69c2482a11448') OR (p.proname = 'current_actor' AND p.prorettype = 'pg_catalog.uuid'::pg_catalog.regtype AND pg_catalog.encode(pg_catalog.sha256(pg_catalog.convert_to(p.prosrc, 'UTF8')), 'hex') = '6514a4c920f80fdcf89a05b3a0f53f48b091522ddd54d3d029fa63b17223ff17') OR (p.proname = 'is_system_actor' AND p.prorettype = 'pg_catalog.bool'::pg_catalog.regtype AND pg_catalog.encode(pg_catalog.sha256(pg_catalog.convert_to(p.prosrc, 'UTF8')), 'hex') = 'c113fed85d803a3a6da72badf5a7048edbd3287a6370b0446fc2202732278cdf'))), false)
          AND has_function_privilege(r.oid, p.oid, 'EXECUTE'))
        OR EXISTS (SELECT 1 FROM pg_auth_members m WHERE m.admin_option AND pg_has_role(r.oid, m.member, 'USAGE'))
        OR pg_has_role(r.oid, 'pg_create_subscription'::regrole, 'USAGE')
        OR EXISTS (SELECT 1 FROM pg_subscription s WHERE pg_has_role(r.oid, s.subowner, 'USAGE'))
        OR EXISTS (SELECT 1 FROM pg_roles server_role
          WHERE server_role.rolname IN ('pg_execute_server_program', 'pg_write_server_files', 'pg_read_server_files')
            AND pg_has_role(r.oid, server_role.oid, 'USAGE'))
    UNION
    -- Volta pelas chamadas para listar também as rotinas de entrada e intermediárias.
    SELECT c.caller FROM unsafe_roles u JOIN owner_roles o ON o.oid = u.oid
      JOIN routine_calls c ON c.proowner = o.proowner
  )
  SELECT string_agg(format('%I.%I(%s) [dono: %I]', n.nspname, p.proname,
    pg_get_function_identity_arguments(p.oid), pg_get_userbyid(p.proowner)), '; ' ORDER BY n.nspname, p.proname, p.oid)
    INTO unsafe_routines
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE EXISTS (SELECT 1 FROM routine_calls c WHERE c.routine = p.oid)
      AND EXISTS (SELECT 1 FROM owner_roles o JOIN unsafe_roles u ON u.oid = o.oid
        WHERE o.proowner = p.proowner);
  IF unsafe_routines IS NOT NULL THEN
    RAISE EXCEPTION 'Rotinas SECURITY DEFINER executáveis pela aplicação com dono privilegiado: %', unsafe_routines
      USING HINT = 'Revogue EXECUTE de PUBLIC, da aplicação, dos papéis herdados ou assumíveis e dos donos intermediários antes de instalar.';
  END IF;
END $vetra_routines$;

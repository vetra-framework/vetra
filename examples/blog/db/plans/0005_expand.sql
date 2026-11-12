-- vetra:plano 0005 expand
-- vetra:transacao por_passo
--
-- Gerado por `vetra db:plan` a partir de .vetra/graph.json. Revise antes de aplicar e confira com
-- `vetra db:plan --check`. Cada passo diz a fase, o lock que pede numa tabela existente e o custo.

-- vetra:passo 1 fase=expand lock=nenhum custo=catalogo transacao=sim
CREATE TABLE "vetra"."rate_limit" (
  "id" bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  "namespace" text NOT NULL,
  "policy_id" text NOT NULL,
  "tenant_id" uuid,
  "actor_id" uuid NOT NULL,
  "admitted_at" timestamp(6) with time zone NOT NULL DEFAULT pg_catalog.clock_timestamp()
);
ALTER TABLE "vetra"."rate_limit" OWNER TO "vetra_owner";
REVOKE ALL ON TABLE "vetra"."rate_limit" FROM PUBLIC, "vetra_app", "vetra_relay";
CREATE INDEX "vt_rate_limit_counter" ON "vetra"."rate_limit" ("namespace", "policy_id", "tenant_id", "actor_id", "admitted_at", "id");
CREATE INDEX "vt_rate_limit_purge" ON "vetra"."rate_limit" ("admitted_at", "id");
ALTER TABLE "vetra"."rate_limit" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "vetra"."rate_limit" FORCE ROW LEVEL SECURITY;
CREATE POLICY "vt_rate_limit_owner" ON "vetra"."rate_limit" AS PERMISSIVE FOR ALL TO "vetra_owner" USING (true) WITH CHECK (true);
CREATE POLICY "vt_rate_limit_relay" ON "vetra"."rate_limit" AS PERMISSIVE FOR SELECT TO "vetra_relay" USING (true);
CREATE POLICY "vt_rate_limit_purge" ON "vetra"."rate_limit" AS PERMISSIVE FOR DELETE TO "vetra_relay" USING (true);
GRANT SELECT, DELETE ON TABLE "vetra"."rate_limit" TO "vetra_relay";
CREATE FUNCTION "vetra"."reserve_rate_limit"(text) RETURNS bigint
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $vetra_rate_limit$
DECLARE
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
  IF pg_catalog.cardinality(parts) <> 4 OR parts[1] <> 'r1'
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
     OR NOT (payload ? 'tenant_id') OR (payload->'tenant_id' <> 'null'::jsonb AND pg_catalog.jsonb_typeof(payload->'tenant_id') IS DISTINCT FROM 'string')
     OR pg_catalog.jsonb_typeof(payload->'actor_id') IS DISTINCT FROM 'string'
     OR pg_catalog.jsonb_typeof(payload->'op_id') IS DISTINCT FROM 'string'
     OR ((payload->>'tenant_id') IS NOT NULL AND (payload->>'tenant_id') !~ uuid_pattern) OR (payload->>'actor_id') !~ uuid_pattern
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
EXCEPTION WHEN OTHERS THEN
  RETURN NULL;
END
$vetra_rate_limit$;
ALTER FUNCTION "vetra"."reserve_rate_limit"(text) OWNER TO "vetra_owner";
REVOKE ALL ON FUNCTION "vetra"."reserve_rate_limit"(text) FROM PUBLIC, "vetra_app", "vetra_relay";
GRANT EXECUTE ON FUNCTION "vetra"."reserve_rate_limit"(text) TO "vetra_app";
DO $vetra_rate_limit_routines$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_proc p WHERE COALESCE((p.pronamespace = (SELECT oid FROM pg_catalog.pg_namespace WHERE nspname = 'vetra' AND nspowner = 'vetra_owner'::regrole)
  AND p.proname = 'reserve_rate_limit' AND p.proowner = 'vetra_owner'::regrole
  AND p.prolang = (SELECT oid FROM pg_catalog.pg_language WHERE lanname = 'plpgsql')
  AND p.prokind = 'f' AND p.prosecdef AND p.provolatile = 'v' AND p.proparallel = 'u'
  AND NOT p.proleakproof AND NOT p.proisstrict AND NOT p.proretset
  AND p.pronargs = 1 AND p.proargtypes = '25'::pg_catalog.oidvector AND p.prorettype = 'pg_catalog.int8'::regtype
  AND p.pronargdefaults = 0 AND p.provariadic = 0 AND p.prosupport = 0
  AND p.proallargtypes IS NULL AND p.proargmodes IS NULL AND p.proargnames IS NULL
  AND p.proargdefaults IS NULL AND p.prosqlbody IS NULL AND p.probin IS NULL
  AND p.proconfig = ARRAY['search_path=pg_catalog, pg_temp']::text[]
  AND pg_catalog.encode(pg_catalog.sha256(pg_catalog.convert_to(p.prosrc, 'UTF8')), 'hex') = '2e3e112b71f55eee835de5238bd3ded763c4e664821a3dd8c8859b99eb07c27f'), false)) THEN
    RAISE EXCEPTION 'Rotina de reserva de taxa incompatível com o ADR-051';
  END IF;
END $vetra_rate_limit_routines$;

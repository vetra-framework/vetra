-- Retrato do esquema: resultado de aplicar db/plans/ num banco vazio (vetra db:plan --snapshot).
-- Gerado a partir do pg_dump --schema-only normalizado, com donos; não edite à mão.
-- vetra:base 0001_inicial sha256=26bce26b615308acfbf3bb768c65dd85b9a9a3add19f02b7bd0efc6c5b6033c3
-- vetra:base 0002_expand sha256=61c3c42273fbd3777f8cca9d35b7a5002eb9934a17b1dfed28645e77e9f10929
-- vetra:base 0003_expand sha256=e284e8d252520473d806135f8831fddc7e029a09e2cc3d3ffc4acceb175ec450
-- vetra:base 0004_expand sha256=844868a4395f6c6f2406a255c4853f0d2fc4a5e979238d284f6da3afc9e08176
-- vetra:base 0005_expand sha256=d88c5d14aba9976cf424f80a3fe95600251c028fb9b5a8f3ff198dd92579ba0f
-- vetra:base 0006_expand sha256=eacde1fc964886a20bff87958628f350a165ab7f127872c7c55bfb89f157cca4

ALTER SCHEMA public OWNER TO vetra_owner;

CREATE SCHEMA vetra;

ALTER SCHEMA vetra OWNER TO vetra_owner;

CREATE SCHEMA vetra_private;

ALTER SCHEMA vetra_private OWNER TO vetra_owner;

CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA vetra_private;

COMMENT ON EXTENSION pgcrypto IS 'cryptographic functions';

CREATE FUNCTION vetra.current_actor() RETURNS uuid
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pg_temp'
    AS $_$
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
$_$;

ALTER FUNCTION vetra.current_actor() OWNER TO vetra_owner;

CREATE FUNCTION vetra.current_tenant() RETURNS uuid
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pg_temp'
    AS $_$
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
$_$;

ALTER FUNCTION vetra.current_tenant() OWNER TO vetra_owner;

CREATE FUNCTION vetra.is_system_actor() RETURNS boolean
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pg_temp'
    AS $_$
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
$_$;

ALTER FUNCTION vetra.is_system_actor() OWNER TO vetra_owner;

CREATE FUNCTION vetra.outbox_maintain(ahead integer, retention integer) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pg_temp'
    SET lock_timeout TO '3s'
    AS $_$
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
$_$;

ALTER FUNCTION vetra.outbox_maintain(ahead integer, retention integer) OWNER TO vetra_owner;

CREATE FUNCTION vetra.vt_authz_01e3b579ef1811b6be2c64ee_delete() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pg_temp'
    AS $$
DECLARE affected_tenant text;
BEGIN
  FOR affected_tenant IN SELECT DISTINCT "company_id"::text AS tenant_id FROM vt_old ORDER BY tenant_id LOOP
    INSERT INTO "vetra"."authz_revisions" AS stored (tenant_id, revision) VALUES (affected_tenant, 1)
      ON CONFLICT (tenant_id) DO UPDATE SET revision = stored.revision + 1;
    PERFORM pg_notify('vetra_authz', affected_tenant);
  END LOOP;
  RETURN NULL;
END $$;

ALTER FUNCTION vetra.vt_authz_01e3b579ef1811b6be2c64ee_delete() OWNER TO vetra_owner;

CREATE FUNCTION vetra.vt_authz_01e3b579ef1811b6be2c64ee_insert() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pg_temp'
    AS $$
DECLARE affected_tenant text;
BEGIN
  FOR affected_tenant IN SELECT DISTINCT "company_id"::text AS tenant_id FROM vt_new ORDER BY tenant_id LOOP
    INSERT INTO "vetra"."authz_revisions" AS stored (tenant_id, revision) VALUES (affected_tenant, 1)
      ON CONFLICT (tenant_id) DO UPDATE SET revision = stored.revision + 1;
    PERFORM pg_notify('vetra_authz', affected_tenant);
  END LOOP;
  RETURN NULL;
END $$;

ALTER FUNCTION vetra.vt_authz_01e3b579ef1811b6be2c64ee_insert() OWNER TO vetra_owner;

CREATE FUNCTION vetra.vt_authz_01e3b579ef1811b6be2c64ee_update() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pg_temp'
    AS $$
DECLARE affected_tenant text;
BEGIN
  FOR affected_tenant IN SELECT "company_id"::text AS tenant_id FROM vt_old UNION SELECT "company_id"::text AS tenant_id FROM vt_new ORDER BY tenant_id LOOP
    INSERT INTO "vetra"."authz_revisions" AS stored (tenant_id, revision) VALUES (affected_tenant, 1)
      ON CONFLICT (tenant_id) DO UPDATE SET revision = stored.revision + 1;
    PERFORM pg_notify('vetra_authz', affected_tenant);
  END LOOP;
  RETURN NULL;
END $$;

ALTER FUNCTION vetra.vt_authz_01e3b579ef1811b6be2c64ee_update() OWNER TO vetra_owner;

CREATE FUNCTION vetra.vt_authz_5aab7bffb3a1c59035452764_delete() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pg_temp'
    AS $$
DECLARE affected_tenant text;
BEGIN
  FOR affected_tenant IN SELECT DISTINCT "id"::text AS tenant_id FROM vt_old ORDER BY tenant_id LOOP
    INSERT INTO "vetra"."authz_revisions" AS stored (tenant_id, revision) VALUES (affected_tenant, 1)
      ON CONFLICT (tenant_id) DO UPDATE SET revision = stored.revision + 1;
    PERFORM pg_notify('vetra_authz', affected_tenant);
  END LOOP;
  RETURN NULL;
END $$;

ALTER FUNCTION vetra.vt_authz_5aab7bffb3a1c59035452764_delete() OWNER TO vetra_owner;

CREATE FUNCTION vetra.vt_authz_5aab7bffb3a1c59035452764_insert() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pg_temp'
    AS $$
DECLARE affected_tenant text;
BEGIN
  FOR affected_tenant IN SELECT DISTINCT "id"::text AS tenant_id FROM vt_new ORDER BY tenant_id LOOP
    INSERT INTO "vetra"."authz_revisions" AS stored (tenant_id, revision) VALUES (affected_tenant, 1)
      ON CONFLICT (tenant_id) DO UPDATE SET revision = stored.revision + 1;
    PERFORM pg_notify('vetra_authz', affected_tenant);
  END LOOP;
  RETURN NULL;
END $$;

ALTER FUNCTION vetra.vt_authz_5aab7bffb3a1c59035452764_insert() OWNER TO vetra_owner;

CREATE FUNCTION vetra.vt_authz_5aab7bffb3a1c59035452764_update() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pg_temp'
    AS $$
DECLARE affected_tenant text;
BEGIN
  FOR affected_tenant IN SELECT "id"::text AS tenant_id FROM vt_old UNION SELECT "id"::text AS tenant_id FROM vt_new ORDER BY tenant_id LOOP
    INSERT INTO "vetra"."authz_revisions" AS stored (tenant_id, revision) VALUES (affected_tenant, 1)
      ON CONFLICT (tenant_id) DO UPDATE SET revision = stored.revision + 1;
    PERFORM pg_notify('vetra_authz', affected_tenant);
  END LOOP;
  RETURN NULL;
END $$;

ALTER FUNCTION vetra.vt_authz_5aab7bffb3a1c59035452764_update() OWNER TO vetra_owner;

CREATE FUNCTION vetra.vt_authz_7bf2063f1fe867c04fa2ed84_delete() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pg_temp'
    AS $$
DECLARE affected_tenant text;
BEGIN
  FOR affected_tenant IN SELECT DISTINCT "company_id"::text AS tenant_id FROM vt_old ORDER BY tenant_id LOOP
    INSERT INTO "vetra"."authz_revisions" AS stored (tenant_id, revision) VALUES (affected_tenant, 1)
      ON CONFLICT (tenant_id) DO UPDATE SET revision = stored.revision + 1;
    PERFORM pg_notify('vetra_authz', affected_tenant);
  END LOOP;
  RETURN NULL;
END $$;

ALTER FUNCTION vetra.vt_authz_7bf2063f1fe867c04fa2ed84_delete() OWNER TO vetra_owner;

CREATE FUNCTION vetra.vt_authz_7bf2063f1fe867c04fa2ed84_insert() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pg_temp'
    AS $$
DECLARE affected_tenant text;
BEGIN
  FOR affected_tenant IN SELECT DISTINCT "company_id"::text AS tenant_id FROM vt_new ORDER BY tenant_id LOOP
    INSERT INTO "vetra"."authz_revisions" AS stored (tenant_id, revision) VALUES (affected_tenant, 1)
      ON CONFLICT (tenant_id) DO UPDATE SET revision = stored.revision + 1;
    PERFORM pg_notify('vetra_authz', affected_tenant);
  END LOOP;
  RETURN NULL;
END $$;

ALTER FUNCTION vetra.vt_authz_7bf2063f1fe867c04fa2ed84_insert() OWNER TO vetra_owner;

CREATE FUNCTION vetra.vt_authz_7bf2063f1fe867c04fa2ed84_update() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pg_temp'
    AS $$
DECLARE affected_tenant text;
BEGIN
  FOR affected_tenant IN SELECT "company_id"::text AS tenant_id FROM vt_old UNION SELECT "company_id"::text AS tenant_id FROM vt_new ORDER BY tenant_id LOOP
    INSERT INTO "vetra"."authz_revisions" AS stored (tenant_id, revision) VALUES (affected_tenant, 1)
      ON CONFLICT (tenant_id) DO UPDATE SET revision = stored.revision + 1;
    PERFORM pg_notify('vetra_authz', affected_tenant);
  END LOOP;
  RETURN NULL;
END $$;

ALTER FUNCTION vetra.vt_authz_7bf2063f1fe867c04fa2ed84_update() OWNER TO vetra_owner;

CREATE FUNCTION vetra.vt_authz_86073356dc99948c9f46bbfd_delete() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pg_temp'
    AS $$
DECLARE affected_tenant text;
BEGIN
  FOR affected_tenant IN SELECT DISTINCT "company_id"::text AS tenant_id FROM vt_old ORDER BY tenant_id LOOP
    INSERT INTO "vetra"."authz_revisions" AS stored (tenant_id, revision) VALUES (affected_tenant, 1)
      ON CONFLICT (tenant_id) DO UPDATE SET revision = stored.revision + 1;
    PERFORM pg_notify('vetra_authz', affected_tenant);
  END LOOP;
  RETURN NULL;
END $$;

ALTER FUNCTION vetra.vt_authz_86073356dc99948c9f46bbfd_delete() OWNER TO vetra_owner;

CREATE FUNCTION vetra.vt_authz_86073356dc99948c9f46bbfd_insert() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pg_temp'
    AS $$
DECLARE affected_tenant text;
BEGIN
  FOR affected_tenant IN SELECT DISTINCT "company_id"::text AS tenant_id FROM vt_new ORDER BY tenant_id LOOP
    INSERT INTO "vetra"."authz_revisions" AS stored (tenant_id, revision) VALUES (affected_tenant, 1)
      ON CONFLICT (tenant_id) DO UPDATE SET revision = stored.revision + 1;
    PERFORM pg_notify('vetra_authz', affected_tenant);
  END LOOP;
  RETURN NULL;
END $$;

ALTER FUNCTION vetra.vt_authz_86073356dc99948c9f46bbfd_insert() OWNER TO vetra_owner;

CREATE FUNCTION vetra.vt_authz_86073356dc99948c9f46bbfd_update() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pg_temp'
    AS $$
DECLARE affected_tenant text;
BEGIN
  FOR affected_tenant IN SELECT "company_id"::text AS tenant_id FROM vt_old UNION SELECT "company_id"::text AS tenant_id FROM vt_new ORDER BY tenant_id LOOP
    INSERT INTO "vetra"."authz_revisions" AS stored (tenant_id, revision) VALUES (affected_tenant, 1)
      ON CONFLICT (tenant_id) DO UPDATE SET revision = stored.revision + 1;
    PERFORM pg_notify('vetra_authz', affected_tenant);
  END LOOP;
  RETURN NULL;
END $$;

ALTER FUNCTION vetra.vt_authz_86073356dc99948c9f46bbfd_update() OWNER TO vetra_owner;

CREATE FUNCTION vetra.vt_authz_d19ed6c10293be4bf7dd9b93_delete() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pg_temp'
    AS $$
DECLARE affected_tenant text;
BEGIN
  FOR affected_tenant IN SELECT DISTINCT "company_id"::text AS tenant_id FROM vt_old ORDER BY tenant_id LOOP
    INSERT INTO "vetra"."authz_revisions" AS stored (tenant_id, revision) VALUES (affected_tenant, 1)
      ON CONFLICT (tenant_id) DO UPDATE SET revision = stored.revision + 1;
    PERFORM pg_notify('vetra_authz', affected_tenant);
  END LOOP;
  RETURN NULL;
END $$;

ALTER FUNCTION vetra.vt_authz_d19ed6c10293be4bf7dd9b93_delete() OWNER TO vetra_owner;

CREATE FUNCTION vetra.vt_authz_d19ed6c10293be4bf7dd9b93_insert() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pg_temp'
    AS $$
DECLARE affected_tenant text;
BEGIN
  FOR affected_tenant IN SELECT DISTINCT "company_id"::text AS tenant_id FROM vt_new ORDER BY tenant_id LOOP
    INSERT INTO "vetra"."authz_revisions" AS stored (tenant_id, revision) VALUES (affected_tenant, 1)
      ON CONFLICT (tenant_id) DO UPDATE SET revision = stored.revision + 1;
    PERFORM pg_notify('vetra_authz', affected_tenant);
  END LOOP;
  RETURN NULL;
END $$;

ALTER FUNCTION vetra.vt_authz_d19ed6c10293be4bf7dd9b93_insert() OWNER TO vetra_owner;

CREATE FUNCTION vetra.vt_authz_d19ed6c10293be4bf7dd9b93_update() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'pg_temp'
    AS $$
DECLARE affected_tenant text;
BEGIN
  FOR affected_tenant IN SELECT "company_id"::text AS tenant_id FROM vt_old UNION SELECT "company_id"::text AS tenant_id FROM vt_new ORDER BY tenant_id LOOP
    INSERT INTO "vetra"."authz_revisions" AS stored (tenant_id, revision) VALUES (affected_tenant, 1)
      ON CONFLICT (tenant_id) DO UPDATE SET revision = stored.revision + 1;
    PERFORM pg_notify('vetra_authz', affected_tenant);
  END LOOP;
  RETURN NULL;
END $$;

ALTER FUNCTION vetra.vt_authz_d19ed6c10293be4bf7dd9b93_update() OWNER TO vetra_owner;

CREATE FUNCTION vetra.vt_transition_f11b74e8383ca04610952e448ddcd983() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'pg_catalog', 'pg_temp'
    AS $$
DECLARE token text; payload_part text; command_name text;
BEGIN
  IF current_user = 'vetra_migrator' THEN RETURN NEW; END IF;
  -- A função de contexto valida o token inteiro, inclusive cmd, antes de extrair a claim.
  token := pg_catalog.current_setting('vetra.ctx', true);
  IF vetra.current_tenant() IS NULL THEN
    RAISE EXCEPTION 'transition_violation' USING ERRCODE = '42501';
  END IF;
  payload_part := pg_catalog.split_part(token, '.', 3);
  command_name := pg_catalog.convert_from(pg_catalog.decode(pg_catalog.translate(payload_part, '-_', '+/') ||
    pg_catalog.repeat('=', (4 - pg_catalog.length(payload_part) % 4) % 4), 'base64'), 'UTF8')::jsonb->>'cmd';
IF ((TG_OP = 'INSERT' AND NEW."status" = E'won') OR (TG_OP = 'UPDATE' AND NEW."status" IS DISTINCT FROM OLD."status" AND (NEW."status" = E'won' OR OLD."status" = E'won'))) AND (command_name IS NULL OR command_name NOT IN (E'crm.win_lead')) THEN
  RAISE EXCEPTION 'transition_violation' USING ERRCODE = '42501';
END IF;
  RETURN NEW;
END $$;

ALTER FUNCTION vetra.vt_transition_f11b74e8383ca04610952e448ddcd983() OWNER TO vetra_owner;

CREATE TABLE public.companies (
    created_at timestamp(6) with time zone NOT NULL,
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name text NOT NULL
);

ALTER TABLE ONLY public.companies FORCE ROW LEVEL SECURITY;

ALTER TABLE public.companies OWNER TO vetra_owner;

CREATE TABLE public.dealers (
    company_id uuid NOT NULL,
    created_at timestamp(6) with time zone NOT NULL,
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name text NOT NULL
);

ALTER TABLE ONLY public.dealers FORCE ROW LEVEL SECURITY;

ALTER TABLE public.dealers OWNER TO vetra_owner;

CREATE TABLE public.leads (
    company_id uuid NOT NULL,
    created_at timestamp(6) with time zone NOT NULL,
    dealer_id uuid NOT NULL,
    email text,
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name text NOT NULL,
    seller_id uuid,
    status text DEFAULT 'new'::text NOT NULL,
    valor_amount numeric(19,2),
    valor_currency text,
    CONSTRAINT vt_ck_09fca56d131fbca8bb8b28409cfc25ce CHECK ((valor_amount <> 'NaN'::numeric)),
    CONSTRAINT vt_ck_242d848d9fc19c20ee60aa78d6e27ba0 CHECK ((char_length(name) <= 160)),
    CONSTRAINT vt_ck_2ecae20e3dc7306aaef71329e733f2bc CHECK ((char_length(name) >= 2)),
    CONSTRAINT vt_ck_553df3e9e965bf8efdc803982848cf31 CHECK ((status = ANY (ARRAY['contacted'::text, 'lost'::text, 'new'::text, 'won'::text]))),
    CONSTRAINT vt_ck_6f555cb8ab4a60c13c3a43eea5c9b008 CHECK (((valor_amount IS NULL) = (valor_currency IS NULL))),
    CONSTRAINT vt_ck_8917258bea0d4daa1b638f66d025afff CHECK ((valor_currency = ANY (ARRAY['AED'::text, 'AFN'::text, 'ALL'::text, 'AMD'::text, 'AOA'::text, 'ARS'::text, 'AUD'::text, 'AWG'::text, 'AZN'::text, 'BAM'::text, 'BBD'::text, 'BDT'::text, 'BIF'::text, 'BMD'::text, 'BND'::text, 'BOB'::text, 'BOV'::text, 'BRL'::text, 'BSD'::text, 'BTN'::text, 'BWP'::text, 'BYN'::text, 'BZD'::text, 'CAD'::text, 'CDF'::text, 'CHE'::text, 'CHF'::text, 'CHW'::text, 'CLP'::text, 'CNY'::text, 'COP'::text, 'COU'::text, 'CRC'::text, 'CUP'::text, 'CVE'::text, 'CZK'::text, 'DJF'::text, 'DKK'::text, 'DOP'::text, 'DZD'::text, 'EGP'::text, 'ERN'::text, 'ETB'::text, 'EUR'::text, 'FJD'::text, 'FKP'::text, 'GBP'::text, 'GEL'::text, 'GHS'::text, 'GIP'::text, 'GMD'::text, 'GNF'::text, 'GTQ'::text, 'GYD'::text, 'HKD'::text, 'HNL'::text, 'HTG'::text, 'HUF'::text, 'IDR'::text, 'ILS'::text, 'INR'::text, 'IRR'::text, 'ISK'::text, 'JMD'::text, 'JPY'::text, 'KES'::text, 'KGS'::text, 'KHR'::text, 'KMF'::text, 'KPW'::text, 'KRW'::text, 'KYD'::text, 'KZT'::text, 'LAK'::text, 'LBP'::text, 'LKR'::text, 'LRD'::text, 'LSL'::text, 'MAD'::text, 'MDL'::text, 'MGA'::text, 'MKD'::text, 'MMK'::text, 'MNT'::text, 'MOP'::text, 'MRU'::text, 'MUR'::text, 'MVR'::text, 'MWK'::text, 'MXN'::text, 'MXV'::text, 'MYR'::text, 'MZN'::text, 'NAD'::text, 'NGN'::text, 'NIO'::text, 'NOK'::text, 'NPR'::text, 'NZD'::text, 'PAB'::text, 'PEN'::text, 'PGK'::text, 'PHP'::text, 'PKR'::text, 'PLN'::text, 'PYG'::text, 'QAR'::text, 'RON'::text, 'RSD'::text, 'RUB'::text, 'RWF'::text, 'SAR'::text, 'SBD'::text, 'SCR'::text, 'SDG'::text, 'SEK'::text, 'SGD'::text, 'SHP'::text, 'SLE'::text, 'SOS'::text, 'SRD'::text, 'SSP'::text, 'STN'::text, 'SVC'::text, 'SYP'::text, 'SZL'::text, 'THB'::text, 'TJS'::text, 'TMT'::text, 'TOP'::text, 'TRY'::text, 'TTD'::text, 'TWD'::text, 'TZS'::text, 'UAH'::text, 'UGX'::text, 'USD'::text, 'USN'::text, 'UYI'::text, 'UYU'::text, 'UZS'::text, 'VED'::text, 'VES'::text, 'VND'::text, 'VUV'::text, 'WST'::text, 'XAD'::text, 'XAF'::text, 'XCD'::text, 'XCG'::text, 'XOF'::text, 'XPF'::text, 'YER'::text, 'ZAR'::text, 'ZMW'::text, 'ZWG'::text])))
);

ALTER TABLE ONLY public.leads FORCE ROW LEVEL SECURITY;

ALTER TABLE public.leads OWNER TO vetra_owner;

CREATE TABLE public.memberships (
    company_id uuid NOT NULL,
    created_at timestamp(6) with time zone NOT NULL,
    dealer_id uuid NOT NULL,
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    role text NOT NULL,
    user_id uuid NOT NULL,
    CONSTRAINT vt_ck_65b396fea188eea8a1e8dbf919dbc23e CHECK ((role = ANY (ARRAY['gerente'::text, 'vendedor'::text])))
);

ALTER TABLE ONLY public.memberships FORCE ROW LEVEL SECURITY;

ALTER TABLE public.memberships OWNER TO vetra_owner;

CREATE TABLE public.users (
    company_id uuid NOT NULL,
    created_at timestamp(6) with time zone NOT NULL,
    email text NOT NULL,
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name text NOT NULL
);

ALTER TABLE ONLY public.users FORCE ROW LEVEL SECURITY;

ALTER TABLE public.users OWNER TO vetra_owner;

CREATE TABLE vetra.authz_revisions (
    tenant_id text NOT NULL,
    revision bigint NOT NULL,
    CONSTRAINT authz_revisions_revision_check CHECK ((revision >= 0))
);

ALTER TABLE vetra.authz_revisions OWNER TO vetra_owner;

CREATE TABLE vetra.dead_deliveries (
    handler text NOT NULL,
    event_id uuid NOT NULL,
    event_created_at timestamp(6) with time zone NOT NULL,
    event_xid8 xid8 NOT NULL,
    event_seq bigint NOT NULL,
    event text NOT NULL,
    version integer NOT NULL,
    tenant_id uuid,
    payload jsonb NOT NULL,
    attempts integer NOT NULL,
    last_error text,
    died_at timestamp(6) with time zone DEFAULT statement_timestamp() NOT NULL,
    CONSTRAINT dead_deliveries_attempts_check CHECK ((attempts >= 0)),
    CONSTRAINT dead_deliveries_event_check CHECK ((event ~ '^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$'::text)),
    CONSTRAINT dead_deliveries_handler_check CHECK ((handler ~ '^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$'::text)),
    CONSTRAINT dead_deliveries_payload_check CHECK ((jsonb_typeof(payload) = 'object'::text)),
    CONSTRAINT dead_deliveries_version_check CHECK ((version > 0))
);

ALTER TABLE ONLY vetra.dead_deliveries FORCE ROW LEVEL SECURITY;

ALTER TABLE vetra.dead_deliveries OWNER TO vetra_owner;

CREATE TABLE vetra.deliveries (
    event_created_at timestamp(6) with time zone NOT NULL,
    event_xid8 xid8 NOT NULL,
    event_seq bigint NOT NULL,
    event_id uuid NOT NULL,
    handler text NOT NULL,
    tenant_id uuid,
    state text DEFAULT 'pending'::text NOT NULL,
    attempts integer DEFAULT 0 NOT NULL,
    run_after timestamp(6) with time zone DEFAULT statement_timestamp() NOT NULL,
    leased_until timestamp(6) with time zone,
    last_error text,
    created_at timestamp(6) with time zone DEFAULT statement_timestamp() NOT NULL,
    updated_at timestamp(6) with time zone DEFAULT statement_timestamp() NOT NULL,
    CONSTRAINT deliveries_attempts_check CHECK ((attempts >= 0)),
    CONSTRAINT deliveries_handler_check CHECK ((handler ~ '^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$'::text)),
    CONSTRAINT deliveries_state_check CHECK ((state = ANY (ARRAY['pending'::text, 'done'::text, 'dead'::text])))
)
PARTITION BY RANGE (event_created_at);

ALTER TABLE ONLY vetra.deliveries FORCE ROW LEVEL SECURITY;

ALTER TABLE vetra.deliveries OWNER TO vetra_owner;

CREATE TABLE vetra.deliveries_default (
    event_created_at timestamp(6) with time zone NOT NULL,
    event_xid8 xid8 NOT NULL,
    event_seq bigint NOT NULL,
    event_id uuid NOT NULL,
    handler text NOT NULL,
    tenant_id uuid,
    state text DEFAULT 'pending'::text NOT NULL,
    attempts integer DEFAULT 0 NOT NULL,
    run_after timestamp(6) with time zone DEFAULT statement_timestamp() NOT NULL,
    leased_until timestamp(6) with time zone,
    last_error text,
    created_at timestamp(6) with time zone DEFAULT statement_timestamp() NOT NULL,
    updated_at timestamp(6) with time zone DEFAULT statement_timestamp() NOT NULL,
    CONSTRAINT deliveries_attempts_check CHECK ((attempts >= 0)),
    CONSTRAINT deliveries_handler_check CHECK ((handler ~ '^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$'::text)),
    CONSTRAINT deliveries_state_check CHECK ((state = ANY (ARRAY['pending'::text, 'done'::text, 'dead'::text])))
);

ALTER TABLE ONLY vetra.deliveries_default FORCE ROW LEVEL SECURITY;

ALTER TABLE vetra.deliveries_default OWNER TO vetra_owner;

CREATE TABLE vetra.idempotency (
    id bigint NOT NULL,
    tenant_id uuid,
    command text NOT NULL,
    key text NOT NULL,
    origin text NOT NULL,
    principal text,
    input_hash bytea NOT NULL,
    result jsonb,
    handler text,
    event_id uuid,
    event_created_at timestamp(6) with time zone,
    created_at timestamp(6) with time zone DEFAULT statement_timestamp() NOT NULL,
    CONSTRAINT idempotency_command_check CHECK (((char_length(command) >= 1) AND (char_length(command) <= 255))),
    CONSTRAINT idempotency_input_hash_check CHECK ((octet_length(input_hash) = 32)),
    CONSTRAINT idempotency_key_check CHECK ((key ~ '^[!-~]{1,255}$'::text)),
    CONSTRAINT idempotency_origin_check CHECK ((origin = ANY (ARRAY['adapter'::text, 'event'::text]))),
    CONSTRAINT idempotency_principal_check CHECK (((principal IS NULL) OR ((char_length(principal) >= 1) AND (char_length(principal) <= 160)))),
    CONSTRAINT idempotency_result_check CHECK (((result IS NULL) OR (octet_length((result)::text) <= 65536))),
    CONSTRAINT vt_idempotency_origin CHECK ((((origin = 'event'::text) AND (handler IS NOT NULL) AND (event_id IS NOT NULL) AND (event_created_at IS NOT NULL)) OR ((origin = 'adapter'::text) AND (handler IS NULL) AND (event_id IS NULL) AND (event_created_at IS NULL))))
);

ALTER TABLE ONLY vetra.idempotency FORCE ROW LEVEL SECURITY;

ALTER TABLE vetra.idempotency OWNER TO vetra_owner;

ALTER TABLE vetra.idempotency ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME vetra.idempotency_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);

CREATE TABLE vetra.outbox (
    created_at timestamp(6) with time zone DEFAULT statement_timestamp() NOT NULL,
    xid8 xid8 DEFAULT pg_current_xact_id() NOT NULL,
    seq bigint NOT NULL,
    event_id uuid NOT NULL,
    event text NOT NULL,
    version integer NOT NULL,
    tenant_id uuid,
    actor_id uuid,
    op_id uuid NOT NULL,
    cmd text NOT NULL,
    payload jsonb NOT NULL,
    CONSTRAINT outbox_cmd_check CHECK (((char_length(cmd) >= 1) AND (char_length(cmd) <= 255))),
    CONSTRAINT outbox_event_check CHECK ((event ~ '^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$'::text)),
    CONSTRAINT outbox_payload_check CHECK ((jsonb_typeof(payload) = 'object'::text)),
    CONSTRAINT outbox_version_check CHECK ((version > 0))
)
PARTITION BY RANGE (created_at);

ALTER TABLE ONLY vetra.outbox FORCE ROW LEVEL SECURITY;

ALTER TABLE vetra.outbox OWNER TO vetra_owner;

CREATE TABLE vetra.outbox_default (
    created_at timestamp(6) with time zone DEFAULT statement_timestamp() NOT NULL,
    xid8 xid8 DEFAULT pg_current_xact_id() NOT NULL,
    seq bigint NOT NULL,
    event_id uuid NOT NULL,
    event text NOT NULL,
    version integer NOT NULL,
    tenant_id uuid,
    actor_id uuid,
    op_id uuid NOT NULL,
    cmd text NOT NULL,
    payload jsonb NOT NULL,
    CONSTRAINT outbox_cmd_check CHECK (((char_length(cmd) >= 1) AND (char_length(cmd) <= 255))),
    CONSTRAINT outbox_event_check CHECK ((event ~ '^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$'::text)),
    CONSTRAINT outbox_payload_check CHECK ((jsonb_typeof(payload) = 'object'::text)),
    CONSTRAINT outbox_version_check CHECK ((version > 0))
);

ALTER TABLE ONLY vetra.outbox_default FORCE ROW LEVEL SECURITY;

ALTER TABLE vetra.outbox_default OWNER TO vetra_owner;

ALTER TABLE vetra.outbox ALTER COLUMN seq ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME vetra.outbox_seq_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);

CREATE TABLE vetra.relay_checkpoints (
    name text NOT NULL,
    next_xid8 xid8 NOT NULL,
    updated_at timestamp(6) with time zone DEFAULT statement_timestamp() NOT NULL,
    CONSTRAINT relay_checkpoints_name_check CHECK ((name ~ '^[a-z][a-z0-9_]*$'::text))
);

ALTER TABLE ONLY vetra.relay_checkpoints FORCE ROW LEVEL SECURITY;

ALTER TABLE vetra.relay_checkpoints OWNER TO vetra_owner;

CREATE TABLE vetra_private.keys (
    kid text NOT NULL,
    secret bytea NOT NULL,
    status text NOT NULL,
    not_before timestamp with time zone NOT NULL,
    CONSTRAINT keys_kid_check CHECK ((kid ~ '^[A-Za-z0-9_-]{1,64}$'::text)),
    CONSTRAINT keys_secret_check CHECK ((octet_length(secret) >= 32)),
    CONSTRAINT keys_status_check CHECK ((status = ANY (ARRAY['active'::text, 'verify_only'::text, 'revoked'::text])))
);

ALTER TABLE vetra_private.keys OWNER TO vetra_owner;

ALTER TABLE ONLY vetra.deliveries ATTACH PARTITION vetra.deliveries_default DEFAULT;

ALTER TABLE ONLY vetra.outbox ATTACH PARTITION vetra.outbox_default DEFAULT;

ALTER TABLE ONLY public.users
    ADD CONSTRAINT vt_pk_344f37be5dc149cf8c9590e8719b61c5 PRIMARY KEY (id);

ALTER TABLE ONLY public.memberships
    ADD CONSTRAINT vt_pk_72678947e9265c089ef5e782916c070e PRIMARY KEY (id);

ALTER TABLE ONLY public.dealers
    ADD CONSTRAINT vt_pk_b43d772e1801c2820d5ce950c7904a03 PRIMARY KEY (id);

ALTER TABLE ONLY public.companies
    ADD CONSTRAINT vt_pk_c37b42fe24009eca08260a3f4ae04e1c PRIMARY KEY (id);

ALTER TABLE ONLY public.leads
    ADD CONSTRAINT vt_pk_c80c5863244cc35ab960f4dfbd32cf17 PRIMARY KEY (id);

ALTER TABLE ONLY public.users
    ADD CONSTRAINT vt_uq_10292275116667a4cb37592c31190a5e UNIQUE (company_id, id);

ALTER TABLE ONLY public.memberships
    ADD CONSTRAINT vt_uq_2ad0bcba005223984ee5a30c2cc7594b UNIQUE (company_id, id);

ALTER TABLE ONLY public.leads
    ADD CONSTRAINT vt_uq_42a25356531b11d1e4d5decf7a0e1e24 UNIQUE (company_id, id);

ALTER TABLE ONLY public.dealers
    ADD CONSTRAINT vt_uq_dec744303aacdbb8492f2eaa3c88bead UNIQUE (company_id, id);

ALTER TABLE ONLY public.memberships
    ADD CONSTRAINT vt_uq_f193c8e4d9da74f0e30aad2549ccca62 UNIQUE (company_id, user_id, dealer_id, role);

ALTER TABLE ONLY vetra.authz_revisions
    ADD CONSTRAINT authz_revisions_pkey PRIMARY KEY (tenant_id);

ALTER TABLE ONLY vetra.dead_deliveries
    ADD CONSTRAINT dead_deliveries_pkey PRIMARY KEY (handler, event_id);

ALTER TABLE ONLY vetra.deliveries
    ADD CONSTRAINT deliveries_pkey PRIMARY KEY (handler, event_id, event_created_at);

ALTER TABLE ONLY vetra.deliveries_default
    ADD CONSTRAINT deliveries_default_pkey PRIMARY KEY (handler, event_id, event_created_at);

ALTER TABLE ONLY vetra.idempotency
    ADD CONSTRAINT idempotency_pkey PRIMARY KEY (id);

ALTER TABLE ONLY vetra.outbox
    ADD CONSTRAINT outbox_pkey PRIMARY KEY (created_at, xid8, seq);

ALTER TABLE ONLY vetra.outbox_default
    ADD CONSTRAINT outbox_default_pkey PRIMARY KEY (created_at, xid8, seq);

ALTER TABLE ONLY vetra.relay_checkpoints
    ADD CONSTRAINT relay_checkpoints_pkey PRIMARY KEY (name);

ALTER TABLE ONLY vetra.idempotency
    ADD CONSTRAINT vt_idempotency_key UNIQUE NULLS NOT DISTINCT (tenant_id, command, key);

ALTER TABLE ONLY vetra_private.keys
    ADD CONSTRAINT keys_pkey PRIMARY KEY (kid);

CREATE INDEX vt_ix_507afec86a6c207e0ca28dd203ffb300 ON public.leads USING btree (company_id, status);

CREATE INDEX vt_ix_5d662343cb5148e8d65b15809c1e3c37 ON public.leads USING btree (company_id, dealer_id);

CREATE INDEX vt_ix_ba6fa65b14061f8852d348fd2cc40b43 ON public.memberships USING btree (company_id, dealer_id);

CREATE INDEX vt_ix_f72a7756af1519cd4c2c3c51d5ec8b22 ON public.leads USING btree (company_id, seller_id);

CREATE INDEX vt_deliveries_ready ON ONLY vetra.deliveries USING btree (run_after) WHERE (state = 'pending'::text);

CREATE INDEX deliveries_default_run_after_idx ON vetra.deliveries_default USING btree (run_after) WHERE (state = 'pending'::text);

CREATE INDEX vt_outbox_relay ON ONLY vetra.outbox USING btree (xid8, seq);

CREATE INDEX outbox_default_xid8_seq_idx ON vetra.outbox_default USING btree (xid8, seq);

CREATE INDEX vt_idempotency_purge ON vetra.idempotency USING btree (origin, created_at);

CREATE UNIQUE INDEX vt_keys_active ON vetra_private.keys USING btree (status) WHERE (status = 'active'::text);

ALTER INDEX vetra.deliveries_pkey ATTACH PARTITION vetra.deliveries_default_pkey;

ALTER INDEX vetra.vt_deliveries_ready ATTACH PARTITION vetra.deliveries_default_run_after_idx;

ALTER INDEX vetra.outbox_pkey ATTACH PARTITION vetra.outbox_default_pkey;

ALTER INDEX vetra.vt_outbox_relay ATTACH PARTITION vetra.outbox_default_xid8_seq_idx;

CREATE TRIGGER vt_authz_01e3b579ef1811b6be2c64ee_delete AFTER DELETE ON public.users REFERENCING OLD TABLE AS vt_old FOR EACH STATEMENT EXECUTE FUNCTION vetra.vt_authz_01e3b579ef1811b6be2c64ee_delete();

ALTER TABLE public.users ENABLE ALWAYS TRIGGER vt_authz_01e3b579ef1811b6be2c64ee_delete;

CREATE TRIGGER vt_authz_01e3b579ef1811b6be2c64ee_insert AFTER INSERT ON public.users REFERENCING NEW TABLE AS vt_new FOR EACH STATEMENT EXECUTE FUNCTION vetra.vt_authz_01e3b579ef1811b6be2c64ee_insert();

ALTER TABLE public.users ENABLE ALWAYS TRIGGER vt_authz_01e3b579ef1811b6be2c64ee_insert;

CREATE TRIGGER vt_authz_01e3b579ef1811b6be2c64ee_update AFTER UPDATE ON public.users REFERENCING OLD TABLE AS vt_old NEW TABLE AS vt_new FOR EACH STATEMENT EXECUTE FUNCTION vetra.vt_authz_01e3b579ef1811b6be2c64ee_update();

ALTER TABLE public.users ENABLE ALWAYS TRIGGER vt_authz_01e3b579ef1811b6be2c64ee_update;

CREATE TRIGGER vt_authz_5aab7bffb3a1c59035452764_delete AFTER DELETE ON public.companies REFERENCING OLD TABLE AS vt_old FOR EACH STATEMENT EXECUTE FUNCTION vetra.vt_authz_5aab7bffb3a1c59035452764_delete();

ALTER TABLE public.companies ENABLE ALWAYS TRIGGER vt_authz_5aab7bffb3a1c59035452764_delete;

CREATE TRIGGER vt_authz_5aab7bffb3a1c59035452764_insert AFTER INSERT ON public.companies REFERENCING NEW TABLE AS vt_new FOR EACH STATEMENT EXECUTE FUNCTION vetra.vt_authz_5aab7bffb3a1c59035452764_insert();

ALTER TABLE public.companies ENABLE ALWAYS TRIGGER vt_authz_5aab7bffb3a1c59035452764_insert;

CREATE TRIGGER vt_authz_5aab7bffb3a1c59035452764_update AFTER UPDATE ON public.companies REFERENCING OLD TABLE AS vt_old NEW TABLE AS vt_new FOR EACH STATEMENT EXECUTE FUNCTION vetra.vt_authz_5aab7bffb3a1c59035452764_update();

ALTER TABLE public.companies ENABLE ALWAYS TRIGGER vt_authz_5aab7bffb3a1c59035452764_update;

CREATE TRIGGER vt_authz_7bf2063f1fe867c04fa2ed84_delete AFTER DELETE ON public.leads REFERENCING OLD TABLE AS vt_old FOR EACH STATEMENT EXECUTE FUNCTION vetra.vt_authz_7bf2063f1fe867c04fa2ed84_delete();

ALTER TABLE public.leads ENABLE ALWAYS TRIGGER vt_authz_7bf2063f1fe867c04fa2ed84_delete;

CREATE TRIGGER vt_authz_7bf2063f1fe867c04fa2ed84_insert AFTER INSERT ON public.leads REFERENCING NEW TABLE AS vt_new FOR EACH STATEMENT EXECUTE FUNCTION vetra.vt_authz_7bf2063f1fe867c04fa2ed84_insert();

ALTER TABLE public.leads ENABLE ALWAYS TRIGGER vt_authz_7bf2063f1fe867c04fa2ed84_insert;

CREATE TRIGGER vt_authz_7bf2063f1fe867c04fa2ed84_update AFTER UPDATE ON public.leads REFERENCING OLD TABLE AS vt_old NEW TABLE AS vt_new FOR EACH STATEMENT EXECUTE FUNCTION vetra.vt_authz_7bf2063f1fe867c04fa2ed84_update();

ALTER TABLE public.leads ENABLE ALWAYS TRIGGER vt_authz_7bf2063f1fe867c04fa2ed84_update;

CREATE TRIGGER vt_authz_86073356dc99948c9f46bbfd_delete AFTER DELETE ON public.dealers REFERENCING OLD TABLE AS vt_old FOR EACH STATEMENT EXECUTE FUNCTION vetra.vt_authz_86073356dc99948c9f46bbfd_delete();

ALTER TABLE public.dealers ENABLE ALWAYS TRIGGER vt_authz_86073356dc99948c9f46bbfd_delete;

CREATE TRIGGER vt_authz_86073356dc99948c9f46bbfd_insert AFTER INSERT ON public.dealers REFERENCING NEW TABLE AS vt_new FOR EACH STATEMENT EXECUTE FUNCTION vetra.vt_authz_86073356dc99948c9f46bbfd_insert();

ALTER TABLE public.dealers ENABLE ALWAYS TRIGGER vt_authz_86073356dc99948c9f46bbfd_insert;

CREATE TRIGGER vt_authz_86073356dc99948c9f46bbfd_update AFTER UPDATE ON public.dealers REFERENCING OLD TABLE AS vt_old NEW TABLE AS vt_new FOR EACH STATEMENT EXECUTE FUNCTION vetra.vt_authz_86073356dc99948c9f46bbfd_update();

ALTER TABLE public.dealers ENABLE ALWAYS TRIGGER vt_authz_86073356dc99948c9f46bbfd_update;

CREATE TRIGGER vt_authz_d19ed6c10293be4bf7dd9b93_delete AFTER DELETE ON public.memberships REFERENCING OLD TABLE AS vt_old FOR EACH STATEMENT EXECUTE FUNCTION vetra.vt_authz_d19ed6c10293be4bf7dd9b93_delete();

ALTER TABLE public.memberships ENABLE ALWAYS TRIGGER vt_authz_d19ed6c10293be4bf7dd9b93_delete;

CREATE TRIGGER vt_authz_d19ed6c10293be4bf7dd9b93_insert AFTER INSERT ON public.memberships REFERENCING NEW TABLE AS vt_new FOR EACH STATEMENT EXECUTE FUNCTION vetra.vt_authz_d19ed6c10293be4bf7dd9b93_insert();

ALTER TABLE public.memberships ENABLE ALWAYS TRIGGER vt_authz_d19ed6c10293be4bf7dd9b93_insert;

CREATE TRIGGER vt_authz_d19ed6c10293be4bf7dd9b93_update AFTER UPDATE ON public.memberships REFERENCING OLD TABLE AS vt_old NEW TABLE AS vt_new FOR EACH STATEMENT EXECUTE FUNCTION vetra.vt_authz_d19ed6c10293be4bf7dd9b93_update();

ALTER TABLE public.memberships ENABLE ALWAYS TRIGGER vt_authz_d19ed6c10293be4bf7dd9b93_update;

CREATE TRIGGER vt_transition_f11b74e8383ca04610952e448ddcd983 BEFORE INSERT OR UPDATE ON public.leads FOR EACH ROW EXECUTE FUNCTION vetra.vt_transition_f11b74e8383ca04610952e448ddcd983();

ALTER TABLE public.leads ENABLE ALWAYS TRIGGER vt_transition_f11b74e8383ca04610952e448ddcd983;

ALTER TABLE ONLY public.memberships
    ADD CONSTRAINT vt_fk_057ae10e2c51523cc3a35350d3d8ed01 FOREIGN KEY (company_id, user_id) REFERENCES public.users(company_id, id) DEFERRABLE;

ALTER TABLE ONLY public.memberships
    ADD CONSTRAINT vt_fk_23e2862edd3ae0c1190f4dc21edfe150 FOREIGN KEY (company_id) REFERENCES public.companies(id) DEFERRABLE;

ALTER TABLE ONLY public.leads
    ADD CONSTRAINT vt_fk_70eb50f95e008e03c285c62b8baf5678 FOREIGN KEY (company_id) REFERENCES public.companies(id) DEFERRABLE;

ALTER TABLE ONLY public.memberships
    ADD CONSTRAINT vt_fk_7211b73e05e6868b82aaee0448e1153b FOREIGN KEY (company_id, dealer_id) REFERENCES public.dealers(company_id, id) DEFERRABLE;

ALTER TABLE ONLY public.leads
    ADD CONSTRAINT vt_fk_8b878e59781167f0360b2f869fcdf0af FOREIGN KEY (company_id, dealer_id) REFERENCES public.dealers(company_id, id) DEFERRABLE;

ALTER TABLE ONLY public.dealers
    ADD CONSTRAINT vt_fk_9b6e67cc348ce3c83008af98c8e65744 FOREIGN KEY (company_id) REFERENCES public.companies(id) DEFERRABLE;

ALTER TABLE ONLY public.users
    ADD CONSTRAINT vt_fk_ac86ccd4650187b1da6ac46730cc6d13 FOREIGN KEY (company_id) REFERENCES public.companies(id) DEFERRABLE;

ALTER TABLE ONLY public.leads
    ADD CONSTRAINT vt_fk_f0816bdf4c58bac7b3046779037a72d2 FOREIGN KEY (company_id, seller_id) REFERENCES public.users(company_id, id) DEFERRABLE;

ALTER TABLE public.companies ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.dealers ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.leads ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.memberships ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.users ENABLE ROW LEVEL SECURITY;

CREATE POLICY vt_access ON public.companies TO vetra_app USING (true) WITH CHECK (true);

CREATE POLICY vt_access ON public.memberships TO vetra_app USING (true) WITH CHECK (true);

CREATE POLICY vt_access ON public.users TO vetra_app USING (true) WITH CHECK (true);

CREATE POLICY vt_scope_create ON public.leads FOR INSERT TO vetra_app WITH CHECK ((dealer_id = ANY (ARRAY( SELECT vt_scope_3.dealer_id
   FROM public.memberships vt_scope_3
  WHERE ((vt_scope_3.company_id = ( SELECT vetra.current_tenant() AS current_tenant)) AND ((vt_scope_3.role = ANY (ARRAY['gerente'::text, 'vendedor'::text])) AND (vt_scope_3.user_id = ( SELECT vetra.current_actor() AS current_actor))))))));

CREATE POLICY vt_scope_delete ON public.leads FOR DELETE TO vetra_app USING ((dealer_id = ANY (ARRAY( SELECT vt_scope_5.dealer_id
   FROM public.memberships vt_scope_5
  WHERE ((vt_scope_5.company_id = ( SELECT vetra.current_tenant() AS current_tenant)) AND ((vt_scope_5.role = 'gerente'::text) AND (vt_scope_5.user_id = ( SELECT vetra.current_actor() AS current_actor))))))));

CREATE POLICY vt_scope_read ON public.dealers FOR SELECT TO vetra_app USING ((id = ANY (ARRAY( SELECT vt_scope_1.dealer_id
   FROM public.memberships vt_scope_1
  WHERE ((vt_scope_1.company_id = ( SELECT vetra.current_tenant() AS current_tenant)) AND ((vt_scope_1.role = ANY (ARRAY['gerente'::text, 'vendedor'::text])) AND (vt_scope_1.user_id = ( SELECT vetra.current_actor() AS current_actor))))))));

CREATE POLICY vt_scope_read ON public.leads FOR SELECT TO vetra_app USING ((dealer_id = ANY (ARRAY( SELECT vt_scope_2.dealer_id
   FROM public.memberships vt_scope_2
  WHERE ((vt_scope_2.company_id = ( SELECT vetra.current_tenant() AS current_tenant)) AND ((vt_scope_2.role = ANY (ARRAY['gerente'::text, 'vendedor'::text])) AND (vt_scope_2.user_id = ( SELECT vetra.current_actor() AS current_actor))))))));

CREATE POLICY vt_scope_update ON public.leads FOR UPDATE TO vetra_app USING ((dealer_id = ANY (ARRAY( SELECT vt_scope_4.dealer_id
   FROM public.memberships vt_scope_4
  WHERE ((vt_scope_4.company_id = ( SELECT vetra.current_tenant() AS current_tenant)) AND ((vt_scope_4.role = ANY (ARRAY['gerente'::text, 'vendedor'::text])) AND (vt_scope_4.user_id = ( SELECT vetra.current_actor() AS current_actor)))))))) WITH CHECK ((dealer_id = ANY (ARRAY( SELECT vt_scope_4.dealer_id
   FROM public.memberships vt_scope_4
  WHERE ((vt_scope_4.company_id = ( SELECT vetra.current_tenant() AS current_tenant)) AND ((vt_scope_4.role = ANY (ARRAY['gerente'::text, 'vendedor'::text])) AND (vt_scope_4.user_id = ( SELECT vetra.current_actor() AS current_actor))))))));

CREATE POLICY vt_system ON public.dealers TO vetra_app USING (( SELECT vetra.is_system_actor() AS is_system_actor)) WITH CHECK (( SELECT vetra.is_system_actor() AS is_system_actor));

CREATE POLICY vt_system ON public.leads TO vetra_app USING (( SELECT vetra.is_system_actor() AS is_system_actor)) WITH CHECK (( SELECT vetra.is_system_actor() AS is_system_actor));

CREATE POLICY vt_tenant ON public.companies AS RESTRICTIVE TO vetra_app USING ((id = ( SELECT vetra.current_tenant() AS current_tenant))) WITH CHECK ((id = ( SELECT vetra.current_tenant() AS current_tenant)));

CREATE POLICY vt_tenant ON public.dealers AS RESTRICTIVE TO vetra_app USING ((company_id = ( SELECT vetra.current_tenant() AS current_tenant))) WITH CHECK ((company_id = ( SELECT vetra.current_tenant() AS current_tenant)));

CREATE POLICY vt_tenant ON public.leads AS RESTRICTIVE TO vetra_app USING ((company_id = ( SELECT vetra.current_tenant() AS current_tenant))) WITH CHECK ((company_id = ( SELECT vetra.current_tenant() AS current_tenant)));

CREATE POLICY vt_tenant ON public.memberships AS RESTRICTIVE TO vetra_app USING ((company_id = ( SELECT vetra.current_tenant() AS current_tenant))) WITH CHECK ((company_id = ( SELECT vetra.current_tenant() AS current_tenant)));

CREATE POLICY vt_tenant ON public.users AS RESTRICTIVE TO vetra_app USING ((company_id = ( SELECT vetra.current_tenant() AS current_tenant))) WITH CHECK ((company_id = ( SELECT vetra.current_tenant() AS current_tenant)));

ALTER TABLE vetra.dead_deliveries ENABLE ROW LEVEL SECURITY;

ALTER TABLE vetra.deliveries ENABLE ROW LEVEL SECURITY;

ALTER TABLE vetra.deliveries_default ENABLE ROW LEVEL SECURITY;

ALTER TABLE vetra.idempotency ENABLE ROW LEVEL SECURITY;

ALTER TABLE vetra.outbox ENABLE ROW LEVEL SECURITY;

ALTER TABLE vetra.outbox_default ENABLE ROW LEVEL SECURITY;

ALTER TABLE vetra.relay_checkpoints ENABLE ROW LEVEL SECURITY;

CREATE POLICY vt_dead_deliveries_relay ON vetra.dead_deliveries TO vetra_relay USING (true) WITH CHECK (true);

CREATE POLICY vt_deliveries_default_owner ON vetra.deliveries_default TO vetra_owner USING (true) WITH CHECK (true);

CREATE POLICY vt_deliveries_owner ON vetra.deliveries TO vetra_owner USING (true) WITH CHECK (true);

CREATE POLICY vt_deliveries_relay ON vetra.deliveries TO vetra_relay USING (true) WITH CHECK (true);

CREATE POLICY vt_idempotency_app ON vetra.idempotency TO vetra_app USING ((tenant_id = ( SELECT vetra.current_tenant() AS current_tenant))) WITH CHECK ((tenant_id = ( SELECT vetra.current_tenant() AS current_tenant)));

CREATE POLICY vt_idempotency_relay ON vetra.idempotency TO vetra_relay USING (true) WITH CHECK (true);

CREATE POLICY vt_outbox_default_owner ON vetra.outbox_default TO vetra_owner USING (true) WITH CHECK (true);

CREATE POLICY vt_outbox_insert ON vetra.outbox FOR INSERT TO vetra_app WITH CHECK (((tenant_id = ( SELECT vetra.current_tenant() AS current_tenant)) AND (NOT (actor_id IS DISTINCT FROM ( SELECT vetra.current_actor() AS current_actor)))));

CREATE POLICY vt_outbox_owner ON vetra.outbox TO vetra_owner USING (true) WITH CHECK (true);

CREATE POLICY vt_outbox_relay ON vetra.outbox FOR SELECT TO vetra_relay USING (true);

CREATE POLICY vt_relay_checkpoints_owner ON vetra.relay_checkpoints TO vetra_owner USING (true) WITH CHECK (true);

CREATE POLICY vt_relay_checkpoints_relay ON vetra.relay_checkpoints TO vetra_relay USING (true) WITH CHECK (true);

REVOKE USAGE ON SCHEMA public FROM PUBLIC;
GRANT USAGE ON SCHEMA public TO vetra_app;

GRANT USAGE ON SCHEMA vetra TO vetra_app;
GRANT USAGE ON SCHEMA vetra TO vetra_relay;

REVOKE ALL ON FUNCTION vetra.current_actor() FROM PUBLIC;
GRANT ALL ON FUNCTION vetra.current_actor() TO vetra_app;

REVOKE ALL ON FUNCTION vetra.current_tenant() FROM PUBLIC;
GRANT ALL ON FUNCTION vetra.current_tenant() TO vetra_app;

REVOKE ALL ON FUNCTION vetra.is_system_actor() FROM PUBLIC;
GRANT ALL ON FUNCTION vetra.is_system_actor() TO vetra_app;

REVOKE ALL ON FUNCTION vetra.outbox_maintain(ahead integer, retention integer) FROM PUBLIC;
GRANT ALL ON FUNCTION vetra.outbox_maintain(ahead integer, retention integer) TO vetra_relay;

REVOKE ALL ON FUNCTION vetra.vt_authz_01e3b579ef1811b6be2c64ee_delete() FROM PUBLIC;

REVOKE ALL ON FUNCTION vetra.vt_authz_01e3b579ef1811b6be2c64ee_insert() FROM PUBLIC;

REVOKE ALL ON FUNCTION vetra.vt_authz_01e3b579ef1811b6be2c64ee_update() FROM PUBLIC;

REVOKE ALL ON FUNCTION vetra.vt_authz_5aab7bffb3a1c59035452764_delete() FROM PUBLIC;

REVOKE ALL ON FUNCTION vetra.vt_authz_5aab7bffb3a1c59035452764_insert() FROM PUBLIC;

REVOKE ALL ON FUNCTION vetra.vt_authz_5aab7bffb3a1c59035452764_update() FROM PUBLIC;

REVOKE ALL ON FUNCTION vetra.vt_authz_7bf2063f1fe867c04fa2ed84_delete() FROM PUBLIC;

REVOKE ALL ON FUNCTION vetra.vt_authz_7bf2063f1fe867c04fa2ed84_insert() FROM PUBLIC;

REVOKE ALL ON FUNCTION vetra.vt_authz_7bf2063f1fe867c04fa2ed84_update() FROM PUBLIC;

REVOKE ALL ON FUNCTION vetra.vt_authz_86073356dc99948c9f46bbfd_delete() FROM PUBLIC;

REVOKE ALL ON FUNCTION vetra.vt_authz_86073356dc99948c9f46bbfd_insert() FROM PUBLIC;

REVOKE ALL ON FUNCTION vetra.vt_authz_86073356dc99948c9f46bbfd_update() FROM PUBLIC;

REVOKE ALL ON FUNCTION vetra.vt_authz_d19ed6c10293be4bf7dd9b93_delete() FROM PUBLIC;

REVOKE ALL ON FUNCTION vetra.vt_authz_d19ed6c10293be4bf7dd9b93_insert() FROM PUBLIC;

REVOKE ALL ON FUNCTION vetra.vt_authz_d19ed6c10293be4bf7dd9b93_update() FROM PUBLIC;

REVOKE ALL ON FUNCTION vetra.vt_transition_f11b74e8383ca04610952e448ddcd983() FROM PUBLIC;

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.companies TO vetra_app;

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.dealers TO vetra_app;

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.leads TO vetra_app;

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.memberships TO vetra_app;

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.users TO vetra_app;

GRANT SELECT ON TABLE vetra.authz_revisions TO vetra_app;

GRANT SELECT,INSERT ON TABLE vetra.dead_deliveries TO vetra_relay;

GRANT SELECT,INSERT,UPDATE ON TABLE vetra.deliveries TO vetra_relay;

GRANT SELECT ON TABLE vetra.idempotency TO vetra_app;
GRANT SELECT,DELETE ON TABLE vetra.idempotency TO vetra_relay;

GRANT INSERT(tenant_id) ON TABLE vetra.idempotency TO vetra_app;

GRANT INSERT(command) ON TABLE vetra.idempotency TO vetra_app;

GRANT INSERT(key) ON TABLE vetra.idempotency TO vetra_app;

GRANT INSERT(origin) ON TABLE vetra.idempotency TO vetra_app;

GRANT INSERT(principal) ON TABLE vetra.idempotency TO vetra_app;

GRANT INSERT(input_hash) ON TABLE vetra.idempotency TO vetra_app;

GRANT UPDATE(result) ON TABLE vetra.idempotency TO vetra_app;

GRANT INSERT(handler) ON TABLE vetra.idempotency TO vetra_app;

GRANT INSERT(event_id) ON TABLE vetra.idempotency TO vetra_app;

GRANT INSERT(event_created_at) ON TABLE vetra.idempotency TO vetra_app;

GRANT SELECT ON TABLE vetra.outbox TO vetra_relay;

GRANT INSERT(event_id) ON TABLE vetra.outbox TO vetra_app;

GRANT INSERT(event) ON TABLE vetra.outbox TO vetra_app;

GRANT INSERT(version) ON TABLE vetra.outbox TO vetra_app;

GRANT INSERT(tenant_id) ON TABLE vetra.outbox TO vetra_app;

GRANT INSERT(actor_id) ON TABLE vetra.outbox TO vetra_app;

GRANT INSERT(op_id) ON TABLE vetra.outbox TO vetra_app;

GRANT INSERT(cmd) ON TABLE vetra.outbox TO vetra_app;

GRANT INSERT(payload) ON TABLE vetra.outbox TO vetra_app;

GRANT SELECT,UPDATE ON TABLE vetra.relay_checkpoints TO vetra_relay;

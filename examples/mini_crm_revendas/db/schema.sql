-- Retrato do esquema: resultado de aplicar db/plans/ num banco vazio (vetra db:plan --snapshot).
-- Gerado a partir do pg_dump --schema-only normalizado, com donos; não edite à mão.
-- vetra:base 0001_inicial sha256=26bce26b615308acfbf3bb768c65dd85b9a9a3add19f02b7bd0efc6c5b6033c3

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
  RETURN (payload->>'tenant_id')::uuid;
EXCEPTION WHEN OTHERS THEN
  RETURN NULL;
END
$_$;

ALTER FUNCTION vetra.current_tenant() OWNER TO vetra_owner;

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

ALTER TABLE ONLY vetra_private.keys
    ADD CONSTRAINT keys_pkey PRIMARY KEY (kid);

CREATE INDEX vt_ix_507afec86a6c207e0ca28dd203ffb300 ON public.leads USING btree (company_id, status);

CREATE INDEX vt_ix_5d662343cb5148e8d65b15809c1e3c37 ON public.leads USING btree (company_id, dealer_id);

CREATE INDEX vt_ix_ba6fa65b14061f8852d348fd2cc40b43 ON public.memberships USING btree (company_id, dealer_id);

CREATE INDEX vt_ix_f72a7756af1519cd4c2c3c51d5ec8b22 ON public.leads USING btree (company_id, seller_id);

CREATE UNIQUE INDEX vt_keys_active ON vetra_private.keys USING btree (status) WHERE (status = 'active'::text);

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

CREATE POLICY vt_scope_create ON public.leads FOR INSERT TO vetra_app WITH CHECK (((EXISTS ( SELECT 1
   FROM public.memberships vt_scope_5
  WHERE ((vt_scope_5.company_id = ( SELECT vetra.current_tenant() AS current_tenant)) AND (vt_scope_5.dealer_id = leads.dealer_id) AND ((vt_scope_5.role = 'gerente'::text) AND (vt_scope_5.user_id = ( SELECT vetra.current_actor() AS current_actor)))))) OR (EXISTS ( SELECT 1
   FROM public.memberships vt_scope_6
  WHERE ((vt_scope_6.company_id = ( SELECT vetra.current_tenant() AS current_tenant)) AND (vt_scope_6.dealer_id = leads.dealer_id) AND ((vt_scope_6.role = 'vendedor'::text) AND (vt_scope_6.user_id = ( SELECT vetra.current_actor() AS current_actor))))))));

CREATE POLICY vt_scope_delete ON public.leads FOR DELETE TO vetra_app USING ((EXISTS ( SELECT 1
   FROM public.memberships vt_scope_9
  WHERE ((vt_scope_9.company_id = ( SELECT vetra.current_tenant() AS current_tenant)) AND (vt_scope_9.dealer_id = leads.dealer_id) AND ((vt_scope_9.role = 'gerente'::text) AND (vt_scope_9.user_id = ( SELECT vetra.current_actor() AS current_actor)))))));

CREATE POLICY vt_scope_read ON public.dealers FOR SELECT TO vetra_app USING (((EXISTS ( SELECT 1
   FROM public.memberships vt_scope_1
  WHERE ((vt_scope_1.company_id = ( SELECT vetra.current_tenant() AS current_tenant)) AND (vt_scope_1.dealer_id = dealers.id) AND ((vt_scope_1.role = 'gerente'::text) AND (vt_scope_1.user_id = ( SELECT vetra.current_actor() AS current_actor)))))) OR (EXISTS ( SELECT 1
   FROM public.memberships vt_scope_2
  WHERE ((vt_scope_2.company_id = ( SELECT vetra.current_tenant() AS current_tenant)) AND (vt_scope_2.dealer_id = dealers.id) AND ((vt_scope_2.role = 'vendedor'::text) AND (vt_scope_2.user_id = ( SELECT vetra.current_actor() AS current_actor))))))));

CREATE POLICY vt_scope_read ON public.leads FOR SELECT TO vetra_app USING (((EXISTS ( SELECT 1
   FROM public.memberships vt_scope_3
  WHERE ((vt_scope_3.company_id = ( SELECT vetra.current_tenant() AS current_tenant)) AND (vt_scope_3.dealer_id = leads.dealer_id) AND ((vt_scope_3.role = 'gerente'::text) AND (vt_scope_3.user_id = ( SELECT vetra.current_actor() AS current_actor)))))) OR (EXISTS ( SELECT 1
   FROM public.memberships vt_scope_4
  WHERE ((vt_scope_4.company_id = ( SELECT vetra.current_tenant() AS current_tenant)) AND (vt_scope_4.dealer_id = leads.dealer_id) AND ((vt_scope_4.role = 'vendedor'::text) AND (vt_scope_4.user_id = ( SELECT vetra.current_actor() AS current_actor))))))));

CREATE POLICY vt_scope_update ON public.leads FOR UPDATE TO vetra_app USING (((EXISTS ( SELECT 1
   FROM public.memberships vt_scope_7
  WHERE ((vt_scope_7.company_id = ( SELECT vetra.current_tenant() AS current_tenant)) AND (vt_scope_7.dealer_id = leads.dealer_id) AND ((vt_scope_7.role = 'gerente'::text) AND (vt_scope_7.user_id = ( SELECT vetra.current_actor() AS current_actor)))))) OR (EXISTS ( SELECT 1
   FROM public.memberships vt_scope_8
  WHERE ((vt_scope_8.company_id = ( SELECT vetra.current_tenant() AS current_tenant)) AND (vt_scope_8.dealer_id = leads.dealer_id) AND ((vt_scope_8.role = 'vendedor'::text) AND (vt_scope_8.user_id = ( SELECT vetra.current_actor() AS current_actor)))))))) WITH CHECK (((EXISTS ( SELECT 1
   FROM public.memberships vt_scope_7
  WHERE ((vt_scope_7.company_id = ( SELECT vetra.current_tenant() AS current_tenant)) AND (vt_scope_7.dealer_id = leads.dealer_id) AND ((vt_scope_7.role = 'gerente'::text) AND (vt_scope_7.user_id = ( SELECT vetra.current_actor() AS current_actor)))))) OR (EXISTS ( SELECT 1
   FROM public.memberships vt_scope_8
  WHERE ((vt_scope_8.company_id = ( SELECT vetra.current_tenant() AS current_tenant)) AND (vt_scope_8.dealer_id = leads.dealer_id) AND ((vt_scope_8.role = 'vendedor'::text) AND (vt_scope_8.user_id = ( SELECT vetra.current_actor() AS current_actor))))))));

CREATE POLICY vt_tenant ON public.companies AS RESTRICTIVE TO vetra_app USING ((id = ( SELECT vetra.current_tenant() AS current_tenant))) WITH CHECK ((id = ( SELECT vetra.current_tenant() AS current_tenant)));

CREATE POLICY vt_tenant ON public.dealers AS RESTRICTIVE TO vetra_app USING ((company_id = ( SELECT vetra.current_tenant() AS current_tenant))) WITH CHECK ((company_id = ( SELECT vetra.current_tenant() AS current_tenant)));

CREATE POLICY vt_tenant ON public.leads AS RESTRICTIVE TO vetra_app USING ((company_id = ( SELECT vetra.current_tenant() AS current_tenant))) WITH CHECK ((company_id = ( SELECT vetra.current_tenant() AS current_tenant)));

CREATE POLICY vt_tenant ON public.memberships AS RESTRICTIVE TO vetra_app USING ((company_id = ( SELECT vetra.current_tenant() AS current_tenant))) WITH CHECK ((company_id = ( SELECT vetra.current_tenant() AS current_tenant)));

CREATE POLICY vt_tenant ON public.users AS RESTRICTIVE TO vetra_app USING ((company_id = ( SELECT vetra.current_tenant() AS current_tenant))) WITH CHECK ((company_id = ( SELECT vetra.current_tenant() AS current_tenant)));

REVOKE USAGE ON SCHEMA public FROM PUBLIC;
GRANT USAGE ON SCHEMA public TO vetra_app;

GRANT USAGE ON SCHEMA vetra TO vetra_app;

REVOKE ALL ON FUNCTION vetra.current_actor() FROM PUBLIC;
GRANT ALL ON FUNCTION vetra.current_actor() TO vetra_app;

REVOKE ALL ON FUNCTION vetra.current_tenant() FROM PUBLIC;
GRANT ALL ON FUNCTION vetra.current_tenant() TO vetra_app;

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

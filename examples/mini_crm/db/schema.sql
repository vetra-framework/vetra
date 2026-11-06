-- Retrato do esquema: resultado de aplicar db/plans/ num banco vazio (vetra db:plan --snapshot).
-- Gerado a partir do pg_dump --schema-only normalizado, com donos; não edite à mão.
-- vetra:base 0001_inicial sha256=eac42c3f9568d5c9b6d5c22e754f124dbbafa4c996ab6dcc5043dc7e28c652ef
-- vetra:base 0002_expand sha256=12497f7b0c149ab338151bd617a19b3c84320637372100b6b78827de2069398d

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

CREATE FUNCTION vetra.vt_authz_1cce5ccc9095a100eb7027cd_delete() RETURNS trigger
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

ALTER FUNCTION vetra.vt_authz_1cce5ccc9095a100eb7027cd_delete() OWNER TO vetra_owner;

CREATE FUNCTION vetra.vt_authz_1cce5ccc9095a100eb7027cd_insert() RETURNS trigger
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

ALTER FUNCTION vetra.vt_authz_1cce5ccc9095a100eb7027cd_insert() OWNER TO vetra_owner;

CREATE FUNCTION vetra.vt_authz_1cce5ccc9095a100eb7027cd_update() RETURNS trigger
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

ALTER FUNCTION vetra.vt_authz_1cce5ccc9095a100eb7027cd_update() OWNER TO vetra_owner;

CREATE FUNCTION vetra.vt_authz_229aa3ce667c07c8349e3918_delete() RETURNS trigger
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

ALTER FUNCTION vetra.vt_authz_229aa3ce667c07c8349e3918_delete() OWNER TO vetra_owner;

CREATE FUNCTION vetra.vt_authz_229aa3ce667c07c8349e3918_insert() RETURNS trigger
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

ALTER FUNCTION vetra.vt_authz_229aa3ce667c07c8349e3918_insert() OWNER TO vetra_owner;

CREATE FUNCTION vetra.vt_authz_229aa3ce667c07c8349e3918_update() RETURNS trigger
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

ALTER FUNCTION vetra.vt_authz_229aa3ce667c07c8349e3918_update() OWNER TO vetra_owner;

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

CREATE TABLE public.leads (
    company_id uuid NOT NULL,
    created_at timestamp(6) with time zone NOT NULL,
    email text,
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name text NOT NULL,
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

ALTER TABLE ONLY public.companies
    ADD CONSTRAINT vt_pk_c37b42fe24009eca08260a3f4ae04e1c PRIMARY KEY (id);

ALTER TABLE ONLY public.leads
    ADD CONSTRAINT vt_pk_c80c5863244cc35ab960f4dfbd32cf17 PRIMARY KEY (id);

ALTER TABLE ONLY public.leads
    ADD CONSTRAINT vt_uq_42a25356531b11d1e4d5decf7a0e1e24 UNIQUE (company_id, id);

ALTER TABLE ONLY vetra.authz_revisions
    ADD CONSTRAINT authz_revisions_pkey PRIMARY KEY (tenant_id);

ALTER TABLE ONLY vetra.dead_deliveries
    ADD CONSTRAINT dead_deliveries_pkey PRIMARY KEY (handler, event_id);

ALTER TABLE ONLY vetra.deliveries
    ADD CONSTRAINT deliveries_pkey PRIMARY KEY (handler, event_id, event_created_at);

ALTER TABLE ONLY vetra.deliveries_default
    ADD CONSTRAINT deliveries_default_pkey PRIMARY KEY (handler, event_id, event_created_at);

ALTER TABLE ONLY vetra.outbox
    ADD CONSTRAINT outbox_pkey PRIMARY KEY (created_at, xid8, seq);

ALTER TABLE ONLY vetra.outbox_default
    ADD CONSTRAINT outbox_default_pkey PRIMARY KEY (created_at, xid8, seq);

ALTER TABLE ONLY vetra_private.keys
    ADD CONSTRAINT keys_pkey PRIMARY KEY (kid);

CREATE INDEX vt_ix_507afec86a6c207e0ca28dd203ffb300 ON public.leads USING btree (company_id, status);

CREATE INDEX vt_deliveries_ready ON ONLY vetra.deliveries USING btree (run_after) WHERE (state = 'pending'::text);

CREATE INDEX deliveries_default_run_after_idx ON vetra.deliveries_default USING btree (run_after) WHERE (state = 'pending'::text);

CREATE INDEX vt_outbox_relay ON ONLY vetra.outbox USING btree (xid8, seq);

CREATE INDEX outbox_default_xid8_seq_idx ON vetra.outbox_default USING btree (xid8, seq);

CREATE UNIQUE INDEX vt_keys_active ON vetra_private.keys USING btree (status) WHERE (status = 'active'::text);

ALTER INDEX vetra.deliveries_pkey ATTACH PARTITION vetra.deliveries_default_pkey;

ALTER INDEX vetra.vt_deliveries_ready ATTACH PARTITION vetra.deliveries_default_run_after_idx;

ALTER INDEX vetra.outbox_pkey ATTACH PARTITION vetra.outbox_default_pkey;

ALTER INDEX vetra.vt_outbox_relay ATTACH PARTITION vetra.outbox_default_xid8_seq_idx;

CREATE TRIGGER vt_authz_1cce5ccc9095a100eb7027cd_delete AFTER DELETE ON public.leads REFERENCING OLD TABLE AS vt_old FOR EACH STATEMENT EXECUTE FUNCTION vetra.vt_authz_1cce5ccc9095a100eb7027cd_delete();

ALTER TABLE public.leads ENABLE ALWAYS TRIGGER vt_authz_1cce5ccc9095a100eb7027cd_delete;

CREATE TRIGGER vt_authz_1cce5ccc9095a100eb7027cd_insert AFTER INSERT ON public.leads REFERENCING NEW TABLE AS vt_new FOR EACH STATEMENT EXECUTE FUNCTION vetra.vt_authz_1cce5ccc9095a100eb7027cd_insert();

ALTER TABLE public.leads ENABLE ALWAYS TRIGGER vt_authz_1cce5ccc9095a100eb7027cd_insert;

CREATE TRIGGER vt_authz_1cce5ccc9095a100eb7027cd_update AFTER UPDATE ON public.leads REFERENCING OLD TABLE AS vt_old NEW TABLE AS vt_new FOR EACH STATEMENT EXECUTE FUNCTION vetra.vt_authz_1cce5ccc9095a100eb7027cd_update();

ALTER TABLE public.leads ENABLE ALWAYS TRIGGER vt_authz_1cce5ccc9095a100eb7027cd_update;

CREATE TRIGGER vt_authz_229aa3ce667c07c8349e3918_delete AFTER DELETE ON public.companies REFERENCING OLD TABLE AS vt_old FOR EACH STATEMENT EXECUTE FUNCTION vetra.vt_authz_229aa3ce667c07c8349e3918_delete();

ALTER TABLE public.companies ENABLE ALWAYS TRIGGER vt_authz_229aa3ce667c07c8349e3918_delete;

CREATE TRIGGER vt_authz_229aa3ce667c07c8349e3918_insert AFTER INSERT ON public.companies REFERENCING NEW TABLE AS vt_new FOR EACH STATEMENT EXECUTE FUNCTION vetra.vt_authz_229aa3ce667c07c8349e3918_insert();

ALTER TABLE public.companies ENABLE ALWAYS TRIGGER vt_authz_229aa3ce667c07c8349e3918_insert;

CREATE TRIGGER vt_authz_229aa3ce667c07c8349e3918_update AFTER UPDATE ON public.companies REFERENCING OLD TABLE AS vt_old NEW TABLE AS vt_new FOR EACH STATEMENT EXECUTE FUNCTION vetra.vt_authz_229aa3ce667c07c8349e3918_update();

ALTER TABLE public.companies ENABLE ALWAYS TRIGGER vt_authz_229aa3ce667c07c8349e3918_update;

CREATE TRIGGER vt_transition_f11b74e8383ca04610952e448ddcd983 BEFORE INSERT OR UPDATE ON public.leads FOR EACH ROW EXECUTE FUNCTION vetra.vt_transition_f11b74e8383ca04610952e448ddcd983();

ALTER TABLE public.leads ENABLE ALWAYS TRIGGER vt_transition_f11b74e8383ca04610952e448ddcd983;

ALTER TABLE ONLY public.leads
    ADD CONSTRAINT vt_fk_70eb50f95e008e03c285c62b8baf5678 FOREIGN KEY (company_id) REFERENCES public.companies(id) DEFERRABLE;

ALTER TABLE public.companies ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.leads ENABLE ROW LEVEL SECURITY;

CREATE POLICY vt_access ON public.companies TO vetra_app USING (true) WITH CHECK (true);

CREATE POLICY vt_access ON public.leads TO vetra_app USING (true) WITH CHECK (true);

CREATE POLICY vt_tenant ON public.companies AS RESTRICTIVE TO vetra_app USING ((id = ( SELECT vetra.current_tenant() AS current_tenant))) WITH CHECK ((id = ( SELECT vetra.current_tenant() AS current_tenant)));

CREATE POLICY vt_tenant ON public.leads AS RESTRICTIVE TO vetra_app USING ((company_id = ( SELECT vetra.current_tenant() AS current_tenant))) WITH CHECK ((company_id = ( SELECT vetra.current_tenant() AS current_tenant)));

ALTER TABLE vetra.dead_deliveries ENABLE ROW LEVEL SECURITY;

ALTER TABLE vetra.deliveries ENABLE ROW LEVEL SECURITY;

ALTER TABLE vetra.deliveries_default ENABLE ROW LEVEL SECURITY;

ALTER TABLE vetra.outbox ENABLE ROW LEVEL SECURITY;

ALTER TABLE vetra.outbox_default ENABLE ROW LEVEL SECURITY;

CREATE POLICY vt_outbox_insert ON vetra.outbox FOR INSERT TO vetra_app WITH CHECK (((tenant_id = ( SELECT vetra.current_tenant() AS current_tenant)) AND (NOT (actor_id IS DISTINCT FROM ( SELECT vetra.current_actor() AS current_actor)))));

REVOKE USAGE ON SCHEMA public FROM PUBLIC;
GRANT USAGE ON SCHEMA public TO vetra_app;

GRANT USAGE ON SCHEMA vetra TO vetra_app;

REVOKE ALL ON FUNCTION vetra.current_actor() FROM PUBLIC;
GRANT ALL ON FUNCTION vetra.current_actor() TO vetra_app;

REVOKE ALL ON FUNCTION vetra.current_tenant() FROM PUBLIC;
GRANT ALL ON FUNCTION vetra.current_tenant() TO vetra_app;

REVOKE ALL ON FUNCTION vetra.vt_authz_1cce5ccc9095a100eb7027cd_delete() FROM PUBLIC;

REVOKE ALL ON FUNCTION vetra.vt_authz_1cce5ccc9095a100eb7027cd_insert() FROM PUBLIC;

REVOKE ALL ON FUNCTION vetra.vt_authz_1cce5ccc9095a100eb7027cd_update() FROM PUBLIC;

REVOKE ALL ON FUNCTION vetra.vt_authz_229aa3ce667c07c8349e3918_delete() FROM PUBLIC;

REVOKE ALL ON FUNCTION vetra.vt_authz_229aa3ce667c07c8349e3918_insert() FROM PUBLIC;

REVOKE ALL ON FUNCTION vetra.vt_authz_229aa3ce667c07c8349e3918_update() FROM PUBLIC;

REVOKE ALL ON FUNCTION vetra.vt_transition_f11b74e8383ca04610952e448ddcd983() FROM PUBLIC;

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.companies TO vetra_app;

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.leads TO vetra_app;

GRANT SELECT ON TABLE vetra.authz_revisions TO vetra_app;

GRANT INSERT(event_id) ON TABLE vetra.outbox TO vetra_app;

GRANT INSERT(event) ON TABLE vetra.outbox TO vetra_app;

GRANT INSERT(version) ON TABLE vetra.outbox TO vetra_app;

GRANT INSERT(tenant_id) ON TABLE vetra.outbox TO vetra_app;

GRANT INSERT(actor_id) ON TABLE vetra.outbox TO vetra_app;

GRANT INSERT(op_id) ON TABLE vetra.outbox TO vetra_app;

GRANT INSERT(cmd) ON TABLE vetra.outbox TO vetra_app;

GRANT INSERT(payload) ON TABLE vetra.outbox TO vetra_app;

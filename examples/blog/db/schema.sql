-- Retrato do esquema: resultado de aplicar db/plans/ num banco vazio (vetra db:plan --snapshot).
-- Gerado a partir do pg_dump --schema-only normalizado, com donos; não edite à mão.
-- vetra:base 0001_inicial sha256=3a9923f0b8b998f844d085356e44b6814b54fc627bd2280558b564f8025d196c
-- vetra:base 0002_expand sha256=983ac2efaf8a561d95b84c247fb28e9de4ef0a9d16b4d8991c4d13d152a1aeec
-- vetra:base 0003_expand sha256=e529f9ef1d68262bb0c167e21c2a7d446fda0efc955afba973506a00032f4919
-- vetra:base 0004_expand sha256=4952f9873d87773d64794e7ae60171700950171b8bf30e3a32f26e0123a4b23a

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

CREATE TABLE public.comments (
    approved boolean DEFAULT false NOT NULL,
    author_email text NOT NULL,
    author_name text NOT NULL,
    body text NOT NULL,
    created_at timestamp(6) with time zone NOT NULL,
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    post_id uuid NOT NULL,
    CONSTRAINT vt_ck_c7c0e7456076e638f145552b4955d4be CHECK ((char_length(body) <= 2000)),
    CONSTRAINT vt_ck_fde429239c0bf5c9489713b28d4ae5e2 CHECK ((char_length(author_name) <= 80))
);

ALTER TABLE public.comments OWNER TO vetra_owner;

CREATE TABLE public.posts (
    author_id uuid NOT NULL,
    created_at timestamp(6) with time zone NOT NULL,
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    published_at timestamp(6) with time zone,
    status text DEFAULT 'draft'::text NOT NULL,
    title text NOT NULL,
    CONSTRAINT vt_ck_61ea112cf369b279f4429c9699231bc0 CHECK ((status = ANY (ARRAY['draft'::text, 'published'::text]))),
    CONSTRAINT vt_ck_a5a9aa07fe07d6cfa4b2e63d6d60a1db CHECK ((char_length(title) <= 200))
);

ALTER TABLE public.posts OWNER TO vetra_owner;

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

ALTER TABLE ONLY public.posts
    ADD CONSTRAINT vt_pk_0732ee4194e46d003e5300e171222785 PRIMARY KEY (id);

ALTER TABLE ONLY public.comments
    ADD CONSTRAINT vt_pk_e65d3acd28849b0c97f88486111aef61 PRIMARY KEY (id);

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

CREATE INDEX vt_ix_b376a5f46e965210eb78284646c740a6 ON public.posts USING btree (status, published_at);

CREATE INDEX vt_ix_d3622996ba4077dc3317ae7224cf877c ON public.comments USING btree (post_id);

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

ALTER TABLE ONLY public.comments
    ADD CONSTRAINT vt_fk_d52bd44498b03fbdc39a2c3b32f20bd2 FOREIGN KEY (post_id) REFERENCES public.posts(id) DEFERRABLE;

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

CREATE POLICY vt_idempotency_app ON vetra.idempotency TO vetra_app USING ((tenant_id IS NULL)) WITH CHECK ((tenant_id IS NULL));

CREATE POLICY vt_idempotency_relay ON vetra.idempotency TO vetra_relay USING (true) WITH CHECK (true);

CREATE POLICY vt_outbox_default_owner ON vetra.outbox_default TO vetra_owner USING (true) WITH CHECK (true);

CREATE POLICY vt_outbox_insert ON vetra.outbox FOR INSERT TO vetra_app WITH CHECK ((tenant_id IS NULL));

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

REVOKE ALL ON FUNCTION vetra.outbox_maintain(ahead integer, retention integer) FROM PUBLIC;
GRANT ALL ON FUNCTION vetra.outbox_maintain(ahead integer, retention integer) TO vetra_relay;

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.comments TO vetra_app;

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.posts TO vetra_app;

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

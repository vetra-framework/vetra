-- Retrato do esquema: resultado de aplicar db/plans/ num banco vazio (vetra db:plan --snapshot).
-- Gerado a partir do pg_dump --schema-only normalizado, com donos; não edite à mão.
-- vetra:base 0001_inicial sha256=336cf4db0ffa3c626ccbc42ed9310e0ef207b703475dd6ef95633dd2a81946f9
-- vetra:base 0002_expand sha256=589225e2590a1bb9b1f546b8ba002fbde81b040120fff5c81ba4bb3285778449

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

CREATE TABLE public.messages (
    author_id uuid NOT NULL,
    body text NOT NULL,
    created_at timestamp(6) with time zone NOT NULL,
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    room_id uuid NOT NULL,
    CONSTRAINT vt_ck_60c9617cf5e34dbbe2bea54e76d66b13 CHECK ((char_length(body) <= 4000))
);

ALTER TABLE public.messages OWNER TO vetra_owner;

CREATE TABLE public.room_memberships (
    created_at timestamp(6) with time zone NOT NULL,
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    room_id uuid NOT NULL,
    user_id uuid NOT NULL
);

ALTER TABLE public.room_memberships OWNER TO vetra_owner;

CREATE TABLE public.rooms (
    created_at timestamp(6) with time zone NOT NULL,
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name text NOT NULL,
    owner_id uuid NOT NULL,
    CONSTRAINT vt_ck_edfbcde86f777997d3250f9e8ffd5a85 CHECK ((char_length(name) <= 80))
);

ALTER TABLE public.rooms OWNER TO vetra_owner;

CREATE TABLE public.users (
    created_at timestamp(6) with time zone NOT NULL,
    email text NOT NULL,
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name text NOT NULL,
    CONSTRAINT vt_ck_d1b6d46a7070d1e01500f3308355ceba CHECK ((email = lower(email)))
);

ALTER TABLE public.users OWNER TO vetra_owner;

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
    CONSTRAINT idempotency_origin_check CHECK ((origin = 'adapter'::text)),
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

ALTER TABLE ONLY public.messages
    ADD CONSTRAINT vt_pk_29dd45144ead987a3c36b8eff5054f05 PRIMARY KEY (id);

ALTER TABLE ONLY public.users
    ADD CONSTRAINT vt_pk_344f37be5dc149cf8c9590e8719b61c5 PRIMARY KEY (id);

ALTER TABLE ONLY public.rooms
    ADD CONSTRAINT vt_pk_6ea7e6e7e69a80a75e7b9121bc19b161 PRIMARY KEY (id);

ALTER TABLE ONLY public.room_memberships
    ADD CONSTRAINT vt_pk_e79206a51d8dd23231c4cf4f49c11d55 PRIMARY KEY (id);

ALTER TABLE ONLY public.room_memberships
    ADD CONSTRAINT vt_uq_63280809b6e0753d434cd9533e4818d6 UNIQUE (room_id, user_id);

ALTER TABLE ONLY public.users
    ADD CONSTRAINT vt_uq_790bc8d38d2b0db83fe19d17b070d9fb UNIQUE (email);

ALTER TABLE ONLY vetra.idempotency
    ADD CONSTRAINT idempotency_pkey PRIMARY KEY (id);

ALTER TABLE ONLY vetra.idempotency
    ADD CONSTRAINT vt_idempotency_key UNIQUE NULLS NOT DISTINCT (tenant_id, command, key);

ALTER TABLE ONLY vetra_private.keys
    ADD CONSTRAINT keys_pkey PRIMARY KEY (kid);

CREATE INDEX vt_ix_3b5480ce7197874d7a5bdb6436221573 ON public.messages USING btree (author_id);

CREATE INDEX vt_ix_59b6dee34acd95168591b33e06d42632 ON public.room_memberships USING btree (user_id);

CREATE INDEX vt_ix_6c5a6962c5567e3136218a20ccd778bb ON public.messages USING btree (room_id, created_at);

CREATE INDEX vt_ix_837c5ade83a68764757de4ae044f9802 ON public.rooms USING btree (owner_id);

CREATE INDEX vt_idempotency_purge ON vetra.idempotency USING btree (origin, created_at);

CREATE UNIQUE INDEX vt_keys_active ON vetra_private.keys USING btree (status) WHERE (status = 'active'::text);

ALTER TABLE ONLY public.room_memberships
    ADD CONSTRAINT vt_fk_0b495c1a0bbc85eda7648441551cc807 FOREIGN KEY (room_id) REFERENCES public.rooms(id) DEFERRABLE;

ALTER TABLE ONLY public.messages
    ADD CONSTRAINT vt_fk_64193792c688830b05f0bff5d5c518b3 FOREIGN KEY (room_id) REFERENCES public.rooms(id) DEFERRABLE;

ALTER TABLE ONLY public.room_memberships
    ADD CONSTRAINT vt_fk_887e921b8d995136be84fdaab786f5a2 FOREIGN KEY (user_id) REFERENCES public.users(id) DEFERRABLE;

ALTER TABLE ONLY public.messages
    ADD CONSTRAINT vt_fk_b238fbf3a0c884447c919c7309c73229 FOREIGN KEY (author_id) REFERENCES public.users(id) DEFERRABLE;

ALTER TABLE ONLY public.rooms
    ADD CONSTRAINT vt_fk_d28ab3d2ad832571f34da936408718a9 FOREIGN KEY (owner_id) REFERENCES public.users(id) DEFERRABLE;

ALTER TABLE vetra.idempotency ENABLE ROW LEVEL SECURITY;

CREATE POLICY vt_idempotency_app ON vetra.idempotency TO vetra_app USING ((tenant_id IS NULL)) WITH CHECK ((tenant_id IS NULL));

CREATE POLICY vt_idempotency_relay ON vetra.idempotency TO vetra_relay USING (true) WITH CHECK (true);

REVOKE USAGE ON SCHEMA public FROM PUBLIC;
GRANT USAGE ON SCHEMA public TO vetra_app;

GRANT USAGE ON SCHEMA vetra TO vetra_app;
GRANT USAGE ON SCHEMA vetra TO vetra_relay;

REVOKE ALL ON FUNCTION vetra.current_actor() FROM PUBLIC;
GRANT ALL ON FUNCTION vetra.current_actor() TO vetra_app;

REVOKE ALL ON FUNCTION vetra.current_tenant() FROM PUBLIC;
GRANT ALL ON FUNCTION vetra.current_tenant() TO vetra_app;

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.messages TO vetra_app;

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.room_memberships TO vetra_app;

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.rooms TO vetra_app;

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.users TO vetra_app;

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

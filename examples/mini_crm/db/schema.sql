-- Retrato do esquema: resultado de aplicar db/plans/ num banco vazio (vetra db:plan --snapshot).
-- Gerado a partir do pg_dump --schema-only normalizado, com donos; não edite à mão.

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

CREATE TABLE public.companies (
    created_at timestamp(6) with time zone NOT NULL,
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name text NOT NULL
);

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

ALTER TABLE public.leads OWNER TO vetra_owner;

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

ALTER TABLE ONLY public.companies
    ADD CONSTRAINT vt_pk_c37b42fe24009eca08260a3f4ae04e1c PRIMARY KEY (id);

ALTER TABLE ONLY public.leads
    ADD CONSTRAINT vt_pk_c80c5863244cc35ab960f4dfbd32cf17 PRIMARY KEY (id);

ALTER TABLE ONLY public.leads
    ADD CONSTRAINT vt_uq_42a25356531b11d1e4d5decf7a0e1e24 UNIQUE (company_id, id);

ALTER TABLE ONLY vetra_private.keys
    ADD CONSTRAINT keys_pkey PRIMARY KEY (kid);

CREATE INDEX vt_ix_507afec86a6c207e0ca28dd203ffb300 ON public.leads USING btree (company_id, status);

CREATE UNIQUE INDEX vt_keys_active ON vetra_private.keys USING btree (status) WHERE (status = 'active'::text);

ALTER TABLE ONLY public.leads
    ADD CONSTRAINT vt_fk_70eb50f95e008e03c285c62b8baf5678 FOREIGN KEY (company_id) REFERENCES public.companies(id) DEFERRABLE;

REVOKE USAGE ON SCHEMA public FROM PUBLIC;
GRANT USAGE ON SCHEMA public TO vetra_app;

GRANT USAGE ON SCHEMA vetra TO vetra_app;

REVOKE ALL ON FUNCTION vetra.current_actor() FROM PUBLIC;
GRANT ALL ON FUNCTION vetra.current_actor() TO vetra_app;

REVOKE ALL ON FUNCTION vetra.current_tenant() FROM PUBLIC;
GRANT ALL ON FUNCTION vetra.current_tenant() TO vetra_app;

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.companies TO vetra_app;

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.leads TO vetra_app;

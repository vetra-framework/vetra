-- vetra:plano 0001 inicial
-- vetra:transacao unica
--
-- Gerado por `vetra db:plan` a partir de .vetra/graph.json. Revise antes de aplicar e confira com
-- `vetra db:plan --check`. Cada passo diz a fase, o lock que pede numa tabela existente e o custo.

-- vetra:passo 1 fase=expand lock=nenhum custo=catalogo
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

-- vetra:passo 2 fase=expand lock=nenhum custo=catalogo
DO $vetra_database_privileges$
BEGIN
  EXECUTE pg_catalog.format('REVOKE CREATE, TEMPORARY ON DATABASE %I FROM PUBLIC, "vetra_app"', pg_catalog.current_database());
  EXECUTE pg_catalog.format('GRANT CREATE ON DATABASE %I TO "vetra_owner"', pg_catalog.current_database());
  IF pg_catalog.has_database_privilege('vetra_app', pg_catalog.current_database(), 'CREATE,TEMPORARY') THEN
    RAISE EXCEPTION 'vetra_app não pode criar objetos no banco, nem ser seu dono';
  END IF;
END $vetra_database_privileges$;

-- vetra:passo 3 fase=expand lock=nenhum custo=catalogo
CREATE SCHEMA "vetra" AUTHORIZATION "vetra_owner";

-- vetra:passo 4 fase=expand lock=nenhum custo=catalogo
CREATE SCHEMA "vetra_private" AUTHORIZATION "vetra_owner";

-- vetra:passo 5 fase=expand lock=nenhum custo=catalogo
CREATE EXTENSION "pgcrypto" WITH SCHEMA "vetra_private";

-- vetra:passo 6 fase=expand lock=nenhum custo=catalogo
CREATE TABLE "vetra_private"."keys" (
  "kid" text PRIMARY KEY CHECK ("kid" ~ '^[A-Za-z0-9_-]{1,64}$'),
  "secret" bytea NOT NULL CHECK (pg_catalog.octet_length("secret") >= 32),
  "status" text NOT NULL CHECK ("status" IN ('active', 'verify_only', 'revoked')),
  "not_before" timestamp with time zone NOT NULL
);

-- vetra:passo 7 fase=expand lock=AccessExclusive custo=tabela_vazia
ALTER TABLE "vetra_private"."keys" OWNER TO "vetra_owner";

-- vetra:passo 8 fase=expand lock=Share custo=tabela_vazia
CREATE UNIQUE INDEX "vt_keys_active" ON "vetra_private"."keys" ("status") WHERE "status" = 'active';

-- vetra:passo 9 fase=expand lock=nenhum custo=catalogo
REVOKE ALL ON SCHEMA "vetra", "vetra_private" FROM PUBLIC, "vetra_app";

-- vetra:passo 10 fase=expand lock=nenhum custo=catalogo
REVOKE ALL ON TABLE "vetra_private"."keys" FROM PUBLIC, "vetra_app";

-- vetra:passo 11 fase=expand lock=nenhum custo=catalogo
GRANT USAGE ON SCHEMA "vetra" TO "vetra_app";

-- vetra:passo 12 fase=expand lock=nenhum custo=catalogo
CREATE FUNCTION "vetra"."current_tenant"() RETURNS uuid LANGUAGE plpgsql STABLE SECURITY DEFINER PARALLEL UNSAFE
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
$vetra_context$;

-- vetra:passo 13 fase=expand lock=nenhum custo=catalogo
ALTER FUNCTION "vetra"."current_tenant"() OWNER TO "vetra_owner";

-- vetra:passo 14 fase=expand lock=nenhum custo=catalogo
REVOKE ALL ON FUNCTION "vetra"."current_tenant"() FROM PUBLIC, "vetra_app";

-- vetra:passo 15 fase=expand lock=nenhum custo=catalogo
GRANT EXECUTE ON FUNCTION "vetra"."current_tenant"() TO "vetra_app";

-- vetra:passo 16 fase=expand lock=nenhum custo=catalogo
CREATE FUNCTION "vetra"."current_actor"() RETURNS uuid LANGUAGE plpgsql STABLE SECURITY DEFINER PARALLEL UNSAFE
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
$vetra_context$;

-- vetra:passo 17 fase=expand lock=nenhum custo=catalogo
ALTER FUNCTION "vetra"."current_actor"() OWNER TO "vetra_owner";

-- vetra:passo 18 fase=expand lock=nenhum custo=catalogo
REVOKE ALL ON FUNCTION "vetra"."current_actor"() FROM PUBLIC, "vetra_app";

-- vetra:passo 19 fase=expand lock=nenhum custo=catalogo
GRANT EXECUTE ON FUNCTION "vetra"."current_actor"() TO "vetra_app";

-- vetra:passo 20 fase=expand lock=nenhum custo=catalogo
CREATE TABLE "public"."companies" (
  "created_at" timestamp(6) with time zone NOT NULL,
  "id" uuid NOT NULL DEFAULT pg_catalog.gen_random_uuid(),
  "name" text NOT NULL,
  CONSTRAINT "vt_pk_c37b42fe24009eca08260a3f4ae04e1c" PRIMARY KEY ("id")
);

-- vetra:passo 21 fase=expand lock=nenhum custo=catalogo
CREATE TABLE "public"."dealers" (
  "company_id" uuid NOT NULL,
  "created_at" timestamp(6) with time zone NOT NULL,
  "id" uuid NOT NULL DEFAULT pg_catalog.gen_random_uuid(),
  "name" text NOT NULL,
  CONSTRAINT "vt_pk_b43d772e1801c2820d5ce950c7904a03" PRIMARY KEY ("id")
);

-- vetra:passo 22 fase=expand lock=AccessExclusive custo=tabela_vazia
ALTER TABLE "public"."dealers" ADD CONSTRAINT "vt_uq_dec744303aacdbb8492f2eaa3c88bead" UNIQUE ("company_id", "id");

-- vetra:passo 23 fase=expand lock=nenhum custo=catalogo
CREATE TABLE "public"."leads" (
  "company_id" uuid NOT NULL,
  "created_at" timestamp(6) with time zone NOT NULL,
  "dealer_id" uuid NOT NULL,
  "email" text,
  "id" uuid NOT NULL DEFAULT pg_catalog.gen_random_uuid(),
  "name" text NOT NULL,
  "seller_id" uuid,
  "status" text NOT NULL DEFAULT E'new',
  "valor_amount" numeric(19, 2),
  "valor_currency" text,
  CONSTRAINT "vt_pk_c80c5863244cc35ab960f4dfbd32cf17" PRIMARY KEY ("id"),
  CONSTRAINT "vt_ck_09fca56d131fbca8bb8b28409cfc25ce" CHECK ("valor_amount" <> 'NaN'::numeric),
  CONSTRAINT "vt_ck_242d848d9fc19c20ee60aa78d6e27ba0" CHECK (pg_catalog.char_length("name") <= 160),
  CONSTRAINT "vt_ck_2ecae20e3dc7306aaef71329e733f2bc" CHECK (pg_catalog.char_length("name") >= 2),
  CONSTRAINT "vt_ck_553df3e9e965bf8efdc803982848cf31" CHECK ("status" IN (E'contacted', E'lost', E'new', E'won')),
  CONSTRAINT "vt_ck_6f555cb8ab4a60c13c3a43eea5c9b008" CHECK (("valor_amount" IS NULL) = ("valor_currency" IS NULL)),
  CONSTRAINT "vt_ck_8917258bea0d4daa1b638f66d025afff" CHECK ("valor_currency" IN (E'AED', E'AFN', E'ALL', E'AMD', E'AOA', E'ARS', E'AUD', E'AWG', E'AZN', E'BAM', E'BBD', E'BDT', E'BIF', E'BMD', E'BND', E'BOB', E'BOV', E'BRL', E'BSD', E'BTN', E'BWP', E'BYN', E'BZD', E'CAD', E'CDF', E'CHE', E'CHF', E'CHW', E'CLP', E'CNY', E'COP', E'COU', E'CRC', E'CUP', E'CVE', E'CZK', E'DJF', E'DKK', E'DOP', E'DZD', E'EGP', E'ERN', E'ETB', E'EUR', E'FJD', E'FKP', E'GBP', E'GEL', E'GHS', E'GIP', E'GMD', E'GNF', E'GTQ', E'GYD', E'HKD', E'HNL', E'HTG', E'HUF', E'IDR', E'ILS', E'INR', E'IRR', E'ISK', E'JMD', E'JPY', E'KES', E'KGS', E'KHR', E'KMF', E'KPW', E'KRW', E'KYD', E'KZT', E'LAK', E'LBP', E'LKR', E'LRD', E'LSL', E'MAD', E'MDL', E'MGA', E'MKD', E'MMK', E'MNT', E'MOP', E'MRU', E'MUR', E'MVR', E'MWK', E'MXN', E'MXV', E'MYR', E'MZN', E'NAD', E'NGN', E'NIO', E'NOK', E'NPR', E'NZD', E'PAB', E'PEN', E'PGK', E'PHP', E'PKR', E'PLN', E'PYG', E'QAR', E'RON', E'RSD', E'RUB', E'RWF', E'SAR', E'SBD', E'SCR', E'SDG', E'SEK', E'SGD', E'SHP', E'SLE', E'SOS', E'SRD', E'SSP', E'STN', E'SVC', E'SYP', E'SZL', E'THB', E'TJS', E'TMT', E'TOP', E'TRY', E'TTD', E'TWD', E'TZS', E'UAH', E'UGX', E'USD', E'USN', E'UYI', E'UYU', E'UZS', E'VED', E'VES', E'VND', E'VUV', E'WST', E'XAD', E'XAF', E'XCD', E'XCG', E'XOF', E'XPF', E'YER', E'ZAR', E'ZMW', E'ZWG'))
);

-- vetra:passo 24 fase=expand lock=AccessExclusive custo=tabela_vazia
ALTER TABLE "public"."leads" ADD CONSTRAINT "vt_uq_42a25356531b11d1e4d5decf7a0e1e24" UNIQUE ("company_id", "id");

-- vetra:passo 25 fase=expand lock=Share custo=tabela_vazia
CREATE INDEX "vt_ix_507afec86a6c207e0ca28dd203ffb300" ON "public"."leads" ("company_id", "status");

-- vetra:passo 26 fase=expand lock=Share custo=tabela_vazia
CREATE INDEX "vt_ix_5d662343cb5148e8d65b15809c1e3c37" ON "public"."leads" ("company_id", "dealer_id");

-- vetra:passo 27 fase=expand lock=Share custo=tabela_vazia
CREATE INDEX "vt_ix_f72a7756af1519cd4c2c3c51d5ec8b22" ON "public"."leads" ("company_id", "seller_id");

-- vetra:passo 28 fase=expand lock=nenhum custo=catalogo
CREATE TABLE "public"."memberships" (
  "company_id" uuid NOT NULL,
  "created_at" timestamp(6) with time zone NOT NULL,
  "dealer_id" uuid NOT NULL,
  "id" uuid NOT NULL DEFAULT pg_catalog.gen_random_uuid(),
  "role" text NOT NULL,
  "user_id" uuid NOT NULL,
  CONSTRAINT "vt_pk_72678947e9265c089ef5e782916c070e" PRIMARY KEY ("id"),
  CONSTRAINT "vt_ck_65b396fea188eea8a1e8dbf919dbc23e" CHECK ("role" IN (E'gerente', E'vendedor'))
);

-- vetra:passo 29 fase=expand lock=AccessExclusive custo=tabela_vazia
ALTER TABLE "public"."memberships" ADD CONSTRAINT "vt_uq_2ad0bcba005223984ee5a30c2cc7594b" UNIQUE ("company_id", "id");

-- vetra:passo 30 fase=expand lock=AccessExclusive custo=tabela_vazia
ALTER TABLE "public"."memberships" ADD CONSTRAINT "vt_uq_f193c8e4d9da74f0e30aad2549ccca62" UNIQUE ("company_id", "user_id", "dealer_id", "role");

-- vetra:passo 31 fase=expand lock=Share custo=tabela_vazia
CREATE INDEX "vt_ix_ba6fa65b14061f8852d348fd2cc40b43" ON "public"."memberships" ("company_id", "dealer_id");

-- vetra:passo 32 fase=expand lock=nenhum custo=catalogo
CREATE TABLE "public"."users" (
  "company_id" uuid NOT NULL,
  "created_at" timestamp(6) with time zone NOT NULL,
  "email" text NOT NULL,
  "id" uuid NOT NULL DEFAULT pg_catalog.gen_random_uuid(),
  "name" text NOT NULL,
  CONSTRAINT "vt_pk_344f37be5dc149cf8c9590e8719b61c5" PRIMARY KEY ("id")
);

-- vetra:passo 33 fase=expand lock=AccessExclusive custo=tabela_vazia
ALTER TABLE "public"."users" ADD CONSTRAINT "vt_uq_10292275116667a4cb37592c31190a5e" UNIQUE ("company_id", "id");

-- vetra:passo 34 fase=expand lock=ShareRowExclusive custo=tabela_vazia
ALTER TABLE "public"."dealers" ADD CONSTRAINT "vt_fk_9b6e67cc348ce3c83008af98c8e65744" FOREIGN KEY ("company_id") REFERENCES "public"."companies" ("id") MATCH SIMPLE ON DELETE NO ACTION ON UPDATE NO ACTION DEFERRABLE INITIALLY IMMEDIATE;

-- vetra:passo 35 fase=expand lock=ShareRowExclusive custo=tabela_vazia
ALTER TABLE "public"."leads" ADD CONSTRAINT "vt_fk_70eb50f95e008e03c285c62b8baf5678" FOREIGN KEY ("company_id") REFERENCES "public"."companies" ("id") MATCH SIMPLE ON DELETE NO ACTION ON UPDATE NO ACTION DEFERRABLE INITIALLY IMMEDIATE;

-- vetra:passo 36 fase=expand lock=ShareRowExclusive custo=tabela_vazia
ALTER TABLE "public"."leads" ADD CONSTRAINT "vt_fk_8b878e59781167f0360b2f869fcdf0af" FOREIGN KEY ("company_id", "dealer_id") REFERENCES "public"."dealers" ("company_id", "id") MATCH SIMPLE ON DELETE NO ACTION ON UPDATE NO ACTION DEFERRABLE INITIALLY IMMEDIATE;

-- vetra:passo 37 fase=expand lock=ShareRowExclusive custo=tabela_vazia
ALTER TABLE "public"."leads" ADD CONSTRAINT "vt_fk_f0816bdf4c58bac7b3046779037a72d2" FOREIGN KEY ("company_id", "seller_id") REFERENCES "public"."users" ("company_id", "id") MATCH SIMPLE ON DELETE NO ACTION ON UPDATE NO ACTION DEFERRABLE INITIALLY IMMEDIATE;

-- vetra:passo 38 fase=expand lock=ShareRowExclusive custo=tabela_vazia
ALTER TABLE "public"."memberships" ADD CONSTRAINT "vt_fk_057ae10e2c51523cc3a35350d3d8ed01" FOREIGN KEY ("company_id", "user_id") REFERENCES "public"."users" ("company_id", "id") MATCH SIMPLE ON DELETE NO ACTION ON UPDATE NO ACTION DEFERRABLE INITIALLY IMMEDIATE;

-- vetra:passo 39 fase=expand lock=ShareRowExclusive custo=tabela_vazia
ALTER TABLE "public"."memberships" ADD CONSTRAINT "vt_fk_23e2862edd3ae0c1190f4dc21edfe150" FOREIGN KEY ("company_id") REFERENCES "public"."companies" ("id") MATCH SIMPLE ON DELETE NO ACTION ON UPDATE NO ACTION DEFERRABLE INITIALLY IMMEDIATE;

-- vetra:passo 40 fase=expand lock=ShareRowExclusive custo=tabela_vazia
ALTER TABLE "public"."memberships" ADD CONSTRAINT "vt_fk_7211b73e05e6868b82aaee0448e1153b" FOREIGN KEY ("company_id", "dealer_id") REFERENCES "public"."dealers" ("company_id", "id") MATCH SIMPLE ON DELETE NO ACTION ON UPDATE NO ACTION DEFERRABLE INITIALLY IMMEDIATE;

-- vetra:passo 41 fase=expand lock=ShareRowExclusive custo=tabela_vazia
ALTER TABLE "public"."users" ADD CONSTRAINT "vt_fk_ac86ccd4650187b1da6ac46730cc6d13" FOREIGN KEY ("company_id") REFERENCES "public"."companies" ("id") MATCH SIMPLE ON DELETE NO ACTION ON UPDATE NO ACTION DEFERRABLE INITIALLY IMMEDIATE;

-- vetra:passo 42 fase=expand lock=nenhum custo=catalogo
ALTER SCHEMA "public" OWNER TO "vetra_owner";

-- vetra:passo 43 fase=expand lock=nenhum custo=catalogo
REVOKE ALL ON SCHEMA "public" FROM PUBLIC, "vetra_app";

-- vetra:passo 44 fase=expand lock=nenhum custo=catalogo
GRANT USAGE ON SCHEMA "public" TO "vetra_app";

-- vetra:passo 45 fase=expand lock=AccessExclusive custo=tabela_vazia
ALTER TABLE "public"."companies" OWNER TO "vetra_owner";

-- vetra:passo 46 fase=expand lock=nenhum custo=catalogo
REVOKE ALL ON TABLE "public"."companies" FROM PUBLIC, "vetra_app";

-- vetra:passo 47 fase=expand lock=nenhum custo=catalogo
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE "public"."companies" TO "vetra_app";

-- vetra:passo 48 fase=expand lock=AccessExclusive custo=tabela_vazia
ALTER TABLE "public"."dealers" OWNER TO "vetra_owner";

-- vetra:passo 49 fase=expand lock=nenhum custo=catalogo
REVOKE ALL ON TABLE "public"."dealers" FROM PUBLIC, "vetra_app";

-- vetra:passo 50 fase=expand lock=nenhum custo=catalogo
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE "public"."dealers" TO "vetra_app";

-- vetra:passo 51 fase=expand lock=AccessExclusive custo=tabela_vazia
ALTER TABLE "public"."leads" OWNER TO "vetra_owner";

-- vetra:passo 52 fase=expand lock=nenhum custo=catalogo
REVOKE ALL ON TABLE "public"."leads" FROM PUBLIC, "vetra_app";

-- vetra:passo 53 fase=expand lock=nenhum custo=catalogo
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE "public"."leads" TO "vetra_app";

-- vetra:passo 54 fase=expand lock=AccessExclusive custo=tabela_vazia
ALTER TABLE "public"."memberships" OWNER TO "vetra_owner";

-- vetra:passo 55 fase=expand lock=nenhum custo=catalogo
REVOKE ALL ON TABLE "public"."memberships" FROM PUBLIC, "vetra_app";

-- vetra:passo 56 fase=expand lock=nenhum custo=catalogo
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE "public"."memberships" TO "vetra_app";

-- vetra:passo 57 fase=expand lock=AccessExclusive custo=tabela_vazia
ALTER TABLE "public"."users" OWNER TO "vetra_owner";

-- vetra:passo 58 fase=expand lock=nenhum custo=catalogo
REVOKE ALL ON TABLE "public"."users" FROM PUBLIC, "vetra_app";

-- vetra:passo 59 fase=expand lock=nenhum custo=catalogo
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE "public"."users" TO "vetra_app";

-- vetra:passo 60 fase=expand lock=AccessExclusive custo=tabela_vazia
ALTER TABLE "public"."companies" ENABLE ROW LEVEL SECURITY;

-- vetra:passo 61 fase=expand lock=AccessExclusive custo=tabela_vazia
ALTER TABLE "public"."companies" FORCE ROW LEVEL SECURITY;

-- vetra:passo 62 fase=expand lock=AccessExclusive custo=tabela_vazia
CREATE POLICY "vt_tenant" ON "public"."companies" AS RESTRICTIVE FOR ALL TO "vetra_app" USING ("id" = (SELECT vetra.current_tenant())) WITH CHECK ("id" = (SELECT vetra.current_tenant()));

-- vetra:passo 63 fase=expand lock=AccessExclusive custo=tabela_vazia
CREATE POLICY "vt_access" ON "public"."companies" AS PERMISSIVE FOR ALL TO "vetra_app" USING (true) WITH CHECK (true);

-- vetra:passo 64 fase=expand lock=AccessExclusive custo=tabela_vazia
ALTER TABLE "public"."dealers" ENABLE ROW LEVEL SECURITY;

-- vetra:passo 65 fase=expand lock=AccessExclusive custo=tabela_vazia
ALTER TABLE "public"."dealers" FORCE ROW LEVEL SECURITY;

-- vetra:passo 66 fase=expand lock=AccessExclusive custo=tabela_vazia
CREATE POLICY "vt_tenant" ON "public"."dealers" AS RESTRICTIVE FOR ALL TO "vetra_app" USING ("company_id" = (SELECT vetra.current_tenant())) WITH CHECK ("company_id" = (SELECT vetra.current_tenant()));

-- vetra:passo 67 fase=expand lock=AccessExclusive custo=tabela_vazia
CREATE POLICY "vt_scope_read" ON "public"."dealers" AS PERMISSIVE FOR SELECT TO "vetra_app" USING ((EXISTS (SELECT 1 FROM "public"."memberships" AS "vt_scope_1" WHERE ("vt_scope_1"."company_id" = (SELECT vetra.current_tenant())) AND ("vt_scope_1"."dealer_id" = "dealers"."id") AND (("vt_scope_1"."role" = E'gerente') AND ("vt_scope_1"."user_id" = (SELECT vetra.current_actor()))))) OR (EXISTS (SELECT 1 FROM "public"."memberships" AS "vt_scope_2" WHERE ("vt_scope_2"."company_id" = (SELECT vetra.current_tenant())) AND ("vt_scope_2"."dealer_id" = "dealers"."id") AND (("vt_scope_2"."role" = E'vendedor') AND ("vt_scope_2"."user_id" = (SELECT vetra.current_actor()))))));

-- vetra:passo 68 fase=expand lock=AccessExclusive custo=tabela_vazia
ALTER TABLE "public"."leads" ENABLE ROW LEVEL SECURITY;

-- vetra:passo 69 fase=expand lock=AccessExclusive custo=tabela_vazia
ALTER TABLE "public"."leads" FORCE ROW LEVEL SECURITY;

-- vetra:passo 70 fase=expand lock=AccessExclusive custo=tabela_vazia
CREATE POLICY "vt_tenant" ON "public"."leads" AS RESTRICTIVE FOR ALL TO "vetra_app" USING ("company_id" = (SELECT vetra.current_tenant())) WITH CHECK ("company_id" = (SELECT vetra.current_tenant()));

-- vetra:passo 71 fase=expand lock=AccessExclusive custo=tabela_vazia
CREATE POLICY "vt_scope_read" ON "public"."leads" AS PERMISSIVE FOR SELECT TO "vetra_app" USING ((EXISTS (SELECT 1 FROM "public"."memberships" AS "vt_scope_3" WHERE ("vt_scope_3"."company_id" = (SELECT vetra.current_tenant())) AND ("vt_scope_3"."dealer_id" = "leads"."dealer_id") AND (("vt_scope_3"."role" = E'gerente') AND ("vt_scope_3"."user_id" = (SELECT vetra.current_actor()))))) OR (EXISTS (SELECT 1 FROM "public"."memberships" AS "vt_scope_4" WHERE ("vt_scope_4"."company_id" = (SELECT vetra.current_tenant())) AND ("vt_scope_4"."dealer_id" = "leads"."dealer_id") AND (("vt_scope_4"."role" = E'vendedor') AND ("vt_scope_4"."user_id" = (SELECT vetra.current_actor()))))));

-- vetra:passo 72 fase=expand lock=AccessExclusive custo=tabela_vazia
CREATE POLICY "vt_scope_create" ON "public"."leads" AS PERMISSIVE FOR INSERT TO "vetra_app" WITH CHECK ((EXISTS (SELECT 1 FROM "public"."memberships" AS "vt_scope_5" WHERE ("vt_scope_5"."company_id" = (SELECT vetra.current_tenant())) AND ("vt_scope_5"."dealer_id" = "leads"."dealer_id") AND (("vt_scope_5"."role" = E'gerente') AND ("vt_scope_5"."user_id" = (SELECT vetra.current_actor()))))) OR (EXISTS (SELECT 1 FROM "public"."memberships" AS "vt_scope_6" WHERE ("vt_scope_6"."company_id" = (SELECT vetra.current_tenant())) AND ("vt_scope_6"."dealer_id" = "leads"."dealer_id") AND (("vt_scope_6"."role" = E'vendedor') AND ("vt_scope_6"."user_id" = (SELECT vetra.current_actor()))))));

-- vetra:passo 73 fase=expand lock=AccessExclusive custo=tabela_vazia
CREATE POLICY "vt_scope_update" ON "public"."leads" AS PERMISSIVE FOR UPDATE TO "vetra_app" USING ((EXISTS (SELECT 1 FROM "public"."memberships" AS "vt_scope_7" WHERE ("vt_scope_7"."company_id" = (SELECT vetra.current_tenant())) AND ("vt_scope_7"."dealer_id" = "leads"."dealer_id") AND (("vt_scope_7"."role" = E'gerente') AND ("vt_scope_7"."user_id" = (SELECT vetra.current_actor()))))) OR (EXISTS (SELECT 1 FROM "public"."memberships" AS "vt_scope_8" WHERE ("vt_scope_8"."company_id" = (SELECT vetra.current_tenant())) AND ("vt_scope_8"."dealer_id" = "leads"."dealer_id") AND (("vt_scope_8"."role" = E'vendedor') AND ("vt_scope_8"."user_id" = (SELECT vetra.current_actor())))))) WITH CHECK ((EXISTS (SELECT 1 FROM "public"."memberships" AS "vt_scope_7" WHERE ("vt_scope_7"."company_id" = (SELECT vetra.current_tenant())) AND ("vt_scope_7"."dealer_id" = "leads"."dealer_id") AND (("vt_scope_7"."role" = E'gerente') AND ("vt_scope_7"."user_id" = (SELECT vetra.current_actor()))))) OR (EXISTS (SELECT 1 FROM "public"."memberships" AS "vt_scope_8" WHERE ("vt_scope_8"."company_id" = (SELECT vetra.current_tenant())) AND ("vt_scope_8"."dealer_id" = "leads"."dealer_id") AND (("vt_scope_8"."role" = E'vendedor') AND ("vt_scope_8"."user_id" = (SELECT vetra.current_actor()))))));

-- vetra:passo 74 fase=expand lock=AccessExclusive custo=tabela_vazia
CREATE POLICY "vt_scope_delete" ON "public"."leads" AS PERMISSIVE FOR DELETE TO "vetra_app" USING ((EXISTS (SELECT 1 FROM "public"."memberships" AS "vt_scope_9" WHERE ("vt_scope_9"."company_id" = (SELECT vetra.current_tenant())) AND ("vt_scope_9"."dealer_id" = "leads"."dealer_id") AND (("vt_scope_9"."role" = E'gerente') AND ("vt_scope_9"."user_id" = (SELECT vetra.current_actor()))))));

-- vetra:passo 75 fase=expand lock=AccessExclusive custo=tabela_vazia
ALTER TABLE "public"."memberships" ENABLE ROW LEVEL SECURITY;

-- vetra:passo 76 fase=expand lock=AccessExclusive custo=tabela_vazia
ALTER TABLE "public"."memberships" FORCE ROW LEVEL SECURITY;

-- vetra:passo 77 fase=expand lock=AccessExclusive custo=tabela_vazia
CREATE POLICY "vt_tenant" ON "public"."memberships" AS RESTRICTIVE FOR ALL TO "vetra_app" USING ("company_id" = (SELECT vetra.current_tenant())) WITH CHECK ("company_id" = (SELECT vetra.current_tenant()));

-- vetra:passo 78 fase=expand lock=AccessExclusive custo=tabela_vazia
CREATE POLICY "vt_access" ON "public"."memberships" AS PERMISSIVE FOR ALL TO "vetra_app" USING (true) WITH CHECK (true);

-- vetra:passo 79 fase=expand lock=AccessExclusive custo=tabela_vazia
ALTER TABLE "public"."users" ENABLE ROW LEVEL SECURITY;

-- vetra:passo 80 fase=expand lock=AccessExclusive custo=tabela_vazia
ALTER TABLE "public"."users" FORCE ROW LEVEL SECURITY;

-- vetra:passo 81 fase=expand lock=AccessExclusive custo=tabela_vazia
CREATE POLICY "vt_tenant" ON "public"."users" AS RESTRICTIVE FOR ALL TO "vetra_app" USING ("company_id" = (SELECT vetra.current_tenant())) WITH CHECK ("company_id" = (SELECT vetra.current_tenant()));

-- vetra:passo 82 fase=expand lock=AccessExclusive custo=tabela_vazia
CREATE POLICY "vt_access" ON "public"."users" AS PERMISSIVE FOR ALL TO "vetra_app" USING (true) WITH CHECK (true);

-- vetra:passo 83 fase=expand lock=nenhum custo=catalogo
CREATE FUNCTION "vetra"."vt_transition_f11b74e8383ca04610952e448ddcd983"() RETURNS trigger LANGUAGE plpgsql SECURITY INVOKER
  SET search_path = pg_catalog, pg_temp AS $vetra_transition$
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
END $vetra_transition$;

-- vetra:passo 84 fase=expand lock=nenhum custo=catalogo
ALTER FUNCTION "vetra"."vt_transition_f11b74e8383ca04610952e448ddcd983"() OWNER TO "vetra_owner";

-- vetra:passo 85 fase=expand lock=nenhum custo=catalogo
REVOKE ALL ON FUNCTION "vetra"."vt_transition_f11b74e8383ca04610952e448ddcd983"() FROM PUBLIC, "vetra_app";

-- vetra:passo 86 fase=expand lock=ShareRowExclusive custo=tabela_vazia
CREATE TRIGGER "vt_transition_f11b74e8383ca04610952e448ddcd983" BEFORE INSERT OR UPDATE ON "public"."leads" FOR EACH ROW EXECUTE FUNCTION "vetra"."vt_transition_f11b74e8383ca04610952e448ddcd983"();

-- vetra:passo 87 fase=expand lock=ShareRowExclusive custo=tabela_vazia
ALTER TABLE "public"."leads" ENABLE ALWAYS TRIGGER "vt_transition_f11b74e8383ca04610952e448ddcd983";

-- vetra:passo 88 fase=expand lock=nenhum custo=catalogo
DO $vetra_roles$
BEGIN
  IF current_setting('server_version_num')::integer < 170000 THEN
    RAISE EXCEPTION 'Vetra exige PostgreSQL 17 ou superior';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'vetra_owner' AND NOT rolcanlogin AND NOT rolsuper AND NOT rolbypassrls AND NOT rolcreaterole) THEN
    RAISE EXCEPTION 'Proprietário deve existir, sem LOGIN, SUPERUSER, BYPASSRLS ou CREATEROLE';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'vetra_app' AND NOT rolsuper AND NOT rolbypassrls AND NOT rolcreaterole) THEN
    RAISE EXCEPTION 'Aplicação deve existir, sem SUPERUSER, BYPASSRLS ou CREATEROLE';
  END IF;
  IF pg_has_role('vetra_app', 'vetra_owner', 'MEMBER') THEN
    RAISE EXCEPTION 'Aplicação não pode pertencer ao papel proprietário';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_roles r WHERE pg_has_role('vetra_app', r.oid, 'SET') AND (r.rolsuper OR r.rolbypassrls OR r.rolcreaterole)) THEN
    RAISE EXCEPTION 'Aplicação não pode assumir por SET ROLE papel com SUPERUSER, BYPASSRLS ou CREATEROLE';
  END IF;
  -- Com ADMIN OPTION utilizável, a aplicação concederia a si própria um papel que hoje não pode assumir.
  -- Só conta o ADMIN utilizável: um vínculo INHERIT FALSE, SET FALSE não o empresta.
  IF EXISTS (SELECT 1 FROM pg_auth_members m WHERE m.admin_option AND EXISTS (SELECT 1 FROM pg_roles a WHERE pg_has_role('vetra_app', a.oid, 'SET') AND pg_has_role(a.oid, m.member, 'USAGE'))) THEN
    RAISE EXCEPTION 'Aplicação não pode administrar papéis (ADMIN OPTION) diretamente, por herança ou por SET ROLE';
  END IF;
  -- O aplicador da replicação lógica não dispara triggers por instrução, nem ENABLE ALWAYS.
  IF EXISTS (SELECT 1 FROM pg_roles a WHERE pg_has_role('vetra_app', a.oid, 'SET') AND pg_has_role(a.oid, 'pg_create_subscription'::regrole, 'USAGE'))
     OR EXISTS (SELECT 1 FROM pg_subscription s WHERE EXISTS (SELECT 1 FROM pg_roles a WHERE pg_has_role('vetra_app', a.oid, 'SET') AND pg_has_role(a.oid, s.subowner, 'USAGE'))) THEN
    RAISE EXCEPTION 'Aplicação não pode criar nem possuir subscriptions de replicação lógica';
  END IF;
  -- Executar programas ou ler e gravar arquivos do servidor contorna as permissões SQL.
  IF EXISTS (SELECT 1 FROM pg_roles p WHERE p.rolname IN ('pg_execute_server_program', 'pg_write_server_files', 'pg_read_server_files')
     AND EXISTS (SELECT 1 FROM pg_roles a WHERE pg_has_role('vetra_app', a.oid, 'SET') AND pg_has_role(a.oid, p.oid, 'USAGE'))) THEN
    RAISE EXCEPTION 'Aplicação não pode usar pg_execute_server_program, pg_write_server_files ou pg_read_server_files';
  END IF;
END $vetra_roles$;

-- vetra:passo 89 fase=expand lock=ShareRowExclusive custo=tabela_vazia
LOCK TABLE ONLY "public"."companies", ONLY "public"."dealers", ONLY "public"."leads", ONLY "public"."memberships", ONLY "public"."users" IN SHARE ROW EXCLUSIVE MODE;

-- vetra:passo 90 fase=expand lock=AccessShare custo=tabela_vazia
DO $vetra_tables$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_index i JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attname = 'id'
    WHERE i.indrelid = '"public"."companies"'::regclass AND i.indisprimary AND i.indnatts = 1 AND i.indkey[0] = a.attnum) THEN
    RAISE EXCEPTION 'Raiz do tenant deve ter chave primária simples em id';
  END IF;
IF NOT EXISTS (SELECT 1 FROM pg_class WHERE oid = '"public"."companies"'::regclass AND relkind = 'r' AND NOT relispartition)
   OR EXISTS (SELECT 1 FROM pg_inherits WHERE inhrelid = '"public"."companies"'::regclass OR inhparent = '"public"."companies"'::regclass) THEN
  RAISE EXCEPTION 'Tabelas particionadas ou herdadas não são suportadas: %', '"public"."companies"';
END IF;
IF NOT EXISTS (SELECT 1 FROM pg_attribute a JOIN pg_attribute root ON root.attrelid = '"public"."companies"'::regclass AND root.attname = 'id'
  WHERE a.attrelid = '"public"."companies"'::regclass AND a.attname = 'id' AND NOT a.attisdropped AND NOT root.attisdropped
    AND a.attnotnull AND root.attnotnull AND a.atttypid = root.atttypid AND a.atttypmod = root.atttypmod
    AND root.atttypid IN ('uuid'::regtype, 'text'::regtype, 'varchar'::regtype, 'bpchar'::regtype, 'int2'::regtype, 'int4'::regtype, 'int8'::regtype)) THEN
  RAISE EXCEPTION 'Coluna de tenant ausente, nula ou de tipo incompatível: %.%', '"public"."companies"', 'id';
END IF;
IF EXISTS (SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE c.oid = '"public"."companies"'::regclass
  AND (pg_has_role('vetra_app', c.relowner, 'MEMBER') OR pg_has_role('vetra_app', n.nspowner, 'MEMBER'))) THEN
  RAISE EXCEPTION 'Aplicação não pode possuir tabela protegida ou seu schema: %', '"public"."companies"';
END IF;
IF NOT EXISTS (SELECT 1 FROM pg_class WHERE oid = '"public"."dealers"'::regclass AND relkind = 'r' AND NOT relispartition)
   OR EXISTS (SELECT 1 FROM pg_inherits WHERE inhrelid = '"public"."dealers"'::regclass OR inhparent = '"public"."dealers"'::regclass) THEN
  RAISE EXCEPTION 'Tabelas particionadas ou herdadas não são suportadas: %', '"public"."dealers"';
END IF;
IF NOT EXISTS (SELECT 1 FROM pg_attribute a JOIN pg_attribute root ON root.attrelid = '"public"."companies"'::regclass AND root.attname = 'id'
  WHERE a.attrelid = '"public"."dealers"'::regclass AND a.attname = 'company_id' AND NOT a.attisdropped AND NOT root.attisdropped
    AND a.attnotnull AND root.attnotnull AND a.atttypid = root.atttypid AND a.atttypmod = root.atttypmod
    AND root.atttypid IN ('uuid'::regtype, 'text'::regtype, 'varchar'::regtype, 'bpchar'::regtype, 'int2'::regtype, 'int4'::regtype, 'int8'::regtype)) THEN
  RAISE EXCEPTION 'Coluna de tenant ausente, nula ou de tipo incompatível: %.%', '"public"."dealers"', 'company_id';
END IF;
IF EXISTS (SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE c.oid = '"public"."dealers"'::regclass
  AND (pg_has_role('vetra_app', c.relowner, 'MEMBER') OR pg_has_role('vetra_app', n.nspowner, 'MEMBER'))) THEN
  RAISE EXCEPTION 'Aplicação não pode possuir tabela protegida ou seu schema: %', '"public"."dealers"';
END IF;
IF NOT EXISTS (SELECT 1 FROM pg_class WHERE oid = '"public"."leads"'::regclass AND relkind = 'r' AND NOT relispartition)
   OR EXISTS (SELECT 1 FROM pg_inherits WHERE inhrelid = '"public"."leads"'::regclass OR inhparent = '"public"."leads"'::regclass) THEN
  RAISE EXCEPTION 'Tabelas particionadas ou herdadas não são suportadas: %', '"public"."leads"';
END IF;
IF NOT EXISTS (SELECT 1 FROM pg_attribute a JOIN pg_attribute root ON root.attrelid = '"public"."companies"'::regclass AND root.attname = 'id'
  WHERE a.attrelid = '"public"."leads"'::regclass AND a.attname = 'company_id' AND NOT a.attisdropped AND NOT root.attisdropped
    AND a.attnotnull AND root.attnotnull AND a.atttypid = root.atttypid AND a.atttypmod = root.atttypmod
    AND root.atttypid IN ('uuid'::regtype, 'text'::regtype, 'varchar'::regtype, 'bpchar'::regtype, 'int2'::regtype, 'int4'::regtype, 'int8'::regtype)) THEN
  RAISE EXCEPTION 'Coluna de tenant ausente, nula ou de tipo incompatível: %.%', '"public"."leads"', 'company_id';
END IF;
IF EXISTS (SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE c.oid = '"public"."leads"'::regclass
  AND (pg_has_role('vetra_app', c.relowner, 'MEMBER') OR pg_has_role('vetra_app', n.nspowner, 'MEMBER'))) THEN
  RAISE EXCEPTION 'Aplicação não pode possuir tabela protegida ou seu schema: %', '"public"."leads"';
END IF;
IF NOT EXISTS (SELECT 1 FROM pg_class WHERE oid = '"public"."memberships"'::regclass AND relkind = 'r' AND NOT relispartition)
   OR EXISTS (SELECT 1 FROM pg_inherits WHERE inhrelid = '"public"."memberships"'::regclass OR inhparent = '"public"."memberships"'::regclass) THEN
  RAISE EXCEPTION 'Tabelas particionadas ou herdadas não são suportadas: %', '"public"."memberships"';
END IF;
IF NOT EXISTS (SELECT 1 FROM pg_attribute a JOIN pg_attribute root ON root.attrelid = '"public"."companies"'::regclass AND root.attname = 'id'
  WHERE a.attrelid = '"public"."memberships"'::regclass AND a.attname = 'company_id' AND NOT a.attisdropped AND NOT root.attisdropped
    AND a.attnotnull AND root.attnotnull AND a.atttypid = root.atttypid AND a.atttypmod = root.atttypmod
    AND root.atttypid IN ('uuid'::regtype, 'text'::regtype, 'varchar'::regtype, 'bpchar'::regtype, 'int2'::regtype, 'int4'::regtype, 'int8'::regtype)) THEN
  RAISE EXCEPTION 'Coluna de tenant ausente, nula ou de tipo incompatível: %.%', '"public"."memberships"', 'company_id';
END IF;
IF EXISTS (SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE c.oid = '"public"."memberships"'::regclass
  AND (pg_has_role('vetra_app', c.relowner, 'MEMBER') OR pg_has_role('vetra_app', n.nspowner, 'MEMBER'))) THEN
  RAISE EXCEPTION 'Aplicação não pode possuir tabela protegida ou seu schema: %', '"public"."memberships"';
END IF;
IF NOT EXISTS (SELECT 1 FROM pg_class WHERE oid = '"public"."users"'::regclass AND relkind = 'r' AND NOT relispartition)
   OR EXISTS (SELECT 1 FROM pg_inherits WHERE inhrelid = '"public"."users"'::regclass OR inhparent = '"public"."users"'::regclass) THEN
  RAISE EXCEPTION 'Tabelas particionadas ou herdadas não são suportadas: %', '"public"."users"';
END IF;
IF NOT EXISTS (SELECT 1 FROM pg_attribute a JOIN pg_attribute root ON root.attrelid = '"public"."companies"'::regclass AND root.attname = 'id'
  WHERE a.attrelid = '"public"."users"'::regclass AND a.attname = 'company_id' AND NOT a.attisdropped AND NOT root.attisdropped
    AND a.attnotnull AND root.attnotnull AND a.atttypid = root.atttypid AND a.atttypmod = root.atttypmod
    AND root.atttypid IN ('uuid'::regtype, 'text'::regtype, 'varchar'::regtype, 'bpchar'::regtype, 'int2'::regtype, 'int4'::regtype, 'int8'::regtype)) THEN
  RAISE EXCEPTION 'Coluna de tenant ausente, nula ou de tipo incompatível: %.%', '"public"."users"', 'company_id';
END IF;
IF EXISTS (SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE c.oid = '"public"."users"'::regclass
  AND (pg_has_role('vetra_app', c.relowner, 'MEMBER') OR pg_has_role('vetra_app', n.nspowner, 'MEMBER'))) THEN
  RAISE EXCEPTION 'Aplicação não pode possuir tabela protegida ou seu schema: %', '"public"."users"';
END IF;

END $vetra_tables$;

-- vetra:passo 91 fase=expand lock=nenhum custo=catalogo
DO $vetra_shared_schema$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'vetra') THEN
    IF NOT EXISTS (SELECT 1 FROM pg_namespace n JOIN pg_roles r ON r.oid = n.nspowner
      WHERE n.nspname = 'vetra' AND r.rolname = 'vetra_owner') THEN
      RAISE EXCEPTION 'Schema vetra existente deve pertencer a vetra_owner';
    END IF;
  ELSE
    CREATE SCHEMA "vetra" AUTHORIZATION "vetra_owner";
  END IF;
END $vetra_shared_schema$;

-- vetra:passo 92 fase=expand lock=nenhum custo=catalogo
CREATE TABLE "vetra"."authz_revisions" (tenant_id text PRIMARY KEY, revision bigint NOT NULL CHECK (revision >= 0));

-- vetra:passo 93 fase=expand lock=AccessExclusive custo=tabela_vazia
ALTER TABLE "vetra"."authz_revisions" OWNER TO "vetra_owner";

-- vetra:passo 94 fase=expand lock=nenhum custo=catalogo
REVOKE ALL ON "vetra"."authz_revisions" FROM PUBLIC, "vetra_app";

-- vetra:passo 95 fase=expand lock=nenhum custo=catalogo
GRANT USAGE ON SCHEMA "vetra" TO "vetra_app";

-- vetra:passo 96 fase=expand lock=nenhum custo=catalogo
GRANT SELECT ON "vetra"."authz_revisions" TO "vetra_app";

-- vetra:passo 97 fase=expand lock=nenhum custo=catalogo
CREATE FUNCTION "vetra"."vt_authz_5aab7bffb3a1c59035452764_insert"() RETURNS trigger LANGUAGE plpgsql
  SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $vetra_authz$
DECLARE affected_tenant text;
BEGIN
  FOR affected_tenant IN SELECT DISTINCT "id"::text AS tenant_id FROM vt_new ORDER BY tenant_id LOOP
    INSERT INTO "vetra"."authz_revisions" AS stored (tenant_id, revision) VALUES (affected_tenant, 1)
      ON CONFLICT (tenant_id) DO UPDATE SET revision = stored.revision + 1;
    PERFORM pg_notify('vetra_authz', affected_tenant);
  END LOOP;
  RETURN NULL;
END $vetra_authz$;

-- vetra:passo 98 fase=expand lock=nenhum custo=catalogo
ALTER FUNCTION "vetra"."vt_authz_5aab7bffb3a1c59035452764_insert"() OWNER TO "vetra_owner";

-- vetra:passo 99 fase=expand lock=nenhum custo=catalogo
REVOKE ALL ON FUNCTION "vetra"."vt_authz_5aab7bffb3a1c59035452764_insert"() FROM PUBLIC, "vetra_app";

-- vetra:passo 100 fase=expand lock=ShareRowExclusive custo=tabela_vazia
CREATE TRIGGER "vt_authz_5aab7bffb3a1c59035452764_insert" AFTER INSERT ON "public"."companies"
  REFERENCING NEW TABLE AS vt_new FOR EACH STATEMENT EXECUTE FUNCTION "vetra"."vt_authz_5aab7bffb3a1c59035452764_insert"();

-- vetra:passo 101 fase=expand lock=ShareRowExclusive custo=tabela_vazia
ALTER TABLE "public"."companies" ENABLE ALWAYS TRIGGER "vt_authz_5aab7bffb3a1c59035452764_insert";

-- vetra:passo 102 fase=expand lock=nenhum custo=catalogo
CREATE FUNCTION "vetra"."vt_authz_5aab7bffb3a1c59035452764_delete"() RETURNS trigger LANGUAGE plpgsql
  SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $vetra_authz$
DECLARE affected_tenant text;
BEGIN
  FOR affected_tenant IN SELECT DISTINCT "id"::text AS tenant_id FROM vt_old ORDER BY tenant_id LOOP
    INSERT INTO "vetra"."authz_revisions" AS stored (tenant_id, revision) VALUES (affected_tenant, 1)
      ON CONFLICT (tenant_id) DO UPDATE SET revision = stored.revision + 1;
    PERFORM pg_notify('vetra_authz', affected_tenant);
  END LOOP;
  RETURN NULL;
END $vetra_authz$;

-- vetra:passo 103 fase=expand lock=nenhum custo=catalogo
ALTER FUNCTION "vetra"."vt_authz_5aab7bffb3a1c59035452764_delete"() OWNER TO "vetra_owner";

-- vetra:passo 104 fase=expand lock=nenhum custo=catalogo
REVOKE ALL ON FUNCTION "vetra"."vt_authz_5aab7bffb3a1c59035452764_delete"() FROM PUBLIC, "vetra_app";

-- vetra:passo 105 fase=expand lock=ShareRowExclusive custo=tabela_vazia
CREATE TRIGGER "vt_authz_5aab7bffb3a1c59035452764_delete" AFTER DELETE ON "public"."companies"
  REFERENCING OLD TABLE AS vt_old FOR EACH STATEMENT EXECUTE FUNCTION "vetra"."vt_authz_5aab7bffb3a1c59035452764_delete"();

-- vetra:passo 106 fase=expand lock=ShareRowExclusive custo=tabela_vazia
ALTER TABLE "public"."companies" ENABLE ALWAYS TRIGGER "vt_authz_5aab7bffb3a1c59035452764_delete";

-- vetra:passo 107 fase=expand lock=nenhum custo=catalogo
CREATE FUNCTION "vetra"."vt_authz_5aab7bffb3a1c59035452764_update"() RETURNS trigger LANGUAGE plpgsql
  SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $vetra_authz$
DECLARE affected_tenant text;
BEGIN
  FOR affected_tenant IN SELECT "id"::text AS tenant_id FROM vt_old UNION SELECT "id"::text AS tenant_id FROM vt_new ORDER BY tenant_id LOOP
    INSERT INTO "vetra"."authz_revisions" AS stored (tenant_id, revision) VALUES (affected_tenant, 1)
      ON CONFLICT (tenant_id) DO UPDATE SET revision = stored.revision + 1;
    PERFORM pg_notify('vetra_authz', affected_tenant);
  END LOOP;
  RETURN NULL;
END $vetra_authz$;

-- vetra:passo 108 fase=expand lock=nenhum custo=catalogo
ALTER FUNCTION "vetra"."vt_authz_5aab7bffb3a1c59035452764_update"() OWNER TO "vetra_owner";

-- vetra:passo 109 fase=expand lock=nenhum custo=catalogo
REVOKE ALL ON FUNCTION "vetra"."vt_authz_5aab7bffb3a1c59035452764_update"() FROM PUBLIC, "vetra_app";

-- vetra:passo 110 fase=expand lock=ShareRowExclusive custo=tabela_vazia
CREATE TRIGGER "vt_authz_5aab7bffb3a1c59035452764_update" AFTER UPDATE ON "public"."companies"
  REFERENCING OLD TABLE AS vt_old NEW TABLE AS vt_new FOR EACH STATEMENT EXECUTE FUNCTION "vetra"."vt_authz_5aab7bffb3a1c59035452764_update"();

-- vetra:passo 111 fase=expand lock=ShareRowExclusive custo=tabela_vazia
ALTER TABLE "public"."companies" ENABLE ALWAYS TRIGGER "vt_authz_5aab7bffb3a1c59035452764_update";

-- vetra:passo 112 fase=expand lock=nenhum custo=catalogo
REVOKE TRUNCATE, TRIGGER, REFERENCES ON "public"."companies" FROM PUBLIC, "vetra_app";

-- vetra:passo 113 fase=expand lock=nenhum custo=catalogo
CREATE FUNCTION "vetra"."vt_authz_86073356dc99948c9f46bbfd_insert"() RETURNS trigger LANGUAGE plpgsql
  SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $vetra_authz$
DECLARE affected_tenant text;
BEGIN
  FOR affected_tenant IN SELECT DISTINCT "company_id"::text AS tenant_id FROM vt_new ORDER BY tenant_id LOOP
    INSERT INTO "vetra"."authz_revisions" AS stored (tenant_id, revision) VALUES (affected_tenant, 1)
      ON CONFLICT (tenant_id) DO UPDATE SET revision = stored.revision + 1;
    PERFORM pg_notify('vetra_authz', affected_tenant);
  END LOOP;
  RETURN NULL;
END $vetra_authz$;

-- vetra:passo 114 fase=expand lock=nenhum custo=catalogo
ALTER FUNCTION "vetra"."vt_authz_86073356dc99948c9f46bbfd_insert"() OWNER TO "vetra_owner";

-- vetra:passo 115 fase=expand lock=nenhum custo=catalogo
REVOKE ALL ON FUNCTION "vetra"."vt_authz_86073356dc99948c9f46bbfd_insert"() FROM PUBLIC, "vetra_app";

-- vetra:passo 116 fase=expand lock=ShareRowExclusive custo=tabela_vazia
CREATE TRIGGER "vt_authz_86073356dc99948c9f46bbfd_insert" AFTER INSERT ON "public"."dealers"
  REFERENCING NEW TABLE AS vt_new FOR EACH STATEMENT EXECUTE FUNCTION "vetra"."vt_authz_86073356dc99948c9f46bbfd_insert"();

-- vetra:passo 117 fase=expand lock=ShareRowExclusive custo=tabela_vazia
ALTER TABLE "public"."dealers" ENABLE ALWAYS TRIGGER "vt_authz_86073356dc99948c9f46bbfd_insert";

-- vetra:passo 118 fase=expand lock=nenhum custo=catalogo
CREATE FUNCTION "vetra"."vt_authz_86073356dc99948c9f46bbfd_delete"() RETURNS trigger LANGUAGE plpgsql
  SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $vetra_authz$
DECLARE affected_tenant text;
BEGIN
  FOR affected_tenant IN SELECT DISTINCT "company_id"::text AS tenant_id FROM vt_old ORDER BY tenant_id LOOP
    INSERT INTO "vetra"."authz_revisions" AS stored (tenant_id, revision) VALUES (affected_tenant, 1)
      ON CONFLICT (tenant_id) DO UPDATE SET revision = stored.revision + 1;
    PERFORM pg_notify('vetra_authz', affected_tenant);
  END LOOP;
  RETURN NULL;
END $vetra_authz$;

-- vetra:passo 119 fase=expand lock=nenhum custo=catalogo
ALTER FUNCTION "vetra"."vt_authz_86073356dc99948c9f46bbfd_delete"() OWNER TO "vetra_owner";

-- vetra:passo 120 fase=expand lock=nenhum custo=catalogo
REVOKE ALL ON FUNCTION "vetra"."vt_authz_86073356dc99948c9f46bbfd_delete"() FROM PUBLIC, "vetra_app";

-- vetra:passo 121 fase=expand lock=ShareRowExclusive custo=tabela_vazia
CREATE TRIGGER "vt_authz_86073356dc99948c9f46bbfd_delete" AFTER DELETE ON "public"."dealers"
  REFERENCING OLD TABLE AS vt_old FOR EACH STATEMENT EXECUTE FUNCTION "vetra"."vt_authz_86073356dc99948c9f46bbfd_delete"();

-- vetra:passo 122 fase=expand lock=ShareRowExclusive custo=tabela_vazia
ALTER TABLE "public"."dealers" ENABLE ALWAYS TRIGGER "vt_authz_86073356dc99948c9f46bbfd_delete";

-- vetra:passo 123 fase=expand lock=nenhum custo=catalogo
CREATE FUNCTION "vetra"."vt_authz_86073356dc99948c9f46bbfd_update"() RETURNS trigger LANGUAGE plpgsql
  SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $vetra_authz$
DECLARE affected_tenant text;
BEGIN
  FOR affected_tenant IN SELECT "company_id"::text AS tenant_id FROM vt_old UNION SELECT "company_id"::text AS tenant_id FROM vt_new ORDER BY tenant_id LOOP
    INSERT INTO "vetra"."authz_revisions" AS stored (tenant_id, revision) VALUES (affected_tenant, 1)
      ON CONFLICT (tenant_id) DO UPDATE SET revision = stored.revision + 1;
    PERFORM pg_notify('vetra_authz', affected_tenant);
  END LOOP;
  RETURN NULL;
END $vetra_authz$;

-- vetra:passo 124 fase=expand lock=nenhum custo=catalogo
ALTER FUNCTION "vetra"."vt_authz_86073356dc99948c9f46bbfd_update"() OWNER TO "vetra_owner";

-- vetra:passo 125 fase=expand lock=nenhum custo=catalogo
REVOKE ALL ON FUNCTION "vetra"."vt_authz_86073356dc99948c9f46bbfd_update"() FROM PUBLIC, "vetra_app";

-- vetra:passo 126 fase=expand lock=ShareRowExclusive custo=tabela_vazia
CREATE TRIGGER "vt_authz_86073356dc99948c9f46bbfd_update" AFTER UPDATE ON "public"."dealers"
  REFERENCING OLD TABLE AS vt_old NEW TABLE AS vt_new FOR EACH STATEMENT EXECUTE FUNCTION "vetra"."vt_authz_86073356dc99948c9f46bbfd_update"();

-- vetra:passo 127 fase=expand lock=ShareRowExclusive custo=tabela_vazia
ALTER TABLE "public"."dealers" ENABLE ALWAYS TRIGGER "vt_authz_86073356dc99948c9f46bbfd_update";

-- vetra:passo 128 fase=expand lock=nenhum custo=catalogo
REVOKE TRUNCATE, TRIGGER, REFERENCES ON "public"."dealers" FROM PUBLIC, "vetra_app";

-- vetra:passo 129 fase=expand lock=nenhum custo=catalogo
CREATE FUNCTION "vetra"."vt_authz_7bf2063f1fe867c04fa2ed84_insert"() RETURNS trigger LANGUAGE plpgsql
  SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $vetra_authz$
DECLARE affected_tenant text;
BEGIN
  FOR affected_tenant IN SELECT DISTINCT "company_id"::text AS tenant_id FROM vt_new ORDER BY tenant_id LOOP
    INSERT INTO "vetra"."authz_revisions" AS stored (tenant_id, revision) VALUES (affected_tenant, 1)
      ON CONFLICT (tenant_id) DO UPDATE SET revision = stored.revision + 1;
    PERFORM pg_notify('vetra_authz', affected_tenant);
  END LOOP;
  RETURN NULL;
END $vetra_authz$;

-- vetra:passo 130 fase=expand lock=nenhum custo=catalogo
ALTER FUNCTION "vetra"."vt_authz_7bf2063f1fe867c04fa2ed84_insert"() OWNER TO "vetra_owner";

-- vetra:passo 131 fase=expand lock=nenhum custo=catalogo
REVOKE ALL ON FUNCTION "vetra"."vt_authz_7bf2063f1fe867c04fa2ed84_insert"() FROM PUBLIC, "vetra_app";

-- vetra:passo 132 fase=expand lock=ShareRowExclusive custo=tabela_vazia
CREATE TRIGGER "vt_authz_7bf2063f1fe867c04fa2ed84_insert" AFTER INSERT ON "public"."leads"
  REFERENCING NEW TABLE AS vt_new FOR EACH STATEMENT EXECUTE FUNCTION "vetra"."vt_authz_7bf2063f1fe867c04fa2ed84_insert"();

-- vetra:passo 133 fase=expand lock=ShareRowExclusive custo=tabela_vazia
ALTER TABLE "public"."leads" ENABLE ALWAYS TRIGGER "vt_authz_7bf2063f1fe867c04fa2ed84_insert";

-- vetra:passo 134 fase=expand lock=nenhum custo=catalogo
CREATE FUNCTION "vetra"."vt_authz_7bf2063f1fe867c04fa2ed84_delete"() RETURNS trigger LANGUAGE plpgsql
  SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $vetra_authz$
DECLARE affected_tenant text;
BEGIN
  FOR affected_tenant IN SELECT DISTINCT "company_id"::text AS tenant_id FROM vt_old ORDER BY tenant_id LOOP
    INSERT INTO "vetra"."authz_revisions" AS stored (tenant_id, revision) VALUES (affected_tenant, 1)
      ON CONFLICT (tenant_id) DO UPDATE SET revision = stored.revision + 1;
    PERFORM pg_notify('vetra_authz', affected_tenant);
  END LOOP;
  RETURN NULL;
END $vetra_authz$;

-- vetra:passo 135 fase=expand lock=nenhum custo=catalogo
ALTER FUNCTION "vetra"."vt_authz_7bf2063f1fe867c04fa2ed84_delete"() OWNER TO "vetra_owner";

-- vetra:passo 136 fase=expand lock=nenhum custo=catalogo
REVOKE ALL ON FUNCTION "vetra"."vt_authz_7bf2063f1fe867c04fa2ed84_delete"() FROM PUBLIC, "vetra_app";

-- vetra:passo 137 fase=expand lock=ShareRowExclusive custo=tabela_vazia
CREATE TRIGGER "vt_authz_7bf2063f1fe867c04fa2ed84_delete" AFTER DELETE ON "public"."leads"
  REFERENCING OLD TABLE AS vt_old FOR EACH STATEMENT EXECUTE FUNCTION "vetra"."vt_authz_7bf2063f1fe867c04fa2ed84_delete"();

-- vetra:passo 138 fase=expand lock=ShareRowExclusive custo=tabela_vazia
ALTER TABLE "public"."leads" ENABLE ALWAYS TRIGGER "vt_authz_7bf2063f1fe867c04fa2ed84_delete";

-- vetra:passo 139 fase=expand lock=nenhum custo=catalogo
CREATE FUNCTION "vetra"."vt_authz_7bf2063f1fe867c04fa2ed84_update"() RETURNS trigger LANGUAGE plpgsql
  SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $vetra_authz$
DECLARE affected_tenant text;
BEGIN
  FOR affected_tenant IN SELECT "company_id"::text AS tenant_id FROM vt_old UNION SELECT "company_id"::text AS tenant_id FROM vt_new ORDER BY tenant_id LOOP
    INSERT INTO "vetra"."authz_revisions" AS stored (tenant_id, revision) VALUES (affected_tenant, 1)
      ON CONFLICT (tenant_id) DO UPDATE SET revision = stored.revision + 1;
    PERFORM pg_notify('vetra_authz', affected_tenant);
  END LOOP;
  RETURN NULL;
END $vetra_authz$;

-- vetra:passo 140 fase=expand lock=nenhum custo=catalogo
ALTER FUNCTION "vetra"."vt_authz_7bf2063f1fe867c04fa2ed84_update"() OWNER TO "vetra_owner";

-- vetra:passo 141 fase=expand lock=nenhum custo=catalogo
REVOKE ALL ON FUNCTION "vetra"."vt_authz_7bf2063f1fe867c04fa2ed84_update"() FROM PUBLIC, "vetra_app";

-- vetra:passo 142 fase=expand lock=ShareRowExclusive custo=tabela_vazia
CREATE TRIGGER "vt_authz_7bf2063f1fe867c04fa2ed84_update" AFTER UPDATE ON "public"."leads"
  REFERENCING OLD TABLE AS vt_old NEW TABLE AS vt_new FOR EACH STATEMENT EXECUTE FUNCTION "vetra"."vt_authz_7bf2063f1fe867c04fa2ed84_update"();

-- vetra:passo 143 fase=expand lock=ShareRowExclusive custo=tabela_vazia
ALTER TABLE "public"."leads" ENABLE ALWAYS TRIGGER "vt_authz_7bf2063f1fe867c04fa2ed84_update";

-- vetra:passo 144 fase=expand lock=nenhum custo=catalogo
REVOKE TRUNCATE, TRIGGER, REFERENCES ON "public"."leads" FROM PUBLIC, "vetra_app";

-- vetra:passo 145 fase=expand lock=nenhum custo=catalogo
CREATE FUNCTION "vetra"."vt_authz_d19ed6c10293be4bf7dd9b93_insert"() RETURNS trigger LANGUAGE plpgsql
  SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $vetra_authz$
DECLARE affected_tenant text;
BEGIN
  FOR affected_tenant IN SELECT DISTINCT "company_id"::text AS tenant_id FROM vt_new ORDER BY tenant_id LOOP
    INSERT INTO "vetra"."authz_revisions" AS stored (tenant_id, revision) VALUES (affected_tenant, 1)
      ON CONFLICT (tenant_id) DO UPDATE SET revision = stored.revision + 1;
    PERFORM pg_notify('vetra_authz', affected_tenant);
  END LOOP;
  RETURN NULL;
END $vetra_authz$;

-- vetra:passo 146 fase=expand lock=nenhum custo=catalogo
ALTER FUNCTION "vetra"."vt_authz_d19ed6c10293be4bf7dd9b93_insert"() OWNER TO "vetra_owner";

-- vetra:passo 147 fase=expand lock=nenhum custo=catalogo
REVOKE ALL ON FUNCTION "vetra"."vt_authz_d19ed6c10293be4bf7dd9b93_insert"() FROM PUBLIC, "vetra_app";

-- vetra:passo 148 fase=expand lock=ShareRowExclusive custo=tabela_vazia
CREATE TRIGGER "vt_authz_d19ed6c10293be4bf7dd9b93_insert" AFTER INSERT ON "public"."memberships"
  REFERENCING NEW TABLE AS vt_new FOR EACH STATEMENT EXECUTE FUNCTION "vetra"."vt_authz_d19ed6c10293be4bf7dd9b93_insert"();

-- vetra:passo 149 fase=expand lock=ShareRowExclusive custo=tabela_vazia
ALTER TABLE "public"."memberships" ENABLE ALWAYS TRIGGER "vt_authz_d19ed6c10293be4bf7dd9b93_insert";

-- vetra:passo 150 fase=expand lock=nenhum custo=catalogo
CREATE FUNCTION "vetra"."vt_authz_d19ed6c10293be4bf7dd9b93_delete"() RETURNS trigger LANGUAGE plpgsql
  SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $vetra_authz$
DECLARE affected_tenant text;
BEGIN
  FOR affected_tenant IN SELECT DISTINCT "company_id"::text AS tenant_id FROM vt_old ORDER BY tenant_id LOOP
    INSERT INTO "vetra"."authz_revisions" AS stored (tenant_id, revision) VALUES (affected_tenant, 1)
      ON CONFLICT (tenant_id) DO UPDATE SET revision = stored.revision + 1;
    PERFORM pg_notify('vetra_authz', affected_tenant);
  END LOOP;
  RETURN NULL;
END $vetra_authz$;

-- vetra:passo 151 fase=expand lock=nenhum custo=catalogo
ALTER FUNCTION "vetra"."vt_authz_d19ed6c10293be4bf7dd9b93_delete"() OWNER TO "vetra_owner";

-- vetra:passo 152 fase=expand lock=nenhum custo=catalogo
REVOKE ALL ON FUNCTION "vetra"."vt_authz_d19ed6c10293be4bf7dd9b93_delete"() FROM PUBLIC, "vetra_app";

-- vetra:passo 153 fase=expand lock=ShareRowExclusive custo=tabela_vazia
CREATE TRIGGER "vt_authz_d19ed6c10293be4bf7dd9b93_delete" AFTER DELETE ON "public"."memberships"
  REFERENCING OLD TABLE AS vt_old FOR EACH STATEMENT EXECUTE FUNCTION "vetra"."vt_authz_d19ed6c10293be4bf7dd9b93_delete"();

-- vetra:passo 154 fase=expand lock=ShareRowExclusive custo=tabela_vazia
ALTER TABLE "public"."memberships" ENABLE ALWAYS TRIGGER "vt_authz_d19ed6c10293be4bf7dd9b93_delete";

-- vetra:passo 155 fase=expand lock=nenhum custo=catalogo
CREATE FUNCTION "vetra"."vt_authz_d19ed6c10293be4bf7dd9b93_update"() RETURNS trigger LANGUAGE plpgsql
  SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $vetra_authz$
DECLARE affected_tenant text;
BEGIN
  FOR affected_tenant IN SELECT "company_id"::text AS tenant_id FROM vt_old UNION SELECT "company_id"::text AS tenant_id FROM vt_new ORDER BY tenant_id LOOP
    INSERT INTO "vetra"."authz_revisions" AS stored (tenant_id, revision) VALUES (affected_tenant, 1)
      ON CONFLICT (tenant_id) DO UPDATE SET revision = stored.revision + 1;
    PERFORM pg_notify('vetra_authz', affected_tenant);
  END LOOP;
  RETURN NULL;
END $vetra_authz$;

-- vetra:passo 156 fase=expand lock=nenhum custo=catalogo
ALTER FUNCTION "vetra"."vt_authz_d19ed6c10293be4bf7dd9b93_update"() OWNER TO "vetra_owner";

-- vetra:passo 157 fase=expand lock=nenhum custo=catalogo
REVOKE ALL ON FUNCTION "vetra"."vt_authz_d19ed6c10293be4bf7dd9b93_update"() FROM PUBLIC, "vetra_app";

-- vetra:passo 158 fase=expand lock=ShareRowExclusive custo=tabela_vazia
CREATE TRIGGER "vt_authz_d19ed6c10293be4bf7dd9b93_update" AFTER UPDATE ON "public"."memberships"
  REFERENCING OLD TABLE AS vt_old NEW TABLE AS vt_new FOR EACH STATEMENT EXECUTE FUNCTION "vetra"."vt_authz_d19ed6c10293be4bf7dd9b93_update"();

-- vetra:passo 159 fase=expand lock=ShareRowExclusive custo=tabela_vazia
ALTER TABLE "public"."memberships" ENABLE ALWAYS TRIGGER "vt_authz_d19ed6c10293be4bf7dd9b93_update";

-- vetra:passo 160 fase=expand lock=nenhum custo=catalogo
REVOKE TRUNCATE, TRIGGER, REFERENCES ON "public"."memberships" FROM PUBLIC, "vetra_app";

-- vetra:passo 161 fase=expand lock=nenhum custo=catalogo
CREATE FUNCTION "vetra"."vt_authz_01e3b579ef1811b6be2c64ee_insert"() RETURNS trigger LANGUAGE plpgsql
  SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $vetra_authz$
DECLARE affected_tenant text;
BEGIN
  FOR affected_tenant IN SELECT DISTINCT "company_id"::text AS tenant_id FROM vt_new ORDER BY tenant_id LOOP
    INSERT INTO "vetra"."authz_revisions" AS stored (tenant_id, revision) VALUES (affected_tenant, 1)
      ON CONFLICT (tenant_id) DO UPDATE SET revision = stored.revision + 1;
    PERFORM pg_notify('vetra_authz', affected_tenant);
  END LOOP;
  RETURN NULL;
END $vetra_authz$;

-- vetra:passo 162 fase=expand lock=nenhum custo=catalogo
ALTER FUNCTION "vetra"."vt_authz_01e3b579ef1811b6be2c64ee_insert"() OWNER TO "vetra_owner";

-- vetra:passo 163 fase=expand lock=nenhum custo=catalogo
REVOKE ALL ON FUNCTION "vetra"."vt_authz_01e3b579ef1811b6be2c64ee_insert"() FROM PUBLIC, "vetra_app";

-- vetra:passo 164 fase=expand lock=ShareRowExclusive custo=tabela_vazia
CREATE TRIGGER "vt_authz_01e3b579ef1811b6be2c64ee_insert" AFTER INSERT ON "public"."users"
  REFERENCING NEW TABLE AS vt_new FOR EACH STATEMENT EXECUTE FUNCTION "vetra"."vt_authz_01e3b579ef1811b6be2c64ee_insert"();

-- vetra:passo 165 fase=expand lock=ShareRowExclusive custo=tabela_vazia
ALTER TABLE "public"."users" ENABLE ALWAYS TRIGGER "vt_authz_01e3b579ef1811b6be2c64ee_insert";

-- vetra:passo 166 fase=expand lock=nenhum custo=catalogo
CREATE FUNCTION "vetra"."vt_authz_01e3b579ef1811b6be2c64ee_delete"() RETURNS trigger LANGUAGE plpgsql
  SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $vetra_authz$
DECLARE affected_tenant text;
BEGIN
  FOR affected_tenant IN SELECT DISTINCT "company_id"::text AS tenant_id FROM vt_old ORDER BY tenant_id LOOP
    INSERT INTO "vetra"."authz_revisions" AS stored (tenant_id, revision) VALUES (affected_tenant, 1)
      ON CONFLICT (tenant_id) DO UPDATE SET revision = stored.revision + 1;
    PERFORM pg_notify('vetra_authz', affected_tenant);
  END LOOP;
  RETURN NULL;
END $vetra_authz$;

-- vetra:passo 167 fase=expand lock=nenhum custo=catalogo
ALTER FUNCTION "vetra"."vt_authz_01e3b579ef1811b6be2c64ee_delete"() OWNER TO "vetra_owner";

-- vetra:passo 168 fase=expand lock=nenhum custo=catalogo
REVOKE ALL ON FUNCTION "vetra"."vt_authz_01e3b579ef1811b6be2c64ee_delete"() FROM PUBLIC, "vetra_app";

-- vetra:passo 169 fase=expand lock=ShareRowExclusive custo=tabela_vazia
CREATE TRIGGER "vt_authz_01e3b579ef1811b6be2c64ee_delete" AFTER DELETE ON "public"."users"
  REFERENCING OLD TABLE AS vt_old FOR EACH STATEMENT EXECUTE FUNCTION "vetra"."vt_authz_01e3b579ef1811b6be2c64ee_delete"();

-- vetra:passo 170 fase=expand lock=ShareRowExclusive custo=tabela_vazia
ALTER TABLE "public"."users" ENABLE ALWAYS TRIGGER "vt_authz_01e3b579ef1811b6be2c64ee_delete";

-- vetra:passo 171 fase=expand lock=nenhum custo=catalogo
CREATE FUNCTION "vetra"."vt_authz_01e3b579ef1811b6be2c64ee_update"() RETURNS trigger LANGUAGE plpgsql
  SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $vetra_authz$
DECLARE affected_tenant text;
BEGIN
  FOR affected_tenant IN SELECT "company_id"::text AS tenant_id FROM vt_old UNION SELECT "company_id"::text AS tenant_id FROM vt_new ORDER BY tenant_id LOOP
    INSERT INTO "vetra"."authz_revisions" AS stored (tenant_id, revision) VALUES (affected_tenant, 1)
      ON CONFLICT (tenant_id) DO UPDATE SET revision = stored.revision + 1;
    PERFORM pg_notify('vetra_authz', affected_tenant);
  END LOOP;
  RETURN NULL;
END $vetra_authz$;

-- vetra:passo 172 fase=expand lock=nenhum custo=catalogo
ALTER FUNCTION "vetra"."vt_authz_01e3b579ef1811b6be2c64ee_update"() OWNER TO "vetra_owner";

-- vetra:passo 173 fase=expand lock=nenhum custo=catalogo
REVOKE ALL ON FUNCTION "vetra"."vt_authz_01e3b579ef1811b6be2c64ee_update"() FROM PUBLIC, "vetra_app";

-- vetra:passo 174 fase=expand lock=ShareRowExclusive custo=tabela_vazia
CREATE TRIGGER "vt_authz_01e3b579ef1811b6be2c64ee_update" AFTER UPDATE ON "public"."users"
  REFERENCING OLD TABLE AS vt_old NEW TABLE AS vt_new FOR EACH STATEMENT EXECUTE FUNCTION "vetra"."vt_authz_01e3b579ef1811b6be2c64ee_update"();

-- vetra:passo 175 fase=expand lock=ShareRowExclusive custo=tabela_vazia
ALTER TABLE "public"."users" ENABLE ALWAYS TRIGGER "vt_authz_01e3b579ef1811b6be2c64ee_update";

-- vetra:passo 176 fase=expand lock=nenhum custo=catalogo
REVOKE TRUNCATE, TRIGGER, REFERENCES ON "public"."users" FROM PUBLIC, "vetra_app";

-- vetra:passo 177 fase=expand lock=nenhum custo=catalogo
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
  AND p.prorettype = 'pg_catalog.uuid'::pg_catalog.regtype
  AND p.proallargtypes IS NULL AND p.proargmodes IS NULL AND p.proargnames IS NULL
  AND p.proargdefaults IS NULL AND p.prosqlbody IS NULL AND p.probin IS NULL
  AND p.proconfig = ARRAY['search_path=pg_catalog, pg_temp']::text[]
  AND ((p.proname = 'current_tenant' AND pg_catalog.encode(pg_catalog.sha256(pg_catalog.convert_to(p.prosrc, 'UTF8')), 'hex') = '214c01e27351d5a6d356f4699938bd1dfcf50acccf38e43d4e92b6689152b815') OR (p.proname = 'current_actor' AND pg_catalog.encode(pg_catalog.sha256(pg_catalog.convert_to(p.prosrc, 'UTF8')), 'hex') = '90c4339286bf6c7aa52bf807f49beeba575cc1b30b1bc736f129a076419271be'))), false)
      AND EXISTS (SELECT 1 FROM pg_roles r WHERE pg_has_role('vetra_app', r.oid, 'SET') AND has_function_privilege(r.oid, p.oid, 'EXECUTE'))) THEN
    RAISE EXCEPTION 'Execução herdada ou assumível por SET ROLE das funções de revisão não é permitida';
  END IF;
END $vetra_privileges$;

-- vetra:passo 178 fase=expand lock=nenhum custo=catalogo
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
  AND p.prorettype = 'pg_catalog.uuid'::pg_catalog.regtype
  AND p.proallargtypes IS NULL AND p.proargmodes IS NULL AND p.proargnames IS NULL
  AND p.proargdefaults IS NULL AND p.prosqlbody IS NULL AND p.probin IS NULL
  AND p.proconfig = ARRAY['search_path=pg_catalog, pg_temp']::text[]
  AND ((p.proname = 'current_tenant' AND pg_catalog.encode(pg_catalog.sha256(pg_catalog.convert_to(p.prosrc, 'UTF8')), 'hex') = '214c01e27351d5a6d356f4699938bd1dfcf50acccf38e43d4e92b6689152b815') OR (p.proname = 'current_actor' AND pg_catalog.encode(pg_catalog.sha256(pg_catalog.convert_to(p.prosrc, 'UTF8')), 'hex') = '90c4339286bf6c7aa52bf807f49beeba575cc1b30b1bc736f129a076419271be'))), false)
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
  AND p.prorettype = 'pg_catalog.uuid'::pg_catalog.regtype
  AND p.proallargtypes IS NULL AND p.proargmodes IS NULL AND p.proargnames IS NULL
  AND p.proargdefaults IS NULL AND p.prosqlbody IS NULL AND p.probin IS NULL
  AND p.proconfig = ARRAY['search_path=pg_catalog, pg_temp']::text[]
  AND ((p.proname = 'current_tenant' AND pg_catalog.encode(pg_catalog.sha256(pg_catalog.convert_to(p.prosrc, 'UTF8')), 'hex') = '214c01e27351d5a6d356f4699938bd1dfcf50acccf38e43d4e92b6689152b815') OR (p.proname = 'current_actor' AND pg_catalog.encode(pg_catalog.sha256(pg_catalog.convert_to(p.prosrc, 'UTF8')), 'hex') = '90c4339286bf6c7aa52bf807f49beeba575cc1b30b1bc736f129a076419271be'))), false)
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

-- vetra:passo 179 fase=expand lock=RowExclusive custo=tabela_vazia
INSERT INTO "vetra"."authz_revisions" (tenant_id, revision) SELECT "id"::text, 0 FROM "public"."companies";

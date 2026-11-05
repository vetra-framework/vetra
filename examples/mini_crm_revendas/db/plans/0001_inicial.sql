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

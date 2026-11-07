-- vetra:plano 0003 expand
-- vetra:transacao por_passo
--
-- Gerado por `vetra db:plan` a partir de .vetra/graph.json. Revise antes de aplicar e confira com
-- `vetra db:plan --check`. Cada passo diz a fase, o lock que pede numa tabela existente e o custo.

-- vetra:passo 1 fase=expand lock=AccessExclusive custo=catalogo transacao=sim
DO $vetra_relay_role$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'vetra_relay' AND rolcanlogin
      AND NOT rolsuper AND NOT rolcreatedb AND NOT rolcreaterole AND NOT rolreplication AND NOT rolbypassrls) THEN
    RAISE EXCEPTION 'Papel vetra_relay ausente ou incompatível; execute o bootstrap operacional do ADR-036';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_catalog.pg_auth_members m
      WHERE m.member = 'vetra_relay'::regrole OR m.roleid = 'vetra_relay'::regrole) THEN
    RAISE EXCEPTION 'vetra_relay não pode pertencer a outro papel nem ter membros (ADR-040, §3)';
  END IF;
END $vetra_relay_role$;
CREATE TABLE "vetra"."relay_checkpoints" (
  "name" text PRIMARY KEY CHECK ("name" ~ '^[a-z][a-z0-9_]*$'),
  "next_xid8" pg_catalog.xid8 NOT NULL,
  "updated_at" timestamp(6) with time zone NOT NULL DEFAULT pg_catalog.statement_timestamp()
);
INSERT INTO "vetra"."relay_checkpoints" ("name", "next_xid8") VALUES ('relay', '0');
ALTER TABLE "vetra"."relay_checkpoints" OWNER TO "vetra_owner";
REVOKE ALL ON TABLE "vetra"."relay_checkpoints" FROM PUBLIC, "vetra_app";
ALTER TABLE "vetra"."relay_checkpoints" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "vetra"."relay_checkpoints" FORCE ROW LEVEL SECURITY;
CREATE POLICY "vt_outbox_relay" ON "vetra"."outbox" AS PERMISSIVE FOR SELECT TO "vetra_relay" USING (true);
CREATE POLICY "vt_deliveries_relay" ON "vetra"."deliveries" AS PERMISSIVE FOR ALL TO "vetra_relay" USING (true) WITH CHECK (true);
CREATE POLICY "vt_dead_deliveries_relay" ON "vetra"."dead_deliveries" AS PERMISSIVE FOR ALL TO "vetra_relay" USING (true) WITH CHECK (true);
CREATE POLICY "vt_relay_checkpoints_relay" ON "vetra"."relay_checkpoints" AS PERMISSIVE FOR ALL TO "vetra_relay" USING (true) WITH CHECK (true);
CREATE POLICY "vt_outbox_owner" ON "vetra"."outbox" AS PERMISSIVE FOR ALL TO "vetra_owner" USING (true) WITH CHECK (true);
CREATE POLICY "vt_outbox_default_owner" ON "vetra"."outbox_default" AS PERMISSIVE FOR ALL TO "vetra_owner" USING (true) WITH CHECK (true);
CREATE POLICY "vt_deliveries_owner" ON "vetra"."deliveries" AS PERMISSIVE FOR ALL TO "vetra_owner" USING (true) WITH CHECK (true);
CREATE POLICY "vt_deliveries_default_owner" ON "vetra"."deliveries_default" AS PERMISSIVE FOR ALL TO "vetra_owner" USING (true) WITH CHECK (true);
CREATE POLICY "vt_relay_checkpoints_owner" ON "vetra"."relay_checkpoints" AS PERMISSIVE FOR ALL TO "vetra_owner" USING (true) WITH CHECK (true);
GRANT USAGE ON SCHEMA "vetra" TO "vetra_relay";
GRANT SELECT ON TABLE "vetra"."outbox" TO "vetra_relay";
GRANT SELECT, INSERT, UPDATE ON TABLE "vetra"."deliveries" TO "vetra_relay";
GRANT SELECT, INSERT ON TABLE "vetra"."dead_deliveries" TO "vetra_relay";
GRANT SELECT, UPDATE ON TABLE "vetra"."relay_checkpoints" TO "vetra_relay";
CREATE FUNCTION "vetra"."outbox_maintain"(ahead integer, retention integer) RETURNS jsonb LANGUAGE plpgsql
  SECURITY DEFINER SET search_path = pg_catalog, pg_temp SET lock_timeout = '3s' AS $vetra_outbox$
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
$vetra_outbox$;
ALTER FUNCTION "vetra"."outbox_maintain"(integer,integer) OWNER TO "vetra_owner";
REVOKE ALL ON FUNCTION "vetra"."outbox_maintain"(integer,integer) FROM PUBLIC, "vetra_app";
GRANT EXECUTE ON FUNCTION "vetra"."outbox_maintain"(integer,integer) TO "vetra_relay";

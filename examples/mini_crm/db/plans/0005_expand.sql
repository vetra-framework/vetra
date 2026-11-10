-- vetra:plano 0005 expand
-- vetra:transacao por_passo
--
-- Gerado por `vetra db:plan` a partir de .vetra/graph.json. Revise antes de aplicar e confira com
-- `vetra db:plan --check`. Cada passo diz a fase, o lock que pede numa tabela existente e o custo.

-- vetra:passo 1 fase=expand lock=nenhum custo=catalogo transacao=sim
CREATE TABLE "vetra"."idempotency" (
  "id" bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  "tenant_id" uuid,
  "command" text NOT NULL CHECK (pg_catalog.char_length("command") BETWEEN 1 AND 255),
  "key" text NOT NULL CHECK ("key" ~ '^[!-~]{1,255}$'),
  "origin" text NOT NULL CHECK ("origin" IN ('adapter', 'event')),
  "principal" text CHECK ("principal" IS NULL OR pg_catalog.char_length("principal") BETWEEN 1 AND 160),
  "input_hash" bytea NOT NULL CHECK (pg_catalog.octet_length("input_hash") = 32),
  "result" jsonb CHECK ("result" IS NULL OR pg_catalog.octet_length("result"::text) <= 65536),
  "handler" text,
  "event_id" uuid,
  "event_created_at" timestamp(6) with time zone,
  "created_at" timestamp(6) with time zone NOT NULL DEFAULT pg_catalog.statement_timestamp(),
  CONSTRAINT "vt_idempotency_key" UNIQUE NULLS NOT DISTINCT ("tenant_id", "command", "key"),
  CONSTRAINT "vt_idempotency_origin" CHECK (
    ("origin" = 'event' AND "handler" IS NOT NULL AND "event_id" IS NOT NULL AND "event_created_at" IS NOT NULL)
    OR ("origin" = 'adapter' AND "handler" IS NULL AND "event_id" IS NULL AND "event_created_at" IS NULL))
);
CREATE INDEX "vt_idempotency_purge" ON "vetra"."idempotency" ("origin", "created_at");
ALTER TABLE "vetra"."idempotency" OWNER TO "vetra_owner";
REVOKE ALL ON TABLE "vetra"."idempotency" FROM PUBLIC, "vetra_app", "vetra_relay";
ALTER TABLE "vetra"."idempotency" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "vetra"."idempotency" FORCE ROW LEVEL SECURITY;
CREATE POLICY "vt_idempotency_app" ON "vetra"."idempotency" AS PERMISSIVE FOR ALL TO "vetra_app" USING ("tenant_id" = (SELECT vetra.current_tenant())) WITH CHECK ("tenant_id" = (SELECT vetra.current_tenant()));
CREATE POLICY "vt_idempotency_relay" ON "vetra"."idempotency" AS PERMISSIVE FOR ALL TO "vetra_relay" USING (true) WITH CHECK (true);
GRANT SELECT ON TABLE "vetra"."idempotency" TO "vetra_app";
GRANT INSERT ("tenant_id", "command", "key", "origin", "principal", "input_hash", "handler", "event_id", "event_created_at") ON TABLE "vetra"."idempotency" TO "vetra_app";
GRANT UPDATE ("result") ON TABLE "vetra"."idempotency" TO "vetra_app";
GRANT SELECT, DELETE ON TABLE "vetra"."idempotency" TO "vetra_relay";

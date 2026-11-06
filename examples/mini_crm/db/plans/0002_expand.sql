-- vetra:plano 0002 expand
-- vetra:transacao por_passo
--
-- Gerado por `vetra db:plan` a partir de .vetra/graph.json. Revise antes de aplicar e confira com
-- `vetra db:plan --check`. Cada passo diz a fase, o lock que pede numa tabela existente e o custo.

-- vetra:passo 1 fase=expand lock=nenhum custo=catalogo transacao=sim
CREATE TABLE "vetra"."outbox" (
  "created_at" timestamp(6) with time zone NOT NULL DEFAULT pg_catalog.statement_timestamp(),
  "xid8" pg_catalog.xid8 NOT NULL DEFAULT pg_catalog.pg_current_xact_id(),
  "seq" bigint GENERATED ALWAYS AS IDENTITY,
  "event_id" uuid NOT NULL,
  "event" text NOT NULL CHECK ("event" ~ '^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$'),
  "version" integer NOT NULL CHECK ("version" > 0),
  "tenant_id" uuid,
  "actor_id" uuid,
  "op_id" uuid NOT NULL,
  "cmd" text NOT NULL CHECK (pg_catalog.char_length("cmd") BETWEEN 1 AND 255),
  "payload" jsonb NOT NULL CHECK (pg_catalog.jsonb_typeof("payload") = 'object'),
  PRIMARY KEY ("created_at", "xid8", "seq")
) PARTITION BY RANGE ("created_at");
CREATE TABLE "vetra"."outbox_default" PARTITION OF "vetra"."outbox" DEFAULT;
CREATE TABLE "vetra"."deliveries" (
  "event_created_at" timestamp(6) with time zone NOT NULL,
  "event_xid8" pg_catalog.xid8 NOT NULL,
  "event_seq" bigint NOT NULL,
  "event_id" uuid NOT NULL,
  "handler" text NOT NULL CHECK ("handler" ~ '^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$'),
  "tenant_id" uuid,
  "state" text NOT NULL DEFAULT 'pending' CHECK ("state" IN ('pending', 'done', 'dead')),
  "attempts" integer NOT NULL DEFAULT 0 CHECK ("attempts" >= 0),
  "run_after" timestamp(6) with time zone NOT NULL DEFAULT pg_catalog.statement_timestamp(),
  "leased_until" timestamp(6) with time zone,
  "last_error" text,
  "created_at" timestamp(6) with time zone NOT NULL DEFAULT pg_catalog.statement_timestamp(),
  "updated_at" timestamp(6) with time zone NOT NULL DEFAULT pg_catalog.statement_timestamp(),
  PRIMARY KEY ("handler", "event_id", "event_created_at")
) PARTITION BY RANGE ("event_created_at");
CREATE TABLE "vetra"."deliveries_default" PARTITION OF "vetra"."deliveries" DEFAULT;
CREATE TABLE "vetra"."dead_deliveries" (
  "handler" text NOT NULL CHECK ("handler" ~ '^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$'),
  "event_id" uuid NOT NULL,
  "event_created_at" timestamp(6) with time zone NOT NULL,
  "event_xid8" pg_catalog.xid8 NOT NULL,
  "event_seq" bigint NOT NULL,
  "event" text NOT NULL CHECK ("event" ~ '^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$'),
  "version" integer NOT NULL CHECK ("version" > 0),
  "tenant_id" uuid,
  "payload" jsonb NOT NULL CHECK (pg_catalog.jsonb_typeof("payload") = 'object'),
  "attempts" integer NOT NULL CHECK ("attempts" >= 0),
  "last_error" text,
  "died_at" timestamp(6) with time zone NOT NULL DEFAULT pg_catalog.statement_timestamp(),
  PRIMARY KEY ("handler", "event_id")
);
CREATE INDEX "vt_outbox_relay" ON "vetra"."outbox" ("xid8", "seq");
CREATE INDEX "vt_deliveries_ready" ON "vetra"."deliveries" ("run_after") WHERE "state" = 'pending';
ALTER TABLE "vetra"."outbox" OWNER TO "vetra_owner";
REVOKE ALL ON TABLE "vetra"."outbox" FROM PUBLIC, "vetra_app";
ALTER TABLE "vetra"."outbox" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "vetra"."outbox" FORCE ROW LEVEL SECURITY;
ALTER TABLE "vetra"."outbox_default" OWNER TO "vetra_owner";
REVOKE ALL ON TABLE "vetra"."outbox_default" FROM PUBLIC, "vetra_app";
ALTER TABLE "vetra"."outbox_default" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "vetra"."outbox_default" FORCE ROW LEVEL SECURITY;
ALTER TABLE "vetra"."deliveries" OWNER TO "vetra_owner";
REVOKE ALL ON TABLE "vetra"."deliveries" FROM PUBLIC, "vetra_app";
ALTER TABLE "vetra"."deliveries" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "vetra"."deliveries" FORCE ROW LEVEL SECURITY;
ALTER TABLE "vetra"."deliveries_default" OWNER TO "vetra_owner";
REVOKE ALL ON TABLE "vetra"."deliveries_default" FROM PUBLIC, "vetra_app";
ALTER TABLE "vetra"."deliveries_default" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "vetra"."deliveries_default" FORCE ROW LEVEL SECURITY;
ALTER TABLE "vetra"."dead_deliveries" OWNER TO "vetra_owner";
REVOKE ALL ON TABLE "vetra"."dead_deliveries" FROM PUBLIC, "vetra_app";
ALTER TABLE "vetra"."dead_deliveries" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "vetra"."dead_deliveries" FORCE ROW LEVEL SECURITY;
CREATE POLICY "vt_outbox_insert" ON "vetra"."outbox" AS PERMISSIVE FOR INSERT TO "vetra_app" WITH CHECK ("tenant_id" = (SELECT vetra.current_tenant()) AND "actor_id" IS NOT DISTINCT FROM (SELECT vetra.current_actor()));
GRANT INSERT ("event_id", "event", "version", "tenant_id", "actor_id", "op_id", "cmd", "payload") ON TABLE "vetra"."outbox" TO "vetra_app";

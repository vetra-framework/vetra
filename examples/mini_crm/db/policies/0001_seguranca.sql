-- Vetra: segurança derivada da IR; aplicada somente pelos passos de db/plans/.

-- Confira com vetra db:plan --check; não aplique este espelho separadamente.

-- crm.company: sem escopo SQL; permissiva de tenant, RBAC na aplicação.

-- crm.lead: sem escopo SQL; permissiva de tenant, RBAC na aplicação.

ALTER TABLE "public"."companies" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."companies" FORCE ROW LEVEL SECURITY;

CREATE POLICY "vt_tenant" ON "public"."companies" AS RESTRICTIVE FOR ALL TO "vetra_app" USING ("id" = (SELECT vetra.current_tenant())) WITH CHECK ("id" = (SELECT vetra.current_tenant()));

CREATE POLICY "vt_access" ON "public"."companies" AS PERMISSIVE FOR ALL TO "vetra_app" USING (true) WITH CHECK (true);

ALTER TABLE "public"."leads" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."leads" FORCE ROW LEVEL SECURITY;

CREATE POLICY "vt_tenant" ON "public"."leads" AS RESTRICTIVE FOR ALL TO "vetra_app" USING ("company_id" = (SELECT vetra.current_tenant())) WITH CHECK ("company_id" = (SELECT vetra.current_tenant()));

CREATE POLICY "vt_access" ON "public"."leads" AS PERMISSIVE FOR ALL TO "vetra_app" USING (true) WITH CHECK (true);

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

ALTER FUNCTION "vetra"."vt_transition_f11b74e8383ca04610952e448ddcd983"() OWNER TO "vetra_owner";

REVOKE ALL ON FUNCTION "vetra"."vt_transition_f11b74e8383ca04610952e448ddcd983"() FROM PUBLIC, "vetra_app";

CREATE TRIGGER "vt_transition_f11b74e8383ca04610952e448ddcd983" BEFORE INSERT OR UPDATE ON "public"."leads" FOR EACH ROW EXECUTE FUNCTION "vetra"."vt_transition_f11b74e8383ca04610952e448ddcd983"();

ALTER TABLE "public"."leads" ENABLE ALWAYS TRIGGER "vt_transition_f11b74e8383ca04610952e448ddcd983";

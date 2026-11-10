-- vetra:plano 0004 expand
-- vetra:transacao por_passo
--
-- Gerado por `vetra db:plan` a partir de .vetra/graph.json. Revise antes de aplicar e confira com
-- `vetra db:plan --check`. Cada passo diz a fase, o lock que pede numa tabela existente e o custo.

-- vetra:passo 1 fase=expand lock=AccessExclusive custo=catalogo transacao=sim
DROP POLICY "vt_tenant" ON "public"."dealers";
DROP POLICY "vt_scope_read" ON "public"."dealers";
CREATE POLICY "vt_tenant" ON "public"."dealers" AS RESTRICTIVE FOR ALL TO "vetra_app" USING ("company_id" = (SELECT vetra.current_tenant())) WITH CHECK ("company_id" = (SELECT vetra.current_tenant()));
CREATE POLICY "vt_scope_read" ON "public"."dealers" AS PERMISSIVE FOR SELECT TO "vetra_app" USING (("dealers"."id" = ANY (ARRAY(SELECT "vt_scope_1"."dealer_id" FROM "public"."memberships" AS "vt_scope_1" WHERE ("vt_scope_1"."company_id" = (SELECT vetra.current_tenant())) AND (("vt_scope_1"."role" IN (E'gerente', E'vendedor')) AND ("vt_scope_1"."user_id" = (SELECT vetra.current_actor())))))));

-- vetra:passo 2 fase=expand lock=AccessExclusive custo=catalogo transacao=sim
DROP POLICY "vt_tenant" ON "public"."leads";
DROP POLICY "vt_scope_read" ON "public"."leads";
DROP POLICY "vt_scope_create" ON "public"."leads";
DROP POLICY "vt_scope_update" ON "public"."leads";
DROP POLICY "vt_scope_delete" ON "public"."leads";
CREATE POLICY "vt_tenant" ON "public"."leads" AS RESTRICTIVE FOR ALL TO "vetra_app" USING ("company_id" = (SELECT vetra.current_tenant())) WITH CHECK ("company_id" = (SELECT vetra.current_tenant()));
CREATE POLICY "vt_scope_read" ON "public"."leads" AS PERMISSIVE FOR SELECT TO "vetra_app" USING (("leads"."dealer_id" = ANY (ARRAY(SELECT "vt_scope_2"."dealer_id" FROM "public"."memberships" AS "vt_scope_2" WHERE ("vt_scope_2"."company_id" = (SELECT vetra.current_tenant())) AND (("vt_scope_2"."role" IN (E'gerente', E'vendedor')) AND ("vt_scope_2"."user_id" = (SELECT vetra.current_actor())))))));
CREATE POLICY "vt_scope_create" ON "public"."leads" AS PERMISSIVE FOR INSERT TO "vetra_app" WITH CHECK (("leads"."dealer_id" = ANY (ARRAY(SELECT "vt_scope_3"."dealer_id" FROM "public"."memberships" AS "vt_scope_3" WHERE ("vt_scope_3"."company_id" = (SELECT vetra.current_tenant())) AND (("vt_scope_3"."role" IN (E'gerente', E'vendedor')) AND ("vt_scope_3"."user_id" = (SELECT vetra.current_actor())))))));
CREATE POLICY "vt_scope_update" ON "public"."leads" AS PERMISSIVE FOR UPDATE TO "vetra_app" USING (("leads"."dealer_id" = ANY (ARRAY(SELECT "vt_scope_4"."dealer_id" FROM "public"."memberships" AS "vt_scope_4" WHERE ("vt_scope_4"."company_id" = (SELECT vetra.current_tenant())) AND (("vt_scope_4"."role" IN (E'gerente', E'vendedor')) AND ("vt_scope_4"."user_id" = (SELECT vetra.current_actor()))))))) WITH CHECK (("leads"."dealer_id" = ANY (ARRAY(SELECT "vt_scope_4"."dealer_id" FROM "public"."memberships" AS "vt_scope_4" WHERE ("vt_scope_4"."company_id" = (SELECT vetra.current_tenant())) AND (("vt_scope_4"."role" IN (E'gerente', E'vendedor')) AND ("vt_scope_4"."user_id" = (SELECT vetra.current_actor())))))));
CREATE POLICY "vt_scope_delete" ON "public"."leads" AS PERMISSIVE FOR DELETE TO "vetra_app" USING (("leads"."dealer_id" = ANY (ARRAY(SELECT "vt_scope_5"."dealer_id" FROM "public"."memberships" AS "vt_scope_5" WHERE ("vt_scope_5"."company_id" = (SELECT vetra.current_tenant())) AND (("vt_scope_5"."role" = E'gerente') AND ("vt_scope_5"."user_id" = (SELECT vetra.current_actor())))))));

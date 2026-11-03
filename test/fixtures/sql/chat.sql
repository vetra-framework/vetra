CREATE TABLE "public"."messages" (
  "author_id" uuid NOT NULL,
  "body" text NOT NULL,
  "created_at" timestamp(6) with time zone NOT NULL,
  "id" uuid NOT NULL DEFAULT pg_catalog.gen_random_uuid(),
  "room_id" uuid NOT NULL,
  CONSTRAINT "vt_pk_29dd45144ead987a3c36b8eff5054f05" PRIMARY KEY ("id"),
  CONSTRAINT "vt_ck_60c9617cf5e34dbbe2bea54e76d66b13" CHECK (pg_catalog.char_length("body") <= 4000)
);
CREATE INDEX "vt_ix_3b5480ce7197874d7a5bdb6436221573" ON "public"."messages" ("author_id");
CREATE INDEX "vt_ix_6c5a6962c5567e3136218a20ccd778bb" ON "public"."messages" ("room_id", "created_at");
CREATE TABLE "public"."room_memberships" (
  "created_at" timestamp(6) with time zone NOT NULL,
  "id" uuid NOT NULL DEFAULT pg_catalog.gen_random_uuid(),
  "room_id" uuid NOT NULL,
  "user_id" uuid NOT NULL,
  CONSTRAINT "vt_pk_e79206a51d8dd23231c4cf4f49c11d55" PRIMARY KEY ("id")
);
ALTER TABLE "public"."room_memberships" ADD CONSTRAINT "vt_uq_63280809b6e0753d434cd9533e4818d6" UNIQUE ("room_id", "user_id");
CREATE INDEX "vt_ix_59b6dee34acd95168591b33e06d42632" ON "public"."room_memberships" ("user_id");
CREATE TABLE "public"."rooms" (
  "created_at" timestamp(6) with time zone NOT NULL,
  "id" uuid NOT NULL DEFAULT pg_catalog.gen_random_uuid(),
  "name" text NOT NULL,
  "owner_id" uuid NOT NULL,
  CONSTRAINT "vt_pk_6ea7e6e7e69a80a75e7b9121bc19b161" PRIMARY KEY ("id"),
  CONSTRAINT "vt_ck_edfbcde86f777997d3250f9e8ffd5a85" CHECK (pg_catalog.char_length("name") <= 80)
);
CREATE INDEX "vt_ix_837c5ade83a68764757de4ae044f9802" ON "public"."rooms" ("owner_id");
CREATE TABLE "public"."users" (
  "created_at" timestamp(6) with time zone NOT NULL,
  "email" text NOT NULL,
  "id" uuid NOT NULL DEFAULT pg_catalog.gen_random_uuid(),
  "name" text NOT NULL,
  CONSTRAINT "vt_pk_344f37be5dc149cf8c9590e8719b61c5" PRIMARY KEY ("id"),
  CONSTRAINT "vt_ck_d1b6d46a7070d1e01500f3308355ceba" CHECK ("email" = pg_catalog.lower("email"))
);
ALTER TABLE "public"."users" ADD CONSTRAINT "vt_uq_790bc8d38d2b0db83fe19d17b070d9fb" UNIQUE ("email");
ALTER TABLE "public"."messages" ADD CONSTRAINT "vt_fk_64193792c688830b05f0bff5d5c518b3" FOREIGN KEY ("room_id") REFERENCES "public"."rooms" ("id") MATCH SIMPLE ON DELETE NO ACTION ON UPDATE NO ACTION DEFERRABLE INITIALLY IMMEDIATE;
ALTER TABLE "public"."messages" ADD CONSTRAINT "vt_fk_b238fbf3a0c884447c919c7309c73229" FOREIGN KEY ("author_id") REFERENCES "public"."users" ("id") MATCH SIMPLE ON DELETE NO ACTION ON UPDATE NO ACTION DEFERRABLE INITIALLY IMMEDIATE;
ALTER TABLE "public"."room_memberships" ADD CONSTRAINT "vt_fk_0b495c1a0bbc85eda7648441551cc807" FOREIGN KEY ("room_id") REFERENCES "public"."rooms" ("id") MATCH SIMPLE ON DELETE NO ACTION ON UPDATE NO ACTION DEFERRABLE INITIALLY IMMEDIATE;
ALTER TABLE "public"."room_memberships" ADD CONSTRAINT "vt_fk_887e921b8d995136be84fdaab786f5a2" FOREIGN KEY ("user_id") REFERENCES "public"."users" ("id") MATCH SIMPLE ON DELETE NO ACTION ON UPDATE NO ACTION DEFERRABLE INITIALLY IMMEDIATE;
ALTER TABLE "public"."rooms" ADD CONSTRAINT "vt_fk_d28ab3d2ad832571f34da936408718a9" FOREIGN KEY ("owner_id") REFERENCES "public"."users" ("id") MATCH SIMPLE ON DELETE NO ACTION ON UPDATE NO ACTION DEFERRABLE INITIALLY IMMEDIATE;

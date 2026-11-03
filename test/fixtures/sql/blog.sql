CREATE TABLE "public"."comments" (
  "approved" boolean NOT NULL DEFAULT FALSE,
  "author_email" text NOT NULL,
  "author_name" text NOT NULL,
  "body" text NOT NULL,
  "created_at" timestamp(6) with time zone NOT NULL,
  "id" uuid NOT NULL DEFAULT pg_catalog.gen_random_uuid(),
  "post_id" uuid NOT NULL,
  CONSTRAINT "vt_pk_e65d3acd28849b0c97f88486111aef61" PRIMARY KEY ("id"),
  CONSTRAINT "vt_ck_c7c0e7456076e638f145552b4955d4be" CHECK (pg_catalog.char_length("body") <= 2000),
  CONSTRAINT "vt_ck_fde429239c0bf5c9489713b28d4ae5e2" CHECK (pg_catalog.char_length("author_name") <= 80)
);
CREATE INDEX "vt_ix_d3622996ba4077dc3317ae7224cf877c" ON "public"."comments" ("post_id");
CREATE TABLE "public"."posts" (
  "author_id" uuid NOT NULL,
  "created_at" timestamp(6) with time zone NOT NULL,
  "id" uuid NOT NULL DEFAULT pg_catalog.gen_random_uuid(),
  "published_at" timestamp(6) with time zone,
  "status" text NOT NULL DEFAULT E'draft',
  "title" text NOT NULL,
  CONSTRAINT "vt_pk_0732ee4194e46d003e5300e171222785" PRIMARY KEY ("id"),
  CONSTRAINT "vt_ck_61ea112cf369b279f4429c9699231bc0" CHECK ("status" IN (E'draft', E'published')),
  CONSTRAINT "vt_ck_a5a9aa07fe07d6cfa4b2e63d6d60a1db" CHECK (pg_catalog.char_length("title") <= 200)
);
CREATE INDEX "vt_ix_b376a5f46e965210eb78284646c740a6" ON "public"."posts" ("status", "published_at");
ALTER TABLE "public"."comments" ADD CONSTRAINT "vt_fk_d52bd44498b03fbdc39a2c3b32f20bd2" FOREIGN KEY ("post_id") REFERENCES "public"."posts" ("id") MATCH SIMPLE ON DELETE NO ACTION ON UPDATE NO ACTION DEFERRABLE INITIALLY IMMEDIATE;

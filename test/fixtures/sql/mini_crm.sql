CREATE TABLE "public"."companies" (
  "created_at" timestamp(6) with time zone NOT NULL,
  "id" uuid NOT NULL DEFAULT pg_catalog.gen_random_uuid(),
  "name" text NOT NULL,
  CONSTRAINT "vt_pk_c37b42fe24009eca08260a3f4ae04e1c" PRIMARY KEY ("id")
);
CREATE TABLE "public"."leads" (
  "company_id" uuid NOT NULL,
  "created_at" timestamp(6) with time zone NOT NULL,
  "email" text,
  "id" uuid NOT NULL DEFAULT pg_catalog.gen_random_uuid(),
  "name" text NOT NULL,
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
ALTER TABLE "public"."leads" ADD CONSTRAINT "vt_uq_42a25356531b11d1e4d5decf7a0e1e24" UNIQUE ("company_id", "id");
CREATE INDEX "vt_ix_507afec86a6c207e0ca28dd203ffb300" ON "public"."leads" ("company_id", "status");
ALTER TABLE "public"."leads" ADD CONSTRAINT "vt_fk_70eb50f95e008e03c285c62b8baf5678" FOREIGN KEY ("company_id") REFERENCES "public"."companies" ("id") MATCH SIMPLE ON DELETE NO ACTION ON UPDATE NO ACTION DEFERRABLE INITIALLY IMMEDIATE;

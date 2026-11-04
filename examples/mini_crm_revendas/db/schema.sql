-- Retrato do esquema: resultado de aplicar db/plans/ num banco vazio (vetra db:plan --snapshot).
-- Gerado a partir do pg_dump --schema-only --no-owner normalizado; não edite à mão.

CREATE TABLE public.companies (
    created_at timestamp(6) with time zone NOT NULL,
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name text NOT NULL
);

CREATE TABLE public.dealers (
    company_id uuid NOT NULL,
    created_at timestamp(6) with time zone NOT NULL,
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name text NOT NULL
);

CREATE TABLE public.leads (
    company_id uuid NOT NULL,
    created_at timestamp(6) with time zone NOT NULL,
    dealer_id uuid NOT NULL,
    email text,
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name text NOT NULL,
    seller_id uuid,
    status text DEFAULT 'new'::text NOT NULL,
    valor_amount numeric(19,2),
    valor_currency text,
    CONSTRAINT vt_ck_09fca56d131fbca8bb8b28409cfc25ce CHECK ((valor_amount <> 'NaN'::numeric)),
    CONSTRAINT vt_ck_242d848d9fc19c20ee60aa78d6e27ba0 CHECK ((char_length(name) <= 160)),
    CONSTRAINT vt_ck_2ecae20e3dc7306aaef71329e733f2bc CHECK ((char_length(name) >= 2)),
    CONSTRAINT vt_ck_553df3e9e965bf8efdc803982848cf31 CHECK ((status = ANY (ARRAY['contacted'::text, 'lost'::text, 'new'::text, 'won'::text]))),
    CONSTRAINT vt_ck_6f555cb8ab4a60c13c3a43eea5c9b008 CHECK (((valor_amount IS NULL) = (valor_currency IS NULL))),
    CONSTRAINT vt_ck_8917258bea0d4daa1b638f66d025afff CHECK ((valor_currency = ANY (ARRAY['AED'::text, 'AFN'::text, 'ALL'::text, 'AMD'::text, 'AOA'::text, 'ARS'::text, 'AUD'::text, 'AWG'::text, 'AZN'::text, 'BAM'::text, 'BBD'::text, 'BDT'::text, 'BIF'::text, 'BMD'::text, 'BND'::text, 'BOB'::text, 'BOV'::text, 'BRL'::text, 'BSD'::text, 'BTN'::text, 'BWP'::text, 'BYN'::text, 'BZD'::text, 'CAD'::text, 'CDF'::text, 'CHE'::text, 'CHF'::text, 'CHW'::text, 'CLP'::text, 'CNY'::text, 'COP'::text, 'COU'::text, 'CRC'::text, 'CUP'::text, 'CVE'::text, 'CZK'::text, 'DJF'::text, 'DKK'::text, 'DOP'::text, 'DZD'::text, 'EGP'::text, 'ERN'::text, 'ETB'::text, 'EUR'::text, 'FJD'::text, 'FKP'::text, 'GBP'::text, 'GEL'::text, 'GHS'::text, 'GIP'::text, 'GMD'::text, 'GNF'::text, 'GTQ'::text, 'GYD'::text, 'HKD'::text, 'HNL'::text, 'HTG'::text, 'HUF'::text, 'IDR'::text, 'ILS'::text, 'INR'::text, 'IRR'::text, 'ISK'::text, 'JMD'::text, 'JPY'::text, 'KES'::text, 'KGS'::text, 'KHR'::text, 'KMF'::text, 'KPW'::text, 'KRW'::text, 'KYD'::text, 'KZT'::text, 'LAK'::text, 'LBP'::text, 'LKR'::text, 'LRD'::text, 'LSL'::text, 'MAD'::text, 'MDL'::text, 'MGA'::text, 'MKD'::text, 'MMK'::text, 'MNT'::text, 'MOP'::text, 'MRU'::text, 'MUR'::text, 'MVR'::text, 'MWK'::text, 'MXN'::text, 'MXV'::text, 'MYR'::text, 'MZN'::text, 'NAD'::text, 'NGN'::text, 'NIO'::text, 'NOK'::text, 'NPR'::text, 'NZD'::text, 'PAB'::text, 'PEN'::text, 'PGK'::text, 'PHP'::text, 'PKR'::text, 'PLN'::text, 'PYG'::text, 'QAR'::text, 'RON'::text, 'RSD'::text, 'RUB'::text, 'RWF'::text, 'SAR'::text, 'SBD'::text, 'SCR'::text, 'SDG'::text, 'SEK'::text, 'SGD'::text, 'SHP'::text, 'SLE'::text, 'SOS'::text, 'SRD'::text, 'SSP'::text, 'STN'::text, 'SVC'::text, 'SYP'::text, 'SZL'::text, 'THB'::text, 'TJS'::text, 'TMT'::text, 'TOP'::text, 'TRY'::text, 'TTD'::text, 'TWD'::text, 'TZS'::text, 'UAH'::text, 'UGX'::text, 'USD'::text, 'USN'::text, 'UYI'::text, 'UYU'::text, 'UZS'::text, 'VED'::text, 'VES'::text, 'VND'::text, 'VUV'::text, 'WST'::text, 'XAD'::text, 'XAF'::text, 'XCD'::text, 'XCG'::text, 'XOF'::text, 'XPF'::text, 'YER'::text, 'ZAR'::text, 'ZMW'::text, 'ZWG'::text])))
);

CREATE TABLE public.memberships (
    company_id uuid NOT NULL,
    created_at timestamp(6) with time zone NOT NULL,
    dealer_id uuid NOT NULL,
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    role text NOT NULL,
    user_id uuid NOT NULL,
    CONSTRAINT vt_ck_65b396fea188eea8a1e8dbf919dbc23e CHECK ((role = ANY (ARRAY['gerente'::text, 'vendedor'::text])))
);

CREATE TABLE public.users (
    company_id uuid NOT NULL,
    created_at timestamp(6) with time zone NOT NULL,
    email text NOT NULL,
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name text NOT NULL
);

ALTER TABLE ONLY public.users
    ADD CONSTRAINT vt_pk_344f37be5dc149cf8c9590e8719b61c5 PRIMARY KEY (id);

ALTER TABLE ONLY public.memberships
    ADD CONSTRAINT vt_pk_72678947e9265c089ef5e782916c070e PRIMARY KEY (id);

ALTER TABLE ONLY public.dealers
    ADD CONSTRAINT vt_pk_b43d772e1801c2820d5ce950c7904a03 PRIMARY KEY (id);

ALTER TABLE ONLY public.companies
    ADD CONSTRAINT vt_pk_c37b42fe24009eca08260a3f4ae04e1c PRIMARY KEY (id);

ALTER TABLE ONLY public.leads
    ADD CONSTRAINT vt_pk_c80c5863244cc35ab960f4dfbd32cf17 PRIMARY KEY (id);

ALTER TABLE ONLY public.users
    ADD CONSTRAINT vt_uq_10292275116667a4cb37592c31190a5e UNIQUE (company_id, id);

ALTER TABLE ONLY public.memberships
    ADD CONSTRAINT vt_uq_2ad0bcba005223984ee5a30c2cc7594b UNIQUE (company_id, id);

ALTER TABLE ONLY public.leads
    ADD CONSTRAINT vt_uq_42a25356531b11d1e4d5decf7a0e1e24 UNIQUE (company_id, id);

ALTER TABLE ONLY public.dealers
    ADD CONSTRAINT vt_uq_dec744303aacdbb8492f2eaa3c88bead UNIQUE (company_id, id);

ALTER TABLE ONLY public.memberships
    ADD CONSTRAINT vt_uq_f193c8e4d9da74f0e30aad2549ccca62 UNIQUE (company_id, user_id, dealer_id, role);

CREATE INDEX vt_ix_507afec86a6c207e0ca28dd203ffb300 ON public.leads USING btree (company_id, status);

CREATE INDEX vt_ix_5d662343cb5148e8d65b15809c1e3c37 ON public.leads USING btree (company_id, dealer_id);

CREATE INDEX vt_ix_ba6fa65b14061f8852d348fd2cc40b43 ON public.memberships USING btree (company_id, dealer_id);

CREATE INDEX vt_ix_f72a7756af1519cd4c2c3c51d5ec8b22 ON public.leads USING btree (company_id, seller_id);

ALTER TABLE ONLY public.memberships
    ADD CONSTRAINT vt_fk_057ae10e2c51523cc3a35350d3d8ed01 FOREIGN KEY (company_id, user_id) REFERENCES public.users(company_id, id) DEFERRABLE;

ALTER TABLE ONLY public.memberships
    ADD CONSTRAINT vt_fk_23e2862edd3ae0c1190f4dc21edfe150 FOREIGN KEY (company_id) REFERENCES public.companies(id) DEFERRABLE;

ALTER TABLE ONLY public.leads
    ADD CONSTRAINT vt_fk_70eb50f95e008e03c285c62b8baf5678 FOREIGN KEY (company_id) REFERENCES public.companies(id) DEFERRABLE;

ALTER TABLE ONLY public.memberships
    ADD CONSTRAINT vt_fk_7211b73e05e6868b82aaee0448e1153b FOREIGN KEY (company_id, dealer_id) REFERENCES public.dealers(company_id, id) DEFERRABLE;

ALTER TABLE ONLY public.leads
    ADD CONSTRAINT vt_fk_8b878e59781167f0360b2f869fcdf0af FOREIGN KEY (company_id, dealer_id) REFERENCES public.dealers(company_id, id) DEFERRABLE;

ALTER TABLE ONLY public.dealers
    ADD CONSTRAINT vt_fk_9b6e67cc348ce3c83008af98c8e65744 FOREIGN KEY (company_id) REFERENCES public.companies(id) DEFERRABLE;

ALTER TABLE ONLY public.users
    ADD CONSTRAINT vt_fk_ac86ccd4650187b1da6ac46730cc6d13 FOREIGN KEY (company_id) REFERENCES public.companies(id) DEFERRABLE;

ALTER TABLE ONLY public.leads
    ADD CONSTRAINT vt_fk_f0816bdf4c58bac7b3046779037a72d2 FOREIGN KEY (company_id, seller_id) REFERENCES public.users(company_id, id) DEFERRABLE;

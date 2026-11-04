-- Retrato do esquema: resultado de aplicar db/plans/ num banco vazio (vetra db:plan --snapshot).
-- Gerado a partir do pg_dump --schema-only --no-owner normalizado; não edite à mão.

CREATE TABLE public.companies (
    created_at timestamp(6) with time zone NOT NULL,
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name text NOT NULL
);

CREATE TABLE public.leads (
    company_id uuid NOT NULL,
    created_at timestamp(6) with time zone NOT NULL,
    email text,
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name text NOT NULL,
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

ALTER TABLE ONLY public.companies
    ADD CONSTRAINT vt_pk_c37b42fe24009eca08260a3f4ae04e1c PRIMARY KEY (id);

ALTER TABLE ONLY public.leads
    ADD CONSTRAINT vt_pk_c80c5863244cc35ab960f4dfbd32cf17 PRIMARY KEY (id);

ALTER TABLE ONLY public.leads
    ADD CONSTRAINT vt_uq_42a25356531b11d1e4d5decf7a0e1e24 UNIQUE (company_id, id);

CREATE INDEX vt_ix_507afec86a6c207e0ca28dd203ffb300 ON public.leads USING btree (company_id, status);

ALTER TABLE ONLY public.leads
    ADD CONSTRAINT vt_fk_70eb50f95e008e03c285c62b8baf5678 FOREIGN KEY (company_id) REFERENCES public.companies(id) DEFERRABLE;

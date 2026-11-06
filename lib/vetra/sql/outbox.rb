# frozen_string_literal: true

require 'digest'

module Vetra
  module SQL
    # Armazenamento da outbox (ADR-024, §3, e ADR-040, §§ 1, 2 e 5): tabelas particionadas por tempo, partições
    # DEFAULT, entregas mortas fora da purga e a concessão de INSERT por coluna para a aplicação. Só existe numa
    # aplicação com eventos; o relay e a manutenção (ADR-040, §§ 3 e 4) são de outra tarefa.
    class Outbox
      TABLES = %w[outbox outbox_default deliveries deliveries_default dead_deliveries].freeze
      # Colunas que a aplicação grava. created_at, xid8 e seq vêm do banco (ADR-040, §1).
      APP_COLUMNS = %w[event_id event version tenant_id actor_id op_id cmd payload].freeze
      TIMESTAMP = 'timestamp(6) with time zone'
      NOW = 'pg_catalog.statement_timestamp()'
      NAME = %q{'^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$'}

      def self.needed?(document)
        document.is_a?(Hash) && document.fetch('nodes', []).any? { |node| node['kind'] == 'event' }
      end

      def initialize(schema)
        @document = schema.document
        @tenant = @document.dig('app', 'tenant')
        root = schema.tables.find { |table| table['scope'] == 'tenant_root' }
        @tenant_type = root ? root['columns'].find { |column| column['name'] == 'id' }.fetch('type') : 'uuid'
      end

      # Uma instrução por passo, na ordem: tabelas, partições, índices, donos, revogações, RLS, política e concessão.
      def statements
        return [] unless self.class.needed?(@document)
        tables + indexes + TABLES.flat_map { |name| protection(name) } + [policy, grant]
      end

      # Os SHA-256 das instruções, que o Differ usa para separar a seção da outbox das demais.
      def digests
        statements.map { |sql| Digest::SHA256.hexdigest(sql) }
      end

      private

      def quote(name)
        Context.quote(name)
      end

      def relation(name)
        "#{quote('vetra')}.#{quote(name)}"
      end

      def tables
        [<<~SQL.chomp,
          CREATE TABLE #{relation('outbox')} (
            "created_at" #{TIMESTAMP} NOT NULL DEFAULT #{NOW},
            "xid8" pg_catalog.xid8 NOT NULL DEFAULT pg_catalog.pg_current_xact_id(),
            "seq" bigint GENERATED ALWAYS AS IDENTITY,
            "event_id" uuid NOT NULL,
            "event" text NOT NULL CHECK ("event" ~ #{NAME}),
            "version" integer NOT NULL CHECK ("version" > 0),
            "tenant_id" #{@tenant_type},
            "actor_id" uuid,
            "op_id" uuid NOT NULL,
            "cmd" text NOT NULL CHECK (pg_catalog.char_length("cmd") BETWEEN 1 AND 255),
            "payload" jsonb NOT NULL CHECK (pg_catalog.jsonb_typeof("payload") = 'object'),
            PRIMARY KEY ("created_at", "xid8", "seq")
          ) PARTITION BY RANGE ("created_at");
        SQL
         "CREATE TABLE #{relation('outbox_default')} PARTITION OF #{relation('outbox')} DEFAULT;",
         <<~SQL.chomp,
           CREATE TABLE #{relation('deliveries')} (
             "event_created_at" #{TIMESTAMP} NOT NULL,
             "event_xid8" pg_catalog.xid8 NOT NULL,
             "event_seq" bigint NOT NULL,
             "event_id" uuid NOT NULL,
             "handler" text NOT NULL CHECK ("handler" ~ #{NAME}),
             "tenant_id" #{@tenant_type},
             "state" text NOT NULL DEFAULT 'pending' CHECK ("state" IN ('pending', 'done', 'dead')),
             "attempts" integer NOT NULL DEFAULT 0 CHECK ("attempts" >= 0),
             "run_after" #{TIMESTAMP} NOT NULL DEFAULT #{NOW},
             "leased_until" #{TIMESTAMP},
             "last_error" text,
             "created_at" #{TIMESTAMP} NOT NULL DEFAULT #{NOW},
             "updated_at" #{TIMESTAMP} NOT NULL DEFAULT #{NOW},
             PRIMARY KEY ("handler", "event_id", "event_created_at")
           ) PARTITION BY RANGE ("event_created_at");
         SQL
         "CREATE TABLE #{relation('deliveries_default')} PARTITION OF #{relation('deliveries')} DEFAULT;",
         <<~SQL.chomp]
           CREATE TABLE #{relation('dead_deliveries')} (
             "handler" text NOT NULL CHECK ("handler" ~ #{NAME}),
             "event_id" uuid NOT NULL,
             "event_created_at" #{TIMESTAMP} NOT NULL,
             "event_xid8" pg_catalog.xid8 NOT NULL,
             "event_seq" bigint NOT NULL,
             "event" text NOT NULL CHECK ("event" ~ #{NAME}),
             "version" integer NOT NULL CHECK ("version" > 0),
             "tenant_id" #{@tenant_type},
             "payload" jsonb NOT NULL CHECK (pg_catalog.jsonb_typeof("payload") = 'object'),
             "attempts" integer NOT NULL CHECK ("attempts" >= 0),
             "last_error" text,
             "died_at" #{TIMESTAMP} NOT NULL DEFAULT #{NOW},
             PRIMARY KEY ("handler", "event_id")
           );
         SQL
      end

      def indexes
        # Nascem com as tabelas: o PostgreSQL não cria índice CONCURRENTLY numa tabela particionada (ADR-040, §1).
        ["CREATE INDEX #{quote('vt_outbox_relay')} ON #{relation('outbox')} (\"xid8\", \"seq\");",
         "CREATE INDEX #{quote('vt_deliveries_ready')} ON #{relation('deliveries')} (\"run_after\") WHERE \"state\" = 'pending';"]
      end

      # Dono, nenhuma concessão herdada de PUBLIC e RLS forçado sem política: nega tudo a quem não tiver política.
      def protection(name)
        ["ALTER TABLE #{relation(name)} OWNER TO #{quote('vetra_owner')};",
         "REVOKE ALL ON TABLE #{relation(name)} FROM PUBLIC, #{quote('vetra_app')};",
         "ALTER TABLE #{relation(name)} ENABLE ROW LEVEL SECURITY;",
         "ALTER TABLE #{relation(name)} FORCE ROW LEVEL SECURITY;"]
      end

      def policy
        check = if @tenant
          # IS NOT DISTINCT FROM: o ator de sistema de um handler não tem actor_id (ADR-024, §4, decisão 2).
          '"tenant_id" = (SELECT vetra.current_tenant()) AND "actor_id" IS NOT DISTINCT FROM (SELECT vetra.current_actor())'
        else
          '"tenant_id" IS NULL'
        end
        "CREATE POLICY #{quote('vt_outbox_insert')} ON #{relation('outbox')} AS PERMISSIVE FOR INSERT TO #{quote('vetra_app')} WITH CHECK (#{check});"
      end

      def grant
        columns = APP_COLUMNS.map { |name| quote(name) }.join(', ')
        "GRANT INSERT (#{columns}) ON TABLE #{relation('outbox')} TO #{quote('vetra_app')};"
      end
    end
  end
end

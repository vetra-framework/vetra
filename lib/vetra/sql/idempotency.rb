# frozen_string_literal: true

require 'digest'

module Vetra
  module SQL
    # Registro de idempotência da operação (ADR-016, ADR-043): a tabela `vetra.idempotency`, a chave única
    # `(tenant, comando, chave)` com `NULLS NOT DISTINCT` (o tenant é nulo no contexto global), o RLS de tenant, as
    # concessões mínimas da aplicação e o acesso do papel de manutenção (`vetra_relay`) para a purga. Existe em toda
    # aplicação; só a origem `event` (chave derivada de um evento) existe numa aplicação com outbox.
    class Idempotency
      TABLE = 'idempotency'
      KEY_CONSTRAINT = 'vt_idempotency_key'
      PURGE_INDEX = 'vt_idempotency_purge'
      # Colunas que a aplicação grava; o resultado entra por UPDATE, depois da execução (ADR-043, §3). created_at e id
      # vêm do banco.
      APP_COLUMNS = %w[tenant_id command key origin principal input_hash handler event_id event_created_at].freeze
      # Teto do resultado guardado, em bytes do JSON (ADR-043, §4).
      RESULT_LIMIT = 65_536
      TIMESTAMP = 'timestamp(6) with time zone'
      NOW = 'pg_catalog.statement_timestamp()'

      def initialize(schema)
        @document = schema.document
        @tenant = @document&.dig('app', 'tenant')
        root = schema.tables.find { |table| table['scope'] == 'tenant_root' }
        @tenant_type = root ? root['columns'].find { |column| column['name'] == 'id' }.fetch('type') : 'uuid'
        @events = Outbox.needed?(@document)
      end

      # Uma instrução por passo, na ordem: guarda do papel, tabela, índice, proteção, políticas e concessões. Numa aplicação
      # com outbox, a guarda do papel de manutenção e o USAGE do schema já vêm da seção do relay (ADR-040), que a precede no
      # plano: repeti-los daria instruções idênticas nas duas seções e confundiria o Differ, que as separa pelo texto exato.
      def statements
        [*(@events ? [] : [Context.relay_guard]), table, index, *protection, *policies, *grants]
      end

      # Os SHA-256 das instruções, que o Differ usa para separar a seção das demais.
      def digests
        statements.map { |sql| Digest::SHA256.hexdigest(sql) }
      end

      private

      def quote(name)
        Context.quote(name)
      end

      def relation
        "#{quote('vetra')}.#{quote(TABLE)}"
      end

      def origins
        @events ? "'adapter', 'event'" : "'adapter'"
      end

      def table
        <<~SQL.chomp
          CREATE TABLE #{relation} (
            "id" bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
            "tenant_id" #{@tenant_type},
            "command" text NOT NULL CHECK (pg_catalog.char_length("command") BETWEEN 1 AND 255),
            "key" text NOT NULL CHECK ("key" ~ '^[!-~]{1,255}$'),
            "origin" text NOT NULL CHECK ("origin" IN (#{origins})),
            "principal" text CHECK ("principal" IS NULL OR pg_catalog.char_length("principal") BETWEEN 1 AND 160),
            "input_hash" bytea NOT NULL CHECK (pg_catalog.octet_length("input_hash") = 32),
            "result" jsonb CHECK ("result" IS NULL OR pg_catalog.octet_length("result"::text) <= #{RESULT_LIMIT}),
            "handler" text,
            "event_id" uuid,
            "event_created_at" #{TIMESTAMP},
            "created_at" #{TIMESTAMP} NOT NULL DEFAULT #{NOW},
            CONSTRAINT #{quote(KEY_CONSTRAINT)} UNIQUE NULLS NOT DISTINCT ("tenant_id", "command", "key"),
            CONSTRAINT #{quote('vt_idempotency_origin')} CHECK (
              ("origin" = 'event' AND "handler" IS NOT NULL AND "event_id" IS NOT NULL AND "event_created_at" IS NOT NULL)
              OR ("origin" = 'adapter' AND "handler" IS NULL AND "event_id" IS NULL AND "event_created_at" IS NULL))
          );
        SQL
      end

      # A purga varre por origem e idade; a chave única já cobre a busca da operação.
      def index
        "CREATE INDEX #{quote(PURGE_INDEX)} ON #{relation} (\"origin\", \"created_at\");"
      end

      # Dono, nenhuma concessão herdada e RLS forçado: quem não tiver política não vê nada.
      def protection
        ["ALTER TABLE #{relation} OWNER TO #{quote('vetra_owner')};",
         "REVOKE ALL ON TABLE #{relation} FROM PUBLIC, #{quote('vetra_app')}, #{quote('vetra_relay')};",
         "ALTER TABLE #{relation} ENABLE ROW LEVEL SECURITY;",
         "ALTER TABLE #{relation} FORCE ROW LEVEL SECURITY;"]
      end

      def policies
        # O tenant do contexto (o ator de sistema também tem tenant); numa aplicação global, só a linha sem tenant.
        check = @tenant ? '"tenant_id" = (SELECT vetra.current_tenant())' : '"tenant_id" IS NULL'
        [
          "CREATE POLICY #{quote('vt_idempotency_app')} ON #{relation} AS PERMISSIVE FOR ALL TO #{quote('vetra_app')} USING (#{check}) WITH CHECK (#{check});",
          "CREATE POLICY #{quote('vt_idempotency_relay')} ON #{relation} AS PERMISSIVE FOR ALL TO #{quote('vetra_relay')} USING (true) WITH CHECK (true);"
        ]
      end

      # A aplicação lê, grava a chave e só atualiza o resultado; nunca apaga. A purga é do papel de manutenção.
      def grants
        columns = APP_COLUMNS.map { |name| quote(name) }.join(', ')
        ["GRANT SELECT ON TABLE #{relation} TO #{quote('vetra_app')};",
         "GRANT INSERT (#{columns}) ON TABLE #{relation} TO #{quote('vetra_app')};",
         "GRANT UPDATE (#{quote('result')}) ON TABLE #{relation} TO #{quote('vetra_app')};",
         *(@events ? [] : ["GRANT USAGE ON SCHEMA #{quote('vetra')} TO #{quote('vetra_relay')};"]),
         "GRANT SELECT, DELETE ON TABLE #{relation} TO #{quote('vetra_relay')};"]
      end
    end
  end
end

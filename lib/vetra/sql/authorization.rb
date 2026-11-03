require 'digest'

module Vetra
  module SQL
    class Authorization
      Result = Struct.new(:sql, :tables, :warnings, keyword_init: true)

      def initialize(document, schema: 'vetra', owner_role: 'vetra_owner', app_role: 'vetra_app')
        @document = Graph::Data.copy(document)
        @schema, @owner, @app = schema, owner_role, app_role
      end

      def generate
        warnings = Graph::Validator.new.validate!(@document)
        [@schema, @owner, @app].each { |name| identifier!(name) }
        if @owner == @app || @schema.start_with?('pg_') || @schema == 'information_schema'
          raise Graph::Error.single('authz_roles', 'Use papéis distintos e um schema de infraestrutura fora dos schemas reservados.')
        end
        tenant = @document.dig('app', 'tenant', 'entity', 'id')
        raise Graph::Error.single('authz_tenant', 'O bootstrap de revisão exige tenant explícito; aplicações globais ainda não são suportadas.', pointer: '/app/tenant') unless tenant
        entities = @document['nodes'].select { |node| node['kind'] == 'entity' }.to_h { |node| [node['id'], node] }
        @root = entities.fetch(tenant)
        ids = [tenant] + @document['nodes'].select { |node| node['kind'] == 'policy' }.flat_map { |node| node['reads'].map { |ref| ref['id'] } }
        tables = ids.uniq.sort.map do |id|
          entity = entities.fetch(id)
          column = if id == tenant
            'id'
          elsif entity.dig('tenant', 'entity', 'id') == tenant
            entity.dig('tenant', 'field')
          end
          storage = entity['storage']
          [storage['schema'], storage['table'], column].each { |name| identifier!(name) }
          { 'entity' => id, 'schema' => storage['schema'], 'table' => storage['table'], 'tenant_column' => column }
        end
        if @root.dig('storage', 'primary_key') != ['id'] || tables.any? { |table| table['schema'] == @schema } || tables.map { |table| table.values_at('schema', 'table') }.uniq.size != tables.size
          raise Graph::Error.single('authz_storage', 'Use raiz com PK id, tabelas físicas distintas e schema de infraestrutura separado das tabelas da aplicação.')
        end
        @tables = tables.sort_by { |table| table.values_at('schema', 'table') }
        sql = [header, 'BEGIN;', "SET LOCAL lock_timeout = '3s';", 'SET LOCAL search_path = pg_catalog, pg_temp;', role_guards,
               "LOCK TABLE #{@tables.map { |table| "ONLY #{relation(table)}" }.join(', ')} IN SHARE ROW EXCLUSIVE MODE;",
               storage_guards, infrastructure, *@tables.map { |table| triggers(table) }, privilege_guards,
               "-- Varredura da raiz do tenant para preencher revisões iniciais.",
               "INSERT INTO #{revisions} (tenant_id, revision) SELECT #{quote('id')}::text, 0 FROM #{root_relation};", 'COMMIT;', ''].join("\n")
        Graph::Data.freeze(Result.new(sql: sql, tables: @tables, warnings: warnings))
      end

      private

      def identifier!(name)
        unless name.is_a?(String) && name.match?(/\A[a-z][a-z0-9_]*\z/) && name.bytesize <= 63
          raise Graph::Error.single('authz_identifier', 'Identificadores SQL exigem letras minúsculas, números ou sublinhado, começam por letra e têm até 63 bytes.')
        end
      end

      def quote(name)
        %Q{"#{name}"}
      end

      def literal(value)
        "'#{value.gsub("'", "''")}'"
      end

      def relation(table)
        "#{quote(table['schema'])}.#{quote(table['table'])}"
      end

      def root_relation
        relation(@root['storage'])
      end

      def revisions
        "#{quote(@schema)}.#{quote('authz_revisions')}"
      end

      def header
        (["-- Vetra: bootstrap de revisão de autorização; SQL para revisão, sem aplicação automática.",
          "-- Grafo #{@document['digest']}; aplicação #{JSON.generate(@document.dig('app', 'name'))}.",
          '-- Requer PostgreSQL 17+, tabelas existentes, papéis existentes e schema de infraestrutura novo.',
          '-- Instalação: bloqueia escritas com SHARE ROW EXCLUSIVE; lock_timeout = 3s; lê os IDs da raiz.'] +
          @tables.map { |table| "-- #{table['entity']}: #{relation(table)}; tenant pela coluna #{quote(table['tenant_column'])}." }).join("\n")
      end

      def role_guards
        <<~SQL
          DO $vetra_roles$
          BEGIN
            IF current_setting('server_version_num')::integer < 170000 THEN
              RAISE EXCEPTION 'Vetra exige PostgreSQL 17 ou superior';
            END IF;
            IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = #{literal(@owner)} AND NOT rolcanlogin AND NOT rolsuper AND NOT rolbypassrls AND NOT rolcreaterole) THEN
              RAISE EXCEPTION 'Proprietário deve existir, sem LOGIN, SUPERUSER, BYPASSRLS ou CREATEROLE';
            END IF;
            IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = #{literal(@app)} AND NOT rolsuper AND NOT rolbypassrls AND NOT rolcreaterole) THEN
              RAISE EXCEPTION 'Aplicação deve existir, sem SUPERUSER, BYPASSRLS ou CREATEROLE';
            END IF;
            IF pg_has_role(#{literal(@app)}, #{literal(@owner)}, 'MEMBER') THEN
              RAISE EXCEPTION 'Aplicação não pode pertencer ao papel proprietário';
            END IF;
            IF EXISTS (SELECT 1 FROM #{assumable_roles} AND (r.rolsuper OR r.rolbypassrls OR r.rolcreaterole)) THEN
              RAISE EXCEPTION 'Aplicação não pode assumir por SET ROLE papel com SUPERUSER, BYPASSRLS ou CREATEROLE';
            END IF;
            -- Com ADMIN OPTION utilizável, a aplicação concederia a si própria um papel que hoje não pode assumir.
            -- Só conta o ADMIN utilizável: um vínculo INHERIT FALSE, SET FALSE não o empresta.
            IF EXISTS (SELECT 1 FROM pg_auth_members m WHERE m.admin_option AND #{usable('m.member')}) THEN
              RAISE EXCEPTION 'Aplicação não pode administrar papéis (ADMIN OPTION) diretamente, por herança ou por SET ROLE';
            END IF;
            -- O aplicador da replicação lógica não dispara triggers por instrução, nem ENABLE ALWAYS.
            IF #{usable("'pg_create_subscription'::regrole")}
               OR EXISTS (SELECT 1 FROM pg_subscription s WHERE #{usable('s.subowner')}) THEN
              RAISE EXCEPTION 'Aplicação não pode criar nem possuir subscriptions de replicação lógica';
            END IF;
            -- Executar programas ou ler e gravar arquivos do servidor contorna as permissões SQL.
            IF EXISTS (SELECT 1 FROM pg_roles p WHERE p.rolname IN ('pg_execute_server_program', 'pg_write_server_files', 'pg_read_server_files')
               AND #{usable('p.oid')}) THEN
              RAISE EXCEPTION 'Aplicação não pode usar pg_execute_server_program, pg_write_server_files ou pg_read_server_files';
            END IF;
          END $vetra_roles$;
        SQL
      end

      def storage_guards
        checks = @tables.map do |table|
          path = literal(relation(table))
          column = literal(table['tenant_column'])
          <<~SQL
            IF NOT EXISTS (SELECT 1 FROM pg_class WHERE oid = #{path}::regclass AND relkind = 'r' AND NOT relispartition)
               OR EXISTS (SELECT 1 FROM pg_inherits WHERE inhrelid = #{path}::regclass OR inhparent = #{path}::regclass) THEN
              RAISE EXCEPTION 'Tabelas particionadas ou herdadas não são suportadas: %', #{path};
            END IF;
            IF NOT EXISTS (SELECT 1 FROM pg_attribute a JOIN pg_attribute root ON root.attrelid = #{literal(root_relation)}::regclass AND root.attname = 'id'
              WHERE a.attrelid = #{path}::regclass AND a.attname = #{column} AND NOT a.attisdropped AND NOT root.attisdropped
                AND a.attnotnull AND root.attnotnull AND a.atttypid = root.atttypid AND a.atttypmod = root.atttypmod
                AND root.atttypid IN ('uuid'::regtype, 'text'::regtype, 'varchar'::regtype, 'bpchar'::regtype, 'int2'::regtype, 'int4'::regtype, 'int8'::regtype)) THEN
              RAISE EXCEPTION 'Coluna de tenant ausente, nula ou de tipo incompatível: %.%', #{path}, #{column};
            END IF;
            IF EXISTS (SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE c.oid = #{path}::regclass
              AND (pg_has_role(#{literal(@app)}, c.relowner, 'MEMBER') OR pg_has_role(#{literal(@app)}, n.nspowner, 'MEMBER'))) THEN
              RAISE EXCEPTION 'Aplicação não pode possuir tabela protegida ou seu schema: %', #{path};
            END IF;
          SQL
        end
        <<~SQL
          DO $vetra_tables$
          BEGIN
            IF NOT EXISTS (SELECT 1 FROM pg_index i JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attname = 'id'
              WHERE i.indrelid = #{literal(root_relation)}::regclass AND i.indisprimary AND i.indnatts = 1 AND i.indkey[0] = a.attnum) THEN
              RAISE EXCEPTION 'Raiz do tenant deve ter chave primária simples em id';
            END IF;
          #{checks.join}
          END $vetra_tables$;
        SQL
      end

      def infrastructure
        <<~SQL
          CREATE SCHEMA #{quote(@schema)} AUTHORIZATION #{quote(@owner)};
          CREATE TABLE #{revisions} (tenant_id text PRIMARY KEY, revision bigint NOT NULL CHECK (revision >= 0));
          ALTER TABLE #{revisions} OWNER TO #{quote(@owner)};
          REVOKE ALL ON #{revisions} FROM PUBLIC, #{quote(@app)};
          GRANT USAGE ON SCHEMA #{quote(@schema)} TO #{quote(@app)};
          GRANT SELECT ON #{revisions} TO #{quote(@app)};
        SQL
      end

      def triggers(table)
        suffix = Digest::SHA256.hexdigest([@document.dig('app', 'name'), table['entity']].join("\0"))[0, 24]
        column = quote(table['tenant_column'])
        {
          'insert' => ['NEW TABLE AS vt_new', "SELECT DISTINCT #{column}::text AS tenant_id FROM vt_new ORDER BY tenant_id"],
          'delete' => ['OLD TABLE AS vt_old', "SELECT DISTINCT #{column}::text AS tenant_id FROM vt_old ORDER BY tenant_id"],
          'update' => ['OLD TABLE AS vt_old NEW TABLE AS vt_new', "SELECT #{column}::text AS tenant_id FROM vt_old UNION SELECT #{column}::text AS tenant_id FROM vt_new ORDER BY tenant_id"]
        }.map do |event, (references, tenants)|
          name = quote("vt_authz_#{suffix}_#{event}")
          function = "#{quote(@schema)}.#{name}"
          <<~SQL
            CREATE FUNCTION #{function}() RETURNS trigger LANGUAGE plpgsql
              SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $vetra_authz$
            DECLARE affected_tenant text;
            BEGIN
              FOR affected_tenant IN #{tenants} LOOP
                INSERT INTO #{revisions} AS stored (tenant_id, revision) VALUES (affected_tenant, 1)
                  ON CONFLICT (tenant_id) DO UPDATE SET revision = stored.revision + 1;
                PERFORM pg_notify('vetra_authz', affected_tenant);
              END LOOP;
              RETURN NULL;
            END $vetra_authz$;
            ALTER FUNCTION #{function}() OWNER TO #{quote(@owner)};
            REVOKE ALL ON FUNCTION #{function}() FROM PUBLIC, #{quote(@app)};
            CREATE TRIGGER #{name} AFTER #{event.upcase} ON #{relation(table)}
              REFERENCING #{references} FOR EACH STATEMENT EXECUTE FUNCTION #{function}();
            -- ALWAYS: dispara também com session_replication_role = replica, que suprime triggers comuns.
            ALTER TABLE #{relation(table)} ENABLE ALWAYS TRIGGER #{name};
          SQL
        end.join + "REVOKE TRUNCATE, TRIGGER, REFERENCES ON #{relation(table)} FROM PUBLIC, #{quote(@app)};\n"
      end

      # Papéis cujos privilégios a aplicação tem ou pode obter: ela própria, os herdados e os alcançáveis por SET ROLE,
      # inclusive concessões com INHERIT FALSE, que has_*_privilege(app, ...) não enxerga.
      def assumable_roles
        "pg_roles r WHERE pg_has_role(#{literal(@app)}, r.oid, 'SET')"
      end

      # Papel cujos poderes a aplicação usa de fato: herdado por algum papel que ela pode assumir (inclusive ela
      # própria). Depois de SET ROLE, valem as heranças do papel assumido, e não só as da aplicação.
      def usable(role)
        "EXISTS (SELECT 1 FROM pg_roles a WHERE pg_has_role(#{literal(@app)}, a.oid, 'SET') AND pg_has_role(a.oid, #{role}, 'USAGE'))"
      end

      def privilege_guards
        checks = @tables.map do |table|
          <<~SQL
            IF EXISTS (SELECT 1 FROM #{assumable_roles} AND (has_table_privilege(r.oid, #{literal(relation(table))}, 'TRUNCATE,TRIGGER')
              OR has_any_column_privilege(r.oid, #{literal(relation(table))}, 'REFERENCES'))) THEN
              RAISE EXCEPTION 'Privilégios herdados ou assumíveis por SET ROLE de TRUNCATE/TRIGGER/REFERENCES ainda permitem alterar a invalidação';
            END IF;
          SQL
        end
        <<~SQL
          DO $vetra_privileges$
          BEGIN
          #{checks.join}
            IF EXISTS (SELECT 1 FROM #{assumable_roles} AND has_schema_privilege(r.oid, #{literal(@schema)}, 'CREATE')) THEN
              RAISE EXCEPTION 'Privilégio herdado ou assumível por SET ROLE permite criar objetos na infraestrutura';
            END IF;
            IF EXISTS (SELECT 1 FROM #{assumable_roles}
              AND (has_table_privilege(r.oid, #{literal(revisions)}, 'INSERT,UPDATE,DELETE,TRUNCATE,TRIGGER,REFERENCES')
                OR has_any_column_privilege(r.oid, #{literal(revisions)}, 'INSERT,UPDATE,REFERENCES'))) THEN
              RAISE EXCEPTION 'Privilégio herdado ou assumível por SET ROLE permite escrita nas revisões';
            END IF;
            IF EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
              WHERE n.nspname = #{literal(@schema)} AND EXISTS (SELECT 1 FROM #{assumable_roles} AND has_function_privilege(r.oid, p.oid, 'EXECUTE'))) THEN
              RAISE EXCEPTION 'Execução herdada ou assumível por SET ROLE das funções de revisão não é permitida';
            END IF;
          END $vetra_privileges$;
        SQL
      end
    end
  end
end

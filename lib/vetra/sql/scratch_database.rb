# frozen_string_literal: true

require 'open3'
require 'securerandom'

module Vetra
  module SQL
    # Banco descartável para aplicar planos e tirar o retrato (ADR-025, §1). Cria um banco novo a partir do
    # template0 no servidor de DATABASE_URL, aplica os planos, roda o pg_dump e remove o banco, mesmo numa falha.
    # Nunca altera o banco nomeado na URL.
    class ScratchDatabase
      # Parâmetros efetivos da conexão temporária que o pg_dump recebe em --dbname; a senha vai só pelo ambiente.
      DUMP_KEYS = %w[host hostaddr port user dbname options target_session_attrs sslmode sslrootcert sslcert sslkey sslcrl
                     sslnegotiation gssencmode channel_binding require_auth krbsrvname connect_timeout].freeze
      # Variáveis herdadas que poderiam levar o pg_dump a outro servidor ou banco (PGSERVICE completa o que falta).
      CLEARED_ENV = %w[PGSERVICE PGSERVICEFILE PGHOST PGHOSTADDR PGPORT PGDATABASE PGUSER PGPASSWORD PGOPTIONS PGSSLMODE
                       PGSSLROOTCERT PGSSLCERT PGSSLKEY PGTARGETSESSIONATTRS PGREQUIRESSL].freeze
      DROPPED = [/\A--/, /\ASET /, /\ASELECT pg_catalog\.set_config\(/, /\A\\(restrict|unrestrict) /].freeze

      def initialize(url:, pg_dump: 'pg_dump', driver: -> { require 'pg' })
        @url, @pg_dump, @driver = url, pg_dump, driver
      end

      def apply_and_dump(plans)
        load_driver!
        admin = connect(@url)
        admin.exec('SET client_min_messages = warning')
        self.class.check_pg_dump!(pg_dump_version, admin.server_version / 10_000)
        name = "vetra_plan_#{SecureRandom.hex(6)}"
        admin.exec("CREATE DATABASE #{name} TEMPLATE template0 ENCODING 'UTF8' LOCALE 'C'")
        begin
          # O banco temporário só existe no servidor em que a conexão administrativa entrou: com vários hosts na URL,
          # a conexão a ele e o pg_dump ficam fixos nesse servidor.
          connection = connect(params.merge('dbname' => name, 'host' => admin.host, 'port' => admin.port.to_s,
                                            'hostaddr' => admin.hostaddr.to_s))
          connection.exec('SET client_min_messages = warning')
          PlanExecutor.new(connection).apply(plans)
          # O pg_dump usa os parâmetros que a conexão temporária de fato resolveu, para ler o mesmo banco.
          # Com vários hosts na URL, fixa o servidor em que a conexão entrou, em vez de deixar o pg_dump escolher outro.
          effective = connection.conninfo_hash.transform_keys(&:to_s)
          effective.merge!('host' => connection.host, 'port' => connection.port.to_s, 'hostaddr' => connection.hostaddr.to_s)
          connection.close
          connection = nil
          self.class.normalize_dump(dump(effective))
        ensure
          connection&.close
          admin.exec("DROP DATABASE IF EXISTS #{name} WITH (FORCE)")
        end
      ensure
        admin&.close
      end

      # O pg_dump precisa ser da mesma versão principal do servidor: um mais antigo recusa o servidor, e um mais novo
      # pode escrever o mesmo esquema de outro jeito, o que faria o retrato depender de quem o gerou.
      def self.check_pg_dump!(version_output, server_major)
        client_major = version_output[/\Apg_dump \(PostgreSQL\) (\d+)/, 1]&.to_i
        return if client_major == server_major
        raise Graph::Error.single('db_pg_dump', "pg_dump #{client_major || 'desconhecido'} não corresponde ao servidor PostgreSQL #{server_major}; " \
                                                "aponte VETRA_PG_DUMP para o pg_dump #{server_major}.")
      end

      # Tira do dump o que depende de quem e quando o gerou (comentários com versões, SET de sessão e as linhas
      # \restrict com chave aleatória) e junta linhas vazias repetidas, mas só entre instruções: uma linha dentro de um
      # literal ou corpo de função fica intacta, para que o retrato não esconda diferença de esquema, privilégio ou RLS.
      def self.normalize_dump(text)
        kept, scanner = [], StatementScanner.new
        # Tira só o LF de cada linha: um CR dentro de um literal é dado e precisa sobreviver no retrato.
        text.each_line do |raw|
          line = raw.delete_suffix("\n")
          if scanner.boundary?
            next if DROPPED.any? { |pattern| pattern.match?(line) }
            next if line.strip.empty? && (kept.empty? || kept.last.empty?)
            next kept << '' if line.strip.empty?
          end
          kept << line
          scanner.feed(line)
        end
        kept.pop while kept.last&.empty?
        "#{kept.join("\n")}\n"
      end

      private

      def load_driver!
        @driver.call
      rescue LoadError
        raise Graph::Error.single('db_driver', 'db:plan --check e --snapshot exigem a gem pg; acrescente-a ao Gemfile da aplicação.')
      end

      # A mensagem do driver pode repetir trechos da URL, inclusive a senha; o diagnóstico só diz a classe e o SQLSTATE.
      def connect(target)
        PG.connect(target)
      rescue PG::Error => e
        raise Graph::Error.single('db_connection', "Não foi possível conectar ao servidor de DATABASE_URL (#{e.class}" \
                                                   "#{" #{e.result&.error_field(PG::PG_DIAG_SQLSTATE)}" if e.respond_to?(:result) && e.result}); confira a URL.")
      end

      def params
        PG::Connection.conninfo_parse(@url).each_with_object({}) { |option, out| out[option[:keyword]] = option[:val] if option[:val] }
      rescue PG::Error => e
        raise Graph::Error.single('db_connection', "DATABASE_URL inválida (#{e.class}); confira a URL.")
      end

      def pg_dump_version
        output, status = Open3.capture2e(@pg_dump, '--version')
        raise Graph::Error.single('db_pg_dump', "#{@pg_dump} --version falhou: #{output.lines.first&.strip}") unless status.success?
        output
      rescue SystemCallError
        raise Graph::Error.single('db_pg_dump', "pg_dump não encontrado (#{@pg_dump}); instale o cliente do PostgreSQL ou defina VETRA_PG_DUMP.")
      end

      def dump(effective)
        environment, arguments = self.class.pg_dump_invocation(effective)
        output, errors, status = Open3.capture3(environment, @pg_dump, *arguments)
        raise Graph::Error.single('db_pg_dump', "pg_dump falhou: #{errors.lines.first&.strip}") unless status.success?
        output.force_encoding(Encoding::UTF_8)
      end

      # Ambiente e argumentos do pg_dump: o banco e o servidor vêm explícitos em --dbname (string de conexão com valores
      # entre aspas), as variáveis PG* herdadas são removidas e a senha, se houver, vai só em PGPASSWORD.
      def self.pg_dump_invocation(effective)
        conninfo = DUMP_KEYS.filter_map do |key|
          value = effective[key]
          "#{key}='#{value.gsub(/['\\]/) { |character| "\\#{character}" }}'" if value && !value.empty?
        end.join(' ')
        environment = CLEARED_ENV.to_h { |name| [name, nil] }
        environment['PGPASSWORD'] = effective['password'] if effective['password'] && !effective['password'].empty?
        [environment, ['--schema-only', '--no-owner', '--dbname', conninfo]]
      end
    end

    # Aplica planos numa conexão, cada plano numa transação com lock_timeout de 3 s (ADR-015, §5). É o executor comum:
    # a K8 acrescenta o registro em vetra.migrations, o lock consultivo e as novas tentativas.
    class PlanExecutor
      def initialize(connection)
        @connection = connection
      end

      def apply(plans)
        plans.each do |plan|
          step = nil
          @connection.exec('BEGIN')
          @connection.exec("SET LOCAL lock_timeout = '3s'")
          plan.steps.each do |current|
            step = current
            @connection.exec(current.sql)
          end
          @connection.exec('COMMIT')
        rescue StandardError => e
          @connection.exec('ROLLBACK') rescue nil
          raise Graph::Error.single('db_plan_apply', "Plano #{plan.file_name}, passo #{step&.number || 0}: #{e.message.lines.first&.strip}")
        end
      end
    end
  end
end

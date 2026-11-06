# frozen_string_literal: true

module Vetra
  module Data
    # Identifica pools cujo login de cada conexão é conferido pela fábrica.
    module RuntimeDatabase; end

    module UnnamedDatasets
      def prepare(*)
        raise Error.single('data_named_statement', 'Vetra Data não permite statements nomeados.')
      end

      def call(*)
        raise Error.single('data_named_statement', 'Vetra Data não permite statements nomeados.')
      end
    end

    module ContextLogging
      # Thread#[] é local à fibra. Não se altera a lista compartilhada de loggers do pool.
      def log_connection_yield(sql, conn, args = nil, &block)
        return yield if Thread.current[:vetra_data_installing_context].equal?(self)

        super
      end
    end

    def self.configure(db)
      unless db.database_type == :postgres && %i[postgres mock].include?(db.adapter_scheme)
        raise Error.single('data_connection', 'Vetra Data exige um pool PostgreSQL com o driver pg.')
      end
      db.extension :pg_auto_parameterize
      db.extend(ContextLogging)
      db.extend_datasets(UnnamedDatasets)
      db
    end

    def self.connect(url, **options)
      # O usuário da URL é sobrescrito; a conferência é repetida em cada conexão do pool.
      db = Sequel.connect(url, **options, user: 'vetra_app', after_connect: method(:check_connection))
      configure(db).extend(RuntimeDatabase)
    rescue StandardError
      db&.disconnect
      raise Error.single('data_connection', 'Não foi possível abrir o pool como vetra_app no PostgreSQL.'), cause: nil
    end

    def self.check_connection(connection)
      unless connection.respond_to?(:exec) && connection.exec(<<~SQL).getvalue(0, 0) == 't'
        SELECT current_user = 'vetra_app' AND session_user = 'vetra_app'
          AND NOT rolsuper AND NOT rolbypassrls
        FROM pg_catalog.pg_roles WHERE rolname = current_user
      SQL
        raise Error.single('data_connection', 'A conexão do runtime deve usar vetra_app sem superusuário nem BYPASSRLS.')
      end
    end
    private_class_method :check_connection
  end
end

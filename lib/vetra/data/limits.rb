# frozen_string_literal: true

module Vetra
  module Data
    # Política operacional do ADR-008, §5. Não configura a sessão nem guarda resultado no pool.
    class Limits
      MAX_TIMEOUT = 120_000 # milissegundos; operações maiores devem ser divididas (ADR-016).
      UNITS = { nil => 1, 'ms' => 1, 's' => 1000, 'min' => 60_000, 'h' => 3_600_000, 'd' => 86_400_000 }.freeze
      private_constant :UNITS

      def self.validate_timeout!(value, positive: false)
        return value if value.is_a?(Integer) && value.between?(positive ? 1 : 0, MAX_TIMEOUT)

        raise Error.single('data_timeout', 'Timeout deve ser inteiro em milissegundos dentro do intervalo permitido.'), cause: nil
      end

      def initialize(transaction_timeout: 30_000, idle_in_transaction_session_timeout: 10_000)
        @ceilings = { transaction_timeout: self.class.validate_timeout!(transaction_timeout, positive: true),
                      idle_in_transaction_session_timeout: self.class.validate_timeout!(idle_in_transaction_session_timeout, positive: true) }.freeze
        freeze
      end

      def verify!(db)
        # Uma instrução na conexão da transação externa, antes do contexto e do call. Nomes são parâmetros;
        # missing_ok cobre servidor sem o GUC. Nova transação relê: SET de sessão/pooler pode mudar o efetivo.
        row = db.select(*@ceilings.keys.map { |name| Sequel.function(:current_setting, name.to_s, true).as(name) }).first
        valid = row && @ceilings.all? do |name, ceiling|
          value = row[name]
          match = value.is_a?(String) && value.ascii_only? && /\A(\d+)(ms|s|min|h|d)?\z/.match(value)
          milliseconds = match && match[1].to_i * UNITS.fetch(match[2])
          milliseconds && milliseconds.between?(1, ceiling)
        end
        return if valid

        raise Error.single('data_limits', 'A unidade exige limites efetivos de transação e ociosidade positivos e dentro dos tetos operacionais.'), cause: nil
      end
    end
  end
end

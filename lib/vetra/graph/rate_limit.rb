module Vetra
  module Graph
    module RateLimit
      FEATURE = 'vetra.rate_limit'
      UNITS = { 's' => 1, 'min' => 60, 'h' => 3600 }.freeze

      def self.parse(value, source:)
        match = value.is_a?(String) && /\A([1-9][0-9]*)\/([1-9][0-9]*)?(s|min|h)\z/.match(value)
        if match
          limit = match[1].to_i
          seconds = (match[2] || '1').to_i * UNITS.fetch(match[3])
          if limit <= Canonical::MAX_INTEGER && seconds <= Canonical::MAX_INTEGER
            return { 'limit' => limit, 'window_seconds' => seconds, 'key' => 'actor_tenant' }
          end
        end
        raise Error.single('rate_limit', 'rate_limit: exige uma string como "5/min" ou "5/2min", com limite e janela inteiros positivos, unidades s, min ou h e valores no intervalo seguro da IR.', pointer: '/rate_limit', source: source)
      end
    end
  end
end

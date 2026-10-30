require "json"
require "digest"

module Vetra
  module Graph
    # RFC 8785 for the IR subset: floats are forbidden, so ECMAScript number
    # rounding is unnecessary. Object keys sort by UTF-16 code units, not UTF-8.
    module Canonical
      MAX_INTEGER = (2**53) - 1

      module_function

      def parse(bytes)
        JSON.parse(bytes, allow_duplicate_key: false, create_additions: false, allow_nan: false)
      rescue JSON::ParserError, EncodingError, ArgumentError => e
        raise Error.single("invalid_json", "JSON inválido (#{e.class}).")
      end

      def dump(value)
        case value
        when Hash
          unless value.keys.all? { |key| key.is_a?(String) }
            raise Error.single("invalid_data", "Chaves da IR devem ser strings.")
          end
          keys = value.keys.sort_by { |key| key.encode(Encoding::UTF_16BE).bytes }
          "{#{keys.map { |key| "#{dump(key)}:#{dump(value.fetch(key))}" }.join(',')}}"
        when Array
          "[#{value.map { |child| dump(child) }.join(',')}]"
        when String
          text = value.encode(Encoding::UTF_8)
          raise Error.single("invalid_data", "String UTF-8 inválida.") unless text.valid_encoding?
          JSON.generate(text)
        when Integer
          raise Error.single("invalid_data", "Inteiro fora do intervalo seguro da IR.") if value.abs > MAX_INTEGER
          value.to_s
        when TrueClass then "true"
        when FalseClass then "false"
        when NilClass then "null"
        else
          raise Error.single("invalid_data", "Tipo #{value.class} não permitido na IR; decimais usam strings.")
        end
      rescue EncodingError => e
        raise Error.single("invalid_data", "Codificação inválida (#{e.class}).")
      end

      def digest(document)
        payload = document.reject { |key, _| key == "digest" }
        "sha256:#{Digest::SHA256.hexdigest(dump(payload))}"
      end
    end
  end
end

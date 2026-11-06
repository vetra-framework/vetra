# frozen_string_literal: true

require 'bigdecimal'
require 'date'
require 'time'

module Vetra
  module Data
    class RecordNotFound < Error
      def initialize
        super(Error.single('data_record_not_found', 'Registro não encontrado.').diagnostics)
      end
    end

    class Conflict < Error
      attr_reader :kind

      def initialize(kind)
        @kind = kind
        super(Error.single('data_conflict', 'Conflito ao persistir o registro.').diagnostics)
      end
    end

    # Só valores atravessam a fronteira; nunca expressões do Sequel ou objetos do driver.
    module Values
      module_function

      def immutable(value)
        invalid! if value.is_a?(Sequel::SQL::Expression) || value.is_a?(Sequel::LiteralString)
        case value
        when Hash then value.to_h { |key, child| [immutable(key), immutable(child)] }.freeze
        when Array then value.map { |child| immutable(child) }.freeze
        when String, Time, Date then value.dup.freeze
        else
          return value if Ractor.shareable?(value)
          raise Error.single('data_value', 'Valor incompatível com o campo do registro.')
        end
      end

      def invalid!
        raise Error.single('data_value', 'Valor incompatível com o campo do registro.')
      end

      def decimal(value, type)
        invalid! unless value.is_a?(BigDecimal) || (value.is_a?(String) && value.match?(/\A-?\d+(?:\.\d+)?\z/))
        number = value.is_a?(BigDecimal) ? value : BigDecimal(value)
        invalid! unless number.finite? && number == number.round(type.fetch('scale')) &&
                        number.abs < BigDecimal("1e#{type.fetch('precision') - type.fetch('scale')}")
        number
      end

      def timestamp(value)
        if value.is_a?(String)
          invalid! unless value.match?(/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d{1,6})?(?:Z|[+-]\d\d:\d\d)\z/)
          Date.iso8601(value.split('T').first)
          value = Time.iso8601(value)
        end
        invalid! unless value.is_a?(Time) && value.getutc.year.between?(1, 9999) && value.nsec % 1000 == 0
        value.getutc.freeze
      rescue ArgumentError
        invalid!
      end

      def json(value)
        case value
        when Hash
          invalid! unless value.keys.all? { |key| key.is_a?(String) }
          value.to_h { |key, child| [text(key), json(child)] }
        when Array then value.map { |child| json(child) }
        when String then text(value)
        when Integer, TrueClass, FalseClass, NilClass then value
        when Float
          invalid! unless value.finite?
          value
        else invalid!
        end
      end

      def text(value)
        invalid! unless value.instance_of?(String) && value.valid_encoding?
        result = value.encode(Encoding::UTF_8)
        invalid! if result.include?("\0")
        result
      rescue EncodingError
        invalid!
      end

      def coerce(value, field, currency:)
        invalid! if value.is_a?(Sequel::SQL::Expression) || value.is_a?(Sequel::LiteralString)
        if value.nil?
          invalid! unless field['nullable']
          return nil
        end
        type = field.fetch('type')
        converted = case type.fetch('name')
        when 'string', 'text', 'email', 'enum'
          result = text(value)
          result = result.downcase if field['normalize']
          constraints = field.fetch('constraints', {})
          invalid! if result.length < constraints.fetch('min_length', 0) ||
                      (constraints['max_length'] && result.length > constraints['max_length']) ||
                      (type['name'] == 'enum' && !type['values'].include?(result))
          result
        when 'id'
          invalid! unless value.is_a?(String) && value.match?(/\A[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}\z/)
          value.downcase
        when 'integer'
          invalid! unless value.is_a?(Integer) && (-2**63...2**63).cover?(value)
          value
        when 'boolean'
          invalid! unless value == true || value == false
          value
        when 'decimal' then decimal(value, type)
        when 'money'
          parts = value.is_a?(Money) ? value.to_h : value
          invalid! unless parts.is_a?(Hash) && (parts.keys.map(&:to_s) - %w[amount currency]).empty?
          amount = parts.fetch(:amount) { parts.fetch('amount') { invalid! } }
          code = parts.fetch(:currency) { parts.fetch('currency', currency) }
          exponent = Graph::Currency::EXPONENTS[code]
          invalid! unless exponent && exponent <= type['scale']
          Money.new(amount: decimal(amount, type), currency: code)
        when 'date'
          date = value.is_a?(String) ? Date.iso8601(value) : value
          invalid! unless date.instance_of?(Date) && date.year.between?(1, 9999)
          date
        when 'timestamp' then timestamp(value)
        when 'json' then json(value)
        else invalid!
        end
        immutable(converted)
      rescue ArgumentError, TypeError
        invalid!
      end
    end

    Money = ::Data.define(:amount, :currency) do
      def initialize(amount:, currency:)
        Values.invalid! unless amount.is_a?(BigDecimal) && amount.finite? && Graph::Currency::EXPONENTS.key?(currency)
        super(amount: amount, currency: Values.immutable(currency))
      end
    end
  end
end

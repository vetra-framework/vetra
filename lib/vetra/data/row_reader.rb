# frozen_string_literal: true

module Vetra
  module Data
    # Borda interna: recebe exclusivamente linhas tipadas pelo Sequel/pg sobre o DDL da IR.
    class RowReader
      def initialize(fields, record_type)
        @record_type = record_type
        @readers = fields.map do |field|
          name = field.fetch('name').to_sym
          kind = field.fetch('type').fetch('name')
          if kind == 'money'
            amount, currency = "#{name}_amount".to_sym, "#{name}_currency".to_sym
            [name, ->(row) { self.class.money(row.fetch(amount), row.fetch(currency)) }]
          else
            [name, ->(row) { self.class.convert(row.fetch(name), kind) }]
          end
        end.freeze
        freeze
      end

      def call(row)
        values = @readers.to_h { |name, read| [name, read.call(row)] }
        record = self.class.construct(@record_type, values)
        self.class.invalid! unless Ractor.shareable?(record)
        record
      rescue KeyError, ArgumentError, TypeError, NoMethodError, RangeError, EncodingError
        self.class.invalid!
      end

      def self.construct(type, values)
        # Os valores já são imutáveis; chamar Record#initialize copiaria tudo novamente.
        record = type.allocate
        ::Data.instance_method(:initialize).bind_call(record, **values)
        record
      end

      def self.convert(value, kind)
        return nil if value.nil?
        case kind
        when 'string', 'text', 'email', 'enum', 'id' then text(value)
        when 'timestamp'
          utc = value.utc? ? value : value.getutc
          invalid! unless utc.year.between?(1, 9999) && utc.nsec % 1000 == 0
          utc.freeze
        when 'date'
          invalid! unless value.year.between?(1, 9999)
          value.freeze
        when 'json' then json(value)
        else value # bigint, boolean e numeric já vêm prontos do driver, na escala do DDL.
        end
      end

      def self.text(value)
        (value.encoding == Encoding::UTF_8 ? value : value.encode(Encoding::UTF_8)).freeze
      end

      def self.money(amount, currency)
        return nil if amount.nil? && currency.nil?
        invalid! if amount.nil? || currency.nil?
        construct(Money, { amount: amount, currency: text(currency) })
      end

      def self.json(value)
        value = value.to_h if value.is_a?(Sequel::Postgres::JSONBHash)
        value = value.to_a if value.is_a?(Sequel::Postgres::JSONBArray)
        case value
        when Hash then value.to_h { |key, child| [text(key), json(child)] }.freeze
        when Array then value.map { |child| json(child) }.freeze
        when String then text(value)
        when Integer, TrueClass, FalseClass, NilClass then value
        when Float
          invalid! unless value.finite?
          value
        else invalid!
        end
      end

      def self.invalid!
        raise Error.single('data_read_value', 'Linha do banco incompatível com o registro.'), cause: nil
      end
    end
  end
end

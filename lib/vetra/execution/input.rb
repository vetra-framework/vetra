# frozen_string_literal: true

module Vetra
  module Execution
    # Consome contratos já validados da IR. A ausência opcional é preservada, distinta de NULL.
    class Input
      def initialize(document)
        contracts = document.fetch('nodes').select { |node| node['kind'] == 'contract' }
          .to_h { |node| [node['id'], node] }
        @contracts = Graph::Data.freeze(Graph::Data.copy(contracts))
        @currency = document.fetch('app').fetch('currency')
        freeze
      end

      def validate(contract_id, value, pointer: '/input')
        contract = @contracts.fetch(contract_id)
        if contract['collection']
          invalid!(pointer) unless value.is_a?(Array)
          return value.each_with_index.map { |item, index| object(contract, item, "#{pointer}/#{index}") }.freeze
        end
        object(contract, value, pointer)
      end

      private

      def object(contract, value, pointer)
        fields = contract.fetch('fields').to_h { |field| [field['name'], field] }
        unless value.is_a?(Hash) && value.keys.all? { |key| key.is_a?(String) || key.is_a?(Symbol) } &&
               value.keys.map(&:to_s).uniq.size == value.size && (value.keys.map(&:to_s) - fields.keys).empty?
          raise Error.single('data_input_fields', 'Entrada exige objeto com campos conhecidos e sem nomes duplicados.', pointer: pointer)
        end
        supplied = value.transform_keys(&:to_s)
        fields.each_with_object({}) do |(name, field), result|
          at = "#{pointer}/#{name}"
          unless supplied.key?(name)
            invalid!(at) if field['required']
            next
          end
          result[name] = convert(field, supplied[name], at)
        end.freeze
      end

      def convert(field, value, pointer)
        type = field.fetch('type')
        if !value.nil? && %w[record collection].include?(type['name'])
          contract = @contracts.fetch(type.dig('contract', 'id'))
          if type['name'] == 'collection'
            invalid!(pointer) unless value.is_a?(Array)
            value.each_with_index.map { |item, index| object(contract, item, "#{pointer}/#{index}") }.freeze
          else
            object(contract, value, pointer)
          end
        else
          Data::Values.coerce(value, field, currency: @currency)
        end
      rescue Data::Error => error
        raise error, cause: nil if error.diagnostics.first.pointer != '/'
        invalid!(pointer)
      end

      def invalid!(pointer)
        raise Error.single('data_value', 'Valor incompatível com o contrato de entrada.', pointer: pointer), cause: nil
      end
    end
  end
end

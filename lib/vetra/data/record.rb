# frozen_string_literal: true

module Vetra
  module Data
    module Record
      # Data#with chama initialize; ambos copiam os valores mutáveis antes de congelar.
      def initialize(**attributes)
        super(**Values.immutable(attributes))
      end

      def enum_group?(group)
        self.class::ENUM_GROUPS.fetch(group).any? { |field, values| values.include?(public_send(field)) }
      end
      private :enum_group?

      # O Ruby/Data chama estes ganchos no registro; um leitor de campo quebraria seu funcionamento.
      KERNEL_HOOKS = %i[
        initialize initialize_copy initialize_clone initialize_dup method_missing respond_to_missing?
        singleton_method_added singleton_method_removed singleton_method_undefined instance_variables_to_inspect
      ].freeze

      # Sem Sequel/pg: o compilador e os repositórios consultam a mesma fonte de métodos.
      METHOD_SOURCE = ::Data.define { include Record }.freeze

      def self.reserved_method?(name)
        # Consulta os ancestrais atuais, mesmo quando uma biblioteca acrescenta métodos depois do require.
        return true if METHOD_SOURCE.method_defined?(name)
        return false unless METHOD_SOURCE.private_method_defined?(name)

        METHOD_SOURCE.instance_method(name).owner != ::Kernel || KERNEL_HOOKS.include?(name.to_sym)
      end
    end
  end
end

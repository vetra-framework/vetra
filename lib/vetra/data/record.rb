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
    end
  end
end

# frozen_string_literal: true

module Vetra
  module Data
    # Descrição imutável. Guarda apenas valores e nomes conferidos, nunca dataset/SQL.
    class Query
      def initialize(repository, equalities: [], fields: ['id'])
        @repository = repository
        @equalities, @fields = Values.immutable(equalities), Values.immutable(fields)
        freeze
      end

      def where(**equalities, &block)
        reject_block!(block)
        self.class.new(@repository, equalities: @equalities + [@repository.__send__(:query_equalities, equalities)], fields: @fields)
      end

      def order(*fields, &block)
        reject_block!(block)
        names = @repository.__send__(:query_fields, fields)
        self.class.new(@repository, equalities: @equalities, fields: (names + ['id']).uniq)
      end

      def first(n, &block)
        terminal(n, false, block)
      end

      def last(n, &block)
        terminal(n, true, block)
      end

      def all(&block)
        reject_block!(block)
        @repository.__send__(:query_all, @equalities, @fields)
      end

      private

      def reject_block!(block)
        raise Error.single('data_query', 'Consulta aceita somente igualdade, campos e limite inteiro positivo; não aceita bloco.') if block
      end

      def terminal(n, reverse, block)
        reject_block!(block)
        unless n.is_a?(Integer) && n.positive?
          raise Error.single('data_query', 'Consulta aceita somente igualdade, campos e limite inteiro positivo; não aceita bloco.')
        end
        @repository.__send__(:query_all, @equalities, @fields, limit: n, reverse: reverse)
      end
    end
  end
end

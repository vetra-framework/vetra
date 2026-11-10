# frozen_string_literal: true

module Vetra
  module Execution
    class Predicate
      def initialize(entities, tables)
        @entities, @tables = entities, tables
        freeze
      end

      # Percorre a árvore inteira antes de avaliar: curto-circuito não esconde um operador sem suporte.
      def validate!(tree, entity_id)
        entity = @entities.fetch(entity_id)
        case tree['op']
        when 'true' then nil
        when 'and', 'or' then tree.fetch('terms').each { |term| validate!(term, entity_id) }
        when 'not' then validate!(tree.fetch('term'), entity_id)
        when 'eq'
          operand!(tree.fetch('left'), entity)
          operand!(tree.fetch('right'), entity)
          comparison!(tree.fetch('left'), tree.fetch('right'), entity)
        when 'in'
          operand!(tree.fetch('left'), entity)
          right = tree.fetch('right')
          unsupported! unless right['kind'] == 'literal' && right['value'].is_a?(Array) && right['value'].all? { |value| scalar?(value) }
          right['value'].each { |value| comparison!(tree.fetch('left'), { 'kind' => 'literal', 'value' => value }, entity) }
        when 'exists'
          tree.fetch('relation').each do |name|
            link = entity.fetch('relations').find { |relation| relation['name'] == name }
            unsupported! unless link && %w[belongs_to has_many].include?(link['kind'])
            entity = @entities.fetch(link.dig('target', 'id'))
          end
          validate!(tree.fetch('where'), entity.fetch('id'))
        else unsupported!
        end
      end

      # NULL usa a lógica de três valores do SQL, inclusive sob NOT e IN.
      def evaluate(tree, entity_id, row, context, snapshot)
        case tree['op']
        when 'true' then true
        when 'and', 'or'
          values = tree.fetch('terms').map { |term| evaluate(term, entity_id, row, context, snapshot) }
          if tree['op'] == 'and'
            values.include?(false) ? false : (values.include?(nil) ? nil : true)
          else
            values.include?(true) ? true : (values.include?(nil) ? nil : false)
          end
        when 'not'
          result = evaluate(tree.fetch('term'), entity_id, row, context, snapshot)
          result.nil? ? nil : !result
        when 'eq'
          entity = @entities.fetch(entity_id)
          left = operand(tree.fetch('left'), row, context, operand_type(tree.fetch('right'), entity))
          right = operand(tree.fetch('right'), row, context, operand_type(tree.fetch('left'), entity))
          null_literal = %w[left right].any? { |side| tree.dig(side, 'kind') == 'literal' && tree[side]['value'].nil? }
          !null_literal && (left.nil? || right.nil?) ? nil : left == right
        when 'in'
          value = operand(tree.fetch('left'), row, context)
          type = operand_type(tree.fetch('left'), @entities.fetch(entity_id))
          list = tree.dig('right', 'value').map { |item| comparison_literal(item, type) }
          return false if list.empty?
          return nil if value.nil?
          list.include?(value) ? true : (list.include?(nil) ? nil : false)
        when 'exists'
          rows = [row]
          tree.fetch('relation').each do |name|
            link = @entities.fetch(entity_id).fetch('relations').find { |relation| relation['name'] == name }
            target = link.dig('target', 'id')
            candidates = scoped_rows(target, context, snapshot)
            rows = rows.flat_map do |source|
              local = link.fetch('local_fields').map { |field| field_value(source, field) }
              next [] if local.any?(&:nil?)
              candidates.select { |candidate| link.fetch('target_fields').map { |field| field_value(candidate, field) } == local }
            end
            entity_id = target
          end
          rows.any? { |candidate| evaluate(tree.fetch('where'), entity_id, candidate, context, snapshot) == true }
        end
      end

      def scoped_rows(entity_id, context, snapshot)
        snapshot.rows(entity_id).select { |row| in_tenant?(entity_id, row, context) }
      end

      def in_tenant?(entity_id, row, context)
        column = @tables.fetch(entity_id)['tenant_column']
        !column || field_value(row, column) == context.tenant_id
      end

      def field_value(row, name)
        unless row.key?(name)
          raise Error.single('data_authorization_snapshot', 'Fatos de autorização ausentes, incompletos, incompatíveis ou obsoletos.')
        end
        row.fetch(name)
      end

      private

      def scalar?(value)
        value.nil? || value == true || value == false || value.is_a?(String) || value.is_a?(Numeric)
      end

      def operand!(value, entity)
        case value['kind']
        when 'literal' then unsupported! unless scalar?(value['value'])
        when 'actor' then unsupported! unless value['path'] == ['id']
        when 'field'
          field = entity.fetch('fields').find { |candidate| candidate['name'] == value['path'].first }
          unsupported! unless value['path'].size == 1 && field && !%w[money json record collection].include?(field.dig('type', 'name'))
        else unsupported!
        end
      end

      def operand_type(value, entity)
        return 'id' if value['kind'] == 'actor'
        entity['fields'].find { |field| field['name'] == value['path'].first }.dig('type', 'name') if value['kind'] == 'field'
      end

      def comparison!(left, right, entity)
        a, b = operand_type(left, entity), operand_type(right, entity)
        if a && b
          family = ->(type) { %w[string text email enum].include?(type) ? :text : (%w[integer decimal].include?(type) ? :number : type) }
          unsupported! unless family.call(a) == family.call(b)
        elsif a || b
          comparison_literal(a ? right['value'] : left['value'], a || b)
        elsif !left['value'].nil? && !right['value'].nil?
          family = ->(value) { value.is_a?(Numeric) ? :number : (value.is_a?(String) ? :text : :boolean) }
          unsupported! unless family.call(left['value']) == family.call(right['value'])
        end
      end

      # O SQL tipa um literal textual pelo outro operando: UUID, data e timestamp não são texto Ruby.
      # Não aplica normalize, enum ou limites do campo ao literal de comparação.
      def comparison_literal(value, type)
        return value if value.nil? || type.nil?
        case type
        when 'string', 'text', 'email', 'enum'
          Data::Values.text(value)
        when 'integer', 'decimal'
          if value.is_a?(String)
            unsupported! unless value.match?(type == 'integer' ? /\A-?\d+\z/ : /\A-?\d+(?:\.\d+)?\z/)
            return Data::Values.coerce(Integer(value, 10), { 'type' => { 'name' => 'integer' } }, currency: nil) if type == 'integer'
          else
            unsupported! unless value.is_a?(Numeric)
          end
          number = BigDecimal(value.to_s)
          unsupported! unless number.finite?
          number
        else
          Data::Values.coerce(value, { 'type' => { 'name' => type } }, currency: nil)
        end
      rescue Data::Error, ArgumentError, TypeError
        unsupported!
      end

      def operand(value, row, context, type = nil)
        case value['kind']
        when 'literal' then comparison_literal(value['value'], type)
        when 'actor' then context.actor_id
        when 'field' then field_value(row, value['path'].first)
        end
      end

      def unsupported!
        raise Error.single('data_authorization_predicate', 'Predicado de autorização fora do subconjunto suportado pelo avaliador Ruby.'), cause: nil
      end
    end
  end
end

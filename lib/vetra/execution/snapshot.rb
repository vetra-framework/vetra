# frozen_string_literal: true

module Vetra
  module Execution
    # Fatos completos fornecidos exclusivamente pela borda confiável, antes da operação (ADR-044).
    # Uma chave ausente não significa uma relação vazia: não se prova NOT EXISTS com fatos incompletos.
    class Snapshot
      attr_reader :roles, :revision

      def initialize(owner:, context:, roles:, revision:, records:)
        unless context.is_a?(Data::Context) && roles.is_a?(Array) && roles.all? { |role| role.is_a?(String) } &&
               !revision.nil? && records.is_a?(Hash) && records.all? do |entity, rows|
                 entity.is_a?(String) && rows.is_a?(Array) && rows.all? { |row| row.is_a?(Hash) }
               end
          invalid!
        end
        @owner = owner
        @principal = principal(context)
        @roles, @revision = Data::Values.immutable(roles.uniq), Data::Values.immutable(revision)
        @records = Data::Values.immutable(records.to_h do |entity, rows|
          converted = rows.map do |row|
            invalid! unless row.keys.all? { |key| key.is_a?(String) || key.is_a?(Symbol) } && row.keys.map(&:to_s).uniq.size == row.size
            row.transform_keys(&:to_s)
          end
          ids = converted.filter_map { |row| row['id'] }
          invalid! if ids.uniq.size != ids.size
          [entity, converted]
        end)
        freeze
      end

      def matches?(owner, context)
        @owner.equal?(owner) && @principal == principal(context)
      end

      def rows(entity_id)
        invalid! unless @records.key?(entity_id)
        @records.fetch(entity_id)
      end

      def inspect = '#<Vetra::Execution::Snapshot [REDACTED]>'
      alias to_s inspect

      private

      def principal(context)
        [context.scope, context.tenant_id, context.actor_id, context.system_actor].freeze
      end

      def invalid!
        raise Error.single('data_authorization_snapshot', 'Fatos de autorização ausentes, incompletos, incompatíveis ou obsoletos.')
      end
    end
  end
end

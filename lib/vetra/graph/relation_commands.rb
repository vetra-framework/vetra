module Vetra
  module Graph
    # Semântica compartilhada pelo gerador e pelo validador, sem execução da primitiva.
    module RelationCommands
      FEATURE = 'vetra.relation_commands'.freeze

      def self.parse(name)
        match = /\Amany_to_many\.(add|remove)\.([a-z][a-z0-9_]*)\z/.match(name)
        match && match.captures
      end

      def self.singular(name)
        return "#{name[0...-3]}y" if name.match?(/[^aeiou]ies\z/)
        return name[0...-1] if name.end_with?('s') && !name.end_with?('ss')
        name
      end

      def self.action(verb, relation)
        "#{verb}_#{singular(relation['name'])}"
      end

      def self.input_fields(owner, target)
        [owner, target].map do |entity|
          { 'name' => "#{entity['id'].split('.').last}_id",
            'type' => { 'name' => 'id', 'entity' => Data.reference('entity', entity['id']) },
            'required' => true, 'nullable' => false, 'privacy' => { 'personal' => false } }
        end
      end

      def self.junction_error(owner, relation, target, junction)
        unless owner['tenant'] == target['tenant'] && owner['tenant'] == junction['tenant'] &&
            relation['same_tenant'] == !owner['tenant'].nil?
          return 'dono, alvo e junção devem compartilhar tenant e chaves same_tenant coerentes'
        end
        links = [owner, target].map do |entity|
          junction['relations'].select { |link| link['kind'] == 'belongs_to' && link['target'] == Data.reference('entity', entity['id']) }
        end
        unless links.all? { |items| items.size == 1 } && links[0] != links[1]
          return 'a junção deve ter exatamente um belongs_to para cada lado'
        end
        links = links.map(&:first)
        expected_keys = [owner, target].map { |entity| [entity.dig('tenant', 'field'), 'id'].compact }
        unless links.map { |link| link['target_fields'] } == expected_keys &&
            expected_keys == relation.values_at('local_fields', 'target_fields') &&
            links.all? { |link| link['same_tenant'] == relation['same_tenant'] }
          return 'as chaves da junção devem coincidir com as da relação'
        end
        keys = links.flat_map { |link| link['local_fields'] }.uniq
        fields = junction['fields'].to_h { |field| [field['name'], field] }
        typed = links.zip([owner, target]).all? do |link, entity|
          referenced = entity['fields'].to_h { |field| [field['name'], field] }
          link['local_fields'].size == link['target_fields'].size &&
            link['local_fields'].zip(link['target_fields']).all? do |local, remote|
              fields[local] && referenced[remote] && fields[local]['type'] == referenced[remote]['type']
            end
        end
        return 'as colunas da junção devem ter os tipos dos IDs referenciados' unless typed
        if keys.any? { |name| !fields[name] || !fields[name]['required'] || fields[name]['nullable'] || fields[name]['set_by'] || fields[name]['guarded'] }
          return 'as chaves do vínculo devem ser obrigatórias, não nulas e graváveis pela primitiva'
        end
        unless junction['indexes'].any? { |index| index['unique'] && index['fields'].sort == keys.sort }
          return 'a junção exige índice único exatamente sobre o par de chaves, incluindo tenant'
        end
        missing = junction['fields'].reject do |field|
          keys.include?(field['name']) || field['name'] == 'id' || (!field['required'] && field['nullable']) || field.key?('default') || field['generate']
        end
        return "a junção exige campos adicionais sem default ou geração: #{missing.map { |field| field['name'] }.join(', ')}" unless missing.empty?
        nil
      end
    end
  end
end

# frozen_string_literal: true

module Vetra
  module Data
    # Fábrica da borda confiável; o call recebe somente o resultado de bind.
    class Repositories
      RECORD_METHODS = ::Data.define { include Record }.instance_methods.freeze

      attr_reader :entity_ids

      def initialize(document)
        schema = SQL::Schema.new(document).generate
        @currency = schema.document.fetch('app').fetch('currency')
        @entities = schema.document['nodes'].select { |node| node['kind'] == 'entity' }.to_h { |node| [node['id'], node] }.freeze
        @capabilities = schema.document['nodes'].select { |node| node['kind'] == 'capability' && node.dig('config', 'type') == 'repository' }
          .to_h { |node| [node['id'], node['config']] }.freeze
        @tables = schema.tables.to_h { |table| [table['entity'], table] }.freeze
        @entities.each_value do |entity|
          if entity['fields'].any? { |field| RECORD_METHODS.include?(field['name'].to_sym) }
            raise Error.single('data_record_type', 'Nome do campo colide com método do registro.')
          end
        end
        @types, @repositories = {}, {}
        @entities.each_value do |entity|
          type = ::Data.define(*entity['fields'].map { |field| field['name'].to_sym })
          type.include(Record)
          groups = {}
          entity['fields'].each do |field|
            field.dig('type', 'groups')&.each do |name, values|
              (groups[name] ||= []) << [field['name'], values]
            end
          end
          type.const_set(:ENUM_GROUPS, Values.immutable(groups))
          groups.each_key do |name|
            # Nomes de grupo vêm do schema fechado da IR, mas também são conferidos como métodos Ruby.
            unless name.match?(/\A[a-z][a-z0-9_]*\z/) && !type.method_defined?("#{name}?")
              raise Error.single('data_record_type', 'Grupo de enum colide com método do registro ou tem nome inválido.')
            end
            type.class_eval("def #{name}?; enum_group?(#{name.dump}); end", __FILE__, __LINE__)
          end
          @types[entity['id']] = type.freeze
          repository = Class.new(Repository)
          entity['relations'].select { |relation| relation['kind'] == 'many_to_many' }.each do |relation|
            junction = @entities.fetch(relation.dig('through', 'id'))
            target = @entities.fetch(relation.dig('target', 'id'))
            if Graph::RelationCommands.junction_error(entity, relation, target, junction)
              raise Error.single('data_relation', 'Vínculo exige junção elegível conforme o ADR-032, mesmo com commands: false.')
            end
            %w[add remove].each do |verb|
              method = "#{Graph::RelationCommands.action(verb, relation)}!"
              if repository.method_defined?(method)
                raise Error.single('data_relation', 'Método gerado de vínculo colide com outro método do repositório.')
              end
              repository.define_method(method) { |owner_id, target_id| change_link(relation, verb, owner_id, target_id) }
            end
          end
          @repositories[entity['id']] = repository.freeze
        end
        @types.freeze
        @repositories.freeze
        @entity_ids = @entities.keys.sort.freeze
        freeze
      end

      def record_type(entity_id)
        @types.fetch(entity_id) { raise Error.single('data_repository', 'Entidade ou capacidade de repositório não encontrada na IR.') }
      end

      def bind(capability_id, unit:)
        config = @capabilities.fetch(capability_id) { raise Error.single('data_repository', 'Entidade ou capacidade de repositório não encontrada na IR.') }
        build(config.dig('entity', 'id'), unit, config.fetch('access'))
      end

      private

      def build(entity_id, unit, access)
        @repositories.fetch(entity_id).new(catalog: self, unit: unit, access: access,
          entity: @entities.fetch(entity_id), table: @tables.fetch(entity_id), record_type: @types.fetch(entity_id), currency: @currency)
      end
    end
  end
end

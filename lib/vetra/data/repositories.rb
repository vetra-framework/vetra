# frozen_string_literal: true

require 'securerandom'

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
        @tenant_app = !schema.document.dig('app', 'tenant').nil?
        @emits = emissions(schema.document['nodes'])
        freeze
      end

      # Etapa 7 do ADR-016 (ADR-040, §2): grava na outbox, na unidade, os eventos que o comando da unidade declara a
      # partir deste registro, com o payload projetado. Devolve os event_id gravados. É borda confiável, como bind.
      def emit!(unit, record)
        entity_id = @types.key(record.class)
        raise Error.single('data_event', 'Emissão exige um registro de entidade desta IR.') unless entity_id
        context = unit.context
        declared = @emits.fetch(context.cmd, []).select { |emit| emit['entity'] == entity_id }
        raise Error.single('data_event', 'O comando da unidade não declara evento a partir deste registro.') if declared.empty?
        raise Error.single('data_read_only', 'Escrita exige capacidade read_write e unidade gravável.') if context.read_only?
        if declared.any? { |emit| emit['fields'].any? { |field| field.dig('privacy', 'personal') } }
          # Sem a cifra do ADR-013, §6, a outbox nunca recebe dado pessoal, nem se o call resgatar o erro.
          unit.doom!(Error.single('data_event_personal', 'Evento com campo pessoal exige a cifra do ADR-013; a unidade de trabalho foi desfeita.'))
        end
        declared.map do |emit|
          payload = emit['fields'].to_h { |field| [field['name'], Values.event_value(record.public_send(field['name']), field)] }
          event_id = SecureRandom.uuid
          write_event(unit, context, emit, event_id, payload)
          event_id
        end.freeze
      end

      def record_type(entity_id)
        @types.fetch(entity_id) { raise Error.single('data_repository', 'Entidade ou capacidade de repositório não encontrada na IR.') }
      end

      def bind(capability_id, unit:)
        config = @capabilities.fetch(capability_id) { raise Error.single('data_repository', 'Entidade ou capacidade de repositório não encontrada na IR.') }
        build(config.dig('entity', 'id'), unit, config.fetch('access'))
      end

      private

      # Por comando, os eventos de emits com a versão, a entidade de origem e os campos do contrato do payload.
      def emissions(nodes)
        events = nodes.select { |node| node['kind'] == 'event' }.to_h { |node| [node['id'], node] }
        contracts = nodes.select { |node| node['kind'] == 'contract' }.to_h { |node| [node['id'], node] }
        nodes.select { |node| node['kind'] == 'command' && node['emits']&.any? }.to_h do |command|
          emits = command['emits'].map do |emit|
            event = events.fetch(emit.dig('event', 'id'))
            fields = contracts.fetch(event.dig('payload', 'id'))['fields'].select { |field| emit['fields'].include?(field['name']) }
            entity = @entities.fetch(emit.dig('from', 'id'))
            unless fields.size == emit['fields'].size && fields.all? { |field| entity['fields'].any? { |item| item['name'] == field['name'] } }
              raise Error.single('data_event', 'Projeção do evento não corresponde ao contrato do payload.')
            end
            { 'event' => event['id'], 'version' => event['version'], 'entity' => entity['id'], 'fields' => fields }
          end
          [command['id'], Values.immutable(emits)]
        end.freeze
      end

      def write_event(unit, context, emit, event_id, payload)
        unit.access(multi_tenant: @tenant_app) do |db|
          # Sem RETURNING: a aplicação só tem INSERT por coluna na outbox; created_at, xid8 e seq vêm do banco.
          db[Sequel.qualify('vetra', 'outbox')].disable_insert_returning.insert(
            event_id: event_id, event: emit['event'], version: emit['version'], tenant_id: context.tenant_id,
            actor_id: context.actor_id, op_id: context.op_id, cmd: context.cmd, payload: Sequel.pg_jsonb_wrap(payload)
          )
          # Só acorda quem lê a outbox; o conteúdo do evento nunca vai na notificação (ADR-008, §1).
          db.get(Sequel.function(:pg_notify, 'vetra_outbox', context.tenant_id || ''))
        end
      rescue Sequel::DatabaseError => error
        wrapped = error.wrapped_exception
        state = wrapped.respond_to?(:result) ? wrapped.result&.error_field('C') : nil
        raise Error.single('data_access_denied', 'Acesso aos dados recusado.'), cause: nil if state == '42501'
        raise Error.single('data_database', 'Falha ao acessar os dados.'), cause: nil
      end

      def build(entity_id, unit, access)
        @repositories.fetch(entity_id).new(catalog: self, unit: unit, access: access,
          entity: @entities.fetch(entity_id), table: @tables.fetch(entity_id), record_type: @types.fetch(entity_id), currency: @currency)
      end
    end
  end
end

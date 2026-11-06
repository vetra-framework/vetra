# frozen_string_literal: true

module Vetra
  module Data
    class Repository
      def initialize(catalog:, unit:, access:, entity:, table:, record_type:, currency:)
        @catalog, @unit, @access = catalog, unit, access
        @entity, @table, @record_type, @currency = entity, table, record_type, currency
        @fields = entity['fields'].to_h { |field| [field['name'], field] }.freeze
        freeze
      end

      def find!(id)
        execute { |dataset| read_record!(dataset.where(id: record_id(id)).first) }
      end

      def lock!(id)
        execute(write: true) { |dataset| read_record!(dataset.where(id: record_id(id)).for_update.first) }
      end

      def create!(**attributes)
        execute(write: true) do |dataset|
          values = creation_values(attributes)
          transitions!(nil, values)
          record = read_record!(dataset.returning.insert(physical(values)).first)
          @entity['relations'].select { |relation| relation['kind'] == 'many_to_many' }.each do |relation|
            relation.fetch('include_on_create', []).each do |name|
              link = @entity['relations'].find { |entry| entry['name'] == name && entry['kind'] == 'belongs_to' }
              change_link(relation, 'add', record.id, record.public_send(link['local_fields'].last))
            end
          end
          record
        end
      end

      def update!(record_or_id, **attributes)
        execute(write: true) do |dataset|
          values = writable(attributes, create: false)
          target = dataset.where(id: record_id(record_or_id))
          # OLD vem sempre do banco, sob lock; nunca se confia no objeto recebido.
          old = read_record!(target.for_update.first)
          transitions!(old, values)
          values.empty? ? old : read_record!(target.returning.update(physical(values)).first)
        end
      end

      def delete!(record_or_id)
        execute(write: true) { |dataset| read_record!(dataset.where(id: record_id(record_or_id)).returning.delete.first) }
      end

      def where(**equalities, &block)
        Query.new(self).where(**equalities, &block)
      end

      def order(*fields, &block)
        Query.new(self).order(*fields, &block)
      end

      def first(n, &block) = Query.new(self).first(n, &block)
      def last(n, &block) = Query.new(self).last(n, &block)
      def all(&block) = Query.new(self).all(&block)

      def inspect
        '#<Vetra::Data::Repository>'
      end
      alias to_s inspect

      private

      def query_fields(fields)
        fields.map do |name|
          unless (name.is_a?(String) || name.is_a?(Symbol)) && @fields.key?(name.to_s)
            raise Error.single('data_field', 'Campo desconhecido no repositório.')
          end
          name.to_s
        end
      end

      def query_equalities(equalities)
        query_fields(equalities.keys)
        equalities.to_h { |name, value| [name.to_s, coerce(name.to_s, value)] }
      end

      def query_all(equalities, fields, limit: nil, reverse: false)
        execute do |dataset|
          equalities.each { |values| dataset = dataset.where(physical(values)) }
          columns = fields.flat_map { |name| physical_names(name) }.map(&:to_sym)
          # reverse_order também inverte NULLS LAST, preservando a janela de last(n).
          dataset = dataset.order(*columns)
          dataset = dataset.reverse_order if reverse
          dataset = dataset.limit(limit) if limit
          records = dataset.all.map { |row| read_record!(row) }
          (reverse ? records.reverse : records).freeze
        end
      end

      def execute(write: false)
        @unit.access(multi_tenant: @table['scope'] != 'global') do |db|
          if write && (@access != 'read_write' || @unit.context.read_only?)
            raise Error.single('data_read_only', 'Escrita exige capacidade read_write e unidade gravável.')
          end
          dataset = db[Sequel.qualify(@table['schema'], @table['table'])]
          column = @table['tenant_column']
          dataset = dataset.where(column.to_sym => @unit.context.tenant_id) if column
          yield dataset
        end
      rescue Sequel::UniqueConstraintViolation
        raise Conflict.new(:unique), cause: nil
      rescue Sequel::ForeignKeyConstraintViolation
        raise Conflict.new(:foreign_key), cause: nil
      rescue Sequel::DatabaseError => error
        # PG_DIAG_SQLSTATE = 'C'; não inclui nem retém o erro/SQL/valores do driver.
        wrapped = error.wrapped_exception
        state = wrapped.respond_to?(:result) ? wrapped.result&.error_field('C') : nil
        raise Conflict.new(:unique), cause: nil if state == '23505'
        raise Conflict.new(:foreign_key), cause: nil if state == '23503'
        raise Conflict.new(:deadlock), cause: nil if state == '40P01'
        raise Conflict.new(:serialization), cause: nil if error.is_a?(Sequel::SerializationFailure) || state == '40001'
        if state == '42501'
          raise Error.single('data_access_denied', 'Acesso aos dados recusado.'), cause: nil
        end
        raise Error.single('data_database', 'Falha ao acessar os dados.'), cause: nil
      end

      def coerce(name, value)
        Values.coerce(value, @fields.fetch(name), currency: @currency)
      end

      def record_id(record_or_id)
        value = record_or_id.is_a?(@record_type) ? record_or_id.id : record_or_id
        coerce('id', value)
      end

      def writable(attributes, create:)
        query_fields(attributes.keys)
        attributes.to_h do |name, value|
          name = name.to_s
          if name == @table['tenant_column'] || (!create && name == 'id') || @fields[name].dig('generate', 'kind') == 'timestamp'
            raise Error.single('data_assignment', 'Identidade, tenant e timestamp gerado não são atribuíveis por esta operação.')
          end
          [name, coerce(name, value)]
        end
      end

      def creation_values(attributes)
        values = writable(attributes, create: true)
        @table['assignments'].each do |name, assignment|
          next if values.key?(name)
          if assignment['default']
            values[name] = assignment_default(name, assignment)
          elsif assignment.dig('generate', 'kind') == 'timestamp'
            values[name] = @unit.now
          end
        end
        column = @table['tenant_column']
        values[column] = @unit.context.tenant_id if column
        @table['assignments'].each do |name, assignment|
          next unless assignment.dig('generate', 'kind') == 'slug' && !values.key?(name)
          source = values[assignment.dig('generate', 'from')]
          Values.invalid! unless source.is_a?(String)
          slug = source.unicode_normalize(:nfkd).downcase.gsub(/\p{M}/, '').gsub(/[^a-z0-9]+/, '-').gsub(/\A-|-\z/, '')
          values[name] = coerce(name, slug)
        end
        @fields.each do |name, field|
          next if values.key?(name) || name == 'id'
          Values.invalid! unless field['nullable']
          values[name] = nil
        end
        values
      end

      def assignment_default(name, assignment)
        default = assignment['default']
        return nil unless default
        value = if default['kind'] == 'literal'
          default['value']
        else
          default['name'] == 'current_actor' ? @unit.context.actor_id : @unit.context.tenant_id
        end
        coerce(name, value)
      end

      def transitions!(old, values)
        values.each do |name, value|
          assignment = @table['assignments'].fetch(name)
          previous = old ? old.public_send(name) : assignment_default(name, assignment)
          next if previous == value
          commands = assignment['set_by']
          transition_denied!(name, commands) if commands && commands.none? { |command| command['id'] == @unit.context.cmd }
          assignment.fetch('guarded', []).each do |guard|
            next unless [previous, value].include?(guard['value'])
            transition_denied!(name, guard['commands']) unless guard['commands'].any? { |command| command['id'] == @unit.context.cmd }
          end
        end
      end

      def transition_denied!(name, commands)
        expected = commands.map { |command| command['id'] }.sort.join(', ')
        raise Error.single('data_transition', "Campo #{name} exige um dos comandos: #{expected}.")
      end

      def physical_names(name)
        @fields.fetch(name).dig('type', 'name') == 'money' ? ["#{name}_amount", "#{name}_currency"] : [name]
      end

      def physical(values)
        values.each_with_object({}) do |(name, value), result|
          field = @fields.fetch(name)
          if field.dig('type', 'name') == 'money'
            result["#{name}_amount".to_sym], result["#{name}_currency".to_sym] = value ? [value.amount, value.currency] : [nil, nil]
          else
            result[name.to_sym] = field.dig('type', 'name') == 'json' && !value.nil? ? Sequel.pg_jsonb_wrap(value) : value
          end
        end
      end

      def read_record!(row)
        raise RecordNotFound.new, cause: nil unless row
        values = @fields.to_h do |name, field|
          if field.dig('type', 'name') == 'money'
            amount, currency = row.values_at("#{name}_amount".to_sym, "#{name}_currency".to_sym)
            value = amount.nil? && currency.nil? ? nil : { amount: amount, currency: currency }
          else
            value = row.fetch(name.to_sym)
            if field.dig('type', 'name') == 'json'
              value = value.to_h if value.is_a?(Sequel::Postgres::JSONBHash)
              value = value.to_a if value.is_a?(Sequel::Postgres::JSONBArray)
            end
          end
          [name.to_sym, coerce(name, value)]
        end
        @record_type.new(**values)
      end

      def sibling(entity_id)
        @catalog.__send__(:build, entity_id, @unit, @access)
      end

      def change_link(relation, verb, owner_id, target_id)
        execute(write: true) do
          owner = lock!(owner_id)
          target = sibling(relation.dig('target', 'id')).find!(target_id)
          if verb == 'remove'
            required = relation.fetch('include_on_create', []).any? do |name|
              link = @entity['relations'].find { |entry| entry['kind'] == 'belongs_to' && entry['name'] == name }
              link['local_fields'].zip(link['target_fields']).all? { |local, remote| owner.public_send(local) == target.public_send(remote) }
            end
            raise Error.single('data_required_link', 'Vínculo obrigatório da criação não pode ser removido.') if required
          end
          junction = sibling(relation.dig('through', 'id'))
          links = junction.__send__(:belongs_to_links)
          values = {}
          [[@entity['id'], owner], [relation.dig('target', 'id'), target]].each do |entity_id, record|
            link = links.find { |entry| entry.dig('target', 'id') == entity_id }
            link['local_fields'].zip(link['target_fields']).each { |local, remote| values[local] = record.public_send(remote) }
          end
          junction.__send__(:persist_link, values, verb)
          owner
        end
      end

      def persist_link(values, verb)
        execute(write: true) do |dataset|
          if verb == 'add'
            attributes = values.reject { |name, _| name == @table['tenant_column'] }.transform_keys(&:to_sym)
            created = creation_values(attributes)
            transitions!(nil, created)
            # Só o par da relação é idempotente; outras unicidades continuam sendo conflito.
            dataset.insert_conflict(target: values.keys.map(&:to_sym)).insert(physical(created))
          else
            dataset.where(physical(values)).delete
          end
        end
      end

      def belongs_to_links
        @entity['relations'].select { |link| link['kind'] == 'belongs_to' }
      end
    end
  end
end

module Vetra
  module Graph
    module LiveDependencies
      module_function

      def outside_boundary?(query, nodes:)
        query.key?('unsafe_effect') || query['uses'].any? do |reference|
          !%w[repository deterministic].include?(nodes.fetch(reference.values_at('kind', 'id')).dig('config', 'type'))
        end
      end

      def required(query, nodes:, extra: [])
        entities = [query.dig('authorize', 'entity'), *extra]
        query['uses'].each do |reference|
          config = nodes.fetch(reference.values_at('kind', 'id'))['config']
          entities << config['entity'] if config['type'] == 'repository'
        end
        pending_contracts = [query.dig('output', 'id')]
        contracts = {}
        until pending_contracts.empty?
          id = pending_contracts.pop
          next if contracts[id]
          contracts[id] = true
          contract = nodes.fetch(['contract', id])
          origin = contract['generated_from']
          entities << origin if origin && origin['kind'] == 'entity'
          Data.references(contract['fields']) do |reference, _pointer|
            entities << reference if reference['kind'] == 'entity'
            pending_contracts << reference['id'] if reference['kind'] == 'contract'
          end
        end
        policies = nodes.values.select { |node| node['kind'] == 'policy' }.group_by { |node| node.dig('entity', 'id') }
        found = {}
        until entities.empty?
          reference = entities.pop
          id = reference.fetch('id')
          next if found[id]
          found[id] = reference
          policies.fetch(id, []).each do |policy|
            authorized = id == query.dig('authorize', 'entity', 'id') && policy['actions'].include?(query.dig('authorize', 'action'))
            entities.concat(policy['reads']) if authorized || policy['actions'].include?('read')
          end
        end
        found.values.sort_by { |reference| reference.values_at('kind', 'id') }
      end
    end
  end
end

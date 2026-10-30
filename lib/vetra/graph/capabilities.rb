module Vetra
  module Graph
    module Capabilities
      module_function

      def reference(name, domain:, operation_kind:, nodes:, source: nil)
        id = name.include?('.') ? name : "#{domain}.#{name}"
        capability = nodes[['capability', id]]
        unless capability
          raise Error.single('reference_missing', "Declare effect ou repositório #{id} antes de usá-lo.", source: source)
        end
        if %w[query handler].include?(operation_kind) && capability.dig('config', 'type') == 'repository' && capability.dig('config', 'access') == 'read_write'
          id = "#{id}_read"
        end
        unless nodes.key?(['capability', id])
          raise Error.single('reference_missing', "Capacidade resolvida não declarada: #{id}.", source: source)
        end
        Data.reference('capability', id)
      end
    end
  end
end

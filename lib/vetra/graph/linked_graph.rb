module Vetra
  module Graph
    class LinkedGraph
      attr_reader :document, :warnings, :bindings, :implementation_ids, :builtin_bindings

      def initialize(document:, warnings:, bindings:, implementations:)
        @document = Data.freeze(document)
        @warnings = Data.freeze(warnings)
        @bindings = Data.freeze(bindings.sort_by { |binding| binding['operation'].values_at('kind', 'id') })
        @implementation_ids = Data.freeze(implementations.keys.sort)
        @builtin_bindings = Data.freeze(@bindings.select { |binding| binding['kind'] == 'builtin' })
        @binding_index = @bindings.to_h { |binding| [binding['operation'].values_at('kind', 'id').freeze, binding] }.freeze
        # Executable closures stay private. Their captured state is not made
        # shareable by freezing a Proc; only the data views are shareable.
        @implementations = implementations.dup.freeze
        freeze
      end

      def binding_for(kind, id)
        @binding_index.fetch([kind, id]) do
          raise Error.single('binding_missing', "Vínculo não encontrado: #{kind} #{id}.")
        end
      end
    end
  end
end

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

      # Porta da borda confiável (o Runner, ADR-045): roda o bloco Ruby verificado da operação com o hospedeiro dado.
      # O bloco continua privado; só esta chamada o executa, e só para uma operação Ruby.
      def run_implementation(kind, id, host:, input:, arguments:)
        binding = binding_for(kind, id)
        unless binding['kind'] == 'ruby'
          raise Error.single('implementation_not_ruby', "A operação #{id} usa uma primitiva, não um bloco Ruby.")
        end
        # O método do BasicObject, e não o do hospedeiro: um instance_exec redefinido por ele devolveria o bloco privado.
        BasicObject.instance_method(:instance_exec).bind_call(host, input, *arguments, &@implementations.fetch(binding['ref']))
      end
    end
  end
end

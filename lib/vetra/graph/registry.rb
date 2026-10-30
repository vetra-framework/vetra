module Vetra
  module Graph
    class Registry
      attr_reader :declarations, :bindings, :application

      def initialize
        @declarations = []
        @bindings = {}
        @application = nil
        @sealed = false
      end

      def app(attributes)
        ensure_open!
        raise Error.single("duplicate_app", "Declare Vetra.app uma única vez.", source: attributes['source']) if @application
        @application = attributes
      end

      def add(declaration, block: nil)
        ensure_open!
        key = declaration.values_at("kind", "id")
        if declarations.any? { |entry| entry.values_at("kind", "id") == key }
          raise Error.single("duplicate_id", "Identidade repetida: #{key.join(' ')}.", source: declaration['source'])
        end
        if block
          reference = "#{declaration.fetch('id')}#call"
          raise Error.single("duplicate_implementation", "Implementação repetida: #{reference}.", source: declaration['source']) if bindings.key?(reference)
          @bindings[reference] = block
        end
        @declarations << declaration
      end

      def seal!
        ensure_open!
        @sealed = true
        Data.freeze(@application)
        Data.freeze(@declarations)
        @bindings.each_value(&:freeze)
        @bindings.freeze
        freeze
      end

      private

      def ensure_open!
        raise Error.single("registry_frozen", "O registro já está congelado; inicie outro build.") if @sealed
      end
    end
  end
end

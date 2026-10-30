module Vetra
  module Graph
    # Evaluates trusted project declarations once into a fresh, sealed registry.
    # Both compilation and linking use this path; neither executes a call body.
    class DeclarationLoader
      def initialize(manifest)
        @manifest = manifest
      end

      def load
        registry = Registry.new
        paths = @manifest.entries.map { |entry| entry['path'] }
        declarations = paths.grep(/\Aapp\/domains\/.*\.rb\z/).sort_by do |path|
          [path.split('/')[2], File.basename(path) == 'domain.rb' ? 0 : 1, path]
        end
        ['config/app.rb', *declarations].each do |path|
          domain = path == 'config/app.rb' ? nil : path.split('/')[2]
          origin = { 'path' => path, 'line' => 1 }
          if domain && !domain.match?(/\A[a-z][a-z0-9_]*\z/)
            raise Error.single('domain_name', 'Use nomes de domínio em snake_case ASCII.', source: origin)
          end
          context = DSL::Context.new(registry, @manifest, domain, origin)
          previous = Thread.current[:vetra_graph_context]
          begin
            Thread.current[:vetra_graph_context] = context
            context.evaluate_source(@manifest.read(path), @manifest.root.join(path).to_s)
          rescue SyntaxError, ArgumentError, TypeError, NameError => error
            raise Error.single('dsl_error', "Declaração inválida (#{error.class}): #{error.message.lines.first&.strip}", source: origin)
          ensure
            Thread.current[:vetra_graph_context] = previous
          end
        end
        registry.seal!
      end
    end
  end
end

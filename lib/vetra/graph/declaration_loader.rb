module Vetra
  module Graph
    # Evaluates trusted project declarations once into a fresh, sealed registry.
    # Both compilation and linking use this path; neither executes a call body.
    class DeclarationLoader
      KEYWORD_ERROR = /\A(unknown|missing) keywords?: (.+)\z/

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
            raise(keyword_error(error, path, origin) ||
              Error.single('dsl_error', "Declaração inválida (#{error.class}): #{error.message.lines.first&.strip}", source: origin))
          ensure
            Thread.current[:vetra_graph_context] = previous
          end
        end
        registry.seal!
      end

      private

      # Uma palavra-chave desconhecida ou ausente numa declaração vira um diagnóstico que nomeia a opção, o método e a
      # linha da declaração, em vez do ArgumentError do Ruby apontando a linha 1. Qualquer outro erro continua sendo
      # dsl_error.
      def keyword_error(error, path, origin)
        return unless error.is_a?(ArgumentError)
        match = KEYWORD_ERROR.match(error.message.lines.first.to_s.strip) or return
        names = match[2].split(', ').map { |name| name.delete_prefix(':') }.join(', ')
        locations = error.backtrace_locations || []
        method = locations.first&.base_label
        place = method&.match?(/\A[a-z_]+[!?]?\z/) ? " em #{method}" : ''
        file = @manifest.root.join(path).to_s
        frame = locations.find { |location| (location.absolute_path || location.path) == file }
        source = frame ? origin.merge('line' => frame.lineno) : origin
        if match[1] == 'unknown'
          Error.single('unsupported_option', "Opções não implementadas#{place}: #{names}.", source: source)
        else
          Error.single('missing_option', "Opções obrigatórias ausentes#{place}: #{names}.", source: source)
        end
      end
    end
  end
end

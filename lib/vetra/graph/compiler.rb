require "tempfile"

module Vetra
  module Graph
    Result = Struct.new(:document, :warnings, :implementation_ids, keyword_init: true) do
      def bytes
        "#{Canonical.dump(document)}\n"
      end
    end

    class Compiler
      attr_reader :root

      def initialize(root: Dir.pwd)
        @root = Pathname.new(root).realpath
      rescue Errno::ENOENT, Errno::ENOTDIR
        raise Error.single('project_root', 'Diretório do projeto não existe.')
      end

      def build
        manifest = Manifest.new(root)
        registry = Registry.new
        paths = manifest.entries.map { |entry| entry['path'] }
        declarations = paths.grep(/\Aapp\/domains\/.*\.rb\z/).sort_by { |path| [path.split('/')[2], File.basename(path) == 'domain.rb' ? 0 : 1, path] }
        ['config/app.rb', *declarations].each do |path|
          domain = path == 'config/app.rb' ? nil : path.split('/')[2]
          if domain && !domain.match?(/\A[a-z][a-z0-9_]*\z/)
            raise Error.single('domain_name', 'Use nomes de domínio em snake_case ASCII.', source: { 'path' => path, 'line' => 1 })
          end
          context = DSL::Context.new(registry, manifest, domain, { 'path' => path, 'line' => 1 })
          previous = Thread.current[:vetra_graph_context]
          begin
            Thread.current[:vetra_graph_context] = context
            context.evaluate_source(manifest.read(path), root.join(path).to_s)
          rescue SyntaxError, ArgumentError, TypeError, NameError => e
            raise Error.single('dsl_error', "Declaração inválida (#{e.class}): #{e.message.lines.first&.strip}", source: { 'path' => path, 'line' => 1 })
          ensure
            Thread.current[:vetra_graph_context] = previous
          end
        end
        registry.seal!
        document = Normalizer.new(registry, manifest).document
        validator = Validator.new
        validator.validate!(document)
        Manifest.new(root).verify!(document)
        Data.freeze(Result.new(document: document, warnings: validator.warnings, implementation_ids: registry.bindings.keys.sort))
      end

      def write
        result = build
        directory = root.join('.vetra')
        directory.mkdir unless directory.exist?
        unless directory.realpath.to_s.start_with?("#{root}/") && !directory.symlink?
          raise Error.single('artifact_path', '.vetra deve ser um diretório dentro do projeto.')
        end
        Tempfile.create(['graph-', '.json'], directory.to_s) do |file|
          file.binmode
          file.write(result.bytes)
          file.flush
          file.fsync
          file.close
          File.rename(file.path, artifact.to_s)
        end
        result
      end

      def check
        result = build
        unless artifact.file? && !artifact.symlink? && artifact.binread == result.bytes
          raise Error.single('graph_stale', 'IR ausente ou desatualizada; execute graph:build e revise .vetra/graph.json.')
        end
        result
      end

      def validate_file(path, sources: false)
        document = Canonical.parse(File.binread(path))
        validator = Validator.new
        validator.validate!(document)
        Manifest.new(root).verify!(document) if sources
        Data.freeze(Result.new(document: document, warnings: validator.warnings, implementation_ids: []))
      rescue Errno::ENOENT, Errno::ENOTDIR
        raise Error.single('graph_missing', 'Arquivo da IR não existe.')
      end

      def artifact
        root.join('.vetra/graph.json')
      end
    end
  end
end

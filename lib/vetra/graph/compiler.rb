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
        document, registry, warnings = compile(manifest)
        Manifest.new(root).verify!(document)
        Data.freeze(Result.new(document: document, warnings: warnings, implementation_ids: registry.bindings.keys.sort))
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
          file.chmod(0o666 & ~File.umask)
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

      def link
        bytes = artifact_bytes
        document = Canonical.parse(bytes)
        Validator.new.validate!(document)
        unless bytes == "#{Canonical.dump(document)}\n"
          raise Error.single('graph_not_canonical', 'O artefato deve usar JSON canônico seguido de LF; execute graph:build no pipeline.')
        end
        producer = document.fetch('producer')
        unless producer['version'] == Vetra::VERSION && producer['ruby_version'] == RUBY_VERSION
          raise Error.single('producer_mismatch', 'Versões do Vetra/Ruby diferem do build; carregue o pacote com as versões registradas.', pointer: '/producer')
        end
        manifest = Manifest.new(root)
        manifest.verify!(document)
        Data.freeze(document)

        # Registration is needed to recreate Ruby closures in this process. The
        # normalized declaration is an audit only: it never replaces the artifact.
        audit, registry, warnings = compile(manifest)
        unless Canonical.dump(audit) == Canonical.dump(document)
          raise Error.single('graph_model_mismatch', 'As declarações carregadas diferem da IR aprovada; reconstrua e revise o pacote.')
        end
        linked = Linker.new(document, manifest).link(registry, warnings: warnings)
        Manifest.new(root).verify!(document)
        unless artifact_bytes == bytes
          raise Error.single('graph_changed', 'O artefato mudou durante a vinculação; use um pacote imutável.')
        end
        linked
      end

      private

      def compile(manifest)
        registry = DeclarationLoader.new(manifest).load
        document = Normalizer.new(registry, manifest).document
        warnings = Validator.new.validate!(document)
        [document, registry, warnings]
      end

      def artifact_bytes
        unless artifact.file? && !artifact.symlink?
          raise Error.single('graph_missing', 'IR ausente ou não regular; publique .vetra/graph.json junto ao pacote.')
        end
        if artifact.dirname.symlink? || !artifact.dirname.realpath.to_s.start_with?("#{root}/")
          raise Error.single('artifact_path', '.vetra deve ser um diretório dentro do projeto.')
        end
        artifact.binread
      rescue Errno::ENOENT, Errno::ENOTDIR
        raise Error.single('graph_missing', 'Arquivo da IR não existe.')
      end
    end
  end
end

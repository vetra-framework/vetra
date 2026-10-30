require "open3"

module Vetra
  module Graph
    class DiffSource
      def initialize(root: Dir.pwd)
        @root = Pathname.new(root).realpath
      rescue Errno::ENOENT, Errno::ENOTDIR
        raise Error.single('project_root', 'Diretório do projeto não existe.')
      end

      def read(input)
        bytes = input.start_with?('git:') ? read_revision(input.delete_prefix('git:')) : File.binread(input)
        Canonical.parse(bytes)
      rescue Errno::ENOENT, Errno::ENOTDIR
        raise Error.single('graph_missing', "Arquivo da IR não existe: #{input}.")
      rescue Error => error
        raise Error.new(error.diagnostics.map do |diagnostic|
          Diagnostic.new(**diagnostic.to_h.merge(message: "Entrada #{input}: #{diagnostic.message}"))
        end)
      end

      private

      def git(*arguments)
        Open3.capture3('git', '-C', @root.to_s, *arguments)
      rescue Errno::ENOENT
        raise Error.single('git_unavailable', 'Git não está disponível; forneça dois arquivos JSON.')
      end

      def read_revision(reference)
        raise Error.single('git_reference', 'Informe uma revisão depois de git:.') if reference.empty?
        @prefix ||= begin
          output, _error, status = git('rev-parse', '--show-prefix')
          raise Error.single('git_repository', '--root deve apontar para uma aplicação dentro de um repositório Git.') unless status.success?
          output.delete_suffix("\n")
        end
        commit, _error, status = git('rev-parse', '--verify', '--end-of-options', "#{reference}^{commit}")
        unless status.success? && commit.delete_suffix("\n").match?(/\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/)
          raise Error.single('git_reference', "Revisão Git inválida: #{reference}.")
        end
        path = "#{@prefix}.vetra/graph.json"
        bytes, _error, status = git('cat-file', 'blob', "#{commit.delete_suffix("\n")}:#{path}")
        unless status.success?
          raise Error.single('git_graph_missing', "IR ausente em #{reference}:#{path}; confira a revisão e --root.")
        end
        bytes
      end
    end
  end
end

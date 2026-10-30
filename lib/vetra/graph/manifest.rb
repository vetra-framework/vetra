require "find"
require "pathname"

module Vetra
  module Graph
    class Manifest
      REQUIRED = %w[config/app.rb Gemfile Gemfile.lock .ruby-version].freeze
      attr_reader :root, :entries

      def initialize(root, extra_paths: [])
        @root = Pathname.new(root).realpath
        @bytes = {}
        paths = REQUIRED + extra_paths
        %w[app lib config].each do |directory|
          base = @root.join(directory)
          next unless base.exist? || base.symlink?
          Find.find(base.to_s) do |path|
            relative = Pathname.new(path).relative_path_from(@root).to_s
            if Pathname.new(path).basename.to_s.match?(/\A(?:secrets|credentials)(?:\.|\z)|\A\.env|\.(?:key|pem|enc)\z/)
              Find.prune if File.directory?(path)
              next
            end
            checked_path(relative)
            if File.symlink?(path) && File.directory?(path)
              raise Error.single("input_symlink", "Diretórios de entrada não podem ser links: #{relative}.")
            end
            paths << relative if File.file?(path)
          end
        end
        @entries = paths.uniq.sort.map do |path|
          @bytes[path] = checked_path(path).binread
          { "path" => path, "digest" => "sha256:#{Digest::SHA256.hexdigest(@bytes.fetch(path))}" }
        end
        Data.freeze(@entries)
      rescue Errno::ENOENT, Errno::ENOTDIR => e
        raise Error.single("input_missing", "Entrada ausente; confira config/app.rb, Gemfile, Gemfile.lock e .ruby-version (#{e.class}).")
      end

      def read(path)
        @bytes.fetch(path).dup.force_encoding(Encoding::UTF_8)
      end

      def digest_for(path)
        @entries.find { |entry| entry['path'] == path }.fetch("digest")
      end

      def source(path, line)
        absolute = Pathname.new(path).expand_path
        relative = absolute.relative_path_from(root).to_s
        checked_path(relative)
        { "path" => relative, "line" => line }
      end

      def verify!(document)
        unless entries == document.fetch("inputs")
          raise Error.single("inputs_changed", "Fontes adicionados, removidos ou alterados; execute graph:build no build de release.", pointer: "/inputs")
        end
      end

      private

      def checked_path(path)
        pieces = path.split("/", -1)
        if path.empty? || path.start_with?("/") || path.match?(/\A[A-Za-z]:|[\\\x00-\x1f]/) || pieces.any? { |part| %w[. ..].include?(part) || part.empty? }
          raise Error.single("input_path", "Use caminho relativo sem travessia: #{path.inspect}.")
        end
        if pieces.any? { |part| part == ".vetra" || part.match?(/\A(?:secrets|credentials)(?:\.|\z)|\A\.env|\.(?:key|pem|enc)\z/) }
          raise Error.single("input_path", "Cache e segredos não são entradas da IR.")
        end
        actual = root.join(path).realpath
        unless actual.to_s.start_with?("#{root}/")
          raise Error.single("input_path", "Entrada escapa da raiz do projeto: #{path}.")
        end
        actual
      end
    end
  end
end

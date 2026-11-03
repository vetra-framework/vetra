#!/usr/bin/env ruby
require 'optparse'
require 'open3'
require 'pathname'
require 'vetra'

module VetraCI
  class GraphGate
    class Failure < StandardError; end

    def initialize(root:, out: $stdout, summary: nil)
      @root, @out, @summary = Pathname.new(root).realpath, out, summary
    end

    def run(base:, initial_push: false)
      @reports = []
      exceptions = compatibility_declarations
      if initial_push && base == '0' * 40
        @out.puts '::notice::Primeiro push: não existe grafo anterior; os exemplos passam por check, validate e link.'
        return 0
      end
      raise Failure, 'Base vazia ou inicial sem --initial-push.' if base.to_s.empty? || base == '0' * 40 || initial_push
      revision = git('rev-parse', '--verify', '--end-of-options', "#{base}^{commit}").strip
      paths = git('ls-tree', '-r', '-z', '--name-only', revision).split("\0").select do |path|
        path.match?(%r{(?:\A|/)\.vetra/graph\.json\z})
      end
      @out.puts '::notice::A base não tem grafos: nada a comparar.' if paths.empty?
      failed = false
      paths.each do |path|
        unless @root.join(path).file? && !@root.join(path).symlink?
          @out.puts "::error::Artefato removido ou não regular: #{path} existe na base e precisa de revisão própria."
          failed = true
          next
        end
        app = File.dirname(File.dirname(path))
        before = Vetra::Graph::DiffSource.new(root: @root.join(app)).read("git:#{revision}")
        after = Vetra::Graph::Canonical.parse(@root.join(path).binread)
        report = Vetra::Graph::Diff.new.compare(before, after)
        @out.puts "graph:diff #{app} contra #{revision}"
        @out.puts report.to_text
        @reports << [path, report]
        next unless report.breaking?
        declaration = exceptions.find do |entry|
          entry['artifact'] == path && entry['before_digest'] == before['digest'] && entry['after_digest'] == after['digest']
        end
        if declaration
          @out.puts "::warning::Quebra intencional declarada para #{path}: #{declaration['reason']}"
        else
          @out.puts "::error::Quebra sem declaração de compatibilidade para os digests exatos de #{path}."
          failed = true
        end
      end
      failed ? 1 : 0
    rescue Failure, Vetra::Graph::Error, SystemCallError => error
      @out.puts "::error::#{error.message}"
      1
    ensure
      write_summary
    end

    private

    def git(*arguments)
      output, error, status = Open3.capture3('git', '-C', @root.to_s, *arguments)
      raise Failure, "Falha ao ler a base (git #{arguments.first}): #{error.strip}" unless status.success?
      output
    end

    def compatibility_declarations
      path = @root.join('.github/graph-compatibility.json')
      return [] unless path.exist?
      document = Vetra::Graph::Canonical.parse(path.binread)
      unless document.is_a?(Hash) && document.keys.sort == %w[changes format_version] && document['format_version'] == '1' && document['changes'].is_a?(Array)
        raise Failure, 'Declaração de compatibilidade inválida.'
      end
      entries = document['changes']
      entries.each do |entry|
        valid = entry.is_a?(Hash) && entry.keys.sort == %w[after_digest artifact before_digest reason]
        valid &&= entry.values.all? { |value| value.is_a?(String) }
        valid &&= %w[before_digest after_digest].all? { |key| entry[key].match?(/\Asha256:[0-9a-f]{64}\z/) }
        valid &&= !entry['reason'].strip.empty?
        raise Failure, 'Cada quebra intencional exige artefato, digests exatos e motivo.' unless valid
      end
      keys = entries.map { |entry| entry.values_at('artifact', 'before_digest', 'after_digest') }
      raise Failure, 'Declarações de compatibilidade duplicadas.' unless keys.uniq == keys
      entries
    end

    def write_summary
      return unless @summary && @reports
      File.open(@summary, 'a') do |file|
        file.puts "## Diff arquitetural\n\nMudanças marcadas para revisão exigem revisão do mantenedor antes da integração."
        @reports.each do |path, report|
          counts = report.data['summary']
          file.puts "\n### `#{path}`\n\n#{counts['breaking']} quebras potenciais; #{counts['requires_review']} mudanças exigem revisão.\n"
          report.data['changes'].select { |change| change['requires_review'] }.each do |change|
            file.puts "- `#{change['impact']}`: `#{change['kind']} #{change['id']} #{change['path']}`"
          end
        end
      end
    end
  end
end

if $PROGRAM_NAME == __FILE__
  options = { root: Dir.pwd, initial_push: false }
  parser = OptionParser.new do |arguments|
    arguments.on('--base REF') { |value| options[:base] = value }
    arguments.on('--root ROOT') { |value| options[:root] = value }
    arguments.on('--initial-push') { options[:initial_push] = true }
  end
  begin
    parser.parse!
    raise OptionParser::MissingArgument, '--base' unless options[:base]
    raise OptionParser::InvalidArgument, ARGV.join(' ') unless ARGV.empty?
    gate = VetraCI::GraphGate.new(root: options[:root], summary: ENV['GITHUB_STEP_SUMMARY'])
    exit gate.run(base: options[:base], initial_push: options[:initial_push])
  rescue OptionParser::ParseError => error
    warn error.message
    exit 2
  end
end

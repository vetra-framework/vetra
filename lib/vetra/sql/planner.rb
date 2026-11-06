# frozen_string_literal: true

require 'digest'
require 'fileutils'

module Vetra
  module SQL
    # `vetra db:plan`: cada plano é gravado com o seu modelo físico (ADR-038, §1), o próximo plano é calculado contra o
    # modelo do último, e o retrato db/schema.sql é o resultado de aplicar os planos num banco descartável (ADR-025, §1).
    # Os planos antigos não são regenerados: a cadeia de SHA-256 dos modelos os prende, e só o último é recalculado.
    class Planner
      PLANS = 'db/plans'
      MODELS = Model::DIRECTORY
      SCHEMA = 'db/schema.sql'
      POLICIES = 'db/policies/0001_seguranca.sql'
      SCHEMA_HEADER = "-- Retrato do esquema: resultado de aplicar db/plans/ num banco vazio (vetra db:plan --snapshot).\n" \
                      "-- Gerado a partir do pg_dump --schema-only normalizado, com donos; não edite à mão.\n"
      BASE = /\A-- vetra:base (\d{4}_[a-z][a-z0-9_]*) sha256=([0-9a-f]{64})\z/

      Result = Struct.new(:status, :plans, :path, keyword_init: true)

      # Sem diferença entre modelos (C9), um modelo que mudou é recusado. A diferença recebe o modelo de base, o esquema
      # da IR e o número do próximo plano, e devolve um Plan.
      REFUSE = lambda do |base:, schema:, number:|
        detail = number == '0002' ? ' Um banco que nunca recebeu o plano pode recomeçar removendo db/plans e db/models.' : ''
        raise Graph::Error.single('db_plan_incremental', "A IR mudou desde #{PLANS}/#{base.document.dig('plan', 'file')}, e o plano incremental " \
                                                         "ainda não calcula diferenças (rodada 4, C9).#{detail}")
      end

      # Corpo e bases de um retrato: o cabeçalho, uma linha `-- vetra:base` por plano, uma linha vazia e o dump.
      def self.render_schema(bases, body)
        SCHEMA_HEADER + bases.map { |name, digest| "-- vetra:base #{name} sha256=#{digest}\n" }.join + "\n" + body
      end

      def self.parse_schema(text)
        return nil unless text.start_with?(SCHEMA_HEADER)
        lines = text.delete_prefix(SCHEMA_HEADER).lines
        bases = []
        while (match = BASE.match(lines.first.to_s.chomp))
          bases << match.captures
          lines.shift
        end
        return nil unless lines.first == "\n"
        { bases: bases, body: lines.drop(1).join }
      end

      # O dump que um retrato descreve, sem cabeçalho nem bases; nil num arquivo fora do formato.
      def self.schema_body(text)
        parse_schema(text)&.fetch(:body)
      end

      def initialize(root:, database: nil, differ: REFUSE)
        @root = File.expand_path(root)
        @database = database
        @differ = differ
      end

      # Grava o plano inicial, o modelo de um plano inicial antigo ou o próximo plano; não toca em banco.
      def plan
        expected!
        plans, models = read_plans, read_models
        if plans.empty?
          raise Graph::Error.single('db_model_chain', "#{MODELS} tem modelos sem plano; remova-os ou restaure #{PLANS}.") unless models.empty?
          path = write_plan(@initial, nil)
          FileUtils.mkdir_p(File.dirname(File.join(@root, POLICIES)))
          File.write(File.join(@root, POLICIES), @security.artifact)
          return Result.new(status: :written, plans: [@initial], path: path)
        end
        if models.empty? && plans.size == 1 && plans.first.render == @initial.render
          # Plano inicial gravado antes do ADR-038: ganha o modelo que a mesma IR gera, com o espelho conferido antes.
          ensure_policies!
          model = Model.build(@initial, @state)
          write_model(model)
          return Result.new(status: :written, plans: plans, path: File.join(@root, MODELS, model.file))
        end
        verify_chain!(plans, models)
        if models.last.same_state?(@state)
          ensure_latest!(plans, models)
          ensure_policies!
          return Result.new(status: :unchanged, plans: plans, path: File.join(@root, PLANS, plans.last.file_name))
        end
        following = @differ.call(base: models.last, schema: @schema, number: format('%04d', plans.size + 1))
        path = write_plan(following, models.last)
        Result.new(status: :written, plans: plans + [following], path: path)
      end

      # Regrava db/schema.sql aplicando os planos commitados num banco descartável, depois de conferi-los sem banco.
      def snapshot
        plans = verified_plans
        dumps = database.replay(plans)
        dumps = converge!(plans, dumps)
        path = File.join(@root, SCHEMA)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, self.class.render_schema(bases(plans, dumps), dumps.last))
        Result.new(status: :written, plans: plans, path: path)
      end

      # Falha se os planos não forem os que a IR e a cadeia pedem, ou se o retrato não for o resultado deles
      # (ADR-025, §1, item 3, e ADR-038, §3).
      def check
        plans = verified_plans
        target = database
        path = File.join(@root, SCHEMA)
        raise Graph::Error.single('db_schema_missing', "#{SCHEMA} não existe; execute vetra db:plan --snapshot.") unless File.file?(path)
        dumps = converge!(plans, target.replay(plans))
        compare_schema!(File.binread(path).force_encoding(Encoding::UTF_8), self.class.render_schema(bases(plans, dumps), dumps.last))
        Result.new(status: :checked, plans: plans, path: path)
      end

      # Planos que o db:migrate pode aplicar: os commitados, conferidos antes de qualquer acesso ao banco.
      def migration_plans
        verified_plans
      end

      def compare_schema!(committed, produced)
        return if committed == produced
        line = committed.lines.zip(produced.lines).index { |a, b| a != b } || [committed.lines.size, produced.lines.size].min
        raise Graph::Error.single('db_schema_stale', "#{SCHEMA} difere do resultado dos planos a partir da linha #{line + 1}; " \
                                                     'execute vetra db:plan --snapshot e revise a diferença.')
      end

      private

      def database
        @database or raise Graph::Error.single('db_database_url', 'Defina DATABASE_URL com um servidor PostgreSQL descartável, onde o papel possa criar bancos.')
      end

      def expected!
        document = Graph::Compiler.new(root: @root).read_artifact.document
        @schema = Schema.new(document).generate
        @security = Security.new(@schema).generate
        @initial = Plan.initial(@schema)
        @state = Model.state(@schema, @initial)
      end

      def verified_plans
        expected!
        plans, models = read_plans, read_models
        raise Graph::Error.single('db_plan_missing', "Nenhum plano em #{PLANS}; execute vetra db:plan.") if plans.empty?
        verify_chain!(plans, models)
        unless models.last.same_state?(@state)
          raise Graph::Error.single('db_plan_stale', "A IR mudou desde #{PLANS}/#{plans.last.file_name}; execute vetra db:plan e revise o plano novo.")
        end
        ensure_latest!(plans, models)
        ensure_policies!
        plans
      end

      # Com mais de um plano, aplicar todos e aplicar o plano inicial da IR atual num banco vazio precisa dar o mesmo
      # retrato: é o que mostra que o modelo descreve o banco, e não só a IR (ADR-038, §3).
      def converge!(plans, dumps)
        return dumps if plans.size == 1
        fresh, replayed = self.class.structural(database.replay([@initial]).last), self.class.structural(dumps.last)
        return dumps if fresh == replayed
        line = replayed.lines.zip(fresh.lines).index { |a, b| a != b } || 0
        raise Graph::Error.single('db_plan_convergence', "Aplicar #{PLANS} não dá o esquema que a IR cria num banco vazio (diferença na linha " \
                                                         "#{line + 1} do dump sem a ordem das colunas); o modelo de #{plans.last.file_name} não descreve o banco.")
      end

      # Um dump em que a ordem das definições de cada CREATE TABLE não conta. Uma coluna acrescentada por ADD COLUMN fica
      # no fim da tabela, e o plano inicial ordena as colunas pelo nome. Cada definição (coluna ou restrição) é comparada
      # inteira, com os literais de várias linhas intactos; só a ordem entre elas é ignorada. O resto do dump (donos,
      # ACLs, RLS, índices, funções) continua comparado na ordem. Só a convergência usa esta forma: o retrato segue exato.
      def self.structural(dump)
        out, items, current, scanner = [], nil, [], StatementScanner.new
        # Tira só o LF de cada linha: um CR dentro de um literal é dado e precisa contar na comparação.
        dump.each_line do |raw|
          line = raw.delete_suffix("\n")
          if items && !scanner.literal? && line.start_with?(')')
            items << current unless current.empty?
            out.concat(items.map { |item| item.join("\n").delete_suffix(',') }.sort)
            out << line
            items, current = nil, []
          elsif items
            current << line
            scanner.feed(line)
            if !scanner.literal? && line.end_with?(',')
              items << current
              current = []
            end
            next
          else
            out << line
            items = [] if scanner.boundary? && line.match?(/\ACREATE (UNLOGGED )?TABLE .* \($/)
          end
          scanner.feed(line)
        end
        out.concat(items.flatten + current) if items
        "#{out.join("\n")}\n"
      end

      def bases(plans, dumps)
        plans.zip(dumps).map { |plan, dump| [plan.file_name.delete_suffix('.sql'), Digest::SHA256.hexdigest(dump)] }
      end

      def write_plan(plan, previous)
        FileUtils.mkdir_p(File.join(@root, PLANS))
        path = File.join(@root, PLANS, plan.file_name)
        File.write(path, plan.render)
        write_model(Model.build(plan, @state, previous: previous))
        path
      end

      def write_model(model)
        FileUtils.mkdir_p(File.join(@root, MODELS))
        File.write(File.join(@root, MODELS, model.file), model.text)
      end

      # Cada plano tem o seu modelo, e cada modelo repete a cadeia do anterior com o SHA-256 dos arquivos: editar,
      # trocar ou remover um plano ou modelo antigo é recusado antes de qualquer acesso ao banco.
      def verify_chain!(plans, models)
        names = ->(list) { list.map { |item| item.respond_to?(:file_name) ? item.file_name.delete_suffix('.sql') : item.file.delete_suffix('.json') } }
        unless names.call(plans) == names.call(models)
          raise Graph::Error.single('db_model_chain', "Cada plano de #{PLANS} precisa do modelo de mesmo nome em #{MODELS}, e só ele " \
                                                      "(planos: #{names.call(plans).join(', ')}; modelos: #{names.call(models).join(', ')}).")
        end
        chain = []
        plans.zip(models).each_with_index do |(plan, model), index|
          entry = { 'file' => plan.file_name, 'sha256' => Digest::SHA256.hexdigest(plan.render) }
          chain << entry
          previous = index.zero? ? nil : { 'file' => models[index - 1].file, 'sha256' => Digest::SHA256.hexdigest(models[index - 1].text) }
          next if model.document['plan'] == entry && model.document['plans'] == chain && model.document['previous'] == previous
          raise Graph::Error.single('db_model_chain', "#{MODELS}/#{model.file} não corresponde a #{PLANS}/#{plan.file_name} e aos modelos anteriores; " \
                                                      'um plano ou modelo já gravado não se edita.')
        end
      end

      # O último plano é o que a IR gera a partir do modelo anterior: o inicial, ou a diferença da C9.
      def ensure_latest!(plans, models)
        expected = plans.size == 1 ? @initial : @differ.call(base: models[-2], schema: @schema, number: plans.last.number)
        return if plans.last.render == expected.render
        raise Graph::Error.single('db_plan_stale', "#{PLANS}/#{plans.last.file_name} difere do que a IR gera. Um banco que nunca recebeu o plano pode " \
                                                   'recomeçar removendo db/plans e db/models; um banco aplicado exige um plano novo.')
      end

      def ensure_policies!
        directory = File.join(@root, 'db/policies')
        path = File.join(@root, POLICIES)
        unless File.directory?(directory) && Dir.children(directory).sort == [File.basename(POLICIES)] &&
               File.file?(path) && File.binread(path) == @security.artifact.b
          raise Graph::Error.single('db_policies_stale', "#{POLICIES} deve ser o espelho exato da segurança gerada; revise a IR e regenere os artefatos do banco vazio juntos.")
        end
      end

      def read_plans
        read_directory(PLANS) do |entry, text|
          plan = Plan.parse(text, file: "#{PLANS}/#{entry}")
          # Reescrever o texto no formato canônico pega edições que o parser aceitaria mas o gerador não emitiria.
          raise Graph::Error.single('db_plan_format', "#{PLANS}/#{entry}: fora do formato canônico do plano.") unless plan.render == text
          plan
        end.tap do |plans|
          numbers = plans.map(&:number)
          raise Graph::Error.single('db_plan_format', "#{PLANS}: números de plano repetidos.") unless numbers.uniq == numbers
          unless numbers == (1..numbers.size).map { |number| format('%04d', number) }
            raise Graph::Error.single('db_plan_format', "#{PLANS}: os planos são numerados em sequência a partir de 0001.")
          end
        end
      end

      def read_models
        read_directory(MODELS) { |entry, text| Model.new(file: entry, text: text) }
      end

      def read_directory(relative)
        directory = File.join(@root, relative)
        return [] unless File.directory?(directory)
        Dir.children(directory).sort.map do |entry|
          path = File.join(directory, entry)
          raise Graph::Error.single(relative == PLANS ? 'db_plan_format' : 'db_model_format', "#{relative}/#{entry}: só arquivos #{relative == PLANS ? 'NNNN_nome.sql' : 'NNNN_nome.json'}.") unless File.file?(path)
          yield entry, File.binread(path).force_encoding(Encoding::UTF_8)
        end
      end
    end
  end
end

# frozen_string_literal: true

require 'fileutils'

module Vetra
  module SQL
    # `vetra db:plan`: o plano é função da IR, e o retrato db/schema.sql é o resultado de aplicar os planos num banco
    # descartável (ADR-025, §1). Nesta rodada só existe o plano inicial, de um banco vazio; mudar o esquema de um banco
    # que já tem plano exige o plano incremental, ainda não implementado.
    class Planner
      PLANS = 'db/plans'
      SCHEMA = 'db/schema.sql'
      SCHEMA_HEADER = "-- Retrato do esquema: resultado de aplicar db/plans/ num banco vazio (vetra db:plan --snapshot).\n" \
                      "-- Gerado a partir do pg_dump --schema-only normalizado, com donos; não edite à mão.\n\n"

      Result = Struct.new(:status, :plans, :path, keyword_init: true)

      def initialize(root:, database: nil)
        @root = File.expand_path(root)
        @database = database
      end

      # Grava o plano inicial se ainda não houver plano; não toca em banco.
      def plan
        expected = expected_plan
        plans = read_plans
        if plans.empty?
          FileUtils.mkdir_p(File.join(@root, PLANS))
          path = File.join(@root, PLANS, expected.file_name)
          File.write(path, expected.render)
          return Result.new(status: :written, plans: [expected], path: path)
        end
        ensure_current!(plans, expected)
        Result.new(status: :unchanged, plans: plans, path: File.join(@root, PLANS, plans.first.file_name))
      end

      # Regrava db/schema.sql aplicando os planos commitados num banco descartável. Só aplica planos que a IR gera:
      # um plano editado à mão poderia mexer em objetos do servidor inteiro, fora do banco temporário.
      def snapshot
        plans = read_plans
        raise Graph::Error.single('db_plan_missing', "Nenhum plano em #{PLANS}; execute vetra db:plan.") if plans.empty?
        ensure_current!(plans, expected_plan)
        target = database
        path = File.join(@root, SCHEMA)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, SCHEMA_HEADER + target.apply_and_dump(plans))
        Result.new(status: :written, plans: plans, path: path)
      end

      # Falha se o plano não for o que a IR gera ou se o retrato não for o resultado dos planos (ADR-025, §1, item 3).
      def check
        plans = read_plans
        raise Graph::Error.single('db_plan_missing', "Nenhum plano em #{PLANS}; execute vetra db:plan.") if plans.empty?
        ensure_current!(plans, expected_plan)
        target = database
        path = File.join(@root, SCHEMA)
        raise Graph::Error.single('db_schema_missing', "#{SCHEMA} não existe; execute vetra db:plan --snapshot.") unless File.file?(path)
        compare_schema!(File.binread(path).force_encoding(Encoding::UTF_8), SCHEMA_HEADER + target.apply_and_dump(plans))
        Result.new(status: :checked, plans: plans, path: path)
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

      def expected_plan
        document = Graph::Compiler.new(root: @root).read_artifact.document
        Plan.initial(Schema.new(document).generate)
      end

      def ensure_current!(plans, expected)
        unless plans.size == 1 && plans.first.file_name == expected.file_name
          raise Graph::Error.single('db_plan_incremental', "#{PLANS} tem planos além do inicial; o plano incremental ainda não existe (rodada 4).")
        end
        return if plans.first.render == expected.render
        raise Graph::Error.single('db_plan_stale', "#{PLANS}/#{expected.file_name} difere do que a IR gera. Um banco vazio pode " \
                                                   'recomeçar removendo o plano e executando vetra db:plan; um banco aplicado exige o plano incremental.')
      end

      def read_plans
        directory = File.join(@root, PLANS)
        return [] unless File.directory?(directory)
        entries = Dir.children(directory).sort
        plans = entries.map do |entry|
          path = File.join(directory, entry)
          raise Graph::Error.single('db_plan_format', "#{PLANS}/#{entry}: só arquivos de plano NNNN_nome.sql.") unless File.file?(path)
          plan = Plan.parse(File.binread(path).force_encoding(Encoding::UTF_8), file: "#{PLANS}/#{entry}")
          # Reescrever o texto no formato canônico pega edições que o parser aceitaria mas o gerador não emitiria.
          raise Graph::Error.single('db_plan_format', "#{PLANS}/#{entry}: fora do formato canônico do plano.") unless plan.render == File.binread(path).force_encoding(Encoding::UTF_8)
          plan
        end
        numbers = plans.map(&:number)
        raise Graph::Error.single('db_plan_format', "#{PLANS}: números de plano repetidos.") unless numbers.uniq == numbers
        plans
      end
    end
  end
end

# frozen_string_literal: true

require 'securerandom'

module Vetra
  module Execution
    # Implementações de referência da borda (ADR-045, §2), para as sondas e para uso local. Valem para **um** processo
    # e para o tamanho de dados da referência; um produto com vários processos ou muito dado injeta as suas.

    # Marcador de autoridade em memória, para aplicações sem revisão SQL (blog e chat). Só vê as mudanças que passam por
    # ela: escritas de outro processo, ou direto no banco, não a movem, e esse limite não é escondido.
    class InProcessAuthority
      def initialize
        @generation = 0
        @mutex = Mutex.new
      end

      def call(_context = nil) = @mutex.synchronize { @generation }

      # Publica uma nova geração; invalida todo snapshot lido antes.
      def publish!(_context = nil) = @mutex.synchronize { @generation += 1 }

      def inspect = '#<Vetra::Execution::InProcessAuthority>'
      alias to_s inspect
    end

    # Marcador composto `[revisão de vetra.authz_revisions, geração da identidade]` dos CRMs (ADR-044, §1.1), lido numa só
    # instrução em autocommit, pelo pool próprio da borda. A revisão sobe por trigger na mesma transação que muda o dado;
    # a geração da identidade é da borda e sobe quando um papel muda fora do banco (SSO, por exemplo).
    class DatabaseAuthority
      attr_reader :identity_generation

      def initialize(db:, identity_generation: InProcessAuthority.new)
        unless db.is_a?(Data::RuntimeDatabase) || (db.respond_to?(:adapter_scheme) && db.adapter_scheme == :mock && db.database_type == :postgres)
          raise Error.single('data_connection', 'Crie o pool da borda por Vetra::Data.connect para conferir o login de cada conexão.')
        end
        unless identity_generation.respond_to?(:call) && identity_generation.respond_to?(:publish!)
          raise Error.single('execution_edge', 'A geração da identidade exige call e publish!.')
        end
        @db = Data.configure(db)
        @identity_generation = identity_generation
        freeze
      end

      def call(context)
        revision = @db[Sequel.qualify('vetra', 'authz_revisions')].where(tenant_id: context.tenant_id).get(:revision)
        raise Error.single('data_authorization_snapshot', 'Fatos de autorização ausentes, incompletos, incompatíveis ou obsoletos.') if revision.nil?
        [Integer(revision), @identity_generation.call(context)].freeze
      end

      # A borda chama isto quando uma atribuição de papel muda fora do banco.
      def identity_changed!(context = nil) = @identity_generation.publish!(context)

      def inspect = '#<Vetra::Execution::DatabaseAuthority>'
      alias to_s inspect
    end

    # Provedor de fatos de referência: lê os registros que as políticas percorrem pelo **pool próprio** da borda (uma
    # `UnitOfWork` distinta da da operação, com o mesmo escopo), então a contagem de transações dele não é a da operação.
    # Lê pelo papel `vetra_app` com o contexto do ator, de modo que o RLS dos CRMs filtra como filtra a operação.
    class DatabaseFacts
      DEFAULT_LIMIT = 10_000

      def initialize(catalog:, unit:, authority:, limit: DEFAULT_LIMIT)
        unless catalog.is_a?(Data::Repositories) && unit.is_a?(Data::UnitOfWork) && authority.respond_to?(:call) &&
               limit.is_a?(Integer) && limit.positive?
          raise Error.single('execution_edge', 'O provedor de fatos exige catálogo, unidade própria, autoridade e limite positivo.')
        end
        @catalog, @unit, @authority, @limit = catalog, unit, authority, limit
        freeze
      end

      def call(request)
        context = request.context
        marker = @authority.call(context) # antes dos fatos: uma mudança no meio deixa o snapshot velho, nunca novo
        plan = request.authorization.fact_plan(request.operation_id, request.roles)
        claims = { actor_id: context.actor_id, op_id: context.op_id, cmd: 'vetra.authorization_facts' }
        claims[:tenant_id] = context.tenant_id if context.scope == :tenant
        records = {}
        @unit.read(**claims) do |unit|
          plan[:entities].each { |entity_id| records[entity_id] = @catalog.fact_rows(entity_id, unit: unit, limit: @limit) }
          if plan[:principal] && !records.key?(plan[:principal])
            records[plan[:principal]] = @catalog.fact_rows(plan[:principal], unit: unit, limit: @limit, ids: [request.input.fetch(plan[:record])])
          end
        end
        request.authorization.snapshot(context: context, roles: request.roles, revision: marker, records: records)
      end

      def inspect = '#<Vetra::Execution::DatabaseFacts>'
      alias to_s inspect
    end
  end
end

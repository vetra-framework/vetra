require_relative "vetra/version"
require_relative "vetra/graph/diagnostic"
require_relative "vetra/graph/data"
require_relative "vetra/graph/currency"
require_relative "vetra/graph/canonical"
require_relative "vetra/graph/rate_limit"
require_relative "vetra/graph/manifest"
require_relative "vetra/graph/schema"
require_relative "vetra/graph/relation_commands"
require_relative "vetra/graph/live_dependencies"
require_relative "vetra/graph/validator"
require_relative "vetra/graph/registry"
require_relative "vetra/graph/dsl"
require_relative "vetra/graph/declaration_loader"
require_relative "vetra/graph/analysis"
require_relative "vetra/graph/capabilities"
require_relative "vetra/graph/normalizer"
require_relative "vetra/graph/linked_graph"
require_relative "vetra/graph/linker"
require_relative "vetra/graph/compiler"
require_relative "vetra/graph/diff_source"
require_relative "vetra/graph/diff"
require_relative "vetra/sql/context"
require_relative "vetra/sql/authorization"
require_relative "vetra/sql/schema"
require_relative "vetra/sql/statement_scanner"
require_relative "vetra/sql/security"
require_relative "vetra/sql/plan"
require_relative "vetra/sql/scratch_database"
require_relative "vetra/sql/planner"

module Vetra
  def self.app(name, &block)
    context = Thread.current[:vetra_graph_context]
    raise Graph::Error.single("dsl_context", "Carregue Vetra.app pelo compilador.") unless context

    context.app(name, &block)
  end
end

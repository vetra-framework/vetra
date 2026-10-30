require_relative "vetra/version"
require_relative "vetra/graph/diagnostic"
require_relative "vetra/graph/data"
require_relative "vetra/graph/canonical"
require_relative "vetra/graph/manifest"
require_relative "vetra/graph/schema"
require_relative "vetra/graph/validator"
require_relative "vetra/graph/registry"
require_relative "vetra/graph/dsl"
require_relative "vetra/graph/analysis"
require_relative "vetra/graph/normalizer"
require_relative "vetra/graph/compiler"
require_relative "vetra/graph/diff_source"
require_relative "vetra/graph/diff"

module Vetra
  def self.app(name, &block)
    context = Thread.current[:vetra_graph_context]
    raise Graph::Error.single("dsl_context", "Carregue Vetra.app pelo compilador.") unless context

    context.app(name, &block)
  end
end

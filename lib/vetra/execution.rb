# frozen_string_literal: true

# Executor parcial do ADR-016 e handlers de sistema (ADR-044 a ADR-048). Carregamento explícito; abre conexão só pela unidade e pelos
# colaboradores que o chamador injeta na borda.
require_relative 'data'

module Vetra
  module Execution
    Error = Data::Error
  end
end

require_relative 'execution/input'
require_relative 'execution/snapshot'
require_relative 'execution/predicate'
require_relative 'execution/authorization'
require_relative 'execution/edge'
require_relative 'execution/facts'
require_relative 'execution/guard'
require_relative 'execution/runner'
require_relative 'execution/handler_runner'

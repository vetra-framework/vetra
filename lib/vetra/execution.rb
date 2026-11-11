# frozen_string_literal: true

# Etapas 1 a 5 e 8 do ADR-016 (ADR-044 e ADR-045). Carregamento explícito; abre conexão só pela unidade e pelos
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

# frozen_string_literal: true

# Etapas 2 e 3 do ADR-016. Carregamento explícito; não abre conexão nem despacha calls.
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

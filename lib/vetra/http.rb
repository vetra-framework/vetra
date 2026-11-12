# frozen_string_literal: true

# Adaptador HTTP experimental (ADR-050), como aplicação Rack, sem dependência nova. Carregamento explícito.
require_relative 'execution'

module Vetra
  module Http
    Error = Data::Error
  end
end

require_relative 'http/app'

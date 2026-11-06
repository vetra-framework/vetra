# frozen_string_literal: true

# Carregamento explícito: o compilador não depende de Sequel nem do driver.
require 'sequel'
require_relative 'graph/diagnostic'

Sequel.extension :fiber_concurrency

module Vetra
  module Data
    class Error < Graph::Error; end
  end
end

require_relative 'data/context'
require_relative 'data/context_issuer'
require_relative 'data/database'
require_relative 'data/unit_of_work'

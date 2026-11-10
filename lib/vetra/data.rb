# frozen_string_literal: true

# Carregamento explícito: o compilador não depende de Sequel nem do driver.
require 'sequel'
require_relative 'graph/diagnostic'
require_relative '../vetra'

Sequel.extension :fiber_concurrency

module Vetra
  module Data
    class Error < Graph::Error
      def code = diagnostics.first.code
    end
  end
end

require_relative 'data/context'
require_relative 'data/context_issuer'
require_relative 'data/database'
require_relative 'data/values'
require_relative 'data/database_errors'
require_relative 'data/limits'
require_relative 'data/unit_of_work'
require_relative 'data/record'
require_relative 'data/row_reader'
require_relative 'data/query'
require_relative 'data/repository'
require_relative 'data/repositories'
require_relative 'data/relay'
require_relative 'data/idempotency'

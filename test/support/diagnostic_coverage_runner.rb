require 'minitest'
require 'vetra'
require_relative 'diagnostic_coverage'

coverage = VetraTest::DiagnosticCoverage.new(root: File.expand_path('../..', __dir__))
recorder = Module.new do
  define_method(:new) do |**attributes|
    coverage.record(attributes.fetch(:code))
    super(**attributes)
  end
end
Vetra::Graph::Diagnostic.singleton_class.prepend(recorder)

Minitest.after_run do
  exit 1 unless coverage.report
end

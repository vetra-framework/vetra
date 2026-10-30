require_relative "lib/vetra/version"

Gem::Specification.new do |spec|
  spec.name = "vetra"
  spec.version = Vetra::VERSION
  spec.authors = ["Denilson Silva"]
  spec.summary = "Compilador experimental do Grafo da Aplicação Vetra"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 4.0"
  spec.files = Dir["lib/**/*.rb", "bin/vetra", "docs/ir/v*.schema.json", "LICENSE", "README.md"]
  spec.bindir = "bin"
  spec.executables = ["vetra"]
  spec.require_paths = ["lib"]

  spec.add_dependency "json", ">= 2.18", "< 3"
  spec.add_dependency "json_schemer", "~> 2.5"
  spec.add_dependency "prism", "~> 1.0"
  spec.add_development_dependency "minitest", "~> 5.25"
  spec.add_development_dependency "rake", "~> 13.2"
end

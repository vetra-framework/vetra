require_relative "lib/vetra/version"

Gem::Specification.new do |spec|
  spec.name = "vetra"
  spec.version = Vetra::VERSION
  spec.authors = ["Denilson Silva"]
  spec.summary = "Compilador, camada de dados e executor parcial do Grafo da Aplicação Vetra (experimental)"
  spec.description = <<~TEXT.tr("\n", " ").strip
    Vetra, um framework web experimental para Ruby 4 e PostgreSQL que descreve a aplicação como um grafo
    verificável. Compila o DSL de entidades, comandos, consultas, permissões e eventos numa IR versionada, valida o
    artefato, compara versões, vincula os blocos Ruby, gera e aplica o plano de banco e traz a camada de dados e
    um executor parcial das operações. Ainda não serve HTTP nem tem histórico, auditoria e cifra.
  TEXT
  spec.homepage = "https://github.com/vetra-framework/vetra"
  spec.license = "MIT"
  spec.metadata = {
    "source_code_uri" => spec.homepage,
    "documentation_uri" => "#{spec.homepage}/blob/main/docs/fase-0.md",
    "bug_tracker_uri" => "#{spec.homepage}/issues",
    "rubygems_mfa_required" => "true"
  }
  spec.required_ruby_version = ">= 4.0"
  spec.files = Dir["lib/**/*.rb", "bin/vetra", "docs/ir/v*.schema.json", "LICENSE", "README.md"]
  spec.bindir = "bin"
  spec.executables = ["vetra"]
  spec.require_paths = ["lib"]

  spec.add_dependency "json", ">= 2.18", "< 3"
  spec.add_dependency "json_schemer", "~> 2.5"
  spec.add_dependency "prism", "~> 1.0"
  spec.add_dependency "sequel", "~> 5.110"
  spec.add_dependency "pg", "~> 1.7"
  spec.add_development_dependency "minitest", "~> 5.25"
  spec.add_development_dependency "rake", "~> 13.2"
end

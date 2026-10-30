require "json_schemer"

module Vetra
  module Graph
    class Schema
      VERSION = "0.1"
      FEATURES = %w[vetra.core].freeze
      CRUD_ACTIONS = %w[create read update delete].freeze
      PATH = File.expand_path("../../../docs/ir/v0.1.schema.json", __dir__)

      def initialize
        definition = JSON.parse(File.read(PATH, encoding: Encoding::UTF_8))
        properties = definition.fetch("properties")
        envelope = definition.merge("properties" => properties.merge("nodes" => properties.fetch("nodes").merge("items" => { "type" => "object" })))
        @envelope = schemer(envelope)
        @nodes = properties.fetch("nodes").fetch("items").fetch("oneOf").to_h do |branch|
          kind = branch.fetch("$ref").split("/").last
          [kind, schemer(definition.merge("$ref" => branch.fetch("$ref")).reject { |key, _| %w[type properties required additionalProperties].include?(key) })]
        end
      end

      def validate!(document)
        unless document.is_a?(Hash) && document["ir_version"] == VERSION
          raise Error.single("ir_version", "Versão de IR não suportada; este compilador aceita apenas #{VERSION}.", pointer: "/ir_version")
        end
        unknown = Array(document["requires"]) - FEATURES
        unless unknown.empty?
          raise Error.single("ir_feature", "Recursos não implementados: #{unknown.join(', ')}.", pointer: "/requires")
        end
        diagnostics = errors(@envelope, document)
        raise Error.new(diagnostics) unless diagnostics.empty?
        document.fetch("nodes").each_with_index do |node, index|
          validator = @nodes[node["kind"]]
          if validator
            diagnostics.concat(errors(validator, node, "/nodes/#{index}", node["source"]))
          else
            diagnostics << Diagnostic.new(code: "node_kind", message: "Tipo de nó desconhecido.", pointer: "/nodes/#{index}/kind", source: node["source"], severity: :error)
          end
        end
        raise Error.new(diagnostics) unless diagnostics.empty?
      end

      private

      def schemer(schema)
        JSONSchemer.schema(schema, ref_resolver: proc { |uri| raise Error.single("schema_reference", "Referência externa proibida: #{uri}.") }, regexp_resolver: proc { |pattern| Regexp.new(pattern.sub(/\A\^/, '\\A').sub(/\$\z/, '\\z')) })
      end

      def errors(validator, value, prefix = "", source = nil)
        validator.validate(value).map do |error|
          Diagnostic.new(code: "schema", message: error.fetch("error"), pointer: "#{prefix}#{error.fetch('data_pointer')}", source: source, severity: :error)
        end
      end
    end
  end
end

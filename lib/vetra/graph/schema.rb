require "json_schemer"

module Vetra
  module Graph
    class Schema
      VERSION = "0.6"
      VERSIONS = Data.freeze({
        '0.1' => %w[vetra.core],
        '0.2' => %w[vetra.core vetra.timestamps],
        '0.3' => %w[vetra.core vetra.timestamps vetra.structured_outputs vetra.live],
        '0.4' => %w[vetra.core vetra.timestamps vetra.structured_outputs vetra.live vetra.relation_commands],
        '0.5' => %w[vetra.core vetra.timestamps vetra.structured_outputs vetra.live vetra.relation_commands vetra.money_rounding],
        '0.6' => %w[vetra.core vetra.timestamps vetra.structured_outputs vetra.live vetra.relation_commands vetra.money_rounding vetra.rate_limit]
      })
      CRUD_ACTIONS = %w[create read update delete].freeze
      PATH = File.expand_path("../../../docs/ir/v0.6.schema.json", __dir__)

      def self.supports?(version, feature)
        VERSIONS.fetch(version, []).include?(feature)
      end

      def self.path(version)
        VERSIONS.fetch(version)
        version == VERSION ? PATH : File.expand_path("../../../docs/ir/v#{version}.schema.json", __dir__)
      end

      def initialize
        @schemas = {}
      end

      def validate!(document)
        unless document.is_a?(Hash) && VERSIONS.key?(document["ir_version"])
          raise Error.single("ir_version", "Versão de IR não suportada; este compilador aceita #{VERSIONS.keys.join(', ')}.", pointer: "/ir_version")
        end
        version = document.fetch('ir_version')
        supported = VERSIONS.fetch(version)
        unknown = Array(document["requires"]) - supported
        unless unknown.empty?
          raise Error.single("ir_feature", "Recursos não implementados: #{unknown.join(', ')}.", pointer: "/requires")
        end
        envelope, nodes = validators(version)
        diagnostics = errors(envelope, document)
        raise Error.new(diagnostics) unless diagnostics.empty?
        document.fetch("nodes").each_with_index do |node, index|
          validator = nodes[node["kind"]]
          if validator
            diagnostics.concat(errors(validator, node, "/nodes/#{index}", node["source"]))
          else
            diagnostics << Diagnostic.new(code: "node_kind", message: "Tipo de nó desconhecido.", pointer: "/nodes/#{index}/kind", source: node["source"], severity: :error)
          end
        end
        raise Error.new(diagnostics) unless diagnostics.empty?
      end

      private

      def validators(version)
        @schemas[version] ||= begin
          path = self.class.path(version)
          definition = JSON.parse(File.read(path, encoding: Encoding::UTF_8))
          properties = definition.fetch('properties')
          envelope = definition.merge('properties' => properties.merge('nodes' => properties.fetch('nodes').merge('items' => { 'type' => 'object' })))
          nodes = properties.fetch('nodes').fetch('items').fetch('oneOf').to_h do |branch|
            kind = branch.fetch('$ref').split('/').last
            [kind, schemer(definition.merge('$ref' => branch.fetch('$ref')).reject { |key, _| %w[type properties required additionalProperties].include?(key) })]
          end
          [schemer(envelope), nodes]
        end
      end

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

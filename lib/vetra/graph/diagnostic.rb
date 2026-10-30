module Vetra
  module Graph
    Diagnostic = Struct.new(:code, :message, :pointer, :source, :severity, keyword_init: true) do
      def to_s
        origin = source ? "#{source.fetch('path')}:#{source.fetch('line')} " : ""
        "#{origin}[#{code}] #{pointer || '/'}: #{message}"
      end
    end

    class Error < StandardError
      attr_reader :diagnostics

      def initialize(diagnostics)
        @diagnostics = diagnostics
        super(diagnostics.map(&:to_s).join("\n"))
      end

      def self.single(code, message, source: nil, pointer: "/")
        new([Diagnostic.new(code: code, message: message, source: source, pointer: pointer, severity: :error)])
      end
    end
  end
end

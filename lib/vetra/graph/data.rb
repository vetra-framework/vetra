module Vetra
  module Graph
    module Data
      module_function

      def freeze(value)
        case value
        when Hash
          value.each { |key, child| freeze(key); freeze(child) }
        when Array
          value.each { |child| freeze(child) }
        when Struct
          value.each { |child| freeze(child) }
        end
        value.freeze
      end

      def copy(value)
        case value
        when Hash then value.to_h { |key, child| [key.dup, copy(child)] }
        when Array then value.map { |child| copy(child) }
        when String then value.dup
        else value
        end
      end

      def reference(kind, id)
        { "kind" => kind, "id" => id }
      end

      def references(value, pointer = "", &block)
        case value
        when Hash
          if value.keys.sort == %w[id kind]
            yield value, pointer
          elsif value["kind"] != "literal"
            value.each do |key, child|
              next if key == "annotations"
              references(child, "#{pointer}/#{key.gsub('~', '~0').gsub('/', '~1')}", &block)
            end
          end
        when Array
          value.each_with_index { |child, i| references(child, "#{pointer}/#{i}", &block) }
        end
      end
    end
  end
end

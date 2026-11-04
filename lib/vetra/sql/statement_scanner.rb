# frozen_string_literal: true

module Vetra
  module SQL
    # Acompanha, linha a linha, se o texto SQL está entre instruções: fora de literais ('...', E'...', "...",
    # $tag$...$tag$), de comentários de bloco e de uma instrução sem o `;` final. Só nessa fronteira um marcador
    # `-- vetra:` do plano ou uma linha de sessão do pg_dump significa o que parece; dentro de um literal ou de um
    # corpo de função, a mesma linha é dado.
    class StatementScanner
      DOLLAR = /\$([A-Za-z_][A-Za-z0-9_]*)?\$/

      def initialize
        @mode = nil
        @dollar = nil
        @escape = false
        @depth = 0
        @open = false
      end

      def boundary?
        @mode.nil? && !@open
      end

      def feed(line)
        text = "#{line}\n"
        index = 0
        while index < text.size
          char = text[index]
          case @mode
          when :single
            if @escape && char == '\\'
              index += 1
            elsif char == "'"
              text[index + 1] == "'" ? index += 1 : @mode = nil
            end
          when :double
            if char == '"'
              text[index + 1] == '"' ? index += 1 : @mode = nil
            end
          when :dollar
            if text[index, @dollar.size] == @dollar
              index += @dollar.size - 1
              @mode = nil
            end
          when :block
            if text[index, 2] == '/*'
              @depth += 1
              index += 1
            elsif text[index, 2] == '*/'
              @depth -= 1
              index += 1
              @mode = nil if @depth.zero?
            end
          else
            index = top_level(text, index, char)
          end
          index += 1
        end
        self
      end

      private

      # Retorna o índice do último caractere consumido no nível de topo.
      def top_level(text, index, char)
        previous = index.positive? ? text[index - 1] : ''
        if text[index, 2] == '--'
          return text.size - 1
        elsif text[index, 2] == '/*'
          @mode, @depth = :block, 1
          return index + 1
        elsif char == "'"
          @mode = :single
          @escape = previous.match?(/[Ee]/) && !(index > 1 && text[index - 2].match?(/[A-Za-z0-9_]/))
        elsif char == '"'
          @mode = :double
        elsif char == '$' && !previous.match?(/[A-Za-z0-9_]/) && (tag = DOLLAR.match(text, index)) && tag.begin(0) == index
          @mode, @dollar = :dollar, tag[0]
          @open = true
          return index + tag[0].size - 1
        elsif char == ';'
          @open = false
          return index
        end
        @open = true unless char.match?(/\s/)
        index
      end
    end
  end
end

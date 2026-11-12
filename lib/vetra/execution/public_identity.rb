# frozen_string_literal: true

require 'openssl'
require 'securerandom'
require 'set'

module Vetra
  module Execution
    # Contrato da identidade na borda pública (ADR-049). Uma superfície pública (HTTP, CLI, job, webhook) entrega a credencial a um
    # **resolvedor** que a aplicação implementa (sessão, token, assinatura do provedor, identificador do processo) e que devolve uma
    # `Identity`. Este guarda se põe entre o resolvedor e a borda e confere o que o resolvedor devolveu, porque um resolvedor com defeito
    # (ou um que repassa campos do pedido) nunca pode conceder poder: falha fechada, com código próprio e sem causa.
    #
    # **Confere forma e declaração, não autenticidade**: um resolvedor que copia do pedido um UUID, um tenant e um papel declarados passa por aqui. A
    # autenticidade da identidade é do resolvedor confiável (ADR-044); o guarda só impede que um defeito dele (ator de sistema, valor malformado, papel que
    # o grafo não declara) chegue à borda.
    #
    # O que confere (ADR-049, §2):
    # * a identidade é uma `Identity`, e **nunca um ator de sistema** (o ator de sistema é só dos handlers, pelo `HandlerRunner`);
    # * o ator é um UUID em minúsculas, inclusive o do visitante (a identidade anônima tem ator, `AnonymousIssuer`);
    # * cada papel é um papel declarado no grafo, como texto;
    # * o tenant é um UUID numa aplicação com tenant e fica ausente numa global;
    # * a geração, se houver, é um inteiro não negativo (a conferência de que ela é a corrente é do `Runner`, `Edge#identity_current?`).
    class PublicIdentity
      UUID = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/

      def initialize(resolver:, linked:)
        unless resolver.respond_to?(:call) && linked.is_a?(Graph::LinkedGraph)
          raise Error.single('execution_edge', 'A identidade pública exige um resolvedor chamável e o grafo vinculado.')
        end
        document = linked.document
        @resolver = resolver
        @roles = document.fetch('nodes').select { |node| node['kind'] == 'role' }.to_set { |node| node['id'] }.freeze
        @tenant_app = !document.dig('app', 'tenant').nil?
        freeze
      end

      # Devolve uma identidade **canônica**: um `Identity` novo, com cópias congeladas dos valores já conferidos. A que o resolvedor devolveu (que
      # pode ser uma subclasse, de leitores que mudam, ou ter textos mutáveis) não passa adiante, então o que se conferiu é o que se usa.
      def call(credentials)
        received = begin
          @resolver.call(credentials)
        rescue StandardError
          # O erro do resolvedor, de qualquer tipo, vira o genérico: nem mensagem, nem código, nem causa chegam à borda.
          raise Error.single('execution_identity', 'A borda não resolveu uma identidade para esta operação.'), cause: nil
        end
        validate!(received)
      end

      def inspect = '#<Vetra::Execution::PublicIdentity>'
      alias to_s inspect

      private

      # Cada leitor é chamado uma vez, e só os valores **nativos** lidos (cópias de String e de Array feitas pelo próprio Vetra, sem chamar `dup`, `to_s` nem
      # `each` do objeto do resolvedor) são conferidos e usados. Um leitor que levanta, de qualquer tipo, vira o erro genérico: nenhum código nem mensagem
      # do resolvedor chega à borda.
      def validate!(identity)
        generic = Error.single('execution_identity', 'A borda não resolveu uma identidade para esta operação.')
        raise generic unless Identity === identity # `===` do módulo: a identidade não decide se é uma `Identity`
        # Só aqui, e uma vez cada, os leitores do objeto do resolvedor são chamados; depois disto, só métodos de módulos (`===`) e de objetos nativos.
        system_actor, actor, roles, tenant, generation = begin
          [identity.system_actor, native(identity.actor_id), native_list(identity.roles), native_or_invalid(identity.tenant_id), identity.generation]
        rescue StandardError
          raise generic, cause: nil
        end
        raise Error.single('execution_identity_system', 'Uma superfície pública não admite ator de sistema.') unless NilClass === system_actor
        raise Error.single('execution_identity_actor', 'A identidade pública exige um ator UUID, inclusive o visitante.') unless actor && uuid?(actor)
        unless roles && roles.all? { |role| role && @roles.include?(role) }
          raise Error.single('execution_identity_role', 'A identidade pública só pode ter papéis declarados no grafo.')
        end
        tenant_ok = @tenant_app ? (String === tenant && uuid?(tenant)) : NilClass === tenant
        raise Error.single('execution_identity_tenant', 'O tenant da identidade não condiz com a aplicação.') unless tenant_ok
        unless NilClass === generation || (Integer === generation && generation >= 0)
          raise Error.single('execution_identity_generation', 'A geração da identidade deve ser um inteiro não negativo.')
        end
        Identity.new(tenant_id: tenant, actor_id: actor, roles: roles, system_actor: nil, generation: generation)
      end

      INVALID = Object.new.freeze
      private_constant :INVALID

      # Ausente (nil) continua nil; um texto vira cópia nativa; qualquer outra coisa vira um marcador que nenhuma conferência aceita.
      def native_or_invalid(value) = NilClass === value ? nil : (native(value) || INVALID)

      # UUID em minúsculas, em texto ASCII válido: um texto em outra codificação (UTF-16) ou inválido é recusado em vez de levantar na comparação.
      def uuid?(text) = text.valid_encoding? && text.ascii_only? && UUID.match?(text)

      # Cópia nativa e congelada de um texto, ou nil se não é um texto. `String.new(texto)` copia o conteúdo sem chamar nenhum método do objeto.
      def native(value) = String === value ? String.new(value).freeze : nil

      # Cópia nativa e congelada de uma lista de textos (nil se não é uma lista, ou se algum elemento não é texto).
      def native_list(value)
        return nil unless Array === value
        copy = Array.new(value).map { |element| native(element) }
        copy.all? ? copy.freeze : nil
      end
    end

    # Identidade anônima estável, emitida e verificada (ADR-049, §4). O visitante de uma superfície pública recebe uma credencial
    # (`a1.<nonce>.<mac>`) que a borda guarda (cookie, por exemplo) e reapresenta; o ator dele é um UUID derivado do nonce por HMAC com o
    # segredo da aplicação, estável a cada reapresentação e impossível de escolher pelo cliente. O limite de taxa por visitante
    # (ADR-034) e o isolamento entre visitantes da idempotência (ADR-043) dependem desse ator. Quem não apresenta uma credencial válida
    # não é um visitante: a borda emite outra, e o histórico do limite começa de novo, o que o ADR-049 registra como limite.
    class AnonymousIssuer
      PREFIX = 'a1'
      ID_LABEL = 'vetra-anon-id-v1.'
      MAC_LABEL = 'vetra-anon-mac-v1.'
      MIN_SECRET = 32

      def initialize(secret:)
        unless secret.is_a?(String) && secret.bytesize >= MIN_SECRET
          raise Error.single('execution_anonymous_secret', "O segredo da identidade anônima exige texto de pelo menos #{MIN_SECRET} bytes.")
        end
        @secret = secret.dup.freeze
        freeze
      end

      # Uma credencial nova para um visitante novo.
      def issue
        nonce = SecureRandom.random_bytes(16)
        "#{PREFIX}.#{encode(nonce)}.#{encode(mac(nonce))}"
      end

      # O ator anônimo da credencial, ou nil se ela não é autêntica (formato, tamanho ou MAC).
      def verify(token)
        # `ascii_only?` recusa antes de separar qualquer texto em outra codificação (UTF-16, UTF-32), que levantaria na comparação.
        return nil unless token.is_a?(String) && token.bytesize <= 128 && token.ascii_only?
        parts = token.split('.', -1)
        return nil unless parts.size == 3 && parts[0] == PREFIX && parts[1].match?(/\A[A-Za-z0-9_-]{22}\z/) && parts[2].match?(/\A[A-Za-z0-9_-]{43}\z/)
        nonce = decode(parts[1])
        supplied = decode(parts[2])
        return nil unless nonce.bytesize == 16 && supplied.bytesize == 32 && OpenSSL.fixed_length_secure_compare(supplied, mac(nonce))
        actor_for(nonce)
      rescue ArgumentError, EncodingError
        nil
      end

      # A `Identity` do visitante: ator anônimo, os papéis anônimos que o chamador declara e o tenant, se a aplicação tem. nil se a credencial não vale.
      def identity(token, roles:, tenant_id: nil, generation: nil)
        actor = verify(token)
        actor && Identity.new(tenant_id: tenant_id, actor_id: actor, roles: roles, generation: generation)
      end

      def inspect = '#<Vetra::Execution::AnonymousIssuer>'
      alias to_s inspect

      private

      def mac(nonce) = OpenSSL::HMAC.digest('SHA256', @secret, MAC_LABEL + nonce)

      def actor_for(nonce)
        bytes = OpenSSL::HMAC.digest('SHA256', @secret, ID_LABEL + nonce).byteslice(0, 16).bytes
        bytes[6] = (bytes[6] & 0x0f) | 0x80 # versão 8: UUID de formato livre
        bytes[8] = (bytes[8] & 0x3f) | 0x80 # variante RFC 9562
        hex = bytes.pack('C*').unpack1('H*')
        "#{hex[0, 8]}-#{hex[8, 4]}-#{hex[12, 4]}-#{hex[16, 4]}-#{hex[20, 12]}"
      end

      def encode(bytes) = [bytes].pack('m0').tr('+/', '-_').delete('=')

      def decode(text) = (text.tr('-_', '+/') + ('=' * ((4 - (text.size % 4)) % 4))).unpack1('m0')
    end

    # Um adaptador que declara vários processos recusa subir sem uma autoridade que enxergue as mudanças de todos (ADR-049, §5).
    def self.require_shared_authority!(edge)
      return if edge.respond_to?(:shared_authority?) && edge.shared_authority?
      raise Error.single('execution_authority_not_shared',
                         'Vários processos exigem uma autoridade de revisão compartilhada; a de referência vale para um processo.')
    end
  end
end

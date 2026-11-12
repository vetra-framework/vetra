# frozen_string_literal: true

require 'json'
require 'uri'

module Vetra
  module Http
    # O que a aplicação entrega ao resolvedor de identidade (ADR-049): só os cabeçalhos de credencial, sem interpretá-los. O adaptador
    # nunca lê papel, ator nem tenant do pedido.
    # `origin` e `fetch_site` (`Origin` e `Sec-Fetch-Site`) vão junto para que um resolvedor que autentica por cookie de sessão possa recusar um pedido de outro site (CSRF).
    Credentials = ::Data.define(:authorization, :cookie, :origin, :fetch_site, :headers) do
      def initialize(authorization: nil, cookie: nil, origin: nil, fetch_site: nil, headers: {})
        super(authorization: authorization, cookie: cookie, origin: origin, fetch_site: fetch_site, headers: headers.dup.freeze)
      end

      def inspect = '#<Vetra::Http::Credentials [REDACTED]>'
      alias to_s inspect
      def pretty_print(printer) = printer.text(inspect)
    end

    # Adaptador HTTP do ADR-007 e do ADR-050: traduz um pedido Rack para o `Runner` e a saída dele para uma resposta. Faz só o que o
    # ADR-007, §2 manda: traduzir a entrada, entregar a credencial ao resolvedor, extrair a chave de idempotência e traduzir as saídas de
    # falha. Não abre transação, não lê nem grava dados, não decide regra de negócio e não repete etapa.
    #
    # `call(env)` segue o contrato Rack 3 (status, cabeçalhos em minúsculas, corpo em lista) e nunca levanta. Nada do que o cliente envia
    # (cabeçalho, caminho, consulta, corpo) atribui identidade, papel ou tenant: a credencial vai ao resolvedor da borda.
    class App
      LIMITS = { max_body: 1_048_576, max_query: 8_192, max_query_pairs: 50, max_path: 2_048, max_depth: 8, max_fields: 200 }.freeze
      KEY_PATTERN = /\A[\x21-\x7e]{1,255}\z/
      HEADER_NAME = /\A[A-Za-z0-9-]{1,64}\z/
      MAX_ERRORS = 20
      # Três classes de recusa na etapa 3. Só uma **decisão** de autorização (a lista abaixo; `data_authorization_rate_limit` é a operação limitada que ainda não tem
      # contadores) é 403 ou 404. Indisponibilidade (`UNAVAILABLE_CODES`; `data_access_denied` é o SQLSTATE 42501 de falta de permissão **no banco**: nenhuma
      # política chegou a ser avaliada) é 503. Todo o resto (predicado incompatível, contexto incoerente, operação desconhecida, invariante quebrada) é um defeito: 500.
      DENIAL_CODES = %w[data_authorization_denied data_authorization_fields data_authorization_final data_authorization_rate_limit
                        data_authorization_system_actor data_authorization_context].freeze
      # Falha de infraestrutura (banco, conexão, fatos ilegíveis, timeouts, contenção): retentável, e o acesso segue recusado.
      UNAVAILABLE_CODES = %w[data_authorization_snapshot data_connection data_database data_access_denied data_limits data_context_install data_statement_timeout
                             data_lock_timeout data_serialization data_conflict data_timeout].freeze
      Route = Struct.new(:id, :verb, :segments, :operation, :kind, :idempotency, :record_targeted, :fields, keyword_init: true)

      # Recusa interna do adaptador: nunca vaza detalhe do pedido.
      class Refusal < StandardError
        attr_reader :status, :code, :headers

        def initialize(status, code, headers = {})
          @status, @code, @headers = status, code, headers
          super(code)
        end
      end
      private_constant :Refusal

      # `runners`: um `Runner` por rota (perfil de timeouts e isolamento por rota, sem mutar o padrão), indexado pelo id da rota.
      def initialize(linked:, runner:, runners: {}, credential_headers: [], **limits)
        unless linked.is_a?(Graph::LinkedGraph) && runner.respond_to?(:run) && runner.respond_to?(:serialize) && runners.is_a?(Hash) &&
               runners.values.all? { |item| item.respond_to?(:run) && item.respond_to?(:serialize) } &&
               credential_headers.is_a?(Array) && credential_headers.all? { |name| name.is_a?(String) && HEADER_NAME.match?(name) }
          raise Error.single('http_app', 'O adaptador HTTP exige o grafo vinculado, o Runner, perfis de Runner por rota e cabeçalhos de credencial válidos.')
        end
        unless (limits.keys - LIMITS.keys).empty? && limits.values.all? { |value| value.is_a?(Integer) && value.positive? }
          raise Error.single('http_app', 'Os limites do adaptador HTTP são inteiros positivos conhecidos.')
        end
        @limits = LIMITS.merge(limits).freeze
        @runner = runner
        @runners = runners.dup.freeze
        @credential_headers = credential_headers.to_h { |name| [name.downcase, "HTTP_#{name.upcase.tr('-', '_')}"] }.freeze
        @routes = build_routes(linked.document).freeze
        @field_names = linked.document.fetch('nodes').select { |node| node['kind'] == 'contract' }.flat_map { |node| node.fetch('fields').map { |field| field['name'] } }.to_set.freeze
        freeze
      end

      def call(env)
        status, headers, body = begin
          respond(*handle(env))
        rescue Refusal => refusal
          failure(refusal.status, refusal.code, refusal.headers)
        rescue StandardError
          failure(500, 'internal_error')
        end
        # HEAD (só onde o grafo o declara) leva os cabeçalhos da resposta do GET, com o `content-length` dela, e nenhum corpo: em **toda** resposta, inclusive as recusas.
        [status, headers, env['REQUEST_METHOD'].to_s == 'HEAD' ? [] : body]
      end

      def inspect = '#<Vetra::Http::App>'
      alias to_s inspect

      private

      # ---- rotas ---------------------------------------------------------------------------------------------------------------

      def build_routes(document)
        nodes = document.fetch('nodes')
        operations = nodes.select { |node| %w[command query].include?(node['kind']) }.to_h { |node| [node['id'], node] }
        contracts = nodes.select { |node| node['kind'] == 'contract' }.to_h { |node| [node['id'], node] }
        nodes.select { |node| node['kind'] == 'route' && node['surface'] == 'http' }.map do |node|
          operation = operations.fetch(node.dig('target', 'id'))
          fields = contracts.fetch(operation.dig('input', 'id')).fetch('fields').to_h { |field| [field['name'], field.dig('type', 'name')] }
          Route.new(id: node['id'], verb: node.dig('config', 'method'), segments: node.dig('config', 'path').split('/').drop(1).map { |part| part.start_with?(':') ? [part[1..]] : part },
                    operation: operation['id'], kind: operation['kind'], idempotency: node['idempotency'], record_targeted: !operation.dig('authorize', 'record').nil?,
                    fields: fields.freeze).freeze
        end
      end

      def match(verb, path)
        parts = path == '/' ? [] : path.split('/', -1).drop(1)
        allowed = []
        @routes.each do |route|
          params = extract(route, parts)
          next unless params
          return [route, params] if route.verb == verb
          allowed << route.verb
        end
        raise Refusal.new(405, 'method_not_allowed', { 'allow' => allowed.uniq.sort.join(', ') }) unless allowed.empty?
        raise Refusal.new(404, 'not_found')
      end

      def extract(route, parts)
        return nil unless parts.size == route.segments.size
        params = {}
        route.segments.zip(parts).each do |segment, part|
          if segment.is_a?(Array)
            value = decode_segment(part)
            params[segment.first] = value
          elsif segment != part
            return nil
          end
        end
        params
      end

      def decode_segment(part)
        raise Refusal.new(400, 'bad_request') if part.empty?
        value = URI.decode_uri_component(part)
        raise Refusal.new(400, 'bad_request') unless value.valid_encoding? && !value.include?("\0") && !value.include?('/')
        value
      rescue ArgumentError
        raise Refusal.new(400, 'bad_request')
      end

      # ---- o pedido ------------------------------------------------------------------------------------------------------------

      def handle(env)
        verb = env['REQUEST_METHOD'].to_s
        path = env['PATH_INFO'].to_s
        path = '/' if path.empty?
        raise Refusal.new(414, 'uri_too_long') if path.bytesize > @limits[:max_path]
        raise Refusal.new(400, 'bad_request') unless path.start_with?('/') && path.valid_encoding? && !path.include?("\0")
        route, params = match(verb, path)
        input = build_input(env, route, params)
        key = idempotency_key(env, route)
        outcome = (@runners[route.id] || @runner).run(route.operation, input, credentials: credentials(env), idempotency_key: key)
        translate(route, outcome)
      end

      def build_input(env, route, params)
        query = env['QUERY_STRING'].to_s
        body = read_body(env)
        if route.kind == 'query'
          raise Refusal.new(400, 'bad_request') unless body.empty?
          data = parse_query(query)
        else
          raise Refusal.new(400, 'bad_request') unless query.empty?
          data = parse_json(env, body)
        end
        conflict = data.keys & params.keys
        raise Refusal.new(400, 'input_conflict') unless conflict.empty?
        typed = ->(hash) { hash.to_h { |name, value| [name, convert(route, name, value)] } }
        route.kind == 'query' ? typed.call(data).merge(typed.call(params)) : data.merge(typed.call(params))
      end

      # Caminho e consulta chegam como texto; o contrato manda nos tipos. Um valor que não vira o tipo do campo segue como texto, e o
      # contrato o recusa com 422. O corpo JSON já traz tipos, e uma decimal ou um dinheiro como número (Float) é recusado pelo contrato.
      def convert(route, name, value)
        return value unless value.is_a?(String)
        case route.fields[name]
        when 'integer' then value.match?(/\A-?\d{1,19}\z/) ? Integer(value, 10) : value
        when 'boolean' then { 'true' => true, 'false' => false }.fetch(value, value)
        else value
        end
      end

      def parse_query(query)
        raise Refusal.new(414, 'uri_too_long') if query.bytesize > @limits[:max_query]
        return {} if query.empty?
        # Decodifica em bytes e só depois confere o UTF-8: um `%FF` solto é recusado, e não trocado por um caractere de substituição.
        pairs = URI.decode_www_form(query, Encoding::BINARY).map { |name, value| [name.force_encoding(Encoding::UTF_8), value.force_encoding(Encoding::UTF_8)] }
        raise Refusal.new(400, 'bad_request') if pairs.size > @limits[:max_query_pairs]
        names = pairs.map(&:first)
        raise Refusal.new(400, 'bad_request') if names.uniq.size != names.size || pairs.any? { |name, value| !(name.valid_encoding? && value.valid_encoding?) || name.include?("\0") || value.include?("\0") }
        pairs.to_h
      rescue ArgumentError
        raise Refusal.new(400, 'bad_request')
      end

      # Leitura limitada, sem confiar no Content-Length: lê no máximo o limite mais um byte.
      def read_body(env)
        declared = env['CONTENT_LENGTH']
        if declared && !declared.to_s.empty?
          raise Refusal.new(400, 'bad_request') unless declared.to_s.match?(/\A\d{1,12}\z/)
          raise Refusal.new(413, 'payload_too_large') if declared.to_i > @limits[:max_body]
        end
        input = env['rack.input']
        data = input ? input.read(@limits[:max_body] + 1).to_s : ''
        raise Refusal.new(413, 'payload_too_large') if data.bytesize > @limits[:max_body]
        data
      end

      # Todo comando exige `Content-Type: application/json`, **mesmo sem corpo**: um formulário de outro site não o envia sem preflight, e um POST vazio
      # com cookie não passa (CSRF, ADR-050, §3).
      def parse_json(env, body)
        media = env['CONTENT_TYPE'].to_s.split(';').first.to_s.strip.downcase
        raise Refusal.new(415, 'unsupported_media_type') unless media == 'application/json'
        return {} if body.empty?
        text = body.dup.force_encoding(Encoding::UTF_8)
        raise Refusal.new(400, 'bad_request') unless text.valid_encoding?
        data = JSON.parse(text, allow_duplicate_key: false, create_additions: false, allow_nan: false, max_nesting: @limits[:max_depth])
        raise Refusal.new(400, 'bad_request') unless data.is_a?(Hash) && count_fields(data) <= @limits[:max_fields]
        data
      rescue JSON::ParserError, EncodingError, ArgumentError
        raise Refusal.new(400, 'bad_request')
      end

      # Campos de todos os níveis (chaves de objeto): o limite vale para o corpo inteiro, e não só para a raiz.
      def count_fields(value)
        case value
        when Hash then value.size + value.each_value.sum { |item| count_fields(item) }
        when Array then value.sum { |item| count_fields(item) }
        else 0
        end
      end

      def idempotency_key(env, route)
        raw = env['HTTP_IDEMPOTENCY_KEY']
        if raw.nil? || raw.to_s.empty?
          raise Refusal.new(400, 'idempotency_key_required') if route.idempotency == 'required'
          return nil
        end
        raise Refusal.new(400, 'bad_request') unless KEY_PATTERN.match?(raw.to_s)
        raw.to_s
      end

      def credentials(env)
        Credentials.new(authorization: env['HTTP_AUTHORIZATION'], cookie: env['HTTP_COOKIE'], origin: env['HTTP_ORIGIN'], fetch_site: env['HTTP_SEC_FETCH_SITE'],
                        headers: @credential_headers.each_with_object({}) { |(name, key), result| result[name] = env[key] if env[key] })
      end

      # ---- a resposta ----------------------------------------------------------------------------------------------------------

      # As saídas do Runner no vocabulário HTTP (ADR-007, §3). Um registro que o ator não vê e um que não existe têm a mesma resposta (404),
      # nas operações que apontam um registro; a lista de erros é pública e fixa, sem valor, SQL, causa nem credencial.
      def translate(route, outcome)
        case outcome.status
        when :ok then success(route, outcome)
        when :unresolved then [401, { 'error' => { 'code' => 'unauthenticated' } }, {}]
        when :invalid then [422, { 'error' => { 'code' => 'invalid_input', 'fields' => pointers(outcome) } }, {}]
        when :denied then denied(route, outcome)
        when :not_found then [404, { 'error' => { 'code' => 'not_found' } }, {}]
        when :failed then failed(outcome)
        when :conflict then [409, { 'error' => { 'code' => 'conflict' } }, retry_header(outcome)]
        when :rate_limited then [429, { 'error' => { 'code' => 'rate_limited' } }, { 'retry-after' => '1' }]
        else [500, { 'error' => { 'code' => 'internal_error' } }, retry_header(outcome)]
        end
      end

      # O acesso fica recusado nos dois casos, mas a **indisponibilidade** (os fatos de autorização não foram lidos) não é uma negação: é 503, retentável, e
      # não o 404 que diria ao cliente que o registro não existe.
      def denied(route, outcome)
        code = outcome.code
        return [503, { 'error' => { 'code' => 'unavailable' } }, { 'retry-after' => '1' }] if UNAVAILABLE_CODES.include?(code)
        return [500, { 'error' => { 'code' => 'internal_error' } }, {}] unless code.nil? || DENIAL_CODES.include?(code)
        route.record_targeted ? [404, { 'error' => { 'code' => 'not_found' } }, {}] : [403, { 'error' => { 'code' => 'forbidden' } }, {}]
      end

      def success(route, outcome)
        runner = @runners[route.id] || @runner
        value = outcome.replayed? ? outcome.value : runner.serialize(route.operation, outcome.value)
        headers = outcome.replayed? ? { 'idempotent-replayed' => 'true' } : {}
        value.nil? ? [204, nil, headers] : [200, value, headers]
      end

      def failed(outcome)
        code = outcome.code.to_s
        if code == 'execution_failure'
          [422, { 'error' => { 'code' => 'business_rule', 'fields' => pointers(outcome) } }, {}]
        elsif code.include?('idempotency')
          [422, { 'error' => { 'code' => 'idempotency_key_reused' } }, {}]
        else
          [422, { 'error' => { 'code' => 'rejected' } }, {}]
        end
      end

      def retry_header(outcome) = outcome.retryable? ? { 'retry-after' => '1' } : {}

      # Só ponteiros cujos segmentos são campos **declarados** no grafo (ou `input` e índices de coleção): um nome que o cliente escolheu no corpo
      # nunca volta na resposta.
      def pointers(outcome)
        outcome.diagnostics.map(&:pointer).select { |pointer| declared_pointer?(pointer) }.uniq.first(MAX_ERRORS)
      end

      def declared_pointer?(pointer)
        return false unless pointer.is_a?(String) && pointer.match?(%r{\A/[A-Za-z0-9_/]{0,200}\z})
        pointer.split('/').drop(1).all? { |segment| segment == 'input' || segment.match?(/\A\d{1,6}\z/) || @field_names.include?(segment) }
      end

      def failure(status, code, headers = {}) = respond(status, { 'error' => { 'code' => code } }, headers)

      def respond(status, body, headers = {})
        common = { 'cache-control' => 'no-store', 'x-content-type-options' => 'nosniff' }
        return [status, common.merge(headers), []] if body.nil?
        json = JSON.generate(body)
        [status, common.merge('content-type' => 'application/json; charset=utf-8', 'content-length' => json.bytesize.to_s).merge(headers), [json]]
      end
    end
  end
end

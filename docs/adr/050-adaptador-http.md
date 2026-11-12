# ADR-050: Adaptador HTTP

- Status: proposto
- Data: 2026-11-12
- Depende de: ADR-007 (adaptadores), ADR-016 (ciclo de vida), ADR-045 (borda interna e Runner), ADR-047 (fechamento do Runner), ADR-049 (identidade da borda pública)
- Relacionados: ADR-010 (modo hospedado), ADR-034 (limite de taxa), ADR-043 (idempotência), ADR-044 (entrada e autorização em Ruby)

## Contexto

O ADR-007 define o que um adaptador faz e não faz e como as três saídas de falha viram o vocabulário de cada superfície, mas nenhum adaptador existia: o `Runner` só era chamado por sondas. A K24 entrega o primeiro,
o HTTP, como aplicação **Rack** sem dependência nova, para provar o fluxo completo com um pedido de verdade e mostrar onde o executor e o grafo ainda falham. É **experimental**: roda sobre o executor parcial, sem
histórico, auditoria nem cifra (plano da rodada 6), e não anuncia conformidade integral com o ADR-016.

## Decisão

### 1. Uma aplicação Rack, sem dependência

`Vetra::Http::App.new(linked:, runner:, runners: {}, credential_headers: [], **limites)` é um objeto chamável: `call(env)` devolve `[status, cabeçalhos, corpo]` (Rack 3, cabeçalhos em minúsculas) e **nunca levanta**.
Não depende da gem `rack` nem de um servidor; quem o monta (Puma, Falcon, `config.ru`, o Rails do modo hospedado) é do hospedeiro. As rotas vêm dos nós `route` de superfície `http` da IR: método, caminho com
parâmetros `:nome`, operação de destino e a exigência de idempotência. Rota que o grafo não declara é 404; caminho conhecido com outro método é 405 com `Allow`. `HEAD` só responde onde o grafo o declara (uma consulta exposta por `HEAD`): leva os cabeçalhos e o `content-length` do GET equivalente e nenhum corpo; `OPTIONS` não é suportado (405).

### 2. A entrada

- **Caminho**: dividido em segmentos, decodificado uma vez; segmento vazio, com `/`, NUL ou UTF-8 inválido é 400; o caminho tem até 2 KiB (414).
- **Consulta** (só em consultas): até 8 KiB e 50 pares, sem chave repetida, decodificada em bytes e conferida em UTF-8 (um `%FF` solto é 400). Um comando com consulta é 400.
- **Corpo** (só em comandos): lido **com limite, qualquer que seja o `Content-Length`** (lê no máximo o limite mais um byte: 1 MiB por padrão, 413), com `Content-Length` malformado em 400. **Todo comando exige
  `Content-Type: application/json`, mesmo sem corpo** (415); o JSON é estrito: objeto, sem chaves repetidas, sem `NaN`, até 8 níveis e 200 campos **no corpo inteiro, em todos os níveis** (400). Uma consulta com corpo é 400.
- **Conflitos**: um nome presente no caminho e na consulta ou no corpo é 400 (`input_conflict`); o corpo nunca redefine um parâmetro do caminho.
- **Tipos**: o caminho e a consulta chegam como texto, e o contrato do grafo manda: `integer` e `boolean` viram o tipo do campo, o resto segue como texto, e o `Runner` valida e recusa o que não serve (422). Decimais e dinheiro
  só são aceitos como texto exato ou como o objeto do contrato; um número JSON (`Float`) é recusado pelo contrato, **sem perda monetária**.

### 3. A identidade vem da credencial, nunca do pedido

O adaptador não lê ator, tenant nem papéis do pedido. Entrega ao `Runner`, como `credentials`, um `Http::Credentials` com `Authorization`, `Cookie`, `Origin`, `Sec-Fetch-Site` e os cabeçalhos que a aplicação configurou em
`credential_headers` (`X-Actor-Id` e semelhantes só chegam se alguém os configurar, e o resolvedor os verifica). O resolvedor é o `PublicIdentity` do ADR-049. **CSRF**: um comando só é aceito com `Content-Type: application/json` (mesmo com corpo vazio), que um formulário
de outro site não consegue enviar sem uma verificação prévia (preflight), e o adaptador não emite cabeçalhos CORS; quando há sessão por cookie, a proteção contra CSRF é do resolvedor, que recebe `Origin` e `Sec-Fetch-Site` para recusar um pedido de outro site, e o teste do
adaptador cobre a entrega desses dois cabeçalhos e a recusa do POST vazio sem o tipo. **CORS é fechado**: nenhum
cabeçalho `Access-Control-*`, e uma origem que precise dele o acrescenta no hospedeiro.

### 4. A chave de idempotência

Cabeçalho `Idempotency-Key` (1 a 255 caracteres ASCII imprimíveis, 400 se não for). Uma rota marcada `required` no grafo sem o cabeçalho é 400 (`idempotency_key_required`), **antes** do `Runner`. O `Runner` continua
recusando chave para saída pessoal (ADR-043, §4). Uma repetição devolve o resultado guardado com `Idempotent-Replayed: true`.

### 5. As saídas

| `Outcome` | HTTP | Código público |
|---|---|---|
| `ok` | 200 com o JSON do contrato de saída (204 se a operação não declara saída) | — |
| `unresolved` | 401 | `unauthenticated` |
| `invalid` | 422 | `invalid_input`, com os ponteiros dos campos |
| `denied` | **404** se a operação aponta um registro (`authorize ... record:`), 403 se não; **503** com `Retry-After: 1` se os fatos ou o banco não puderam ser lidos (indisponibilidade, e não negação: o acesso segue recusado); **500** se a recusa é um defeito (predicado incompatível, contexto incoerente) | `not_found` / `forbidden` / `unavailable` / `internal_error` |
| `not_found` | 404 | `not_found` |
| `failed` | 422 | `business_rule` (com o campo), `idempotency_key_reused` ou `rejected` |
| `conflict` | 409, com `Retry-After: 1` se retentável | `conflict` |
| `rate_limited` | 429 com `Retry-After: 1` | `rate_limited` |
| `error` | 500, com `Retry-After: 1` se retentável | `internal_error` |

A lista é pública e fixa: nenhum valor, SQL, causa, mensagem interna nem credencial. Os ponteiros de campo só nomeiam campos **declarados no grafo** (ou `input` e índices de coleção): um nome que o cliente escolheu no corpo nunca volta. Um registro que o ator não vê e um que não existe têm **a mesma resposta** (404) nas operações que apontam um registro; isso
fecha a enumeração por 403 contra 404, e **não** fecha a diferença de tempo (que não foi medida). Toda resposta leva `Cache-Control: no-store` e `X-Content-Type-Options: nosniff`. O motivo textual de um `fail!` não sai
(só o campo): é uma limitação conhecida.

### 6. A saída é conferida antes do commit

Até aqui o `Runner` só conferia a saída do `call` contra o contrato quando havia chave de idempotência; sem chave, um valor fora do contrato terminava `ok` e só a serialização o recusava, **depois do commit**. Agora
`Runner#register` confere a saída **sempre** (`execution_output`, 500), tanto a forma do contrato quanto a possibilidade de **serializar** (um texto binário num campo `json` tem a forma e não serializa), e desfaz a unidade, de modo que uma resposta HTTP nunca diz sucesso sobre um valor inválido. O custo é uma serialização a mais por operação, não medido. O status `rate_limited` (429) entra em `Outcome::HTTP`;
o `Runner` ainda não o produz (os contadores são da C17).

### 7. Perfis, tempo e o que o adaptador não faz

`runners:` aceita um `Runner` por rota (id da rota), para dar a uma rota outros `statement_timeout`, `lock_timeout` e isolamento, **sem mutar o `Runner` padrão**. **O orçamento total do pedido não é do adaptador, e isto é uma decisão que este ADR toma e o mantenedor pode reabrir**: o plano da rodada 6 pedia um orçamento total com cancelamento e limpeza seguros cobrindo o resolvedor, os fatos, o pool e
a serialização, e o adaptador **não o entrega**. Ele não cancela uma thread (o cancelamento no meio do COMMIT é o desfecho incerto que o ADR-048 já trata, e interromper o resolvedor ou a leitura de fatos no meio não tem limpeza segura
fora do `Runner`). O que existe: o `statement_timeout`, o `lock_timeout` e o isolamento por rota (`runners:`), o `pool_timeout` do Sequel na espera por conexão, e o servidor ou o proxy, que respondem pelo tempo de leitura, por cabeçalhos e conexões lentas e pelo tempo total.
Um resolvedor ou um provedor de fatos que travem não têm teto no Vetra. Um
timeout depois de um possível commit deixa o resultado incerto, e a recuperação é repetir **com a mesma chave**, quando uma chave válida foi aceita; sem ela, o cliente não pode repetir com segurança. O adaptador
também não resolve a autoridade entre processos (ADR-049, §5) nem aplica o limite de taxa (C17).

## Alternativas rejeitadas

- **Depender da gem `rack` ou de um servidor.** Uma dependência de runtime para ler um hash; a aplicação chamável basta e roda em qualquer servidor Rack.
- **Deixar o adaptador cancelar o pedido por `Timeout`.** Interromper uma thread no meio de uma transação foi o problema que o ADR-048 resolveu com limpeza explícita; um cancelamento fora do `Runner` o reabriria.
- **Aceitar `application/x-www-form-urlencoded`.** Um formulário de outro site o envia sem preflight, e o CSRF viraria problema do adaptador.
- **403 sempre para o acesso negado.** Revelaria a existência do registro; o ADR-007 já permite o 404.
- **Devolver o motivo do `fail!`.** O texto é do autor do comando e não passou por uma lista de mensagens públicas; entra com um ADR que a defina.

## Consequências

- Os quatro exemplos passam a ser alcançáveis por um pedido HTTP, pelo `Runner` parcial. O servidor real e a equivalência entre as superfícies são da K27.
- A conferência da saída antes do commit vale para toda superfície, não só para a HTTP.
- O corpo de erro tem uma forma única (`{"error": {"code": ...}}`), e um cliente decide por ela.
- Uma rota HTTP com chave obrigatória não existe nos exemplos; o teste cobre a regra direto.

## Garantia

| Garantia | Nível | Mecanismo |
|---|---|---|
| Nenhum campo de identidade do pedido atribui autoridade | Verificável por testes | O adaptador só entrega a credencial; o `PublicIdentity` (ADR-049) confere |
| A leitura do corpo é limitada, qualquer que seja o `Content-Length` | Verificável por testes | `rack.input.read(limite + 1)` |
| Entrada hostil (JSON duplicado, aninhado, consulta repetida, segmento perigoso) é recusada antes do `Runner` | Verificável por testes | 400, 413, 414 e 415 |
| Registro negado e inexistente têm a mesma resposta | Verificável por testes (não cobre o tempo) | 404 nas operações com registro |
| Uma resposta nunca diz sucesso sobre uma saída fora do contrato | Transacional | `Runner#register` antes do commit |

### Testes de aceitação

1. Uma consulta lê o caminho e devolve o JSON serializado; um comando lê o caminho e o corpo; os cabeçalhos de identidade que ninguém configurou não chegam ao resolvedor.
2. Rota desconhecida é 404; método errado é 405 com `Allow`; `OPTIONS` é 405 e sem CORS; `HEAD` só responde onde o grafo o declara, sem corpo e com o `content-length` do GET.
3. O corpo é lido com limite mesmo com `Content-Length` mentiroso, sem `Content-Length` e com valor malformado; JSON com chave repetida, `NaN`, array, texto solto, UTF-8 inválido, aninhamento ou campos demais é 400; tipo de mídia errado é 415, inclusive num POST sem corpo; o limite de campos vale para o corpo inteiro.
4. Conflito entre caminho, consulta e corpo, consulta em comando, corpo em consulta, chave de consulta repetida, `%FF` solto, consulta longa ou com muitos pares e segmento de caminho com `/`, NUL ou UTF-8 inválido são recusados sem chamar o `Runner`.
5. O cabeçalho `Idempotency-Key` malformado é 400; a rota que o exige, sem ele, é 400; a repetição é marcada.
6. Cada status do `Outcome` tem o seu status HTTP e o seu código público; nenhum texto interno chega à resposta; negado e inexistente são iguais nas operações com registro, criar negado é 403, e fatos indisponíveis (conexão, banco, timeouts, permissão SQL) são 503 retentável, e uma recusa que é defeito do avaliador ou do contexto é 500, nunca 403 nem 404; os ponteiros só nomeiam campos declarados.
7. Um erro inesperado do `Runner` é um 500 genérico; toda resposta leva os cabeçalhos seguros e nenhum CORS.
8. Com o `Runner` real e bancos simulados: uma credencial válida lê o registro; sem credencial é 401; cabeçalhos de identidade forjados não autenticam; um id que não é UUID é 422.
9. Uma saída fora do contrato, sem chave, termina `error` com `execution_output` e `ROLLBACK`, sem `COMMIT`; uma saída com a forma do contrato que não serializa é recusada pelo mesmo `register` (o teste cobre `ensure_serializable!` com os dois códigos; o `ROLLBACK` integrado é o da saída inválida).

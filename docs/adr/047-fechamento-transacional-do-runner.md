# ADR-047: Fechamento transacional do Runner

- Status: proposto
- Data: 2026-11-11
- Depende de: ADR-004 (§5), ADR-016, ADR-022 (§6), ADR-040, ADR-043, ADR-045 e ADR-046

## Contexto

O `Runner` despachava as etapas 1 a 6 e 8, mas a etapa 7 era um gancho vazio e uma falha depois da etapa 4 saía como exceção. Faltavam
quatro coisas do ADR-016: os eventos do `emits` gravados na mesma transação que os dados, o registro de idempotência (ADR-043) ligado
à operação, o mapeamento de cada falha para a saída que o ADR promete (422, 403, 409, 500), e a repetição da operação depois de falha de
serialização ou deadlock, que só é segura quando a operação não tem efeito fora do banco.

## Decisão

### 1. Eventos na etapa 7

O `call` nunca grava um evento. Depois da reautorização do estado final, o `Runner` grava os eventos que o comando declara em `emits`
(`Repositories#emit_declared!`), com o payload projetado do **registro que o comando devolveu**, na unidade, antes do commit. Falha
fechada: se o retorno não é o registro da entidade de que todos os eventos declarados partem, não há como projetar, e a unidade é desfeita
(`data_event`). Um payload com campo pessoal continua recusado e desfaz a unidade (ADR-040, §2; a cifra é da rodada 6). Uma consulta e
uma repetição de resultado guardado não emitem.

### 2. Idempotência na etapa 4 e na etapa 7

`run(..., idempotency_key:)` aceita a chave do adaptador (origem `adapter`; a origem `event` é da C14).

- **Antes da etapa 4** (sem transação nem fatos), a chave é recusada como `:invalid` (422) quando a operação é uma consulta
  (`execution_idempotency_query`), quando está fora do formato do registro (`data_idempotency_key`) ou quando a **saída** do comando
  leva algum campo pessoal, direto ou em um `record` ou `collection` (`execution_idempotency_personal`), porque o resultado não pode ser
  guardado em claro (ADR-043, §4). Como todo comando que devolve um `lead` devolve o e-mail pessoal, essa recusa vale para eles todos
  enquanto a cifra não existir.
- **A forma JSON vem do contrato.** Tanto o hash da entrada quanto o resultado guardado são o JSON do valor **segundo o contrato declarado** da
  operação (campos declarados, em `record` e `collection` recursivamente, na forma canônica dos eventos: decimais e dinheiro como texto exato,
  instantes em UTC **com microssegundos**, datas ISO 8601), e não o que o `call` devolveu por inteiro nem um `to_json` do valor Ruby. Assim um
  campo fora do contrato, em particular um campo pessoal que o contrato não declara, nunca é gravado; um valor que não tem um campo obrigatório
  do contrato desfaz a unidade (`data_idempotency_result`, 500); e dois instantes que diferem só nos microssegundos têm hashes diferentes. Um
  número não inteiro dentro de um campo `json` da entrada não tem forma canônica (o hash a recusa), e a chave é recusada antes da etapa 4
  (`:invalid`, `data_idempotency_input`).
- **O tipo é conferido, pela conferência do framework.** Cada campo escalar passa pela **mesma** `Values.coerce` que valida as entradas (tipo, nulidade, enum,
  UUID, comprimento, escala e precisão do decimal, dinheiro, instante e data que existem) antes de ser guardado, e sai na forma canônica dos eventos: um `Hash` num campo
  de texto, `7` ou um e-mail num `id`, um decimal fora da escala (ou `NaN`), um instante ou uma data impossível, um nulo num campo que não aceita nulo ou um valor fora do
  enum não são guardados (`data_idempotency_result`); um campo opcional ausente é omitido, e um campo obrigatório ausente desfaz a unidade. Um contrato com `collection: true`
  vira uma lista. O resultado de uma repetição, já em JSON, passa de novo pelo mesmo serializador sem mudar (`Runner#serialize` é idempotente). O limite é
  este: o framework **confia na declaração de privacidade do contrato**; um texto pessoal dentro de um campo declarado como não pessoal não é detectável.
- **Na etapa 4**, dentro da unidade, o `Runner` reivindica `(tenant, comando, chave)` com o hash da entrada e o principal
  (`Idempotency#claim!`). Cada tentativa reivindica de novo: o claim de uma tentativa desfeita não existe mais.
- **Repetição de resultado.** Mesma chave, mesma entrada e mesmo principal com resultado confirmado: o `call`, a reautorização e os
  eventos **não** rodam, e o `Outcome` traz o JSON guardado, com `replayed?` verdadeiro. O valor de uma repetição é a forma JSON do
  resultado, não o registro Ruby; `Runner#serialize(operation_id, value)` dá a mesma forma ao resultado de uma execução comum, e um adaptador que
  serializa para JSON fica com os dois iguais.
- **Na etapa 7**, depois dos eventos, `complete!` guarda o resultado serializado **na mesma transação**, com o claim emitido por
  `claim!` nesta unidade (a biblioteca recusa qualquer outro objeto). A forma JSON usa as mesmas regras do payload de evento: decimais e
  dinheiro como texto exato, instantes em UTC com microssegundos, datas ISO 8601.
- Chave reutilizada com outra entrada ou outro principal: `:failed` (422, `data_idempotency_key_reuse`), sem revelar nada do resultado.

### 3. O status de cada falha

`run` devolve sempre um `Outcome`; só uma operação que o grafo não tem levanta (erro de programação). `run!` levanta o erro de dados em
vez de mapeá-lo, para testes e diagnóstico. A mensagem e a causa do erro original nunca saem no `Outcome`.

| Origem | `status` | HTTP | Retentável |
|---|---|---|---|
| Identidade não resolvida | `:unresolved` | 401 | não |
| Entrada fora do contrato, chave recusada antes da etapa 4 | `:invalid` | 422 | não |
| Política, escopo, fatos obsoletos, contexto; recusa de acesso no corpo (`data_authorization_*`) | `:denied` | 403 | não |
| `RecordNotFound` no corpo | `:not_found` | 404 | não |
| `fail!` (`Failure`), chave reutilizada | `:failed` | 422 | não |
| `Conflict` de unicidade ou chave estrangeira | `:conflict` | 409 | não |
| `lock_timeout`, deadlock ou serialização que esgotou as repetições | `:conflict` | 409 | **sim** |
| `statement_timeout` | `:error` | 500 | **sim** |
| `data_idempotency_result` (resultado acima de 64 KiB ou fora de JSON) e todo outro erro de dados | `:error` | 500 | não |
| Exceção inesperada | `:error` (`execution_unexpected`) | 500 | não |

O resultado grande demais para a idempotência é **500**, e não 422: a operação válida do cliente não pode ser concluída por um limite do
servidor, e uma nova tentativa dá o mesmo resultado; a unidade é desfeita, como o ADR-043 exige.

### 4. Repetição

Falha de serialização (`40001`) e deadlock (`40P01`) repetem a operação **inteira**, a partir da etapa 3, **depois do rollback**, até
**3 vezes** (a primeira execução mais as repetições), com espera crescente e variação aleatória (50 ms, 100 ms e 200 ms, multiplicados
por um fator entre 0,5 e 1,5; o relógio e o sorteio são injetáveis). Cada tentativa abre a sua unidade, reivindica a chave de novo e
reautoriza; o `op_id` é o mesmo, porque é uma operação lógica só. Os eventos e as escritas de uma tentativa desfeita não existem, então
**não há evento duplicado**.

A repetição só acontece quando a operação é segura para repetir: **nenhuma capacidade em `uses` declara `retry_safe: false` e o comando
não declara `unsafe_effect`** (ADR-004, §5, e ADR-022, §6). Senão a falha sai como `:conflict` retentável, sem repetir. `lock_timeout` e
`statement_timeout` também não são repetidos pelo `Runner`: voltam como retentáveis, e quem repete é o cliente. As três tentativas
internas do `claim!` para a linha que a purga apagou não são esta repetição.

## Alternativas rejeitadas

1. **O `call` grava os eventos.** Duplicaria a regra em cada comando e permitiria um evento sem o dado, ou o dado sem o evento.
2. **Repetir também `lock_timeout` e `statement_timeout`.** O primeiro indica contenção que a espera de uma repetição não resolve, e o
   segundo, uma operação lenta que repetida piora; o cliente decide.
3. **Guardar a forma Ruby do resultado.** O registro é JSON (ADR-043), e a repetição precisa devolver o que um cliente recebeu da primeira
   vez, não o objeto de um processo.
4. **Aceitar a chave num comando de saída pessoal e guardar o resultado sem o campo pessoal.** Mudaria o que a repetição devolve; sem a
   cifra do ADR-013 a recusa é a única saída que não falsifica o resultado.
5. **`data_idempotency_result` como 422.** Culparia o cliente por um limite do servidor.

## Consequências

Sem mudança de banco, plano, IR ou dependência. O `Runner` passa a ser a superfície completa das oito etapas para um adaptador: o que
falta é o histórico e a auditoria (etapa 7 do ADR-016, rodada 6), os handlers de sistema e o runner deles (C14) e os adaptadores. Os testes
que esperavam uma exceção de `run` passam a chamar `run!`. A espera entre repetições bloqueia a thread do chamador, e um adaptador
assíncrono injeta o seu `sleeper`.

## Garantia

- **Verificável por testes (sem banco):** `test/execution_closing_test.rb` cobre o evento na etapa 7 (e a falha fechada), a ordem do claim,
  dos eventos e da conclusão antes do commit, o replay sem execução nem evento, a chave reutilizada, as recusas antes da etapa 4, cada linha
  da tabela de status, a repetição por serialização e deadlock (espera crescente, no máximo 3, sem evento duplicado) e a recusa de repetir com
  `unsafe_effect` ou `retry_safe: false`.
- **Transacional a confirmar:** `script/sonda_fechamento.rb` (13 verificações no PostgreSQL 17 e 18, e na CI), com **duas transações
  concorrentes de verdade**: uma falha de serialização e um deadlock repetidos com sucesso, sem evento duplicado, e a mesma falha de serialização
  num comando com `unsafe_effect` voltando como 409 retentável sem repetir; a chave guardando o resultado e a repetição sem executar nem emitir.
- **Operacional:** a atribuição de `retry_safe: false` e de `unsafe_effect` é do autor do modelo; o framework confia nela.

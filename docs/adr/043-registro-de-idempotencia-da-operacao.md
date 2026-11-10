# ADR-043: Registro de idempotência da operação

- Status: aceito
- Aceite: 2026-11-10, pelo Claude por delegação do mantenedor, após a auditoria da K16 (aprovada na rodada 3), com a sonda da idempotência em 83/83 no PostgreSQL 17.11 e 18.6.
- Data: 2026-11-10
- Depende de: ADR-005, ADR-008, ADR-011, ADR-013, ADR-014, ADR-016, ADR-024, ADR-036, ADR-038 e ADR-040
- Evidência: [sonda da idempotência](../../script/sonda_idempotencia.rb), no PostgreSQL 17 e 18

## Contexto

O ADR-016 descreve o contrato da idempotência da operação: uma tabela com chave única em `(tenant, comando, chave)`, o hash da
entrada e o resultado, gravada na etapa 4 e na mesma transação, de modo que só existe se a operação confirmou; a mesma chave com a
mesma entrada devolve o resultado guardado, com outra entrada é 422, e uma chave em uso por uma operação aberta espera o lock da
linha e, passado o `lock_timeout`, é 409. Deixa em aberto o esquema, a retenção (24 horas é "hipótese de trabalho") e o custo.

Quatro lacunas aparecem quando o contrato vira tabela:

1. **O contexto global.** Blog e chat não têm tenant, e `UNIQUE (tenant, comando, chave)` com tenant nulo **não é único** no
   PostgreSQL: duas linhas com a mesma chave caberiam.
2. **A retenção.** A chave de um adaptador (cabeçalho `Idempotency-Key`, argumento de CLI) pode expirar em horas. A chave derivada
   de um evento (o handler de sistema, ADR-014, §3 e ADR-024) não pode: enquanto a entrega existir, inclusive a `dead`, uma
   repetição do evento precisa achar o resultado, e não executar o comando de novo.
3. **Quem purga.** A outbox tem o relay e a manutenção (ADR-040), mas o chat não tem outbox, e a aplicação nunca deve apagar chaves.
4. **O que a chave protege.** Duas pessoas no mesmo tenant podem escolher a mesma chave para o mesmo comando: sem amarrar a chave a
   um principal, a segunda leria o resultado da primeira.

Este ADR decide o esquema e as quatro lacunas. O uso do registro pelo executor (etapas 4 e 7, a repetição e o 409 como resposta
HTTP) é da K19; a derivação da chave a partir do evento e o runner dos handlers, da C14.

## Decisão

### 1. A tabela `vetra.idempotency`

Existe em **toda** aplicação, no schema `vetra`, com dono `vetra_owner`:

| Coluna | Forma |
|---|---|
| `id` | `bigint GENERATED ALWAYS AS IDENTITY`, chave primária; serve à purga em lotes |
| `tenant_id` | o tipo do `id` da raiz do tenant; **nulo** numa aplicação global |
| `command` | `text`, de 1 a 255 caracteres |
| `key` | `text`, de 1 a 255 caracteres ASCII visíveis (`^[!-~]{1,255}$`) |
| `origin` | `adapter` ou `event`; só `adapter` numa aplicação sem outbox |
| `principal` | o `actor_id`, `system:<handler>` do ator de sistema (ADR-024, §4) ou nulo para o visitante |
| `input_hash` | `bytea` de 32 bytes: SHA-256 do JSON canônico da entrada |
| `result` | `jsonb` de até 64 KiB; nulo até a operação concluir |
| `handler`, `event_id`, `event_created_at` | a origem `event`: obrigatórios nela e proibidos na outra |
| `created_at` | do banco (`statement_timestamp()`), nunca da aplicação |

A chave única é `UNIQUE NULLS NOT DISTINCT (tenant_id, command, key)`, **uma** restrição que vale nos dois contextos: com tenant nulo, a
mesma chave duas vezes é violação, como é com tenant presente. Não se inventa um tenant sentinela e não há índice parcial por
contexto. O PostgreSQL 17 (o mínimo do projeto) já aceita a cláusula.

### 2. O principal faz parte da chave

A reivindicação compara o `principal` e o hash da entrada. Se **qualquer um** difere, o erro é o mesmo (`data_idempotency_key_reuse`,
422) e **nunca devolve o resultado guardado nem diz qual dos dois diferiu**: quem não é dono da chave não aprende que ela existe nem o que
ela produziu. O hash vem do JSON canônico (chaves ordenadas), então a ordem das chaves da entrada não conta.

### 3. O fluxo na unidade de trabalho

1. **Reivindicar (etapa 4).** `INSERT ... ON CONFLICT ON CONSTRAINT vt_idempotency_key DO NOTHING RETURNING id`. Se inseriu, a chave é
   nossa; a linha só se torna visível a outros quando a transação confirma.
2. **Conflito.** Se não inseriu, lê a linha: principal ou hash diferentes são `data_idempotency_key_reuse`; sem resultado é
   `data_idempotency_state` (não deveria acontecer, porque a linha só é visível depois do commit); com resultado, é a repetição e o `call`
   não roda.
3. **Concorrência.** Se a transação dona da chave ainda está aberta, o `INSERT` espera a unicidade (o lock da linha, como o ADR-016
   manda). Se ela confirma, o segundo vê o resultado e repete sem executar; se ela desfaz, a chave é do segundo, que executa. Passado o
   `lock_timeout`, é `Conflict(:lock_timeout)`, que o executor mapeia para 409.
4. **Concluir (etapa 7).** `UPDATE ... SET result = ... WHERE id = ? AND result IS NULL AND principal IS NOT DISTINCT FROM ?` na mesma
   transação. O rollback da unidade desfaz a reivindicação e o resultado juntos. O claim é **o objeto que `claim!` emitiu nesta transação**: a
   biblioteca registra os claims emitidos por identidade do objeto e do contexto transacional, então um replay, um claim de outra
   unidade, um `Claim` construído à mão (mesmo com os mesmos valores de um claim pendente) e uma segunda conclusão são
   `data_idempotency_state`, e o `WHERE` impede, no banco, que a conclusão
   sobrescreva um resultado confirmado ou conclua a chave de outro principal.

Um registro confirmado sempre tem resultado. Não há linha "em andamento" fora de uma transação aberta, então não há chave presa por uma
queda: o rollback a devolve.

### 4. Limites do que se guarda

- **O resultado:** JSON de até **64 KiB** (65.536 bytes), medidos **no banco**, como `octet_length(result::text)` (o `jsonb::text` tem um
  espaço depois de `:` e de `,`). Acima disso a operação desfaz, porque a promessa de repetir não se cumpriria, com `data_idempotency_result`.
  O banco é o árbitro, porque o `jsonb` **normaliza** o que recebe: chaves repetidas ficam só com a última e números e escapes são
  reescritos, então o JSON compacto de Ruby pode ser **maior** que o `jsonb::text` (e o `jsonb::text` pode ser maior que o compacto, pelos
  espaços). Ruby não decide o teto de 64 KiB: impõe só um limite adicional ao payload serializado (1 MiB, proteção de memória e de rede), que
  recusa até um JSON que normalizaria para menos, e a recusa do `CHECK` (23514) na
  conclusão vira `data_idempotency_result`, sem a mensagem do driver. As duas fronteiras (o compacto que cabe só depois de normalizado e o
  compacto que não cabe) são testadas no PostgreSQL.
- **Dado pessoal.** Enquanto a cifra do ADR-013 não existe (rodada 6), o resultado de um comando que devolve campo pessoal **não pode
  ser guardado em claro**; a K19 recusa esse caso, como a K11 condena o evento com campo pessoal. Este ADR não o resolve.
- **A chave:** de 1 a 255 caracteres ASCII visíveis, conferida em Ruby antes do SQL e no `CHECK`.

### 5. Retenção por origem e quem purga

| Origem | Retenção |
|---|---|
| `adapter` | **24 horas** por padrão (valor inicial, configurável de 1 a 8.760 horas); passado o prazo, a chave pode ser reutilizada |
| `event` | enquanto existir uma entrega do evento para o handler, em `vetra.deliveries` **ou** em `vetra.dead_deliveries`, e nunca menos que o prazo de `adapter` |

A purga é do **papel de manutenção `vetra_relay`**, o mesmo da outbox (ADR-040, §3), e **nunca** da aplicação: o `vetra_app` tem `SELECT`,
`INSERT` das colunas da chave e `UPDATE` só de `result`, e nenhum `DELETE`. O `vetra_relay` tem `SELECT` e `DELETE` e uma política própria.
A purga é SQL parametrizado em `Vetra::Data::Relay#purge_idempotency`, em lotes ordenados por `created_at` e `id` (sem `FOR UPDATE`, que exigiria `UPDATE`; só apaga
linhas já confirmadas e vencidas, que nenhuma transação aberta conclui) e com **um corte de tempo fixado por execução e tirado do relógio do PostgreSQL** (o de `created_at`, sem depender do relógio do processo),
para que chaves que vencem durante a purga fiquem para a próxima e o laço sempre termine. O corte viaja como texto com o fuso
(`timestamptz::text`) e entra por `CAST(? AS timestamptz)`: nunca como `timestamp` sem fuso, que o deslocaria pelo fuso da sessão. O
comando `vetra idempotency:purge [--retention-hours] [--batch]` a expõe. Não há rotina SQL nova: menos uma superfície `SECURITY DEFINER`.

Uma aplicação **sem outbox**, como o chat, não tem chave de evento (o `CHECK` da origem a proíbe), e a purga só varre as de adaptador. O
papel de manutenção existe em toda aplicação (vem do bootstrap do ADR-036), então o chat também a roda.

### 6. Privilégios e RLS

Tabela com `ENABLE` e `FORCE ROW LEVEL SECURITY`, `REVOKE ALL` de `PUBLIC`, `vetra_app` e `vetra_relay`, e então as concessões da §5.
Numa aplicação com tenant, a política de `vetra_app` é `"tenant_id" = (SELECT vetra.current_tenant())` em `USING` e `WITH CHECK`
(o ator de sistema também tem tenant); numa global, `"tenant_id" IS NULL`. Um tenant não lê nem grava a chave de outro. O `vetra_relay`
lê todas, para purgar.

### 7. O plano incremental

A seção da idempotência é reconhecida pelo **texto exato** que o gerador atual produz, como a outbox (ADR-040, §5): nasce inteira, num
passo, quando o modelo anterior não a tem; qualquer diferença depois é recusada com `db_plan_statement` até um ADR a traduzir. Numa
aplicação com outbox, a guarda do papel de manutenção e o `USAGE` do schema vêm do relay e não se repetem (instruções idênticas em duas
seções confundiriam o `Differ`). Os quatro exemplos ganham um plano novo cada.

## Alternativas rejeitadas

| Alternativa | Por que não |
|---|---|
| Tenant sentinela (um UUID fixo) para o contexto global | Inventa uma linha que não existe, e o RLS de tenant a trataria como um tenant de verdade |
| Dois índices únicos parciais (um para tenant nulo, outro para presente) | Duas restrições para manter e testar; `NULLS NOT DISTINCT` diz o mesmo numa só |
| Chave única sem o principal, e o resultado devolvido a quem repetir a chave | Vaza o resultado de um ator para outro do mesmo tenant |
| Linha "em andamento" com estado e expiração, fora da transação | Cria chaves presas por uma queda; a reivindicação dentro da transação dispensa a recuperação |
| Rotina SQL `SECURITY DEFINER` de purga, como a da outbox | Mais uma rotina fechada, e a purga de eventos precisaria de política de dono em `dead_deliveries`, que é da seção da outbox |
| Purgar pela aplicação | Daria `DELETE` ao `vetra_app`, que poderia apagar a prova de uma operação que já executou |
| Reter a chave de evento por tempo fixo | Uma repetição depois do prazo reexecutaria o comando; a regra do ADR-014 é a entrega, não o relógio |

## Consequências

- Toda operação com chave passa a escrever e atualizar uma linha: o custo entra no caminho quente e é medido na K20 (ADR-016, "custo da
  escrita na tabela de idempotência"). Esta tarefa não o mede.
- A tabela cresce com as chaves de adaptador por 24 horas e com as de evento pelo tempo das partições de entregas (7 dias por padrão, ADR-040):
  a purga precisa rodar. Sem ela, a tabela só cresce; o ADR não a agenda, e o `idempotency:purge` é o ponto de entrada de quem agenda.
- O `lock_timeout` da espera é o da unidade (ADR-016); a K17 o provisiona. A reivindicação não define um próprio.
- O resultado de um comando com campo pessoal não é guardado enquanto a cifra não existir.
- A **K19** liga isto ao executor: a chave vem do adaptador (`Idempotency-Key`, argumento, job) ou é derivada do `event_id` pela **C14**, a
  repetição devolve `replay`, e `data_idempotency_key_reuse` vira 422 e `Conflict(:lock_timeout)`, 409.

## Testes de aceitação

1. Uma chave nova executa e guarda; a repetição devolve o resultado sem executar de novo (sonda, 3 aplicações).
2. A mesma chave com outra entrada, ou por outro principal, é recusada sem devolver o resultado.
3. A operação que desfaz depois de reivindicar não deixa linha, e a chave volta a ser livre.
4. Duas transações na mesma chave: a segunda espera a primeira e devolve o resultado dela; se a primeira desfaz, a segunda executa; passado
   o `lock_timeout`, é conflito. Com quatro transações, o `call` roda uma vez só.
5. Tenant nulo: a mesma chave duas vezes é violação de unicidade (23505), também em aplicação com tenant, com a linha inserida pelo dono.
6. Um tenant não lê nem grava a chave de outro (RLS); a aplicação não apaga, não esvazia, não define `id` nem `created_at` e só atualiza `result`.
7. O banco recusa chave fora do formato, resultado acima de 64 KiB e origem incoerente (23514); o chat recusa a origem `event`.
8. A purga apaga em lotes as chaves de adaptador vencidas e mantém as dentro do prazo; mantém a chave de evento com entrega pendente ou morta,
   apaga a órfã vencida e a apaga também depois que a entrega some.
9. O papel de manutenção não escreve nem atualiza o registro, e a aplicação não o purga.
10. `db:plan --check` confere o plano e o retrato dos quatro exemplos no PostgreSQL 17 e 18, e o `Differ` recusa a seção alterada.
11. A conclusão recusa replay, claim de outra transação, claim fabricado e segunda conclusão, e não sobrescreve um resultado confirmado; os erros do
    banco na conclusão saem traduzidos, sem a mensagem do driver; o teto de 64 KiB é decidido pelo banco na fronteira (sonda e testes).
12. O corte da purga é um só por execução, vem do banco e não muda com o fuso da sessão do papel de manutenção (testes e sonda).
13. O teto de 64 KiB vale sobre o `jsonb` normalizado: chaves repetidas e números reescritos que encolhem são aceitos, e um `Claim` fabricado com
    os valores de um pendente é recusado (sonda).

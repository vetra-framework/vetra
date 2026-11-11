# ADR-046: Autorização dos acessos, estado final e ator de sistema

- Status: proposto
- Data: 2026-11-11
- Depende de: ADR-016 (etapas 3 e 6), ADR-024 (§4), ADR-037, ADR-039, ADR-044 e ADR-045

## Contexto

O ADR-044 decidiu que o `uses` de um comando **não concede dados**: cada acesso adicional do corpo precisa de uma política, por ação,
registro e campos. O ADR-045 entregou o `Runner` com a admissão (etapas 1 a 3) e deixou os acessos dos repositórios sem autorização:
`Repository#execute` só confere capacidade de escrita, unidade e tenant. Duas lacunas seguiram abertas. Primeiro, a **reautorização do
estado final** (etapa 6 do ADR-016): um `update` pode mover o registro para um escopo em que o ator não tem acesso (a troca de revenda do
exemplo 1, teste 4). Segundo, o **ator de sistema** de um handler: o ADR-024, §4, decide que a concessão dele é a lista `calls`, e o
avaliador da C13 o recusava por inteiro.

Blog e chat não têm RLS (ADR-031): para eles esta camada é a única barreira. Nos CRMs ela concorda com o RLS, que continua sendo a
barreira final.

## Decisão

### 1. Uma guarda por operação, instalada na unidade pelo Runner

`Execution::AccessGuard` é criada pelo `Runner` a cada operação e entregue à `UnitOfWork` (`transaction(guard:)`, lida por
`unit.guard`). Os repositórios a consultam em cada acesso; **fora do `Runner` ela não existe**, e os repositórios se comportam como
sempre (capacidade, tenant, contexto e transições). A guarda decide com `Authorization#decide`, a mesma função da admissão, sobre a linha
do acesso:

| Acesso | Decisão |
|---|---|
| `find!`, `lock!` | `read` sobre o registro lido, com todos os campos da entidade. `lock!` **não** exige `update`: a escrita é decidida quando acontece (o vínculo `add_member` do chat, por exemplo, não tem política `update`) |
| `create!` | `create` sobre a linha candidata (campos fornecidos, defaults, tenant), **antes** do `INSERT` e antes de conferir a transição |
| `update!` | `read` e `update` sobre o OLD, lido sob lock, com os campos que mudam |
| `delete!` | `read` e `delete` sobre o OLD, lido sob lock (o `DELETE ... RETURNING` só o devolveria depois de apagar) |
| vínculo (`add_member!`, `remove_member!`) | `read` do dono e a **ação do vínculo** (`add_member`, `remove_member`) sobre o dono; o alvo e a junção fazem parte do que a ação autorizou |
| coleção (`where`, `order`, `first`, `last`, `all`) | `read` por linha: a linha que o papel não lê some, como no RLS |

Um `include_on_create` roda como parte da criação já autorizada e **não** repete a decisão (a sala recém-criada ainda não tem o vínculo
que a política `members` exigiria para lê-la).

### 2. Semântica da recusa

- **Sem concessão alguma** do papel para a ação na entidade: `data_authorization_denied`, explícito, **antes de qualquer consulta**, inclusive a de coleção (a
  resposta não pode depender de o registro existir: sem isso, "negado" e "não encontrado" seriam um oráculo de existência), mesmo para uma
  coleção vazia. É o caso
  de `chat.add_member_by_email`: `users_read` sem política de leitura de `chat.user` recusa no corpo, e nada é gravado. Um resultado vazio
  esconderia o erro de modelo.
- **Há concessão, mas a linha não a satisfaz**: leitura de um registro vira `RecordNotFound` (como no RLS) e a coleção filtra; escrita
  recusa com `data_authorization_denied` antes de escrever. Campos não cobertos são `data_authorization_fields`, e concessão que depende
  de `rate_limit:` sem contadores é `data_authorization_rate_limit` (ADR-044).
- A leitura de registro inteiro exige **todos** os campos da entidade; uma política que cobre menos recusa.

A coleção lê em lotes de 200 linhas e avança até completar o limite de `first(n)`/`last(n)` com as linhas **visíveis** (ou esgotar a
tabela): o limite vale depois do filtro, e a ordem ganha o `id` como desempate (a `Query` já o faz).

### 3. Coletor de fatos na unidade

Os fatos de cada decisão (as entidades que as políticas candidatas percorrem, com as junções) são lidos **na própria unidade**, na mesma
transação, pelo mesmo `fact_rows` do provedor da borda (limite de 10.000 linhas por entidade, recusa em vez de truncar). Há um cache por
entidade dentro da operação, **descartado a cada escrita** dela: as escritas passam todas pelos repositórios, então o que a operação
mudou nunca é lido velho. Ao contrário do `Snapshot` da admissão, não há marcador de revisão a confirmar: os fatos nascem da transação
que vai gravar.

### 4. Estado final (etapa 6)

Depois do `call` e antes do commit, o `Runner` chama `AccessGuard#reauthorize!` (e, só então, `register`): para cada linha criada ou alterada, relê o estado
final com fatos novos e decide `create` (linha criada) ou `update` sobre ele, com os campos gravados. Recusa com
`data_authorization_final`, o que desfaz a unidade inteira. A linha apagada depois de escrita não é reautorizada (a última escrita diz se ela está apagada: apagar e recriar o mesmo `id` a deixa
existente), e a que sumiu das leituras (invisível depois da escrita) recusa. Um savepoint de `compose` que é desfeito devolve à guarda o
ponto de retorno anterior: as escritas registradas dentro dele e os fatos lidos deixam de valer. Só uma **exceção** que sai do
`compose` o dá por desfeito: `break`, `return` e `throw` não são exceções, o Sequel libera o savepoint, e o que foi escrito vale. Onde há RLS, o `WITH CHECK` já recusou na escrita (`data_access_denied`), e as duas
recusas concordam; onde não há, esta é a barreira. Os campos de transição continuam conferidos pelo repositório a cada escrita. Um `call` que sai **sem concluir o fechamento** (`throw`,
`break` ou exceção) nunca é confirmado: o `Runner` marca a transação para ser desfeita (`UnitOfWork#abandon!`), porque o Sequel trataria
uma saída não local como commit e a reautorização seria pulada.

### 5. Consulta de coleção na admissão

Uma consulta `read` **sem** `record:` não tem linha para a etapa 3: o papel a admite (há concessão, os campos de leitura inteira a
cobrem), sem fatos (`fact_plan` devolve vazio), e a guarda filtra cada linha no corpo. Um comando sem `record:` que não seja o CRUD de
criação continua recusado por falta de informação (ADR-044).

### 6. Ator de sistema (ADR-024, §4)

`Identity` ganha `system_actor`, o identificador do handler; ele não tem `actor_id` nem papéis. Na etapa 3, `Authorization#check` autoriza o
comando **se, e somente se,** ele está nos `calls` do nó `handler` cujo `id` é o `system_actor`; sem papéis, fatos nem revisão, com a
entrada ainda validada e o contexto ainda conferido. Fora dos `calls`, handler desconhecido ou nó que não é handler recusam com
`data_authorization_system_actor`. A guarda não aplica políticas de papéis a um ator de sistema, e a reautorização é vazia: o tenant do
evento segue isolado pelo repositório e pelo banco (RLS com a condição `vt_system`, K15). A chave de idempotência e o runner dos handlers
são da K19 e da C14.

## Alternativas rejeitadas

1. **Traduzir as políticas para SQL nos acessos.** Nega o ADR-037 (o subconjunto SQL é só do RLS dos CRMs) e não cobre blog e chat.
2. **Recusar a coleção em vez de filtrar.** Obrigaria o corpo a conhecer a política; o filtro por linha é o que o RLS faz.
3. **`lock!` exigir `update`.** Quebraria `chat.add_member`, cujo papel tem a ação do vínculo e não `update`.
4. **Reautorizar só pelo que o repositório devolveu no `UPDATE`.** Não relê os fatos: um vínculo mudado na mesma operação passaria.
5. **Cache de fatos entre operações.** Exige a invalidação por entidade e por papel que o ADR-045 já declinou; o cache vale só dentro da
   operação.
6. **Confiar só no RLS dos CRMs.** Blog e chat não têm RLS.

## Consequências

Sem mudança de banco, plano, IR ou dependência. Cada acesso passa a custar uma decisão, e a primeira de cada entidade, a leitura dos
fatos que ela percorre; o `delete!` ganha um `SELECT ... FOR UPDATE`. O custo é da referência e da medição da K20, não uma promessa. A
leitura de coleção filtra em Ruby, em lotes, e não é o caminho para tabelas grandes com filtro seletivo; a evolução é uma consulta com
a política traduzida, que exigiria um ADR próprio. Limites assumidos: o `rate_limit:` segue sem contadores (rodada 6), a leitura exige
todos os campos, e os handlers ainda não rodam (C14).

## Garantia

- **Verificável por testes (sem banco):** `test/execution_guard_test.rb` cobre cada acesso, a recusa explícita sem concessão, o
  filtro e a paginação, a reautorização do estado final, o vínculo e o ator de sistema; `test/execution_authorization_test.rb`, o
  ramo de sistema, a admissão de coleção e `decide`.
- **Transacional a confirmar:** `script/sonda_acessos.rb` (21 verificações no PostgreSQL 17 e 18, e na CI): no chat, o filtro de
  `my_rooms`, a leitura da sala nova na mesma operação que escreveu o vínculo (os fatos antigos são descartados), a recusa de `add_member_by_email` e a mudança do que o membro novo lê; no blog, o estado final recusando a troca de autor;
  no CRM com revendas, a troca de revenda recusada e desfeita, o isolamento de tenant e o ator de sistema com os `calls`.
- **Operacional:** o tamanho dos dados que a leitura de fatos e o filtro de coleção aguentam.

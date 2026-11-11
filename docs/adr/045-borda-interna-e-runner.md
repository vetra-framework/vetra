# ADR-045: Borda interna, autoridade de revisão e Runner

- Status: proposto
- Data: 2026-11-11
- Depende de: ADR-016, ADR-020, ADR-024 (§4), ADR-039, ADR-040, ADR-043, ADR-044 e a C15 (limites da unidade)

## Contexto

O ADR-044 decidiu que o avaliador de autorização não abre transação e só vê os fatos que uma **borda confiável** lhe entrega,
com a revisão confirmada de forma autoritativa fora do pool da operação. Ele deixou a borda sem dono: o contrato dos fatos, a
autoridade de revisão e o despacho. Sem isso, as oito etapas do ADR-016 não rodam de ponta a ponta, as primitivas CRUD e de
vínculo continuam só descritas (`executor: "pending"` no linker) e a K18 não tem onde aplicar a autorização aos acessos.

Este ADR decide a borda e o `Runner` das etapas 1 a 5 e 8. As etapas 6 e 7 têm ganchos próprios e vazios: a K18 reautoriza o
estado final e a K19 grava eventos e idempotência. O ADR-044 continua proposto e o aceite é do mantenedor; a borda é injetável,
então uma troca de decisão (a transação curta de leitura, alternativa 1 do ADR-044) troca o provedor sem reescrever o despacho.

## Decisão

### 1. A borda é um contrato de três colaboradores

`Vetra::Execution::Edge.new(identity:, facts:, authority:)` recebe três objetos chamáveis:

- `identity.call(credentials)` devolve uma `Identity` (tenant, ator e papéis). A autenticidade das credenciais é do adaptador do
  hospedeiro; o `Runner` nunca lê tenant, ator ou papéis da entrada.
- `facts.call(request)` recebe uma `FactsRequest` (o avaliador, a operação, o contexto, os papéis e a entrada validada) e devolve o
  `Snapshot` da operação. Lê **fora do pool da operação** e lê o marcador de autoridade **antes** dos fatos: uma mudança no meio
  deixa o snapshot parecendo velho, nunca novo.
- `authority.call(context)` confirma o marcador corrente, de forma autoritativa; é o `current_revision` do ADR-044. Se também
  responder a `publish!(context)`, o `Runner` o chama (§3).

A exceção de um colaborador nunca atravessa a borda: identidade vira `execution_identity` (qualquer exceção, inclusive um erro de
dados), fatos e autoridade viram `data_authorization_snapshot`, sempre sem causa e sem a mensagem do provedor. Só um erro de dados
que o **provedor de fatos** levante por conta própria (por exemplo, fatos acima do limite) mantém o seu código, também sem causa.

### 2. Implementações de referência e a autoridade de revisão

A referência serve às sondas e ao uso local. Vale para **um processo** e para o tamanho de dados da referência; um produto com
vários processos ou muito dado injeta as suas implementações.

- **CRMs (`DatabaseAuthority`).** O marcador é composto, `[revisão de vetra.authz_revisions, geração da identidade]`. A revisão é lida
  numa só instrução em autocommit, pelo pool próprio da borda, e sobe por trigger na mesma transação que muda o dado (ADR-020 e 030).
  A geração da identidade é entregue pela borda e sobe (`identity_changed!`) quando um papel muda fora do banco, por SSO, por
  exemplo. Um tenant sem linha de revisão recusa.
- **Blog e chat (`InProcessAuthority`).** Não têm tenant nem revisão SQL, e este ADR não inventa um. O marcador é uma geração
  **em processo**. O `Runner` a publica depois do commit (ou da falha) de todo comando que usa um repositório `read_write` de uma
  entidade que alguma política lê, derivado da IR (a entidade da política, as junções e os alvos dos seus saltos `exists`). Quando uma
  atribuição de papel muda fora do `Runner`, a borda publica. **Escritas feitas por outro processo, ou direto no banco, não movem
  essa geração**, e este ADR não finge que as detecta: a autoridade distribuída é do modo hospedado e dos adaptadores (rodada 6).
- **Provedor de fatos (`DatabaseFacts`).** Lê, numa `UnitOfWork` própria (pool próprio, mesmo escopo e papel `vetra_app`), as linhas
  que as políticas candidatas percorrem: a entidade principal só pelo `record:` da entrada e as demais inteiras. Como lê com o
  contexto do ator, o RLS dos CRMs filtra os fatos como filtra a operação. Passando do limite de linhas (10.000 por entidade por
  padrão), **recusa** em vez de truncar, porque uma lista incompleta provaria uma ausência falsa. Não guarda cache entre
  operações; cada operação lê de novo. Isso inclui a junção inteira `chat.room_membership` e o alvo `chat.user`
  dos percursos `members` (C16), sem filtrar os vínculos só pelo ator ou sala principal.

Autoridade ausente, divergente ou fora do ar recusa com `data_authorization_snapshot`.

### 3. O Runner

`Runner.new(linked:, catalog:, unit:, edge:, unit_options:)` percorre, por operação:

| # | Etapa | No `Runner` |
|---|---|---|
| 1 | Resolver | `Edge#resolve`; falha vira `Outcome(:unresolved)` |
| 2 | Validar | `Authorization#validate_input`; falha vira `Outcome(:invalid)` (422) |
| 3 | Autorizar | provedor de fatos e `Authorization#check`; recusa vira `Outcome(:denied)` (403) |
| 4 | Abrir | `UnitOfWork#transaction` ou `#read`, com o contexto e os limites da C15 (`unit_options`) |
| 5 | Executar | o `call` verificado ou a primitiva, só com as capacidades de `uses` |
| 6 | Persistir | reautorização do estado final (K18, [ADR-046](046-autorizacao-dos-acessos-e-estado-final.md)) |
| 7 | Registrar | eventos do `emits` e resultado da idempotência (K19, [ADR-047](047-fechamento-transacional-do-runner.md)) |
| 8 | Confirmar | o commit; depois dele, ou da falha, a publicação da geração |

As etapas 1 a 3 devolvem um `Outcome` e **não tocam o pool da operação**. O que acontece depois da etapa 4 (`Failure` do `fail!`,
conflito, timeout, erro inesperado) termina com a unidade já desfeita por inteiro: `run!` o **levanta**, e `run` o devolve como `Outcome` com o
status do ADR-016 (422, 409, 500; ADR-047). Uma
operação que o grafo não tem é erro de programação (`data_execution_operation`), não um `Outcome`.

A geração em processo é publicada **também na falha** depois da etapa 4: o desfecho de um commit que falhou no meio é incerto, e
publicar a mais custa só um snapshot refeito. Publicar **antes** do commit seria pior: outra operação leria fatos antigos sob o
marcador novo.

**Publicação que falha.** Depois do commit, `Edge#publish!` nunca levanta: o comando já existe, e uma exceção da autoridade não pode
desfazê-lo nem mascarar a sua `Failure`. Em vez disso a **confirmação fica indisponível**: `Edge#authority` (o `current_revision` do
avaliador) passa a recusar com `data_authorization_snapshot`, então nenhum snapshot anterior é admitido enquanto a invalidação não
estiver garantida. A borda volta a admitir quando uma nova chamada de `Edge#publish!(contexto)`, feita pelo hospedeiro, tem sucesso
(devolve `true`) **e foi iniciada depois da última falha**: a geração que ela publica é posterior ao commit que não conseguiu publicar.
Uma publicação lenta, iniciada antes da falha, não reabre a guarda, porque o seu incremento pode ser anterior a esse commit.

**Erros do driver.** O `Runner` traduz o `Sequel::DatabaseError` que sobra do `BEGIN` e do `COMMIT` (a unidade só traduz os
retentáveis) para um erro de dados, sem a mensagem nem a causa do driver.

**Limite assumido.** Entre o commit e a publicação da geração há uma janela de microssegundos em que outra thread do mesmo processo
pode ser admitida com fatos lidos antes do commit. É a mesma janela de admissão que o ADR-044, §1.4 aceita (como no ADR-020, uma
admissão que já começou antes do commit de uma revogação pode terminar), e o RLS dos CRMs continua verificando o vínculo atual
no banco. Este ADR não promete ordenação distribuída estrita.

### 4. Capacidades, primitivas e o descritor do linker

- O `call` recebe só o que o `uses` declara, na ordem dos parâmetros: um repositório ligado à unidade (`Repositories#bind`) ou o
  relógio da operação (`clock`, o instante da unidade). Outra capacidade (`uuid`, `random`, efeitos externos) **recusa** com
  `execution_capability`, porque ainda não há executor para ela; nenhuma é simulada em silêncio.
- A entrada chega ao `call` como um `Data` com **todos** os campos do contrato; o opcional ausente é `nil`. O hospedeiro do `call`
  oferece só `fail!`, que levanta `Execution::Failure` (campo e motivo como dados, nunca no texto do diagnóstico).
- As primitivas `crud.create`, `crud.read`, `crud.update` e `crud.delete` e as de vínculo `many_to_many.add|remove.<relação>` rodam
  pelos métodos do repositório da entidade autorizada.
- O bloco Ruby verificado continua privado. `LinkedGraph#run_implementation` é a única porta, para o `Runner`, e só roda operações
  Ruby, pelo `instance_exec` do `BasicObject`: um hospedeiro que o redefina não extrai o bloco. O descritor `builtin` deixa de dizer `executor: "pending"`: traz `kind`, `operation` e `name`. A IR não muda.

### 5. As duas contagens de transações

O teste 1 do ADR-016, relido pelo ADR-044 como "zero transações **da operação**", é medido nas duas pontas: a do pool da operação
(zero nas etapas 1 a 3 recusadas) e a do pool da borda (que **não** é zero: a resolução dos fatos abre a sua transação). A sonda
as conta pelo logger de cada pool. Nenhuma tarefa anuncia "zero transações do fluxo".

### 6. Composição

Um comando que chama outro por composição mantém o `cmd` da operação externa nos savepoints (ADR-016), então a autoridade de
transição de um campo (`set_by`, `guarded`) é a do comando externo, e **um comando composto não empresta a autoridade de
transição de outro** (ADR-039). O `Runner` desta entrega não expõe composição ao `call`; ela chega com os handlers (C14).

## Alternativas rejeitadas

1. **Provedor de fatos no pool da operação.** Simplificaria a medição, mas faria a recusa abrir transação do pool da operação e
   quebraria o teste 1 (ADR-044, alternativa 1). O pool próprio da borda é o custo que o ADR-044 já aceitou.
2. **Autoridade por TTL ou por NOTIFY.** Eventualmente consistentes, não cumprem o contrato de invalidação do ADR-044, §1.2.
3. **Publicar a geração antes do commit, ou só no sucesso.** Antes, fatos velhos passam sob marcador novo. Só no sucesso, um commit
   de resultado incerto deixa snapshots velhos válidos.
4. **Cache de snapshots entre operações.** Mais rápido, mas exige invalidação por entidade e por papel que a K17 não prova; cada
   operação lê de novo, e a K20 mede o custo.
5. **Inventar tenant ou revisão SQL para blog e chat.** Mudaria o modelo e o plano; a geração em processo, com o limite dito, não.

## Consequências

Sem mudança de banco, plano, IR ou dependência. A execução das oito etapas ficou completa nas etapas 1 a 8 pelas K18 e K19; falta o histórico e a
auditoria (etapa 7 do ADR-016), os handlers (C14) e os adaptadores (rodada 6). O custo da leitura de fatos por
operação, e o de `DatabaseFacts` em tabelas grandes, são da referência e da medição da K20, não uma promessa de produto. O aceite
do ADR-044 e o deste ADR são do mantenedor; se o do ADR-044 mudar a etapa 3, troca-se o provedor.

Com a emenda C16 ao ADR-044, `chat.read_room` deixa de recusar por predicado sem suporte: o dono com
vínculo e os demais membros podem ler a sala, e o não membro recusa com `data_authorization_denied`.
Ler/criar mensagem usa o mesmo vínculo por `room → members`. Escritas na junção entram na publicação
da geração em processo; add/remove_member invalidam os snapshots anteriores depois do commit.

Uma observação do modelo, fora do escopo: no blog, `crud scope: :author` entra em **todas** as políticas da entidade, inclusive na
do visitante (`status = 'published'` e `author_id = actor.id`), então o visitante não lê nenhum post. Quem decide é o modelo, não
o executor; fica registrada para a rodada 6.

## Garantia

- **Verificável por testes (sem banco):** `test/execution_runner_test.rb` cobre as três saídas de recusa, o zero SQL do pool da
  operação, a exceção de colaborador sem causa, a geração publicada no sucesso e na falha, as primitivas e o limite de linhas.
- **Transacional a confirmar:** `script/sonda_runner.rb` (27 verificações no PostgreSQL 17 e 18, e na CI) roda um comando de cada
  exemplo pelo `Runner` em dois pools de `vetra_app`, conta as duas transações, e exige o contrato de invalidação do ADR-044, §1:
  depois do commit que muda um vínculo o marcador avança e o snapshot antigo é recusado; a revogação durante a admissão recusa pela
  segunda conferência; e a autoridade fora do ar recusa sem transportar a exceção.
- **Operacional:** a autenticidade das credenciais e dos papéis, a atualidade da autoridade quando há outro processo ou escrita fora
  do `Runner`, e o tamanho de dados que o provedor de referência aguenta.

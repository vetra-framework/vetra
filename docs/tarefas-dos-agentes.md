# Tarefas dos agentes

Quadro das tarefas divididas entre o Codex e o Claude, conforme [AGENTS.md](../AGENTS.md). Cada linha diz quem
está com a tarefa, a situação e a auditoria. O mantenedor define prioridades e pode trocar responsáveis.

Situações: `a fazer`, `em andamento`, `em auditoria`, `devolvida`, `concluída`.

## Rodada 1 (2026-11-03)

| ID | Tarefa | Responsável | Situação | Commit | Auditoria e parecer |
|---|---|---|---|---|---|
| K1 | Registrar o fluxo entre agentes: `AGENTS.md`, `CLAUDE.md` e este quadro | Claude | concluída | ver histórico | Parecer do Codex pedido |
| K2 | Auditar as entregas do Codex de `cb7c0b5` a `61efbb8` | Claude | concluída | — | Resultado abaixo |
| K3 | Atualizar a linha de commits do resumo da situação e formalizar as linhas de cabeçalho permitidas em ADR aceito | Claude | concluída | ver histórico | Parecer do Codex pedido |
| C1 | Geração automática dos comandos de vínculo de `many_to_many` (parte do critério 7) | Codex | concluída | `58993e2` | Devolvida na rodada 1, aprovada na rodada 2; ADR-032 proposto; CI verde ([auditoria](#auditoria-c1)) |
| K4 | Protocolo novo: os dois implementam, auditoria cruzada, decisão e envio pelo Claude; lacunas do parecer | Claude | concluída | `e761f05` | Pedido do mantenedor; incorpora o parecer do Codex sobre `1aca944` |
| K5 | `db:authz:sql`: fechar os caminhos que contornam a revisão (papéis assumíveis por `SET ROLE`, `ADMIN OPTION`, `REFERENCES`, `session_replication_role`) | Claude | concluída | `fb41921` | Rodadas 1 a 3 devolvidas pelo Codex; rodada 4 aprovada com ajuste não bloqueante; CI verde, sonda 29/29 no PostgreSQL 17 e 18 ([auditoria](#auditoria-k5)) |
| C2 | `db:authz:sql`: recusar ou listar para revisão as rotinas `SECURITY DEFINER` existentes que a aplicação pode executar e que pertencem a papéis com poder de escrita, `TRUNCATE` ou `TRIGGER` nas tabelas protegidas (achado da auditoria da K5) | Codex | concluída | `4588b78` | Rodadas 1 e 2 devolvidas pelo Claude; rodada 3 aprovada; CI verde, sonda 59/59 no PostgreSQL 17 e 18 ([auditoria](#auditoria-c2)) |

### C1: escopo

- Gerar, a partir de `many_to_many`, os comandos de inclusão e remoção do vínculo previstos na proposta, com
  contrato tipado, autorização pela entidade dona da relação e descritor de primitiva, sem executor.
- Decidir num ADR `proposto` como a geração convive com comandos declarados explicitamente (o chat já declara
  `add_member` e `remove_member`), como se chamam, como se desligam e o que entra no diff.
- Testes de compilação, diagnóstico das recusas, exemplos reconstruídos, gate sem quebra não declarada e docs
  (`fase-0.md`, critérios e situação) coerentes.
- Entregar sem commit, com o relatório do protocolo.

## Rodada 2 (2026-11-03)

O mantenedor delegou ao Claude as decisões pendentes. Decidido: ADR-032 aceito, com a geração ligada por padrão;
ADRs 028 a 031 confirmados; nenhuma questão em aberto vira ADR de resolução agora; a consulta sem `returns` nem
`authorize` continua recusada. O Codex não alcança o PostgreSQL no sandbox, então as tarefas com sonda ficam com
o Claude e as de compilador podem ir para os dois.

| ID | Tarefa | Responsável | Situação | Commit | Auditoria e parecer |
|---|---|---|---|---|---|
| C3 | `rounding:` em `currency` (construto da proposta hoje recusado, critério 7): ADR proposto, DSL, IR em nova MENOR conforme o ADR-001 §4, validador, diff e docs | Codex | concluída | `1a8ee02`, `3221157` | Rodada 1 devolvida pelo Claude; rodada 2 aprovada; ADR-033 aceito por delegação; CI verde ([auditoria](#auditoria-c3)) |
| K6 | `sonda_adr015`: os quatro casos do ADR-025 (índice e chave em tabela particionada, chave composta por tenant, `CHECK` de `enum`), na CI do PostgreSQL 17 e 18 | Claude | concluída | `77685b0` | Rodada 1 devolvida pelo Codex; rodada 2 aprovada; CI verde, sonda 31/31 no PostgreSQL 17 e 18 ([auditoria](#auditoria-k6)) |
| C4 | `rate_limit:` em `can` (construto da proposta hoje recusado, critério 7), depois da C3 e no mesmo formato | Codex | concluída | `bcc7651` | Rodada 1 devolvida pelo Claude; rodada 2 aprovada; ADR-034 aceito por delegação; CI verde ([auditoria](#auditoria-c4)) |

Rodada concluída. A gem alpha.5 pode ser publicada pelo mantenedor, e o passo seguinte é começar a persistência.

## Rodada 3 (2026-11-03)

Persistência: do grafo a um banco criado por plano versionado, com papéis e RLS, aplicado por `db:migrate`. O
objetivo, a lacuna de decisão, os riscos e as regras estão no [plano da persistência](plano-persistencia.md), que
incorpora o parecer do Codex.

| ID | Tarefa | Responsável | Situação | Commit | Auditoria e parecer |
|---|---|---|---|---|---|
| C5 | Mapeamento físico: ADR-035 proposto e função pura da IR para o modelo de esquema e o DDL de um banco vazio | Codex | concluída | `a9b2bfc` | Aprovada na rodada 1; ADR-035 aceito por delegação; CI verde ([auditoria](#auditoria-c5)) |
| K7 | `db:plan`: formato do plano, executor comum em banco descartável, retrato `db/schema.sql` e `--check` na CI | Claude | concluída | `c6c68e6`, `9f48cd7` | Rodadas 1 a 4 devolvidas pelo Codex; rodada 5 aprovada; CI verde, `--check` no PostgreSQL 17 e 18 ([auditoria](#auditoria-k7)) |
| C6 | Papéis, `vetra_private`, contexto assinado e provisionamento mínimo das chaves | Codex | concluída | `0feaedd`, `4bd4a39` | Rodada 1 devolvida pelo Claude; rodada 2 aprovada; ADR-036 aceito por delegação; CI verde, sonda 58/58 no PostgreSQL 17 e 18 ([auditoria](#auditoria-c6)) |
| C7 | RLS de tenant e de escopo, revisão de autorização como passos do plano e triggers de `transitions enforce: db` | Codex | concluída | `afb3009`, `92aa04f` | Rodada 1 devolvida pelo Claude; rodada 2 aprovada; ADR-037 aceito por delegação; CI verde, sonda 103/103 no PostgreSQL 17 e 18 ([auditoria](#auditoria-c7)) |
| K8 | `db:migrate`: `vetra.migrations`, lock consultivo, `lock_timeout` com novas tentativas, verificação prévia e retomada | Claude | concluída | `da3dda9`, `5b15437` | Rodadas 1 a 3 devolvidas pelo Codex; rodada 4 aprovada; CI verde, sonda 21/21 no PostgreSQL 17 e 18 ([auditoria](#auditoria-k8)) |

Rodada concluída. Todos os exemplos vão do banco vazio ao plano inicial aplicado por `db:migrate`.

## Rodada 5 (2026-11-09)

Persistência, parte 3: um executor **parcial** do ADR-016 (sem histórico, auditoria nem adaptadores, que são da rodada
6), em duas fases. A fase A traz as decisões que a medição da K13 pediu, o ator de sistema, a idempotência e a
autorização em Ruby; a fase B, o executor e os handlers de sistema, é replanejada ao fim da fase A. O objetivo, as
decisões a tomar, os riscos e o que fica para a rodada 6 estão no [plano da persistência](plano-persistencia.md#rodada-5-decisões-da-k13-ator-de-sistema-idempotência-autorização-e-executor-parcial).
O planejamento foi decidido pelo Claude, por delegação do mantenedor, e incorpora o parecer do Codex (abaixo), aprovado na terceira rodada. As
tarefas seguem a ordem da tabela.

| ID | Tarefa | Responsável | Situação | Commit | Auditoria e parecer |
|---|---|---|---|---|---|
| K14 | Forma da política de escopo: ADR-041 (aceito por delegação), escrita medida por ação, permissões comparadas e as formas avaliadas | Claude | concluída | `4456826` | Rodada 1 devolvida pelo Codex; rodada 2 aprovada; CI verde; sonda 4/4 no PostgreSQL 17 e 18 ([auditoria](#auditoria-k14)) |
| C11 | Construção dos registros: ADR-042 proposto, caminho de leitura sem a validação que o banco já garante e o gate do ADR-022, §3 refeito | Codex | concluída | `c204ae1` | Auditada pelo Claude; CI verde; ADR-042 proposto, gate de 10% aberto ([auditoria](#auditoria-c11)) |
| C12 | `graph:build` recusa campo cujo nome colide com método do registro `Data` | Codex | concluída | `35d4a99` | Rodada 1 devolvida pelo Claude; rodada 2 aprovada; CI verde ([auditoria](#auditoria-c12)) |
| K15 | Ator de sistema (ADR-024, §4) só em aplicações com tenant: claim, `vetra.is_system_actor()`, condição nas políticas, tradução incremental das rotinas de contexto e das guardas | Claude | concluída | `e84dc76` | Rodada 1 aprovada pelo Codex; CI verde; sondas 78 (contexto) e 112 (RLS) no PostgreSQL 17 e 18; custo da `vt_system` pendente de decisão do mantenedor ([auditoria](#auditoria-k15)) |
| K16 | Idempotência da operação: ADR-043 proposto, `vetra.idempotency` nos quatro exemplos (contexto global incluído), retenção por origem e a purga | Claude | concluída | `146128a` | Rodadas 1 e 2 devolvidas pelo Codex; rodada 3 aprovada; CI verde; sonda 83 no PostgreSQL 17 e 18 ([auditoria](#auditoria-k16)) |
| C13 | Entrada e autorização em Ruby (etapas 2 e 3): ADR-044 proposto e a recusa de operação que depende só de concessão com `rate_limit:` | Codex | concluída | `8a224a1` | Auditada pelo Claude; CI verde; ADR-044 proposto, aceite do mantenedor pendente ([auditoria](#auditoria-c13)) |
| P5 | Replanejamento da fase B (marco): plano revisado, parecer do Codex e decisão, antes da K17 | Claude | concluída | — | Plano em [plano-persistencia.md](plano-persistencia.md#replanejamento-da-fase-b-p5); primeira rodada devolvida pelo Codex, segunda aprovada ([parecer](#parecer-do-codex-sobre-o-replanejamento-da-fase-b-p5)); a C15 é a próxima |
| C15 | Limites da unidade (fase B): `statement_timeout`, `lock_timeout` e isolamento por operação, e os limites de sessão que protegem o `xmin` | Codex | concluída | `a5b339d` | Auditada pelo Claude, sonda 17/18 e CI verde; a K17 é a próxima ([auditoria](#auditoria-c15)) |
| K17 | Executor I (fase B): borda interna com ADR-045, `Runner`, capacidades e primitivas CRUD e de vínculo | Claude | concluída | `074c75c` | Auditada pelo Codex em três rodadas (quatro bloqueantes e uma corrida corrigidos); ADR-045 proposto, aceite do mantenedor pendente ([auditoria](#auditoria-k17)) |
| C16 | `many_to_many` no avaliador de autorização (fase B), para o `members` do chat | Codex | concluída | `8fb069f` | Auditada pelo Claude, sonda 17/18 e CI verde; emenda ao ADR-044 (proposto); a K18 é a próxima ([auditoria](#auditoria-c16)) |
| K18 | Executor II (fase B): autorização nos acessos dos repositórios, coletor de fatos na unidade, reautorização do estado final e ramo de sistema | Claude | integrada, CI pendente | — | Auditada pelo Codex em quatro rodadas (sete bloqueantes corrigidos); ADR-046 proposto, aceite do mantenedor pendente ([auditoria](#auditoria-k18)) |
| K19 | Executor III (fase B): eventos do `emits`, idempotência, saídas 422/409/500 e a repetição com `retry_safe` e `unsafe_effect` | Claude | a fazer | — | — |
| C14 | Handlers de sistema (fase B): runner sobre o `Relay`, timeout total do handler, chave derivada do evento, Effect Boundary e fixture com `calls` | Codex | a fazer | — | — |
| K20 | Ponta a ponta e a medição do ADR-023 com o executor; o teste 6 continua pendente | Claude | a fazer | — | — |

### Parecer do Codex sobre o plano da rodada 5

Pedido em modo somente leitura, sobre `233421c`. O Codex devolveu a primeira versão do plano, com oito achados
bloqueantes e três não bloqueantes; a decisão de cada um é do Claude.

| Achado do Codex | Bloqueia | Decisão do Claude |
|---|---|---|
| O objetivo prometia cumprir as oito etapas do ADR-016, mas histórico e auditoria não existirão | sim | Ajustar: o plano descreve um executor **parcial**, lista o que não cumpre e reserva a conformidade integral para a rodada 6 |
| A C12 lia as concessões numa unidade somente leitura, que abre transação, contra a promessa do ADR-016 de nenhuma transação para o ator sem permissão | sim | Ajustar: a decisão vira o ADR-044, na C13, com as duas saídas (concessões resolvidas por uma borda confiável ou uma transação curta que termina antes da recusa) |
| Nenhuma entrega protegia os acessos dos repositórios, que não aplicam papéis nem campos visíveis; o `chat.add_member_by_email` lê `users_read` sem concessão de leitura de `chat.user` | sim | Ajustar: a K18 aplica a autorização aos acessos e reautoriza o estado final; o ADR-044 decide o que um `uses` de leitura concede e a origem dos papéis; sondas no blog e no chat, sem RLS |
| A K15 pressupunha uma infraestrutura que a C9 não entrega (o `Differ` recusa função nova de contexto, a exceção do ADR-036 reconhece só as atuais, o contexto Ruby exige `actor_id`) | sim | Ajustar: a K15 inclui a tradução incremental das rotinas, a atualização estrita das guardas, `Context` e `UnitOfWork`, e limita o ator de sistema a aplicações com tenant, para que blog e chat não mudem |
| A K16 não fechava o contexto global (tenant nulo) nem a purga num aplicativo sem outbox | sim | Ajustar: o ADR-043 escolhe a representação do tenant nulo sem sentinela, a retenção por origem e quem purga; K16 antes de K17 se mantém |
| A C14 não ligava a entrega à chave do comando nem ao provedor, e os handlers dos exemplos têm `calls: []` | sim | Ajustar: chave derivada do `event_id`, Effect Boundary na C14, fixture com um handler que chama um comando e testes de queda depois do commit |
| A regra de repetição ignorava `unsafe_effect` | sim | Ajustar: a K19 exige as duas condições e a sonda cobre a recusa |
| Adiar `rate_limit:` exigia uma recusa explícita, porque o blog já limita os comentários | sim | Ajustar: a C13 recusa a operação que dependa só de concessões com limite, e a concessão sem limite continua permitindo |
| A K17 concentrava entregas demais e não explicitava a borda anterior aos adaptadores nem os timeouts | não | Ajustar: o executor vira K17 a K19, com a borda interna e os timeouts na K17 |
| As medições tinham a direção certa, mas `DELETE` usa `USING`, e faltavam permissões por ação, a tabela materializada, a hidratação de `Money`, JSON e datas, o pooler e a contagem das validações de contexto | não | Ajustar: o texto da K14, da C11 e da K20 muda; o teste 6 do ADR-023 continua pendente e os limiares não mudam |
| O item 2 da seção 7 misturava as lacunas do critério 7 com outras pendências e invertia uma dependência (`subject` e `retention` podem ser declarados antes da cifra; o ADR-018 já está aceito; `returns`/`authorize` já foi decidido como recusado) | não | Ajustar a seção 7, separando as lacunas medidas das demais e indicando a dependência de cada uma |

**Segunda rodada do parecer.** O Codex confirmou os onze ajustes e devolveu o plano por três lacunas bloqueantes e
duas não bloqueantes; a decisão de cada uma é do Claude.

| Achado do Codex | Bloqueia | Decisão do Claude |
|---|---|---|
| A C14 testava o reprocessamento de uma entrega `dead`, que o ADR-014 exige como comando explícito e auditado, e a auditoria está adiada | sim | Ajustar: o reprocessamento é da rodada 6; a C14 mantém a retenção das chaves e uma fixture controlada, sem oferecê-lo |
| A C14 não alocava o timeout total do handler (30 s, com lease de 60 s, ADR-024, §1), que o `Relay#work` não impõe | sim | Ajustar: o timeout total entra na C14, com testes de expiração, falha e recuperação por outro worker |
| A K17 não cobria `transaction_timeout` nem `idle_in_transaction_session_timeout`, que o ADR-008, §5 exige para não prender o `xmin` de todos os tenants | sim | Ajustar: a K17 os provisiona e os verifica, com uma sonda de encerramento e de `xmin` liberado |
| O plano conservava, no texto da rodada 4, promessas antigas (histórico, oito etapas, adaptadores, contract, cifra e live) que apontavam para a rodada 5 | não | Ajustar: marcadas como planejamento anterior, substituído, com o destino de cada item |
| O replanejamento da fase B não aparecia como entrega própria, e a aprovação atual não pode valer antecipadamente para ele | não | Ajustar: o marco P5 (plano revisado, parecer do Codex, decisão, integração) precede a K17 |

**Terceira rodada do parecer — aprovada pelo Codex.** Os três achados bloqueantes e o marco P5 foram confirmados
como fechados, sem promessa descoberta nem contradição com um ADR aceito. Restou um achado não bloqueante:

| Achado do Codex | Bloqueia | Decisão do Claude |
|---|---|---|
| O texto ainda falava em "gate por comando" do ADR-023 onde a K20 entrega a **medição** por comando e mantém o teste 6 pendente | não | Ajustar: "medição por comando", com a ressalva de que o gate do teste 6 continua pendente |

## Rodada 4 (2026-11-05)

Persistência, parte 2: o banco da rodada 3 evolui por plano incremental, e o Vetra Data grava nele pelos
repositórios, com contexto emitido em Ruby e eventos na outbox. O objetivo, as decisões a tomar, os riscos e o que
fica para a rodada 5 estão no [plano da persistência](plano-persistencia.md#rodada-4-plano-incremental-repositórios-e-outbox).
O planejamento foi decidido pelo Claude, por delegação do mantenedor, e incorpora o parecer do Codex (abaixo). As
tarefas seguem a ordem da tabela.

| ID | Tarefa | Responsável | Situação | Commit | Auditoria e parecer |
|---|---|---|---|---|---|
| K9 | Fundação do plano incremental: ADR-038, modelo físico versionado e cadeia, modo de transação por passo, história ancorada no gate, filtro de instruções globais, aplicação como `vetra_migrator` com guarda de papéis e catálogo conferido, `--check` com N planos e convergência | Claude | concluída | `5fa7a3a` | Rodadas 1 a 5 devolvidas pelo Codex; rodada 6 aprovada; ADR-038 aceito por delegação; CI verde, sonda 18/18 no PostgreSQL 17 e 18 ([auditoria](#auditoria-k9)) |
| C8 | Unidade de trabalho sobre o Sequel, `sequel` e `pg` como dependências de runtime, emissão do contexto assinado em Ruby e contexto global: ADR-039 | Codex | concluída | `a98c4de`, `75dd5e2` | Aprovada pelo Claude na rodada 1; ADR-039 aceito por delegação; CI verde depois da correção dos lockfiles, sonda 23/23 no PostgreSQL 17 e 18 ([auditoria](#auditoria-c8)) |
| C9 | Diferenças aditivas do modelo para a IR em passos expand classificados, com recusa audível do resto | Codex | concluída | `e2bdd14` | Rodada 1 devolvida pelo Claude; rodada 2 aprovada; CI verde, sonda 99/99 no PostgreSQL 17 e 18 ([auditoria](#auditoria-c9)) |
| K10 | `db:migrate` incremental: progresso por passo, passos fora de transação, índices válidos e inválidos não registrados, base e estado intermediário conferidos, retomada | Claude | concluída | `2db989c` | Rodadas 1 e 2 devolvidas pelo Codex; rodada 3 aprovada; CI verde, sonda 16/16 no PostgreSQL 17 e 18 ([auditoria](#auditoria-k10)) |
| C10 | Repositórios gerados da IR, com registros `Data` congelados, métodos de vínculo e consulta restrita; corpos dos quatro exemplos contra o banco | Codex | concluída | `5c15ebf` | Rodada 1 devolvida pelo Claude; rodada 2 aprovada; CI verde, sonda 72/72 no PostgreSQL 17 e 18 ([auditoria](#auditoria-c10)) |
| K11 | Outbox, armazenamento e emissão: ADR-040 proposto (papéis e RLS), tabelas particionadas no `0002` dos exemplos com eventos, gravação na unidade de trabalho | Claude | concluída | `0fff3ee` | Rodada 1 devolvida pelo Codex; rodada 2 aprovada; CI verde, sonda 36/36 no PostgreSQL 17 e 18 ([auditoria](#auditoria-k11)) |
| K12 | Relay, entregas e manutenção com consumidores simulados: lease, tentativas, entrega morta, partições e purga reconhecidas pela deriva | Claude | concluída | `3c9d6ff` | Rodadas 1 a 3 devolvidas pelo Codex; rodada 4 aprovada; CI verde, sonda 38/38 no PostgreSQL 17 e 18 ([auditoria](#auditoria-k12)) |
| K13 | Custo do contexto assinado por instrução, medição preliminar na matriz do ADR-023, e construção dos `Data` (ADR-022, §3) | Claude | concluída | `3a9c3b2` | Rodadas 1 e 2 devolvidas pelo Codex; rodada 3 aprovada; CI verde; medição informativa no PostgreSQL 17 e 18 ([auditoria](#auditoria-k13)) |

### Parecer do Codex sobre o plano

Pedido sobre `088e317`, em modo somente leitura. O Codex devolveu a primeira versão do plano; a decisão de cada
achado é do Claude.

| Achado do Codex | Bloqueia | Decisão do Claude |
|---|---|---|
| A classificação por prefixo não substitui a proteção atual do `--check`, que só aplica um plano igual ao regenerado: um passo com `CREATE TABLE` e `COMMENT ON DATABASE` passa | sim | Ajustar: a K9 entrega validação integral das formas, modelos exatos de rotinas, execução sem privilégio administrativo e a exceção estrita dos privilégios do banco corrente |
| Introspectar o banco no planejamento contraria o ADR-025, §1, que reserva a introspecção à verificação | sim | Ajustar: modelo físico versionado e vinculado ao plano, conferido pelo replay e pelo retrato no `--check`; o ADR-038 declara essa leitura do §1 |
| A K9 prometia `CONCURRENTLY` e N planos, mas o executor descartável envolve o plano inteiro numa transação | sim | Ajustar: a K9 vira a fundação (modelo, formato, validação e executor) e as diferenças aditivas vão para a C9; a K10 cobre a queda depois do DDL fora de transação, inclusive com o índice válido não registrado. A C8 deixa de depender da K9 |
| As partições criadas pela manutenção apareceriam como deriva no `db:migrate` | sim | Ajustar: o ADR-040 decide como a deriva as reconhece; a K12 tem sonda que aceita a manutenção e recusa uma partição adulterada |
| A K11 prometia entregar a handlers, mas o executor e o ator de sistema ficam para a rodada 5 | sim | Ajustar: a outbox foi dividida em K11 (armazenamento e emissão) e K12 (relay com consumidores simulados); handlers reais vão para a rodada 5. O ADR-040 cobre quem grava, o relay e a manutenção, sem `vetra_migrator` no runtime |
| Blog e chat são globais, e o ADR-036 exige tenant e ator; faltavam formas usadas pelos corpos, como os métodos de vínculo | sim | Ajustar: o ADR-039 define o contexto global sem inventar tenant; a C10 lista `update!` por registro e por ID, `first(n)`/`last(n)`, `add_member!`/`remove_member!`, atribuições de contexto, normalização e geração |
| A K12 não especificava a matriz do gate do ADR-023 e não podia medir o percentual por comando sem executor | sim | Ajustar: K13 como medição preliminar por instrução na matriz do ADR-023, com o gate dos `Data`; o percentual por comando vai para a rodada 5, e uma fusão de funções exige ADR |
| O `pg` continua como dependência de desenvolvimento | não | Ajustar: a C8 promove `sequel` e `pg` |
| A situação ainda dava a aplicação de migrações como pendente | não | Ajustar: distingue o plano inicial aplicado do incremental pendente |

Na segunda rodada, o Codex aprovou o plano e confirmou os nove achados como resolvidos. Restaram dois achados não
bloqueantes:

| Achado do Codex | Bloqueia | Decisão do Claude |
|---|---|---|
| O plano chama de "leitura" do ADR-025, §1 o que é comparar com outro artefato | não | Ajustar: o ADR-038 diz expressamente como complementa o §1, inclusive segurança e infraestrutura, e o replay prova a equivalência entre modelo, planos e retrato |
| Faltava a recuperação de uma partição `DEFAULT` populada antes da primeira manutenção | não | Ajustar: a K12 prepara as partições antes de liberar quem grava, com uma sonda de recuperação sem perda nem duplicação |

## Parecer do Codex sobre o replanejamento da fase B (P5)

**Primeira rodada — devolvida pelo Codex** (base `f64da31`, somente leitura). Confirmou as afirmações centrais (cinco testes e dois guias
citam `executor: "pending"`; `graph:diff` já trata `calls` como permissão; os dois handlers têm `calls: []` e tenant; o visitante do blog
depende de `rate_limit:`; a unidade fixa o isolamento e não recebe limites), a ordem sem ciclo e o tamanho da K18 com a divisão prevista.
Sete achados, três bloqueantes; a decisão de cada um é do Claude.

| Achado do Codex | Bloqueia | Decisão do Claude |
|---|---|---|
| `Repository#execute` converte `55P03` e `57014` no mesmo `data_database`; só a idempotência traduz `55P03` para `Conflict(:lock_timeout)`, e nenhuma entrega corrigia os acessos comuns | sim | Ajustar: a C15 traduz os dois estouros nos repositórios para erros próprios e retentáveis, com testes e sonda; a K19 os mapeia para 409 e para a resposta retentável |
| A autoridade de revisão de referência estava subespecificada: faltavam a leitura consistente, a geração para mudanças externas de identidade e a prova de invalidação, revogação e perda de continuidade | sim | Ajustar: a K17 fixa o marcador composto nos CRMs, a geração em processo publicada pelo `Runner` em blog e chat, o limite de um processo dito no ADR-045, e a sonda exige invalidação, revogação e autoridade fora do ar |
| A chave derivada só do `event_id` colide entre dois handlers do mesmo evento que chamam o mesmo comando, porque a unicidade é `(tenant, comando, chave)` e o principal não a separa | sim | Ajustar: a chave deriva do handler e do `event_id`, e a fixture da C14 tem dois handlers no mesmo evento |
| "Só o provedor muda" prometia demais: a alternativa 1 do ADR-044 também revê a etapa 3 e o teste 1 | não | Ajustar: o texto passa a dizer que a injeção reduz o retrabalho, sem eliminá-lo |
| A lista de testes integrais pendentes omitia o teste 2, que também pede histórico | não | Ajustar: o teste 2 entra, com a parte de dados, evento e idempotência verificada na rodada |
| A K20 não tinha a medição do custo da escrita em `vetra.idempotency`, que o ADR-043 lhe atribui | não | Ajustar: a medição com e sem chave entra na K20 |
| "Quase toda a autorização" do chat não se sustenta: `members` está em três das seis políticas | não | Ajustar: o texto diz três das seis políticas |

**Segunda rodada — aprovada pelo Codex.** Os sete ajustes fecham os achados, sem afirmação falsa nem contradição nova. O plano foi integrado;
a C15 é a próxima tarefa, e o aceite do ADR-044, a saída da `vt_system` e o aceite do ADR-042 seguem com o mantenedor, sem bloquear tarefa.

## Auditoria C15

Implementado pelo Codex sobre `cdcf4f2`; auditado pelo Claude (leitura de todo o código, dos testes, da sonda e dos guias; suíte, gate,
`db:plan` e as sondas no PostgreSQL 17.11 e 18.6, que o sandbox do Codex não executa).

| Achado do Claude | Bloqueia | Decisão |
|---|---|---|
| `DatabaseErrors.sqlstate` chamava `error_field('C')`; o `pg` só aceita o inteiro `PG::PG_DIAG_SQLSTATE` e lança `TypeError` num `PG::Result` real. O mock do teste exigia o literal `'C'`, e por isso os 13 testes e a suíte passavam enquanto 3 verificações da sonda `limites_unidade` e dezenas das sondas `repositorios`, `outbox`, `relay`, `idempotencia`, `vetra_data` e `autorizacao_ruby` falhavam | sim | Ajustar (pelo Claude, por exigir o banco): `sqlstate` usa `PG::PG_DIAG_SQLSTATE`, como o resto da base, e o mock agora recusa qualquer outro campo; todas as sondas passam nos dois servidores |
| O verificador vem ligado por padrão; sem os dois `ALTER ROLE` no bootstrap toda sonda antiga e a CI recusam abrir a unidade (`data_limits`) | sim | Ajustar (pelo Claude; o Codex não edita `.github/`): passo de bootstrap na CI com `transaction_timeout = '30s'` e `idle_in_transaction_session_timeout = '10s'` antes das sondas, e o passo da `sonda_limites_unidade.rb` |

Custo real do verificador, medido contra o banco (uma leitura de `current_setting` por transação externa, 300 operações): mediana 0,71 ms/op
com e 0,54 sem no 17 (diferença 0,18 ms), 0,68 com e 0,58 sem no 18 (0,11 ms), contra os 57 µs do mock. É um `SELECT` por transação externa, não
por acesso; a K20 mede o total no fluxo completo e a decisão de manter o verificador ligado por padrão vai com ela.

**Verificações.** Suíte 702 testes, 16.498 asserções, 0 falhas, 244/244 diagnósticos; gate sem diferenças; `db:plan` sem mudanças nos quatro
exemplos; sonda `limites_unidade` 15/15 e as seis sondas afetadas 100% no 17 e no 18.

**CI.** A [execução 42893712044](https://github.com/vetra-framework/vetra/actions/runs/42893712044) do commit `a5b339d` passou nos cinco jobs, com a sonda de limites e o bootstrap dos dois
parâmetros do `vetra_app`.

## Auditoria C13

Implementado pelo Codex sobre `b866baa`; auditado pelo Claude (leitura do ADR-044 e do núcleo do avaliador, suíte, gate, `db:plan` e a
sonda, que o sandbox do Codex não executa). O ADR-044 **continua proposto**: o aceite é do mantenedor (veja abaixo).

| Achado do Claude | Bloqueia | Decisão |
|---|---|---|
| A sonda contava "zero transações" pelo `pg_stat_database`; no PostgreSQL real as duas verificações falharam (66/68), porque as estatísticas são publicadas com atraso e não resolvem uma transação isolada | sim | Ajustar (pelo Claude, por exigir o banco): a contagem passa a ser a do pool do runtime, pelo logger do Sequel (zero SQL nas recusas; o controle positivo vê `BEGIN` e `COMMIT`); ADR-044 e guia alinhados; 68/68 no 17 e no 18 |

Não achei defeito no código do avaliador: lógica de três valores inclusive sob `NOT` e `IN`, filtro de tenant em cada salto do `exists`, validação da árvore
inteira antes de avaliar, visitante sem ator nunca casando `campo = actor.id`, recusa fechada de predicado sem suporte, de `rate_limit:` e de ator
de sistema. A matriz CRUD (4 atores × 4 ações × 3 revendas) e o segundo tenant concordaram com o RLS nos dois servidores.

**Verificações.** Suíte 689 testes, 0 falhas, 238/238 diagnósticos; gate sem diferenças; `db:plan` sem mudanças; sonda de autorização Ruby 68/68 no 17 e no 18.

**CI.** A [execução 42859941056](https://github.com/vetra-framework/vetra/actions/runs/42859941056) do commit `8a224a1` passou nos cinco jobs, com a sonda
de autorização Ruby em 68/68 no 17 e no 18 e o `db:plan --check` dos quatro exemplos.

**Por que o aceite fica com o mantenedor.** O ADR-044 faz duas coisas que mudam o alcance de uma promessa aceita. (1) Redefine o que o teste de aceitação 1 do
ADR-016 mede: a operação recusada abre zero transações **da operação**, mas quem resolve os fatos no banco por chamada paga essa transação antes da admissão.
(2) Transfere à borda uma obrigação ainda sem dono: confirmar a revisão de autorização de forma autoritativa, que só passa a existir na K17. A alternativa
descartada, uma transação curta somente leitura, cumpriria o ADR-016 ao pé da letra e seria mais simples. O marco P5 deve levar isso em conta.

## Auditoria K16

Implementado pelo Claude sobre `bc15835`; auditado pelo Codex em modo somente leitura, com a árvore conferida por hash antes e depois de cada
rodada. O Claude rodou a suíte, o gate, `db:plan --check` e as sondas no PostgreSQL 18.6 e num 17.11 local, que o sandbox do Codex não alcança.
O ADR-043 foi aceito pelo Claude por delegação do mantenedor depois da rodada 3.

**Rodada 1 — devolvida pelo Codex.**

| Achado do Codex | Bloqueia | Decisão do Claude |
|---|---|---|
| `complete!` não traduzia os erros do banco (a mensagem do driver saía crua e o mapeamento de conflitos se perdia) | sim | Ajustar: tradução com `cause: nil`, testada pela API pública |
| Ruby media o resultado em JSON compacto e o `CHECK` em `jsonb::text`: 65.536 bytes passavam em Ruby e violavam o `CHECK` | sim | Ajustar: o banco decide o teto; o 23514 vira `data_idempotency_result`; fronteira testada no PostgreSQL |
| `complete!` aceitava qualquer linha visível com o `id`: replay, claim de outra transação e outro principal | sim | Ajustar: claim ligado à transação, `UPDATE` com `result IS NULL` e o principal |
| A purga podia não terminar sob carga contínua (o prazo era recalculado por lote) | não | Ajustar: corte fixado por execução |
| A sonda consultava uma chave diferente da operação recusada | não | Ajustar |
| O teste de `id` esperava 428C9 e não discriminava a concessão por coluna | não | Ajustar: tentativa com `OVERRIDING SYSTEM VALUE`, que exige 42501 |

**Rodada 2 — devolvida pelo Codex.** Fechou o achado 1 e deixou lacunas nos demais.

| Achado do Codex | Bloqueia | Decisão do Claude |
|---|---|---|
| O filtro de tamanho em Ruby recusava o que caberia: o JSON compacto pode ser maior que o `jsonb::text` (chaves repetidas e números reescritos) | sim | Ajustar: filtro removido, só um limite adicional de 1 MiB ao payload serializado; premissa do ADR corrigida; sonda com chaves repetidas e números que encolhem |
| O campo público `context` não autenticava o claim: um `Claim` construído à mão foi aceito, e a sonda testava uma linha já concluída | sim | Ajustar: registro dos claims emitidos por identidade do objeto (`ObjectSpace::WeakMap`); teste e sonda contra linha ainda sem resultado |
| O corte da purga usava o relógio do processo, que pode antecipar a expiração | sim | Ajustar: corte lido uma vez no relógio do PostgreSQL |
| O parâmetro do corte perdia o fuso (`$2::timestamp`) | sim | Ajustar: texto com fuso e `CAST(? AS timestamptz)`; sonda com a sessão em `America/Sao_Paulo` |

**Rodada 3 — aprovada pelo Codex.** Os quatro bloqueantes foram confirmados como fechados, com o `WeakMap` verificado sob oito threads, GC e
compactação. Três observações não bloqueantes foram ajustadas pelo Claude:

| Observação do Codex | Decisão do Claude |
|---|---|
| O limite de 1 MiB estava descrito como "absurdo em qualquer representação", mas recusa também um JSON que normalizaria para menos | Ajustar: descrito como limite adicional do payload serializado (código, teste e ADR) |
| O ADR dizia lotes "por `id`", e o SQL ordena por `created_at` | Ajustar: ADR alinhado, e `id` entra como desempate |
| `--batch` e `--retention-hours` eram recusados depois dos retornos de `db:plan` e `outbox:maintain`, que os ignoravam | Ajustar: a exclusividade é validada antes dos retornos, com teste para `db:plan`, `outbox:maintain` e `db:migrate` |

**CI.** A [execução 42849596612](https://github.com/vetra-framework/vetra/actions/runs/42849596612) do commit `146128a` passou nos cinco jobs, com a sonda da
idempotência em 83/83 no 17 e no 18 e o `db:plan --check` dos quatro exemplos.

**Correção colateral.** A sonda expôs que `error_field('C')` levanta `TypeError` neste `pg`; o mapeamento de deadlock, serialização, lock e acesso
negado do repositório e do catálogo estava quebrado em silêncio. Os três usos passaram a `PG::PG_DIAG_SQLSTATE`.

**Verificações do Claude.** Suíte 662 testes, 0 falhas, 229/229 diagnósticos; `db:plan --check` nos quatro exemplos no 17 e no 18; gate sem
diferenças; sondas no 17 e no 18: idempotência 83, contexto assinado 78, RLS e integridade 112, plano incremental 18, Vetra Data 23, plano
aditivo 99, `db:migrate` 21, `db:migrate` incremental 16, repositórios 72, outbox 36 e relay 38. O Differ cria a seção inteira num passo;
cada exemplo ganhou um plano novo (blog `0004`, chat `0002`, mini CRM `0005` e CRM com revendas `0006`).

## Auditoria K15

Implementado pelo Claude sobre `e963008`; auditado pelo Codex em modo somente leitura, com a árvore conferida por hash antes e depois da
rodada. O Claude rodou a suíte, o gate, `db:plan --check` e as sondas no PostgreSQL 18.6 e num 17.11 local, que o sandbox do Codex não
alcança (nele a suíte completa só falha por impossibilidade de criar temporários).

**Rodada 1 — aprovada pelo Codex, sem achado bloqueante.**

| Achado do Codex | Bloqueia | Decisão do Claude |
|---|---|---|
| O teste de "cópia exata do corpo em outro schema" da sonda de contexto usava `body('tenant_id')`, o corpo legado, e não o corpo da aplicação com tenant que a guarda confia | não | Ajustar: as duas verificações usam `system_actor: true` |
| O `db-plan.md` ainda dizia "apenas as duas definições" na guarda de autorização, contra o parágrafo novo e a guarda nova | não | Ajustar: duas definições, e três na aplicação com tenant |

O Codex confirmou o MAC antes das claims, a exclusividade das identidades (os dois claims ou nenhum retornam NULL e falso), o retorno
falso de `is_system_actor()` em todos os caminhos de falha, a regex ancorada contra quebra de linha final, a preservação das guardas e da
restritiva de tenant, e que os corpos e hashes das aplicações globais ficam idênticos aos da base.

**Verificações do Claude.** Suíte 636 testes, 0 falhas, 224/224 diagnósticos; `db:plan --check` nos quatro exemplos no 17 e no 18; gate
sem diferenças; sondas no 17 e no 18: contexto assinado 78, RLS e integridade 112, plano incremental 18, Vetra Data 23, plano aditivo 99,
`db:migrate` 21, `db:migrate` incremental 16, repositórios 72, outbox 36, relay 38 e escopo 4/4. Os testes de outbox, relay, plano inicial
e plano aditivo, e as sondas de `db:migrate` e relay, passaram a esperar os planos novos dos CRMs.

**CI.** A [execução 42831231168](https://github.com/vetra-framework/vetra/actions/runs/42831231168) do commit `e84dc76` passou nos cinco jobs,
com as sondas de contexto (78) e de RLS (112) no 17 e no 18.

**Decisão pendente do mantenedor.** A medição de custo ([relatório](sondas/ator-de-sistema.md)) mostra que a permissiva `vt_system` encarece o
ator comum (de +0,03 a +0,45 ms na leitura por chave e de +0,83 a +1,84 ms nas varreduras). A K15 implementa o que o ADR-024, §4 decidiu;
as saídas são uma função única de contexto (prevista no ADR-024) ou um papel de banco próprio para o ator de sistema, que muda a decisão 2
e pede um ADR novo. Nada disso foi implementado, e o gatilho é a medição por comando da K20.

## Auditoria C12

Implementado pelo Codex sobre `e221477`; auditado pelo Claude (leitura do diff completo, medição dos nomes reservados, suíte, gate e
`db:plan`). A tarefa não toca o banco, então não há sonda.

**Rodada 1 — devolvida pelo Claude.**

| Achado do Claude | Bloqueia | Decisão |
|---|---|---|
| `reserved_method?` reservava todos os métodos privados do registro, inclusive 55 funções privadas do `Kernel` (`format`, `open`, `select`, `test`, `system`, `load`, `print`, `exec`, `warn`...). Um campo `format` ou `open` funciona num `Data` (construção, leitura e `with` conferidos), então a regra proibia nomes plausíveis sem motivo | sim | Ajustar: reservar os métodos públicos e protegidos, os privados que não são do `Kernel` e só os ganchos que o Ruby chama sozinho (`initialize*`, `method_missing`, `respond_to_missing?`, `singleton_method_*`, `instance_variables_to_inspect`); testes de aceitação de `format`, `open`, `select`, `test`, `system` e `load` e de recusa dos ganchos; docs ajustadas |

**CI.** A [execução 42817593744](https://github.com/vetra-framework/vetra/actions/runs/42817593744) do commit `35d4a99` passou nos cinco jobs.

**Rodada 2 — aprovada pelo Claude.** O ajuste fecha o achado: a lista final de privados reservados é a dos ganchos mais `enum_group?`
(e `DelegateClass` e `Digest`, de dono `Object`, fora da sintaxe do DSL). O diagnóstico `field_name_collides_with_record` recusa campos e
predicados de grupo de `enum` no `graph:build` e no `graph:check`, com ponteiro e sugestão; `Repositories` mantém `data_record_type`
como defesa em profundidade, sobre a mesma fonte da lista. Os quatro exemplos não mudam, a IR continua 0.6 e o `.vetra/graph.json`
fica igual.

## Auditoria C11

Implementado pelo Codex sobre `df40e80`; auditado pelo Claude (leitura do diff completo, suíte, gate e sondas). O Claude
executou as sondas no PostgreSQL 18.6 e num 17.11 local, que o sandbox do Codex não alcança. O ADR-042 **continua proposto**:
o aceite depende da decisão do mantenedor sobre o orçamento do gate.

| Achado do Claude | Bloqueia | Decisão |
|---|---|---|
| O ADR-042 estimava cerca de 23% da consulta a partir da medição em Ruby e dos 17 µs por linha da K13; no PostgreSQL a construção ficou de 40% a 56% (7 a 10 µs por registro) | não | Ajustar: o ADR, o relatório da sonda e as docs trazem os números medidos, e a estimativa é registrada como errada |
| O orçamento absoluto de 10 µs por registro, proposto antes da medição, seria atendido no limite (7,2 a 10,1 µs) | não | Ajustar: o ADR registra a ressalva; a decisão continua do mantenedor, e o limiar vigente segue 10% |
| A primeira medição de custo rodou com os dois servidores ao mesmo tempo | não | Ajustar: repetida em sequência, duas execuções por versão |
| O leitor captura `NoMethodError` e o converte em `data_read_value`, o que poderia esconder um defeito do próprio leitor | não | Não ajustar: o contrato é que toda linha incompatível vira o erro de leitura, e a equivalência com a C10 é testada em todos os campos dos quatro exemplos |

**CI.** A [execução 42759473001](https://github.com/vetra-framework/vetra/actions/runs/42759473001) do commit `c204ae1` passou nos cinco jobs,
  com a sonda de custo em 5/5 no 17 e no 18.

**Verificações.** Suíte, 223/223 diagnósticos, gate sem diferenças e `db:plan` sem mudanças; sondas no 17 e no 18: Vetra Data 23,
repositórios 72, outbox 36 e custo do contexto 5/5. Construção dos registros: de 136%-167% (K13) para 40%-56% da consulta; o gate
de 10% do ADR-022 **não é alcançado** e permanece aberto.

## Auditoria K14

Implementado pelo Claude sobre `81f416c`; auditado pelo Codex em modo somente leitura, com a árvore conferida por
hash antes e depois de cada rodada. O Claude rodou a suíte, o gate, `db:plan --check` e as sondas no PostgreSQL 18.6 e
num 17.11 local. A medição é **informativa**: não cumpre o teste de aceitação 6 do ADR-023, que continua pendente.

**Rodada 1 — devolvida pelo Codex.**

| Achado do Codex | Bloqueia | Decisão do Claude |
|---|---|---|
| `actor_bound?` aceitava qualquer igualdade de campo com o ator; `company_id = actor.id` gerava a lista com todos os vínculos do tenant | sim | Ajustar: a coluna do tenant não vincula a lista ao ator, e o gerador mantém o `EXISTS`; teste de regressão e ADR-041, §2 |
| A sonda só comparava a leitura com a política real; nas demais ações a "real" era a própria expectativa | sim | Ajustar: as quatro ações rodam contra `public.leads` e contra cada forma, e a expectativa é calculada sem consultar política |
| O `UPDATE` mantinha a unidade (`SET name = name`) e não exercitava OLD e NEW | sim | Ajustar: pares de origem permitida e proibida e destino permitido, proibido e nulo, com os desfechos 1 linha, 0 linhas e erro, e uma verificação de que os três aparecem |
| O relatório dizia que nenhuma forma ficava abaixo de 1 ms em `UPDATE` e `DELETE`, a materializada era dada como melhor sem a exceção e os totais (atores, vínculos) estavam errados | não | Ajustar: números, exceções e o teste de aceitação 4 do ADR-041 corrigidos |

**Rodada 2 — aprovada pelo Codex.** Os quatro achados foram confirmados como fechados, sem regressão nos pontos tocados;
a normalização do OR foi conferida em 128 mil combinações. O Claude confirmou: suíte 611 testes, 0 falhas, 222/222
diagnósticos; gate sem diferenças nos quatro exemplos; `db:plan --check` nos quatro no 17 e no 18; sondas no 17 e no 18
(plano incremental 18, Vetra Data 23, plano aditivo 99, contexto assinado 58, RLS 103, `db:migrate` 21, `db:migrate` incremental 16,
repositórios 72, outbox 36, relay 38, custo do contexto 4/4, escopo 4/4). O `db:migrate`, a outbox e a contagem de tentativas do
lock_timeout passaram a esperar os quatro planos do CRM com revendas.

**CI.** A [execução 42751564660](https://github.com/vetra-framework/vetra/actions/runs/42751564660) do commit `4456826` passou nos cinco
jobs: suíte, `db:plan` no 17 e no 18 (`--check` nos quatro exemplos) e sondas no 17 e no 18, com a de escopo em 4/4.

**Decisão do ADR-041.** Aceito pelo Claude, por delegação do mantenedor: a política de escopo por vínculo passa à forma
lista, com as concessões da ação fundidas; o `0004_expand` do `mini_crm_revendas` faz a troca atômica das políticas.
O piso de 1 ms por instrução em `UPDATE` e `DELETE` vem das referências ao contexto e fica para uma decisão sobre a função
de contexto, depois da K20.

## Auditoria K13

Implementado pelo Claude sobre `338fd87`; auditado pelo Codex em modo somente leitura, com a árvore conferida por
hash antes e depois de cada rodada. O Claude rodou a medição no PostgreSQL 18.6 e num 17.11 local. A K13 é uma
medição **informativa**: não cumpre o teste de aceitação 6 do ADR-023, e esse gate continua pendente.

**Rodada 1 — devolvida pelo Codex.**

| Achado do Codex | Bloqueia | Decisão |
|---|---|---|
| A forma alternativa do escopo só considerava `gerente`, e a política gerada aceita `gerente` ou `vendedor`; também não havia alternativa de escrita | sim | Ajustar: a lista usa os dois papéis; o relatório limita a conclusão à leitura e diz que o ADR novo precisa medir as formas com `WITH CHECK` |
| A conferência comparava contagens, não conjuntos, e o controle só com o tenant era apresentado como forma equivalente | sim | Ajustar: comparação por conjunto de IDs para seis atores, plano das duas políticas e controle descrito como linha de base de custo |
| Um filho que falhava na preparação travava o pai, que esperava 16 sinais | sim | Ajustar: prontidão por filho (`R`/`E`), espera limitada, encerramento e recolhimento dos filhos nos caminhos de erro |
| O cancelamento entre séries de 1 e 11 instruções, medidas sempre na mesma ordem, não sustentava a precisão alegada (0,487 ms contra um limiar de 0,5 ms) | sim | Ajustar: 3 rodadas com a ordem das séries alternada e a das variantes girada, tabelas limpas nas escritas, latências brutas e dispersão; o veredito passa a incluir "inconclusivo" |
| O texto atribuía a falta de falha acima do limiar à regra dos ADRs, contra o teste de aceitação 6 do ADR-023 | sim | Ajustar: a medição declara que é informativa e não cumpre o teste 6, que fica pendente |
| Extrapolações sem base nos números (independência do tamanho da tabela e das linhas) e o gate do ADR-022 com 9 campos em vez de 10 | não | Ajustar: afirmações restritas às cargas medidas e o gate classificado como aproximação |

**Rodada 2 — devolvida pelo Codex.** Os ajustes funcionais fecharam os achados.

| Achado do Codex | Bloqueia | Decisão |
|---|---|---|
| O relatório falava em acréscimos negativos na questão 1 do 18 e em "uma rodada acima", mas a tabela tem mínimo de +0,200 ms e três das doze estimativas passam de 0,5 ms (+0,520, +0,728 e +0,613) | sim | Ajustar: o texto, o plano e a situação dizem "três de doze estimativas acima no 18"; o −0,560 ms é da questão 2 |
| O ator misto não entra nas séries temporizadas | não | Ajustar: o relatório e o comentário da sonda dizem que os seis atores entram na conferência funcional e só quatro são temporizados |

**Rodada 3 — aprovada pelo Codex**, sem achados novos.

- Suíte com 607 testes, 11.199 asserções e 222/222 diagnósticos, sem mudança desde a K12.
- Medição, 3 rodadas de 3 s: contexto assinado sobre o RLS ingênuo com mediana de 0,212 ms no 17 (dentro) e de
  0,344 ms no 18 (inconclusivo); política de escopo gerada de +0,83 a +2,85 ms na leitura (acima de 1 ms); lista do
  ator de −0,56 a +1,76 ms, com mediana de +1,098 ms para o gerente de 100 no 18; construção dos registros de 72% a
  193% da consulta (acima de 10%).
- `db:plan --check` nos quatro exemplos no 17 e no 18, e o gate sem alterações nos grafos.

**Envio e CI.** Commit `3a9c3b2` na `main`. A CI ([execução 42672241740](https://github.com/vetra-framework/vetra/actions/runs/42672241740)) só ficou verde na tentativa 3: um
incidente do GitHub Actions e da Checks API, aberto das 18:12 às 18:59 UTC, fez a primeira tentativa não criar job
algum e a segunda criar só 3 dos 5; o `ci.yml` do commit só acrescenta um passo e não tem relação com a falha. Na
tentativa 3, os cinco jobs passaram. No job de planos, o PostgreSQL 17.11 e o 18.6 deram relay 38/38, outbox 36/36,
repositórios 72/72, `db:migrate` incremental 16/16, plano aditivo 99/99, Vetra Data 23/23, plano incremental 18/18,
contexto 58/58, RLS 103/103, `db:migrate` 21/21 e a sonda de custo 4/4, com os limiares relatados no relatório.

**Correção posterior do Claude, sem nova auditoria do Codex.** Depois da aprovação, o relatório passou a usar a
mediana, e não a menor repetição, para o gate do ADR-022 (uma repetição isolada deu −8,6%) e a registrar os números
da CI. A mudança só restringe uma afirmação e acrescenta dados; nenhuma conclusão foi ampliada.

## Auditoria K12

Implementado pelo Claude sobre `f45ee36`; auditado pelo Codex em modo somente leitura, com a árvore conferida por
hash antes e depois de cada rodada. O Claude rodou as sondas no PostgreSQL 18.6 e no 17.11 local.

**Rodada 1 — devolvida pelo Codex.**

| Achado do Codex | Bloqueia | Decisão |
|---|---|---|
| A purga podia conferir as pendências enquanto um relay inseria entregas ainda não confirmadas e depois remover a partição com elas | sim | Ajustar: a rotina trava o checkpoint como o `relay!`; sonda com materialização em curso |
| `work` dentro de uma transação externa não confirmava a reserva antes do efeito | sim | Ajustar: o relay recusa transação externa (`data_relay_transaction`) |
| O lease do lote começava antes do primeiro efeito, e os últimos podiam rodar com o lease perdido | sim | Ajustar: `work` reserva uma entrega por vez, logo antes do efeito |
| O passo do `0003` levava `lock=nenhum`, mas cria políticas em tabelas existentes | sim | Ajustar: rótulo pelo lock mais forte das instruções (`AccessExclusive`) |
| O filtro da deriva dividia o dump por linha vazia, inclusive dentro de corpos de função | sim | Ajustar: instruções de topo pelo `StatementScanner` |
| O bootstrap não conferia um `vetra_relay` que já existia | não | Ajustar: a guarda do relay mora no contexto e o bootstrap a roda |

**Rodada 2 — devolvida pelo Codex.** Os ajustes 2 a 6 fecharam os achados.

| Achado do Codex | Bloqueia | Decisão |
|---|---|---|
| A manutenção pedia o checkpoint depois do lock de criação de partição, e o relay faz o contrário: ciclo de locks | sim | Ajustar: o checkpoint vem antes de qualquer lock nas tabelas; sonda com partição faltando e o relay segurando o checkpoint |

**Rodada 3 — devolvida pelo Codex.**

| Achado do Codex | Bloqueia | Decisão |
|---|---|---|
| `failed` atualizava as entregas e depois lia a outbox, e a manutenção trava a outbox e depois as entregas: outro ciclo | sim | Ajustar: a rotina trava checkpoint, outbox e entregas de uma vez, no modo mais forte; a reserva e a falha travam a outbox antes das entregas; sonda com um worker na mesma ordem |
| O filtro tirava o CR de uma quebra CRLF dentro de literais | sim | Ajustar: só o LF, como a normalização; teste com default `'a\r\nb'` |

**Rodada 4 — aprovada pelo Codex**, com um achado não bloqueante.

| Achado do Codex | Bloqueia | Decisão |
|---|---|---|
| O guia dizia que quem grava espera até o `lock_timeout` de 3 s, que só limita a espera da rotina por cada lock | não | Ajustar: o guia e o comentário da rotina fazem a distinção |

- Suíte com 607 testes, 11.199 asserções e 222/222 diagnósticos.
- Sondas no PostgreSQL 18.6 e no 17.11: relay 38/38, outbox 36/36, repositórios 72/72, `db:migrate` incremental
  16/16, plano aditivo 99/99, Vetra Data 23/23, plano incremental 18/18, `db:migrate` 21/21, contexto 58/58 e RLS
  103/103.
- `db:plan --check` nos quatro exemplos no 17 e no 18, e o gate sem alterações nos grafos.

**Envio e CI.** Commit `3c9d6ff` na `main`. A CI ([execução 42378937385](https://github.com/vetra-framework/vetra/actions/runs/42378937385)) passou nos cinco jobs. No job de planos, o PostgreSQL
17.11 e o 18.6 deram relay 38/38, outbox 36/36, repositórios 72/72, `db:migrate` incremental 16/16, plano aditivo
99/99, Vetra Data 23/23, plano incremental 18/18, contexto 58/58, RLS 103/103 e `db:migrate` 21/21.

## Auditoria K11

Implementado pelo Claude sobre `127c690`, com o ADR-040 proposto; auditado pelo Codex em modo somente leitura, com a
árvore conferida por hash antes e depois de cada rodada. O Claude rodou as sondas no PostgreSQL 18.6 e num 17.11
local, extraído do pacote pgdg sem instalação no sistema, para conferir o retrato nas duas versões antes da CI.

**Rodada 1 — devolvida pelo Codex.**

| Achado do Codex | Bloqueia | Decisão |
|---|---|---|
| `unit_of_work.rb`: a conferência da unidade condenada vinha depois do `yield`; um `throw`, `break` ou `return` a pulava e a transação terminava em COMMIT, inclusive dentro de `compose` | sim | Ajustar: `doom!` chama `rollback_on_exit`, que desfaz a transação inteira em qualquer saída; teste com `throw` na transação e em `compose` |
| `scratch_database.rb`: a normalização do NOT NULL herdado reescrevia uma linha dentro de um literal, e dois defaults diferentes davam o mesmo retrato | sim | Ajustar: só a cláusula de topo, com a linha fora de literal e o `CONSTRAINT` fora de um literal aberto nela |
| `differ.rb`: a seção da outbox era conferida só num sentido; uma política excedente na base passava e ficava no banco sem estar no modelo | sim | Ajustar: igualdade nos dois sentidos para os itens com objeto; privilégio excedente cai na conferência genérica; testes para os dois casos |

**Rodada 2 — aprovada pelo Codex**, com dois achados não bloqueantes.

| Achado do Codex | Bloqueia | Decisão |
|---|---|---|
| A normalização também apagava um nome próprio com o sufixo `_<coluna>_not_null` fora de partições | não | Ajustar: só o nome `<pai>_<coluna>_not_null` numa tabela `<pai>_...`, com caso negativo no teste |
| `vetra-data.md` tinha um `\n` literal no texto | não | Ajustar |

- Suíte com 594 testes, 10.546 asserções e 218/218 diagnósticos.
- Sondas no PostgreSQL 18.6 e no 17.11: outbox 36/36, repositórios 72/72, `db:migrate` 21/21, `db:migrate`
  incremental 16/16, plano incremental 18/18, Vetra Data 23/23, contexto 58/58 e RLS 103/103; no 18.6, também
  plano aditivo 99/99.
- `db:plan --check` nos quatro exemplos no 17 e no 18, e o gate sem alterações nos grafos.
- O Claude aceitou o ADR-040 por delegação do mantenedor, depois da aprovação.

**Envio e CI.** Commit `0fff3ee` na `main`. A CI ([execução 42367368631](https://github.com/vetra-framework/vetra/actions/runs/42367368631)) passou nos cinco jobs. No job de planos, o PostgreSQL
17.11 e o 18.6 deram outbox 36/36, repositórios 72/72, `db:migrate` incremental 16/16, plano aditivo 99/99, Vetra
Data 23/23, plano incremental 18/18, contexto 58/58, RLS 103/103 e `db:migrate` 21/21.

## Auditoria C10

Implementado pelo Codex sobre `3e90795`; auditado pelo Claude, que rodou a suíte, o gate e as sondas no PostgreSQL
18.6; o 17 roda no job `db-plan` da CI. A primeira execução do Codex parou no meio pelo limite de uso da conta e foi
retomada a partir da árvore parcial.

**Rodada 1 — devolvida pelo Claude.** A sonda nova passou 72/72 na primeira execução no PostgreSQL 18.6. Ela roda
os corpos `call` dos quatro exemplos pelos repositórios, inclusive a disputa de `add_member!`/`remove_member!`
entre dois backends.

| Achado do Claude | Bloqueia | Decisão |
|---|---|---|
| `lib/vetra/data/repositories.rb:18` definia o `Data` com os nomes dos campos sem conferir colisões. Numa cópia do chat com `string :hash` e `string :class`, `graph:build` e `Repositories.new` passaram, `r.hash` devolveu `"x"` e `{ r => 1 }` levantou `TypeError`; um campo `public_send` quebraria o próprio repositório | sim | Ajustar: `Repositories.new` recusa, com `data_record_type` e antes de gerar qualquer tipo, o campo que coincide com um método público ou protegido do registro. A antecipação no compilador fica pendente |
| Decimal e dinheiro recusam `Integer` na entrada | não | Não ajustar: a entrada estrita evita conversão implícita, e a coerção da entrada fica com o executor |

Na leitura do código:

- o OLD das transições vem do banco, sob `FOR UPDATE`, nunca do objeto recebido;
- o tenant é filtro explícito, além do RLS, e vem só do contexto;
- o `ON CONFLICT` da inclusão casa com o índice único exigido pelo ADR-032, inclusive com tenant;
- os triggers dos CRMs usam `42501`, que o repositório traduz para `data_access_denied`, como o ADR-039 pede;
- a capacidade `read` e a unidade READ ONLY recusam escrita antes de qualquer SQL.

**Rodada 2 — aprovada pelo Claude.**

- Suíte com 583 testes, 9.792 asserções e 216/216 diagnósticos; 35 testes e 865 asserções são da C10.
- Sondas no PostgreSQL 18.6: repositórios 72/72, `db:migrate` incremental 16/16, plano aditivo 99/99, Vetra Data
  23/23, plano incremental 18/18, contexto 58/58, RLS 103/103 e `db:migrate` 21/21.
- `--check` nos quatro exemplos, e o gate contra `origin/main` sem alterações.
- O Claude acrescentou a sonda ao job de planos da CI.
- Planos, modelos, retratos, espelhos e grafos dos exemplos ficaram intactos.

**Envio e CI.** Commit `5c15ebf` na `main`. A CI ([execução 42282609424](https://github.com/vetra-framework/vetra/actions/runs/42282609424)) passou nos cinco jobs. No job de planos, o PostgreSQL
17.11 e o 18.6 deram repositórios 72/72, `db:migrate` incremental 16/16, plano aditivo 99/99, Vetra Data 23/23,
plano incremental 18/18, contexto 58/58, RLS 103/103 e `db:migrate` 21/21.

## Auditoria K10

Implementado pelo Claude sobre `30baef4`; auditado pelo Codex; decisão do Claude. As sondas e o `--check` foram rodados
pelo Claude no PostgreSQL 18.6; o 17 roda no job `db-plan` da CI.

**Rodada 1 — devolvida pelo Codex.**

| Achado do Codex | Bloqueia | Decisão do Claude |
|---|---|---|
| Um plano que começa por índice, com queda depois do índice e antes do registro, acusaria deriva da base na retomada | sim | Ajustar: o começo do plano fica registrado como passo 0, com o SHA-256 do plano, logo depois da conferência da base; com ele, a retomada não confere a base de novo. A sonda cobre um plano só de índices |
| Num banco já migrado, privilégios e objetos fora do dump só eram conferidos no fim, depois de aplicar | sim | Ajustar: conferidos antes de qualquer passo pendente, inclusive na retomada |
| A transação que registra um passo `nao` rodava sem `lock_timeout` | sim | Ajustar: `SET LOCAL lock_timeout` também nela e no registro do começo |
| O índice de uma tentativa anterior era aceito só por nome e tabela | sim | Ajustar: aceito só com a definição do passo (colunas na ordem, btree, sem predicado nem expressão, unicidade); outro índice homônimo é deriva |
| A situação e o plano ainda davam a aplicação incremental como pendente e o progresso em `vetra.migrations` | não | Ajustar |

**Rodada 2 — devolvida pelo Codex.** O marcador, os catálogos, o `lock_timeout` dos registros e a documentação foram
confirmados.

| Achado do Codex | Bloqueia | Decisão do Claude |
|---|---|---|
| A definição do índice usava todas as colunas de `indkey`: um `UNIQUE (a) INCLUDE (b)` passaria como `UNIQUE (a, b)`, e faltavam classe de operadores, collation, ordem e `NULLS NOT DISTINCT` | sim | Ajustar: compara `pg_get_indexdef` com a definição que o passo pede, montada pelo próprio servidor; a sonda cobre o `INCLUDE` |
| O registro do começo do plano ficava fora das novas tentativas, e o `LockTimeout` escapava | sim | Ajustar: o registro do começo também é repetido com espera, com `db_migrate_lock_timeout` ao esgotar |
| A CLI informava novas tentativas que não aconteceram | não | Ajustar: o resultado conta as repetições diretamente |

**Rodada 3 — aprovada pelo Codex**, sem achados. Não encontrou falha de atomicidade, retomada, conferência da base ou
compatibilidade com os registros da K8.

- Suíte com 548 testes, 8.927 asserções e 202/202 diagnósticos.
- Sondas no PostgreSQL 18.6: `db:migrate` incremental 16/16, `db:migrate` 21/21, plano aditivo 99/99, plano incremental
  18/18, Vetra Data 23/23, contexto 58/58 e RLS 103/103.
- `--check` nos quatro exemplos, e o gate sem alterações.

**Envio e CI.** Commit `2db989c` na `main`. A CI ([execução 42251208776](https://github.com/vetra-framework/vetra/actions/runs/42251208776)) passou nos cinco jobs. No job de planos, o PostgreSQL
17.11 e o 18.6 deram `db:migrate` incremental 16/16, plano aditivo 99/99, Vetra Data 23/23, plano incremental 18/18,
contexto 58/58, RLS 103/103 e `db:migrate` 21/21.

## Auditoria C9

Implementado pelo Codex sobre `5e349b8`; auditado pelo Claude, que rodou a suíte, o gate e as sondas no PostgreSQL
18.6; o 17 roda no job `db-plan` da CI. A primeira execução do Codex parou no meio pelo limite de uso da conta e foi
retomada a partir da árvore parcial.

**Rodada 1 — devolvida pelo Claude.**

| Achado do Claude | Bloqueia | Decisão |
|---|---|---|
| `script/sonda_plano_aditivo.rb` montava o login do migrador com o `conninfo_hash` inteiro; a libpq 18 recusa o `scram_client_key` vazio (`invalid SCRAM client key length: 0`), e a sonda parou depois de 3 verificações. Com só os valores não vazios, uma cópia fora da árvore passou 99/99 | sim | Ajustar: o Codex passou a montar o alvo pelos parâmetros da URL, como o `ScratchDatabase`. O código de produção não tinha o defeito |

Na leitura da diferença:

- todo SQL vem do gerador atual;
- a troca de política vai num passo único;
- o `enum` alargado não abre janela sem restrição;
- os índices de apoio vêm antes das FKs;
- uma recusa aborta a construção inteira.

**Rodada 2 — aprovada pelo Claude.**

- Suíte com 543 testes, 8.819 asserções e 203/203 diagnósticos.
- Sondas no PostgreSQL 18.6: plano aditivo 99/99, Vetra Data 23/23, plano incremental 18/18, contexto 58/58, RLS
  103/103 e `db:migrate` 21/21.
- `--check` nos quatro exemplos, e o gate contra `origin/main` sem alterações.
- O Claude acrescentou a sonda ao job de planos da CI.
- Os exemplos não ganharam plano novo: planos, modelos, retratos e espelhos ficaram intactos.

**Envio e CI.** Commit `e2bdd14` na `main`. A CI ([execução 42235979068](https://github.com/vetra-framework/vetra/actions/runs/42235979068)) passou nos cinco jobs. No job de planos, o PostgreSQL
17.11 e o 18.6 deram plano aditivo 99/99, Vetra Data 23/23, plano incremental 18/18, contexto 58/58, RLS 103/103 e
`db:migrate` 21/21.

## Auditoria C8

Implementado pelo Codex sobre `b0483bc`; auditado pelo Claude, que rodou a suíte, o gate e as sondas no PostgreSQL
18.6; o 17 roda no job `db-plan` da CI.

**Rodada 1 — aprovada pelo Claude.**

- Suíte com 510 testes, 8.198 asserções e 195/195 diagnósticos.
- Sondas no PostgreSQL 18.6: Vetra Data 23/23, contexto 58/58, RLS 103/103, `db:migrate` 21/21 e plano incremental
  18/18. O MAC emitido em Ruby é idêntico ao das funções do banco.
- `--check` nos quatro exemplos, e o gate contra `origin/main` com 0 alterações arquiteturais e só o metadado do
  lockfile em cada grafo.
- O compilador não carrega Sequel nem `pg`, e o Vetra Data carrega fora do grupo de desenvolvimento.
- Planos, modelos, retratos e espelhos dos exemplos ficaram intactos.

| Observação do Claude | Bloqueia | Decisão |
|---|---|---|
| A sonda precisava entrar na CI, com senha de login para `vetra_app` no servidor descartável | não | Feito pelo Claude, como previa o pedido: passo no job `db-plan` e `VETRA_APP_PASSWORD` só para esse servidor |
| A documentação descrevia a sonda e o aceite como pendentes | não | Ajustado no envio, com os resultados |
| `rollback!` repassa `Sequel::Rollback` a quem chamou a unidade | não | Não ajustar: é o comportamento escolhido e documentado no ADR-039, §1 |

ADR-039 aceito pelo Claude por delegação do mantenedor.

**Envio e CI.** O commit `a98c4de` entrou na `main`, mas a CI ([execução 42221425042](https://github.com/vetra-framework/vetra/actions/runs/42221425042)) falhou nos jobs `test` e `db:plan` ao
instalar as gems. Os lockfiles tinham sido resolvidos sem rede, e a entrada do `sequel` em `CHECKSUMS` ficou vazia;
o Bundler congelado da CI recusa isso.

A correção `75dd5e2`, do Claude e aprovada pelo Codex:

- preenche o hash com `bundle lock --add-checksums`, conferido contra o publicado no RubyGems;
- reconstrói os grafos, que só mudam no hash do lockfile;
- acrescenta `test/lockfile_test.rb`, que recusa uma entrada sem hash.

A CI ([execução 42223531863](https://github.com/vetra-framework/vetra/actions/runs/42223531863)) passou nos cinco jobs. No job de planos, o PostgreSQL 17.11 e o 18.6 deram Vetra Data 23/23, plano
incremental 18/18, contexto 58/58, RLS 103/103 e `db:migrate` 21/21.

## Auditoria K9

Implementado pelo Claude sobre `d70a00f`; auditado pelo Codex; decisão do Claude. As sondas e o `--check` foram rodados
pelo Claude no PostgreSQL 18.6; o 17 roda no job `db-plan` da CI. O ADR-038 troca a validação integral prevista no
planejamento por regeneração do último plano, história ancorada no gate e contenção; o Codex avaliou a troca.

**Rodada 1 — devolvida pelo Codex.**

| Achado do Codex | Bloqueia | Decisão do Claude |
|---|---|---|
| A cadeia aceitava uma história editada com os hashes recalculados na mesma árvore: nenhuma âncora fora da entrega | sim | Ajustar: o gate confere `db/plans/` e `db/models/` contra a base integrada (arquivo da base inalterado; arquivo novo só depois dos da base) |
| O `vetra_migrator` pode ser dono de outro banco no mesmo servidor, e as ACLs e parâmetros desse banco não entravam no catálogo | sim | Ajustar: o servidor em que o migrador administra outro banco é recusado antes de criar o temporário; o catálogo inclui dono, ACL e parâmetros de todos os bancos |
| A convergência por igualdade textual recusaria uma coluna acrescentada, que fica no fim da tabela | sim | Ajustar: a convergência ignora só a ordem das linhas de cada `CREATE TABLE`; o retrato segue exato. A sonda converge com uma coluna nova |
| A consulta do catálogo lia `pg_authid` mesmo sem superusuário | sim | Ajustar: a senha é lida numa consulta separada, só com superusuário |
| O `db:migrate` aplicaria um segundo plano `unica` num banco vazio | sim | Ajustar: qualquer plano pendente depois do inicial é recusado com `db_migrate_incremental` |
| O filtro recusava identificadores e literais válidos, como uma coluna `copy` | sim | Ajustar: o filtro lê só o código, sem comentários, literais e identificadores; os corpos `$...$` continuam lidos |
| A libpq podia completar o login do migrador com `PGPASSWORD`, `~/.pgpass` ou um `service` do administrador | sim | Ajustar: o login não herda `passfile` nem `service`, e as variáveis de login da libpq saem do ambiente durante a conexão |

**Rodada 2 — devolvida pelo Codex.** Os ajustes de precondição, catálogo de bancos, `pg_authid`, recusa no
`db:migrate` e login do migrador foram confirmados. O Codex considerou a troca da validação integral aceitável em
princípio, condicionada aos dois primeiros achados abaixo.

| Achado do Codex | Bloqueia | Decisão do Claude |
|---|---|---|
| O gate aceitava dois planos novos, e só o último é regenerado: um `0002` com `DELETE` passou com a cadeia recalculada | sim | Ajustar: no máximo um plano novo por aplicação em cada integração, inclusive numa aplicação nova |
| A convergência ordenava linhas soltas, inclusive dentro de literais de várias linhas | sim | Ajustar: ordena definições inteiras de coluna e restrição, com os literais intactos |
| `pg_catalog."set_config"(...)`, com o nome entre aspas, passava pelo filtro | não | Ajustar: o identificador entre aspas chamado como função é conferido pelo nome |

**Rodada 3 — devolvida pelo Codex.** O limite de um plano novo, inclusive em aplicação nova, foi confirmado.

| Achado do Codex | Bloqueia | Decisão do Claude |
|---|---|---|
| Tablespaces ficavam fora da precondição e do catálogo, e o filtro aceitava `GRANT ... ON TABLESPACE` | sim | Ajustar: a precondição recusa tablespace e parâmetro que o migrador administra; o catálogo inclui tablespaces e ACLs de parâmetros; o filtro recusa `ON DATABASE`, `ON TABLESPACE` e `ON PARAMETER` |
| A convergência removia o CR antes do LF dentro de literais | sim | Ajustar: tira só o LF de cada linha |
| Um comentário entre o nome entre aspas e o parêntese escondia a chamada | não | Ajustar: espaços e comentários, inclusive aninhados, são pulados antes do parêntese |
| O caminho que grava o modelo de um plano inicial antigo não conferia o espelho de políticas | não | Ajustar: o espelho é conferido antes de gravar o modelo |

**Rodada 4 — devolvida pelo Codex.** A rodada foi pedida em 2026-11-06, depois que o limite de uso da conta do Codex
interrompeu a primeira tentativa em 2026-11-05. Os quatro ajustes da rodada 3 foram confirmados.

| Achado do Codex | Bloqueia | Decisão do Claude |
|---|---|---|
| A precondição ignorava `pg_database_owner`, que o dono do banco temporário recebe: um GRANT OPTION para ele em outro banco passaria | sim | Ajustar: a precondição considera todos os papéis que o migrador exerce (ele, os herdados ou assumíveis por `SET`, `PUBLIC` e `pg_database_owner`) |
| Os poderes do migrador só eram conferidos pela guarda do próprio plano, que é editável: um migrador promovido a superusuário receberia os passos | sim | Ajustar: a conexão administrativa roda a guarda de papéis do gerador atual antes de qualquer plano, o executor confere a identidade e os atributos da sessão, e o catálogo inclui todos os papéis do servidor |
| Identificadores com escape Unicode (`U&"set\005fconfig"`) escondiam o nome da função | não | Ajustar: o filtro recusa `U&"..."` e `U&'...'`, que o gerador nunca emite |

**Rodada 5 — devolvida pelo Codex.** Os ajustes da rodada 4 foram confirmados.

| Achado do Codex | Bloqueia | Decisão do Claude |
|---|---|---|
| Um plano pode encerrar, com `pg_terminate_backend`, outra sessão do `vetra_migrator` em outro banco, sem privilégio e sem mudar catálogo | sim | Ajustar: o servidor com outra sessão do migrador aberta é recusado antes de criar o banco temporário. Uma sessão que entre durante a aplicação fica registrada como fora da garantia (efeito de disponibilidade, num servidor que já precisa ser descartável) |

**Rodada 6 — aprovada pelo Codex**, sem achados. O Codex considerou a troca da validação integral tecnicamente
aceitável para a K9: a regeneração do último plano, a história imutável contra a base e o limite de um plano novo
por integração sustentam a garantia da história integrada. Antes da integração, a proteção depende das precondições
do servidor descartável, do login restrito e do catálogo, com as exclusões declaradas no ADR-038. Suíte com 493
testes, 7.890 asserções e 186/186 diagnósticos. Sondas no PostgreSQL 18.6: plano incremental 18/18, contexto 58/58,
RLS 103/103 e `db:migrate` 21/21. ADR-038 aceito pelo Claude por delegação do mantenedor.

**Envio.** Commit `5fa7a3a` na `main`. A CI ([execução 42215134526](https://github.com/vetra-framework/vetra/actions/runs/42215134526)) passou nos cinco jobs. No job de planos, o PostgreSQL 17.11 e
o 18.6 deram plano incremental 18/18, contexto 58/58, RLS 103/103 e `db:migrate` 21/21, com o `--check` dos quatro
exemplos aplicado como `vetra_migrator`, que entrou com a senha própria do servidor descartável.

## Auditoria K8

Implementado pelo Claude sobre `8ab5f1b`; auditado pelo Codex; decisão do Claude. As sondas e a CLI conectada foram rodadas
pelo Claude no PostgreSQL 18.6; o 17 roda no job `db-plan` da CI.

**Rodada 1 — devolvida pelo Codex.**

| Achado do Codex | Bloqueia | Decisão do Claude |
|---|---|---|
| A deriva não via os privilégios do próprio banco, que o `pg_dump --schema-only` não inclui: um `GRANT CREATE ON DATABASE` dado depois à aplicação passaria | sim | Ajustar: privilégios do banco conferidos pelo catálogo, antes e depois de aplicar |
| A conferência de banco vazio era uma lista de catálogos e deixava passar uma collation, que só aparecia na deriva depois do commit, com a mensagem "Nada foi alterado" | sim | Ajustar: todo catálogo local com OID a partir de 16384 e o `public` com dono e ACL padrão; mensagem própria para a deriva depois do commit |
| A sonda podia esperar sem prazo e não limpar os bancos | não | Ajustar: prazos e `ensure` |
| O guia do `db:plan` dizia que o `db:migrate` não existia | não | Ajustar |

**Rodada 2 — devolvida pelo Codex.**

| Achado do Codex | Bloqueia | Decisão do Claude |
|---|---|---|
| Uma subscription do banco não era vista (catálogo compartilhado, fora do dump do migrador) | sim | Ajustar: conferida por `pg_subscription.subdbid` |
| Um large object com OID explícito baixo não era visto | sim | Ajustar: qualquer linha em `pg_largeobject_metadata` |

**Rodada 3 — devolvida pelo Codex.**

| Achado do Codex | Bloqueia | Decisão do Claude |
|---|---|---|
| Parâmetros por banco ou por papel no banco (`ALTER DATABASE/ROLE ... SET`), como `session_replication_role = replica`, que desliga a checagem das FKs, não eram vistos | sim | Ajustar: qualquer linha de `pg_db_role_setting` do banco |
| Rótulos de segurança em objetos do sistema não eram vistos | sim | Ajustar: `pg_seclabel` e `pg_shseclabel` do banco; a sonda não os cria, porque exigem provider |
| Publicações | não | Não ajustar o código: já eram vistas; caso acrescentado à sonda |
| Comentários em objetos do sistema | não | Não ajustar: não mudam execução nem permissões; limite documentado |

**Rodada 4 — aprovada pelo Codex**, com um ajuste de texto no plano da persistência, feito pelo Claude.

Verificado pelo Claude no PostgreSQL 18.6: sonda do `db:migrate` 21/21, sem banco nem configuração restante. Ela cobre
aplicação e registro do hash; segunda execução; registro inacessível à aplicação; segundo migrador; superusuário e
aplicação recusados; deriva de esquema, de privilégio do banco, de large object e de parâmetro por banco; plano alterado;
banco com tabela, collation, privilégio padrão, subscription, publicação, large object de OID baixo, parâmetro por banco
ou de papel no banco recusado sem aplicar nada; nova tentativa de `lock_timeout` que aplica; tentativas esgotadas com
retomada; e conexão derrubada no meio do plano com retomada. A CLI conectada como `vetra_migrator` aplica e, na segunda
vez, não acha nada pendente. Sondas de RLS 103/103 e do contexto 58/58; `--check` nos quatro exemplos. Suíte com 477
testes e 7.548 asserções, 179/179.

O commit `da3dda9` foi feito fora do protocolo durante a auditoria, com o estado da rodada 1 e mensagem fora do
formato; não foi reescrito, porque já estava publicado. O `5b15437` traz as correções das rodadas 2 a 4 e o registro da
auditoria. Na CI ([execução 42056786455](https://github.com/vetra-framework/vetra/actions/runs/42056786455)), a sonda do
`db:migrate` passou 21/21, a de RLS 103/103 e a do contexto 58/58 no PostgreSQL 17.11 e no 18.6, com o `--check` dos
quatro exemplos nos dois. Com a K8, a rodada 3 está concluída.

## Auditoria C7

Implementado pelo Codex sobre `f461cb0`; auditado pelo Claude; decisão do Claude. As sondas e os retratos foram rodados
pelo Claude no PostgreSQL 18.6; o 17 roda no job `db-plan` da CI.

**Rodada 1 — devolvida por um ajuste.** ADR-037 proposto: `ENABLE`/`FORCE` RLS em toda tabela com tenant e na raiz, uma
restritiva de tenant por `(SELECT vetra.current_tenant())` (pelo `id` na raiz), permissiva `true` nas entidades sem escopo
SQL e permissivas por ação nas que têm escopo; `db/policies/` como espelho conferido contra a IR e nunca aplicado à parte;
revisão do ADR-031 composta no plano sem transação aninhada; triggers de `transitions enforce: db` `SECURITY INVOKER`,
sem definer novo. Verificado: suíte com 470 testes, 172/172; sonda do contexto assinado 58/58; sonda ADR-031 59/59;
retratos regenerados e `--check` nos quatro exemplos; sonda nova de RLS e integridade 100/103.

| Achado do Claude | Bloqueia | Decisão do Claude |
|---|---|---|
| A sonda chamava `token('cmd' => ...)`, que no Ruby 4 vira argumento de palavra-chave (`ArgumentError`) e derrubava a mesma verificação nos três cenários | sim | Ajustar: hash explícito; com essa mudança numa cópia, 103/103 |
| As tabelas de vínculo têm permissiva `true` dentro do tenant, e uma sessão `vetra_app` com SQL arbitrário poderia criar o próprio vínculo | não | Não ajustar agora: o ADR-037 registra o limite e a situação do projeto o lista como pendência |

**Rodada 2 — aprovada.** No PostgreSQL 18.6, a sonda de RLS e integridade passou 103/103: acessos permitidos no tenant e
no escopo, recusas entre tenants (leitura, escrita, troca de tenant, raiz, FK para outro tenant), sem contexto e com
token inválido, revisão incrementada nas escritas permitidas e desfeita no rollback, e transições permitidas e recusadas,
inclusive `set_by`. A sonda do contexto assinado continua 58/58, e o `--check` passa nos quatro exemplos. O Claude aceitou
o ADR-037 por delegação do mantenedor e acertou nos docs o estado final.

Na CI ([execução 42038274235](https://github.com/vetra-framework/vetra/actions/runs/42038274235)), a sonda de RLS e
integridade passou 103/103 e a do contexto assinado 58/58 no PostgreSQL 17.11 e no 18.6, e o `--check` conferiu os
quatro retratos nos dois.

## Auditoria C6

Implementado pelo Codex sobre `07737ca`; auditado pelo Claude; decisão do Claude. O sandbox do Codex não alcança o
PostgreSQL: as sondas, o bootstrap e os retratos foram rodados pelo Claude no PostgreSQL 18.6; o 17 roda na CI.

**Rodada 1 — devolvida.** ADR-036 proposto: bootstrap dos papéis à parte e repetível, plano que só confere papéis,
`vetra_owner` dono dos objetos, `vetra_app` com DML, `USAGE` e as duas funções de contexto, token
`v1.kid.payload.mac` com HMAC-SHA256 verificado no banco, chaves em `vetra_private.keys` fora dos artefatos, e exceção
exata (assinatura, dono, atributos, configuração e hash do corpo) na guarda de rotinas da C2. Verificado: suíte com 454
testes, 167/167; bootstrap duas vezes; `--snapshot` e `--check` nos quatro exemplos; sonda ADR-031 59/59; a sonda nova
57/57 só numa cópia corrigida em `/tmp`.

| Achado do Claude | Bloqueia | Decisão do Claude |
|---|---|---|
| O plano inicial exigia superusuário para revogar `EXECUTE` dos membros do `pgcrypto`, o que o ADR-002 §3 e o ADR-005 não admitem e que serviços gerenciados não oferecem | sim | Ajustar: `pgcrypto` em `vetra_private`, onde a aplicação não tem `USAGE`, sem revogar os membros; o migrador, dono do banco, aplica o plano; a sonda aplica como `vetra_migrator` |
| A sonda não rodava: `base64` fora do Ruby 4, comparação de UTF-8 com binário e parâmetro de conexão vazio | sim | Ajustar |
| O custo do HMAC por instrução não foi medido (ADR-023) | não | Não ajustar: fica para a rodada de medições |

**Rodada 2 — aprovada.** Suíte com 457 testes e 6.122 asserções, 167/167; bootstrap repetível; a sonda do contexto
assinado passou 58/58, com o plano aplicado pelo `vetra_migrator` (dono do banco, sem superusuário, `CREATEDB` ou
`CREATEROLE`); sonda ADR-031 59/59; retratos regenerados pelo Claude com donos e `--check` nos quatro exemplos, sem
banco temporário restante. O Claude aceitou o ADR-036 por delegação do mantenedor e acertou nos docs o estado final.

Na CI ([execução 42030652797](https://github.com/vetra-framework/vetra/actions/runs/42030652797)), a sonda do contexto
assinado passou 58/58 no PostgreSQL 17.11 e no 18.6, e o `--check` conferiu os retratos com donos nos dois.

## Auditoria K7

Implementado pelo Claude sobre `e0ee3ad`; auditado pelo Codex; decisão do Claude. O sandbox do Codex não alcança o
PostgreSQL, então a aplicação real foi feita pelo Claude no PostgreSQL 18.6; o 17 roda no job `db-plan` da CI.

**Rodada 1 — devolvida pelo Codex.**

| Achado do Codex | Bloqueia | Decisão do Claude |
|---|---|---|
| Uma URL com senha mal codificada fazia a CLI imprimir a mensagem do driver com a senha | sim | Ajustar: erros de URL e conexão viram `db_connection` com classe e SQLSTATE |
| A normalização do retrato tirava linhas `--` e `SET` e espaços também dentro de literais e corpos de função, e dois esquemas diferentes davam o mesmo retrato | sim | Ajustar: `StatementScanner` acompanha literais, comentários de bloco e instruções abertas; a normalização só age entre instruções |
| `--snapshot` aplicava planos editados sem conferir a IR, e um `COMMENT ON DATABASE` chegaria ao servidor | sim | Ajustar: `--snapshot` só aplica planos que a IR gera, como o `--check` |
| A suíte falhava com os `db/` dos exemplos copiados pelos testes | sim | Ajustar: `with_app` remove `db/`, artefato gerado como `.vetra/` |
| Um default com uma linha `-- vetra:` era lido como marcador e o plano gerado era recusado | sim | Ajustar: o leitor do plano usa o mesmo scanner; marcadores só contam entre instruções |
| O formato só tem a transação única; `CREATE INDEX CONCURRENTLY` exigirá passos fora de transação | não | Não ajustar agora: registrado no guia como pré-requisito da rodada 4 |

**Rodada 2 — devolvida pelo Codex.**

| Achado do Codex | Bloqueia | Decisão do Claude |
|---|---|---|
| A normalização tirava o CR de `CRLF` dentro de literais, e `'a
b'` e `'a
b'` davam o mesmo retrato | sim | Ajustar: só o LF delimitador sai de cada linha |
| Um default com CR saía cru no plano, e o segundo `db:plan` recusava o próprio plano | sim | Ajustar: o gerador da C5 escreve caracteres de controle como escapes de E-string; os fixtures da C5 não mudaram |

**Rodada 3 — devolvida pelo Codex.**

| Achado do Codex | Bloqueia | Decisão do Claude |
|---|---|---|
| Um `PGSERVICE` herdado podia levar o `pg_dump` a outro servidor ou banco | sim | Ajustar: o `pg_dump` recebe em `--dbname` os parâmetros efetivos da conexão temporária e roda sem as variáveis `PG*` herdadas; a senha vai só em `PGPASSWORD` |

**Rodada 4 — devolvida pelo Codex.**

| Achado do Codex | Bloqueia | Decisão do Claude |
|---|---|---|
| `target_session_attrs` ficava de fora, e com vários hosts o `pg_dump` podia escolher outro servidor | sim | Ajustar: o servidor efetivo é fixado. Ao reproduzir, o Claude achou um defeito anterior: a conexão ao banco temporário reenviava a lista de hosts e falhava no servidor somente leitura; ela também fica fixa no servidor da conexão administrativa |
| `options` ficava de fora | sim | Ajustar: preservado, com teste do parse pela libpq |

**Rodada 5 — aprovada pelo Codex**, sem achados novos.

Verificado pelo Claude no PostgreSQL 18.6: `db:plan`, `--snapshot` e `--check` nos quatro exemplos, inclusive com
`PGSERVICE`, `PGDATABASE` e `PGHOST` herdados apontando para outro servidor, e com uma URL de dois servidores cujo
primeiro é somente leitura (`target_session_attrs=read-write` e `options`), sem banco temporário restante; a classificação
de lock de cada passo, aplicando os passos um a um com as tabelas já criadas (34 passos sobre tabelas existentes com o
lock declarado; os 13 `CREATE TABLE` só travam a tabela nova). Suíte com 447 testes e 4.804 asserções, 166/166.

Na CI ([execução 41902986720](https://github.com/vetra-framework/vetra/actions/runs/41902986720)), o `--check` passou nos
quatro exemplos no PostgreSQL 17 e no 18: o `pg_dump` 17 reproduz o retrato gerado no 18, o que também confirma no 17
o DDL da C5.

## Auditoria C5

Implementado pelo Codex sobre `131478b`; auditado pelo Claude; decisão do Claude.

**Rodada 1 — aprovada.** ADR-035 proposto e `Vetra::SQL::Schema`, função pura da IR para um modelo congelado e o
DDL de um banco vazio em três blocos (schemas, tabelas com chaves e índices, FKs), com fixtures dos quatro exemplos.
Suíte com 428 testes e 4.618 asserções, 154/154 diagnósticos; gate sem alterações nos grafos.

O Claude aplicou o DDL no PostgreSQL 18.6, um banco vazio por exemplo: 19/19 verificações. O SQL é igual aos
fixtures; os quatro exemplos criam 13 tabelas e 15 FKs numa transação, sem índice inválido, e uma segunda aplicação
falha (`42P07`). No mini CRM com revendas: lead com vendedor nulo é aceito e recebe UUID v4; revenda ou vendedor de
outro tenant é recusado (`23503`); `users` e `dealers` têm FK para a raiz mesmo sem `belongs_to`; `money` exige o
par, recusa `NaN` e moeda com mais casas que a escala (`23514`); `enum` e comprimento são conferidos; as FKs adiáveis
permitem inverter a ordem de inserção numa transação; excluir uma empresa com filhas é recusado. O PostgreSQL 17
entra na CI com a K7.

| Ponto | Bloqueia | Decisão do Claude |
|---|---|---|
| A coluna de moeda aceita qualquer código ISO cujo expoente cabe na escala, não só a moeda da aplicação | não | Não ajustar: o ADR-017 permite valores em outras moedas e deixa a moeda padrão para a entrada |
| `downcase` depende da collation do banco | não | Não ajustar: registrado no ADR-035; a implantação fixa a collation |

## Auditoria C4

Implementado pelo Codex sobre `6b371d3`; auditado pelo Claude; decisão do Claude.

**Rodada 1 — devolvida.** ADR-034 proposto, `rate_limit: "N/[J]unidade"` normalizado em `limit`, `window_seconds`
e `key: actor_tenant`, IR 0.6 com `vetra.rate_limit` só quando usado, schemas 0.1 a 0.5 intactos, diff que trata
afrouxar ou remover como quebra potencial. O blog reproduz a permissão do visitante da proposta. Suíte com 393
testes, 143/143, e gate sem quebra.

| Achado do Claude | Bloqueia | Decisão do Claude |
|---|---|---|
| A regra "todos os limites aplicáveis valem, mesmo com concessão sobreposta sem limite" faz uma permissão limitada reduzir o acesso já concedido por outra; no blog, o `admin` com `manage` em comentários ficaria a 5/min | sim | Ajustar: concessão sem limite admite sem consumir cotas; só quando todas as concessões são limitadas, todas precisam permitir e a admissão conta em todas |
| IDs das políticas dependem da ordem das declarações, e a continuidade das cotas entre builds fica para o runtime | não | Não ajustar: registrado como questão em aberto |

**Rodada 2 — aprovada.** A regra nova está no ADR, com a anterior entre as alternativas rejeitadas. Suíte com 393
testes e 4.307 asserções, 143/143; gate sem quebra; quatro exemplos em check, validação com fontes e link;
`git diff --check` limpo, sem mudança de modo. Os testes usam o exemplo do blog, por isso o formato e o exemplo vão
num só commit, como na C1. O Claude aceitou o ADR-034 por delegação do mantenedor.

## Auditoria K6

Implementado pelo Claude sobre `3221157`; auditado pelo Codex em modo somente leitura; decisão do Claude. A sonda
foi rodada pelo Claude no PostgreSQL 18.6 (31/31: 22 do ADR-015 e 9 do ADR-025); o 17 roda na CI. O 18 aceita
`NOT VALID` na chave estrangeira do pai particionado, o que, pela regra do ADR-025 §3, alinha essa versão ao padrão
das tabelas comuns ([relatório](sondas/adr015.md)).

**Rodada 1 — devolvida pelo Codex.**

| Achado do Codex | Bloqueia | Decisão do Claude |
|---|---|---|
| Uma falha depois do `VALIDATE` deixava a transação aberta e a remoção das tabelas esperando pelo lock; o bloco do `ENUM` podia deixar a sessão abortada | sim | Ajustar: fechar as sessões e desfazer a transação em `ensure`; conferido com uma falha provocada, sem sobra no banco |
| `DROP VALUE` responde `0A000` também no 17, não `42601` | não | Ajustar: exigir `0A000` e corrigir o relatório |
| As recusas aceitavam qualquer erro | não | Ajustar: `0A000` para `CONCURRENTLY` no pai e `42809` para a chave `NOT VALID` no pai antes do 18 |

**Rodada 2 — aprovada pelo Codex**, sem achados novos; suíte com 371 testes, 142/142, e gate repetidos por ele.

## Auditoria C3

Implementado pelo Codex sobre `ea03024`; auditado pelo Claude; decisão do Claude.

**Rodada 1 — devolvida.** ADR-033 proposto, IR 0.5 com `app.rounding` e `vetra.money_rounding`, tabela única de
recursos por versão em `Schema::VERSIONS`. Verificado: 371 testes, 3.414 asserções, 142/142; gate sem quebra;
quatro exemplos em check, validação com fontes e link.

| Achado do Claude | Bloqueia | Decisão do Claude |
|---|---|---|
| Todo build materializava `half_up` e exigia `vetra.money_rounding`, até no blog e no chat, sem `money`: todo consumidor teria de implementar arredondamento para ler qualquer grafo, ao contrário do padrão da C1 | sim | Ajustar: campo e requisito só quando a aplicação declara `rounding:` |
| Trocar o modo é quebra potencial mesmo sem campo `money` | não | Não ajustar: conservador e justificado no ADR |

**Rodada 2 — aprovada.** Só o mini CRM com revendas tem o campo e o requisito. Suíte com 371 testes e 3.482
asserções, 142/142; gate sem quebra; quatro exemplos passam; `git diff --check` limpo, sem mudança de modo. O
Claude aceitou o ADR-033 por delegação do mantenedor e tirou dos docs a narrativa de entrega sem commit.

## Auditoria C1

Implementado pelo Codex sobre `1aca944`; auditado pelo Claude; decisão do Claude.

**Rodada 1 — devolvida.** Suíte, exemplos e gate passavam (348 testes, 141/141 diagnósticos), mas a entrega
acrescentava o recurso `vetra.relation_commands` à IR 0.3 e alterava `docs/ir/v0.3.schema.json`. O ADR-001 (§4)
exige nova MENOR para recurso semântico novo e diz que schemas publicados são imutáveis; o schema 0.3 já tinha
saído na gem 0.1.0.pre.alpha.4, publicada no RubyGems em 2026-11-03 13:08 UTC (conferido pela API do RubyGems).

**Rodada 2 — aprovada.** O schema 0.3 voltou a ser idêntico ao de `HEAD`; a IR 0.4 é um schema novo, igual ao
0.3 exceto pela versão e pelo requisito novo; 0.1, 0.2 e 0.3 continuam aceitas com suas regras, e um documento
0.3 com o requisito ou a primitiva nova é recusado. Verificado pelo Claude: 351 testes e 2.906 asserções, sem
falhas; 141/141 diagnósticos; quatro exemplos em check, validação com fontes e link; gate contra `origin/main`
sem quebra, com a troca de `ir_version` para revisão nos quatro grafos; `git diff --check` limpo.

| Achado | Bloqueia | Decisão do Claude |
|---|---|---|
| Recurso novo dentro da IR 0.3 e schema publicado alterado | sim | Ajustar (feito na rodada 2) |
| A geração vem ligada por padrão, enquanto `crud` é opt-in | não | Não ajustar agora: segue a proposta e está registrado no ADR-032; decisão do mantenedor no aceite do ADR |
| Listas de versões repetidas em `schema.rb`, normalizador, validador e linker | não | Não ajustar agora: o padrão já existia; vale uma tabela de versões quando surgir a 0.5 |
| Nenhum exemplo exercita a geração (o chat usa `commands: false`) | não | Não ajustar: os 20 testes de `relation_commands_test.rb` cobrem a geração e as recusas |

## Auditoria C2

Implementado pelo Codex sobre `de84819`; auditado pelo Claude; decisão do Claude. O sandbox do Codex recusou
sockets Unix e TCP em loopback, então a sonda completa foi rodada pelo Claude, no PostgreSQL 18.6, contra o
gerador novo e contra o de `fb41921` (resto da árvore igual).

**Rodada 1 — devolvida.** Guarda antes da infraestrutura, com o critério de papéis da K5 para quem executa e
para o dono. Sonda 55/55; 33/55 contra `fb41921`.

| Achado do Claude | Bloqueia | Decisão do Claude |
|---|---|---|
| Cadeia de definers: `a()` de dono sem poder, executável por `PUBLIC`, chama `b()`, privada, cujo dono tem `TRUNCATE`; reproduzido no PostgreSQL 18 (tabela esvaziada) sem recusa | sim | Ajustar: fecho recursivo dos papéis alcançáveis por `EXECUTE` de definers |
| A recusa não exige `USAGE` no schema da rotina | não | Não ajustar: conservador; registrar no guia |

**Rodada 2 — devolvida.** Fecho com `UNION`, ciclos encerrados, recusa listando entradas, intermediárias e
rotinas perigosas. Sonda 58/58; 34/58 contra `fb41921`.

| Achado do Claude | Bloqueia | Decisão do Claude |
|---|---|---|
| `INSERT`, `UPDATE` e `DELETE` do dono contavam como poder perigoso, mas DML dispara os triggers `ALWAYS` e incrementa a revisão; erro de especificação do Claude na rodada 1, que recusaria funções de escrita comuns | sim | Ajustar: mesmo modelo de poderes da aplicação (`TRUNCATE`, `TRIGGER`, `REFERENCES`, propriedade, atributos, `ADMIN`, subscriptions, papéis de servidor) |
| A guarda rodava antes da infraestrutura e não conferia, nos donos alcançados, escrita nas revisões, `EXECUTE` nas funções novas e `CREATE` no schema, alcançáveis por privilégios padrão globais do instalador | sim | Ajustar: guarda depois dos `REVOKE`s, conferindo os privilégios efetivos |

**Rodada 3 — aprovada.** Sonda 59/59 no PostgreSQL 18.6, inclusive o `DELETE` por definer de dono só com DML
(revisão de 1 a 2) e as três recusas por privilégios padrão globais; 35/59 contra `fb41921`. Suíte com 355
testes e 2.984 asserções, sem falhas; 141/141 diagnósticos; gate sem alterações; `git diff --check` limpo; modo
`100755` da sonda preservado. O Claude enxugou nos docs a narrativa de rodadas e sandbox, deixando os números
finais. Limite que permanece, documentado no guia: rotinas, corpos e concessões alterados depois da instalação.

## Auditoria K5

Implementado pelo Claude sobre `58993e2`; auditado pelo Codex em modo somente leitura; decisão do Claude.

**Rodada 1 — devolvida pelo Codex.** A correção de `SET ROLE` estava certa (a semântica de `pg_has_role(...,
'SET')` inclui o próprio papel e cadeias), mas três caminhos anteriores contornavam a revisão do mesmo jeito.

| Achado do Codex | Bloqueia | Decisão do Claude |
|---|---|---|
| `GRANT SET ON PARAMETER session_replication_role` permite `replica`, que suprime os triggers | sim | Ajustar de outro modo: triggers `ENABLE ALWAYS`, que vale também para concessões feitas depois da instalação, em vez de só recusar quem tem o poder hoje |
| `REFERENCES` nas tabelas protegidas, inclusive por coluna, não era revogado nem conferido | sim | Ajustar: revogar e recusar, também em papéis assumíveis |
| `ADMIN OPTION` deixa a aplicação conceder a si um papel que hoje não pode assumir | sim | Ajustar: recusar `ADMIN OPTION` da aplicação ou de papel assumível sobre outro papel |
| A edição tirou o bit de execução de `script/sonda_adr031.rb` | não | Ajustar: modo `100755` restaurado |
| A suíte não rodou no sandbox somente leitura do auditor (276 erros de temporários) | não | Não ajustar o código; o Claude repete a suíte antes do envio |

**Rodada 2 — devolvida pelo Codex.** Os três caminhos da rodada 1 ficaram fechados; o Codex rodou a suíte e
conferiu que não alterou a árvore.

| Achado do Codex | Bloqueia | Decisão do Claude |
|---|---|---|
| Uma subscription criada pela aplicação (`pg_create_subscription`) escreve sem disparar triggers por instrução, mesmo `ALWAYS` | sim | Ajustar: recusar uso de `pg_create_subscription` e posse de subscriptions por papel que a aplicação usa |
| `MEMBER WITH ADMIN OPTION` atravessa vínculos `INHERIT FALSE, SET FALSE`: falso positivo com o `ADMIN` implícito de um criador `CREATEROLE` | sim | Ajustar: contar só o `ADMIN` de papéis que a aplicação assume ou herda (`pg_auth_members`), com o caso legítimo na sonda |
| `pg_restore --data-only --disable-triggers` volta os triggers de `ALWAYS` para a habilitação comum | não | Ajustar: documentar a conferência de `tgenabled` depois de um restore assim |
| Contagem da suíte desatualizada no resumo da situação | não | Ajustar no envio |

**Rodada 3 — devolvida pelo Codex.** O falso positivo do criador ficou corrigido; o Codex reproduziu no
PostgreSQL 18.6 dois desvios por cadeia mista e um poder de servidor.

| Achado do Codex | Bloqueia | Decisão do Claude |
|---|---|---|
| `app -SET-> ponte -INHERIT-> administrador`: o `ADMIN` do administrador é utilizável depois de `SET ROLE ponte`, e a consulta não o via (TRUNCATE com revisão parada) | sim | Ajustar: "utilizável" passa a ser o que herda algum papel assumível, não só a aplicação |
| Mesma cadeia com a posse de uma subscription existente | sim | Ajustar com o mesmo critério |
| `pg_execute_server_program` permitiu truncar o arquivo físico da tabela | sim | Ajustar: recusar os três papéis predefinidos de acesso a arquivos e programas do servidor |

**Rodada 4.** Sonda 29/29 no PostgreSQL 18.6, com os três cenários do Codex; contra o gerador de `61efbb8`, as
dez verificações que detectam os caminhos fechados falham (19/29). Suíte com 352 testes e 2.932 asserções.
PostgreSQL 17 só na CI: o WSL tem o cliente, não o servidor.

**Rodada 4 — aprovada com ajuste não bloqueante.** O Codex confirmou os três bloqueantes fechados, também em
cadeias `SET → SET → INHERIT → INHERIT`, sem falso positivo com `pg_read_all_data` ou `pg_monitor`, e repetiu a
suíte (352 testes, 0 falhas, 141/141).

| Achado do Codex | Bloqueia | Decisão do Claude |
|---|---|---|
| Função `SECURITY DEFINER` preexistente do proprietário, executável pela aplicação, faz `TRUNCATE` sem revisão | não | Ajustar documentando o limite no guia; a correção vira a tarefa C2 do Codex, por ser outra classe de problema |

## Auditoria K2: entregas do Codex de `cb7c0b5` a `61efbb8`

Verificado em 2026-11-03 sobre `61efbb8` (a primeira versão deste registro dizia `2d37e15` por engano; o
parecer do Codex apontou a divergência).

**Correção posterior:** o parecer do Codex achou uma lacuna que esta auditoria não viu. O gerador conferia só os
privilégios da aplicação, não os de papéis que ela pode assumir por `SET ROLE` com `INHERIT FALSE`; um
`TRUNCATE` obtido assim apaga vínculos sem incrementar a revisão. A K5 corrige.

**Aprovado.** Suíte com 328 testes e 2.532 asserções, sem falhas, e 137/137 códigos de diagnóstico; os quatro
exemplos passam em check, validação com fontes e link; o gate contra `2cb2700` não aponta quebra e lista para
revisão a IR 0.3, as consultas `my_rooms` e `room_page` e suas rotas; a gem 0.1.0.pre.alpha.5 é construída em
modo estrito. O gerador `db:authz:sql` valida todos os identificadores antes de interpolá-los, usa aspas nos
nomes e literais escapados, recusa papéis privilegiados e não gera SQL parcial.

**Pontos para o mantenedor:**

1. Os ADRs 028 a 031 foram marcados `aceito` pelo próprio agente, na integração. Pelo protocolo novo, o aceite é
   do mantenedor: confirme ou devolva cada um.
2. Os ADRs aceitos 008, 020 e 030 ganharam linhas de cabeçalho (`Evidência posterior`, `Implementação
   posterior`) que a convenção não previa. Não mudam decisões; a K3 as formaliza como referências permitidas.
3. A linha "PRs e commits locais" do resumo parava no PR #36; a K3 a atualiza.
4. A versão 0.1.0.pre.alpha.5 está commitada e não publicada; a alpha.4 publicada não tem os metadados novos.

## Entrega da C15 pelo Codex

Base efetiva: `cdcf4f208a843da6f0f2ef7a79dd71893e4f9dce`, árvore inicialmente limpa na `main`.
É filho direto da base solicitada `991a6a9`; o único acréscimo é o registro de início da C15 no quadro.
Implementação sem commit, branch ou push; árvore entregue para auditoria pelo Claude.

- **Código:** `lib/vetra/data/unit_of_work.rb`, `limits.rb`, `database_errors.rb`, `values.rb`, `repository.rb`,
  `repositories.rb`, `idempotency.rb` e carregamento em `lib/vetra/data.rb`. Timeouts e isolamento externos,
  verificador efetivo padrão e tradução comum, inclusive no commit; condenação total após timeout/serialização/deadlock.
- **Testes:** `test/data_limits_test.rb` (13 testes, 898 asserções) e adaptação dos mocks antigos de contexto,
  repositórios, leitura, outbox, idempotência, sistema, autorização e sondas. Os testes novos exercitam os seis códigos
  `data_timeout`, `data_isolation`, `data_limits`, `data_lock_timeout`, `data_statement_timeout`, `data_serialization`.
- **Sonda:** `script/sonda_limites_unidade.rb`, modo 100755, 15 verificações esperadas. Planos integrados de blog e mini
  CRM pelo migrador; logins reais de aplicação e relay, estouros, serialização, morte de backend ativo/ocioso,
  avanço do xmin e materialização/consumo por handlers. Configuração de teste somente IN DATABASE nos bancos próprios;
  restauração no ensure e comparação dos catálogos de papéis, vínculos e configurações ao final.
- **Documentação:** API, erros, opções, custo e sonda em `docs/vetra-data.md`; comandos operacionais em `docs/db-plan.md`.
  Nenhuma afirmação de status em `docs/situacao-do-projeto.md` precisou mudar; não se anunciou conclusão.

**Decisões.** Timeout da operação é inteiro em ms de 0 a 120.000; zero desliga o limite específico e omissão preserva
sua configuração anterior (nil explícito é inválido). Isolamento somente `:read_committed`/`:serializable`.
O verificador é `limits: Limits.new` por padrão, com tetos 30.000/10.000 ms configuráveis até 120.000 ms;
`limits: false` é a única desativação. Uma instrução parametrizada lê os dois GUCs por transação externa,
antes do contexto; sem cache entre operações nem consultas adicionais por acesso/savepoint, para perceber mudanças
de sessão/pooler. Mediana local com Sequel mock/Ruby 4.0.9, sete séries alternadas de 5.000 unidades vazias:
75,80 µs/op com e 18,45 µs/op sem (diferença 57,35 µs/op); não mede rede/PostgreSQL. A sonda mede o custo real e a contagem.
`Conflict(:lock_timeout)` foi mantido porque já é o contrato da idempotência/K19, agora com código específico;
`StatementTimeout` é distinto, e `SerializationFailure < Conflict` preserva kind `:serialization`. Todos são retentáveis,
sem SQL/mensagem/cause do driver e sem repetição aqui. `57014` também cobre cancelamento externo: não se interpreta
a mensagem para distinguir. Não foi necessário ADR novo: são detalhes de execução previstos nos ADRs 008, 016 e 039
e na P5; os padrões operacionais continuam hipóteses, sem mudar seu aceite.

**Verificação final:** `bundle exec rake test:diagnostics`: 702 testes, 16.498 asserções, sem falhas/erros/skips; Diagnósticos 244/244. `graph:check`, `graph:validate --sources`, `graph:link` e `db:plan` passaram nos
quatro exemplos, sem alterar artefatos (só os avisos já conhecidos de entidade sem política no chat).
`check_graph_compatibility.rb --base origin/main` passou contra `991a6a9`, sem diferenças nos quatro exemplos e sem
aviso de árvore suja. `ruby -c` da sonda e `git diff --check` passaram; modo 755 conferido. Sem falha de temporários.
Os exemplos não têm Rakefile próprio; a suíte é a da raiz. `db:plan --check` depende de PostgreSQL, então não rodou.

**Pendente/risco:** execução real da sonda e das sondas afetadas no PostgreSQL 17/18 e medição real, pelo Claude;
estouro/rollback/xmin/RLS não estão provados por mocks. O padrão ligado recusa ambientes sem os dois parâmetros:
a CI e instalações existentes precisam atualizar o bootstrap antes das sondas antigas/runtime. K19 continua responsável
por repetição e resposta/409. Nenhuma edição em `.github/`, `.claude/`, IR, planos, modelos ou retratos dos exemplos.

**CI (Claude):** no job de planos da matriz 17/18, acrescentar
`run: bundle exec ruby script/sonda_limites_unidade.rb`. No bootstrap operacional que precede as sondas, executar
`ALTER ROLE vetra_app SET transaction_timeout = '30s';` e
`ALTER ROLE vetra_app SET idle_in_transaction_session_timeout = '10s';` como administrador, conforme `docs/db-plan.md`.

Auditoria, achados, decisões e CI: pendentes do Claude; sem commit da entrega ainda.

## Entrega da K17 pelo Claude

Base: `f50006c` (`git rev-parse HEAD`), árvore limpa antes da tarefa. Implementação sem commit, branch ou push; árvore entregue para a
auditoria do Codex, em modo somente leitura.

- **O que mudou.** ADR-045 proposto ([borda interna, autoridade de revisão e Runner](adr/045-borda-interna-e-runner.md)).
  `lib/vetra/execution/edge.rb` (`Identity`, `FactsRequest`, `Edge`), `facts.rb` (`InProcessAuthority`, `DatabaseAuthority`,
  `DatabaseFacts`) e `runner.rb` (`Runner`, `Outcome`, `Failure`, `CallHost`, `OperationClock`); `Authorization#fact_plan`,
  `#policy_entities`, `#scope` e `Predicate#traversed`; `Repositories#fact_rows`; `LinkedGraph#run_implementation`; o descritor
  `builtin` do linker sem `executor: "pending"` (CLI, cinco testes e quatro guias ajustados, a IR não muda).
- **Etapas.** 1 a 5 e 8 como passos nomeados; os ganchos `persist` (K18) e `register` (K19) ficam vazios. As recusas 1 a 3 voltam como
  `Outcome` sem tocar o pool da operação; o que vem depois da etapa 4 levanta, com a unidade desfeita por inteiro.
- **Verificação.** Suíte 729 testes, 16.661 asserções, 0 falhas, 250/250 diagnósticos (27 testes novos: 26 em
  `test/execution_runner_test.rb` e 1 em `link_test.rb`). Sonda `script/sonda_runner.rb` (nova, modo 100755) com 26 verificações no
  PostgreSQL 17.11 e no 18.6: um comando de cada exemplo pelo `Runner` em dois pools de `vetra_app`, as duas contagens de transações,
  a invalidação depois do commit, a revogação durante a admissão e a autoridade fora do ar. Entrou na CI. Gate, `db:plan` e as
  sondas afetadas são rodados pelo Claude antes do envio.
- **O que ficou de fora.** Autorização dos acessos e reautorização do estado final (K18), eventos e idempotência no `Runner` (K19),
  handlers (C14), `many_to_many` no avaliador (C16, e por isso `chat.read_room` recusa com `data_authorization_predicate`),
  composição pelo `call`, capacidades além de repositório e `clock`, adaptadores, autoridade distribuída.
- **Riscos que vejo.** (1) A geração em processo vale para um processo, e há uma janela de microssegundos entre o commit e a
  publicação; o ADR-045, §3 a assume. (2) `DatabaseFacts` lê inteiras as entidades que as políticas percorrem (limite de 10.000
  linhas, recusa acima) e não guarda cache: é referência, e a K20 mede. (3) O `Runner` publica também na falha, o que é conservador.
  (4) Achado do modelo, fora do escopo: no blog, `crud scope: :author` entra em todas as políticas da entidade, inclusive na do
  visitante, então o visitante não lê nenhum post; está no ADR-045 e vai para a rodada 6.

## Auditoria K17

Implementado pelo Claude sobre `f50006c`; auditado pelo Codex em modo somente leitura, com a árvore conferida por hash antes e depois de
cada rodada. O Claude rodou a suíte, o gate, `db:plan` e as sondas no PostgreSQL 17.11 e no 18.6, que o sandbox do Codex não alcança.

**Rodada 1 — devolvida pelo Codex.**

| Achado do Codex | Bloqueia | Decisão do Claude |
|---|---|---|
| `publish!` que levanta exceção escapava do `Runner`: depois do `COMMIT` a geração ficava inalterada e um snapshot anterior continuava válido, e a mensagem do colaborador atravessava a borda; numa `Failure`, a exceção da publicação a mascarava | sim | Ajustar: `Edge#publish!` nunca levanta; a falha torna a confirmação (`Edge#authority`) indisponível, e toda operação seguinte recusa com `data_authorization_snapshot` até uma nova publicação ter sucesso. Testes de recuperação e de não mascarar a `Failure`; ADR-045, §3 |
| Erro de driver no COMMIT saía cru do `Runner` (a unidade só traduz os retentáveis) | sim | Ajustar: o `Runner` traduz o `Sequel::DatabaseError` de `BEGIN` e `COMMIT` para erro de dados, sem mensagem nem causa; teste com unidade que levanta o erro |
| `LinkedGraph#run_implementation` devolvia o `Proc` privado a um hospedeiro que redefinisse `instance_exec` | sim | Ajustar: usa `BasicObject.instance_method(:instance_exec).bind_call`; teste com hospedeiro que redefine o método |
| `Edge#resolve` repropagava um `Data::Error` do provedor com a causa e a mensagem | sim | Ajustar: toda exceção da identidade vira `execution_identity`, sem causa; teste com exceção aninhada |
| A sonda não provava a ordem commit/publicação (conferia só a geração depois de `run`) nem o desfazer de uma escrita antes do `fail!` | não | Ajustar: um wrapper de autoridade registra, na publicação, o que o pool da operação já viu; um `publish_post` de uma cópia temporária do blog escreve e depois falha. Achado extra do Claude: o casamento `include?('COMMIT')` pegava `READ COMMITTED` do `SET TRANSACTION`, então a ordem passava por engano; as contagens usam a palavra inteira. 26/26 no 17 e no 18 |
| `situacao-do-projeto.md` contava dois ADRs propostos e dava o despacho como pendente; `fase-0.md` atribuía à K18 obrigações que o repositório já cumpre | não | Ajustar: três propostos (042, 044 e 045), o `Runner` na linha do runtime, a contagem de sondas e o trecho da fase 0 |

**Rodada 2 — devolvida pelo Codex.** Os quatro bloqueantes e os dois não bloqueantes da rodada 1 foram dados como fechados, e restou um.

| Achado do Codex | Bloqueia | Decisão do Claude |
|---|---|---|
| Publicações concorrentes reabriam a guarda com marcador obsoleto: a publicação A incrementa a geração e suspende antes de retornar; a B falha e torna a confirmação indisponível; a A retorna e reabre a guarda, e um snapshot anterior ao commit da B volta a ser aceito | sim | Ajustar: cada tentativa tira um número antes de publicar, e só uma publicação **iniciada depois** da última falha reabre a confirmação (`Confirmation#begin_publication`, `#published!`, `#failed!`). Teste com threads e barreiras que reproduz a corrida; ADR-045, §3 |

**Rodada 3 — aprovada pelo Codex.** O ajuste fecha o achado da rodada 2: o Codex reproduziu a corrida, procurou outras intercalações (várias falhas,
sucesso só depois de falha, leitura da guarda no meio) e não achou nenhuma que admita um snapshot anterior ao commit que não conseguiu publicar. Restou um
achado de forma, não bloqueante: uma linha em branco no fim do quadro (`git diff --check`), ajustada.

**Verificações.** Suíte 729 testes, 16.661 asserções, 0 falhas, 250/250 diagnósticos; sonda do Runner 26/26 no 17 e no 18.

**CI.** A [execução 43023877656](https://github.com/vetra-framework/vetra/actions/runs/43023877656) do commit `074c75c` passou nos cinco jobs, com a sonda do Runner em 26/26 no 17 e no 18 e o
`db:plan --check` dos quatro exemplos. O aceite do ADR-045 é do mantenedor; a próxima tarefa é a C16 (Codex), `many_to_many` no avaliador.

## Auditoria C16

Implementado pelo Codex sobre `e775a65`; auditado pelo Claude (leitura de todo o código, dos testes, da sonda nova e das emendas; suíte, gate,
`db:plan` e as sondas no PostgreSQL 17.11 e 18.6, que o sandbox do Codex não executa). O ADR-044 **continua proposto**.

| Achado do Claude | Bloqueia | Decisão |
|---|---|---|
| O guia, o ADR-045, a situação e o plano ainda diziam "esperadas", "pendente de execução" e que as políticas de `many_to_many` recusam | não | Ajustar (pelo Claude): os textos passam a dar as contagens executadas (30 e 27) e a C16 como integrada |
| A sonda nova não estava na CI | não | Ajustar (pelo Claude; o Codex não edita `.github/`): passo novo depois da sonda de autorização Ruby |
| O provedor de referência lê inteiras a junção `room_membership` **e** a tabela `chat.user` (com e-mail, dado pessoal) para decidir `members`, porque o avaliador compara a linha do alvo | não | Não ajustar agora: é da referência e do limite de 10.000 linhas por entidade, que recusa em vez de truncar; a K20 mede o custo, e uma leitura por chaves (só as linhas dos ids percorridos) é uma otimização do provedor, não do contrato. Registrado no ADR-045 |

Não achei defeito no avaliador: os três percursos (validação, fatos e avaliação) usam os mesmos saltos pela mesma função, a chave composta é
comparada inteira, NULL em qualquer componente não casa, o tenant filtra junção e alvo, e a entidade omitida recusa mesmo com um salto anterior vazio
(a conferência nova de `Authorization#check` exige todas as entidades percorridas). Os testes cobrem membro, não membro, dono, outra sala, outro tenant,
chave NULL ou órfã, percursos com mais de um salto e dois `many_to_many` na mesma árvore.

**Verificações.** Suíte 738 testes, 0 falhas, 250/250 diagnósticos; gate sem diferenças; `db:plan` sem mudanças nos quatro exemplos; sonda de
autorização do chat 30/30, a do Runner 27/27 e a de autorização Ruby 68/68, no 17 e no 18.

**CI.** A [execução 43035403713](https://github.com/vetra-framework/vetra/actions/runs/43035403713) do commit `8fb069f` passou nos cinco jobs, com a sonda de autorização do chat em 30/30 e a do Runner em
27/27 no 17 e no 18. A próxima tarefa é a K18 (Claude): autorização nos acessos dos repositórios, coletor de fatos na unidade e reautorização do estado final.

## Entrega da K18 pelo Claude

Base: `055600e` (`git rev-parse HEAD`), árvore limpa antes da tarefa. Implementação sem commit, branch ou push; árvore entregue para a
auditoria do Codex, em modo somente leitura.

- **O que mudou.** ADR-046 proposto ([autorização dos acessos, estado final e ator de sistema](adr/046-autorizacao-dos-acessos-e-estado-final.md)).
  `lib/vetra/execution/guard.rb` (`AccessGuard`); `Authorization#decide`, `#granted?`, `#field_names`, `#fact_entities`, o ramo de sistema
  (`system_result`) e a admissão de consulta de coleção (`admit_collection`) em `authorization.rb`; `UnitOfWork#transaction(guard:)` e
  `#guard`; os ganchos da guarda em `Repository` (`find!`, `lock!`, `create!`, `update!`, `delete!`, `query_all` em lotes, `change_link`);
  `Identity#system_actor`; `Runner` com a guarda, o `persist` (etapa 6) e o ramo de sistema (sem fatos). O Runner passou a enviar
  `system_actor` nas claims da unidade (o teste do ator de sistema achou o erro).
- **Semântica.** `lock!` decide só `read`; `update!` e `delete!` leem o OLD sob lock e decidem a ação; o vínculo decide a ação do vínculo
  sobre o dono (o alvo, a junção e o `include_on_create` não repetem a decisão); a coleção filtra por linha, em lotes de 200, e o limite
  vale para as visíveis. Sem concessão alguma do papel, a recusa é explícita (`data_authorization_denied`), mesmo numa coleção vazia (é o
  caso de `chat.add_member_by_email`); com concessão e linha não satisfeita, a leitura some (`RecordNotFound`) e a escrita recusa.
- **Estado final.** `reauthorize!` relê cada linha criada ou alterada com fatos novos e decide `create` ou `update`; recusa com o código
  novo `data_authorization_final` e desfaz a unidade. O cache de fatos é por entidade, dentro da operação, descartado a cada escrita.
- **Ator de sistema.** A etapa 3 autoriza o comando se, e somente se, ele está nos `calls` do handler de mesmo `id`, sem papéis, fatos nem
  revisão; a guarda e a reautorização são vazias para ele.
- **Verificação.** Suíte 768 testes, 17.128 asserções, 0 falhas, 251/251 diagnósticos (30 testes novos: 26 em `test/execution_guard_test.rb`
  e 4 em `execution_authorization_test.rb`). Sonda `script/sonda_acessos.rb` (nova, modo 100755) com 21 verificações no PostgreSQL 17.11
  e no 18.6; as sondas anteriores seguem verdes nos dois (Runner 27, chat 30, autorização Ruby 68, Vetra Data 23, repositórios 72, outbox
  36, relay 38, idempotência 83, limites 15). Entrou na CI. Gate e `db:plan` são rodados pelo Claude antes do envio.
- **O que ficou de fora.** Eventos do `emits` e idempotência no `Runner` (K19), handlers e o runner deles (C14), contadores de
  `rate_limit:` (rodada 6), leitura de coleção traduzida para SQL, leitura com projeção de campos.
- **Riscos que vejo.** (1) Cada acesso custa uma decisão, e a primeira de cada entidade, a leitura dos fatos que ela percorre; o
  `delete!` ganha um `SELECT ... FOR UPDATE`; a K20 mede. (2) O filtro de coleção é em Ruby e pagina de 200 em 200: não serve a tabelas
  grandes com filtro seletivo. (3) A leitura de registro inteiro exige todos os campos da entidade: uma política de leitura com menos
  campos recusa. (4) O ator de sistema não passa por política alguma: o que o limita é o `calls`, o tenant e o RLS (`vt_system`).

## Auditoria K18

Implementado pelo Claude sobre `055600e`; auditado pelo Codex em modo somente leitura, com a árvore conferida por hash antes e depois de cada
rodada. O Claude rodou a suíte, o gate, `db:plan` e as sondas no PostgreSQL 17.11 e no 18.6, que o sandbox do Codex não alcança.

**Rodada 1 — devolvida pelo Codex.**

| Achado do Codex | Bloqueia | Decisão do Claude |
|---|---|---|
| A guarda não acompanhava o rollback de um savepoint de `compose`: apagar dentro dele, reverter, resgatar e transferir o autor deixava `deleted: true`, e a etapa 6 pulava a linha | sim | Ajustar: `UnitOfWork#compose` pede à guarda um ponto de retorno e o restaura se o savepoint não termina (`AccessGuard#checkpoint` e `#restore!`, que também descartam os fatos lidos); teste que reproduz o caso |
| Apagar e recriar o mesmo UUID não limpava a marca de exclusão: um `update!` posterior para outro autor escapava da etapa 6 | sim | Ajustar: só a última escrita diz se a linha está apagada; teste |
| Oráculo de existência: `find!`, `lock!`, `update!` e `delete!` consultavam a linha antes da concessão estática, então o papel sem concessão recebia "negado" para um id existente e "não encontrado" para um inexistente | sim | Ajustar: `AccessGuard#require_grant!` roda antes da consulta nos quatro, e no vínculo antes de travar o dono; teste com tabela cheia e vazia |
| Regressão na precedência de diagnósticos: o registro principal passou a ser resolvido antes das políticas candidatas (`crm.read_lead` sem papéis devolvia `data_authorization_snapshot` em vez de `data_authorization_denied`) | não | Ajustar: `decide` recebe a linha como bloco, resolvido depois da seleção e da validação das políticas; teste |
| No `create!`, a transição era conferida antes da permissão | não | Ajustar: a permissão vem primeiro, como no `update!`; teste |
| A sonda não provava a invalidação dos fatos dentro da mesma operação (cinco chamadas independentes ao Runner) | não | Ajustar: uma cópia temporária do chat com um comando que lê a coleção, cria a sala (vínculo do dono) e relê a sala; passa só se o cache da junção foi descartado. Mais dois testes de unidade, com e sem `touched!`. 21/21 no 17 e no 18 |
| `situacao-do-projeto.md` e o topo do `vetra-data.md` ainda diziam que a autorização dos acessos e o executor não existiam | não | Ajustar |

**Rodada 2 — devolvida pelo Codex.** Os três bloqueantes e os quatro não bloqueantes da rodada 1 foram dados como fechados, e restaram um bloqueante
e um ajuste:

| Achado do Codex | Bloqueia | Decisão do Claude |
|---|---|---|
| `break`, `return` e `throw` para fora do `compose` pulavam o `done = true`, mas o Sequel libera o savepoint: o `ensure` restaurava o ponto de retorno e apagava uma escrita válida, e a troca de autor passava pela etapa 6 e chegava ao `COMMIT` | sim | Ajustar: só uma exceção desfaz o savepoint, então a guarda restaura o ponto de retorno em `rescue Exception` (e não em `ensure`); teste com `break` e `throw` (o `return` segue o mesmo caminho); ADR-046, §4 |
| A coleção consultava o banco antes da concessão estática (`where(...).first(2)` executava o `SELECT` antes de `visible` recusar) | não | Ajustar: `query_all` chama `require_grant!` antes de consultar; o teste confere que nenhum `SELECT` saiu |
| Contagens desatualizadas depois dos ajustes (testes, asserções e verificações da sonda) | não | Ajustar |

**Rodada 3 — devolvida pelo Codex.** O `compose`, a coleção e as contagens foram dados como fechados, e restou um bloqueante.

| Achado do Codex | Bloqueia | Decisão do Claude |
|---|---|---|
| Um `call` que sai por `throw` (aceito pela análise estática) para fora do `Runner#run` pulava `persist`, e o Sequel confirmava a transação: a mesma troca de autor que recebia `data_authorization_final` chegava ao `COMMIT` | sim | Ajustar: o `Runner` só dá o fechamento por concluído depois de `persist` e `register`; senão marca a transação com `UnitOfWork#abandon!` (`rollback_on_exit`), que vale também para `break` e `throw`. A geração continua publicada (o `ensure` do `run`). Teste com um `publish_post` que escreve e faz `throw`; ADR-046, §4 |

**Rodada 4 — aprovada pelo Codex.** O ajuste fecha o achado da rodada 3: o Codex confirmou, com Sequel mock, que `throw`, `break`, `return` e exceção
geram `ROLLBACK`, publicam a geração e limpam a unidade. Restaram três achados não bloqueantes, todos de texto: o registro e as contagens (768 testes, 26 na
guarda, 30 novos), que o Claude já havia atualizado enquanto a auditoria rodava, e duas descrições da sonda que prometiam mais do que executavam (a de
`add_member` e `remove_member` falava de "mesma operação", e a do post alheio de "alterado"); ajustadas, a invalidação dentro da operação continua provada pela
variante do chat.

**Verificações.** Suíte 768 testes, 17.128 asserções, 0 falhas, 251/251 diagnósticos; sonda dos acessos 21/21, e as sondas do Runner (27), do chat (30),
de repositórios (72) e de autorização Ruby (68) verdes no 17 e no 18.

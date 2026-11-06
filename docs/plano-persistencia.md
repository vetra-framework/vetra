# Plano da persistência

A persistência transforma o grafo em banco PostgreSQL 17+, por plano versionado, com papéis, contexto
assinado e RLS. O mapeamento físico está no ADR-035 aceito; o bootstrap dos papéis globais e o contexto
assinado estão no [ADR-036](adr/036-papeis-e-contexto-assinado.md), também aceito. Responsáveis e decisões de auditoria ficam no [quadro dos agentes](tarefas-dos-agentes.md).
A rodada 3 levou cada exemplo de um banco vazio ao plano inicial aplicado; a rodada 4 faz esse banco evoluir e
ser usado pelo Vetra Data.

## Rodada 4: plano incremental, repositórios e outbox

### Objetivo

Um banco que já recebeu o plano inicial recebe as mudanças do modelo por planos incrementais seguros (ADR-015 e
ADR-025), e o Vetra Data lê e grava nele como `vetra_app`. O código Ruby emite o contexto assinado, os
repositórios gerados fazem as leituras e as gravações, e os eventos entram na outbox na mesma transação (ADR-003 e
ADR-022, ADR-014 e ADR-024, ADR-008). Ao fim da rodada:

- os três exemplos com eventos (blog e os dois CRMs) recebem um `0002` com a outbox, gerado pelo plano
  incremental e aplicado por `db:migrate` sobre o banco da rodada 3;
- uma sonda grava pelos repositórios numa unidade de trabalho e emite o evento; o relay materializa as entregas e
  as leva a consumidores simulados, no PostgreSQL 17 e 18. Os handlers reais, com o ator de sistema e os comandos
  dos `calls`, dependem do executor da rodada 5;
- o custo do contexto assinado por instrução tem uma medição preliminar, na matriz do ADR-023. O gate completo,
  por comando, volta quando houver o executor.

A IR permanece 0.6: nada desta rodada muda o formato do grafo.

### Entregas e dependências

As tarefas rodam nesta ordem, uma por vez no checkout compartilhado:

| Tarefa | Implementador | Dependência | Entrega |
|---|---|---|---|
| K9 — fundação do plano incremental | Claude | — | ADR-038 aceito. Modelo físico versionado e vinculado a cada plano, com formato próprio e versão, gerado e nunca editado à mão. Modo de transação por passo no formato do plano, e executor descartável que aplica passos fora de transação. Cadeia dos planos, filtro de instruções globais, aplicação como `vetra_migrator` e catálogo de papéis conferido, no lugar da regeneração dos planos antigos (ver as decisões abaixo). `--check` com N planos e convergência; diferenças aditivas pelo consumidor da C9 |
| C8 — unidade de trabalho e contexto emitido | Codex | — | Implementados a unidade de trabalho e o emissor Ruby, conforme o [ADR-039](adr/039-unidade-de-trabalho-e-repositorios.md): transação externa, savepoints, `read_only`, guarda por fibra e contexto global sem token nem tenant fictício. `sequel` e `pg` são dependências de runtime com janela `~>`, sem carga no compilador. Sonda escrita para auditoria do Claude no 17/18; [guia](vetra-data.md) |
| C9 — diferenças aditivas | Codex | K9 | Implementada a diferença entre o modelo versionado e a IR, em passos expand classificados: tabela nova, coluna anulável, coluna `NOT NULL` com default constante, índice `CONCURRENTLY` fora de transação, índice único de apoio antes da FK composta, FK `NOT VALID` seguida de `VALIDATE`, `CHECK` de `enum` alargado e troca atômica de política. As demais mudanças são recusadas com código próprio, sem plano parcial. `db:plan` grava `NNNN_expand.sql` e o modelo, com nome e conteúdo determinísticos; atualiza o espelho completo da segurança atual. A sonda `sonda_plano_aditivo.rb` cobre 13 cenários, dados, convergência e escrita concorrente em 1 milhão de linhas (99 verificações esperadas). Execução e inclusão na CI pelo Claude no 17/18; [guia](db-plan.md) |
| K10 — `db:migrate` incremental | Claude | K9 e C9 | Progresso por passo em `vetra.migration_steps`, com a linha do plano em `vetra.migrations` junto do último passo, passos fora de transação, `lock_timeout` e novas tentativas por passo. A base de cada plano é conferida antes de aplicá-lo, e a execução retoma do passo seguinte ao último concluído, conferindo o estado intermediário. A sonda interrompe em cada passo, inclusive depois de um DDL fora de transação e antes do registro, com o índice válido ainda não registrado e com o índice inválido |
| C10 — repositórios gerados | Codex | C8 | Implementados `Repositories.new(document)` e `bind(capability_id, unit:)`, com um repositório e um `Data` imutável por entidade. Operações de registro, locks, vínculos idempotentes, `include_on_create` e consulta restrita passam pela guarda da unidade. Tenant vem do contexto; defaults, downcase, slug e created_at seguem ADR-035/027. Capacidade e unidade somente leitura recusam escrita; transições conferem OLD do banco e cmd. Erros públicos não carregam SQL/valores do driver. A sonda `sonda_repositorios.rb` executa os corpos reais dos quatro exemplos, inclusive concorrência de vínculos, com 72/72 verificações no 17/18 da CI. [Contrato e resultados](vetra-data.md#sonda-dos-repositórios) |
| K11 — outbox: armazenamento e emissão | Claude | K10 e C8 | ADR-040 proposto, sobre os papéis e o RLS da outbox. `vetra.outbox` e `vetra.deliveries` particionadas por `created_at`, com partição `DEFAULT`, e `vetra.dead_deliveries`, num `0002` gerado pelo plano incremental para os três exemplos com eventos. O evento é gravado na unidade de trabalho com `xid8`, `seq`, `event_id` e o payload projetado. Um payload com campo pessoal desfaz a unidade de trabalho inteira, enquanto a cifra do ADR-013 não existe |
| K12 — relay, entregas e manutenção | Claude | K11 | Relay por intervalos de `xid8`, materialização das entregas, reserva por lease com `SKIP LOCKED`, tentativas, entrega morta e cópia para `dead_deliveries`, tudo com consumidores simulados. Um comando de manutenção cria as partições antes de liberar quem grava, recupera uma `DEFAULT` populada e purga por `DETACH`/`DROP`. As partições operacionais são reconhecidas pela deriva do `db:migrate` sem esconder adulteração |
| K13 — custo do contexto, medição preliminar | Claude | C10 | Custo por instrução no 17 e no 18, na matriz do ADR-023: 16 clientes, comparação com o RLS ingênuo, vínculos em escala de milhões e o limiar de 1 ms da questão 2. Inclui o pooler transacional quando houver um na CI, e o gate da construção dos `Data` (ADR-022, §3). O percentual por comando volta com o executor. Fundir as funções de contexto exigiria ADR próprio e a atualização coordenada das políticas e da guarda de rotinas do ADR-036 |

Fora as dependências da tabela, a ordem é só a da árvore compartilhada: a C8 não depende da K9. A sonda de cada
entrega do Codex roda com o Claude, porque o sandbox do Codex não alcança o PostgreSQL.

### Decisões que a rodada precisa tomar

Cada decisão entra como ADR `proposto` na tarefa que a implementa e é aceita depois da auditoria.

- **ADR-038 aceito (K9, C9 e K10), a base do plano incremental.** O ADR-025, §1 manda planejar contra o retrato e
  reserva a introspecção à verificação. A decisão é planejar contra um **modelo físico versionado**, gravado pelo
  `db:plan` junto com cada plano e vinculado a ele por hash, para que o `db:plan` continue sem conexão e os estados
  históricos possam ser comparados. O `--check` reaplica os planos num banco descartável e confere o modelo e o
  retrato contra o resultado: a introspecção fica na verificação, como o ADR-025 decide. O §1 compara com
  `db/schema.sql`, e o plano incremental passa a comparar com o modelo. Por isso o ADR-038 diz expressamente como
  complementa o §1, cobrindo também segurança e infraestrutura além das tabelas das entidades, e o replay prova a
  equivalência entre modelo, planos e retrato. O ADR-038 fixa também:
  - o formato versionado do modelo;
  - o modo de transação por passo no formato do plano;
  - o registro por passo, a conferência do estado intermediário na retomada e a da base antes de cada plano;
  - o que o `--check` confere quando há N planos.
- **Segurança do servidor da CI sem regenerar planos antigos (K9).** Hoje o `--check` só aplica um plano igual ao
  que a IR gera, e essa é a proteção do servidor: a classificação por prefixo não basta, porque um passo com
  `CREATE TABLE` seguido de `COMMENT ON DATABASE` recebe classificação conhecida. Um plano antigo não pode ser
  regenerado de uma IR que já mudou. O planejamento previa trocar essa proteção por validação integral das formas
  permitidas, com modelos exatos para rotinas e blocos procedurais. Na K9, o ADR-038 decidiu outro caminho: a
  validação integral exigiria um parser de PL/pgSQL e um registro de modelos ligado a cada versão dos geradores. A
  proteção ficou assim:
  - o último plano continua regenerado e comparado byte a byte, e a cadeia de SHA-256 dos modelos prende os
    anteriores;
  - um filtro de texto recusa instruções sobre objetos globais (papel, tablespace ou outro banco) e de sessão. Os
    privilégios do banco corrente que o plano inicial concede (ADR-036) passam;
  - os planos são aplicados por uma conexão que entra como `vetra_migrator`, separada da conexão administrativa que
    cria o banco temporário;
  - o catálogo dos papéis Vetra é conferido antes e depois.
- **[ADR-039](adr/039-unidade-de-trabalho-e-repositorios.md), aceito (C8 e C10), a unidade de trabalho e os repositórios.**
  - As operações e a consulta restrita, com as formas usadas pelos corpos dos exemplos, implementadas nos
    repositórios gerados e exercitadas pela sonda integrada.
  - Os erros de registro ausente e de conflito, e a forma do registro, conforme o ADR-022, §3.
  - A API da unidade de trabalho e de onde o emissor lê a chave e o `kid`.
  - O **contexto global**: blog e chat não têm tenant, e o ADR-036 exige tenant e ator UUID, reservando visitante
    e global para um contrato posterior. O ADR-039 define esse contrato sem inventar tenant para eles.
- **ADR-040 (K11 e K12), os papéis e o RLS da outbox.** O ADR-024 decide a partição e as entregas, mas não diz com
  que papel o relay lê a outbox de todos os tenants, nem se ela tem RLS. O ADR-040 decide os privilégios de quem
  grava, do relay e da manutenção, sem usar o `vetra_migrator` no runtime. Um papel global novo entra no bootstrap
  operacional do ADR-036, nunca num plano. O ADR-040 também decide como a deriva reconhece as partições
  operacionais, conferindo limites, vínculo ao pai, índices, donos e privilégios.

### Diferenças aditivas implementadas

O `Planner` e o `Migrator` usam a diferença segura por padrão. O último plano é regenerável contra o modelo
anterior, e o espelho `db/policies/0001_seguranca.sql` mostra somente a segurança completa da IR atual; a troca
atômica de políticas está no plano. O índice único de apoio é construído antes de anexar a chave única e antes
da FK, que usa `NOT VALID` e `VALIDATE`. O enum ganha um CHECK auxiliar validado antes da troca final de nomes.
Funções de transição/revisão com a mesma assinatura usam `CREATE OR REPLACE`; a instalação da revisão reúne o
lock, os triggers, os REVOKEs e as guardas num passo atômico, sem reinicializar os dados de revisão.
A substituição de trigger conserva `ENABLE ALWAYS` no mesmo passo. Tabelas novas só recebem o GRANT de DML
para a aplicação depois de toda a segurança instalada.

Remoções, renomeações, tipos físicos, preenchimento necessário, enum estreitado, tenant alterado e instruções sem
tradução têm diagnósticos próprios e não gravam plano parcial. O [guia](db-plan.md#diferenças-aditivas) especifica
passos, locks, custos, recusas e a sonda. São detalhes do ADR-038 aceito; não exigem um ADR substituto. O formato
físico e a IR permanecem nas versões atuais, e os artefatos dos exemplos conservam somente `0001`.

O [`db:migrate`](db-migrate.md) aplica os planos incrementais no banco real (K10): registro por passo em
`vetra.migration_steps`, com o começo do plano marcado depois da conferência da base pela linha `-- vetra:base`;
retomada do passo seguinte; índice da tentativa anterior aceito só com a mesma definição, e inválido refeito;
tentativas de `lock_timeout` por passo; e catálogos fora do dump conferidos antes dos passos.

### Repositórios implementados

O [Vetra Data](vetra-data.md) gera as classes de repositório e de registro a partir da IR validada, usando
o mesmo modelo de atribuições do ADR-035. As capacidades vinculadas pelo linker determinam `read` ou
`read_write`. Todas as operações terminais exigem a unidade ativa na fibra e aplicam o filtro de tenant,
inclusive na raiz; os CRMs têm ainda o RLS do plano. Registros `Data`, dinheiro e decimais são imutáveis;
consultas restritas não expõem dataset. Transições comparam o estado relido e travado no banco com o comando
da unidade antes do DML. O relógio único da operação fornece created_at em UTC com microssegundos.

Os métodos derivados de `many_to_many` travam o dono, conferem os dois registros, usam `ON CONFLICT` sobre o
par da junção na inclusão e preservam os vínculos de `include_on_create`. A sonda executa todos os corpos
Ruby de comandos e consultas dos quatro exemplos, com os argumentos vinculados, e disputa o mesmo dono
em dois backends para conferir inclusão e remoção idempotentes. As revendas são preparadas pelo migrador,
pois o plano existente só concede leitura em `dealers`; os corpos operam como `vetra_app` pelos repositórios.
São 72 verificações, todas passando no PostgreSQL 18.6 e no job de planos da CI, com a
[lista de resultados](vetra-data.md#sonda-dos-repositórios).

A avaliação de `authorize` em Ruby, permissões por campo, reautorização do estado final, eventos, histórico
e o executor das oito etapas continuam na rodada 5. Blog e chat usam contexto global e autorização da
aplicação, conforme ADR-037/039. O contrato do ADR-039 foi preservado; nenhum modelo, plano, retrato,
espelho ou grafo dos exemplos muda, e a IR permanece 0.6. Nenhuma dependência foi acrescentada.

### Riscos e verificações

- **Modelo e versões.** A introspecção e o `pg_dump` mudam entre versões principais. O modelo conferido pelo
  replay precisa sair igual no 17 e no 18, como o retrato já sai.
- **Passos fora de transação.** Com `CONCURRENTLY`, um plano deixa de ser tudo ou nada. Cada passo precisa ser
  registrado e retomável. Um índice inválido de uma falha anterior é detectado e refeito, nunca aceito. Um índice
  válido criado antes de uma queda, mas ainda não registrado, também é reconhecido.
- **Dependências de runtime.** `sequel ~> 5.110` e `pg ~> 1.7` são dependências de runtime (ADR-022, §5),
  resolvidas localmente nos cinco lockfiles. O compilador não carrega nenhuma das duas. Os grafos têm só os
  hashes de entrada/digest atualizados por causa dos lockfiles; os modelos e os artefatos SQL não mudam.
- **Partições operacionais.** A manutenção cria partições que o retrato não tem. A deriva precisa aceitá-las sem
  aceitar uma partição adulterada. A sonda roda a manutenção, depois o `db:migrate` sem deriva, e recusa uma
  partição alterada.
- **Chave do emissor.** Fica só na memória do processo: nunca vai para log, mensagem de erro ou artefato. Os
  testes geram chaves próprias. Configuração entrega bytes binários, ou o ambiente entrega kid e segredo
  hexadecimal; não há leitura de chave de artefato. A chamada de contexto é excluída dos logs SQL do Sequel.
- **Contexto global.** Blog e chat usam unidade sem emissor, tenant ou token. Ator UUID ou visitante ficam no
  contexto Ruby; as funções SQL devolvem NULL e a autorização é da aplicação. A guarda recusa tabela
  multiempresa nesse modo. Isso usa o plano atual, sem alterar banco; reforço de identidade global no banco
  exigirá plano incremental e contrato próprios.
- **Evidência da unidade de trabalho.** Testes sem banco cobrem token, sigilo, transações, parametrização,
  fibras e recusas. A sonda `sonda_vetra_data.rb` confere os efeitos no banco (23 verificações, descritas no
  [guia](vetra-data.md#sonda-no-postgresql-17-e-18)) no job de planos da CI, no PostgreSQL 17 e 18.
- **Outbox e o `xmin`.** Uma transação longa atrasa o relay de todos os tenants (ADR-008, §5). A sonda confere a
  continuidade dos intervalos com transações concorrentes e com uma transação que é desfeita.
- **Determinismo.** As partições diárias dependem da data, então não entram no plano: o plano cria o pai e a
  `DEFAULT`, e a manutenção cria as demais. Uma emissão anterior à primeira manutenção cai na `DEFAULT`, e o
  PostgreSQL recusa anexar uma partição cujo intervalo tem linhas nela. A K12 prepara as partições antes de
  liberar quem grava, e uma sonda recupera uma `DEFAULT` populada sem perder nem duplicar eventos.

### Fora da rodada 4

Ficam para a rodada 5:

- o executor das oito etapas do ADR-016 e os adaptadores, e com eles o gate do ADR-023 por comando;
- os handlers reais, com o ator de sistema (`is_system_actor`, ADR-024, §4) e a autoridade dos `calls`;
- `vetra.instances`, `vetra.schema_state` e a fase contract (ADR-025, §5), que precisam de processos com
  batimento;
- o preenchimento em lotes, as mudanças de tipo e as renomeações declaradas;
- as políticas de administração dos vínculos, dentro do limite que o ADR-037 já documenta;
- a cifra dos campos pessoais (ADR-013) e o distribuidor do live.

Cada uma dessas mudanças de modelo é recusada com código próprio pela diferença aditiva, sem plano parcial.

## Rodada 3 (concluída)

### Estado e objetivo

`Vetra::SQL::Schema` gera o DDL puro das tabelas, chaves e índices dos quatro exemplos. `db:plan` gera o
plano inicial determinístico com fase, lock e custo por passo, transação única e `lock_timeout` de 3 s.
O plano confere papéis existentes, instala `pgcrypto`, cria `vetra_private.keys` vazia e as funções
`vetra.current_tenant()`/`current_actor()`, atribui donos e concede os privilégios mínimos de runtime.
Os papéis são criados por bootstrap operacional separado; nenhum plano cria objetos globais.

`--snapshot` e `--check` aplicam o plano num banco temporário. O retrato inclui donos e privilégios,
sem `--no-owner`. Os planos dos quatro exemplos incluem o contexto, e os retratos saem desses planos. A
sonda do contexto assinado aplica o plano como `vetra_migrator`, dono do banco, sem superusuário. O
[guia](db-plan.md) descreve bootstrap, provisionamento por parâmetros, rotação e resultados esperados.
Nenhuma chave, nem mesmo de teste, entra nos artefatos.

O plano dos CRMs inclui ENABLE/FORCE RLS, tenant restritivo (inclusive raiz por id), permissivas de
escopo, revisão de autorização e triggers de transição. `db/policies/` espelha a segurança aplicada
pelo plano, com divergência recusada antes de acessar o banco. O [ADR-037](adr/037-politicas-e-transicoes-no-plano-inicial.md)
define a tradução das concessões e seus limites; o [guia](db-rls.md) descreve a sonda integrada.
O [`db:migrate`](db-migrate.md) aplica o plano num banco real como `vetra_migrator`. O emissor Ruby e a unidade de
trabalho do [Vetra Data](vetra-data.md) usam essa infraestrutura; repositórios, executor de operações e outbox
continuam pendentes.

### Entregas e dependências da rodada 3

| Tarefa | Implementador | Dependência | Entrega |
|---|---|---|---|
| C5 — mapeamento físico | Codex | — | ADR-035 aceito, modelo puro e DDL determinístico dos quatro exemplos, identificadores validados |
| K7 — planos e retrato | Claude | C5 | `db:plan`, executor comum, retrato e `--check`, CI no PostgreSQL 17/18 |
| C6 — papéis e contexto | Codex | K7 | ADR-036 aceito, bootstrap global separado, donos, privilégios, contexto HMAC e sonda no PostgreSQL 17/18 |
| C7 — RLS e integridade | Codex | C6 | ADR-037 aceito; tenant restritivo, permissivas de escopo em `db/policies/`, revisão nos planos, triggers de transição e sonda de RLS e integridade no PostgreSQL 17/18 |
| K8 — executor persistente | Claude | C7 | `db:migrate` ([guia](db-migrate.md)): hashes em `vetra.migrations`, lock consultivo, tentativas de lock_timeout, banco vazio ou registrado, deriva e retomada, com sonda no PostgreSQL 17/18 |

Só um implementa por vez no checkout compartilhado. O Claude executa as sondas no 17 e 18 na auditoria
das entregas do Codex. Plano incremental expand/migrate/contract com dados, `CONCURRENTLY`, `NOT VALID`,
lotes, repositórios sobre Sequel, outbox e `vetra.instances` ficam fora do plano inicial.

### Decisões físicas e de segurança

- IDs UUID com default v4; texto com checks de comprimento; `bigint`, `numeric(p,s)`, `boolean`, `date`,
  timestamp com fuso/microssegundos e `jsonb`. `enum` é texto com CHECK e `money` usa valor/moeda com
  check de par e moedas compatíveis. A nulidade vem de `nullable`; `created_at` vem do repositório.
- Identificadores ASCII minúsculos, até 63 bytes, validados e citados; colisões são erros. Nomes derivados
  usam hash da estrutura. Não se aceita SQL de predicado parcial ou de default fornecido pelo grafo.
- FKs de tenant implícito também são criadas. Raiz tem escopo próprio; relações entre filhas usam chave
  composta por tenant, sem duplicar junções. MATCH SIMPLE permite vendedor opcional; FKs NO ACTION,
  DEFERRABLE INITIALLY IMMEDIATE, criadas depois das tabelas e chaves únicas, inclusive em ciclos.
- Papéis pertencem ao cluster, preparados uma vez pelo operador e conferidos pelo plano. `vetra_owner`
  possui schemas/tabelas/funções e não faz login. O migrador herda esse papel, com BYPASSRLS. A aplicação
  não tem vínculos, propriedade, DDL ou acesso privado; recebe DML, USAGE e as duas funções de contexto.
- O operador cria o banco vazio com `vetra_migrator` como dono; ele aplica o plano sem superusuário.
  O plano concede CREATE no banco a `vetra_owner` para receber os schemas. `pgcrypto` é instalada em
  `vetra_private`, sem alterar EXECUTE dos membros SECURITY INVOKER; a aplicação não tem USAGE no schema.
  A CI mantém `postgres` em `--snapshot`/`--check`. Esses comandos não alteram papéis.
- Contexto `v1.kid.payload.mac`, HMAC-SHA256 validado no banco a cada instrução, sem cache de sessão,
  comparação de 32 bytes sem saída antecipada por conteúdo, validade padrão de 30 s e teto de 120 s.
  Chaves são provisionadas por parâmetros, fora do plano. `verify_only` permite rotação normal;
  `revoked` falha fechada na próxima instrução READ COMMITTED.
- A exceção da guarda de rotinas da C2 confere assinatura, schema, dono, atributos, configuração e hash
  do corpo exatos. Nome/schema isolados não dão confiança. A sonda recusa cópias e mutações.

### Riscos e verificações da rodada 3

- **Donos e retrato:** `pg_dump` da mesma versão principal do servidor; normalização conserva OWNER,
  ACLs, RLS e corpos de funções. O `--check` da CI confere os retratos no 17 e no 18.
  A sonda aplica em dois bancos e verifica que o catálogo de papéis não mudou.
- **Contexto:** o HMAC/lookup custa uma chamada por função e instrução com InitPlan; usar tenant e ator
  faz duas. O gate do ADR-023 (0,5 ms/instrução e 25% da latência do comando) requer medição com RLS,
  concorrência e pooler no 17/18. PL/pgSQL não garante tempo constante de máquina. REPEATABLE READ pode
  conservar chave revogada no snapshot; emissão/rotação e escolha de isolamento são operacionais.
- **RLS:** blog e chat não têm tenant e `db:authz:sql` os recusa (ADR-031). Não se inventa tenant nem
  revisão para eles. A sonda integrada programa 103 verificações de acessos permitidos e recusados,
  inclusive raiz, FKs, views invoker e funções invoker; execução 17/18 pertence à auditoria.
  Contexto assinado inicial exige UUIDs
  de tenant/ator; visitante/global sem essas identidades precisa de contrato posterior.
- **Escopo e transições:** sem escopo SQL, a permissiva `true` deixa o RBAC na aplicação, inclusive
  administração de vínculos. Predicados sem tradução são registrados no espelho. Os triggers invoker
  dos CRMs validam o token antes de ler cmd e não ampliam a exceção C2. Revisão é composta sem
  BEGIN/COMMIT interno, com guardas depois dos REVOKEs. Eventos e histórico continuam no runtime.
- **K8:** introspecção deve reconhecer banco vazio e cada etapa concluída, sem comparar só com o
  retrato final. Precisa recusar deriva, plano alterado e segundo migrador, conservar o lock consultivo
  e registrar DDL/conclusão atomicamente. Uma interrupção deve permitir retomada verificável.

## Regras

Todo identificador é validado antes de interpolar e usa aspas. Valores operacionais e segredos nunca
entram no SQL versionado. Cada comando novo recebe fase, lock e custo na classificação; uma ausência
é erro. Todo artefato é função dos arquivos versionados e reproduzível na CI. A IR permanece 0.6;
um recurso novo precisará de versão MENOR e `requires` conforme ADR-001. Mudança em SQL exige suíte,
grafos, gate e sonda afetada; sintaxe local da sonda não substitui aplicação no PostgreSQL.

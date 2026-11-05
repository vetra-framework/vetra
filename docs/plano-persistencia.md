# Plano da persistência

A persistência transforma o grafo em banco PostgreSQL 17+, por plano versionado, com papéis, contexto
assinado e RLS. O mapeamento físico está no ADR-035 aceito; o bootstrap dos papéis globais e o contexto
assinado estão no [ADR-036](adr/036-papeis-e-contexto-assinado.md), também aceito. Responsáveis e decisões de auditoria ficam no [quadro dos agentes](tarefas-dos-agentes.md).

## Estado e objetivo

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

O objetivo restante é aplicar os planos com `db:migrate` e isolar os tenants por RLS: com `vetra_app`,
uma sessão de um tenant lê e grava somente o que suas políticas permitem. A concessão de DML atual
não implementa esse isolamento. O runtime e os repositórios ainda não emitem contexto nem executam
operações.

## Entregas e dependências

| Tarefa | Implementador | Dependência | Entrega |
|---|---|---|---|
| C5 — mapeamento físico | Codex | — | ADR-035 aceito, modelo puro e DDL determinístico dos quatro exemplos, identificadores validados |
| K7 — planos e retrato | Claude | C5 | `db:plan`, executor comum, retrato e `--check`, CI no PostgreSQL 17/18 |
| C6 — papéis e contexto | Codex | K7 | ADR-036 aceito, bootstrap global separado, donos, privilégios, contexto HMAC e sonda no PostgreSQL 17/18 |
| C7 — RLS e integridade | Codex | C6 | Tenant restritivo, permissivas de escopo em `db/policies/`, revisão de autorização nos planos e triggers de `transitions enforce: db` |
| K8 — executor persistente | Claude | C7 | `db:migrate`, hashes em `vetra.migrations`, lock consultivo, tentativas de lock_timeout, introspecção e retomada |

Só um implementa por vez no checkout compartilhado. O Claude executa as sondas no 17 e 18 na auditoria
das entregas do Codex. Plano incremental expand/migrate/contract com dados, `CONCURRENTLY`, `NOT VALID`,
lotes, repositórios sobre Sequel, outbox e `vetra.instances` ficam fora do plano inicial.

## Decisões físicas e de segurança

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

## Riscos e verificações restantes

- **Donos e retrato:** `pg_dump` da mesma versão principal do servidor; normalização conserva OWNER,
  ACLs, RLS e corpos de funções. O `--check` da CI confere os retratos no 17 e no 18.
  A sonda aplica em dois bancos e verifica que o catálogo de papéis não mudou.
- **Contexto:** o HMAC/lookup custa uma chamada por função e instrução com InitPlan; usar tenant e ator
  faz duas. O gate do ADR-023 (0,5 ms/instrução e 25% da latência do comando) requer medição com RLS,
  concorrência e pooler no 17/18. PL/pgSQL não garante tempo constante de máquina. REPEATABLE READ pode
  conservar chave revogada no snapshot; emissão/rotação e escolha de isolamento são operacionais.
- **C7:** blog e chat não têm tenant e `db:authz:sql` os recusa (ADR-031). Não se inventa tenant nem
  revisão para eles. A sonda de RLS deve provar acessos permitidos e recusados, inclusive raiz, FKs,
  views e funções, para não passar porque ninguém acessa nada. Contexto assinado inicial exige UUIDs
  de tenant/ator; visitante/global sem essas identidades precisa de contrato posterior.
- **C7:** transições preservam suas colunas; os dois CRMs com `transitions enforce: db` ainda exigem
  triggers. Revisão de autorização deve compor o plano sem transações aninhadas: o SQL standalone já
  contém BEGIN/COMMIT e as guardas precisam continuar efetivas depois dos REVOKEs.
- **K8:** introspecção deve reconhecer banco vazio e cada etapa concluída, sem comparar só com o
  retrato final. Precisa recusar deriva, plano alterado e segundo migrador, conservar o lock consultivo
  e registrar DDL/conclusão atomicamente. Uma interrupção deve permitir retomada verificável.

## Regras

Todo identificador é validado antes de interpolar e usa aspas. Valores operacionais e segredos nunca
entram no SQL versionado. Cada comando novo recebe fase, lock e custo na classificação; uma ausência
é erro. Todo artefato é função dos arquivos versionados e reproduzível na CI. A IR permanece 0.6;
um recurso novo precisará de versão MENOR e `requires` conforme ADR-001. Mudança em SQL exige suíte,
grafos, gate e sonda afetada; sintaxe local da sonda não substitui aplicação no PostgreSQL.

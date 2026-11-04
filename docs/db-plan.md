# Planos de migração e retrato do esquema

`vetra db:plan` transforma o esquema físico do [ADR-035](adr/035-mapeamento-fisico-inicial.md) num plano versionado em
`db/plans/` e confere o retrato `db/schema.sql`, como decidem o [ADR-015](adr/015-migracoes-expand-contract.md), §1, e o
[ADR-025](adr/025-resolucao-das-questoes-do-adr-015.md), §1. Nesta rodada só existe o **plano inicial**, de um banco vazio.
Mudar o esquema de um banco que já tem plano exige o plano incremental, previsto para a rodada 4 do
[plano da persistência](plano-persistencia.md).

## Comandos

```sh
bundle exec bin/vetra db:plan --root examples/mini_crm_revendas
DATABASE_URL=postgres://postgres@127.0.0.1:5432/postgres VETRA_PG_DUMP=/usr/lib/postgresql/18/bin/pg_dump \
  bundle exec bin/vetra db:plan --snapshot --root examples/mini_crm_revendas
DATABASE_URL=... VETRA_PG_DUMP=... bundle exec bin/vetra db:plan --check --root examples/mini_crm_revendas
```

- **`db:plan`** lê `.vetra/graph.json` com as mesmas verificações do `db:authz:sql` (artefato canônico, produtor e
  fontes) e grava `db/plans/0001_inicial.sql` se ainda não houver plano. Não abre conexão. Se o plano já existe e é o
  que a IR gera, não muda nada. Se a IR passou a gerar outro esquema, falha com `db_plan_stale`: um banco que nunca
  recebeu o plano pode recomeçar removendo o arquivo; um banco aplicado precisa do plano incremental.
- **`db:plan --snapshot`** aplica os planos num banco descartável e regrava `db/schema.sql`. Como o `--check`, só aplica
  planos que a IR gera: um plano editado à mão poderia mexer em objetos do servidor inteiro (`COMMENT ON DATABASE`,
  papéis), fora do banco temporário.
- **`db:plan --check`** falha se o plano não for o que a IR gera ou se o retrato não for o resultado de aplicar os planos
  (ADR-025, §1, item 3). É o que a CI roda nos quatro exemplos, no PostgreSQL 17 e no 18.

`--snapshot` e `--check` usam o servidor de `DATABASE_URL` só para criar um banco temporário `vetra_plan_*` a partir do
`template0`, com `UTF8` e `LOCALE 'C'`. O papel precisa poder criar bancos. O banco da URL nunca é alterado, e o
temporário é removido também numa falha. A gem `pg` é exigida só nesses dois modos. Um erro de conexão ou de URL vira
`db_connection` com a classe do erro e o SQLSTATE, sem repetir a mensagem do driver, que pode conter a senha. O `pg_dump`
recebe em `--dbname` os parâmetros que a conexão temporária de fato usou e roda sem as variáveis `PG*` herdadas
(`PGSERVICE`, `PGDATABASE`, `PGHOST` e outras), para que leia o mesmo banco; a senha vai só em `PGPASSWORD`, nunca na
linha de comando. Com vários hosts na URL (por exemplo com `target_session_attrs=read-write`), a conexão ao banco
temporário e o `pg_dump` ficam fixos no servidor em que a conexão administrativa entrou, e `options` é preservado.

## Formato do plano

```sql
-- vetra:plano 0001 inicial
-- vetra:transacao unica
--
-- Gerado por `vetra db:plan` ...

-- vetra:passo 1 fase=expand lock=nenhum custo=catalogo
CREATE TABLE "public"."companies" (
  ...
);

-- vetra:passo 2 fase=expand lock=AccessExclusive custo=tabela_vazia
ALTER TABLE "public"."dealers" ADD CONSTRAINT "vt_uq_..." UNIQUE ("company_id", "id");
```

O cabeçalho dá o número e o nome do plano, que precisam ser os do arquivo (`NNNN_nome.sql`), e a unidade de transação.
`unica` significa que o plano inteiro roda numa transação, com `lock_timeout` de 3 s (ADR-015, §5): uma falha em
qualquer passo desfaz o plano todo. Cada passo é um comando e diz:

| Campo | Valores | Significado |
|---|---|---|
| `fase` | `expand`, `migrate`, `contract` | A fase do ADR-015, §2; o plano inicial só tem `expand` |
| `lock` | `nenhum` ou um modo do PostgreSQL sem o sufixo `Lock` | O lock mais forte que o passo pede numa tabela que já existe; `nenhum` quando o passo só cria um objeto novo |
| `custo` | `catalogo`, `tabela_vazia` | Só catálogo, ou um passo sobre uma tabela criada no mesmo plano, ainda sem linhas |

No plano inicial, `CREATE SCHEMA` e `CREATE TABLE` são `nenhum`/`catalogo`, `ADD CONSTRAINT ... UNIQUE` é
`AccessExclusive`, `CREATE INDEX` é `Share` e `ADD CONSTRAINT ... FOREIGN KEY` é `ShareRowExclusive`, todos
`tabela_vazia`. A classificação foi medida no PostgreSQL 18.6, aplicando os passos dos quatro exemplos um a um com as
tabelas já criadas: os 34 passos sobre tabelas existentes pediram exatamente o lock declarado, e os 13 `CREATE TABLE`
só travam a tabela nova. Um comando que o gerador emita sem classificação falha com `db_plan_step`, em vez de ir sem
lock declarado.

O leitor é estrito (`db_plan_format`): nome, cabeçalho, transação, numeração dos passos, fase, lock, custo, marcadores
`-- vetra:` desconhecidos, SQL fora de um passo, passo vazio, CRLF e qualquer diferença do formato canônico são recusados.
Assim o executor nunca precisa adivinhar onde um passo começa ou em que transação ele roda. Os marcadores só contam
entre instruções (`Vetra::SQL::StatementScanner`): uma linha `-- vetra:` dentro de um literal, como um default de texto com
várias linhas, ou dentro de um corpo `$...$` é dado do passo, e um plano cujo último passo termina dentro de um literal é
recusado.

## Retrato

`db/schema.sql` é o `pg_dump --schema-only --no-owner` do banco temporário depois dos planos, normalizado. A
normalização tira só o que depende de quem gerou e quando: comentários (inclusive as versões), `SET` de sessão,
`set_config` e as linhas `\restrict` com chave aleatória, e junta linhas vazias repetidas. Ela age apenas entre
instruções: dentro de um literal ou de um corpo de função, uma linha que começa com `--` ou `SET` e as linhas vazias
ficam intactas, para que dois esquemas diferentes nunca produzam o mesmo retrato. Nenhuma instrução de esquema,
privilégio ou política é retirada. O `pg_dump` precisa ser da mesma versão principal do servidor (`db_pg_dump`), porque um mais antigo recusa o
servidor e um mais novo poderia escrever o mesmo esquema de outro jeito. Indique o binário com `VETRA_PG_DUMP`.

`--no-owner` fica até a C6: enquanto todos os objetos pertencem a quem aplica o plano, o dono depende do servidor e não
do modelo. Quando a C6 criar os papéis do ADR-005 e der donos explícitos aos objetos, o retrato passa a incluí-los.

## Executor

`Vetra::SQL::PlanExecutor` aplica uma lista de planos numa conexão, cada plano numa transação. É o mesmo executor que o
`--snapshot` e o `--check` usam; a K8 acrescenta o registro em `vetra.migrations`, o lock consultivo, as novas tentativas
de `lock_timeout` e a verificação prévia do `db:migrate`. Uma falha diz o plano e o passo (`db_plan_apply`).

O formato só tem a transação `unica`. A rodada 4 precisa de passos fora de transação (`CREATE INDEX CONCURRENTLY`) e de
grupos transacionais; esses modos entram no formato e no executor antes dela.

## Limites

Não há plano incremental, aplicação num banco de verdade (`db:migrate`), papéis, RLS nem revisão de autorização nos
planos: chegam com a K8, a C6 e a C7. Os testes da suíte não usam banco: o banco descartável é substituído por um falso,
e a aplicação real é conferida pela CI no 17 e 18.

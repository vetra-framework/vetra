# Planos de migração e retrato do esquema

`vetra db:plan` transforma o esquema físico do [ADR-035](adr/035-mapeamento-fisico-inicial.md) num plano versionado em
`db/plans/` e confere o retrato `db/schema.sql`, como decidem o [ADR-015](adr/015-migracoes-expand-contract.md), §1, e o
[ADR-025](adr/025-resolucao-das-questoes-do-adr-015.md), §1. Cada plano é gravado com um **modelo físico versionado** em
`db/models/`, e os planos seguintes partem dele ([ADR-038](adr/038-fundacao-do-plano-incremental.md), proposto). A fundação
do plano incremental está implementada (K9): modelo, cadeia, transação por passo, contenção e convergência. A diferença
entre modelos ainda não: os exemplos só têm o plano inicial, e um modelo que mudou é recusado até a C9 do
[plano da persistência](plano-persistencia.md).

## Comandos

```sh
bundle exec bin/vetra db:plan --root examples/mini_crm_revendas
DATABASE_URL=postgres://postgres@127.0.0.1:5432/postgres VETRA_PG_DUMP=/usr/lib/postgresql/18/bin/pg_dump \
  bundle exec bin/vetra db:plan --snapshot --root examples/mini_crm_revendas
DATABASE_URL=... VETRA_PG_DUMP=... bundle exec bin/vetra db:plan --check --root examples/mini_crm_revendas
```

- **`db:plan`** lê `.vetra/graph.json` com as mesmas verificações do `db:authz:sql` (artefato canônico, produtor e
  fontes). Não abre conexão.
  - Sem plano, grava `db/plans/0001_inicial.sql` e `db/models/0001_inicial.json`.
  - Um plano inicial gravado antes do ADR-038, sem modelo, ganha o modelo que a mesma IR gera, se o plano for o
    que ela gera.
  - Se o modelo do último plano é o que a IR gera, não muda nada.
  - Se a IR passou a gerar outro esquema, o próximo plano é a diferença entre modelos. Até a C9, falha com
    `db_plan_incremental`: um banco que nunca recebeu os planos pode recomeçar removendo `db/plans` e `db/models`.
- **`db:plan --snapshot`** aplica os planos num banco descartável e regrava `db/schema.sql`. Como o `--check`, só aplica
  planos que a cadeia de modelos prende e cujo último plano a IR regenera.
- **`db:plan --check`** falha se a cadeia não conferir, se o último plano não for o que a IR gera ou se o retrato não
  for o resultado de aplicar os planos (ADR-025, §1, item 3). Com mais de um plano, também prova a convergência (ver
  abaixo). É o que a CI roda nos quatro exemplos, no PostgreSQL 17 e no 18.

Os três modos também conferem `db/policies/0001_seguranca.sql`, espelho das instruções de RLS e
transições aplicadas pelo plano. Ausência, edição ou arquivo adicional gera `db_policies_stale` antes
de acessar o banco. A primeira geração grava plano e espelho juntos; só `db/plans/` é aplicado.
O [guia de RLS e integridade](db-rls.md) descreve permissivas, limites e a sonda dos CRMs.

`--snapshot` e `--check` usam o servidor de `DATABASE_URL` só para criar um banco temporário `vetra_plan_*` a partir do
`template0`, com `UTF8`, `LOCALE 'C'` e `vetra_migrator` como dono, e para tirar o `pg_dump`. O papel da URL precisa
poder criar bancos e assumir `vetra_migrator`, o que um superusuário pode. O banco da URL nunca é alterado, e o
temporário é removido também numa falha. Os planos são aplicados por outra conexão, que **entra** como `vetra_migrator`
(ver "Contenção"). A gem `pg` é exigida só nesses dois modos. Um erro de conexão ou de URL vira
`db_connection` com a classe do erro e o SQLSTATE, sem repetir a mensagem do driver, que pode conter a senha. O `pg_dump`
recebe em `--dbname` os parâmetros que a conexão temporária de fato usou e roda sem as variáveis `PG*` herdadas
(`PGSERVICE`, `PGDATABASE`, `PGHOST` e outras), para que leia o mesmo banco; a senha vai só em `PGPASSWORD`, nunca na
linha de comando. Com vários hosts na URL (por exemplo com `target_session_attrs=read-write`), a conexão ao banco
temporário e o `pg_dump` ficam fixos no servidor em que a conexão administrativa entrou, e `options` é preservado.

O plano inicial é aplicável por **`vetra_migrator` como dono do banco, sem superusuário**, conforme o
[ADR-036](adr/036-papeis-e-contexto-assinado.md). Exige os três papéis globais preparados pelo
operador. A CI usa `postgres` em `--snapshot`/`--check` só para criar e remover os bancos temporários; os planos são
aplicados como `vetra_migrator`, com a senha de `VETRA_MIGRATOR_PASSWORD` definida para o servidor descartável.
O plano só modifica objetos no banco alvo; nunca cria nem remove papéis no cluster.

## Bootstrap e contexto assinado

Uma vez por cluster, o operador gera e executa o bootstrap, fora dos planos versionados:

```sh
bundle exec ruby -Ilib -rvetra -e 'puts Vetra::SQL::Context.roles_sql' > /tmp/vetra-papeis.sql
psql "$DATABASE_URL" -X -v ON_ERROR_STOP=1 -f /tmp/vetra-papeis.sql
```

O bootstrap cria somente papéis ausentes, sem senhas. Pode ser repetido; atributos/vínculos incompatíveis
fazem a transação falhar. `vetra_app` tem LOGIN, sem superusuário/BYPASSRLS/CREATEDB/CREATEROLE/REPLICATION
nem vínculo a outro papel. `vetra_owner` tem NOLOGIN e esses poderes desligados. `vetra_migrator` tem
LOGIN, BYPASSRLS e somente vínculo INHERIT/SET ao dono, sem ADMIN. Todos têm INHERIT. Autenticação, senhas e
`CONNECT` são operacionais; não entram em artefatos. O plano confere esses atributos antes do DDL e revoga
`CREATE`/`TEMPORARY` no banco de `PUBLIC` e da aplicação. Não use banco pertencente a `vetra_app`.

Depois, o operador cria o banco vazio com o migrador como dono, sem lhe dar CREATEDB:

```sh
psql "$DATABASE_URL" -X -v ON_ERROR_STOP=1 \
  -c "CREATE DATABASE vetra OWNER vetra_migrator TEMPLATE template0 ENCODING 'UTF8' LOCALE 'C'"
```

Na aplicação dos planos, a conexão é de `vetra_migrator` ao banco criado. A propriedade permite revogar
privilégios do banco e alterar `public` (inicialmente de `pg_database_owner`). O plano concede `CREATE`
no banco a `vetra_owner`, exigido para receber a propriedade dos schemas; o migrador pode assumir esse
papel pelo vínculo SET. `pgcrypto` é extensão confiável, instalável por quem tem `CREATE` no banco.

O dono dos schemas de aplicação, tabelas, `vetra`, `vetra_private`, `keys` e funções de contexto é
`vetra_owner`. O migrador herda seus poderes. A aplicação recebe `USAGE` nos schemas de aplicação e em
`vetra`, DML nas tabelas de aplicação e `EXECUTE` somente em `vetra.current_tenant()`/`current_actor()`;
não recebe DDL, TRUNCATE, TRIGGER, REFERENCES, acesso a `vetra_private` ou funções de revisão. `pgcrypto`
fica em `vetra_private`; seus membros conservam os donos e privilégios de EXECUTE atribuídos pelo
PostgreSQL. São SECURITY INVOKER, sem acesso próprio a segredos; a falta de USAGE no schema impede que
a aplicação os alcance. O dono do schema pode executar `hmac` pelo EXECUTE público. O plano não altera
privilégios dos membros da extensão, o que exigiria superusuário. Um banco com `pgcrypto` preexistente
não é um banco vazio aceito por este plano.

`vetra_private.keys (kid, secret, status, not_before)` nasce **vazia**. Não há chave de exemplo no plano.
O provisionamento usa conexão de `vetra_migrator` e parâmetros do driver, por exemplo:

```ruby
# kid, secret_hex e not_before vêm do provisionador; não imprima esses valores.
connection.exec_params(<<~SQL, [kid, secret_hex, 'active', not_before])
  INSERT INTO vetra_private.keys (kid, secret, status, not_before)
  VALUES ($1, decode($2, 'hex'), $3, $4::timestamptz)
SQL
```

A chave tem pelo menos 32 bytes aleatórios. Há no máximo uma `active`; `verify_only` ainda valida e
`revoked` recusa. Rotação normal troca a antiga para `verify_only` e insere a nova `active` na mesma
transação; conserva a antiga por pelo menos 5 minutos antes de removê-la. Emergência usa `revoked`.
A próxima instrução em READ COMMITTED vê a revogação; REPEATABLE READ conserva a visão antiga. O comando
operacional `keys:rotate` e a integração com `config/secrets.enc` ainda dependem do runtime.

O emissor assina `v1.<kid>.<payload>` com HMAC-SHA256 e acrescenta `.<mac>`. Payload é JSON UTF-8 em
base64url canônico sem padding, com `tenant_id`, `actor_id`, `op_id` (UUIDs canônicos minúsculos), `cmd`
(texto não vazio, até 255 caracteres), `iat` e `exp` (inteiros numéricos em segundos). `operator_id`, se
presente, também é UUID. `kid` usa 1 a 64 caracteres `[A-Za-z0-9_-]`; MAC usa base64url sem padding de
32 bytes; o token inteiro tem no máximo 8.192 bytes. Identidades nulas de visitantes/globais não fazem
parte deste contrato inicial. A emissão padrão dura 30 s, teto de 120 s. O banco verifica
`iat - 5 <= transaction_timestamp() <= exp`, `iat <= exp <= iat + 120` e `iat >= not_before`.

O cliente abre a transação mais externa e usa
`exec_params("SELECT set_config('vetra.ctx', $1, true)", [token])`. As funções STABLE SECURITY DEFINER
retornam UUID ou NULL em qualquer falha. Cada uma lê a chave e recalcula o HMAC, sem cache em variável
de sessão. A comparação percorre sempre 32 bytes, sem saída antecipada por conteúdo; não se promete
tempo constante de máquina no PL/pgSQL. Políticas devem usar `(SELECT vetra.current_tenant())` e
`(SELECT vetra.current_actor())` para executar uma vez por função/instrução. Usar as duas faz dois HMACs.
O gate de custo do ADR-023 ainda precisa da medição com RLS, concorrência e pooler no 17/18.

A guarda de autorização da C2 reconhece apenas as duas definições exatas, incluindo schema, dono,
assinatura, retorno, linguagem, atributos, `search_path` e SHA-256 do corpo. Reutiliza `vetra` somente
quando pertence a `vetra_owner`; tabelas e rotinas de revisão continuam sem substituição. Uma cópia em
outro schema, outro corpo ou outra configuração não recebe a exceção.

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
Os planos são numerados em sequência a partir de `0001`. Há dois modos (ADR-038, §2):

- **`unica`**: o plano inteiro roda numa transação, com `lock_timeout` de 3 s (ADR-015, §5). Uma falha em qualquer
  passo desfaz o plano todo. É o modo do plano inicial.
- **`por_passo`**: cada marcador termina em `transacao=sim` ou `transacao=nao`.
  - Um passo `sim` roda na sua própria transação, com `SET LOCAL lock_timeout = '3s'`. Pode ter mais de uma instrução
    quando elas precisam ser atômicas, como a troca de política.
  - Um passo `nao` roda fora de transação, com `lock_timeout` de sessão durante o passo. Tem uma só instrução,
    `CREATE [UNIQUE] INDEX CONCURRENTLY`, `DROP INDEX CONCURRENTLY IF EXISTS` ou `REINDEX INDEX CONCURRENTLY`.
    `CONCURRENTLY` em qualquer outro lugar é recusado.

```sql
-- vetra:passo 1 fase=expand lock=ShareUpdateExclusive custo=varre_tabela transacao=nao
CREATE INDEX CONCURRENTLY "vt_ix_..." ON "public"."leads" ("company_id", "created_at");
```

Cada passo diz:

| Campo | Valores | Significado |
|---|---|---|
| `fase` | `expand`, `migrate`, `contract` | A fase do ADR-015, §2; o plano inicial só tem `expand` |
| `lock` | `nenhum` ou um modo do PostgreSQL sem o sufixo `Lock` | O lock mais forte que o passo pede numa tabela que já existe; `nenhum` quando o passo só cria um objeto novo |
| `custo` | `catalogo`, `tabela_vazia`, `varre_tabela` | Só catálogo; um passo sobre uma tabela criada no mesmo plano, ainda sem linhas; ou a leitura de uma tabela existente sem bloquear escrita (`CONCURRENTLY`) |
| `transacao` | `sim`, `nao` | Só em planos `por_passo` |

No plano inicial, `CREATE SCHEMA` e `CREATE TABLE` são `nenhum`/`catalogo`, `ADD CONSTRAINT ... UNIQUE` é
`AccessExclusive`, `CREATE INDEX` é `Share` e `ADD CONSTRAINT ... FOREIGN KEY` é `ShareRowExclusive`, todos
`tabela_vazia`. A classificação foi medida no PostgreSQL 18.6, aplicando os passos dos quatro exemplos um a um com as
tabelas já criadas: os 34 passos sobre tabelas existentes pediram exatamente o lock declarado, e os 13 `CREATE TABLE`
só travam a tabela nova. Um comando que o gerador emita sem classificação falha com `db_plan_step`, em vez de ir sem
lock declarado.

Os novos passos de contexto também são `expand`: guardas `DO`, ajustes dos privilégios do banco,
`CREATE EXTENSION`, `CREATE FUNCTION`, `ALTER FUNCTION ... OWNER`, `ALTER SCHEMA ... OWNER` e
`GRANT`/`REVOKE` são `nenhum`/`catalogo`; o índice único de chave ativa é `Share`/`tabela_vazia`;
`ALTER TABLE ... OWNER` é `AccessExclusive`/`tabela_vazia`. Nenhum comando gerado fica sem classificação.
As classificações novas precisam ser conferidas pelo auditor no PostgreSQL 17/18; as medições acima
referem-se somente aos comandos de tabelas/chaves/índices/FKs do mapeamento físico.

Na segurança, ENABLE/FORCE RLS e CREATE POLICY são `AccessExclusive`; CREATE TRIGGER, ENABLE ALWAYS
TRIGGER e LOCK TABLE da revisão são `ShareRowExclusive`; a carga inicial de revisões é `RowExclusive`.
São passos `expand` com custo `tabela_vazia`. As guardas de catálogo são `nenhum`/`catalogo`, e a guarda
de armazenamento usa `AccessShare`/`tabela_vazia`. Os locks de política e trigger seguem os fontes do
PostgreSQL 17 em [policy.c](https://github.com/postgres/postgres/blob/REL_17_STABLE/src/backend/commands/policy.c)
e [tablecmds.c](https://github.com/postgres/postgres/blob/REL_17_STABLE/src/backend/commands/tablecmds.c);
a conferência de execução no 17/18 pertence à auditoria.

O leitor é estrito (`db_plan_format`): nome, cabeçalho, transação, numeração dos passos, fase, lock, custo, marcadores
`-- vetra:` desconhecidos, SQL fora de um passo, passo vazio, CRLF e qualquer diferença do formato canônico são recusados.
Assim o executor nunca precisa adivinhar onde um passo começa ou em que transação ele roda. Os marcadores só contam
entre instruções (`Vetra::SQL::StatementScanner`): uma linha `-- vetra:` dentro de um literal, como um default de texto com
várias linhas, ou dentro de um corpo `$...$` é dado do passo, e um plano cujo último passo termina dentro de um literal é
recusado.

## Modelos e cadeia

`db/models/NNNN_nome.json` acompanha cada plano, com o mesmo número e nome. É JSON canônico gerado pelo `db:plan`:
um arquivo editado à mão é recusado (`db_model_format`). Ele guarda:

- `state`: o esquema depois do plano, isto é, o que o plano inicial da IR daquele momento criaria num banco vazio.
  Contém as tabelas estruturadas do ADR-035 e, na ordem, o tipo, o objeto e o SHA-256 de cada instrução de
  infraestrutura, segurança e revisão. Não guarda SQL executável; serve de base para a diferença do próximo plano;
- `plans`: o SHA-256 de cada plano até este;
- `previous`: o SHA-256 do modelo anterior.

Os planos antigos não são regenerados, porque a IR que os gerou já mudou. A cadeia os prende dentro da árvore: um
plano ou modelo editado, trocado ou removido falha com `db_model_chain` antes de qualquer acesso ao banco. Quem
recalcula os hashes na mesma árvore passa pela cadeia, então a história é ancorada na base integrada: o gate
(`script/check_graph_compatibility.rb --base`) recusa um plano ou modelo da base alterado ou removido, um plano
novo cujo número não vem depois dos da base e mais de um plano novo por aplicação na mesma integração.

Só o último plano é recalculado e comparado byte a byte. Com mais de um plano, o `--check` aplica todos num banco e
o plano inicial da IR atual em outro, e os dois esquemas precisam ser iguais (`db_plan_convergence`). É isso que
mostra que o modelo descreve o banco. A comparação ignora só a ordem entre as definições de cada `CREATE TABLE`,
porque uma coluna acrescentada fica no fim da tabela. Cada definição é comparada inteira, com os literais intactos,
e o retrato continua exato.

## Contenção

Os planos commitados rodam no servidor de quem executa `--check` ou `--snapshot`. Antes da integração, o gate ainda
não conferiu a história, então quatro camadas limitam o que um plano editado alcança (ADR-038, §3):

- **Filtro de texto** (`db_plan_forbidden`), em todo plano lido, inclusive no `db:migrate`.
  - Recusa instruções sobre papéis, membros de papéis, bancos, tablespaces, assinaturas e publicações, privilégios
    `ON DATABASE`, `ON TABLESPACE` e `ON PARAMETER`, e `ALTER SYSTEM`, `SET ROLE`, `SET SESSION AUTHORIZATION`,
    `COPY`, `LOAD`, `set_config` e as funções que leem arquivos ou encerram sessões.
  - Recusa também instruções de topo que mudam a sessão ou a transação do executor (`SET`, `COMMIT`, `BEGIN` e
    outras).
  - Lê só o código: comentários, literais e identificadores entre aspas ficam de fora. Uma coluna `"copy"`, um
    default, um valor de `enum` ou a mensagem de um `RAISE` passam; os corpos `$...$` são lidos como código. Um
    identificador entre aspas chamado como função é conferido pelo nome, mesmo com comentários antes do parêntese
    (`pg_catalog."set_config" /* x */ (...)`). Identificadores e literais com escape Unicode (`U&"..."`) são
    recusados.
  - É um filtro e não uma prova: um `EXECUTE` com o comando num literal escapa dele.
- **Poderes conferidos pelo executor.** Antes de qualquer texto dos planos, a conexão administrativa roda a guarda de
  papéis do gerador atual (a que o plano traz é editável). Depois do login, o executor confere que a sessão é
  `vetra_migrator` sem superusuário, `CREATEROLE`, `CREATEDB` nem `REPLICATION`. Uma falha é `db_plan_role`, sem
  nenhum passo aplicado.
- **Servidor descartável para o migrador.** Antes de criar o banco temporário, o comando recusa com `db_plan_role`
  um servidor com um objeto global que `vetra_migrator` administraria. Contam os papéis que ele exerce: ele mesmo, os
  que herda ou assume por `SET`, `PUBLIC` e `pg_database_owner`, que o dono do banco temporário recebe. O servidor é
  recusado quando tem:
  - um banco ou tablespace de que um desses papéis seja dono, ou com privilégio com GRANT OPTION para um deles;
  - um parâmetro com qualquer privilégio para um deles;
  - outra sessão de `vetra_migrator` aberta em qualquer banco, porque o papel pode encerrar as próprias sessões
    (`pg_terminate_backend`) sem mudar catálogo. Uma sessão que entre durante a aplicação fica fora da garantia.
- **Login como `vetra_migrator`**, dono só do banco temporário, sem superusuário, `CREATEROLE` nem `CREATEDB`. Não há
  `SET ROLE` que o plano possa desfazer. A sonda confere que `RESET ROLE`, `SET SESSION AUTHORIZATION`,
  `CREATE ROLE` e `ALTER DATABASE postgres`, montados em partes, são negados pelo servidor (`db_plan_apply`).
  - A senha vem só de `VETRA_MIGRATOR_PASSWORD`. O login não herda senha, `passfile` nem `service` da URL
    administrativa.
  - Durante a conexão, `PGPASSWORD`, `PGPASSFILE`, `PGSERVICE`, `PGSERVICEFILE` e `PGUSER` saem do ambiente, para
    que a libpq não complete o login com credenciais do administrador.
- **Catálogo** antes e depois, mesmo quando um plano falha (`db_plan_global`):
  - `pg_roles` e `pg_auth_members` dos papéis Vetra, e nome e atributos de todos os papéis do servidor;
  - os parâmetros de todos os papéis em todos os bancos;
  - dono, ACL e atributos dos outros bancos, e dono, ACL e opções dos tablespaces;
  - as ACLs de parâmetros;
  - com superusuário, numa consulta separada, o hash da senha.

  Um `GRANT` sem efeito sobre outro banco, por exemplo, ainda grava a ACL padrão explícita no lugar de `NULL`, e o
  catálogo acusa.

Sem o bootstrap dos papéis, ou sem uma conexão administrativa que possa criar o banco para `vetra_migrator`, o comando
falha com `db_plan_role`. Também falha assim quando o login do migrador é recusado; nesse caso, defina
`VETRA_MIGRATOR_PASSWORD`.

A sonda [`script/sonda_plano_incremental.rb`](../script/sonda_plano_incremental.rb) confere isso no PostgreSQL 17 e
18, junto com um plano `por_passo` aplicado, a convergência de dois planos com índice e com coluna nova num exemplo
copiado, a recusa de um servidor em que o migrador já administra outro banco, um tablespace ou um parâmetro,
inclusive por `pg_database_owner`, com uma sessão do migrador aberta noutro banco ou com o migrador promovido a
superusuário (18 verificações).

## Retrato

`db/schema.sql` é o `pg_dump --schema-only` do banco temporário depois dos planos, normalizado, **com donos**. A
normalização tira só o que depende de quem gerou e quando: comentários (inclusive as versões), `SET` de sessão,
`set_config` e as linhas `\restrict` com chave aleatória, e junta linhas vazias repetidas. Ela age apenas entre
instruções: dentro de um literal ou de um corpo de função, uma linha que começa com `--` ou `SET` e as linhas vazias
ficam intactas, para que dois esquemas diferentes nunca produzam o mesmo retrato. Nenhuma instrução de esquema,
privilégio ou política é retirada. O `pg_dump` precisa ser da mesma versão principal do servidor (`db_pg_dump`), porque um mais antigo recusa o
servidor e um mais novo poderia escrever o mesmo esquema de outro jeito. Indique o binário com `VETRA_PG_DUMP`.

Donos e ACLs são parte da comparação. Não são retirados nem substituídos pela normalização. Os retratos
dos quatro exemplos são regenerados com `--snapshot` sempre que os planos mudam, e o `--check` da CI os confere no
PostgreSQL 17 e 18.

O cabeçalho tem uma linha por plano com o SHA-256 do dump normalizado depois daquele plano (ADR-038, §4). O
`--snapshot` aplica os planos um a um e tira o dump depois de cada um:

```text
-- vetra:base 0001_inicial sha256=3a99…
```

O `db:migrate` compara o banco só com o corpo do retrato. Na K10, a linha do último plano aplicado será a base
conferida antes de aplicar o seguinte.

## Executor

`Vetra::SQL::PlanExecutor` aplica uma lista de planos numa conexão: um plano `unica` numa transação, e um `por_passo`
passo a passo, cada `sim` na sua transação e cada `nao` fora dela. É o mesmo executor que o `--snapshot` e o `--check`
usam. O [`db:migrate`](db-migrate.md) acrescenta o registro em `vetra.migrations`, o lock consultivo, as novas
tentativas de `lock_timeout` e a verificação prévia. Uma falha diz o plano e o passo (`db_plan_apply`).

O `db:migrate` ainda aplica só o plano inicial. Um plano depois dele, ou um plano `por_passo`, é recusado com
`db_migrate_incremental` até a K10, que traz o registro por passo e a retomada.

## Limites

A diferença entre modelos é da C9, e a aplicação incremental num banco de verdade é da K10; a aplicação do plano
inicial é do [`db:migrate`](db-migrate.md). O plano inicial gera RLS, revisão e triggers de
transição, com os limites de RBAC descritos no [guia](db-rls.md). Os testes da suíte não usam banco;
a aplicação real exige as sondas e o `--check` da matriz PostgreSQL 17/18.

## Sonda do contexto

Depois do bootstrap, execute em cluster descartável:

```sh
DATABASE_URL=... bundle exec ruby script/sonda_contexto_assinado.rb
```

A sonda conecta como superusuário para criar dois bancos novos com `OWNER vetra_migrator` e removê-los
no `ensure`. Aplica o plano gerado do mini CRM com revendas sob `SET SESSION AUTHORIZATION vetra_migrator`;
confere current_user/session_user, propriedade do banco e ausência de superusuário/CREATEDB/CREATEROLE.
Confere os atributos dos papéis sem alterá-los e compara o catálogo de papéis antes/depois. Provisiona
chaves aleatórias apenas em memória, por parâmetros e como migrador. São esperadas **58 verificações**:

- Aplicação repetida em bancos distintos, chaves inicialmente vazias, donos fixos, DML funcionando e
  acesso efetivo somente às duas funções; membros de `pgcrypto` continuam SECURITY INVOKER com EXECUTE
  público, inacessíveis à aplicação sem USAGE no schema. Sem leitura/escrita privada, CREATE, TEMP, TRUNCATE, DDL ou SET ROLE
  privilegiado pela aplicação. As sessões usam `SET LOCAL SESSION AUTHORIZATION`, para não emprestar
  o SET ROLE do superusuário à identidade de teste.
- Token válido, tolerância de relógio e validade de 120 s retornam tenant/ator. Ausência, chave ausente,
  expiração, futuro fora da tolerância, duração excessiva, exp anterior a iat, kid desconhecido,
  adulteração de MAC/payload, sintaxe/claims inválidos e not_before incompatível retornam dois NULLs.
- `SET LOCAL` não sobrevive à transação; `verify_only` e nova `active` validam; `revoked` recusa na
  instrução seguinte de uma transação aberta; chave removida recusa.
- A revisão instalada pelo plano aceita as funções exatas e recusa corpo parecido, cópia em outro schema,
  search_path ou dono alterados. As guardas são reexecutadas; as mutações são revertidas.

Sintaxe e testes sem banco podem ser verificados localmente. A evidência de execução das 58 verificações
e a estabilidade dos retratos no 17/18 dependem da auditoria com PostgreSQL; não são resultados da suíte.

O plano dos CRMs também instala revisão, RLS e triggers de transição, sem transação aninhada. Blog e
chat permanecem sem tenant/RLS de tenant/revisão. Execute ainda
`DATABASE_URL=... bundle exec ruby script/sonda_rls_integridade.rb`: são 103 verificações de acessos
permitidos e recusados, detalhadas no [guia](db-rls.md#sonda-no-postgresql-17-e-18).

# ADR-038: Fundação do plano incremental

- Status: aceito
- Aceite: 2026-11-06, pelo Claude por delegação do mantenedor, após a auditoria da K9 (rodadas 1 a 5 devolvidas, rodada 6 aprovada), com a sonda do plano incremental em 18/18 no PostgreSQL 18.6.
- Data: 2026-11-05
- Depende de: ADR-015 (§1, §5 e §6), ADR-025 (§1), ADR-035, ADR-036 e ADR-037
- Relacionados: [plano da persistência](../plano-persistencia.md), rodada 4 (K9, C9 e K10)

## Contexto

Até a rodada 3 só existe o plano inicial, de um banco vazio. O `db:plan` regenera esse plano da IR e o compara
byte a byte com `db/plans/0001_inicial.sql`. Essa igualdade tem duas funções:

- prova que o plano é o que a IR pede;
- protege o servidor em que `--check` e `--snapshot` aplicam o plano: só SQL do gerador é executado, e um plano
  editado à mão não chega ao banco.

Com o segundo plano, as duas funções deixam de valer como estão:

- O `0002` é a diferença entre dois estados. Sem saber de qual estado o banco parte, o `db:plan` não consegue
  calculá-lo.
- O `0001` deixa de ser regenerável: a IR atual já pede outro esquema, e um plano aplicado não pode mudar
  (o `db:migrate` recusa um plano alterado, K8).
- Um passo com `CREATE INDEX CONCURRENTLY` não roda dentro de transação (ADR-015, §4). O plano deixa de ser uma
  transação única, e o executor descartável hoje envolve cada plano inteiro numa.

O ADR-025, §1 manda o `db:plan` comparar a IR com o retrato `db/schema.sql` e reserva a introspecção à
verificação. O retrato é texto do `pg_dump`, normalizado só entre instruções. Interpretá-lo para extrair
colunas, chaves, políticas e funções seria um segundo parser de SQL, frágil a cada versão do PostgreSQL.

## Decisão

### 1. Modelo físico versionado

O `db:plan` grava, junto com cada plano, um **modelo** em `db/models/NNNN_nome.json`, com o mesmo número e nome
do plano. O modelo é gerado, nunca editado à mão: o leitor recusa um arquivo fora do formato canônico.

```json
{
  "format": "vetra-db-model",
  "version": 1,
  "plan": { "file": "0001_inicial.sql", "sha256": "…" },
  "plans": [ { "file": "0001_inicial.sql", "sha256": "…" } ],
  "previous": null,
  "state": {
    "tables": [ … ],
    "statements": [ { "kind": "policy", "object": "crm.leads.vt_policy_…", "sha256": "…" } ]
  }
}
```

- `state` descreve o esquema que o banco tem depois deste plano. É o esquema que o plano inicial da IR daquele
  momento criaria num banco vazio:
  - `tables` são as tabelas estruturadas do `Vetra::SQL::Schema`: colunas, chaves, índices, checks e FKs;
  - `statements` resume, na ordem do plano inicial, cada instrução da infraestrutura, da segurança e da revisão
    (ADR-036 e ADR-037): o tipo, o objeto que ela define, quando define um, e o SHA-256 do texto.

  O modelo cobre, portanto, a segurança e a infraestrutura, não só as tabelas das entidades.
- O modelo não guarda SQL executável. Ele serve para calcular a diferença (C9), e nenhuma parte dele é aplicada.
- `plans` é a cadeia de todos os planos até este, com o SHA-256 de cada arquivo. `previous` aponta para o modelo
  anterior, também por SHA-256. Cada modelo repete a cadeia do anterior e acrescenta o próprio plano.

**Relação com o ADR-025, §1.** Este ADR complementa o §1; não o substitui.

- O próximo plano é calculado contra o modelo do último plano, sem conexão.
- O retrato continua sendo o resultado de aplicar `db/plans/` num banco descartável. O `--check` continua
  conferindo esse resultado.
- A introspecção continua só na verificação, onde o §1 a pôs.

O que muda é o artefato que o `db:plan` lê para saber de onde parte: o modelo, e não o texto do retrato. A
equivalência entre modelo, planos e retrato é provada pelo `--check` (§3). O modelo do último plano tem de ser o
modelo que a IR atual gera, ou há diferença pendente.

### 2. Transação por passo

A segunda linha do plano passa a aceitar dois modos:

- `-- vetra:transacao unica` é o modo de hoje: todos os passos numa transação, com `lock_timeout` de 3 s. Os
  marcadores de passo não mudam.
- `-- vetra:transacao por_passo`: cada marcador ganha `transacao=sim` ou `transacao=nao`.
  - Um passo `sim` roda na própria transação, com `SET LOCAL lock_timeout = '3s'`. Um passo pode ter mais de uma
    instrução quando elas precisam ser atômicas, como a troca de política do ADR-015, §4.
  - Um passo `nao` roda fora de transação, com `lock_timeout` de sessão definido antes e restaurado depois. Ele
    tem exatamente uma instrução, e só das formas que o PostgreSQL exige fora de transação:
    `CREATE [UNIQUE] INDEX CONCURRENTLY`, `DROP INDEX CONCURRENTLY` e `REINDEX INDEX CONCURRENTLY`. O leitor
    recusa qualquer outra.

O plano inicial continua `unica`, e o texto dos quatro exemplos não muda. A classificação ganha o custo
`varre_tabela`, para passos que varrem uma tabela existente sem bloquear escrita (`CONCURRENTLY` e,
na C9, `VALIDATE CONSTRAINT`).

### 3. Verificação sem regenerar a história

Os planos antigos não podem ser regenerados, então a garantia passa a ter seis partes:

1. **O último plano é regenerado.** Enquanto o modelo da IR for o modelo do último plano, o plano é recalculado
   e precisa ser idêntico ao arquivo:
   - o `0001` com o plano inicial da IR, como hoje;
   - um plano `N > 1` com a diferença entre o modelo `N-1` e a IR (C9).
2. **A cadeia prende os anteriores dentro da árvore.** Cada modelo carrega o SHA-256 de todos os planos até ele.
   Editar um plano antigo, trocar a ordem ou remover um plano quebra a cadeia antes de qualquer acesso ao banco.
   Quem recalcula os hashes na mesma árvore passa por ela: a cadeia pega a edição acidental, não a deliberada.
3. **A base integrada ancora a história.** O gate de integração (`script/check_graph_compatibility.rb --base`),
   que roda antes de cada push e na CI, compara `db/plans/` e `db/models/` de cada aplicação com a base:
   - todo plano e modelo que a base tem precisa continuar byte a byte;
   - um arquivo novo só pode ter número maior que os da base;
   - cada aplicação ganha **no máximo um plano novo** por integração, inclusive uma aplicação que a base ainda não
     tem. Só o último plano é regenerado: com dois planos novos, o do meio entraria sem nunca ter sido conferido.

   Assim, todo SQL que chega a um banco é a regeneração do último plano pelo gerador atual ou um plano
   idêntico ao que a base integrada já tem, que foi conferido por regeneração quando era o último, na integração em
   que entrou. É a mesma garantia da rodada 3, estendida à história. Dois planos novos vão em duas integrações.
4. **Filtro de instruções globais.** Em todos os planos, o leitor recusa instruções sobre objetos que não são do
   banco: papéis, membros de papéis, outros bancos, tablespaces, `ALTER SYSTEM`, `SET ROLE` e
   `SET SESSION AUTHORIZATION`. Recusa também privilégios `ON DATABASE`, `ON TABLESPACE` e `ON PARAMETER`, `COPY`,
   `LOAD`, `set_config`, assinaturas e publicações, e as funções que leem arquivos ou encerram sessões. Os
   privilégios do banco corrente que o plano inicial concede vão num `EXECUTE` com literal e não passam pelo filtro.
   - O filtro lê só o código: comentários, literais e identificadores entre aspas não executam nada e ficam de
     fora. Uma coluna `"copy"`, um default ou valor de `enum` e a mensagem de um `RAISE` passam.
   - Um identificador entre aspas chamado como função é conferido pelo nome, mesmo com comentários antes do
     parêntese: `pg_catalog."set_config" /* x */ (...)` continua sendo `set_config`.
   - Identificadores e literais com escape Unicode (`U&"..."`, `U&'...'`) são recusados: o gerador nunca os emite,
     e o nome real só aparece depois de decodificado.
   - Os corpos `$...$` continuam lidos como código.
   - É um filtro e não uma prova: um `EXECUTE` com o comando num literal escapa dele.
5. **Contenção.** O `--check` e o `--snapshot` criam o banco temporário com `vetra_migrator` como dono e aplicam
   os planos numa conexão que **entra** como `vetra_migrator`, separada da conexão administrativa. Não usam
   `SET ROLE` nem `SET SESSION AUTHORIZATION`, que o próprio plano poderia desfazer. É o mesmo papel e o mesmo
   dono do banco do `db:migrate` (ADR-036): sem superusuário, `CREATEROLE` nem `CREATEDB`.
   - **Os poderes do migrador são conferidos pelo executor.** Antes de qualquer texto dos planos, a conexão
     administrativa roda a guarda de papéis do gerador atual (ADR-036), porque a que o plano inicial traz é
     editável. Depois do login, o executor confere que a sessão é `vetra_migrator` sem superusuário, `CREATEROLE`,
     `CREATEDB` nem `REPLICATION`. Uma falha é `db_plan_role`, e nenhum passo é aplicado.
   - **O servidor precisa ser descartável para o migrador.** Antes de criar o banco temporário, a conexão
     administrativa recusa (`db_plan_role`) um servidor com um objeto global que `vetra_migrator` administraria. Os
     papéis que ele exerce são ele mesmo, os que herda ou assume por `SET`, `PUBLIC` e `pg_database_owner`, que o
     dono do banco temporário recebe implicitamente. O servidor é recusado quando tem:
     - um banco ou tablespace de que um desses papéis seja dono, ou em que um deles tenha privilégio com GRANT
       OPTION;
     - um parâmetro com qualquer privilégio para um deles, porque `SET` ou `ALTER SYSTEM` num parâmetro alcança o
       servidor.

     Com o banco temporário como a única coisa que o migrador administra, ele não altera outro banco, tablespace
     nem parâmetro.
   - **Nenhuma outra sessão do migrador.** O papel pode encerrar ou cancelar as próprias sessões em qualquer banco
     (`pg_terminate_backend`), sem privilégio e sem mudar catálogo. O servidor com outra sessão de `vetra_migrator`
     aberta é recusado (`db_plan_role`) antes de criar o banco temporário. Uma sessão que entre durante a aplicação
     continua alcançável: é um efeito de disponibilidade, não de integridade, e fica fora da garantia, coberto só pela
     exigência de servidor descartável.
   - A senha, quando o servidor exige uma, vem só de `VETRA_MIGRATOR_PASSWORD`. O login do migrador não herda a
     senha, o `passfile` nem o `service` da URL administrativa. Durante a conexão, `PGPASSWORD`, `PGPASSFILE`,
     `PGSERVICE`, `PGSERVICEFILE` e `PGUSER` ficam fora do ambiente, para que os defaults da libpq não completem
     o login com credenciais do administrador.
   - A conexão administrativa só cria e remove o banco, confere o catálogo e tira o `pg_dump`.
6. **Catálogo conferido.** A conexão administrativa lê o catálogo antes e depois da aplicação, também quando um
   plano falha, e uma diferença falha com `db_plan_global`:
   - `pg_roles` e os vínculos em `pg_auth_members` dos três papéis Vetra, e nome e atributos de todos os papéis do
     servidor, para acusar um papel criado ou promovido;
   - os parâmetros de todos os papéis em todos os bancos (`pg_db_role_setting`), exceto no banco temporário;
   - dono, ACL, limite de conexões e atributos de todos os outros bancos do servidor;
   - dono, ACL e opções dos tablespaces, e as ACLs de parâmetros (`pg_parameter_acl`);
   - com superusuário, numa consulta separada, o hash da senha em `pg_authid`. Sem superusuário a senha fica fora
     da comparação, e a consulta comum não lê `pg_authid`.

Com mais de um plano, o `--check` também prova a **convergência**. Aplicar todos os planos num banco e aplicar o
plano inicial da IR atual em outro precisa produzir o mesmo esquema. É isso que mostra que o modelo descreve o
banco, e não só a IR. A comparação ignora só a ordem entre as definições de cada `CREATE TABLE`: uma coluna
acrescentada por `ADD COLUMN` fica no fim da tabela, e o plano inicial ordena as colunas pelo nome. Cada definição
de coluna ou restrição é comparada inteira, com os literais de várias linhas intactos. O resto do dump (donos, ACLs,
RLS, índices e funções) é comparado na ordem, e o retrato segue exato.

**Por que não uma validação integral com modelos exatos de rotinas.** O plano da rodada 4 previa validar cada
instrução contra todas as formas permitidas, com modelos exatos para os blocos `DO` e os corpos de função. Isso
exige duas coisas:

- um parser de PL/pgSQL;
- um registro permanente de modelos ligado a cada versão dos geradores, porque um plano antigo foi gerado por
  um gerador antigo.

Regenerar o último plano dá a mesma exatidão no momento em que ele entra, e a base integrada a conserva depois.
A contenção e o catálogo limitam o que uma edição alcança num servidor de desenvolvimento antes da integração. A
mudança de rumo é decisão do Claude nesta tarefa e fica registrada no quadro.

### 4. Base de cada plano

O retrato ganha, no cabeçalho, uma linha por plano com o SHA-256 do `pg_dump` normalizado depois daquele plano:

```text
-- vetra:base 0001_inicial sha256=…
```

- O `--snapshot` aplica os planos um a um e tira o dump depois de cada um.
- O `--check` confere as linhas e o corpo.
- O `db:migrate` confere o banco contra o corpo, como na K8, sem as linhas `-- vetra:base`.
- Na K10, o `db:migrate` confere o banco contra a linha do último plano aplicado antes de aplicar o seguinte. É
  a verificação prévia por introspecção do ADR-025, §1, item 4, para um banco com planos pendentes.

### 5. Registro por passo e retomada (K10)

Num plano `por_passo`, o `db:migrate` registra cada passo concluído. A K10 implementa, e o desenho é este:

- Um passo `sim` é registrado na própria transação, então existe com o registro ou não existe.
- Um passo `nao` é registrado depois do comando, e o efeito dele é conferido pela forma:
  - um índice criado com `CONCURRENTLY` e ainda não registrado é aceito se existir e for válido. Um índice
    inválido é removido com `DROP INDEX CONCURRENTLY` e criado de novo;
  - uma queda entre o comando e o registro, portanto, não perde nem duplica o passo.
- A retomada parte do passo seguinte ao último registrado. A base do plano, conferida antes do primeiro passo,
  não é conferida de novo no meio dele.

### 6. O que fica com a C9 e a K10

- A diferença entre modelos e os passos aditivos ficam com a C9. Até lá, um modelo que mudou é recusado com
  `db_plan_incremental`, como hoje um plano inicial que mudou é recusado com `db_plan_stale`.
- O espelho `db/policies/` continua com um arquivo por banco vazio. A C9 decide como uma troca de política
  aparece nele.
- O `db:migrate` recusa qualquer plano depois do inicial, de qualquer modo de transação, com
  `db_migrate_incremental` até a K10.

## Alternativas rejeitadas

- **Introspectar o banco descartável para planejar.** Colocaria introspecção no planejamento, contra o
  ADR-025, §1. Também exigiria PostgreSQL no `db:plan`.
- **Interpretar `db/schema.sql`.** Seria um segundo parser de SQL, dependente da versão do `pg_dump`.
- **Guardar a IR inteira de cada plano.** Os planos antigos poderiam ser regenerados, mas só com o gerador
  daquela época. Uma mudança no gerador quebraria a história.
- **Aplicar como superusuário com `SET ROLE`.** O plano pode executar `RESET ROLE`.

## Consequências

- Cada plano tem um modelo ao lado, e os quatro exemplos ganham `db/models/0001_inicial.json`. O texto dos planos
  não muda.
- O retrato ganha as linhas `-- vetra:base`, e os quatro retratos são regenerados.
- O `--check` e o `--snapshot` exigem que `vetra_migrator` possa entrar no servidor, e um servidor descartável em
  que ele não administre outro banco. A conexão administrativa precisa poder criar um banco cujo dono é esse
  papel: ser superusuário ou poder assumir `vetra_migrator`. A CI define uma senha para o papel antes dos dois
  comandos.
- O filtro de instruções globais vale para todos os planos, inclusive no `db:migrate`.
- O gate passa a conferir a história dos planos e modelos contra a base.

## Garantia

| Garantia | Nível | Mecanismo |
|---|---|---|
| O plano novo é o que a IR pede | Estrutural | Regeneração do último plano a partir do modelo anterior e da IR |
| Um plano ou modelo já integrado não muda | Verificável por testes | Gate contra a base; a cadeia de SHA-256 pega a edição acidental na árvore |
| O modelo descreve o banco | Verificável por testes | Replay igual ao retrato e convergência com o plano inicial da IR, sem a ordem das colunas |
| Um plano não altera outros bancos nem outros papéis no `--check` | Transacional, limitada | Conexão como `vetra_migrator`, que só administra o banco temporário (precondição) |
| Uma alteração no próprio papel ou em outro banco é apontada | Verificável por testes | Catálogo de papéis e de bancos antes e depois |
| O login do migrador não usa credenciais do administrador | Verificável por testes | Parâmetros e ambiente da libpq limpos na conexão |
| Um passo fora de transação tem uma só instrução, de forma conhecida | Estrutural | Leitor do plano |
| Um `EXECUTE` com o comando num literal | **Fora da garantia** do filtro | Coberto pela contenção e pelo catálogo, não pelo filtro |
| Encerrar uma sessão do migrador que entre no servidor durante a aplicação | **Fora da garantia** | Sessões abertas antes são recusadas; o servidor do `--check` tem de ser descartável |
| Uma edição de plano antes da integração, num servidor que o migrador administra | **Fora da garantia** | Recusada pela precondição; o servidor do `--check` tem de ser descartável |

Testes de aceitação:

1. O `db:plan` grava o plano e o modelo; o modelo é canônico e a cadeia confere.
2. Editar um plano antigo, o modelo ou a cadeia é recusado antes de qualquer acesso ao banco. O gate recusa um
   plano ou modelo da base alterado ou removido, um plano novo com número que não vem depois dos da base e dois
   planos novos na mesma aplicação.
3. Um plano `por_passo` com um passo `nao` aplica `CREATE INDEX CONCURRENTLY` no banco descartável. O leitor
   recusa um passo `nao` com duas instruções ou com outra forma.
4. O filtro recusa `ALTER ROLE`, `SET ROLE`, `COPY` e `COMMENT ON DATABASE` em qualquer plano, e aceita uma coluna
   `"copy"` e a mensagem de um `RAISE`.
5. O `--check` aplica os planos como `vetra_migrator`. Um plano que altera o próprio papel ou a ACL de outro banco
   falha com `db_plan_global`. Um servidor em que o migrador já é dono de outro banco é recusado antes de criar o
   temporário.
6. Com dois planos, o `--check` confere a convergência e as linhas `-- vetra:base`, inclusive com uma coluna
   acrescentada no fim da tabela.
7. O `db:migrate` recusa um segundo plano, `unica` ou `por_passo`.

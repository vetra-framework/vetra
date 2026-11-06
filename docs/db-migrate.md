# Aplicar planos com db:migrate

`vetra db:migrate` aplica num banco de verdade os planos de `db/plans/`, como decidem o
[ADR-015](adr/015-migracoes-expand-contract.md), §1 e §5, e o [ADR-025](adr/025-resolucao-das-questoes-do-adr-015.md),
§1 e §2, e o [ADR-038](adr/038-fundacao-do-plano-incremental.md), §4 e §5. Ele usa os mesmos planos que o
[`db:plan`](db-plan.md) gera e confere: o plano inicial, que se aplica a um banco vazio, e os planos incrementais
`NNNN_expand.sql`, aplicados passo a passo sobre o banco que o plano anterior deixou. O banco é comparado com o corpo de
`db/schema.sql`; as linhas `-- vetra:base` do cabeçalho são a base de cada plano.

```sh
DATABASE_URL=postgres://vetra_migrator@db.exemplo/app VETRA_PG_DUMP=/usr/lib/postgresql/18/bin/pg_dump \
  bundle exec bin/vetra db:migrate --root examples/mini_crm_revendas
```

O banco alvo é o de `DATABASE_URL`, e a conexão precisa ser do `vetra_migrator` (ADR-005): o comando recusa outro
papel, inclusive um superusuário, com `db_migrate_role`. O operador roda antes o bootstrap dos papéis e cria o banco
vazio com o migrador como dono ([guia de planos](db-plan.md)). O `pg_dump` da mesma versão principal do servidor é
exigido, como no `db:plan --check`.

## O que ele faz

1. Confere que a conexão é do `vetra_migrator` e pega o lock consultivo de sessão do migrador. Se outro `db:migrate`
   segura o lock, recusa na hora (`db_migrate_locked`) em vez de esperar. O lock fica com a conexão até o fim e sai
   também numa falha.
2. Lê os planos e os confere contra a IR, como o `--check`: só se aplica plano que a IR gera.
3. Lê `vetra.migrations`. Os registros precisam ser exatamente os primeiros planos, na ordem, com o mesmo hash SHA-256
   do texto do plano. Um plano editado depois de aplicado é recusado (`db_migrate_altered`), e um registro sem o arquivo
   correspondente também (`db_migrate_unknown`).
4. Sem plano pendente, compara o esquema do banco com `db/schema.sql` (o `pg_dump` normalizado, sem a tabela de
   registro) e confere pelo catálogo os privilégios do próprio banco, que o `pg_dump --schema-only` não mostra:
   `vetra_app` sem `CREATE` nem `TEMPORARY` e sem ser dono, `vetra_owner` com `CREATE` (ADR-036). Subscriptions, large
   objects, parâmetros por banco ou por papel no banco e rótulos de segurança, que o dump também não mostra ao migrador,
   contam como deriva; um `session_replication_role = replica` por banco, por exemplo, desligaria a checagem das FKs. Uma mudança feita
   fora dos planos é recusada como deriva (`db_migrate_drift`), sem alterar nada.
5. Com plano pendente, confere a base dele antes do primeiro passo. A base do plano inicial é um banco vazio: nenhum objeto com OID a partir de
   16384 (`FirstNormalObjectId`, o primeiro OID de objetos criados depois do `initdb`) em nenhum catálogo local com OID,
   o que cobre tabelas, tipos, collations, operadores, extensões, gatilhos de evento, privilégios padrão e qualquer
   outra espécie sem lista à mão (o migrador não lê `pg_user_mapping`, mas um mapeamento exige um servidor estrangeiro,
   visível em `pg_foreign_server`), o schema `public` com o dono e os privilégios padrão, e nenhuma subscription do banco,
   large object, parâmetro por banco ou por papel no banco (`ALTER DATABASE/ROLE ... SET`) nem rótulo de segurança, que
   a regra do OID não alcança (um large object aceita OID explícito baixo; os outros ficam em catálogos sem `oid` próprio
   ou compartilhados). Um banco com objetos e sem
   registro é recusado (`db_migrate_not_empty`), com os catálogos encontrados, sem aplicar nada. A base de um plano
   seguinte é o retrato depois do anterior: o SHA-256 do `pg_dump` normalizado do banco precisa ser o da linha
   `-- vetra:base` do plano anterior. Senão, é deriva (`db_migrate_drift`), e nada é alterado.
6. Um plano de transação única (o inicial) roda numa transação, com `lock_timeout` de 3 s, e grava o registro na mesma
   transação: plano e registro entram juntos ou nenhum dos dois. O primeiro plano cria `vetra.migrations` depois de
   criar o schema `vetra`; a aplicação não lê nem grava essa tabela.
7. Um plano por passo roda passo a passo e registra cada um em `vetra.migration_steps` (plano, passo e SHA-256 da
   instrução). Logo depois da conferência da base, o começo do plano fica registrado como o passo 0, com o SHA-256 do
   plano inteiro. O último passo grava também a linha do plano em `vetra.migrations`. Num banco já migrado, os
   privilégios do banco e os objetos que o dump não mostra (parâmetros, subscriptions, large objects e rótulos) são
   conferidos antes de qualquer passo pendente, inclusive numa retomada.
   - Um passo `sim` e o seu registro entram na mesma transação.
   - Um passo `nao` (`CREATE INDEX CONCURRENTLY`) roda fora de transação, com `lock_timeout` de sessão, e é
     registrado logo depois, numa transação curta, também com `lock_timeout`. Antes de rodar, o índice do passo é
     procurado:
     - um índice válido com a definição do passo é o efeito de uma tentativa anterior que caiu antes do registro, e é
       aceito. A definição é a que o próprio servidor escreve (`pg_get_indexdef`), comparada com a que o passo pede:
       um `INCLUDE`, classe de operadores, collation, ordem, `NULLS NOT DISTINCT`, predicado ou parâmetro de
       armazenamento a mais a torna outra;
     - um índice inválido com essa definição (um `CONCURRENTLY` interrompido) é removido com `DROP INDEX CONCURRENTLY`
       e criado de novo;
     - qualquer outro índice com o mesmo nome é deriva.
8. Quando o lock estoura (`55P03`), a unidade é desfeita e repetida depois de 1, 2, 4, 8 e 16 s, com variação de 25%.
   A unidade é o plano inteiro num plano de transação única, e o passo num plano por passo. Esgotadas as seis
   tentativas, nada dessa unidade fica registrado (`db_migrate_lock_timeout`). O registro do começo de um plano por
   passo também é repetido assim. A saída do comando informa só as repetições que de fato aconteceram.
9. Depois de aplicar, compara de novo o esquema e os privilégios do banco. Uma diferença é apontada como deriva, com a
   mensagem de que o plano já foi aplicado e registrado.

## Retomada

Um plano de transação única é retomado inteiro: uma conexão derrubada ou uma falha no meio desfazem o plano e o seu
registro, e a execução seguinte encontra o banco como estava.

Um plano por passo é retomado do passo seguinte ao último registrado. Os passos registrados precisam ser o começo
do plano, com o mesmo SHA-256 de cada instrução: um passo editado depois de aplicado é recusado
(`db_migrate_altered`). Passos a mais, ou de um plano que não é o próximo, também são recusados
(`db_migrate_unknown`). A base só é conferida antes do primeiro passo, porque no meio do plano o banco está, por
definição, entre dois retratos. O marcador do começo (passo 0) diz que ela já foi conferida: um primeiro passo fora
de transação pode ter criado o índice e caído antes do registro, e a retomada reconhece o índice em vez de acusar a
base. O marcador guarda o SHA-256 do plano, e um plano editado no meio da aplicação é recusado. O estado final é
conferido no fim.

O `pg_dump` da conferência usa `--lock-wait-timeout=3s`: com um DDL de outra sessão na fila, falha em vez de esperar
sem limite.

## Verificação

`test/db_migrate_test.rb` cobre a lógica sem banco, com um banco falso: aplicação e registro, segunda execução,
migrador ocupado, papel errado, banco não vazio, plano alterado, registro desconhecido, deriva antes e depois de
aplicar, novas tentativas com espera e esgotamento, e planos que a IR não gera. A
[sonda](../script/sonda_db_migrate.rb) aplica o plano do mini CRM com revendas num PostgreSQL real, como
`vetra_migrator`, e confere: aplicação com o hash registrado; segunda execução sem mudanças; `vetra_app` sem acesso ao
registro; segundo migrador recusado; superusuário e aplicação recusados; deriva recusada; plano alterado recusado pelo
hash; `CREATE` e `TEMPORARY` no banco dados à aplicação, large object e parâmetro por banco criados depois recusados como
deriva; banco com tabela, collation, privilégio padrão, subscription, publicação, large object de OID baixo, parâmetro
por banco ou parâmetro de papel no banco recusado sem aplicar nada; nova tentativa que aplica depois que o bloqueio sai; tentativas
esgotadas sem nada aplicado, com retomada; e conexão derrubada no meio do plano sem nada aplicado, com retomada. Ela roda
no job `db-plan` da CI, no PostgreSQL 17 e 18.

A [sonda incremental](../script/sonda_db_migrate_incremental.rb) aplica, sobre o mini CRM com o plano inicial e 2.000
leads, um segundo plano com uma coluna nova e dois índices `CONCURRENTLY`, e um plano só de índices. Ela confere
(16 verificações):

- o registro de cada passo e do plano, e a segunda execução sem mudanças;
- `vetra_app` sem acesso a `vetra.migration_steps`;
- a retomada depois de uma queda em cada passo, inclusive depois do DDL fora de transação e antes do registro;
- a queda depois do primeiro índice de um plano que começa por índice;
- o índice inválido refeito, e o homônimo com outra definição, inclusive com uma coluna em `INCLUDE`, recusado como
  deriva;
- a base alterada e um parâmetro do banco posto depois do plano inicial recusados antes do primeiro passo;
- o `lock_timeout` repetido por passo até o lock sair;
- o índice de mesmo nome em outra tabela recusado como deriva.

Roda no mesmo job da CI.

## Limites

Não há `--dry-run`, relatório de estado nem fase contract (`vetra.instances`, ADR-025 §5). A deriva é conferida pelo
esquema inteiro do retrato e pelos catálogos citados acima, não só pelos objetos que um plano toca. Um índice válido
encontrado na retomada é aceito só com a definição inteira do passo, como o servidor a escreve. Ficam fora da garantia os comentários em objetos do sistema
e no próprio banco, que não mudam execução nem permissões. Os rótulos de segurança são conferidos pelo catálogo, mas a
sonda não os cria, porque exigem um provider carregado (como o `sepgsql`).

# Aplicar planos com db:migrate

`vetra db:migrate` aplica num banco de verdade os planos de `db/plans/`, como decidem o
[ADR-015](adr/015-migracoes-expand-contract.md), §1 e §5, e o [ADR-025](adr/025-resolucao-das-questoes-do-adr-015.md),
§1 e §2. Ele usa o mesmo plano que o [`db:plan`](db-plan.md) gera e confere. Nesta versão só existe o plano inicial, que
se aplica a um banco vazio; o plano incremental está em construção na rodada 4 do [plano da persistência](plano-persistencia.md): até a K10, um plano depois do inicial, ou um plano `por_passo`, é recusado com `db_migrate_incremental`, sem alterar nada. O banco é comparado com o corpo de `db/schema.sql`, sem as linhas `-- vetra:base` do cabeçalho.

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
5. Com plano pendente, exige um banco vazio, conferido antes de qualquer passo: nenhum objeto com OID a partir de
   16384 (`FirstNormalObjectId`, o primeiro OID de objetos criados depois do `initdb`) em nenhum catálogo local com OID,
   o que cobre tabelas, tipos, collations, operadores, extensões, gatilhos de evento, privilégios padrão e qualquer
   outra espécie sem lista à mão (o migrador não lê `pg_user_mapping`, mas um mapeamento exige um servidor estrangeiro,
   visível em `pg_foreign_server`), o schema `public` com o dono e os privilégios padrão, e nenhuma subscription do banco,
   large object, parâmetro por banco ou por papel no banco (`ALTER DATABASE/ROLE ... SET`) nem rótulo de segurança, que
   a regra do OID não alcança (um large object aceita OID explícito baixo; os outros ficam em catálogos sem `oid` próprio
   ou compartilhados). Um banco com objetos e sem
   registro é recusado (`db_migrate_not_empty`), com os catálogos encontrados, sem aplicar nada.
6. Aplica cada plano pendente numa transação, com `lock_timeout` de 3 s, e grava o registro na mesma transação: plano e
   registro entram juntos ou nenhum dos dois. O primeiro plano cria `vetra.migrations` depois de criar o schema `vetra`;
   a aplicação não lê nem grava essa tabela.
7. Quando o lock estoura (`55P03`), a transação é desfeita e repetida depois de 1, 2, 4, 8 e 16 s, com variação de
   25%. Esgotadas as seis tentativas, nada fica aplicado (`db_migrate_lock_timeout`), e uma nova execução retoma do
   começo do plano.
8. Depois de aplicar, compara de novo o esquema e os privilégios do banco. Uma diferença é apontada como deriva, com a
   mensagem de que o plano já foi aplicado e registrado.

Como cada plano roda numa transação única, a retomada é sempre do plano inteiro: uma conexão derrubada ou uma falha no
meio desfazem o plano e o seu registro, e a execução seguinte encontra o banco como estava. Os passos fora de transação
da rodada 4 vão precisar de registro por passo.

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

## Limites

Não há plano incremental, `--dry-run`, relatório de estado nem fase contract (`vetra.instances`, ADR-025 §5). A deriva é
conferida pelo esquema inteiro do retrato e pelos catálogos citados acima, não só pelos objetos que um plano toca: basta
para o plano inicial e será refinada com o plano incremental. Ficam fora da garantia os comentários em objetos do sistema
e no próprio banco, que não mudam execução nem permissões. Os rótulos de segurança são conferidos pelo catálogo, mas a
sonda não os cria, porque exigem um provider carregado (como o `sepgsql`).

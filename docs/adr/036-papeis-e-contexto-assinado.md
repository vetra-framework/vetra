# ADR-036: Papéis globais, donos e contexto assinado no plano inicial

- Status: aceito
- Aceite: 2026-11-05, pelo Claude por delegação do mantenedor, após a auditoria da C6 (devolvida na rodada 1, aprovada na rodada 2), com o plano aplicado pelo `vetra_migrator` no PostgreSQL 18.6.
- Data: 2026-11-05
- Depende de: ADR-002 (§3), ADR-005 (§1 a §4), ADR-023, ADR-031 e ADR-035

## Contexto

Papéis pertencem ao cluster PostgreSQL. Um plano aplicado por `db:plan --snapshot` ou `--check` precisa
alterar apenas o banco temporário, inclusive na segunda execução. Donos dependentes do usuário que aplica
o plano tornariam o retrato instável. As funções de contexto são `SECURITY DEFINER` de um dono poderoso,
forma que a guarda conservadora de rotinas do ADR-031 recusa.

## Decisão

### Papéis e bootstrap operacional

`Vetra::SQL::Context.roles_sql` gera um bootstrap separado, executado pelo operador uma vez por cluster.
Cria papéis ausentes, sem senha; recusa atributos ou vínculos incompatíveis nos existentes, sem corrigi-los
silenciosamente. Pode ser repetido. O plano nunca cria, altera, concede nem remove papéis. Confere antes
de qualquer DDL PostgreSQL 17+ e estes atributos:

| Papel | LOGIN | INHERIT | SUPERUSER / CREATEDB / CREATEROLE / REPLICATION | BYPASSRLS | Vínculos de saída |
|---|---|---|---|---|---|
| `vetra_app` | sim | sim | não | não | nenhum |
| `vetra_migrator` | sim | sim | não | sim | somente `vetra_owner`, com INHERIT e SET, sem ADMIN |
| `vetra_owner` | não | sim | não | não | nenhum |

Senhas, autenticação e `CONNECT` são operacionais. Depois do bootstrap, o operador cria o banco vazio
com `OWNER vetra_migrator` (comando no [guia](../db-plan.md#bootstrap-e-contexto-assinado)). O migrador
aplica o plano inicial sem superusuário, CREATEDB ou CREATEROLE, em conformidade com o ADR-002 §3 e o
ADR-005. Ser dono do banco permite revogar `CREATE` e `TEMPORARY` de `PUBLIC` e `vetra_app` e alterar
o schema `public`, inicialmente pertencente a `pg_database_owner`. O plano concede `CREATE` no banco a
`vetra_owner`, requisito do PostgreSQL para transferir a esse papel a propriedade dos schemas; o
migrador já pode assumi-lo pelo vínculo SET. Nenhum outro banco é alterado. Os papéis compartilhados
ficam para o operador, nunca para a limpeza do banco temporário. A exclusão de um banco não remove os
papéis. `--snapshot`/`--check` continuam usando `postgres` na CI para criar os bancos temporários;
essa capacidade administrativa do executor de testes não é requisito do plano.

### Donos e privilégios

`vetra_owner` possui os schemas de aplicação (inclusive `public`), as tabelas, `vetra`, `vetra_private`,
`keys` e as duas funções de contexto. Índices e constraints acompanham as tabelas. O migrador herda esse
papel e tem BYPASSRLS para backfills. A aplicação não pode herdá-lo nem assumi-lo.

O plano revoga privilégios de `PUBLIC` e da aplicação nos objetos Vetra criados, depois concede à aplicação
somente `USAGE` nos schemas de aplicação e em `vetra`, DML nas tabelas de aplicação e `EXECUTE` em
`vetra.current_tenant()` e `vetra.current_actor()`. Não concede `CREATE`, `TRUNCATE`, `TRIGGER`,
`REFERENCES`, acesso a `vetra_private` ou execução das funções de revisão. Privilégios padrão de terceiros
continuam sujeitos às guardas de revisão; não se usa `GRANT ... ON ALL TABLES` para a aplicação.

`pgcrypto` é instalado pelo plano em `vetra_private`, sem `IF NOT EXISTS`: banco vazio é pré-condição;
uma instalação anterior em outro schema exige tratamento explícito. Seus membros pertencem ao dono
que o PostgreSQL atribui à extensão confiável; não são reatribuídos e seus privilégios de `EXECUTE` não
são alterados. Revogá-los exigiria superusuário, pois o migrador possui a extensão, mas não seus membros.
Essas funções são SECURITY INVOKER e não acessam a tabela de chaves nem outro segredo do Vetra. A
aplicação não tem `USAGE` em `vetra_private`, portanto não pode alcançá-las, mesmo que
`has_function_privilege(..., 'EXECUTE')` seja verdadeiro; `vetra_owner` tem acesso pela propriedade do schema.
Mantém-se o HMAC de `pgcrypto` previsto no ADR-005, sem implementar a primitiva criptográfica em PL/pgSQL.
O retrato inclui donos explícitos, sem `--no-owner`; a normalização não remove `OWNER TO` nem ACLs.

### Token e chaves

São **quatro** componentes ASCII, separados por ponto: `v1.<kid>.<payload>.<mac>` (a descrição do
ADR-005 diz três, mas seu formato tem quatro). `kid` tem 1 a 64 caracteres `[A-Za-z0-9_-]`. Payload é
JSON UTF-8 em base64url canônico sem padding; MAC são 32 bytes de HMAC-SHA256, também em base64url sem
padding, sobre os bytes UTF-8 de `v1.<kid>.<payload>`. Limite total: 8.192 bytes.

O payload é objeto com `tenant_id`, `actor_id` e `op_id` UUIDs canônicos minúsculos, `cmd` textual não
vazio (até 255 caracteres), `iat` e `exp` numéricos inteiros não negativos. `operator_id`, quando presente,
também é UUID canônico. Esta versão exige tenant e ator identificados; contexto de visitante/global sem
essas identidades exige contrato posterior. Campos adicionais assinados não dão poderes por si sós.
O emissor usa validade padrão de 30 s, com teto rígido de 120 s no verificador. Confere-se
`iat - 5 <= transaction_timestamp() <= exp`, `iat <= exp <= iat + 120` e `iat >= not_before`.

`vetra_private.keys (kid text PK, secret bytea, status text, not_before timestamptz)` exige segredo com
pelo menos 32 bytes e status `active`, `verify_only` ou `revoked`. Há no máximo uma chave `active`.
Nenhuma chave ou token é gerado no plano. Provisionamento e rotação usam parâmetros com o migrador,
em transação: chave antiga passa a `verify_only`, nova passa a `active`; a antiga permanece ao menos
5 minutos antes de ser removida. Emergência usa `revoked`, visível na instrução seguinte sob READ COMMITTED;
um snapshot antigo de REPEATABLE READ conserva sua visão (limite do isolamento PostgreSQL).

As duas funções retornam UUID, são PL/pgSQL, `STABLE SECURITY DEFINER`, `PARALLEL UNSAFE`, com
`search_path = pg_catalog, pg_temp`. Cada uma valida o token inteiro e só então retorna sua identidade.
Não há cache em GUC, tabela temporária ou sessão. Ausência, sintaxe inválida, chave ausente/revogada,
assinatura ou claims inválidos retornam `NULL`, sem explicar a causa. Compara-se o MAC em 32 iterações
com XOR/OR, sem saída antecipada pelo conteúdo; isto não promete tempo constante de máquina no interpretador.
As políticas devem usar subconsulta não correlacionada `(SELECT vetra.current_tenant())`/`current_actor()`:
um HMAC e uma leitura por função e instrução, inclusive duas verificações quando se usam as duas identidades.
O custo completo do ADR-023 segue sujeito à medição no 17/18 com concorrência, RLS e pooler.

### Exceção exata na guarda de rotinas

A guarda exclui do fecho de escalada somente as duas definições conhecidas: schema `vetra` com dono
`vetra_owner`, nome e assinatura sem argumentos, retorno UUID, dono `vetra_owner`, linguagem PL/pgSQL,
atributos de segurança/volatilidade/paralelismo, configurações exatas e SHA-256 dos bytes de `prosrc`.
O hash é derivado do mesmo corpo que o gerador usa, sem catálogo de hashes editado à mão. A lista não
confia em nome, comentário, prefixo ou schema isoladamente. Corpo, assinatura, dono ou configuração
diferente entram novamente no fecho conservador da C2; helpers arbitrários continuam recusados.

A revisão pode usar `vetra` já criado pelo plano somente se pertencer ao dono esperado e ainda não
contiver a tabela de revisões; não recria nem substitui rotinas. A verificação de execução das funções de
revisão usa a mesma exceção exata. Schemas customizados da API de autorização continuam exigindo schema novo.

## Alternativas rejeitadas

- Criar papéis no plano e removê-los no `ensure`: afeta objetos globais, concorre com outros bancos e não
  é reversível com `DROP DATABASE`; uma segunda execução pode encontrar papéis em uso.
- Omitir donos ou normalizá-los removendo SQL: esconderia uma diferença de segurança do retrato.
- Dar DDL, propriedade ou acesso à tabela de chaves à aplicação: permite contornar a fronteira.
- Guardar resultado validado em variável de sessão: forjável e proibido pelo ADR-005.
- Liberar qualquer definer em `vetra` ou com nome conhecido: permite substituir o corpo por código arbitrário.
- Chave de exemplo no plano ou fixture: segredos são dados operacionais, inclusive nos testes.
- Exigir superusuário para revogar `EXECUTE` dos membros de `pgcrypto`: incompatível com o ADR-002 §3,
  desnecessário com o schema privado e funções SECURITY INVOKER.
- Implementar HMAC com `sha256()` nativo: dispensaria a extensão, mas duplicaria a primitiva já prevista
  no ADR-005, sem benefício para os privilégios exigidos; a extensão confiável atende ao migrador dono do banco.

## Consequências e garantia

Geração e classificação dos passos são determinísticas e testadas sem banco. A sonda C6 aplica o plano
gerado em dois bancos de propriedade de `vetra_migrator`, com `SET SESSION AUTHORIZATION vetra_migrator`
durante toda a aplicação, e confere que current_user/session_user não têm superusuário/CREATEDB/CREATEROLE.
Provisiona chaves aleatórias só em memória por parâmetros, verifica identidades, privilégios,
rotação, negação por padrão e mutações da exceção. Exige cluster descartável e bootstrap operacional;
remove seus bancos, não papéis preexistentes. O guia registra a execução no 17 e no 18 como auditoria
necessária. RLS, políticas de escopo, revisão nos planos e triggers de transição pertencem à C7.

Referências do PostgreSQL: [CREATE EXTENSION](https://www.postgresql.org/docs/17/sql-createextension.html),
[ALTER SCHEMA](https://www.postgresql.org/docs/17/sql-alterschema.html),
[pgcrypto](https://www.postgresql.org/docs/17/pgcrypto.html),
[SECURITY DEFINER](https://www.postgresql.org/docs/17/sql-createfunction.html) e
[catálogo pg_proc](https://www.postgresql.org/docs/17/catalog-pg-proc.html).

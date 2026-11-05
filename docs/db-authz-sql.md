# SQL de revisão de autorização

`db:authz:sql` gera o SQL inicial de revisão por tenant do ADR-030. É um gerador sem conexão ao banco;
o runtime live continua pendente. `db:plan` compõe essa revisão com contexto, RLS e transições.

## Gerar para revisão

Na raiz do repositório, com os grafos reconstruídos pelo compilador atual:

```sh
bundle exec bin/vetra db:authz:sql --root examples/mini_crm_revendas > /tmp/vetra-authz.sql
```

O SQL vai somente para stdout; avisos e erros vão para stderr. Falhas não emitem SQL parcial. O comando
não altera arquivos da aplicação, não lê `DATABASE_URL`, não abre conexão e não executa o SQL.

O artefato precisa ser canônico, corresponder aos fontes e ter o produtor Vetra/Ruby do pacote. A leitura
não avalia novamente o DSL nem chama operações. Os hashes conferem integridade, não autenticidade: o
artefato e o SQL continuam sujeitos à revisão.

Os padrões são schema `vetra`, proprietário `vetra_owner` e aplicação `vetra_app`. Para mudar os nomes:

```sh
bundle exec bin/vetra db:authz:sql --root examples/mini_crm_revendas \
  --sql-schema infra --owner-role data_owner --app-role web_app
```

Nomes aceitam letras minúsculas, números e sublinhado, começam por letra e têm até 63 bytes. As opções
de SQL só valem neste comando; `--sources`, `--format` e `--fail-on-breaking` são recusadas.
Saídas: 0 para geração concluída, 1 para erro de pacote/grafo/geração e 2 para uso incorreto da CLI.

## O que é gerado

O cabeçalho identifica o digest do grafo, a aplicação e as tabelas selecionadas. A seleção é a união de
`policy.reads`, inclusive junções, mais a raiz do tenant. É conservadora: alterações em campos que não
mudam a autorização também podem incrementar a revisão. No mini CRM de revendas, entram `companies`,
`dealers`, `leads`, `memberships` e `users`, com 15 triggers no total.

A instalação do SQL segue esta ordem:

1. Abre transação e configura `lock_timeout = 3s` e `search_path` fixo.
2. Confere PostgreSQL 17+, papéis e ausência de vínculo da aplicação com o proprietário. Recusa também
   qualquer papel que a aplicação possa assumir por `SET ROLE` com `SUPERUSER`, `BYPASSRLS` ou `CREATEROLE`,
   e `ADMIN OPTION` utilizável: o de qualquer papel herdado por um papel que ela pode assumir, inclusive ela
   própria (depois de `SET ROLE`, valem as heranças do papel assumido). Com ele, a
   aplicação concederia a si própria, depois da instalação, um papel que hoje não pode assumir. Um `ADMIN` preso
   atrás de um vínculo `INHERIT FALSE, SET FALSE` não conta, porque a aplicação não consegue exercê-lo. Recusa
   ainda o uso de `pg_create_subscription` e a posse de subscriptions, pelo mesmo critério: o aplicador da
   replicação lógica não dispara triggers por instrução, nem `ENABLE ALWAYS`. E recusa o uso de
   `pg_execute_server_program`, `pg_write_server_files` e `pg_read_server_files`, que alcançam arquivos e
   programas do servidor por fora das permissões SQL.
3. Obtém locks `SHARE ROW EXCLUSIVE` nas tabelas selecionadas, em ordem estável.
4. Confere tabelas comuns, ausência de herança/partições, coluna de tenant não nula e tipo compatível com
   o ID da raiz; a raiz precisa de PK simples em `id`. Recusa propriedade pela aplicação.
5. Cria o schema (ou valida `vetra` preexistente com dono `vetra_owner`), `authz_revisions` e funções/triggers de inserção, atualização e exclusão. Os triggers
   ficam `ENABLE ALWAYS`: disparam também com `session_replication_role = replica`, que suprime triggers
   comuns e pode ser concedido a um papel comum com `GRANT SET ON PARAMETER`.
6. Restringe privilégios; revoga `TRUNCATE`, `TRIGGER` e `REFERENCES` das tabelas protegidas e recusa esses
   poderes (`REFERENCES` também por coluna), escrita nas revisões, execução das funções
   ou criação de objetos na infraestrutura, inclusive por privilégios padrão. A recusa vale para a aplicação e
   para todo papel que ela possa assumir por `SET ROLE` (`pg_has_role(..., 'SET')`), inclusive concessões
   `WITH INHERIT FALSE, SET TRUE`, cujos privilégios não aparecem em `has_table_privilege` da aplicação mas
   ficam disponíveis depois de um `SET ROLE`. Sem isso, um `TRUNCATE` obtido assim apagaria vínculos sem
   incrementar a revisão, porque `TRUNCATE` não dispara os triggers de `DELETE`.
7. Audita as funções e procedimentos `SECURITY DEFINER` em `pg_proc`, depois da criação e da restrição dos
   privilégios da infraestrutura. Começa pelos papéis assumíveis pela aplicação e calcula um fecho recursivo:
   para cada definer executável por um papel alcançado, acrescenta o dono e seus papéis assumíveis.
   `EXECUTE` conta diretamente, por herança ou por `PUBLIC` (padrão do PostgreSQL). Repete até não alcançar
   papéis novos; `UNION` elimina repetições e encerra ciclos. Assim, uma entrada de dono sem poder também é
   recusada se esse dono pode executar outro definer que chega a um dono perigoso, mesmo sem `EXECUTE` da
   aplicação na rotina interna. Confere os poderes dos donos alcançados, seus papéis assumíveis e heranças:
   `TRUNCATE` e `TRIGGER` nas tabelas protegidas, `REFERENCES` também por coluna; propriedade das tabelas ou
   de seus schemas; acesso ao papel proprietário da infraestrutura; `SUPERUSER`, `BYPASSRLS`, `CREATEROLE`,
   `ADMIN OPTION` utilizável, criação/posse de subscriptions e os três papéis de acesso ao servidor do passo 2.
   Na infraestrutura, confere também escrita em `authz_revisions` (inclusive por coluna), `EXECUTE` nas
   funções novas e `CREATE` no schema. A propriedade conta mesmo sem ACL: permite desabilitar triggers ou
   remover o schema com `CASCADE`; o dono da infraestrutura pode alterar as revisões. A recusa lista schema,
   nome, argumentos e dono das rotinas alcançáveis que conduzem a esses poderes, incluindo entradas,
   intermediárias e rotinas de dono perigoso. Uma segunda recursão percorre as permissões no sentido inverso
   para compor essa lista. As duas recursões guardam somente OIDs de papéis, sem enumerar caminhos; os donos
   distintos e as chamadas são materializados, e os poderes são conferidos uma vez por papel alcançado.
8. Varre os IDs existentes da raiz para criar revisões zero e confirma a transação.

DML comum nas tabelas protegidas é permitido também aos donos alcançados por definers: `INSERT`, `UPDATE`
e `DELETE` disparam os triggers `ENABLE ALWAYS` e incrementam a revisão. Isso inclui concessões de
`INSERT` e `UPDATE` por coluna. O mesmo modelo de poderes perigosos vale para a aplicação e para esses donos.

A guarda de rotinas fica depois dos `REVOKE`s para conferir os privilégios efetivos dos objetos novos,
incluindo concessões padrão globais do instalador a donos alcançados pelo fecho, sem precisar reconstruir as
regras de `pg_default_acl`. As funções de trigger criadas pelo SQL também são consideradas, mas só entram
no fecho se um papel alcançado ainda tiver `EXECUTE`: a revogação de `PUBLIC` e da aplicação evita a recusa
na instalação normal. Todas as guardas continuam dentro da mesma transação; uma recusa desfaz a instalação.

A auditoria de rotinas é conservadora: verifica poderes, sem interpretar corpos ou conceder exceções a
schemas/extensões. Mesmo um corpo inofensivo é recusado quando seu dono tem esses poderes ou pode chegar a
eles por outros definers. Uma cadeia cujos donos não têm nem alcançam poderes perigosos permite instalar;
uma rotina privilegiada também permite instalar quando nenhum papel alcançável consegue executá-la.
A recusa **não depende de `USAGE` no schema da rotina**: ela pode ser chamada por outra rotina, e as
permissões de acesso podem mudar depois. Esse critério conservador permanece intencional.
A cadeia `SET` de cada dono também é recusada por precaução, conforme o critério de papéis da K5;
isso **não** significa que `SET ROLE` funcione
dentro de um definer. O PostgreSQL o proíbe (a sonda confere SQLSTATE `42501`), tanto na função quanto em
chamadas sob esse contexto. Veja [SET ROLE](https://www.postgresql.org/docs/18/sql-set-role.html).

Há somente a exceção exata das duas funções de contexto do ADR-036, sem revogação automática de rotinas externas. Revise a lista da recusa e revogue
`EXECUTE` antes de tentar instalar novamente, incluindo `PUBLIC`, cada papel que empresta a permissão e
os donos intermediários que dão acesso a rotinas internas:

```sql
REVOKE EXECUTE ON FUNCTION legado.limpar_vinculos(integer) FROM PUBLIC, vetra_app, papel_assumivel;
REVOKE EXECUTE ON PROCEDURE legado.limpar_tudo() FROM PUBLIC, vetra_app, papel_assumivel;
REVOKE EXECUTE ON FUNCTION legado.rotina_interna() FROM dono_intermediario;
```

Revogar somente de `vetra_app` não remove uma concessão de `PUBLIC` ou de outro papel. A instalação aborta
inteira na recusa e preserva as permissões externas para o operador decidir. As funções de revisão já
existem nessa conferência, com seus privilégios restringidos.

As tabelas e os papéis devem existir antes. O instalador precisa dos privilégios de migração sobre esses
objetos e de atribuir as funções ao proprietário. O proprietário deve ser `NOLOGIN NOSUPERUSER NOBYPASSRLS
NOCREATEROLE`; a aplicação, distinta dele, deve ser `NOSUPERUSER NOBYPASSRLS NOCREATEROLE`. O gerador não
cria ou altera papéis, não gera RLS e não concede DML novo sobre as tabelas da aplicação.

O SQL bloqueia escritas durante a instalação e varre a raiz. A espera pelo lock é limitada; o tempo de
execução e o volume da varredura precisam de revisão. Uma aplicação real exige o plano e a verificação
de deriva previstos nos ADRs 015/025, ainda ausentes. Esta saída inicial não oferece deploy sem parada.

O tenant é lido de `id` na raiz e do campo `entity.tenant.field` nas demais tabelas. As relações de transição
fornecem o conjunto distinto de tenants: novos no INSERT, antigos no DELETE e união no UPDATE. O UPSERT
incrementa a revisão armazenada e o NOTIFY informa somente o tenant. Os dois pertencem à transação da escrita.

O ID físico é convertido para texto na revisão. São aceitos UUID, texto e inteiros do PostgreSQL, com tipos
e modificadores iguais nas colunas de vínculo e na raiz. As revisões não têm FK para a raiz: excluir e
recriar um tenant mantém o contador anterior. Tipos personalizados e outros formatos de ID ficam fora
desta instalação inicial.

## API e verificação

```ruby
result = Vetra::SQL::Authorization.new(document, schema: 'infra').generate
result.sql       # SQL standalone congelado, com BEGIN/COMMIT
result.statements # mesmas instruções sem transação, SETs de sessão ou cabeçalho, para compor o plano
result.tables    # entidades, tabelas físicas e colunas do tenant
result.warnings  # diagnósticos do grafo
```

A API valida o grafo e copia sua entrada, sem acessar fontes ou banco. A CLI acrescenta a verificação do
pacote. IRs 0.1/0.2/0.3/0.4 são aceitas com suas regras próprias; a geração não converte ou regrava a IR.

`test/authorization_sql_test.rb` cobre seleção, nomes, mapeamento, determinismo, falhas e CLI sem reavaliar
o DSL. A [sonda ADR-031](../script/sonda_adr031.rb) aplica o SQL realmente gerado em PostgreSQL descartável.
Na rodada K5, no PostgreSQL 18.6, Ruby 4.0.9 e `pg` 1.7.0, passaram 29/29 verificações: instalação, DML em lote, troca de
tenant, ciclo de vida da raiz, atomicidade, concorrência, privilégios, papéis assumíveis por `SET ROLE`,
`ADMIN OPTION` (inclusive herdado por papel assumível e o caso legítimo de `ADMIN` implícito inacessível),
`REFERENCES`, subscriptions (criação e posse herdada), papéis de acesso ao servidor,
`session_replication_role` e recusas de estrutura/papéis/schema. Contra o gerador de `61efbb8`, as dez
verificações que detectam esses caminhos falham (19/29). A limpeza dos schemas e papéis foi conferida. A CI repete a sonda no
PostgreSQL 17 e 18.

A C2 amplia a sonda para 59 verificações: funções, sobrecargas e procedimentos preexistentes; `EXECUTE`
direto, herdado e assumível; cadeias de definers `a -> b` e `a -> b -> c`, inclusive com rotina interna
privada; cadeia legítima com ciclo de permissões entre donos sem poder; poderes do dono por coluna, por
propriedade sem ACL, de replicação e de servidor; dono só com DML (instala, e o `DELETE` pela rotina leva a
revisão de 1 a 2); privilégios padrão globais `FOR ROLE <owner>` concedidos a um dono interno da cadeia
(escrita nas revisões, `EXECUTE` nas funções novas e `CREATE` no schema); instalação depois de revogar
`EXECUTE`; e o limite posterior à instalação (função criada depois faz `TRUNCATE` com a revisão parada).
No PostgreSQL 18.6 passaram 59/59; contra o gerador de `fb41921`, 35/59. O catálogo do 18.6 não tem
`prosecdef` em `pg_catalog` nem em `information_schema`, e os fontes do 17 também não
([`pg_proc.dat`](https://github.com/postgres/postgres/blob/REL_17_STABLE/src/include/catalog/pg_proc.dat)),
por isso não há exclusão desses schemas.

## Limites

Este gerador standalone não aplica planos; `db:plan` compõe suas instruções sem transação aninhada.
Não há `db:migrate`, atualização de instalações existentes, chave global sem tenant, eventos de linha,
assinaturas, executor de operações ou entrega de dados live. O schema novo é uma
pré-condição: colisões falham sem substituir objetos. O mesmo vale para dados particionados ou herdados.
A introspecção gerada verifica somente as colunas e os poderes necessários a este SQL, não o esquema
completo da aplicação. Os poderes e as rotinas preexistentes são conferidos na instalação; novas rotinas,
alterações de corpos, concessões e mudanças de papéis feitas depois não são vigiadas. Uma função
`SECURITY DEFINER` criada depois, de dono privilegiado e executável pela aplicação, ainda pode fazer `TRUNCATE`
sem incrementar a revisão, como a sonda demonstra. A guarda segue permissões de execução de definers,
sem analisar corpos nem provar a segurança de todas as formas de execução indireta; essas mudanças exigem
revisão operacional. Mantenha DDL e concessões estáveis durante
a instalação: os locks protegem as tabelas, não congelam os catálogos de rotinas/papéis.

Um `pg_restore --data-only --disable-triggers` termina com `ENABLE TRIGGER ALL`, que troca o estado `ALWAYS`
dos triggers pela habilitação comum; a partir daí, `session_replication_role = replica` volta a suprimi-los.
Depois de um restore assim, confira `pg_trigger.tgenabled = 'A'` nos triggers `vt_authz_*` e restaure
`ENABLE ALWAYS` antes de liberar a aplicação. Um dump e restore completos preservam o estado. Os fixtures da sonda têm as colunas físicas mínimas usadas pelos triggers.

As funções de privilégio e as relações de transição seguem as referências de
[privilégios](https://www.postgresql.org/docs/18/functions-info.html) e
[triggers](https://www.postgresql.org/docs/18/sql-createtrigger.html) do PostgreSQL.
O [ADR-031](adr/031-geracao-de-sql-de-revisao-de-autorizacao.md) registra as decisões deste incremento.

## Convivência com o contexto assinado

O plano inicial cria `vetra` para as funções de contexto. O gerador de revisão reutiliza esse schema
quando o dono é `vetra_owner`; schemas customizados continuam exigindo criação nova. A tabela de
revisões e suas funções nunca são substituídas. A guarda conservadora de rotinas usa a exceção do
[ADR-036](adr/036-papeis-e-contexto-assinado.md): apenas `current_tenant()` e `current_actor()`
com assinatura, dono, linguagem, atributos, configuração e SHA-256 do corpo exatos ficam fora do
fecho de escalada. Uma função parecida ou uma cópia em outro schema continua sujeita à recusa.
As guardas de execução de funções de revisão e de poderes dos donos usam a mesma identidade exata.

A revisão integra os passos do plano inicial, depois das políticas RLS e dos triggers de transição.
As guardas de privilégios e rotinas continuam depois dos REVOKEs; blog e chat não recebem revisão.
O [guia de planos](db-plan.md) descreve chaves, e o [guia de RLS](db-rls.md) detalha a sonda integrada.

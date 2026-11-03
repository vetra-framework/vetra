# SQL de revisão de autorização

`db:authz:sql` gera o SQL inicial de revisão por tenant do ADR-030. É um gerador sem conexão ao banco;
o plano completo de persistência e o runtime live continuam pendentes.

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
2. Confere PostgreSQL 17+, papéis e ausência de vínculo da aplicação com o proprietário.
3. Obtém locks `SHARE ROW EXCLUSIVE` nas tabelas selecionadas, em ordem estável.
4. Confere tabelas comuns, ausência de herança/partições, coluna de tenant não nula e tipo compatível com
   o ID da raiz; a raiz precisa de PK simples em `id`. Recusa propriedade pela aplicação.
5. Cria um schema novo, `authz_revisions` e funções/triggers de inserção, atualização e exclusão.
6. Restringe privilégios; recusa poderes herdados de `TRUNCATE`/`TRIGGER`, escrita nas revisões,
   execução das funções ou criação de objetos na infraestrutura, inclusive por privilégios padrão.
7. Varre os IDs existentes da raiz para criar revisões zero e confirma a transação.

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
result.sql       # SQL congelado
result.tables    # entidades, tabelas físicas e colunas do tenant
result.warnings  # diagnósticos do grafo
```

A API valida o grafo e copia sua entrada, sem acessar fontes ou banco. A CLI acrescenta a verificação do
pacote. IRs 0.1/0.2/0.3 são aceitas com suas regras próprias; a geração não converte ou regrava a IR.

`test/authorization_sql_test.rb` cobre seleção, nomes, mapeamento, determinismo, falhas e CLI sem reavaliar
o DSL. A [sonda ADR-031](../script/sonda_adr031.rb) aplica o SQL realmente gerado em PostgreSQL descartável.
No PostgreSQL 18.6, Ruby 4.0.9 e `pg` 1.7.0, passaram 17/17 verificações: instalação, DML em lote, troca de
tenant, ciclo de vida da raiz, atomicidade, concorrência, privilégios e recusas de estrutura/papéis/schema.
A limpeza dos schemas e papéis foi conferida. A CI repete a sonda no PostgreSQL 17 e 18.

## Limites

Não há `db:plan`, `db:migrate`, atualização de instalações existentes, chave global sem tenant, geração de
RLS ou eventos de linha, assinaturas, executor de operações ou entrega de dados live. O schema novo é uma
pré-condição: colisões falham sem substituir objetos. O mesmo vale para dados particionados ou herdados.
A introspecção gerada verifica somente as colunas e os poderes necessários a este SQL, não o esquema
completo da aplicação. Os fixtures da sonda têm as colunas físicas mínimas usadas pelos triggers.

As funções de privilégio e as relações de transição seguem as referências de
[privilégios](https://www.postgresql.org/docs/18/functions-info.html) e
[triggers](https://www.postgresql.org/docs/18/sql-createtrigger.html) do PostgreSQL.
O [ADR-031](adr/031-geracao-de-sql-de-revisao-de-autorizacao.md) registra as decisões deste incremento.

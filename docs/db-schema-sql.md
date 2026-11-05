# Modelo físico e SQL inicial

`Vetra::SQL::Schema` traduz a IR validada para o modelo físico do
[ADR-035](adr/035-mapeamento-fisico-inicial.md) e para DDL de PostgreSQL 17+ em banco vazio.
Não abre conexão, não lê `DATABASE_URL`, fontes ou relógio e não executa o SQL.
[`db:plan`](db-plan.md) compõe esse DDL com donos, privilégios e infraestrutura de contexto assinado.

## API

```ruby
require 'vetra'

document = Vetra::Graph::Compiler.new(root: 'examples/mini_crm_revendas').read_artifact.document
result = Vetra::SQL::Schema.new(document).generate
result.tables    # tabelas na ordem de criação, com colunas, checks, PK, únicas, índices e FKs
result.blocks    # [{ 'kind' => 'schemas' | 'tables' | 'foreign_keys', 'statements' => [...], 'sql' => ... }]
result.sql       # concatenação dos três blocos
result.warnings  # avisos do validador do grafo
File.write('/tmp/vetra-schema.sql', result.sql)
```

A API copia a entrada, valida o documento e seu digest, sem converter sua versão, e congela profundamente
a saída. O carregador do exemplo acrescenta a verificação do artefato. A ordem física independe da ordem
dos nós, campos, índices e relações. As versões 0.1 a 0.6 são lidas com suas regras próprias, sem criar
`created_at` retroativamente.

Cada tabela informa `entity`, `schema`, `table`, `columns` (`name`, `field` lógico, `type` SQL, `nullable`
e `default` SQL ou nulo), `checks` (`name`, `expression`), `primary_key`, `unique_keys` e `indexes`
(`name`, `columns`), além de `foreign_keys` (colunas, destino e ações). `assignments` preserva os defaults
da IR, geração, normalização e donos de transição; `transitions` preserva `enforce` para a C7.

`scope` distingue `tenant_root`, `tenant` e `global`. Na raiz, `tenant_column` é `id`; nas filhas, é o campo
da IR; no blog e chat, é nulo. A C7 deve usar esse dado para proteger também a raiz. A ausência de
`entity.tenant` na raiz não significa ausência de proteção.

## Ordem e representação

O primeiro bloco cria schemas de aplicação diferentes de `public`; o segundo cria todas as tabelas,
checks, PKs, chaves únicas e índices; o terceiro acrescenta todas as FKs. Blocos vazios continuam presentes.
Cada elemento de `statements` é uma instrução completa; não divida SQL por ponto e vírgula, pois literais
podem contê-lo. Não há transação embutida: o plano define as unidades transacionais, locks e custos dos passos.

IDs são UUIDs, com default v4 somente na PK `id`. Textos usam `text` com checks de comprimento;
`integer` usa `bigint`; decimais e dinheiro usam `numeric(p,s)`; `timestamp` usa fuso e microssegundos;
`json` usa `jsonb`; enum usa texto com check. Dinheiro desdobra valor e moeda, com check de nulidade
conjunta e moedas compatíveis com a escala. A nulidade vem exclusivamente de `nullable`.

Defaults literais são serializados por tipo e escapados, nunca aceitos como SQL. Defaults de contexto e
`created_at` ficam para o repositório; inserts SQL devem fornecer esse timestamp explicitamente.
Normalização `downcase` é conferida por check; unicidade só existe quando declarada, com nulos distintos.
A equivalência de Unicode depende da collation/locale do banco e do normalizador do repositório.

Cada filha recebe FK para a raiz mesmo sem relação declarada. FKs entre filhas usam as chaves compostas
por tenant e únicas de apoio. FKs usam `MATCH SIMPLE`, `NO ACTION` em exclusão/atualização e são
`DEFERRABLE INITIALLY IMMEDIATE`. O vendedor nulo é permitido, sem dispensar a FK simples da empresa.
Ciclos podem adiar as FKs explicitamente durante uma transação. `has_many` e `many_to_many` não duplicam
a FK nem a tabela da junção.

Identificadores usam ASCII minúsculo, números ou sublinhado, começam por letra, têm até 63 bytes e são
sempre validados e citados. Nomes derivados usam hash da estrutura física, sem ordinais da IR; colisões
são erros, incluindo as colunas de dinheiro e o namespace compartilhado de índices/tabelas.

## Recusas e limites

| Diagnóstico | Recusa |
|---|---|
| `schema_identifier` | Nome físico ou nome de índice declarado com mais de 63 bytes ou sintaxe inválida |
| `schema_reserved` | Schema reservado ao PostgreSQL/Vetra ou coluna de sistema |
| `schema_collision` | Tabela, índice, constraint ou coluna física em colisão |
| `schema_primary_key` | PK diferente de `id` UUID não nulo, ou com default declarado |
| `schema_partial_index` | Índice com `where`, sem tradução segura definida |
| `schema_constraints` | Comprimento em tipo não textual |
| `schema_normalize` | `downcase` em tipo não textual |
| `schema_default` | Literal incompatível com UUID, data, fuso, precisão temporal, comprimento ou normalização |
| `schema_literal` | `U+0000` em literal textual ou JSON |
| `schema_fk_type` | Tipos/modificadores diferentes entre colunas da FK |
| `schema_fk_target` | Destino sem PK ou única integral na ordem referenciada |

A validação da IR pode recusar o documento antes dessas verificações, com seus próprios diagnósticos.
Falhas não retornam modelo ou SQL parcial. Não se resolve colisão por truncamento, nem se aceita predicado
parcial ignorando `where`. Este gerador exige banco vazio e falha se objetos já existirem.

Esta API continua sendo o mapeamento físico puro: não inclui concessões, RLS, revisão ou triggers de
transição. `Plan.initial` acrescenta a infraestrutura do contexto, confere papéis operacionais e atribui
donos e DML (ADR-036). RLS, revisão nos planos e triggers de transição pertencem à C7; aplicação
com histórico e migração incremental ainda não existem.

## Referências de auditoria

`test/schema_sql_test.rb` cobre os quatro exemplos e as recusas, sem banco. As fixtures integrais em
[test/fixtures/sql](../test/fixtures/sql) são comparadas byte a byte com o DDL gerado:

| Exemplo | Tabelas | PKs | Únicas (além da PK) | Índices (além dos de chaves) | Checks | FKs |
|---|---:|---:|---:|---:|---:|---:|
| mini CRM | 2 | 2 | 1 | 1 | 6 | 1 |
| mini CRM com revendas | 5 | 5 | 5 | 4 | 7 | 8 |
| blog | 2 | 2 | 0 | 2 | 4 | 1 |
| chat | 4 | 4 | 2 | 4 | 3 | 5 |

A auditoria deve aplicar cada fixture num banco vazio separado, no PostgreSQL 17 e 18, dentro de uma
transação do aplicador. Espera-se criação integral, sem extensão e sem dependência de papéis Vetra.
Confira no catálogo PKs, únicas, checks e FKs; inserts com `created_at` explícito devem gerar IDs v4.

Nos CRMs, empresa inexistente e referência a vendedor/revenda de outro tenant devem falhar; vendedor
nulo com empresa/revenda válidas deve passar. Dinheiro deve recusar só uma das colunas nula, moeda não
suportada/fora da escala e `NaN`; enum e comprimentos inválidos devem falhar. No chat, email normalizado
repetido deve falhar na única e email fora da forma normalizada deve falhar no check. A criação das
junções deve ocorrer uma vez. Inserções cíclicas em uma fixture adicional podem usar
`SET CONSTRAINTS ALL DEFERRED`, mantendo falha no commit quando falta o destino.

Este DDL ainda não isola leituras por RLS nem impede uma transição de comando indevida; esses testes
passam a ser exigíveis com a C7. Não há resultado de execução em banco registrado nesta entrega.

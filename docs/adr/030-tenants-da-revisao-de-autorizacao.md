# ADR-030: Tenants da revisão de autorização

- Status: aceito
- Implementação posterior: ADR-031 (geração inicial de SQL, sem executor de migrações).
- Aceite: integração direta na main, após validação da sonda e revisão dos limites nesta continuação. Confirmado em 2026-11-03 pelo Claude, por delegação do mantenedor, após a auditoria K2.
- Data: 2026-11-03
- Resolve: ADR-020, questão 6 (origem do tenant no trigger de instrução)
- Depende de: ADR-005 (contexto e RLS), ADR-020 (revisão por tenant)

## Contexto

O ADR-020 exige incrementar a revisão de autorização na transação que muda uma tabela de permissão.
O tenant do contexto não descreve necessariamente todas as linhas alteradas: uma manutenção pode alcançar
mais de um tenant, mudar a associação de uma linha ou executar sem contexto de aplicação.

## Tratamento da questão 6: decidida

O futuro gerador usa tabelas de transição em triggers `AFTER ... FOR EACH STATEMENT`, separados por evento:

- `INSERT`: tenants distintos em `NEW TABLE`.
- `DELETE`: tenants distintos em `OLD TABLE`.
- `UPDATE`: união dos tenants distintos de `OLD TABLE` e `NEW TABLE`.

Cada tenant afetado recebe um incremento por execução do trigger. Uma instrução que não altera linhas
não incrementa revisões. Uma troca de tenant invalida tanto o antigo quanto o novo. Atualizações que
mantêm os mesmos valores podem invalidar conservadoramente. Não se promete um único incremento para SQL
que o PostgreSQL decompõe em vários eventos, como `INSERT ... ON CONFLICT DO UPDATE` ou ações de FKs.

Os tenants são processados em ordem para reduzir inversões de locks numa mesma instrução. O incremento
usa `INSERT ... ON CONFLICT DO UPDATE` com a revisão armazenada, preservando incrementos concorrentes.
Todas as revisões e notificações pertencem à transação da escrita: rollback desfaz ambos.

A função de trigger executa com um proprietário restrito, sem login, superusuário ou `BYPASSRLS`, usa
`search_path` fixo e nomes de objetos persistidos qualificados. A aplicação não recebe escrita direta nas
revisões, `TRUNCATE` nas tabelas de permissão nem autoridade para desativar os triggers. Permissões para
manutenção permanecem separadas. A identidade do tenant vem das linhas, não de uma variável de sessão.
Isso não substitui a autorização de escrita nem o contexto assinado e o RLS do ADR-005.

O gerador precisa representar uma chave de revisão para aplicações sem tenant antes de gerar esses
triggers nelas; o protótipo desta resolução cobre somente tabelas com `tenant_id` obrigatório. Tabelas
particionadas, cascatas e SQL que altera múltiplas tabelas precisam de testes próprios antes de integrar
o gerador. A ordem por tenant dentro de um trigger não elimina deadlocks entre várias instruções.

## Alternativas rejeitadas

- Tenant somente do contexto: não cobre manutenção sem contexto, vários tenants ou troca de associação.
- Trigger de revisão por linha: repete o incremento para todas as linhas de um lote no mesmo tenant.
- Incrementar no código Ruby: SQL direto e caminhos de manutenção poderiam omitir a revisão.

## Evidência e limites

A sonda `script/sonda_adr020.rb` verifica a proposta num PostgreSQL real, com papéis distintos para o
proprietário e a aplicação. Ela também exercita, como demonstrações do ADR-020, uma verificação strict de
revisão, falha fechada, eventos sem conteúdo pessoal e releitura agrupada. Não implementa o gerador,
assinaturas autenticadas, contexto assinado, RLS, transportes, auditoria ou o gate G4 completo.

As 13 verificações passaram localmente no PostgreSQL 18.6; a sonda entra na matriz 17/18 da CI.
O [relatório](../sondas/adr020.md) registra quatro falhas introduzidas que foram detectadas e os limites.

As tabelas de transição e os eventos separados estão documentados em
[CREATE TRIGGER](https://www.postgresql.org/docs/18/sql-createtrigger.html) e
[funções de trigger](https://www.postgresql.org/docs/18/plpgsql-trigger.html). O tratamento de privilégios
e `search_path` segue [CREATE FUNCTION](https://www.postgresql.org/docs/18/sql-createfunction.html).

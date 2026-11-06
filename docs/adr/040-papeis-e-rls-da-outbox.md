# ADR-040: Papéis, RLS e armazenamento da outbox

- Status: aceito
- Aceite: 2026-11-06, pelo Claude por delegação do mantenedor, após a auditoria da K11 (aprovada na rodada 2), com a sonda da outbox em 36/36 no PostgreSQL 17.11 e 18.6.
- Data: 2026-11-06
- Depende de: ADR-008, ADR-013, ADR-014, ADR-016, ADR-024, ADR-036, ADR-037, ADR-038 e ADR-039

## Contexto

O ADR-014 decide a entrega pelo menos uma vez, e o ADR-024 decide a partição por tempo, a chave da outbox e das
entregas e a cópia das entregas mortas para `vetra.dead_deliveries`. Nenhum dos dois diz com que papel cada parte
acessa essas tabelas, se elas têm RLS, nem como entram nos planos de uma aplicação que já tem o plano inicial
aplicado. A K11 cria o armazenamento e a emissão; a K12 cria o relay, as entregas e a manutenção. Este ADR decide
as duas pontas, para que a K12 não precise reabrir o que a K11 grava.

## Decisão

### 1. Objetos

Uma aplicação com ao menos um evento na IR ganha, no schema `vetra` e com dono `vetra_owner`:

| Objeto | Forma |
|---|---|
| `vetra.outbox` | Particionada por `RANGE (created_at)`; chave primária `(created_at, xid8, seq)`; índice `vt_outbox_relay (xid8, seq)` |
| `vetra.outbox_default` | Partição `DEFAULT` da outbox |
| `vetra.deliveries` | Particionada por `RANGE (event_created_at)`; chave primária `(handler, event_id, event_created_at)`; índice parcial `vt_deliveries_ready (run_after) WHERE state = 'pending'` |
| `vetra.deliveries_default` | Partição `DEFAULT` das entregas |
| `vetra.dead_deliveries` | Sem partição; chave primária `(handler, event_id)`, com o evento copiado |

- `created_at` vem de `statement_timestamp()`, `xid8` de `pg_current_xact_id()`, e `seq` é uma identidade
  `GENERATED ALWAYS`. Nenhum deles é gravável pela aplicação: a concessão de `INSERT` é por coluna e não os
  inclui. Assim, a chave de partição e a ordem do ADR-008 não dependem do relógio nem do código da aplicação.
- `tenant_id` tem o tipo do `id` da raiz do tenant; numa aplicação global é `uuid` e fica nulo. `event_id`, `op_id`
  e `actor_id` são UUIDs; `event`, `version`, `cmd` e `payload` (um objeto `jsonb`) completam a linha.
- As entregas guardam o `created_at`, o `xid8` e o `seq` do evento, e particionam pelo mesmo instante: a purga
  de um dia remove o evento e as suas entregas juntos (ADR-024, §3, decisão 5).
- O índice parcial das entregas já nasce no plano da K11. O PostgreSQL não cria índice `CONCURRENTLY` numa tabela
  particionada, então um índice acrescentado depois numa tabela com volume bloquearia a escrita.
- As partições diárias não nascem no plano: são do job de manutenção (§4). Até ele existir, as linhas ficam na
  `DEFAULT`, que é o alarme do ADR-024.

### 2. Quem grava: `vetra_app`

- A aplicação só pode **inserir** na outbox, pelas colunas `event_id`, `event`, `version`, `tenant_id`,
  `actor_id`, `op_id`, `cmd` e `payload`. Não tem `SELECT`, `UPDATE`, `DELETE`, `TRUNCATE`, `REFERENCES` nem
  `TRIGGER`, e não tem acesso às entregas, às entregas mortas nem às partições.
- A outbox tem RLS habilitado e forçado. Uma política `PERMISSIVE FOR INSERT TO vetra_app` aceita só a linha do
  contexto: numa aplicação com tenant, `tenant_id` e `actor_id` iguais a `vetra.current_tenant()` e
  `vetra.current_actor()`; numa aplicação global (ADR-039), `tenant_id` nulo. Um corpo `call` com SQL próprio
  não grava evento de outro tenant.
- As partições e as demais tabelas têm RLS habilitado e forçado sem política para a aplicação: negam tudo a quem
  não tiver uma política própria, inclusive se uma concessão for dada por engano.
- O runtime grava o evento na unidade de trabalho, depois do `call` e antes do commit (etapa 7 do ADR-016): o
  dado e o evento existem juntos ou não existem. O `payload` é a projeção declarada em `emits`, a partir do
  registro devolvido. A gravação também chama `pg_notify('vetra_outbox', tenant)`, com o tenant ou texto vazio,
  sem conteúdo do evento (ADR-008, §1).
- **Campo pessoal.** Enquanto a cifra por DEK do ADR-013, §6 não existir, um payload com campo pessoal é recusado
  e **desfaz a unidade de trabalho inteira**, mesmo que o `call` resgate o erro. A outbox nunca guarda dado
  pessoal em claro.

### 3. Quem lê: o relay, `vetra_relay`

- Um papel global `vetra_relay`, `LOGIN`, `NOBYPASSRLS`, sem `SUPERUSER`, `CREATEDB`, `CREATEROLE` nem
  `REPLICATION`, sem vínculo com `vetra_owner` nem com `vetra_app`, é criado pelo **bootstrap operacional** do
  ADR-036, nunca por um plano. A guarda de papéis passa a conferi-lo.
- Os planos concedem ao relay `SELECT` na outbox, `SELECT, INSERT, UPDATE` nas entregas e `SELECT, INSERT` nas
  entregas mortas, com políticas `TO vetra_relay` próprias. A política da outbox para o relay é `USING (true)`:
  ele lê o cluster por faixa de `xid8`, sem tenant (ADR-024, §3). O isolamento do que um handler faz vem do
  contexto assinado do tenant do evento (ADR-014, §8), não da leitura do relay.
- O relay não tem acesso às tabelas da aplicação, às chaves de `vetra_private` nem às revisões. Não usa
  `vetra_migrator` em execução.

### 4. Manutenção

- Criar, anexar, desanexar e remover partições exige ser dono da tabela particionada. O relay não recebe esse
  poder: a manutenção é feita por rotinas `SECURITY DEFINER` de dono `vetra_owner`, com `search_path` fixo e
  corpo fechado, que só criam as partições diárias dos próximos dias, recuperam as linhas de uma `DEFAULT`
  populada e removem por `DETACH` e `DROP` as partições mais antigas que a retenção. Só `vetra_relay` as executa.
- Uma partição criada pela manutenção segue um nome fixo (`outbox_pAAAAMMDD`, `deliveries_pAAAAMMDD`), limites de
  um dia UTC, dono `vetra_owner`, RLS habilitado e forçado, nenhuma concessão e só os índices herdados do pai.
- A deriva do `db:migrate` reconhece essas partições quando elas cumprem exatamente essas regras e trata qualquer
  outra diferença como adulteração.

### 5. Entrada nos planos

- O plano inicial de uma aplicação com eventos traz a seção da outbox depois das tabelas da aplicação e antes da
  segurança.
- O plano incremental (ADR-038) a cria inteira num passo transacional quando o modelo anterior não a tem. Qualquer
  outra diferença nela, inclusive a sua remoção quando a aplicação deixa de ter eventos, é recusada com
  `db_plan_statement` ou `db_plan_remove`, até que uma tarefa própria traduza essa mudança.

### 6. Divisão entre a K11 e a K12

A K11 implementa os §§ 1, 2 e 5. A K12 implementa o papel `vetra_relay` no bootstrap, as políticas e as
concessões do relay, as rotinas de manutenção e o reconhecimento das partições pela deriva (§§ 3 e 4), num plano
próprio.

## Alternativas descartadas

- **Relay com `BYPASSRLS`:** dispensaria as políticas, mas o papel leria também as tabelas da aplicação se
  recebesse uma concessão por engano.
- **Relay como membro de `vetra_owner`:** daria a ele DDL sobre todo o esquema da aplicação.
- **Manutenção pelo `vetra_migrator`:** é o papel dos planos, com `BYPASSRLS`; deixá-lo no runtime desfaria a
  separação do ADR-036.
- **Gravação por uma rotina `SECURITY DEFINER`:** a concessão por coluna e a política de `INSERT` dão a mesma
  garantia sem acrescentar rotina ao fecho conferido pela guarda do ADR-037.
- **`created_at` vindo do relógio da unidade:** a chave de partição dependeria de um valor da aplicação.
- **Sequência separada para `seq`:** exigiria `USAGE` para a aplicação; a identidade não exige.

## Consequências

- Três exemplos (blog, mini CRM e CRM com revendas) ganham o plano `0002`, o modelo e o retrato atualizados. O
  chat, sem eventos, não muda.
- Até a K12, os eventos ficam na partição `DEFAULT` e ninguém os lê.
- A remoção de todos os eventos de uma aplicação passa a ser uma mudança recusada pelo plano incremental.
- O bootstrap operacional ganha um papel na K12, e a CI e as sondas precisam criá-lo.

## Garantias

| Garantia | Nível | Mecanismo |
|---|---|---|
| Dado e evento existem juntos ou não existem | Transacional | Gravação na unidade de trabalho |
| A aplicação não grava evento de outro tenant | Transacional | Política de `INSERT` com o contexto assinado |
| A aplicação não lê, altera nem remove eventos | Transacional | Concessão por coluna, sem `SELECT`/`UPDATE`/`DELETE` |
| `created_at`, `xid8` e `seq` não vêm da aplicação | Transacional | Defaults, identidade e concessão por coluna |
| A outbox não guarda dado pessoal em claro | Verificável por testes | Recusa da emissão e da unidade inteira, até a cifra do ADR-013 |

## Testes de aceitação

1. O plano `0002` cria a outbox, as entregas e as entregas mortas num banco com o `0001` aplicado e dados, e o
   `--check` confere o retrato.
2. Um comando real grava o evento com `xid8` da própria transação, `seq` crescente e o payload projetado; um
   rollback não deixa evento.
3. A aplicação não grava evento de outro tenant, não define `created_at`, `xid8` nem `seq`, e não lê, altera nem
   remove a outbox, as partições ou as entregas.
4. Um payload com campo pessoal desfaz a unidade inteira, mesmo com o erro resgatado no `call`.
5. Nenhuma instrução nomeada é criada pela emissão.

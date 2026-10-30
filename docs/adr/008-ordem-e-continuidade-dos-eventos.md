# ADR-008: Notificação como invalidação, ordem por xid8 e continuidade

- Status: proposto
- Data: 2026-10-30
- Depende de: ADR-016 (ciclo de vida da operação), ADR-002 (somente PostgreSQL)
- Dependem deste ADR: ADR-014 (outbox com entrega pelo menos uma vez), ADR-020 (entrega live incremental)

## Contexto

O ADR-016 grava os eventos na outbox, na mesma transação dos dados. Falta definir como esses eventos chegam
aos consumidores (handlers e assinaturas live) **sem perder nenhum e sem entregar fora de ordem**.

A armadilha clássica é usar o número de uma sequência como ordem de commit. Não é: um número é atribuído no
`INSERT`, antes do commit. A transação A pega o número 10, a B pega o 11, a B confirma primeiro, o leitor
avança o checkpoint para 11 e, quando a A confirma, o evento 10 fica para trás para sempre.

Outro limite do PostgreSQL: o payload do `NOTIFY` é limitado (8000 bytes por padrão), as notificações não são
duráveis (se a conexão de escuta cair, elas se perdem) e o PgBouncer em modo de transação não suporta
`LISTEN`.

## Decisão

### 1. A notificação só invalida

O `NOTIFY` não carrega dados. Ele diz "há algo novo para o tenant X" e acorda o distribuidor, que **lê a
outbox**. A fonte de verdade é sempre a tabela. Perder uma notificação atrasa a entrega, não a perde.

- O `pg_notify` é chamado dentro da transação de escrita, e o PostgreSQL só o entrega no commit.
- O payload contém só o identificador do tenant (e, no máximo, um contador). Nunca o conteúdo do evento.
- Cada processo mantém **uma conexão `LISTEN` dedicada**, direta ao PostgreSQL, fora do pool e do PgBouncer.
- Como as notificações não são duráveis, o distribuidor também faz **leitura periódica** da outbox (padrão:
  a cada 1 segundo), mesmo sem notificação.

### 2. A ordem vem do `xid8`, não da sequência

Cada evento grava, junto com a sequência, o `xid8` da transação (`pg_current_xact_id()`). O distribuidor lê
em **intervalos fechados por baixo e abertos por cima**:

```sql
SELECT * FROM vetra.outbox
 WHERE xid8 >= $lo
   AND xid8 <  pg_snapshot_xmin(pg_current_snapshot())
 ORDER BY xid8, seq;
```

- `pg_snapshot_xmin` é o menor `xid8` ainda ativo. Toda transação com `xid8` menor que ele **já terminou**
  (confirmou ou desfez). Portanto, todos os eventos dessas transações que existem já estão visíveis, e nenhum
  poderá aparecer depois no mesmo intervalo.
- O próximo intervalo começa onde o anterior terminou (`lo` = `hi` do intervalo anterior). Os intervalos
  são contíguos, o que dá a **prova de continuidade** por construção.
- O `xid8` tem 64 bits; não há volta de contador.
- A mesma regra vale para o relay dos handlers (ADR-014), combinada com `SKIP LOCKED` quando vários relays
  disputam o mesmo intervalo.

**O que o `xid8` não é.** O `xid8` é atribuído na primeira escrita da transação, não no commit; a ordem por
`xid8` **não** é a ordem de commit. Dois eventos de transações diferentes podem sair numa ordem diferente da
confirmação. Isso é inofensivo para continuidade, mas importa para o estado: duas transações alterando a mesma
linha podem entregar as mudanças em ordem inversa.

### 3. Versão por linha resolve a ordem do estado

Toda linha de entidade que participa de consultas live tem uma coluna de versão `_v` (bigint), incrementada
por um trigger `BEFORE UPDATE` gerado (`NEW._v = OLD._v + 1`), o que também cobre SQL direto. Como as
transações que alteram a mesma linha se serializam pelo lock da linha, a versão cresce na ordem real das
alterações daquela linha.

- Os eventos de mudança carregam `(entidade, id, versão)`.
- Quem aplica a mudança (o distribuidor ou o cliente) **ignora** um evento com versão menor ou igual à já
  aplicada para aquele id.
- A ordem entre linhas diferentes não importa para o estado final.

### 4. Checkpoint e ressincronização

- **Checkpoint do cliente:** o `hi` do último intervalo entregue a ele. Na reconexão, o cliente informa esse
  valor; o servidor envia os eventos de `[checkpoint, hi_atual)` que cabem no escopo da assinatura, ou o
  estado completo.
- **Checkpoint do distribuidor:** cada processo grava o seu `hi` em `vetra.distributor_checkpoints` a cada
  ciclo. Serve para retomada rápida e para observabilidade.
- **Retenção:** a outbox guarda eventos para o live por um tempo configurável (padrão proposto: 10 minutos),
  e o `hi` mais antigo ainda disponível fica registrado em `vetra.outbox_purged_before`.
- **Sem prova de continuidade, ressincroniza.** O servidor envia o **estado completo** em vez do diff quando:
  1. o checkpoint do cliente é anterior a `outbox_purged_before`;
  2. o distribuidor perdeu um intervalo (erro, reinício sem checkpoint válido);
  3. o identificador do cluster (`system_identifier`) ou a linha do tempo (`timeline_id`) mudou, o que
     indica failover ou restauração de backup;
  4. a assinatura foi suspensa e reavaliada (ADR-020).

### 5. Quem segura o `xmin`

O `pg_snapshot_xmin` só avança quando as transações **com escrita** mais antigas terminam. Uma transação
longa, ou uma transação preparada esquecida, atrasa a entrega de **todos** os eventos posteriores,
inclusive de outros tenants.

- O papel `vetra_app` roda com `transaction_timeout` e `idle_in_transaction_session_timeout` configurados
  (padrão proposto: 30 s e 10 s).
- O `vetra doctor` e as métricas mostram a idade do `xmin` e quem o segura.
- Transações só de leitura não ganham `xid` e não atrasam o `xmin`.

## Alternativas rejeitadas

- **Sequência como ordem de commit:** perde eventos, como mostrado acima.
- **Serializar commits com um advisory lock** para forçar ordem: elimina a perda, mas serializa todos os
  escritores do sistema.
- **Dados dentro do `NOTIFY`:** limite de tamanho e perda em queda de conexão.
- **Só polling:** funciona, mas adiciona latência ou carga; usado só como complemento.
- **Replicação lógica (LSN) desde já:** daria ordem de commit real, mas traz slots, falhas de operação e uma
  dependência de infraestrutura. Fica para depois, se a medição mostrar necessidade.
- **Fila externa (Kafka, Debezium, Redis Streams) como transporte obrigatório:** o núcleo precisa funcionar só
  com PostgreSQL. O Redis continua opcional, só para sinais efêmeros (ADR-019).

## Consequências

- Nenhum evento é perdido por commit fora de ordem, mesmo com vários escritores e vários processos.
- Há um pequeno atraso: um evento só sai depois que todas as transações anteriores terminaram.
- Uma coluna `_v` e um trigger por entidade que entra em consulta live.
- O `NOTIFY` serializa commits sob escrita muito intensa. O ponto em que isso passa a pesar é uma medição da
  matriz de carga do gate G4; o Redis só entra quando a latência de commit mostrar o problema.
- A tabela de outbox cresce e precisa de limpeza e, em volume alto, partição por tempo.

## Garantias e seus níveis

| Garantia | Nível | Mecanismo |
|---|---|---|
| Nenhum evento é pulado dentro de um intervalo | Transacional | Regra do `xmin` do snapshot |
| Continuidade entre intervalos | Verificável por testes | Intervalos contíguos e ressincronização sem prova |
| Estado por linha na ordem correta | Transacional | `_v` incrementado sob o lock da linha |
| Entrega em tempo hábil | Operacional | Depende de `LISTEN`, polling e de não haver transação longa |

## Testes de aceitação

1. A transação A (sequência 10) confirma depois da B (sequência 11): o evento da A é entregue.
2. Uma transação longa aberta atrasa a entrega; ao terminar, todos os eventos saem, sem perda.
3. Com a notificação descartada, a leitura periódica entrega o evento.
4. Duas transações alteram a mesma linha com `xid8` em ordem inversa à do commit: o estado final tem a
   versão maior.
5. Um checkpoint de cliente anterior à retenção resulta em estado completo.
6. Failover simulado (mudança de `timeline_id`) ressincroniza todas as assinaturas.
7. Vários processos, cada um com sua conexão `LISTEN`, entregam o mesmo conjunto de eventos.
8. Um `UPDATE` direto no SQL também incrementa `_v` e gera o evento de mudança.
9. Uma transação com escrita que excede `transaction_timeout` é encerrada e libera o `xmin`.

## Questões em aberto

- Volume de eventos por segundo em que o `NOTIFY` passa a aumentar a latência de commit (matriz de carga).
- Intervalo da leitura periódica (1 s é hipótese) e retenção do live (10 minutos é hipótese).
- Partição da outbox: por tempo, por tenant ou ambos.

# ADR-014: Outbox com entrega pelo menos uma vez

- Status: aceito
- Data: 2026-10-30
- Depende de: ADR-016 (ciclo de vida da operação), ADR-008 (ordem e continuidade dos eventos), ADR-002 (somente
  PostgreSQL)
- Dependem deste ADR (na data do aceite): 009 (workflows)
- Relacionados: ADR-004 (capacidades e Effect Boundary), ADR-005 (RLS e contexto assinado), ADR-007
  (adaptadores), ADR-010 (modo serviço), ADR-013 (privacidade), ADR-020 (entrega live)

## Contexto

O ADR-016 grava cada evento numa linha da outbox, na mesma transação dos dados: ou o dado e o evento existem
juntos, ou nenhum existe. O ADR-008 define como o distribuidor lê a outbox sem pular evento (intervalos
fechados abaixo do `xmin` do snapshot, por `xid8`). Falta o outro lado: **como um handler recebe o evento,
o que acontece quando ele falha, e o que se pode prometer sobre duplicatas**.

Um handler tem efeitos que a transação do comando não alcança: enviar e-mail, chamar uma API de terceiros,
publicar numa fila. Nenhum protocolo entrega "exatamente uma vez" a um destino externo sem a cooperação dele:
entre executar o efeito e registrar que ele foi executado, o processo pode cair. O exemplo 1 da proposta
reconhece esse limite no e-mail do vendedor.

## Decisão

**A entrega aos handlers é pelo menos uma vez. O handler deduplica pela chave do evento. O efeito externo só
acontece exatamente uma vez quando o provedor aceita uma chave de idempotência.** O Vetra não promete mais do
que isso.

### 1. Do evento ao handler

1. O comando grava o evento na `vetra.outbox` na transação da operação (etapa 7 do ADR-016).
2. O relay lê a outbox pela regra do ADR-008 (`xid8 < pg_snapshot_xmin(...)`, intervalos contíguos) e, para
   cada evento do intervalo, cria uma **entrega** por handler declarado em `on`: uma linha em
   `vetra.deliveries (event_seq, handler, state, attempts, run_after, leased_until, ...)`.
3. Um worker **reserva** uma entrega, executa o handler e a **conclui**.

O `event_id` é o identificador estável do evento, gravado na outbox ao lado de `seq` (a ordem); a entrega aponta
para o evento por `event_seq`.

O conjunto de handlers de um evento é o do grafo no momento em que o relay cria as entregas. Um handler novo
não recebe eventos antigos; recuperar eventos passados é uma operação explícita, fora desta decisão.

### 2. Reserva por lease, nunca por transação aberta

- A reserva é um `UPDATE` curto que define `leased_until = now() + <lease>` para as entregas escolhidas com
  `FOR UPDATE SKIP LOCKED`, e **confirma na hora**. O efeito externo roda **depois**, fora de qualquer
  transação do relay.
- Não se segura um `SELECT ... FOR UPDATE` aberto durante o efeito. O `FOR UPDATE` atribui um `xid` à
  transação (medido no PostgreSQL 16.15, 17.11 e 18.6 por `script/sonda_adr002.rb`: um `SELECT` simples não
  atribui, o `FOR UPDATE` sim), e uma transação
  com `xid` aberta prende o `xmin` e atrasa a entrega de todos os eventos de todos os tenants (ADR-008, §5).
- Uma entrega com `leased_until` vencido volta a ser elegível: é o que recupera o trabalho de um worker que
  caiu. O lease precisa exceder o timeout do handler (padrão proposto: lease de 2 vezes o timeout declarado).
- Vários workers e vários relays disputam as entregas pelo `SKIP LOCKED` sem se bloquear.

### 3. Deduplicação pela chave do evento

- Todo handler declara `idempotent_by :event_id` (o grafo já exige isso). A chave de uma entrega é o par
  `(handler, event_id)`, único em `vetra.deliveries`.
- O handler passa a chave ao efeito externo quando o provedor aceita (`idempotency_key true` na capacidade,
  ADR-004). Com chave aceita, uma repetição produz um só efeito. Sem chave, uma queda entre o efeito e a
  conclusão da entrega **duplica o efeito**, e isso é dito na documentação de cada capacidade.
- A conclusão grava `state = done` depois do efeito. A ordem inversa (marcar antes) trocaria "pelo menos uma
  vez" por "no máximo uma vez" e perderia efeitos em quedas: é rejeitada.
- Um handler que escreve no banco age por comandos, que passam pelas oito etapas e têm a própria chave de
  idempotência derivada do evento (ADR-016).
- O payload de um evento com campo pessoal traz esse campo cifrado pela DEK do titular (ADR-013, §6). O handler
  o decifra pelo cache de DEKs, e a outbox não guarda dado pessoal em claro.

### 4. Falha, repetição e entrega morta

- Falha retentável (timeout, erro 5xx do provedor): nova tentativa com espera crescente e variação aleatória
  (`run_after`). Falha definitiva (`fail!`, entrada inválida): vai direto a `dead`.
- A indisponibilidade do KMS ao decifrar um campo pessoal é falha retentável. Uma DEK destruída (o titular foi
  eliminado) é falha definitiva: a entrega vai direto a `dead`, porque repetir nunca teria sucesso e um efeito
  sobre uma pessoa eliminada não deve acontecer.
- Depois de um número máximo de tentativas (padrão proposto: 10), a entrega vai a `dead`. Uma entrega morta é
  visível em métricas e em `vetra doctor` e pode ser reprocessada por um comando explícito e auditado.
- **Uma entrega com problema não bloqueia as outras.** Cada entrega é independente; não há fila FIFO por
  tenant.

### 5. Ordem

- O relay cria as entregas na ordem do `xid8` (ADR-008), mas a **entrega ao handler não garante ordem**: uma
  repetição, ou dois workers, a desfazem.
- Um handler que depende de ordem usa a versão por linha (`_v`, ADR-008, §3) e ignora o evento cuja versão
  não é maior que a já aplicada. Não existe garantia de ordem entre entidades diferentes.

### 6. Eventos internos e públicos

- Evento interno com `consumer_required` exige ao menos um handler: ausência é erro de compilação (já
  implementado no protótipo).
- Evento público sem consumidor interno é permitido. A publicação para fora do processo (webhook de saída,
  fila de terceiros) não é definida aqui.

### 7. Retenção e observabilidade

- Entregas concluídas e eventos já entregues são removidos após uma retenção configurável (padrão proposto:
  7 dias para auditoria operacional). Entregas `dead` ficam até serem tratadas. A retenção do live é a do
  ADR-008 (10 minutos como hipótese) e é independente desta.
- Métricas mínimas: atraso da entrega mais antiga pendente, tentativas por handler, entregas mortas e idade do
  `xmin`.

### 8. O ator de um handler

- Um handler **não age como o ator que causou o evento**. Ele age como um **ator de sistema do tenant do
  evento**, identificado pelo handler. O contexto assinado (ADR-005) leva esse ator e o `tenant_id` do evento,
  então o RLS enxerga só aquele tenant.
- A autoridade desse ator é **exatamente a dos comandos que o handler declara em `calls`**. A lista é a que o
  grafo conhece e que o diff arquitetural mostra para revisão; o handler não chama outro comando.
- **Operar como o ator original** do evento exige a capacidade explícita e auditada do ADR-016, e ela não é
  concedida por padrão.
- A auditoria de um comando chamado por um handler registra o handler como origem e o `event_id` como causa.

## Alternativas rejeitadas

- **Promessa de entrega exatamente uma vez:** não é alcançável com efeitos externos sem a cooperação do
  provedor. Prometê-la afirmaria mais do que o mecanismo oferece (também rejeitada no ADR-016).
- **Publicar o evento em memória, depois do commit:** um crash entre o commit e a publicação perde o evento. A
  outbox na mesma transação não perde.
- **Reservar a entrega com uma transação aberta durante o efeito:** prende o `xmin` (seção 2).
- **Marcar a entrega como concluída antes do efeito:** troca duplicata por perda silenciosa.
- **Um cursor por handler em vez de uma linha de entrega:** é mais barato em linhas, mas o estado de
  tentativas, espera e entrega morta passa a ser por intervalo e não por evento, e uma falha isolada bloquearia
  o avanço do cursor.
- **Fila externa obrigatória (Kafka, Redis Streams):** o núcleo funciona só com PostgreSQL (ADR-002).
- **O handler agir como o ator original do evento:** o ator pode ter perdido a permissão entre o commit e a
  entrega, e o handler acumularia o privilégio de quem o disparou. Exigir a capacidade explícita mantém o
  privilégio visível.
- **Um papel de sistema com poder amplo para todos os handlers:** um handler com erro alcançaria comandos que
  não declarou.

## Consequências

- Duplicatas raras e **documentadas**, quando o provedor não aceita chave de idempotência.
- Uma linha por (evento, handler): o custo cresce com o produto de eventos por handlers, e a tabela de
  entregas precisa de limpeza e, em volume alto, partição (junto com a outbox, ADR-008).
- Todo handler é escrito supondo repetição: o efeito precisa ser repetível ou receber a chave.
- Há atraso entre o commit e o efeito: o relay só lê abaixo do `xmin`, e uma transação longa atrasa todos os
  eventos (ADR-008, §5).
- Reprocessar uma entrega morta é um ato humano e auditado, não automático.
- O caso comum de um handler (notificar, sincronizar) não precisa de capacidade nenhuma além dos `calls`; agir
  como o usuário que originou o evento exige uma capacidade explícita.
- Cada comando que um handler chama precisa de uma forma de autorizar o ator de sistema (veja as questões em
  aberto).
- Eventos com campo pessoal pagam a cifra e a decifra, e o handler depende da DEK em cache (ADR-013).

## Garantias e seus níveis

| Garantia | Nível | Mecanismo |
|---|---|---|
| Dado e evento existem juntos ou não existem | Transacional | Mesma transação (ADR-016) |
| Nenhum evento é pulado pelo relay | Transacional | Regra do `xmin` (ADR-008) |
| Cada evento chega pelo menos uma vez a cada handler declarado | Operacional | Lease, repetição e entrega morta; depende de haver workers rodando |
| O handler não repete o efeito deduplicado | Verificável por testes | Chave `(handler, event_id)` única |
| O efeito externo ocorre uma vez só | Operacional | Só com chave de idempotência aceita pelo provedor; senão, pode duplicar |
| Uma entrega com problema não bloqueia as demais | Verificável por testes | Entregas independentes |
| Um handler age só pelos comandos que declara, no tenant do evento | Estrutural, com os limites do ADR-004 | `calls` do grafo e contexto assinado do tenant do evento (§8) |
| A outbox não guarda dado pessoal em claro | Verificável por testes | Cifra por DEK dos campos pessoais do payload (ADR-013, §6) |

## Testes de aceitação

1. Uma exceção depois do `emits` não deixa evento na outbox (ADR-016, teste 2).
2. Duas instâncias do relay, disputando o mesmo intervalo, criam cada entrega uma só vez.
3. Dois workers disputando a mesma entrega: apenas um a executa enquanto o lease vale.
4. Um worker que cai no meio do efeito: o lease vence e outro worker repete a entrega.
5. Com um provedor simulado que aceita chave, a repetição produz um só efeito; sem chave, produz dois, e o
   teste documenta a duplicata.
6. Uma entrega que falha sempre vai a `dead` após o máximo de tentativas e não atrasa as outras.
7. Enquanto um handler leva vários segundos num efeito externo, o `pg_snapshot_xmin` continua avançando: o
   relay não segura transação aberta.
8. Um handler adicionado depois não recebe eventos já relayados.
9. A purga remove entregas concluídas após a retenção e preserva as mortas.
10. Os testes rodam com os mesmos papéis de banco de produção, com PostgreSQL real.
11. Um handler que tenta chamar um comando fora de `calls` é recusado no boot. Os comandos que ele chama
    executam com o ator de sistema do handler e o `tenant_id` do evento, nunca com o ator original.
12. A auditoria de um comando chamado por um handler registra o handler e o `event_id`.
13. Com o KMS indisponível, a entrega de um evento com campo pessoal é repetida. Com a DEK do titular destruída,
    ela vai a `dead` sem repetição.

## Questões em aberto

- Padrões de tentativas máximas, espera, lease e retenção (10 tentativas, lease de 2 vezes o timeout e 7 dias
  são hipóteses).
- Fan-out por cursor por handler. Não adotado: a entrega materializada por linha é a decisão desta versão (§1 e
  as alternativas). Um cursor volta por ADR novo, com a medição de volume.
- Partição da outbox e das entregas: por tempo, por tenant ou ambos (herdada do ADR-008).
- Como a política `authorize` de um comando trata o ator de sistema de um handler: uma concessão pela
  declaração `calls` ou um papel de sistema declarado. O nó `handler` da IR 0.1 não tem campo de papel, então o
  segundo caminho exigiria uma nova MENOR (ADR-001).
- Compatibilidade de versões de evento entre quem emite e quem consome durante um deploy.
- Publicação de eventos públicos para fora do processo.

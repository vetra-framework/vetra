# ADR-024: Resolução das questões em aberto do ADR-014

- Status: proposto
- Data: 2026-10-31
- Resolve: ADR-014 (as seis questões em aberto)
- Depende de: ADR-014 (outbox), ADR-005 (contexto assinado), ADR-008 (ordem dos eventos), ADR-015 (expand/contract)
- Relacionados: ADR-004 (capacidades), ADR-009 (workflows), ADR-013 (privacidade), ADR-016 (ciclo de vida),
  ADR-021 (campos de transição), ADR-023 (custo do contexto assinado)

## Contexto

O ADR-014 foi aceito com seis questões em aberto, e o índice pede tratá-las antes de implementar a persistência.
Este ADR não muda a decisão do ADR-014 (entrega pelo menos uma vez, reserva por lease, deduplicação por
`(handler, event_id)`, o handler como ator de sistema do tenant do evento com a autoridade dos seus `calls`). Ele
responde o que o ADR-014 deixou aberto, pela regra de resolução do índice.

| # | Questão | Tratamento |
|---|---|---|
| 1 | Padrões de tentativas, espera, lease e retenção | Valor inicial |
| 2 | Fan-out por cursor por handler | Já resolvida e adiada (gatilho de volume) |
| 3 | Partição da outbox e das entregas | Decidida |
| 4 | Como a política `authorize` trata o ator de sistema de um handler | Decidida |
| 5 | Compatibilidade de versões de evento durante um deploy | Decidida |
| 6 | Publicação de eventos públicos para fora do processo | Decidida e adiada |

## Questões

### 1. Padrões de tentativas, espera, lease e retenção

- Tratamento: **valor inicial**. Todos são hipóteses, escolhidas para ter um ponto de partida medível.
- **Tentativas máximas: 10.** Depois da décima falha retentável, a entrega vai a `dead`.
- **Espera entre tentativas:** `min(1800 s, 10 s × 2^(n−1))`, com variação aleatória de ±20%, em que `n` é o número
  da tentativa que falhou. Sem a variação, as nove esperas somam 4.350 s: uma entrega persiste cerca de **72
  minutos** antes de ir a `dead`. O motivo: cobrir uma indisponibilidade curta do provedor sem repetir o efeito a
  cada segundo.
- **Timeout do handler: 30 s por padrão; lease: 2 vezes o timeout, 60 s** (a regra do ADR-014, §2). O nó `handler`
  da IR 0.1 não tem campo de timeout, então um timeout por handler exigiria uma nova MENOR; até lá o padrão vale
  para todos. O compilador avisa quando a soma dos `timeout_ms` das capacidades externas que o handler usa passa
  do timeout padrão, porque um efeito que dura mais que o lease é repetido enquanto ainda roda.
- **Retenção:** 7 dias para entregas concluídas e eventos entregues (a regra do ADR-014, §7). As `dead` ficam até
  serem tratadas, e a mais antiga acima de 7 dias dispara um alerta.
- **O que pode revisá-los** (limiares também hipóteses): se mais de 1% das entregas mortas forem de um provedor que
  voltou depois da janela de 72 minutos, o teto da espera sobe; se mais de 0,1% das entregas forem repetidas por
  lease vencido com o efeito ainda em curso, o timeout padrão sobe. Medido pelas métricas do ADR-014, §7.

### 2. Fan-out por cursor por handler

- Tratamento: **já resolvida** e **adiada**.
- **Já resolvida:** o ADR-014 decidiu a entrega materializada por linha (§1) e rejeitou o cursor por handler nas
  alternativas, porque o estado de tentativas, espera e entrega morta passaria a ser por intervalo e uma falha
  isolada bloquearia o avanço do cursor.
- **Adiada, com gatilho.** O cursor volta por ADR novo, com medição, quando a criação de entregas pesar: a tabela
  de entregas, com a retenção de 7 dias, passar de **50 milhões de linhas**, ou o relay ficar mais de **10 s**
  atrás da outbox por mais de **5 minutos** por causa da criação de entregas (os dois limiares são hipóteses). O
  segundo vira métrica do ADR-014, §7: o atraso do relay.

### 3. Partição da outbox e das entregas

- Tratamento: **decidida**, com a granularidade como valor inicial.
- **Decisão 1: partição por tempo, nunca por tenant.** A retenção vira o descarte de uma partição inteira, em vez
  de um `DELETE` seguido de `VACUUM`. Por tenant seria inviável com os muitos tenants pequenos que o ADR-005 mira,
  e o relay lê por faixa de `xid8` do cluster, não por tenant; o isolamento entre tenants é do RLS.
- **Decisão 2: particionadas desde a primeira migração.** Particionar depois exige reescrever uma tabela cheia.
- **Decisão 3: a chave.** A chave de partição é `created_at` (o instante da inserção da linha na outbox). A chave
  primária da outbox é `(created_at, xid8, seq)`, porque o PostgreSQL exige a chave de partição na chave primária,
  e cada partição tem um índice `(xid8, seq)` para a leitura do relay (ADR-008, §2). A entrega guarda o
  `created_at` do evento, e sua chave única é `(handler, event_id, event_created_at)`: como o `created_at` é função
  do evento, a unicidade por `(handler, event_id)` do ADR-014, §3 se mantém.
- **Decisão 4: partições diárias** (valor inicial), criadas para os 3 dias seguintes por um job de manutenção, com
  uma partição `DEFAULT` como rede de segurança: uma linha nela é um alarme de que o job atrasou.
- **Decisão 5: a purga é `DETACH` e `DROP`** da partição mais antiga que a retenção. Uma entrega `dead` não pode
  ficar numa partição que será descartada: ao virar `dead`, ela e o payload do evento são copiados para
  `vetra.dead_deliveries`, que não é particionada, e saem da purga. O payload copiado continua com os campos
  pessoais cifrados (ADR-013, §6).
- **Alternativas rejeitadas:**
  - **Por `xid8`:** o PostgreSQL 16.15 aceita `PARTITION BY RANGE (xid8)`, e a poda do relay seria exata. Mas o
    `xid8` avança com toda escrita do cluster, não só com a outbox, então a faixa não corresponde a tempo, a
    retenção por tempo vira estimativa, e criar faixas adiante exige prever o `xid8`.
  - **Por tenant, ou por tenant e tempo:** pelo motivo acima.
  - **Sem partição, com `DELETE` em lote:** funciona em volume baixo, mas deixa dívida de `VACUUM` e custa mais.
- **Medido** (PostgreSQL 16.15, à mão, sem sonda versionada; limites na seção "Verificação preliminar"): a leitura
  de 500 eventos recentes pelo relay custou 0,63 a 0,65 ms na tabela sem partição e **0,93 a 1,01 ms com 8
  partições diárias** (cerca de 0,3 ms a mais: o plano é um `Merge Append` sobre um índice por partição, sem poda
  por `xid8`). Remover um dia de 100 mil linhas custou 344 ms por `DELETE` e **23 ms por `DETACH` mais `DROP`**.
- **Qual resultado decide o quê.** Na matriz de carga do gate G4, medir o custo da leitura do relay com a retenção
  de 7 dias (8 partições) e com partições horárias. Se o acréscimo sobre a tabela sem partição passar de **1 ms por
  leitura** (hipótese), a granularidade ou a retenção em partições é revista por ADR novo.

### 4. Como a política `authorize` trata o ator de sistema de um handler

- Tratamento: **decidida**.
- **Decisão 1: a concessão é a lista `calls`, sem papel de sistema declarado.** Quando o ator da operação é o
  sistema de um handler, a etapa 3 e a etapa 6 do ADR-016 autorizam o comando **se, e somente se, ele está nos
  `calls` desse handler**, lido do grafo. As condições de papel e de propriedade da política do comando não se
  aplicam a esse ator. Continuam valendo: o contrato de entrada, os campos de transição (ADR-021) e o tenant. Não
  precisa de campo novo na IR, e o segundo caminho que o ADR-014 citava (um papel de sistema declarado) fica
  rejeitado: exigiria uma nova MENOR e daria poder amplo, o que o ADR-014, §8 já rejeita.
- **Decisão 2: o ator de sistema no banco.** O contexto assinado (ADR-005) de um handler **não leva `actor_id`**.
  Leva `system_actor`, o identificador do handler, que o framework lê para a auditoria. Sem `actor_id`,
  `vetra.current_actor()` devolve `NULL`, e as políticas de escopo por vínculo não casam com ele (falha fechada).
  Como o handler precisa alcançar as linhas que o comando toca, as políticas de escopo geradas ganham uma segunda
  condição permissiva, `(SELECT vetra.is_system_actor())`, uma função nova do mesmo tipo das demais. O isolamento de
  tenant continua `RESTRICTIVE`: o ator de sistema alcança **o tenant do evento inteiro, não mais**. O limite fino,
  quais comandos, é do grafo. É uma extensão do formato `v1` do ADR-005 no mesmo sentido da que o ADR-011 fez para o
  agente, sem alterar o que o ADR-005 decidiu.
- **Decisão 3: um visitante não é um ator de sistema.** Um contexto sem `actor_id` e sem `system_actor` (o papel
  `visitor`) não satisfaz `is_system_actor()`.
- **Decisão 4: o diff arquitetural trata `calls` como permissão.** Hoje o `graph:diff` classifica um nó `handler`
  como `events` e `capabilities`, não como `permissions`. Como a lista `calls` passa a ser a concessão, acrescentar
  um comando a ela é uma mudança de permissão e precisa aparecer como tal na revisão.
- **Alternativas rejeitadas:**
  - **Um predicado "é sistema" em cada `authorize`:** cada comando teria de conhecer os handlers que o chamam, e a
    lista duplicada divergiria da `calls`.
  - **O handler herdar o escopo do ator original:** o ADR-014, §8 já a rejeita (o ator pode ter perdido o acesso).
- **A mesma regra vale para o ator de sistema de um workflow** (ADR-009, §7), cuja questão equivalente tem a sua
  resolução própria, depois.
- **Custo.** O ator de sistema acrescenta uma terceira função de contexto às políticas de escopo. Como cada função
  valida o token de novo, a medição do ADR-023 (questão 1) deve contar as funções de contexto por instrução. Se o
  custo passar do limiar, uma função única que devolve (tenant, ator, tipo) e valida uma vez é a saída (hipótese,
  não medida).

### 5. Compatibilidade de versões de evento durante um deploy

- Tratamento: **decidida**.
- **Regra 1: dentro de uma versão, só mudança aditiva.** Um campo opcional novo no payload é compatível, e o
  consumidor ignora campo desconhecido (leitor tolerante).
- **Regra 2: mudança incompatível é um evento novo, emitido junto com o antigo.** Remover ou renomear um campo,
  mudar o tipo ou o significado cria um evento com outro nome. Durante a transição, o mesmo comando **emite os
  dois**; os handlers migram para o novo; o antigo sai na fase contract, quando não há entrega pendente nem `dead`
  dele. Espelha o expand/contract do ADR-015.
- **Por quê.** Num deploy, o código antigo e o novo convivem, e a outbox guarda eventos por até 7 dias (e as
  entregas `dead` por mais). O código novo precisa ler o evento antigo, e o código antigo, que ainda roda em outros
  processos, precisa continuar recebendo o que entende.
- **O que já existe:** o `graph:diff` classifica a remoção de um campo de contrato como `breaking`, e o evento tem a
  projeção declarada; a regra 2 usa só emissões que o grafo já aceita (`emits` com mais de um evento).
- **Alternativas rejeitadas:**
  - **Vários `version` do mesmo evento aceitos por um handler:** o nó `event` da IR 0.1 tem um só `version`, então
    exigiria uma nova MENOR.
  - **Conversores na entrega:** lógica a manter para cada par de versões.
  - **Esperar a outbox esvaziar antes do deploy:** prende o deploy por até a retenção.
- **A checagem de contract** (nenhuma entrega pendente nem `dead` do evento antigo) é do `db:plan` e do
  `vetra doctor`.

### 6. Publicação de eventos públicos para fora do processo

- Tratamento: **decidida** (nenhum mecanismo novo) e **adiada** (o contrato externo).
- **Decisão: publicar para fora é um handler.** Um evento público que sai do processo é consumido por um handler
  cuja capacidade externa (webhook de saída, fila de terceiros) o envia, idempotente por `event_id` e com a chave
  que o provedor aceitar (ADR-004, ADR-014, §3). O dado pessoal do payload é decifrado pelo handler e enviado como
  qualquer integração externa, e o envio é registrado no Audit (ADR-013, §3).
- **Adiada, com gatilho:** o esquema publicado do payload, a assinatura das requisições de saída e a política de
  repetição para o destinatário externo. O gatilho é o primeiro requisito real de publicação.

## Consequências

- O ADR-014 passa a ter todas as questões tratadas. As duas que decidem estrutura (a partição e o ator de sistema)
  estão fechadas; as demais são valores iniciais com o que os revisa, ou adiadas com gatilho.
- O gerador de migrações cria a outbox e as entregas particionadas por tempo, com a partição `DEFAULT`, o job de
  manutenção e `vetra.dead_deliveries`.
- As políticas de escopo geradas ganham a condição do ator de sistema e a função `is_system_actor()`; o contexto
  ganha a claim `system_actor`.
- O `graph:diff` precisa classificar `calls` como permissão (hoje não classifica); o compilador precisa avisar
  quando o timeout padrão do handler é menor que a soma dos timeouts de suas capacidades. Nada disso foi
  implementado por este ADR.
- Uma mudança incompatível de evento custa duas emissões durante a transição.

## Garantia

| Garantia | Nível | Mecanismo |
|---|---|---|
| Um handler executa só os comandos que declara em `calls`, no tenant do evento | Estrutural, com os limites do ADR-004 | Concessão por `calls` e tenant do contexto |
| O ator de sistema alcança o tenant do evento, não outro | Transacional | Isolamento de tenant `RESTRICTIVE` (ADR-005) |
| Uma mudança em `calls` aparece como permissão na revisão | Verificável por testes | Categoria do `graph:diff` |
| A purga de um dia não toca entrega `dead` | Verificável por testes | `dead_deliveries` fora das partições |
| Uma mudança incompatível de evento não quebra o deploy | Operacional | Emissão dupla e checagem de contract |

Testes de aceitação das questões decididas:

1. A outbox e as entregas são criadas particionadas por tempo, com a partição `DEFAULT` vazia; uma linha nela
   dispara o alarme.
2. A purga remove a partição mais antiga que a retenção por `DETACH` e `DROP`, e uma entrega que virou `dead`
   continua em `vetra.dead_deliveries` depois dela.
3. A unicidade `(handler, event_id)` se mantém entre partições: o mesmo evento não gera duas entregas.
4. Um comando que não está nos `calls` do handler é recusado para o ator de sistema desse handler; um que está é
   autorizado sem as condições de papel e propriedade da política.
5. O ator de sistema do tenant A não lê nem grava linha do tenant B, nem com a condição de escopo permissiva.
6. Um contexto de visitante, sem `actor_id` e sem `system_actor`, não alcança linha protegida por escopo.
7. Acrescentar um comando aos `calls` de um handler aparece no `graph:diff` como mudança de `permissions`.
8. Um campo opcional novo no payload não quebra um handler antigo; remover um campo exige o evento novo, e o
   `db:plan` recusa o contract do evento antigo enquanto houver entrega pendente ou `dead` dele.
9. O compilador avisa quando a soma dos `timeout_ms` das capacidades de um handler passa do timeout padrão.

## Verificação preliminar

Conferido à mão, **sem sonda versionada**, num banco descartável do PostgreSQL 16.15 (não o 17 nem o 18), em um
sandbox de 4 CPUs, com 800 mil linhas (8 dias de 100 mil), um cliente, conexão local:

- `PARTITION BY RANGE (xid8)` é aceito pelo PostgreSQL 16.15 (só a criação foi exercitada).
- Leitura do relay (500 eventos recentes por `xid8`), duas execuções de 6 s: 0,63 e 0,65 ms sem partição; 1,01 e
  0,93 ms com 8 partições diárias. O plano é um `Merge Append` com um `Index Scan` por partição.
- Retenção de um dia de 100 mil linhas, uma execução: `DELETE`, 344 ms; `DETACH PARTITION`, 2,6 ms; `DROP
  TABLE`, 20,8 ms.

Também foi lido no código e no schema, sem executar: o `graph:diff` classifica o nó `handler` como `events` e
`capabilities` (`lib/vetra/graph/diff.rb`), e o nó `handler` da IR 0.1 não tem campo de timeout nem de papel
(`docs/ir/v0.1.schema.json`).

**O que isto não cobre.** Não houve concorrência, `INSERT` durante a leitura, `VACUUM` nem o custo de manter os
índices por partição na escrita; a carga é sintética. Os números fixam a ordem de grandeza dos limiares, não são
resultado de gate. Nada foi criado como código ou teste no repositório: o banco e os scripts eram descartáveis e
foram removidos.

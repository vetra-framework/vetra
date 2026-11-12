# Ponta a ponta e medição do executor (K20)

Fecha a rodada 5 da persistência: a sonda `script/sonda_ponta_a_ponta.rb` roda os quatro exemplos pelo executor, e a medição
`script/medir_executor.rb` refaz a medição do [ADR-023](../adr/023-resolucao-das-questoes-do-adr-005.md) com os comandos reais,
mede o custo da escrita em `vetra.idempotency` ([ADR-043](../adr/043-registro-de-idempotencia-da-operacao.md)), o da condição
`vt_system` ([ADR-036](../adr/036-papeis-e-contexto-assinado.md), K15), a construção dos registros contra o gate do
[ADR-022, §3](../adr/022-resolucao-das-questoes-do-adr-003.md) ([ADR-042](../adr/042-construcao-dos-registros.md)) e o pooler
transacional. Resultados no PostgreSQL 17.11 e no 18.6, em 2026-11-12.

**O que isto é e não é.** A medição é **informativa**. Ela **não cumpre o teste de aceitação 6 do ADR-023**, que exige uma
medição na CI que falhe acima do limiar: o script só falha nas conferências funcionais e relata cada limiar como dentro,
inconclusivo ou acima. Relatar percentuais não cumpre o teste, e nenhum limiar muda para acomodar um resultado. O gate do teste 6
continua pendente, e qualquer mudança do seu contrato é decisão formal do mantenedor.

## Como foi medido

- **Ponta a ponta.** Cada exemplo roda como está, sem cópia temporária nem fixture, no banco criado pelo plano commitado, como
  `vetra_app` (operação e borda em pools separados) e `vetra_relay` (relay). Os CRMs passam pela outbox, pelo relay e pelo handler
  de sistema real (`crm.notify_sales` e `crm.notify_seller`, com um provedor de e-mail simulado que registra a chave recebida).
- **Latência por comando.** Um cliente, o `Runner` completo (borda, admissão, unidade, guarda, fechamento): 20 chamadas de
  aquecimento e as medidas depois, cada comando com a entrada nova a cada chamada. A mediana e o p95 são do tempo de parede da
  chamada, em Ruby. É um cliente só: a latência com 16 clientes em laço fechado mede a contenção, e a questão 1 do ADR-023 já a
  mede por instrução.
- **Validações de contexto.** O banco conta as chamadas de `vetra.current_tenant()`, `current_actor()` e `is_system_actor()` de
  cada comando (`track_functions` e `pg_stat_user_functions`, com as duas sessões descarregadas por `pg_stat_force_next_flush()`).
  O rastreio custa por chamada, então ele só liga numa **passada à parte, em pools novos**; as séries cronometradas rodam sem ele.
  A sonda confere o contador com chamadas conhecidas (três chamadas contam três; a instrução da medição chama a função uma vez por
  linha). As instruções SQL de dados vêm do logger de cada pool.
- **Custo de uma validação.** `SELECT count(*) FROM generate_series(1, 20000) g WHERE g < 0 OR vetra.current_tenant() IS NOT NULL`
  contra a mesma instrução com `current_setting` (o RLS ingênuo da K13): a função roda uma vez por linha, e a diferença das
  medianas de 9 repetições, em ordem alternada, dividida por 20.000, é o acréscimo por validação. O mesmo, com 16 clientes em
  processos próprios, como na K13. O percentual de cada comando é **validações × custo ÷ mediana**: é uma estimativa, não uma
  subtração de duas execuções ruidosas.
- **Escrita em `vetra.idempotency`.** O mesmo comando (`blog.update_post`) sem chave, com chave nova (claim na etapa 4, complete
  na etapa 7) e na repetição da mesma chave, em ordem girada a cada rodada. Foi o blog porque as saídas do CRM levam e-mail (dado
  pessoal), e uma saída pessoal com chave é recusada antes da etapa 4 (ADR-043, §4; achado abaixo).
- **`vt_system`.** Duas cópias da tabela `leads` do CRM com revendas, com as políticas copiadas da tabela gerada (`pg_policies`),
  uma com `vt_system` e outra sem, 16 tenants de 2.000 linhas, 16 clientes em processos próprios. O ator comum é um gerente com
  vínculo em 10 revendas. A sonda confere que as duas devolvem as mesmas linhas ao ator comum, que só a com `vt_system` entrega o
  tenant ao ator de sistema e que o ator sem vínculo não lê nada em nenhuma.
- **Registros.** A mesma medição da K13 (10.000 leads, mediana de 7 execuções), refeita com o código atual dos repositórios.
- **Pooler.** O PgBouncer 1.26.1 em modo de transação, com 4 conexões de servidor, na frente dos dois pools; só roda se
  `VETRA_PGBOUNCER` aponta o binário (a CI não o instala, então lá essa parte é pulada e dita).

## Resultados

### Ponta a ponta (26 verificações, no 17 e no 18, e na CI)

Os quatro exemplos rodam pelo executor sem mudar o modelo, o plano nem a IR. O que passou:

- **CRM e CRM com revendas:** criar, ler, atualizar, concluir (`win_lead`, que emite `crm.lead.won` na etapa 7) e apagar; o relay entrega
  o evento e o handler real (`notify_sales`, `notify_seller`) chama o provedor com a chave `event:` derivada do handler e do evento;
  a segunda rodada do worker não reentrega; um lead sem vendedor conclui a entrega sem chamar o provedor; o vendedor de outra revenda
  não lê o lead; o lead de outro tenant não é alcançado.
- **Blog:** o autor cria, publica, lê e apaga; `create_post` com chave repete devolvendo o mesmo post e uma chave reutilizada com outra
  entrada vira 422; publicar duas vezes vira 422; apagar um post com comentário vira 409 (chave estrangeira).
- **Chat:** a dona cria a sala, escreve e lê a página; `add_member` e `remove_member` mudam o que a outra pessoa lê; `my_rooms` mostra
  só as salas do ator.
- **As duas recusas que a rodada assume**, ambas confirmadas: `chat.add_member_by_email` (o `uses` não concede `users_read`) e o
  comentário do visitante do blog (`data_authorization_rate_limit`, `rate_limit:` sem contador).

**Achados da sonda (nenhum bloqueia a K20; vão para a rodada 6 ou para o mantenedor):**

1. **`crm.win_lead` não aceita chave.** O comando declara `expose job ... idempotency: :required` (mini_crm), mas devolve o lead, que leva
   `email` (dado pessoal), e uma saída pessoal com chave é recusada antes da etapa 4 (`execution_idempotency_personal`, 422, ADR-043, §4).
   O executor faz o que o ADR manda, e o exemplo declara o que ele não consegue cumprir. Nenhum diagnóstico do compilador pega isso. A K19 já registrou
   que nenhum comando do CRM aceita chave por enquanto; a K20 o confirma com o exemplo real.
2. **O visitante do blog não lê nem o post publicado**, porque `crud scope: :author` fecha a leitura; o papel `visitor` com
   `where: { status: "published" }` não chega a valer. É o modelo do visitante da rodada 6.
3. **O papel do chat não concede `delete` de sala**, então `chat.delete_room` recusa para a dona. É o modelo, e não um defeito do executor.

### Duas contagens de transações (teste 1 do ADR-016)

Pela sonda, por comando, com o logger de cada pool: **a operação** (BEGIN no pool da aplicação) e **a borda** (BEGIN no pool dos fatos).
Nenhum relatório diz "zero transações do fluxo".

| Situação | BEGIN da operação | COMMIT da operação | BEGIN da borda |
|---|---|---|---|
| Comando concluído (crud, `call` Ruby, consulta) | 1 | 1 | 1 |
| Recusado na admissão (`data_authorization_denied`, `rate_limit`) | **0** | 0 | 1 |
| Recusado no corpo (`chat.add_member_by_email`) | 1 | 0 (rollback) | 1 |
| Falha do `call` (`fail!` 422) e conflito 409 | 1 | 0 (rollback) | 1 |
| Saída pessoal com chave (recusa antes da etapa 4) | 0 | 0 | 0 |

Em todos os comandos da tabela da sonda, o pool da operação só abre transação quando a admissão passa.

### Latência por comando e o limiar de 25% (ADR-023)

Um cliente, pelo `Runner`, 120 chamadas após 20 de aquecimento, PostgreSQL 17.11. As medianas absolutas oscilaram entre execuções neste
ambiente (uma máquina compartilhada; no 18.6 chegaram a dobrar em parte dos comandos), então o que se compara é o percentual, não o valor
absoluto. Quatro exemplos, 16 comandos.

**Custo de uma validação de contexto** (acréscimo da função assinada sobre o `current_setting` do RLS ingênuo): **48 µs** com um cliente
e **116 µs** com 16 clientes no 17 (47 µs e 106 µs no 18). É o preço de validar o token com a chave e comparar o MAC em tempo constante.

| Exemplo | Comando | Mediana (ms) | Validações (tenant/ator/sistema) | Acréscimo, custo de 1 cliente | Acréscimo, custo de 16 clientes | Sem as de sistema, 16 clientes |
|---|---|---|---|---|---|---|
| mini_crm_revendas | crm.read_lead | 7,3 | 22 (14/4/4) | 15% | 35% | 29% |
| mini_crm_revendas | crm.update_lead | 17,0 | 56 (34/11/11) | 16% | 38% | 31% |
| mini_crm_revendas | crm.create_lead | 11,5 | 33 (21/6/6) | 14% | 33% | 27% |
| mini_crm_revendas | crm.win_lead | 17,4 | 67 (40/14/13) | 19% | 45% | 36% |
| mini_crm | crm.read_lead | 2,8 | 2 (2/0/0) | 3% | 8% | 8% |
| mini_crm | crm.update_lead | 6,0 | 6 (6/0/0) | 5% | 12% | 12% |
| mini_crm | crm.create_lead | 4,8 | 3 (3/0/0) | 3% | 7% | 7% |
| mini_crm | crm.win_lead | 7,2 | 9 (8/1/0) | 6% | 14% | 14% |
| blog e chat (8 comandos) | — | 1,6 a 7,4 | 0 | 0% | 0% | 0% |

No PostgreSQL 18 os percentuais do CRM com revendas ficam em 12% a 19% (um cliente) e 27% a 42% (16 clientes); os do mini_crm, em 1% a 4% e
3% a 8%. Blog e chat não têm RLS: o contexto assinado não é validado, e a autorização é só a guarda do executor.

**Leitura dos limiares** (hipótese de 25% da latência do comando, ADR-023, questão 1):

- Com o custo medido com **um cliente**, a mediana dos comandos com RLS fica em 10% e o máximo em 19%: **dentro**.
- Com o custo medido com **16 clientes** (que é o cenário do ADR), a mediana fica em 24% (18% no 18) e o máximo em 45% (42%):
  **inconclusivo**, e os quatro comandos do CRM com revendas passam de 25% (33% a 45% no 17; 27% a 42% no 18).
- O número é uma **estimativa conservadora**: ele divide um custo por validação medido sob contenção pela latência medida sem
  contenção. Uma medição direta da latência de cada comando com 16 clientes em laço fechado não foi feita.
- **Onde está o custo.** Não é uma validação cara: é a quantidade. O `update_lead` do CRM com revendas faz **56 validações** em 19
  instruções SQL (34 de `current_tenant`, 11 de `current_actor`, 11 de `is_system_actor`), porque cada política de escopo e cada
  política de tenant referencia as funções de contexto por instrução e por tabela. O mini_crm, sem escopo, faz 2 a 9.
- **Regra do ADR-023:** passar de qualquer um dos dois limiares faz o desenho do ADR-005 voltar por ADR novo, com a alternativa medida.
  A medição **não** cumpre o teste 6 e não decide isso: relata que o resultado do CRM com revendas fica acima do limiar no cenário de
  16 clientes e dentro dele com um cliente. A decisão de abrir ou não esse ADR é do mantenedor.

### A condição `vt_system` no ator comum (K15)

16 clientes, 3 s por série, 3 rodadas, mediana e intervalo, custo por instrução em ms, no PostgreSQL 17.11 (o 18.6 fica de +0,16 a +0,60):

| Instrução | Sem `vt_system` | Com `vt_system` | Acréscimo |
|---|---|---|---|
| Busca por chave | 1,294 | 1,542 | +0,285 (+0,184 a +0,313) |
| Varredura do tenant (2.000 linhas) | 1,322 | 1,788 | +0,410 (+0,305 a +0,564) |
| `UPDATE` com `WITH CHECK` | 3,688 | 4,459 | +0,640 (+0,526 a +0,870) |
| `INSERT` com `WITH CHECK` | 1,464 | 1,494 | +0,030 (−0,077 a +0,225) |

A condição acrescenta de **0,03 a 0,64 ms por instrução** ao ator comum. No fluxo, ela responde por **4 a 13 das 22 a 67 validações** de cada
comando do CRM com revendas (`is_system_actor`, uma por instrução sobre tabela com a política). Sem elas, o acréscimo com 16 clientes cai
de 33%–45% para 27%–36%: tira de 6 a 9 pontos percentuais, e **não** leva sozinha todos os comandos para baixo de 25%. A maior parte do custo é
`current_tenant` e `current_actor`, que a saída da `vt_system` não toca.

**A saída (função única de contexto ou papel de banco próprio) é decisão do mantenedor.** Os números acima são a evidência. A K21 mediu as duas num
protótipo ([saidas-da-vt-system.md](saidas-da-vt-system.md)): cada uma tira de 18% a 20% das validações (a função única funde só o ator na chamada de tenant de cada subconsulta de
escopo, e o papel tira as de sistema), as duas juntas de 36% a 39%. A leitura que este relatório tinha, de que a função única "ataca as três contagens de uma vez", estava errada. Qualquer das
duas exige ADR novo e plano de banco, e nenhuma está implementada.

### Escrita em `vetra.idempotency` (ADR-043)

`blog.update_post` pelo Runner, 120 chamadas de cada tipo em ordem alternada, no 17.11 (mediana e p95, ms):

| Sem chave | Com chave nova (claim e complete) | Repetição com a mesma chave | Acréscimo da chave nova |
|---|---|---|---|
| 4,04 (p95 5,79) | 5,03 (p95 7,07) | 2,28 (p95 3,88) | **+0,99 ms (+24%)** |

No 18.6 o acréscimo foi de +26% (3,2 ms sobre 12,3 ms, numa execução mais lenta). A chave custa **um quarto da latência de um comando que já
escreve uma linha**: é o `INSERT` do claim, na etapa 4, e o `UPDATE` do complete, na etapa 7. A **repetição é mais barata que o comando sem
chave** (2,3 ms contra 4,0 ms): ela ainda abre a transação da operação e reivindica a chave na etapa 4 (`Runner#in_unit`), mas pula o corpo do
comando, a reautorização do estado final, o registro do resultado e a emissão dos eventos, e devolve o JSON guardado. A conferência funcional da medição prova que cada
chave nova gravou uma linha e que as repetições não gravaram outra.

### Construção dos registros contra o gate de 10% (ADR-022, §3; ADR-042)

10.000 leads, aproximação de 9 campos lógicos e 10 colunas, mediana de 7 execuções. É a medição da K13 (`records_gate`), refeita com o código
atual dos repositórios: ela lê pelo repositório numa unidade de leitura, **sem o `Runner`, sem a guarda de acessos da K18 e sem o fechamento
da K19**, que não estão no caminho medido. Ela mede, portanto, a construção dos registros, e **não** o custo da guarda por linha nem o de uma
coleção pelo executor (o filtro de coleção da guarda é em Ruby, de 200 em 200, e não foi medido).

| | Consulta (Sequel) | Repositório | Construção direta | µs por registro | Construção / consulta (razão das medianas) | Mediana das razões por execução (mínimo a máximo) | Limiar |
|---|---|---|---|---|---|---|---|
| PostgreSQL 17.11 | 187 ms | 272 ms | 82 ms | 8,2 | **44%** | 41% (37% a 50%) | 10% |
| PostgreSQL 18.6 | 201 ms | 276 ms | 88 ms | 8,8 | **44%** | 38% (23% a 65%) | 10% |

As duas estatísticas são diferentes: a coluna da razão das medianas divide as medianas independentes da consulta e da construção; a seguinte é a
mediana das razões de cada uma das sete execuções, que é o que a função `threshold` herdada usa. Ambas ficam **acima do gate**, como na C11
(40% a 56%) e na K13. O orçamento de 10% e o aceite do ADR-042 são decisões do mantenedor; a medição não muda o limiar.

### Pooler transacional

PgBouncer 1.26.1 em modo de transação, 4 conexões de servidor, na frente dos dois pools (operação e borda), no CRM com revendas:

| Comando | Direto (ms) | Atrás do pooler (ms) | Acréscimo |
|---|---|---|---|
| `crm.read_lead` | 7,5 | 10,2 | +2,7 |
| `crm.update_lead` | 13,4 | 17,2 | +3,8 |

(No 18.6: +1,4 e +1,4 ms.) O Runner funciona sem mudança, porque o contexto vai por `set_config(..., true)` dentro da transação; depois das
séries, nenhuma sessão ficou com contexto nem com transação aberta. O acréscimo vem dos saltos a mais por comando (a transação da borda e a
da operação passam pelo pooler), e não do custo de contexto. Esta parte só roda com `VETRA_PGBOUNCER` e **não roda na CI**, que não instala
o PgBouncer.

## O que não foi medido

- **Latência por comando com 16 clientes em laço fechado.** O percentual acima é estimado; a medição direta é a que decide o teste 6.
- **O teste de aceitação 6 do ADR-023 continua pendente.** Esta medição não falha acima do limiar, e relatar percentuais não o cumpre.
- Tabelas grandes: a `DatabaseFacts` lê as junções inteiras em `many_to_many`, e o filtro de coleção é em Ruby, de 200 em 200; a
  construção é medida em 10.000 linhas, numa consulta só.
- O relay e os handlers sob carga: a K20 prova o fluxo ponta a ponta; a queda do worker e o timeout são da C14 (ADR-048).

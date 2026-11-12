# Saídas para o custo da `vt_system`: material para a decisão do mantenedor (K21)

Documento de **decisão preparada, não decidida**. A K20 ([custo-executor.md](custo-executor.md)) mediu que a política `vt_system` responde por 4 a 13 das 22 a 67
validações de contexto de cada comando do CRM com revendas, e deixou ao mantenedor a escolha da saída. A K21 mede as saídas candidatas num protótipo e junta, para cada
uma, o que ela custa, o que ela arrisca e o que exige. **Nenhuma saída está implementada, nenhum ADR é novo e nenhum limiar mudou.** O teste de aceitação 6 do
ADR-023 continua pendente. Script: [`script/medir_saidas_vt_system.rb`](../../script/medir_saidas_vt_system.rb).

## A pergunta

O ADR-024, §4 decidiu que o ator de sistema (o handler) é uma **segunda condição permissiva** nas políticas de escopo: `vt_system`, `FOR ALL TO vetra_app`, com
`(SELECT vetra.is_system_actor())` em `USING` e em `WITH CHECK`. Todo ator comum paga essa condição em toda instrução sobre uma tabela com escopo, e cada uma das três
funções de contexto (`current_tenant`, `current_actor`, `is_system_actor`) valida de novo o token assinado (HMAC, jsonb, expressões regulares: de 48 a 116 µs por chamada, K20).

## As saídas

| Saída | O que é | O que muda | Origem |
|---|---|---|---|
| **0. Manter** | A `vt_system` como está (K15) | Nada; o custo do ator comum fica como a K20 mediu | ADR-024, §4 |
| **A. Papel de banco próprio** | O ator de sistema usa um login `vetra_system`; a permissiva vira `TO vetra_system USING (true)` e as políticas de escopo ficam só `TO vetra_app` | Sai a condição de sistema do caminho do ator comum; entra um terceiro papel de banco, outro pool para os handlers e outra linha no bootstrap | [K15](ator-de-sistema.md) (muda a decisão 2 do ADR-024: pede ADR novo) |
| **B. Função única de contexto** | `vetra.context()` valida o token uma vez por referência e devolve `(tenant, ator, sistema)`; dentro de uma subconsulta de escopo, tenant e ator saem de uma chamada só | Mudam as políticas geradas, a guarda de rotinas e o plano (expand/contract); nenhum papel novo | ADR-024, §4 ("hipótese, não medida") |
| **A + B** | As duas | Soma | — |

Fora do que se mediu, e **não proposto**: (i) **cache da validação por transação**, que o próprio `vetra_app` poderia forjar se o cache fosse uma configuração de sessão
(o contexto assinado existe justamente porque `set_config` é forjável) e que numa tabela temporária por sessão quebraria atrás do pooler em modo de transação; (ii) **baratear a
própria validação** (o custo por chamada, 48 µs com um cliente, não foi decomposto entre o HMAC, o jsonb e as expressões regulares): um eixo diferente, sem decisão de papel
nem de política, que esta medição não explorou; (iii) **reduzir as referências que o gerador emite** (cada política de escopo e cada política de tenant referencia as funções, e a
tabela `memberships`, lida dentro da subconsulta de escopo, traz a sua política de tenant junto).

## O que foi medido

**Protótipo, não implementação.** A sonda migra o CRM com revendas, instala `vetra.context()` (o corpo de `is_system_actor()` devolvendo os três valores) e **reescreve no lugar as
políticas de linha** (`pg_policies`) em quatro variantes: `atual` (a `vt_system` como está), `papel` (a política `vt_system` não existe para `vetra_app`, que é o que o ator
comum vê quando o ator de sistema tem papel próprio), `unica` (as referências às funções viram `vetra.context()`: dentro de uma subconsulta de escopo, tenant e ator saem de uma
chamada só) e `papel+unica`. Mede os quatro comandos de referência da K20 pelo `Runner`, com o gerente de 10 revendas (o ator comum), 120 chamadas após 20 de aquecimento, três
rodadas em ordem girada, e conta no banco as chamadas de cada função (`track_functions` numa passada à parte, como na K20). O custo por chamada com 16 clientes vem do método da K20.
Dezessete conferências funcionais passam no PostgreSQL 17.11 e no 18.6: a função única devolve o mesmo que as três (ator comum, ator de sistema, token inválido); em **cada**
variante, por conjunto de IDs, o ator comum lê exatamente os leads das revendas com vínculo (nenhum dos de uma revenda do mesmo tenant sem vínculo, nem dos de outro tenant), o sem vínculo não
lê nada, e o ator de sistema lê o tenant do evento inteiro, inclusive a revenda sem vínculo, e nenhuma linha de outro tenant (com a `vt_system`), ou nenhuma (sem ela).

### As validações por instrução (mesma contagem nas duas versões)

Contagem do banco para uma instrução do gerente sobre `leads`: **`SELECT`: 3 de `current_tenant`, 1 de `current_actor` e 1 de `is_system_actor`; `UPDATE` por chave: 11, 4 e 4;
`INSERT`: 4, 1 e 1.** As 3 de tenant de um `SELECT` são a política restritiva de `leads`, a condição de tenant dentro da subconsulta de escopo e a política restritiva de
`memberships`, que a subconsulta de escopo também atravessa (um `SELECT` só em `memberships` chama `current_tenant` uma vez). É o que explica os 56 do `update_lead` da K20:
11 avaliações da política de escopo de `leads` no comando, cada uma com 3 de tenant, 1 de ator e 1 de sistema (33 + 11 + 11), mais 1 de um gatilho.

### Validações por comando e variante

| Comando | `atual` (tenant / ator / sistema) | `papel` | `unica` (todas de `context()`, menos 1 de gatilho) | `papel+unica` |
|---|---|---|---|---|
| `crm.read_lead` | 22 (14 / 4 / 4) | 18 (−4) | 18 (−4) | 14 (−8, −36%) |
| `crm.update_lead` | 56 (34 / 11 / 11) | 45 (−11) | 45 (−11) | 34 (−22, −39%) |
| `crm.create_lead` | 33 (21 / 6 / 6) | 27 (−6) | 27 (−6) | 21 (−12, −36%) |
| `crm.win_lead` | 67 (40 / 14 / 13) | 54 (−13) | 54 (−13) | 41 (−26, −39%) |

Cada saída sozinha tira de **18% a 20%** das validações; as duas juntas, de **36% a 39%**. A `papel` tira as chamadas de sistema; a `unica` tira as de ator (uma por subconsulta de
escopo, fundida na de tenant) e deixa a condição de sistema onde está. A contagem não muda entre as duas versões do PostgreSQL nem entre execuções.

### O custo dessas validações e a latência

Custo por chamada (acréscimo sobre o RLS ingênuo): `vetra.current_tenant` **50,5 µs** com um cliente e **129,1 µs** com 16 no 17 (44,0 e 110,4 no 18); `vetra.context()` **50,1 µs** e
**132,6 µs** (44,1 e 130,7 no 18). Com um cliente as duas custam o mesmo; com 16, `context()` ficou de 3% (17) a 18% (18) acima, dentro da dispersão que o método tem (a série de
`current_tenant` no 17 foi de 123 a 148 µs). Numerador do percentual da K20 (validações × custo com 16 clientes), em ms, no PostgreSQL 17.11 (no 18.6, entre parênteses):

| Comando | `atual` | `papel` | `unica` | `papel+unica` |
|---|---|---|---|---|
| `crm.read_lead` | 2,84 (2,43) | 2,32 (1,99) | 2,39 (2,35) | 1,86 (1,83) |
| `crm.update_lead` | 7,23 (6,18) | 5,81 (4,97) | 5,96 (5,86) | 4,50 (4,43) |
| `crm.create_lead` | 4,26 (3,64) | 3,48 (2,98) | 3,58 (3,51) | 2,78 (2,73) |
| `crm.win_lead` | 8,65 (7,40) | 6,97 (5,96) | 7,16 (7,04) | 5,43 (5,34) |

A `papel` vale o que a contagem promete nas duas versões (−18% a −20% do numerador). A `unica` vale −16% a −18% no 17 e só −3% a −5% no 18, porque `context()` saiu mais cara por chamada com
16 clientes. **Essa diferença entre versões não está explicada**; com um cliente não aparece. A economia esperada por comando com a `papel`: de 0,4 a 1,7 ms (`update_lead`: −1,4 ms no 17 e
−1,2 ms no 18).

**A latência medida com um cliente não separa as variantes do ruído.** As medianas por variante diferem de −2,7 a +1,1 ms, com dispersão entre rodadas de cerca de 1 ms, e a `unica`
aparece mais lenta que a `atual` em dois comandos do 18. O que sustenta a comparação é a contagem do banco, não o relógio.

### O percentual da K20 e o que ele diz

O percentual (validações × custo com 16 clientes ÷ mediana do comando) é a regra da K20 e **depende do dia**: nesta execução a variante `atual` deu 41% a 60% no 17 e 34% a 50% no 18,
contra os 33% a 45% da K20, porque a mediana do `update_lead` caiu de 17,0 para 12,4 ms e o custo por chamada com 16 clientes subiu de 116 para 129 µs. A medição repetiu o problema da
K20 (máquina compartilhada); só a contagem é estável. Por isso a tabela abaixo é uma **projeção aritmética**: os percentuais da K20 no 17 multiplicados pela razão das contagens.

| | `atual` (K20) | `papel` ou `unica` | `papel+unica` |
|---|---|---|---|
| PostgreSQL 17, por comando (read, update, create, win) | 35%, 38%, 33%, 45% | 29%, 31%, 27%, 36% | **22%, 23%, 21%, 28%** |
| PostgreSQL 18, faixa | 27% a 42% | 22% a 34% | 16% a 27% |
| Veredito da função `threshold` (limiar 25%), só sobre estes quatro comandos | acima (mediana de 36,5%) | acima (mediana de 30%) | inconclusivo (mediana de 23%; 3 de 4 abaixo de 25%) |

O "inconclusivo" da K20 é o veredito sobre os **oito** comandos com RLS dos dois CRMs (mediana de 24%), onde os do `mini_crm`, sem escopo, puxam a mediana para baixo. A tabela acima olha só
os quatro do CRM com revendas, que são os que passam de 25%: neles a variante `atual` já está **acima**.

Medido nesta execução, com os denominadores desta execução, a mediana dos quatro comandos de cada variante ficou **acima de 25% em todas** (no 17: 50%, 42%, 43% e 33%; no 18: 41%, 37%,
39% e 32%; rodadas de 25% a 60%). **Nenhuma saída leva sozinha os comandos do CRM com revendas para baixo de 25%, e as duas juntas só chegam perto.**

## O que cada saída exige e arrisca

Tudo abaixo vem do código e dos ADRs; nada foi implementado.

### A. Papel de banco próprio

- **ADR novo**, porque muda a decisão 2 do ADR-024, §4 (o ator de sistema deixa de ser uma condição nas políticas do `vetra_app`).
- **Bootstrap (ADR-036).** Hoje o `role_guard` confere exatamente `vetra_app`, `vetra_migrator` e `vetra_owner`, e o `relay_guard` confere o `vetra_relay` (ADR-040, §3). Um
  `vetra_system` pediria o seu `LOGIN` e o seu guarda, as suas senhas e um pool novo (e outra entrada no PgBouncer).
- **Concessões e políticas.** O `vetra_system` precisa de `GRANT` em cada tabela da aplicação e da política `TO vetra_system USING (true)`. **Uma política restritiva só vale para os
  papéis que ela nomeia**: a `vt_tenant` de hoje é `TO vetra_app`, e se ela não nomear também o `vetra_system`, o papel novo, com uma permissiva `USING (true)`, leria **todos os
  tenants**. O teste 5 do ADR-024 ("o ator de sistema do tenant A não lê o do B") passa a ser o guarda dessa omissão. As políticas `TO vetra_app` que o fluxo do handler usa
  (`vt_outbox_insert`, `vt_idempotency_app`) também precisariam nomear o papel novo, ou o comando do handler falha fechado.
- **Execução (ADR-048).** O `HandlerRunner` recebe hoje um `Runner` com o pool `vetra_app` e o relay com o pool `vetra_relay`; passaria a receber um `Runner` com o pool do papel de sistema.
- **A fábrica de pools (ADR-039).** `Vetra::Data.connect` força `user: 'vetra_app'` e a conferência de cada conexão exige `current_user` e `session_user` iguais a `vetra_app`; informar outro
  usuário na conexão não basta. Um pool do papel de sistema pede adaptar a fábrica e a sua guarda, o que mexe no contrato do ADR-039.
- **Ganho de segurança, leitura do Claude e não medido.** Um contexto de requisição nunca viraria ator de sistema, mesmo que o emissor assinasse `system_actor` por engano, porque o pool
  dos atores não teria a permissiva; hoje a barreira é o claim assinado mais a lista `calls`. O ator de sistema continua preso ao tenant pelo token (`current_tenant()` na restritiva).
- **Custo medido**: o ator comum não paga nada pela existência do ator de sistema (é a variante `papel`). **Não medido**: o lado do ator de sistema (a sonda não cria o papel).

### B. Função única de contexto

- **ADR novo ou emenda ao ADR-024, §4**, que já a cita como "hipótese, não medida" e que a medição agora mede: a economia é de 18% a 20% das validações, não "as três contagens de uma vez".
- **Sem papel novo, sem pool novo, sem mudança no `Runner` nem no `HandlerRunner`.** O custo está no plano: as políticas de linha de toda tabela com escopo mudam de forma
  (migração expand/contract, ADR-015), `vetra.context()` entra na guarda de rotinas (`trusted_routine_sql`: só as definições conferidas por hash são terminais seguros do fecho C2) e o
  `graph:diff` e o `db:plan` precisam aceitar a forma nova.
- **A economia depende da forma da política.** A fusão acontece onde tenant e ator aparecem na mesma subconsulta de escopo; a política da outbox (`vt_outbox_insert`, tenant e ator sem
  subconsulta) não funde no protótipo, e a de tenant não tem o que fundir. O protótipo só reescreve políticas: os gatilhos `vt_authz_*` e `vt_transition_*` seguem chamando as funções antigas
  (no máximo 1 chamada por comando no protótipo).
- **Risco**: a reescrita de toda política de linha é uma mudança de autorização. O que a prova são as sondas de RLS e a equivalência por conjunto de IDs do ADR-041.

### 0. Manter

Nada muda e o resultado da K20 fica como está: inconclusivo com 16 clientes, e o CRM com revendas acima de 25%. Pelo ADR-023, passar do limiar faz o desenho do ADR-005 voltar por ADR novo
com a alternativa medida; abrir ou não esse ADR é a decisão (b) do mantenedor, e ela **não depende** de escolher uma saída aqui.

## Leitura do Claude (não é decisão)

- Nenhuma saída sozinha resolve a K20: cada uma tira cerca de um quinto das validações, e o CRM com revendas precisaria de mais de um terço. As duas juntas chegam, por projeção, a 21%–28% no 17.
  O que domina é a quantidade de referências (5 por instrução sobre `leads`, 3 delas de tenant), não o preço de cada uma.
- A é a que entrega o que a contagem promete nas duas versões do PostgreSQL e a única que protege o ator comum de um erro do emissor; custa operação (um papel, um pool, uma política a lembrar de
  nomear). B é de graça em operação, mas muda a forma de toda política e, no 18, rendeu menos do que a contagem sugere; **A e B não se excluem**.
- Um terceiro eixo, sem papel nem função nova, está inexplorado: **emitir menos referências**. A condição de tenant dentro da subconsulta de escopo repete o que a política restritiva de
  `memberships` já garante, e cada instrução sobre `leads` carrega 3 chamadas de tenant; cortar uma é cerca de um quinto de novo. Também não foi decomposto o custo da própria validação (48 µs).
- Se a decisão (b) for abrir o ADR-005, esta escolha pode mudar de natureza: o que vale então é qual desenho de contexto o novo ADR adota, e a `vt_system` entra nele.

## O que decidir (do mantenedor)

1. A saída: **0**, **A**, **B**, **A + B**, ou adiar até a decisão (b) sobre o ADR-005. Depois da escolha, o ADR (no próximo número livre, `proposto`) e a tarefa de implementação com auditoria cruzada são de um
   agente; a K21 não escreve nenhum dos dois.
2. Se **A**: aceitar mudar a decisão 2 do ADR-024, §4, o novo papel no bootstrap do ADR-036 e o segundo pool no `HandlerRunner` do ADR-048.
3. Se **B**: aceitar a forma nova das políticas de linha (expand/contract) e a guarda de rotinas com a função nova.
4. O teste 6 do ADR-023, o limiar de 25% e a decisão (b) continuam do mantenedor: **a K21 não os cumpre nem muda.**

## Limites desta medição

- É um **protótipo de políticas**, não implementação: os gatilhos não foram reescritos, o papel `vetra_system` não existe (a variante `papel` só retira a política, o que é o que o ator
  comum vê) e nenhum plano de migração foi gerado. Papéis globais não mudam (a sonda confere).
- Máquina compartilhada (WSL, 4 CPUs): o percentual absoluto oscila entre execuções (a K20 e esta diferem em 10 a 15 pontos); a latência com um cliente não separa as variantes. O custo por
  chamada com 16 clientes é uma estimativa: a latência de cada comando com 16 clientes não foi medida. A diferença entre o custo de `context()` e o de `current_tenant` no 18 não foi explicada.
- Base pequena (16 tenants, cerca de mil leads); o custo das validações não depende do tamanho da tabela, mas o plano de uma subconsulta com `vetra.context()` em tabelas grandes não foi
  olhado com `EXPLAIN`.
- O pooler (PgBouncer) e a CI de uma execução longa não entram; um passo informativo curto (20 amostras, 1 rodada) roda na CI para que o protótipo não apodreça.

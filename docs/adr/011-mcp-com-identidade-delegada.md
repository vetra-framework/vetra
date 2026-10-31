# ADR-011: MCP opt-in com identidade delegada, aprovação para comandos sensíveis e limite de taxa

- Status: aceito
- Data: 2026-10-30
- Depende de: ADR-007 (comando e adaptadores), ADR-016 (ciclo de vida da operação), ADR-005 (RLS e contexto
  assinado)
- Dependem deste ADR (na data do aceite): nenhum. Os ADRs 001, 007 e 016 o citam, mas valem sem ele.
- Relacionados: ADR-001 (compatibilidade da IR), ADR-004 (capacidades), ADR-013 (privacidade e auditoria),
  ADR-017 (money), ADR-020 (revisão de autorização)

## Contexto

A proposta quer que agentes de IA operem sistemas Vetra: ler dados e executar comandos pelo Model Context
Protocol (MCP), sob as mesmas políticas dos usuários. O grafo é uma boa fonte para isso, porque descreve cada
operação com contrato de entrada e de saída e uma política.

Mas um agente não é um usuário:

- **Uma permissão do usuário não implica que um agente deva usá-la sem confirmação.** O usuário pode excluir um
  cliente; isso não quer dizer que um agente, conduzido por um texto que ele leu, deva fazê-lo sozinho.
- **Os argumentos que vêm do agente são entrada não confiável.** Ele pode ter sido induzido por um texto
  malicioso num documento, e-mail ou página que processou (injeção de prompt).
- **Agentes são rápidos e repetitivos.** Um laço descontrolado faz em segundos o que um usuário não faria.

O MCP é uma **extensão** do roadmap (fase final), não parte da fundação. O núcleo funciona integralmente sem ele.

## Decisão

**Nenhum comando é exposto a agentes por padrão. Quando exposto, o agente tem identidade própria e atua por
delegação de um usuário, com permissões que são um subconjunto das dele e prazo de validade. Todo comando exposto
declara se exige aprovação humana, e o compilador impõe um piso (exclusão, permissões e dinheiro). Os argumentos
do agente são entrada não confiável, sempre validados pelo contrato. Há limite de taxa e registro da decisão do
agente.**

### 1. Exposição é opt-in e declarada

- Um comando ou consulta só é uma ferramenta MCP se declarar a exposição (ADR-007: nada é exposto por padrão, nem
  ao MCP). A superfície MCP é mais uma exposição do mesmo comando; o contrato (o mesmo de entrada, ADR-007, §7),
  a política, a transação e a auditoria são os das outras superfícies.
- A exposição diz **o que** pode virar ferramenta: o nome da ferramenta e, num comando, a decisão de aprovação
  (§3). **Quem** pode usá-la é a delegação (§2), que é dado de runtime e não faz parte do grafo.
- **A IR 0.1 não representa essa exposição.** O `surface` de um `route` só aceita `http`, `cli`, `job` e
  `webhook`, e o `docs/ir/README.md` já diz que o MCP não está no formato 0.1. Representá-la (a superfície `mcp`,
  o nome da ferramenta e a decisão de aprovação) exige uma nova MENOR da IR, com `vetra.mcp` em `requires` (ADR-001,
  política de compatibilidade). O DSL do protótipo só tem `expose http:`.
- Uma ferramenta de **comando** exige chave de idempotência, como o webhook (ADR-007, §4): o adaptador acrescenta
  ao esquema da ferramenta um argumento reservado `idempotency_key`, **fora do contrato** do comando. Uma
  ferramenta de consulta não tem chave (ADR-007, §5).
- O **catálogo de ferramentas é gerado do grafo**: o nome, a descrição e os esquemas de entrada e de saída vêm
  dos contratos. Só as operações declaradas aparecem, e o catálogo que um agente recebe é a **interseção** entre
  as exposições declaradas e o escopo da sua delegação (§2). O grafo inteiro nunca é entregue ao agente (ADR-001,
  projeção autorizada).
- Valores monetários, datas e campos pessoais seguem as regras de cada tipo (ADR-017, ADR-013).

### 2. Identidade própria, por delegação

- O agente é um **ator distinto** (tipo agente), nunca o usuário. Toda ação carrega **quem é o agente** e **por
  quem ele age**.
- **Uma credencial MCP pertence a uma única delegação.** O tenant, o delegante e o escopo vêm do registro da
  delegação, nunca da chamada: nem o corpo nem os argumentos escolhem o tenant (ADR-016, etapa 1). Como a
  credencial é emitida e autenticada fica em aberto.
- A delegação é um registro `vetra.delegations`, tabela do framework com `tenant_id`, `ENABLE` e `FORCE ROW LEVEL
  SECURITY` como toda tabela multiempresa (ADR-005). Tem o **delegante** (um usuário), o **agente**, o
  **escopo**, `expires_at` e `revoked_at`. Nesta versão o escopo é um **conjunto de ferramentas** (exposições
  declaradas). Um escopo mais fino, por campo ou por valor de argumento, não existe (veja as questões em aberto).
- A permissão efetiva é a **interseção** entre a política do delegante e o escopo da delegação, avaliada pelo
  mesmo motor nas etapas 3 e 6 do ADR-016. Um agente nunca tem mais poder que quem o delegou.
- **O contexto assinado (ADR-005) mantém o delegante em `actor_id` e acrescenta duas claims, `agent_id` e
  `delegation_id`, sempre juntas.** As políticas de escopo geradas leem `vetra.current_actor()`. Com o delegante
  ali, o banco enxerga o agente exatamente como enxerga o usuário, e o RLS nunca dá ao agente mais do que o
  usuário tem. Se `actor_id` fosse o agente, ele não teria vínculo nenhum e toda política de escopo teria de
  aprender a ler delegações. A restrição **dentro** do que o usuário pode (o escopo) é da aplicação, nas etapas 3
  e 6.
- O formato continua `v1`: o payload é JSON, o MAC cobre o payload inteiro, e a função do banco lê só as claims
  que já lê (`tenant_id`, `actor_id` e `cmd`), então uma claim a mais não a afeta. Isso é um requisito da
  implementação, e o teste de aceitação 14 o cobre. O framework lê `agent_id` e `delegation_id` na etapa 7 para
  gravá-las na auditoria e no histórico (ADR-013). O banco não ganha função nova nesta versão.
- O contexto vale 30 s (ADR-005), então é **emitido a cada chamada** e nunca guardado com a delegação.
- A delegação tem **validade curta** e é **revogável**. Ela é uma tabela de permissão no sentido do ADR-020, §2: o
  framework a cria com o trigger de instrução que incrementa a revisão de autorização do tenant na mesma
  transação, então qualquer mudança nela, até por SQL direto, gera revisão.
- **O que "suspender o agente" quer dizer.** Uma chamada nova é recusada na etapa 1 se a delegação expirou ou foi
  revogada. Numa operação já aberta, a etapa 6 relê a linha da delegação **dentro da transação, com `FOR SHARE`**,
  e desfaz a operação se ela foi revogada ou expirou (contra `transaction_timestamp()`, como o ADR-005 faz com o
  contexto). O `FOR SHARE` serializa a revogação com as operações do agente: a revogação (um `UPDATE`) espera as
  operações abertas daquela delegação terminarem, e as operações da mesma delegação não esperam umas pelas outras.
  Ou a operação confirma antes da revogação, ou vê a revogação e é desfeita; nunca as duas. Uma operação que já
  passou da etapa 6 conclui.

### 3. Comandos sensíveis exigem aprovação humana

**Quem classifica.** Quem declara a exposição de um **comando** ao MCP escreve `approval: :required` ou
`approval: :none`. Não há padrão: omitir é erro de compilação. Uma consulta não escreve e dispensa a declaração.

**Um piso que o compilador deriva da IR e não deixa baixar.** Um comando que cai em qualquer um destes casos e
declara `approval: :none` é erro de compilação, sem forma de sobrescrever nesta versão. Quem discorda do piso tira
o comando do MCP.

- **Exclusão:** a `authorize` do comando tem a ação `delete` (inclui o `crud.delete` gerado).
- **Alteração de permissões:** a entidade da `authorize` é um vínculo de permissão, uma das que têm o trigger de
  revisão de autorização do ADR-020, §2.
- **Operação financeira:** o contrato de entrada ou de saída tem um campo `money` (ADR-017).

**O piso é um mínimo, não uma garantia.** A IR 0.1 não registra o que o `call` escreve, só a ação e a entidade que
o comando autoriza. Um comando que apaga ou move dinheiro por dentro do `call`, sob outra ação e sem campo `money`
no contrato, não é pego: vale a declaração de quem o escreve (§6). Esses três critérios ainda não existem no
compilador.

**O ciclo de uma chamada sensível.**

1. As etapas 1 a 3 do ADR-016 rodam sobre a chamada do agente (credencial, delegação, contrato e autorização). Se
   passam e o comando é `approval: :required`, o framework grava uma **aprovação pendente** e responde
   `pending_approval` com o `approval_id`. A transação do comando **não é aberta**: a unidade de trabalho só
   começa na etapa 4. A aprovação pendente é uma escrita do fluxo de aprovação, anterior à operação.
2. A aprovação pendente guarda o tenant, a delegação, o comando, a chave de idempotência, a entrada, o prazo, o
   estado e um **resumo**: o hash da entrada validada, em forma canônica, junto do tenant, da delegação, do comando
   e da chave. A aprovação vale para **aquele** comando, com **aqueles** argumentos, naquela delegação e com
   aquela chave. A mesma chamada repetida enquanto a aprovação pende devolve a mesma aprovação.
3. Quem aprova é um **humano**. Aprovar é uma operação do framework que só aceita um contexto **sem** `agent_id`;
   um token de agente nunca a executa, então o agente não se aprova por construção. O aprovador padrão é o
   delegante; outros aprovadores dependem de política (em aberto). A interface mostra o comando e os argumentos
   (§6). A aprovação é uma operação e passa pelas oito etapas, com a própria auditoria (quem aprovou, quando e o
   resumo).
4. Aprovar **não executa**. Quando o agente **repete a chamada** com a mesma chave, as etapas 1 a 3 rodam de novo,
   **com o estado de agora**: a delegação pode ter sido revogada, o usuário pode ter perdido a permissão. A
   aprovação dispensa só o passo humano, não a autorização. Se o resumo bate com uma aprovação aprovada, não
   expirada e não consumida, a etapa 4 a **consome** (`UPDATE ... WHERE estado = 'approved'`) na mesma transação
   em que grava o registro de idempotência. O commit a consome; o rollback a devolve, e ela continua valendo até
   expirar. Repetida depois do commit, a mesma chave devolve o resultado guardado (ADR-016) e não executa de novo.
5. Uma aprovação rejeitada ou expirada recusa a chamada seguinte. Para tentar de novo, o agente usa outra chave, e
   o limite de taxa (§5) vale para os pedidos.

**O dado pessoal da aprovação pendente.** A entrada guardada é mais um lugar onde dado pessoal persiste, fora do
histórico e da auditoria. Os campos pessoais dela são cifrados pela DEK do titular (ADR-013, §6), como na outbox e
no histórico de workflow (ADR-009, §7). Se o titular é eliminado, a aprovação não pode ser executada: falha
fechada e é cancelada, sem expor o dado. A entrada é apagada quando a aprovação é consumida, rejeitada ou expira;
o registro da decisão (quem, quando, resumo) permanece.

### 4. Entrada não confiável

- Os argumentos vindos do agente passam pela **mesma validação de contrato** das outras superfícies (ADR-016,
  etapa 2). Nada do que o agente envia é interpretado como instrução do sistema.
- O que o sistema devolve ao agente também pode carregar texto malicioso para uma próxima etapa. A saída é
  restrita pelo contrato de saída e por tudo que o **delegante** pode ler (a etapa 6 e o RLS, os mesmos da
  operação). Uma restrição de campos própria da delegação não existe nesta versão: o escopo limita as operações,
  não os campos. Campos pessoais seguem a classificação (ADR-013).
- Um comando exposto ao MCP é projetado como se **qualquer** argumento fosse hostil.

### 5. Limite de taxa e registro da decisão

- Há **limite de taxa** por identidade de agente e por delegação, além dos limites do papel. Ele é aplicado na
  etapa 1, **antes de qualquer acesso ao banco**. Onde o contador mora fica em aberto.
- Cada chamada de comando tem uma **chave de idempotência** (§1): uma repetição do agente não duplica o efeito, e a
  mesma chave com entrada diferente é recusada (ADR-016).
- A decisão do agente fica registrada em lugares diferentes, conforme onde ela ocorre:

| Decisão | Onde fica |
|---|---|
| Executada, ou falhou depois da etapa 4 | Audit, na transação da operação, com `agent_id`, `delegation_id` e, se houve, `approval_id` (ADR-013; ADR-016, etapa 7) |
| Pendente, aprovada, rejeitada, expirada ou consumida | O registro da aprovação, com quem decidiu e quando |
| Recusada nas etapas 1 a 3 (credencial, delegação, escopo, contrato, permissão ou taxa) | Log estruturado e métricas por agente e por delegação, sem valor pessoal (campos e resumo, nunca o valor). **Não** vai para o Audit |

- Isso reduz o que o texto anterior prometia (as chamadas recusadas na auditoria). Uma recusa nas etapas 1 a 3 não
  abre transação (ADR-016, teste 1) e, sem transação, não há onde gravar no Audit, que é gravado na etapa 7.

### 6. O que isto não garante

- O Vetra **não impede** um agente de repassar a um provedor de modelo os dados que a delegação permitiu que ele
  leia. A defesa é restringir o que a delegação lê e o que sai (operações, taxa e auditoria), mas o dado entregue
  ao agente passou do controle do sistema.
- A **classificação de sensibilidade é responsabilidade de quem declara o comando**. O piso do §3 cobre só o que a
  IR enxerga (ação, entidade e campos `money` do contrato). Um comando destrutivo fora do piso e declarado
  `approval: :none` é executado sem aprovação.
- A aprovação humana depende de a pessoa entender o que aprova; a interface de aprovação deve mostrar a ação e
  os argumentos, não só um "continuar?".
- A atribuição ao agente na auditoria é gravada pelo framework: é tão forte quanto o código que a grava (ADR-005,
  tabela de ameaças).
- As recusas das etapas 1 a 3 não estão no Audit do tenant (§5).

## Alternativas rejeitadas

- **O agente com a identidade integral do usuário** (a alternativa da proposta): qualquer coisa que o usuário
  pode, o agente faz sem confirmação, e a auditoria não distingue quem agiu.
- **Expor todos os comandos ao MCP por padrão:** transforma cada comando numa superfície de ataque sem decisão.
- **Aprovação genérica por sessão:** uma aprovação concedida uma vez serviria a qualquer ação seguinte, inclusive
  uma induzida.
- **Confiar que o modelo "sabe" o que é perigoso:** a segurança tem de estar no servidor, não na obediência do
  agente.
- **Filtrar prompts em busca de injeção:** não é confiável como barreira; o contrato e a política são.
- **Credencial longa e compartilhada para agentes:** sem prazo, sem revogação e sem rastro por agente.
- **Classificação opcional, com padrão "não sensível":** um comando de escrita esquecido executaria sem aprovação,
  em silêncio.
- **Derivar toda a sensibilidade do `call`:** a IR 0.1 não registra o que o `call` escreve, e a análise do Ruby não
  enxerga escrita dinâmica. O compilador deriva só o piso do §3.
- **O agente como `actor_id` do contexto:** as políticas de escopo leem `vetra.current_actor()`; o agente não tem
  vínculo e não veria nada, e cada política teria de aprender a ler delegações, com a interseção escrita em SQL.
- **Autorizar só na chamada, antes da espera:** a aprovação pode chegar horas depois, e a delegação, ou a
  permissão do usuário, mudar nesse tempo.
- **Executar ao aprovar, na requisição de quem aprova:** a operação rodaria no pedido do aprovador, e o agente
  perderia o limite de taxa, a chave de idempotência e o resultado da própria chamada.
- **Gravar no Audit as recusas das etapas 1 a 3:** contradiz o teste 1 do ADR-016 e o motivo dele (a recusa é
  barata e não pega conexão do pool), faz de cada recusa de um agente em laço uma escrita (a amplificação que o
  limite de taxa existe para evitar), e uma credencial inválida nem tem tenant para o RLS.
- **Revogar sem trava, só relendo a delegação:** deixa uma janela entre a leitura e o commit em que a operação de
  um agente revogado ainda confirma.

## Consequências

- Mais governança, menos automação irrestrita: é a troca que a proposta assume.
- Todo comando exposto a agentes precisa declarar a aprovação e ter um contrato bem definido. Esquecer é erro de
  compilação, e o piso do §3 não se baixa.
- A IR precisa de uma nova MENOR para representar a exposição MCP; até lá o grafo não tem onde registrá-la. O diff
  arquitetural precisa tratar a mudança de `approval:` de `required` para `none` como mudança de superfície que
  exige revisão.
- Duas tabelas do framework, delegações e aprovações, com revogação, expiração e remoção da entrada pendente.
- A latência de um comando sensível inclui a espera por uma pessoa, e o agente precisa repetir a chamada depois da
  aprovação.
- O contexto assinado ganha duas claims (agente e delegação) e a auditoria ganha três campos (agente, delegação e
  aprovação).
- Cada operação de agente paga um `FOR SHARE` na linha da delegação. Os bloqueios compartilhados não esperam uns
  pelos outros, mas muitos ao mesmo tempo na mesma linha criam um multixact; o limite de taxa limita isso, e o
  custo é uma hipótese a medir na fase 1.
- Uma recusa nas etapas 1 a 3 aparece no log e nas métricas, não na auditoria do tenant.

## Garantias e seus níveis

| Garantia | Nível | Mecanismo |
|---|---|---|
| Um comando só é alcançável pelo MCP se declarado | Estrutural | Exposição opt-in (ADR-007) |
| Todo comando exposto declara a aprovação, e o piso não se baixa | Estrutural, limitado | Erro de compilação; o piso cobre só o que a IR enxerga (§3) |
| O agente nunca pode mais que o delegante | Estrutural no tenant e no escopo; verificável por testes dentro do escopo da delegação | RLS com o delegante como `actor_id`; interseção avaliada pelo mesmo motor |
| Uma operação sensível não executa sem aprovação | Verificável por testes | Estado pendente antes da etapa 4 |
| A aprovação não vale para outra entrada, delegação ou chave | Verificável por testes | Aprovação presa ao resumo |
| A aprovação vale uma vez e não sobrevive a uma revogação | Verificável por testes | Consumo na etapa 4; etapas 1 a 3 repetidas depois da aprovação |
| O agente não aprova a si mesmo | Estrutural | Aprovar só aceita contexto sem `agent_id` |
| Argumentos hostis não ultrapassam o contrato | Verificável por testes, não prova | Validação do contrato; testes adversariais |
| A revogação suspende o agente | Transacional e verificável por testes | `FOR SHARE` na etapa 6 (§2) e revisão de autorização (ADR-020) |
| A ação do agente é atribuída a ele na auditoria | Transacional; vale o que vale o código que grava | Claims do contexto lidas na etapa 7 |
| O dado pessoal da aprovação pendente não fica em claro | Verificável por testes | Cifra por DEK do titular (ADR-013, §6) |
| Dado entregue ao agente não é repassado | **Fora da garantia** | Só se limita o que sai |

## Testes de aceitação

1. Um comando sem exposição MCP não aparece no catálogo nem pode ser chamado como ferramenta.
2. O catálogo de uma delegação é exatamente as exposições declaradas que o escopo dela inclui, com os esquemas dos
   contratos.
3. Um agente não executa uma operação que o delegante não pode executar.
4. Uma delegação expirada ou revogada recusa a chamada. Uma revogação confirmada antes da etapa 6 de uma operação
   aberta a desfaz, e uma revogação feita durante a operação espera por ela: nunca as duas coisas.
5. Uma chamada sensível fica pendente e **não abre transação** até ser aprovada.
6. Uma aprovação para uma entrada não autoriza a mesma operação com um argumento alterado, nem em outra delegação
   ou com outra chave.
7. O agente não consegue aprovar a própria chamada: aprovar com um contexto que tem `agent_id` é recusado.
8. Argumentos adversariais (texto com instruções, valores fora do contrato, campos extras) são recusados ou
   tratados como dados.
9. O limite de taxa por agente e por delegação é aplicado antes de qualquer acesso ao banco.
10. A auditoria registra o agente, o delegante, a delegação e a aprovação das operações que chegaram à etapa 4. O
    registro da aprovação guarda cada decisão. As recusas das etapas 1 a 3 não abrem transação e aparecem no log
    sem valor pessoal.
11. Uma repetição da mesma chamada do agente, com a mesma chave, não duplica o efeito. Um comando chamado sem
    `idempotency_key` é recusado.
12. A saída de uma ferramenta não contém campo que o delegante não pode ler.
13. Um comando exposto ao MCP sem `approval:` não compila. Um comando com `authorize` de `delete`, de entidade de
    vínculo de permissão, ou com campo `money` no contrato, e `approval: :none`, não compila.
14. Um token `v1` com as claims `agent_id` e `delegation_id` valida com o mesmo tenant e o mesmo ator de um sem
    elas; adulterar uma das claims invalida o MAC; e uma consulta do agente vê só o que o delegante vê.
15. Depois da aprovação, uma delegação revogada, ou um usuário que perdeu a permissão, recusa a chamada. A
    aprovação não é consumida por uma tentativa recusada.
16. Uma aprovação é consumida no commit e devolvida no rollback. A mesma chave repetida depois do commit devolve o
    resultado guardado.
17. Eliminado o titular de um dado pessoal da entrada, a aprovação pendente falha fechada e é cancelada, sem
    expor o dado. Consumida, rejeitada ou expirada, a entrada é apagada.

## Verificação preliminar

Conferido à mão, **sem sonda versionada**, no PostgreSQL 16.15: duas transações que leem a mesma linha com
`FOR SHARE` não esperam uma pela outra; um `UPDATE` da mesma linha (a revogação) espera a transação que a trava e
só passa depois do commit dela (com `lock_timeout` de 1 s, falhou enquanto a transação estava aberta e funcionou
depois). É a base do §2.

Não existem a exposição MCP na IR (o `surface` aceita `http`, `cli`, `job` e `webhook`), o DSL dela (o protótipo
só tem `expose http:`), o piso de sensibilidade no compilador, as delegações, as aprovações, o adaptador MCP nem o
limite de taxa.

## Questões em aberto

- Como o agente se autentica no servidor MCP e como a credencial de uma delegação é emitida e revogada. O §2 fixa
  só que uma credencial pertence a uma única delegação.
- A interface e o canal de aprovação humana, o prazo da aprovação, quem pode aprovar além do delegante e o que o
  aprovador vê de um campo que a sua própria permissão não lê.
- Validade e limite de taxa padrão das delegações, e onde o contador do limite mora com vários processos.
- Um escopo mais fino que a ferramenta: campos de saída por delegação (por exemplo, campo pessoal só se a
  delegação o listar) e restrição de valores de argumento. Sem isso o teste 12 cobre só o que o delegante lê.
- Quais consultas podem ser ferramentas de leitura, e como limitar a exfiltração por leituras repetidas.
- Se um deploy invalida as aprovações pendentes: o resumo não inclui o digest do grafo, então uma aprovação
  sobrevive a uma mudança do comando dentro do prazo.
- Um registro das tentativas recusadas que o administrador do tenant possa consultar, sem a amplificação de uma
  escrita por recusa.
- A representação exata na IR (nova MENOR): o `config` do `route` com a superfície `mcp`, o nome da ferramenta e
  a aprovação, e como o diff arquitetural a classifica.
- Um conjunto de testes adversariais de injeção de prompt e como ele evolui.

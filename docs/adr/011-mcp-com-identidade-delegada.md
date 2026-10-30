# ADR-011: MCP opt-in com identidade delegada, aprovação para comandos sensíveis e limite de taxa

- Status: proposto
- Data: 2026-10-30
- Depende de: ADR-007 (comando e adaptadores), ADR-016 (ciclo de vida da operação), ADR-005 (RLS e contexto
  assinado)
- Relacionados: ADR-004 (capacidades), ADR-013 (privacidade e auditoria), ADR-020 (revisão de autorização)

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
delegação de um usuário, com permissões que são um subconjunto das dele e prazo de validade. Comandos
classificados como sensíveis exigem aprovação humana explícita. Os argumentos do agente são entrada não
confiável, sempre validados pelo contrato. Há limite de taxa e auditoria completa da decisão do agente.**

### 1. Exposição é opt-in e declarada

- Um comando ou consulta só é uma ferramenta MCP se declarar a exposição, num bloco próprio com a delegação e
  a aprovação (ADR-007: nada é exposto por padrão, nem ao MCP). A superfície MCP é mais uma exposição do mesmo
  comando; o contrato, a política, a transação e a auditoria são os das outras superfícies.
- O **catálogo de ferramentas é gerado do grafo**: o nome, a descrição e os esquemas de entrada e de saída vêm
  dos contratos. Só as operações declaradas aparecem; o grafo inteiro nunca é entregue ao agente.
- Valores monetários, datas e campos pessoais seguem as regras de cada tipo (ADR-017, ADR-013).

### 2. Identidade própria, por delegação

- O agente é um **ator distinto** (tipo agente), nunca o usuário. Toda ação carrega **quem é o agente** e **por
  quem ele age**.
- A delegação é um registro com **o usuário delegante, o agente, o escopo concedido e a validade**. O escopo é
  um **subconjunto** do que o usuário pode: a permissão efetiva é a **interseção** entre as políticas do
  usuário e as da delegação, avaliada pelo mesmo motor (ADR-016, etapa 3 e etapa 6). Um agente nunca tem mais
  poder que quem o delegou.
- O contexto assinado da operação (ADR-005) passa a carregar a identidade do agente e a delegação, além do
  ator. O formato atual do contexto não os tem; o ADR-005, ainda proposto, deve acrescentá-los (veja as questões
  em aberto).
- A delegação tem **validade curta** e é **revogável**. Ela é uma tabela de permissão no sentido do
  ADR-020: sua mudança incrementa a revisão de autorização do tenant, então uma revogação suspende o agente em
  andamento do mesmo modo que uma revogação de acesso suspende uma assinatura.

### 3. Comandos sensíveis exigem aprovação humana

- Uma operação **sensível** não executa por chamada do agente. A chamada fica **pendente de aprovação**; só
  depois de um humano aprovar ela segue para a etapa 4 do ADR-016. A aprovação ocorre **antes de abrir a
  transação**.
- A classificação inicial de sensíveis inclui **exclusão**, **operações financeiras** e **alteração de
  permissões**. É um mínimo; quem declara o comando pode classificar outros.
- A aprovação é **presa à entrada exata**: ela vale para aquele comando com aqueles argumentos (identificados
  por um resumo da entrada), por tempo limitado. Se o agente alterar um argumento depois da aprovação, a
  aprovação não vale.
- Quem aprova é um humano com direito de aprovar (o delegante, ou outro conforme a política). O agente não
  aprova a si mesmo.
- A aprovação é registrada na auditoria, com quem aprovou, quando, e a entrada.

### 4. Entrada não confiável

- Os argumentos vindos do agente passam pela **mesma validação de contrato** das outras superfícies (ADR-016,
  etapa 2). Nada do que o agente envia é interpretado como instrução do sistema.
- O que o sistema devolve ao agente também pode carregar texto malicioso para uma próxima etapa. A saída é
  restrita pelo contrato e pelos campos que a política da delegação permite ver; campos pessoais seguem a
  classificação.
- Um comando exposto ao MCP é projetado como se **qualquer** argumento fosse hostil.

### 5. Limite de taxa e auditoria completa

- Há **limite de taxa** por identidade de agente e por delegação, além dos limites do papel.
- Cada chamada é auditada com: o agente, o delegante, a ferramenta, a entrada (com dado pessoal mascarado e
  cifrado como em todo o Audit, ADR-013), a decisão (executada, recusada, pendente, aprovada) e o resultado. A
  **decisão do agente** fica rastreável, inclusive as recusadas.
- Cada chamada tem uma **chave de idempotência** própria (ADR-016, tabela de superfícies), então uma repetição
  do agente não duplica o efeito.

### 6. O que isto não garante

- O Vetra **não impede** um agente de repassar a um provedor de modelo os dados que a delegação permitiu que ele
  leia. A defesa é restringir o que a delegação lê e o que sai (campos, taxa e auditoria), mas o dado entregue ao
  agente passou do controle do sistema.
- A **classificação de sensibilidade é responsabilidade de quem declara o comando**. Um comando destrutivo
  mal classificado como não sensível é executado sem aprovação.
- A aprovação humana depende de a pessoa entender o que aprova; a interface de aprovação deve mostrar a ação e
  os argumentos, não só um "continuar?".

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

## Consequências

- Mais governança, menos automação irrestrita: é a troca que a proposta assume.
- Todo comando exposto a agentes precisa de uma classificação de sensibilidade e de um contrato bem definido.
- Uma tabela e um fluxo novos: delegações e aprovações pendentes, com revogação e expiração.
- A latência de um comando sensível inclui a espera por uma pessoa.
- O contexto assinado e a auditoria ganham campos novos (agente, delegante, decisão).

## Garantias e seus níveis

| Garantia | Nível | Mecanismo |
|---|---|---|
| Um comando só é alcançável pelo MCP se declarado | Estrutural | Exposição opt-in (ADR-007) |
| O agente nunca pode mais que o delegante | Verificável por testes | Interseção de políticas avaliada pelo mesmo motor |
| Uma operação sensível não executa sem aprovação | Verificável por testes | Estado pendente antes da etapa 4 |
| A aprovação não vale para outra entrada | Verificável por testes | Aprovação presa ao resumo da entrada |
| Argumentos hostis não ultrapassam o contrato | Verificável por testes, não prova | Validação do contrato; testes adversariais |
| Revogar a delegação suspende o agente | Transacional e verificável por testes | Revisão de autorização (ADR-020) |
| Dado entregue ao agente não é repassado | **Fora da garantia** | Só se limita o que sai |

## Testes de aceitação

1. Um comando sem exposição MCP não aparece no catálogo nem pode ser chamado como ferramenta.
2. O catálogo de ferramentas corresponde exatamente às exposições declaradas, com os esquemas dos contratos.
3. Um agente não executa uma operação que o delegante não pode executar.
4. Uma delegação expirada ou revogada recusa a chamada; uma revogação em andamento suspende o agente.
5. Uma chamada sensível fica pendente e **não abre transação** até ser aprovada.
6. Uma aprovação para uma entrada não autoriza a mesma operação com um argumento alterado.
7. O agente não consegue aprovar a própria chamada.
8. Argumentos adversariais (texto com instruções, valores fora do contrato, campos extras) são recusados ou
   tratados como dados.
9. O limite de taxa por agente e por delegação é aplicado.
10. A auditoria registra o agente, o delegante, a decisão e a aprovação, inclusive das chamadas recusadas.
11. Uma repetição da mesma chamada do agente, com a mesma chave, não duplica o efeito.
12. Campos pessoais fora da política da delegação não aparecem na saída da ferramenta.

## Questões em aberto

- **Quem classifica os comandos como sensíveis, e qual é o padrão por tipo de operação.** A proposta deixa em
  aberto; este ADR fixa só o mínimo (exclusão, financeiro, permissões) e a regra de que a classificação é de
  quem declara. Falta decidir se uma exposição ao MCP de um comando de escrita sem classificação é erro de
  compilação.
- O formato da delegação e as extensões do contexto assinado do ADR-005 (identidade do agente, delegante,
  escopo e validade).
- Como o agente se autentica no servidor MCP e como o servidor obtém a delegação do usuário; o mecanismo do
  transporte não foi especificado aqui.
- A interface e o canal de aprovação humana, o prazo da aprovação e quem pode aprovar.
- Validade e limite de taxa padrão das delegações.
- Quais consultas podem ser ferramentas de leitura, e como limitar a exfiltração por leituras repetidas.
- Um conjunto de testes adversariais de injeção de prompt e como ele evolui.

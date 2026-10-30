# ADR-012: Canário em modo sombra com capacidades simuladas

- Status: proposto
- Data: 2026-10-30
- Depende de: ADR-004 (capacidades e Effect Boundary), ADR-016 (ciclo de vida da operação)
- Relacionados: ADR-006 (isolamento de domínios), ADR-007 (adaptadores), ADR-013 (dado pessoal)

**Esta decisão pertence à fase 4 do roadmap.** Ela só é implementada depois da fundação, do tempo real e dos
processos duráveis. O ADR existe agora para que a fundação não tome decisões que a impeçam (as capacidades
precisam declarar como são simuladas).

## Contexto

Um canário comum envia uma parte do tráfego real a uma versão nova e observa o resultado. Se a versão nova
executa os efeitos de verdade, ela escreve em dobro, envia o e-mail duas vezes e cobra duas vezes. O risco está
na proposta: "efeitos duplicados no canário: escritas e envios em dobro".

O **modo sombra** resolve isso: a versão nova de um domínio recebe uma **cópia** do tráfego e roda com
**capacidades simuladas**; só as **respostas** são comparadas com as da versão que atende. Funciona porque
os efeitos de uma operação passam pelo Effect Boundary (ADR-004), que pode ser substituído por um simulador.

## Decisão

**A versão nova de um domínio recebe uma cópia do tráfego e roda com capacidades simuladas, sem nenhum efeito
real. Só as respostas são comparadas. É uma extensão da fase 4.**

### 1. Quem é elegível

Uma operação só entra no modo sombra se **toda** a sua superfície de efeito é simulável. O grafo já tem o que
é preciso para decidir isso:

- cada capacidade declara `simulation`: `seeded` (relógio, UUID e acaso determinísticos), `memory` (repositório
  e efeitos com simulador em memória) ou `none` (sem simulador);
- uma operação com `unsafe_effect` está **fora da garantia de repetição e de sombra** (o validador já o avisa).

A regra é: **elegível ⇔ sem `unsafe_effect` e toda capacidade usada com `simulation` diferente de `none`.**
Aplicada ao grafo atual dos exemplos, todas as operações são elegíveis (`clock` é `seeded`; repositórios e o
`mailer` declarado com `simulate :memory` são `memory`). Removendo o `simulate` do `mailer`, o handler que o usa
passa a `mailer=none` e fica **inelegível**, o que mostra que a regra distingue. Operações com efeitos fora do
Effect Boundary nunca são elegíveis.

### 2. O que o simulador fixa

Para que as respostas sejam comparáveis, tudo o que muda a cada execução vem do simulador:

- o **relógio**, os **UUIDs** e os **timestamps** são fixados a partir de uma semente reproduzível (ADR-004).
  Sem isso, haveria divergências falsas, só porque um instante ou um identificador são diferentes;
- as capacidades externas respondem como o simulador declarado (`simulate`), nunca chamam o serviço real;
- o acaso e as falhas, quando simulados, vêm da mesma semente.

### 3. Escritas num repositório simulado, nunca numa transação revertida

- As leituras da versão sombra vêm de um **instantâneo consistente de leitura** do banco, aberto como somente
  leitura e curto (por requisição).
- As escritas vão para um **repositório simulado** sobre esse instantâneo: uma camada em memória, descartada
  ao fim.
- **Não se usa uma transação que depois é revertida.** Uma transação com escrita segura **locks** das linhas e
  tem um `xid`, o que atrasa quem escreve na produção e prende o `xmin` (ADR-008, §5). O ADR-014 mediu que um
  `FOR UPDATE` já atribui `xid` no PostgreSQL. Reverter no fim não desfaz o dano feito durante a execução.

### 4. O que se compara

- A **resposta** (status e corpo, normalizados).
- Os **eventos** que a operação emitiria, capturados por uma outbox simulada.
- O **conjunto de escritas** que ela faria, capturado pelo repositório simulado.
- A comparação tem regras de tolerância declaradas (por exemplo, campos que a versão nova muda de propósito),
  e as divergências são relatadas com a entrada que as produziu.
- Dado pessoal da comparação não é persistido em claro: segue a classificação e o mascaramento do ADR-013.

### 5. Cópia do tráfego sem prejudicar a produção

- O tráfego é espelhado **no adaptador** (ADR-007), com amostragem. A resposta da sombra **nunca** é devolvida
  ao cliente.
- A execução sombra roda **de forma assíncrona**, com timeout e orçamento próprios, em processo ou pool
  separados, para não competir com a produção por CPU e conexões.
- Falha ou lentidão da sombra não afeta a requisição original.
- A sombra usa o mesmo ator e o mesmo contexto assinado da requisição original e continua sob o RLS (ADR-005);
  não ganha privilégio.

## Alternativas rejeitadas

- **Canário que executa efeitos reais** (a alternativa da proposta): duplica escritas, e-mails e cobranças.
- **Executar a versão sombra numa transação que depois é revertida:** prende locks e `xmin` na produção
  (seção 3).
- **Só testes em pré-produção:** não reproduzem a variedade das entradas reais.
- **Comparar apenas métricas (latência, erros):** não detecta uma resposta diferente.
- **Tornar tudo elegível por padrão:** esconderia as operações com efeito real, que são justamente as perigosas.

## Consequências

- Compara versões com tráfego real sem efeitos duplicados.
- Exige um **simulador determinístico** e um **repositório simulado**; são trabalho do núcleo (capacidades que
  declaram `simulation`) e dependem de o `call` respeitar o Effect Boundary.
- Operações com `unsafe_effect` ou com capacidade `none` ficam fora, e o relatório de elegibilidade as mostra.
- Custo de CPU e de conexões: a sombra executa a operação duas vezes. O orçamento e a amostragem controlam isso.
- Código que faz I/O fora do Effect Boundary escapa da simulação e pode produzir efeito real (limite do
  ADR-004).

## Garantias e seus níveis

| Garantia | Nível | Mecanismo |
|---|---|---|
| A sombra não produz efeito externo | Estrutural, com o limite do ADR-004 | Só capacidades simuladas; operações com `simulation: none` ou `unsafe_effect` são inelegíveis |
| A sombra não segura locks nem `xmin` da produção | Verificável por testes | Instantâneo de leitura e repositório simulado, sem transação de escrita |
| As respostas são comparáveis | Verificável por testes | Relógio, UUID e timestamps fixados por semente |
| Código fora do Effect Boundary | **Fora da garantia** | Não é simulável |
| A cópia do tráfego não afeta a produção | Operacional | Execução assíncrona com orçamento próprio |

## Testes de aceitação

1. Uma operação elegível, executada em modo sombra, não envia e-mail, não escreve no banco e não chama nenhum
   host externo.
2. Uma operação com `unsafe_effect`, ou que use uma capacidade `none`, é recusada para o modo sombra com a razão
   no relatório.
3. Com a mesma semente, duas execuções sombra da mesma entrada produzem respostas idênticas (sem divergência
   por relógio ou UUID).
4. Uma divergência real entre a versão atual e a nova é detectada e relatada com a entrada que a produziu.
5. Durante uma execução sombra, nenhum lock de linha é mantido e o `xmin` da produção continua avançando.
6. As escritas da sombra não são visíveis na produção e não sobrevivem à execução.
7. Uma lentidão ou falha da sombra não altera a latência nem o resultado da requisição original.
8. A resposta da sombra nunca chega ao cliente.
9. A sombra roda sob o mesmo RLS e o mesmo ator, e não lê dados de outro tenant.
10. Dado pessoal não aparece em claro no relatório de divergências.

## Questões em aberto

- O formato do simulador e da semente, e como ele é compartilhado com os testes por simulação determinística
  (pilar 8).
- Como o repositório simulado representa leituras depois de escritas dentro da mesma operação (uma leitura de
  algo que a própria sombra acabou de escrever).
- As regras de tolerância da comparação e quem as declara.
- Orçamento e amostragem padrão, e como a sombra se limita sob carga.
- Como o instantâneo de leitura convive com a limpeza do banco (`vacuum`) quando a sombra é frequente.
- Como lidar com operações cujo resultado depende de outra operação concorrente (ordem entre requisições
  espelhadas).

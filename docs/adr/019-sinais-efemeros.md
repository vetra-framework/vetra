# ADR-019: Sinais efêmeros autorizados pelo mesmo motor

- Status: proposto
- Data: 2026-10-30
- Depende de: ADR-020 (entrega live incremental), ADR-008 (notificação e conexão `LISTEN`), ADR-005 (RLS e
  contexto assinado)
- Relacionados: ADR-002 (tabelas `UNLOGGED` e Redis opcional), ADR-013 (privacidade), ADR-018 (cliente de UI)

## Contexto

Telas em tempo real mostram mais do que dados persistidos: "fulano está digitando" e "fulano está online" são
sinais de vida curta. Eles têm exigências diferentes dos dados:

- **não devem ir para o histórico nem para a auditoria**: seriam ruído e volume sem valor;
- **precisam expirar sozinhos**: um indicador de digitação que fica preso depois de uma queda de conexão é um
  defeito visível;
- **frequentes e baratos**: um sinal por tecla seria uma escrita por tecla.

Mas eles **não podem ficar fora do controle de acesso**. Presença numa sala privada revela quem participa dela;
um canal sem autorização vaza essa informação para quem não deveria saber. O Exemplo 3 (chat) deixa os sinais
fora do código do exemplo e remete a este ADR; o ADR-020 já fixou que eles "não passam pelo caminho dos dados
nem entram no histórico, e seguem este ADR com a mesma autorização das consultas live".

## Decisão

**Sinais efêmeros usam o mesmo motor de autorização dos dados, não são gravados no histórico, e a presença se
apoia em leases por usuário e dispositivo numa tabela `UNLOGGED`. O Redis é um adaptador opcional, adotado por
métrica de latência de commit.**

### 1. Autorização: a regra de acesso dos dados

- Um sinal pertence a um **tópico**: um registro autorizável, como uma sala. Receber os sinais de um tópico
  exige o direito de **ler** esse registro; emitir um sinal exige o direito de **escrever** nele (no chat,
  poder enviar mensagem na sala). A autorização é avaliada pelas mesmas políticas, com o contexto do ADR-005.
- Os sinais seguem a **revisão de autorização** do ADR-020. No modo `strict`, nenhum lote iniciado depois da
  revogação entrega sinais a quem perdeu o acesso, e a assinatura reautorizada apaga o que ele via.
- Os grupos de entrega têm o tenant na chave estática: usuários de empresas diferentes nunca compartilham
  grupo (ADR-020).
- Um sinal entregue a quem perdeu o acesso a pouco antes é uma janela de milissegundos, como a dos dados
  (ADR-020); não há como recolher o que já foi exibido.

### 2. "Digitando"

- É um sinal **sem estado no banco**. Não é gravado em lugar algum.
- O cliente o emite com **limitação de taxa** (padrão proposto: no máximo um sinal a cada 3 s por tópico e
  ator), não um por tecla.
- Quem recebe o **expira sozinho**: se não chega uma renovação em um prazo curto (padrão proposto: 5 s), o
  indicador some. Por isso uma queda de conexão não deixa um indicador preso.
- Entre processos, o sinal viaja pela conexão `LISTEN` dedicada de cada processo (ADR-008), levando só
  identificadores (tenant, tópico, tipo, ator), nunca conteúdo.

### 3. Presença

- A presença é uma **lease por usuário e dispositivo**: uma linha com `(tenant, tópico, usuário, dispositivo,
  expira_em)` numa tabela **`UNLOGGED`** (no modo só PostgreSQL).
- O dispositivo **renova** a lease por heartbeat (padrão proposto: a cada 10 s, com validade de 3 vezes isso).
  Uma desconexão detectada remove a lease na hora; uma não detectada expira.
- Um usuário está presente enquanto tiver **ao menos uma lease válida**. Se um de vários dispositivos
  desconecta, a presença continua correta.
- O estado de presença **não** entra no histórico nem na auditoria (ADR-013).

**Por que `UNLOGGED`.** Medido no PostgreSQL 16.15, 17.11 e 18.6:

| Propriedade | Resultado |
|---|---|
| Volume de WAL ao inserir 50 mil linhas | Praticamente nenhum numa tabela `UNLOGGED` (0 bytes no 16 e no 17; 96 bytes no 18); cerca de 3,6 MB numa tabela comum |
| Depois de um desligamento limpo | Os 1 000 registros continuam lá |
| Depois de um **crash** (desligamento imediato, ou `SIGKILL` no processo) | A tabela `UNLOGGED` volta **vazia (0)**; a comum retém tudo. Igual nas três versões |

A perda no crash é aceitável: as leases se recompõem em até um intervalo de heartbeat, quando os clientes
reconectam e renovam. A proposta registra o mesmo custo: "a presença se perde num crash do banco". Pela
documentação do PostgreSQL, tabelas `UNLOGGED` também não são replicadas para réplicas, o que tem o mesmo
efeito num failover (não medido aqui).

### 4. Transporte e o limite do `NOTIFY`

Medido no PostgreSQL 16.15, 17.11 e 18.6 (`script/sonda_adr019.rb`, 5 de 5 verificações em cada):

- O payload do `NOTIFY` tem limite: 7 999 bytes passam e 8 000 falham (`payload string too long`). Sinais
  carregam só identificadores.
- A notificação **só chega no commit**; um rollback não a entrega.
- Notificações idênticas na **mesma transação** chegam uma só vez. Isso ajuda, mas **não substitui** a limitação
  de taxa da seção 2: sinais em transações separadas continuam sendo notificações separadas.
- O `LISTEN` pertence à **sessão**: só a conexão que escuta recebe. Por isso a conexão dedicada do ADR-008, fora
  do pool. Atrás de um pooler em modo de transação, a notificação pode inclusive chegar a **outro cliente** que
  segurava o backend (medido no ADR-003 e no ADR-008).
- Cada `NOTIFY` custa no commit (o ADR-008 registra que ele serializa commits sob escrita muito intensa). É o
  motivo da limitação de taxa e do Redis opcional.

### 5. Redis, opcional

- O Redis pode transportar os sinais como adaptador, **sem ser requisito do núcleo** (ADR-002).
- A adoção é **por métrica**: quando o `NOTIFY` passar a aumentar a latência de commit das transações de
  negócio, medida na matriz de carga do gate G4 (alterações persistidas e sinais efêmeros medidos
  separadamente).
- A autorização continua **dentro do processo Vetra**, antes de entregar ao cliente. O Redis transporta; nunca
  decide quem pode ver um sinal.

### 6. Limites de proteção

Existem limites por conexão (sinais por segundo) e por tópico, como os das assinaturas (ADR-020). Um cliente que
os excede é limitado e, se persistir, desconectado.

## Alternativas rejeitadas

- **Gravar sinais no histórico** (alternativa da proposta): volume sem valor, e o dado de presença ficaria
  retido sem necessidade.
- **Canal sem autorização** (alternativa da proposta): vazaria quem participa de um tópico privado.
- **Um sinal por tecla, sem limitação:** uma escrita por tecla; o `NOTIFY` serializaria commits.
- **Presença numa tabela comum:** cada heartbeat geraria WAL e replicação sem necessidade, para um dado que
  pode ser recomposto.
- **Redis como requisito:** uma peça operacional a mais no núcleo sem necessidade medida (ADR-002).
- **Um contador de usuários online, sem identidade:** não responde "quem" nem "em qual dispositivo", que é o
  que a tela precisa.

## Consequências

- A mesma regra de acesso vale para dados e sinais, e uma revogação os atinge juntos.
- A presença se perde em um crash do banco e se recompõe sozinha em poucos segundos.
- Cada heartbeat é uma escrita (sem WAL), e o volume cresce com os usuários presentes: o custo e o trabalho do
  `autovacuum` numa tabela com muitas atualizações precisam ser medidos.
- A limitação de taxa dos sinais é uma regra de produto (quantos sinais por segundo), não só de infraestrutura.
- O Redis, se adotado, é uma dependência operacional a mais, só a partir da medição.

## Garantias e seus níveis

| Garantia | Nível | Mecanismo |
|---|---|---|
| Sinais seguem a mesma autorização dos dados | Verificável por testes | Mesmas políticas e revisão de autorização (ADR-020) |
| Usuários de empresas diferentes nunca compartilham grupo | Verificável por testes | Tenant na chave estática (ADR-020) |
| O indicador de digitação expira após queda de conexão | Verificável por testes | Expiração no receptor; sem estado no banco |
| A presença é correta com vários dispositivos | Verificável por testes | Lease por usuário e dispositivo |
| Sinais não vão para o histórico nem para a auditoria | Estrutural | Tabela `UNLOGGED` e ausência de gravação no histórico |
| A presença sobrevive a um crash do banco | **Não oferecida** | `UNLOGGED` volta vazia; recompõe-se pelos heartbeats |
| Entrega em tempo hábil | Operacional | `LISTEN` dedicado; depende da carga de `NOTIFY` |

## Testes de aceitação

1. O indicador de digitação expira depois de uma queda inesperada da conexão (ADR-020, teste 8).
2. A presença continua correta quando um de vários dispositivos de um usuário desconecta (ADR-020, teste 9).
3. Depois de `pg_ctl stop -m immediate` e reinício, a tabela de presença volta vazia e as leases se recompõem
   em até um intervalo de heartbeat.
4. Um usuário removido de uma sala deixa de receber os sinais dela depois da revogação, no modo `strict`.
5. Usuários de tenants diferentes nunca compartilham um grupo de entrega de sinais.
6. Um sinal emitido por quem não pode escrever no tópico é recusado.
7. Nenhum sinal (digitação ou presença) aparece no histórico nem na auditoria.
8. A limitação de taxa impede que um cliente que emite um sinal por tecla gere mais de um `NOTIFY` por
   intervalo.
9. O payload de um sinal nunca excede o limite do `NOTIFY`, e só leva identificadores.
10. Com o adaptador Redis, a autorização e os resultados dos testes anteriores não mudam.
11. A matriz de carga mede os sinais efêmeros separadamente das alterações persistidas, com todos os usuários
    no mesmo grupo de permissão e com permissões individuais.

## Questões em aberto

- Se o estado de presença é dado pessoal para fins de privacidade (ADR-013) e como é tratado, já que revela
  comportamento.
- Valores de limitação de taxa, expiração de digitação, heartbeat e validade da lease (3 s, 5 s, 10 s e 30 s são
  hipóteses).
- Custo e `autovacuum` da tabela de presença com muitos heartbeats; se uma escrita em lote por processo
  substitui uma por heartbeat.
- Comportamento da presença num failover para uma réplica, onde a tabela `UNLOGGED` não existe populada.
- O volume de `NOTIFY` em que a latência de commit passa a pesar (matriz de carga do gate G4) e, com isso, o
  limiar para adotar o Redis.
- Se o "digitando" viaja só por `NOTIFY` ou também por memória do processo quando o emissor e os receptores
  estão no mesmo processo.

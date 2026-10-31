# ADR-009: Workflows duráveis por histórico de eventos e replay determinístico

- Status: aceito
- Data: 2026-10-30
- Depende de: ADR-016 (ciclo de vida da operação), ADR-004 (capacidades e Effect Boundary), ADR-014 (outbox)
- Relacionados: ADR-001 (análise do código), ADR-005 (RLS e contexto assinado), ADR-007 (comando e
  adaptadores), ADR-008 (ordem dos eventos), ADR-013 (privacidade)

## Contexto

Processos de negócio que duram horas ou dias ("lead sem contato em 48 h: escalar ao gerente") viram, em
aplicações comuns, uma colcha de cron, flags de estado e jobs espalhados. O estado do processo fica implícito
nas colunas e é difícil de ler, testar e evoluir.

A versão inicial da proposta falava em **persistir Fibers no PostgreSQL**. Isso é inviável: uma Fiber suspensa
não pode ser serializada e restaurada com a sua pilha depois que o processo reinicia (confirmado: `Marshal.dump`
de uma Fiber falha com `no _dump_data is defined for class Fiber`).

A correção, que a proposta adota, é a de sistemas como o Temporal: guardar o **histórico dos eventos** e, após
uma queda ou um deploy, **reexecutar o código desde o início**, devolvendo os resultados já registrados até o
ponto em que parou.

## Decisão

**O workflow é escrito em Ruby linear e roda numa Fiber. Cada efeito (comando, temporizador, sinal) é registrado
no histórico no PostgreSQL. Após falha ou deploy, o código é reexecutado e os resultados registrados vêm do
histórico até o ponto de parada.** É uma extensão da fase final do roadmap e não faz parte da fundação.

> A sintaxe abaixo é ilustrativa; nada disso existe ainda.

```ruby
workflow :escalar_lead_parado do
  input :lead_id, :id
  call do |input, ctx|
    ctx.wait 48.hours, unless_signal: :contatado
    ctx.run :escalar_para_gerente, lead_id: input.lead_id
  end
end
```

### 1. O modelo

- O histórico de uma execução é uma sequência **somente de inclusão** de eventos: comando agendado e concluído,
  temporizador criado e disparado, sinal recebido, execução concluída ou cancelada. Fica no PostgreSQL, com o
  tenant e o contexto do ADR-005.
- Um **passo de decisão** reexecuta o código do workflow. Para cada chamada a `ctx`, se o histórico já tem o
  resultado naquela posição, ele é devolvido; senão, o comando é registrado como pendente e a execução
  suspende.
- Quem avança a execução são workers que reservam passos por lease curto e confirmado, nunca por transação
  aberta (mesmo padrão do ADR-014, para não prender o `xmin`, ADR-008).
- Temporizadores são linhas com `fire_at`, lidas com `SKIP LOCKED`. Sinais entram como eventos do histórico, na
  ordem em que foram gravados.
- Os campos pessoais das entradas e dos resultados dos passos entram no histórico **cifrados pela DEK do
  titular** (ADR-013, §6), como na outbox. Se o titular é eliminado, a execução que depende deles não pode ser
  reexecutada: ela falha fechada e é cancelada pelo contrato de cancelamento (seção 2), sem expor o dado.

### 2. Efeitos só por comandos idempotentes

- Um workflow **não faz efeito direto**. Tudo o que muda o mundo é um **comando** (ou uma atividade declarada),
  que passa pelas oito etapas do ADR-016 e tem uma chave de idempotência derivada de `(execução, posição)`.
  Uma repetição do mesmo passo, depois de uma queda, não duplica o efeito.
- Cancelamento, sinais concorrentes e compensações (desfazer passos já feitos) são definidos **por contrato**,
  e não por convenção. O conteúdo do contrato ainda não está especificado (veja as questões em aberto).

### 3. Determinismo: três camadas, com garantias diferentes

Para o replay funcionar, o código do workflow não pode ler o relógio, gerar números aleatórios, fazer I/O nem
criar threads por conta própria. Isso é garantido em três camadas, e **só a primeira é uma garantia**:

1. **A API do workflow é a única fonte de tempo, acaso e efeito.** O relógio é `ctx.now`, o acaso é
   `ctx.random`, o efeito é `ctx.run`. O resultado de cada um entra no histórico e é devolvido igual no replay.
2. **Análise estática do corpo do workflow**, com o mesmo analisador do ADR-001 (que já sinaliza `Time.now`,
   `File`, `Net::HTTP` e chamadas ao sistema). É a barreira de revisão, com os limites já documentados: não
   resolve fluxo de dados nem helpers arbitrários.
3. **`TracePoint` em desenvolvimento e teste**, como rede de segurança. **Não é uma barreira.**

O que se mediu no Ruby 4.0.9 (`script/sonda_adr009.rb`, 14 de 14 verificações) sobre o `TracePoint`:

- Bloqueia `Time.now`, `Process.clock_gettime`, `rand`, `Random.rand`, `sleep`, `File.read` e `Thread.new`, e
  alcança uma `Fiber` criada dentro do workflow, na mesma thread.
- **Precisa assinar `:call` além de `:c_call`:** no Ruby 4, `Time.now` é definido em Ruby (`<internal:timev>`) e
  não gera `:c_call`. Um bloqueio que assine só `:c_call` deixa o relógio passar.
- **É uma lista de negação e tem furos.** Numa medição separada, escaparam `Time.new` (sem argumento),
  `Date.today`, `SecureRandom`, `Kernel#system`, `IO.popen`, `TCPSocket`, `ENV`, `Dir.glob` e `$stdout.puts`.
  Qualquer chamada não listada passa.
- **Custa caro:** com os dois eventos ligados, 2 milhões de chamadas simples levaram cerca de 4 vezes mais
  (315 ms contra 1 304 ms). Por isso fica só em desenvolvimento e teste.

A rede de segurança que **funciona em produção** é a do replay: ao reexecutar, se o código chamar um comando
diferente do que o histórico tem na mesma posição, a execução falha com erro de não-determinismo (verificado:
`posição 0: o histórico tem cobrar e o código chamou enviar_email`). Isso detecta código que **mudou** sem
versão, mas **não** detecta um relógio lido e usado sem alterar a sequência de comandos.

### 4. Versionamento

- Cada workflow tem uma **versão explícita**. Uma execução que começou na versão N termina na versão N,
  mesmo depois de um deploy que publica a N+1.
- Logo, o código das versões em uso precisa continuar disponível enquanto houver execuções nelas. O grafo
  registra a versão de cada workflow e o diff arquitetural deve classificar a mudança do código de uma versão
  já publicada como quebra potencial (o diff atual não conhece workflows).
- Uma mudança que reordena ou remove passos de uma versão em uso é um novo workflow (nova versão), nunca uma
  edição.

### 5. Sem escalonador de fibras nesta versão

O código do workflow é linear. Cada chamada a `ctx` **suspende** a Fiber (`Fiber.yield`) e a retoma com o
resultado que está no histórico, como no motor da sonda (`script/sonda_adr009.rb`): o workflow linear completa e
cada efeito roda uma vez; depois de uma queda, o replay reaproveita o histórico e não repete o passo já feito.
Como o código não faz I/O nem usa `sleep` ou threads (seção 3), nada precisa ser interceptado por um
`Fiber::Scheduler`, e a ordem de retomada é a do histórico. O tempo é virtual: vem de `ctx.now` e `ctx.wait`, que
o histórico registra. Uma corrida entre um temporizador e um sinal (`unless_signal`) se resolve pelo que foi
gravado primeiro.

**Ramos concorrentes dentro de um workflow (`ctx.parallel`, por exemplo) exigem um escalonador determinístico e
ficam fora desta decisão.** O Temporal Ruby SDK usa Fibers com um escalonador assim, mas a sonda não o cobre.
Esse recurso volta por ADR novo, depois que o escalonador for provado.

### 6. Alternativa mantida: adaptador para o Temporal

Para quem já tem essa infraestrutura, um adaptador mantém os mesmos comandos como atividades e o mesmo grafo,
com o motor do Temporal no lugar do motor do Vetra.

### 7. O ator de um workflow

- Como um handler (ADR-014, §8), um workflow **não age como o ator que o iniciou**: ele pode durar dias, e o ator
  pode ter perdido a permissão nesse tempo. Age como um **ator de sistema do tenant da execução**, identificado
  pelo workflow e pela versão. O tenant da execução fica no histórico.
- A autoridade desse ator é **exatamente a dos comandos que o workflow declara executar**: a lista que o grafo
  conhece e que o diff arquitetural mostra para revisão. Um `ctx.run` de outro comando é recusado.
- O contexto assinado (ADR-005) vale 30 s por padrão, muito menos que uma execução. Por isso ele é **emitido a
  cada passo**, para cada comando, com o tenant da execução, o ator de sistema e o `op_id` do comando. Nunca é
  guardado no histórico nem reaproveitado entre passos.
- **Agir como o ator que iniciou** a execução exige a capacidade explícita e auditada do ADR-016, e não é
  concedida por padrão.
- A auditoria de cada comando registra o workflow, a versão e a posição como origem.

## Alternativas rejeitadas

- **Persistir Fibers** (a alternativa da proposta): impossível, uma Fiber suspensa não é serializável.
- **Temporal obrigatório:** adicionaria uma peça de infraestrutura ao núcleo; fica como adaptador opcional.
- **Máquina de estados declarativa:** é explícita, mas perde o código linear que torna o fluxo legível e que é
  a razão de ser da proposta.
- **Cron, flags e jobs** (o estado atual): o estado do processo fica implícito e não há versão nem replay.
- **Confiar no `TracePoint` para o determinismo:** medido acima; tem furos e é caro.
- **Executar workflows dentro de uma única transação longa:** prende conexão e `xmin` (ADR-008, ADR-016).
- **Um escalonador de fibras determinístico já na primeira versão:** a sonda não o cobre, e um workflow linear
  não precisa dele; só ramos concorrentes o exigem, e voltam por ADR novo.
- **O workflow agir como o ator que o iniciou:** a execução dura dias e o ator pode perder a permissão, ou sair
  da empresa, no meio.
- **Guardar o contexto assinado no histórico:** ele vale 30 s, e um token guardado seria um segredo de vida
  longa no banco.

## Consequências

- Fluxos longos em Ruby linear, duráveis e com versão. O estado deixa de estar espalhado em colunas.
- Restrições reais para quem escreve: sem relógio, acaso, I/O ou threads diretos, e todo efeito por comando.
- O histórico cresce com a duração da execução e o replay fica mais lento com ele; é preciso um limite e uma
  forma de continuar a execução com um histórico novo.
- Código de versões antigas precisa ser mantido enquanto houver execuções nelas.
- Nesta versão um workflow tem um fluxo só, sem ramos concorrentes. O paralelismo exige o escalonador e um ADR
  novo.
- O dado pessoal dos passos fica cifrado no histórico, e eliminar o titular cancela as execuções que dependem
  dele (ADR-013).
- Cada comando de um workflow exige um contexto assinado novo, o que é uma emissão por passo.
- É extensão da fase final e não bloqueia a fundação.

## Garantias e seus níveis

| Garantia | Nível | Mecanismo |
|---|---|---|
| Efeitos de um passo não se repetem após queda | Operacional | Histórico mais chave de idempotência por `(execução, posição)`; efeito externo exatamente uma vez só com chave aceita pelo provedor (ADR-014) |
| O código não usa relógio, acaso, I/O ou threads | Estrutural, limitado | API do `ctx` e análise estática; sem resolução de fluxo de dados |
| Mudança incompatível de código é detectada no replay | Verificável por testes | Comparação de cada passo com o histórico |
| Bloqueio por `TracePoint` | **Rede de segurança de desenvolvimento** | Lista de negação com furos e custo alto; não é garantia |
| Execuções antigas terminam na versão original | Verificável por testes | Versão explícita por workflow |
| Um workflow age só pelos comandos que declara, no tenant da execução | Estrutural, com os limites do ADR-004 | Lista declarada e contexto assinado por passo (§7) |
| O dado pessoal do histórico do workflow não fica em claro | Verificável por testes | Cifra por DEK do titular (ADR-013, §6) |

## Testes de aceitação

1. Um worker encerrado no meio da execução: outro retoma e **não repete** os comandos já registrados.
2. O replay de um histórico completo devolve o mesmo resultado e não executa nenhum efeito.
3. Um código alterado, incompatível com o histórico, falha com erro de não-determinismo que cita a posição.
4. Um temporizador sobrevive a reinício do processo e dispara uma única vez com vários workers.
5. Dois sinais simultâneos são aplicados na ordem do histórico e geram o mesmo resultado em qualquer replay.
6. Uma execução iniciada na versão N termina na N depois do deploy da N+1.
7. A análise estática recusa `Time.now`, `rand`, `File` e `Net::HTTP` no corpo de um workflow, e aceita
   `ctx.now`, `ctx.random` e `ctx.run`.
8. Cancelamento e compensação seguem o contrato declarado, inclusive com falha no meio da compensação.
9. O workflow não segura transação nem prende o `xmin` enquanto espera um temporizador ou um comando.
10. Os efeitos de cada passo passam pelas oito etapas e pelo RLS, com os papéis de banco de produção.
11. Um workflow que tenta executar um comando que não declarou é recusado. Cada comando executa com o ator de
    sistema do workflow e um contexto assinado novo, e o contexto não aparece no histórico.
12. Uma execução que espera mais que a validade do contexto (30 s) ainda executa o passo seguinte, com um
    contexto novo.
13. Eliminado o titular de um dado pessoal do histórico, a execução que depende dele falha fechada e é
    cancelada pelo contrato, sem expor o dado.

## Questões em aberto

- Limite de tamanho do histórico e a forma de continuar uma execução com um histórico novo, para o replay não
  degradar.
- Como o código de versões antigas é mantido e descartado com segurança.
- Como a política `authorize` de um comando trata o ator de sistema de um workflow: a mesma questão aberta do
  ADR-014, para o handler.
- O contrato de cancelamento, de sinais concorrentes e de compensação: o que o desenvolvedor declara e como o
  motor o aplica. A seção 2 diz apenas que é por contrato.
- A sintaxe do DSL (`workflow`, `ctx.run`, `ctx.wait`, sinais) e o seu lugar no grafo e na IR; o schema 0.1
  não representa workflows. Inclui como o workflow declara os comandos que executa.
- Ramos concorrentes: a viabilidade e o custo do escalonador de fibras determinístico, que a sonda não cobre.
  Fora desta versão (seção 5).
- Precisão e carga dos temporizadores com muitas execuções simultâneas.

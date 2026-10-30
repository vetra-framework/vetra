# ADR-016: Ciclo de vida da operação

- Status: proposto
- Data: 2026-10-30
- Dependem deste ADR: 004 (capacidades e Effect Boundary), 005 (RLS e contexto assinado), 020 (entrega live incremental)

## Contexto

No Rails, a regra de negócio de uma mesma operação costuma ficar espalhada entre controller, service, job,
callback de model e rake task. Cada superfície reimplementa validação, autorização, transação, evento e
auditoria, e cada reimplementação pode esquecer uma etapa. Os exemplos da proposta mostram o custo: no mini
CRM, o `update` só é seguro se o desenvolvedor lembrar de reautorizar depois de atribuir os parâmetros, e o
e-mail do vendedor pode sair duplicado se o relay reprocessar um evento.

O Vetra precisa de um contrato único, válido para HTTP, CLI, job e webhook, que diga em que ordem as coisas
acontecem, o que é garantido em cada etapa e o que não é. Sem ele, os ADRs de capacidades, RLS e consultas
reativas não têm onde se apoiar.

## Decisão

**O comando é a única unidade de operação.** Toda escrita no sistema, venha de onde vier, passa pelas mesmas
oito etapas, nesta ordem. Um adaptador (HTTP, CLI, job, webhook, MCP) só traduz a entrada e a saída; não
decide nada de negócio e não abre transação.

### As oito etapas

| # | Etapa | O que acontece | Dentro da transação? |
|---|---|---|---|
| 1 | Resolver | O adaptador identifica o comando no grafo, o ator, o tenant e a chave de idempotência (se houver) | Não |
| 2 | Validar | A entrada é validada pelo contrato derivado do grafo; valores monetários e datas são normalizados | Não |
| 3 | Autorizar | A política com escopo é avaliada sobre a entrada (ator, papel, escopo, registro referenciado) | Não |
| 4 | Abrir | Abre a unidade de trabalho: transação mais externa, contexto assinado com `SET LOCAL`, registro de idempotência | Sim |
| 5 | Executar | Roda o bloco `call` com as capacidades declaradas; efeitos externos só pelo Effect Boundary | Sim |
| 6 | Persistir | Grava pelos repositórios; reautoriza sobre o estado final; confere campos de transição | Sim |
| 7 | Registrar | Grava na mesma transação os eventos na outbox, o histórico e a auditoria | Sim |
| 8 | Confirmar | Faz o commit, devolve a resposta; só depois o relay entrega os eventos aos handlers | Commit |

O desenvolvedor só escreve o `call` da etapa 5. As etapas 6 e 7 são executadas pelo framework a partir das
declarações (`emits`, `history`, `personal:`).

### Três saídas de falha

| Saída | Quando | Transação aberta? | Resposta padrão |
|---|---|---|---|
| Entrada inválida | Etapa 2 | Não | 422, com os erros por campo |
| Acesso negado | Etapa 3 | Não | 403 (ou 404 quando revelar a existência do registro for um vazamento) |
| Falha na execução | Etapas 4 a 8 | Sim, desfeita por inteiro | 422 para `fail!`, 409 para conflito, 500 para erro inesperado |

Qualquer falha depois da etapa 4 desfaz **tudo**: dados, evento na outbox, histórico e registro de
idempotência. Não existe estado intermediário visível.

### Pré-condições, garantias e limites por etapa

**1. Resolver.**
- Pré-condição: credencial ou sessão válida, ou papel `visitor` explícito na entidade.
- Garantia: o ator e o tenant vêm da credencial, nunca da entrada do usuário. Um campo `company_id` enviado
  no corpo é ignorado (ou recusado, se divergir).
- Limite: a validade da credencial é problema do adaptador de autenticação, não deste ADR.

**2. Validar.**
- Garantia: só entra na etapa seguinte uma entrada que cumpre o contrato derivado da entidade e do comando
  (tipos, tamanhos, `required`, `Float` recusado em campos monetários). Campos de transição (`set_by:`,
  `guarded:`) enviados por um comando genérico são recusados aqui (ADR-021).
- Limite: validações que dependem do banco (unicidade, existência) ficam para a etapa 6, para não haver
  corrida entre validar e gravar.

**3. Autorizar.**
- Garantia: nenhuma transação é aberta para um ator sem permissão. A avaliação usa o escopo declarado
  (`scope_from:`).
- Limite: esta é a autorização **de entrada**. O estado final é reautorizado na etapa 6, porque um `update`
  pode mudar o registro para um escopo onde o ator não tem acesso (a troca de revenda do exemplo 1).

**4. Abrir.**
- Garantia: a transação mais externa recebe o contexto assinado (tenant, ator, validade curta) com
  `SET LOCAL`. O formato do token, a chave e a rotação são do ADR-005; este ADR só fixa **quando** ele é
  definido: uma vez, na transação mais externa, nunca dentro de um savepoint.
- Garantia: o registro de idempotência (ver abaixo) é gravado aqui, dentro da transação.
- Limite: consulta multiempresa fora de transação é recusada com erro explícito, não com resultado vazio.

**5. Executar.**
- Garantia: o bloco `call` só enxerga as capacidades que o comando declarou (`uses`). Relógio, UUID,
  aleatoriedade e qualquer efeito externo vêm de capacidades, o que os torna interceptáveis e simuláveis.
- Limite: código que abra conexão própria ou faça I/O direto escapa do Effect Boundary. É a fronteira de
  confiança documentada no pilar 6; a classificação das dependências (confiáveis, restritas, fora da
  garantia) vale aqui.

**6. Persistir.**
- Garantia: o RLS com `USING` e `WITH CHECK` é a barreira final. A reautorização sobre o estado final roda
  aqui, antes do commit. Campos de transição só mudam pelo comando que os declara.
- Limite: a reautorização cobre o que a política declara. Regras que dependem de dado fora do banco não são
  verificadas.

**7. Registrar.**
- Garantia: o evento (com o `xid8` da transação, usado para ordenar a entrega), o histórico e a auditoria são
  gravados **na mesma transação** que os dados. Ou tudo existe, ou nada existe.
- Limite: dado pessoal no histórico e na auditoria é cifrado com a DEK do titular (pilar 7); a eliminação por
  destruição da DEK não alcança backups anteriores da chave.

**8. Confirmar.**
- Garantia: o commit é o único ponto em que a operação passa a existir para o resto do sistema. A resposta
  só é enviada depois dele.
- Limite: se o processo cair entre o commit e a resposta, o cliente não sabe o resultado. A chave de
  idempotência existe para esse caso (ver abaixo).

### Unidade de trabalho e savepoints

- Há **uma** transação por operação. Um comando que chama outro comando (composição) não abre outra
  transação: usa um **savepoint**.
- O rollback de um savepoint desfaz também os eventos, o histórico e a auditoria gravados dentro dele,
  porque eles são linhas da mesma transação. Nenhum evento sai por causa de um trecho revertido.
- O contexto assinado não é redefinido dentro de um savepoint: o `SET LOCAL` feito lá seria desfeito no
  rollback do savepoint. Trocar de tenant no meio da operação também é proibido.
- Um comando chamado por composição é reautorizado com o ator da operação externa; não há elevação de
  privilégio por composição. Operar como outro ator exige uma capacidade explícita e auditada.

### Effect Boundary e outbox

- **Dentro da transação, o único efeito externo permitido é gravar uma linha na outbox.** Enviar e-mail,
  chamar API de terceiros, publicar em fila: tudo isso é feito por um **handler**, depois do commit.
- O relay lê a outbox com `SKIP LOCKED`, na ordem do `xid8`, e só entrega eventos abaixo de
  `pg_snapshot_xmin(pg_current_snapshot())`, o ponto em que todas as transações anteriores já terminaram
  (a mecânica completa fica no ADR-020).
- A entrega é **pelo menos uma vez**. O handler deduplica pela chave do evento (`idempotent_by :event_id`).
  Essa deduplicação protege o **handler**, não o mundo externo: o efeito só ocorre exatamente uma vez se o
  provedor externo aceitar uma chave de idempotência.
- Um handler também é uma operação: ele só age por comandos, então passa pelas mesmas oito etapas quando
  precisa escrever.

### Idempotência da operação

- O adaptador pode fornecer uma chave de idempotência (cabeçalho `Idempotency-Key` em HTTP, argumento em
  CLI, identificador do job ou do webhook).
- A tabela de idempotência tem chave única em `(tenant, comando, chave)` e guarda um hash da entrada e o
  resultado. É gravada na etapa 4, na mesma transação, então só existe se a operação foi confirmada.
- Mesma chave e mesma entrada: devolve o resultado guardado, sem executar de novo. Mesma chave com entrada
  diferente: 422 com erro explícito. Chave em uso por uma operação ainda aberta: o segundo pedido espera o
  lock da linha; passado o `lock_timeout`, recebe 409.
- A chave tem prazo de retenção configurável (padrão proposto: 24 horas), passado o qual pode ser reutilizada.
- Sem chave, a operação **não** é idempotente. Isso é dito na documentação de cada adaptador, e comandos
  expostos a webhooks de terceiros exigem a chave (o identificador do evento do provedor).

### Concorrência, timeouts e repetição

- Nível de isolamento padrão: `READ COMMITTED`. Regras que dependem de ler e depois escrever o mesmo
  registro usam `lock!` explícito no `call` (como em `win_lead`). `SERIALIZABLE` é opt-in por comando.
- Cada adaptador declara `statement_timeout` e `lock_timeout`. Estourar um deles desfaz a operação e responde
  com erro retentável.
- Em falha de serialização ou deadlock, o framework **repete a operação inteira** (no máximo 3 vezes, com
  espera crescente com variação aleatória). Isso só é seguro porque a etapa 5 não tem efeito externo fora do
  Effect Boundary; um comando que declare uma capacidade sem repetição segura (`retry: false`) não é
  repetido.
- Streaming e operações longas (relatórios, importações) não rodam dentro de uma única unidade de trabalho:
  são divididas em comandos menores ou viram workflow durável (pilar 5).

### O que cada superfície pode variar

| Superfície | Timeout | Idempotência | Observação |
|---|---|---|---|
| HTTP | Por rota, com padrão do app | `Idempotency-Key` opcional; obrigatório em rotas marcadas | Resposta e código seguem a tabela de falhas |
| CLI | Sem limite padrão, configurável | Argumento `--key` | Sai com código diferente de zero em qualquer das três falhas |
| Job | Do job | Identificador do job | Repetição do job reutiliza a chave |
| Webhook | Curto, com resposta rápida | Identificador do evento do provedor (obrigatório) | Valida a assinatura antes da etapa 1 |
| MCP | Do comando | Chave por chamada do agente | Comando sensível exige aprovação humana antes da etapa 4 (ADR-011) |

Nenhuma superfície pode pular uma etapa, trocar a ordem ou ter transação própria.

## Alternativas rejeitadas

- **Responsabilidades espalhadas entre comando, job e persistência** (o estilo Rails): é o problema que
  motiva o ADR. Cada superfície reimplementa as etapas, e a diferença entre elas só aparece em produção.
- **Transação aberta pelo adaptador.** Faria cada superfície decidir o próprio limite transacional e permitiria
  validar ou autorizar com a transação aberta, segurando conexão e lock por entrada inválida.
- **Autorizar só dentro do `call`.** Gastaria uma transação por pedido negado e deixaria a autorização a cargo
  do desenvolvedor, que pode esquecê-la.
- **Publicar eventos em hook pós-commit na memória do processo.** Um crash entre o commit e a publicação
  perderia o evento. A outbox na mesma transação não perde.
- **Promessa de entrega exatamente uma vez.** Não é alcançável com efeitos externos sem a cooperação do
  provedor; prometer isso seria afirmar mais do que o mecanismo oferece.
- **Repetir a operação sem restrição.** Duplicaria efeitos externos; por isso a repetição depende do Effect
  Boundary.

## Consequências

- As etapas, a ordem e as três saídas de falha viram vocabulário comum de erros, logs, traces e relatórios
  (`vetra explain` mostra em que etapa uma operação parou).
- Entrada inválida e acesso negado são baratos: não abrem transação nem pegam conexão do pool.
- Há uma tabela de idempotência e uma outbox por banco, e o custo de escrevê-las entra em toda operação
  confirmada. O benchmark da fase 1 deve medir esse custo.
- A reautorização sobre o estado final fecha a classe de falha do exemplo 1 (troca de revenda no `update`)
  para tudo que usa o CRUD gerado.
- O modo hospedado precisa honrar o mesmo contrato quando o Active Record e o Sequel dividem a transação
  (os cinco testes da estratégia de adoção, em particular o rollback de savepoint e a devolução limpa da
  conexão ao pool).
- Operações que não cabem numa transação curta precisam ser desenhadas como comandos menores ou workflows,
  o que é uma restrição real para quem vem do Rails.

## Garantias e seus níveis

| Garantia | Nível | Mecanismo |
|---|---|---|
| Nenhuma operação executa sem passar pelas oito etapas | Estrutural | O grafo só expõe comandos pelo adaptador; não existe caminho para o banco fora dele, para o que foi declarado |
| Dados, evento, histórico e auditoria existem juntos ou não existem | Transacional | Mesma transação do PostgreSQL |
| Isolamento entre tenants na gravação | Transacional e verificável por testes | RLS com `WITH CHECK` e contexto assinado |
| Evento entregue pelo menos uma vez, em ordem de commit | Operacional | Outbox, `xid8` e relay; depende do relay estar rodando |
| Efeito externo exatamente uma vez | Operacional | Só com chave de idempotência aceita pelo provedor |
| Repetição segura após deadlock | Verificável por testes | Depende de o `call` respeitar o Effect Boundary |

## Testes de aceitação

1. Entrada inválida e acesso negado não abrem transação (verificado pela contagem de transações no banco).
2. Uma exceção em qualquer ponto das etapas 5 a 7 não deixa dado, evento, histórico nem registro de
   idempotência.
3. O rollback de um savepoint não deixa evento na outbox.
4. Um `update` que move o registro para um escopo sem permissão é recusado na etapa 6.
5. Um comando genérico não consegue gravar um campo de transição.
6. Duas chamadas simultâneas com a mesma chave de idempotência executam o `call` uma vez só.
7. A mesma chave com entrada diferente é recusada.
8. Um handler que recebe o mesmo evento duas vezes não repete o efeito declarado como deduplicado.
9. Uma falha de serialização repete a operação sem duplicar eventos.
10. Todas as superfícies (HTTP, CLI, job, webhook) produzem o mesmo resultado e o mesmo histórico para a
    mesma entrada.
11. Os testes rodam com os mesmos papéis de banco de produção, com PostgreSQL real.

## Questões que este ADR deixa para outros

- Formato do contexto assinado, emissão, validade e rotação da chave: ADR-005.
- Ordem e continuidade da entrega de eventos, checkpoint e ressincronização: ADR-020.
- Como o MCP classifica comandos sensíveis e coleta a aprovação humana: ADR-011.
- Custo medido do HMAC por consulta e da escrita na tabela de idempotência: medição da fase 1.
- Retenção da chave de idempotência (24 horas é hipótese de trabalho).

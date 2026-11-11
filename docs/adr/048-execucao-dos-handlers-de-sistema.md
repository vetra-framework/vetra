# ADR-048: Execução dos handlers de sistema

- Status: proposto
- Data: 2026-11-11
- Depende de: ADR-004, ADR-008, ADR-014, ADR-016, ADR-024 (§§1 e 4), ADR-043, ADR-045, ADR-046 e ADR-047

## Contexto

O relay já materializa e reserva entregas, e o Runner admite comandos para uma identidade de sistema pela lista `calls` do
handler. Falta ligar os dois: executar o bloco do handler, encaminhar comandos e efeitos com uma chave estável, impor o timeout
total e traduzir a falha em nova tentativa ou entrega morta. Os dois handlers dos exemplos têm `calls: []`; os testes precisam de
uma cópia temporária com dois handlers do mesmo evento chamando o mesmo comando. A IR e os planos dos exemplos ficam preservados.

## Decisão

### Superfície e identidade

`Execution::HandlerRunner.new(linked:, relay:, runner:, effects:)` recebe o relay com seu pool `vetra_relay`, um Runner com
pool `vetra_app` e uma borda interna que aceite a `Identity` confiável passada como credencial. Ambos usam o mesmo grafo vinculado.
`work(handler_id, limit: 10)` reserva uma entrega por vez, imediatamente antes de executar, e devolve contagens de `done`, `retry`,
`dead` e `lost`. O tenant vem exclusivamente de `Delivery#tenant_id`, nunca do payload, do ator original ou de um argumento do
bloco. `system_actor` é o ID completo do handler, sem `actor_id` nem papéis. Aplicação sem tenant ou sem outbox recusa a carga.

O bloco recebe um `Data` imutável com os campos declarados do payload (campos desconhecidos são ignorados, opcionais ausentes
chegam como nil). O hospedeiro oferece `call_command(:nome_local, entrada)` ou `call_command('domínio.comando', entrada)`, além
de `fail!`. O método confere `calls` antes de despachar, e o Runner confere novamente a autoridade do mesmo handler. Cada comando
abre sua unidade; o handler não envolve comandos ou efeitos em uma transação. Um comando confirmado sobrevive à falha posterior
do handler. O valor devolvido por `call_command` é sempre o JSON imutável do contrato de saída, também na primeira execução, para
que uma repetição não mude as decisões seguintes do bloco.

Um resultado inválido, negado, não encontrado, uma falha de negócio ou um conflito definitivo do comando falha permanentemente a
entrega; um resultado retentável ou erro de servidor pede nova tentativa pelo relay. Em particular,
`execution_idempotency_personal` falha permanentemente **sem abrir a unidade do comando**, como o ADR-047 exige: não se remove a
chave nem se omite o campo pessoal para contornar a recusa. `Relay::PermanentFailure` e `fail!` do handler vão a `dead`; exceções
inesperadas pedem nova tentativa. O relay continua guardando só a classe do erro, sem mensagens ou dados do evento.

As capacidades externas de `uses` recebem fachadas congeladas. `effects` mapeia o ID completo da capacidade para o provedor
confiável; o despachante encaminha o método/argumentos, impõe o `timeout_ms` da capacidade e injeta `idempotency_key:` quando
declarado `true`, sobrescrevendo eventual chave escolhida pelo bloco. Não há adaptador de rede genérico: configuração de hosts e
restrições do protocolo são obrigações do provedor da capacidade. O relógio `core.clock` usa o instante do evento, estável nas
tentativas. Outros executores de capacidade (inclusive repositório direto no handler) são recusados na carga nesta versão;
leituras e escritas de dados feitas pelos comandos usam as capacidades e guardas do Runner. Uma capacidade não declarada nunca é
injetada. A aplicação continua dentro dos limites de confiança do ADR-004: I/O próprio ou código comprometido escapa da fachada.

### Chave e retenção

A chave base é `event:` seguido do SHA-256 hexadecimal do JSON canônico `[handler_id, event_id]` (70 caracteres ASCII visíveis).
Não depende do worker, da tentativa, do tenant do payload nem do tempo de execução. O digest de uma tupla evita ambiguidades de
separador e cabe mesmo para IDs longos. O primeiro comando usa a base; a segunda chamada ao **mesmo comando** acrescenta `:2`, e
assim por diante. Cada capacidade externa tem seu próprio contador de invocações, com a mesma base para a primeira e o mesmo
sufixo de ocorrência. Assim o mailer de uma chamada recebe exatamente a chave usada pelo comando da mesma ocorrência. Comandos
diferentes podem usar a base porque a unicidade inclui o comando. Provedores distintos devem deduplicar no âmbito da capacidade.

A sequência e os argumentos das chamadas precisam ser estáveis entre tentativas. Reordenar ocorrências ou mudar seus argumentos
num deploy pode causar `data_idempotency_key_reuse`; o contador não é um histórico durável de execução do handler. Chamadas
paralelas no mesmo bloco não são suportadas. O contador reinicia em cada entrega, e um replay continua ocupando a mesma ocorrência.

O Runner aceita `idempotency_origin: :event, idempotency_event: { handler:, event_id:, event_created_at: }`, mantendo o padrão
`:adapter` da API anterior. Antes da etapa 4, recusa metadados incoerentes, falta de chave/outbox ou handler diferente da identidade.
Encaminha origem e evento ao `claim!` na mesma unidade. O principal é `system:<handler>`; a unicidade continua sendo
`(tenant, comando, chave)`, sem separar por principal. O instante da retenção é enviado como texto UTC com microssegundos e cast
explícito `timestamptz`, para não mudar com o fuso da sessão. A purga do ADR-043 mantém a chave enquanto existir entrega, inclusive
`done` e `dead` e a cópia em `dead_deliveries`, e nunca menos que o prazo mínimo. Não há reprocessamento de `dead` nesta entrega.

### Timeout total e fechamento

O orçamento total do worker é **30 segundos**, com **lease de 60 segundos**. Uma opção de infraestrutura permite outro orçamento
para testes/sondas, com lease inteira de 1 a 3600 segundos e pelo menos duas vezes o orçamento; não há opção por handler na IR.
Um único `Timeout.timeout` envolve a preparação, as capacidades e todo o bloco; os timeouts de cada capacidade ou instrução SQL
não reiniciam nem substituem esse orçamento. `complete` e `failed` ficam fora dele.

O timer levanta `Execution::HandlerTimeout`, derivada de `Exception`, que atravessa o mapeamento de `StandardError` do Runner e
os resgates usuais do bloco. Dentro do bloco da unidade, a interrupção é imediata e o fechamento incompleto chama `abandon!`;
o Sequel desfaz a transação e limpa a conexão antes de devolver o controle ao worker. O Runner adia **essa** interrupção durante
a abertura e o controle/limpeza da transação, por `Thread.handle_interrupt`, para não interromper BEGIN/COMMIT/ROLLBACK no meio.
Se COMMIT já começou, ele pode terminar; a chave confirmada protege a recuperação. A propagação do timeout espera esses trechos
terminarem: não é uma promessa de matar o processo aos 30 s, e os limites de sessão/instrução da C15 continuam necessários.
Não se abandona uma thread ainda trabalhando nem se devolve sua conexão ao pool enquanto ela executa.

O timeout registra falha retentável pelo relay, com tentativa e espera crescente, **preservando a lease** da reserva interrompida
até vencer. Outro worker recupera depois da lease e de `run_after`; na décima falha vai a `dead` normalmente. Um processo morto
antes de registrar a falha também é recuperado pela lease. Código que captura `Exception` e suprime o cancelamento ou extensões
nativas que não atendem interrupções estão fora desta garantia; o processo deve ser supervisionado operacionalmente.

## Alternativas rejeitadas

- Chave só do evento: colide entre handlers com o mesmo comando e principal diferente.
- Chave aleatória por tentativa: a queda depois do commit repete a escrita.
- Uma transação para o handler inteiro: inclui rede e prende conexão, locks e `xmin`; mistura comandos já confirmáveis.
- Somente timeout das capacidades ou SQL: não limita CPU, espera e soma de chamadas do handler.
- Matar uma thread e continuar sem aguardar o fechamento: pode deixar SQL em execução ou transação aberta.
- Suprimir a idempotência quando a saída é pessoal: perde a proteção da queda depois do commit.

## Consequências

A entrega continua pelo menos uma vez; o provedor só deduplica se aceitar a chave e mantê-la pelo tempo necessário. O handler
pode executar um prefixo de comandos e falhar depois; a tentativa seguinte repete o bloco, mas os comandos confirmados devolvem
o resultado guardado. A ordem das chamadas faz parte do contrato operacional do handler. Não há mudança de IR, plano, modelo,
retrato ou dependência. Histórico, auditoria, cifra e reprocessamento auditado continuam na rodada 6.

## Garantia

- **Sem banco:** testes com Runner/Idempotency reais sobre tabelas simuladas e relay com lease verificam dois handlers, repetição,
  queda após commit, chave no provedor, ocorrências, recusas por `calls` e saída pessoal, falhas, tenant e timeout com rollback.
  Um timeout durante COMMIT também é verificado: o controle termina e o próximo worker obtém replay.
- **PostgreSQL, 12 verificações no 17 e no 18, e na CI:** `script/sonda_handlers.rb`, com planos aplicados como
  `vetra_migrator`, aplicação `vetra_app` e relay `vetra_relay`, evento emitido pelo Runner, SIGKILL de um worker antes de
  `complete`, recuperação sem escrita/emissão repetidas, retenção e purga, isolamento e timeout. Sintaxe conferida sem banco.
- **Revisão arquitetural:** `Graph::Diff` já classifica `calls` de handler como `permissions`; conferido sem alterar o diff.

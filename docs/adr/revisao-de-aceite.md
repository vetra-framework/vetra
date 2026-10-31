# Lista de revisão para aceitar os ADRs

Os 21 ADRs estão escritos e foram aceitos: os da rodada 1 (016, 001 e 002), os da rodada 2 (003, 004, 005, 006,
007, 008, 015 e 017), os da rodada 3 (010, 011, 012, 013, 014, 018, 020 e 021) e os da rodada 4 (009 e 019). Esta
lista organiza a revisão: em que ordem ler, o
que conferir em cada ADR e o que o revisor precisa aceitar de forma explícita. Ela não aceita nada por si; a
decisão é de quem revisa.

Aceitar um ADR é aceitar a **decisão**, não a implementação: fora o compilador da fase 0, nenhum componente
existe ainda. Como um ADR aceito não é editado (uma mudança gera outro ADR que o substitui), o momento de
corrigir texto, números e referências é **antes** do aceite.

A classificação "pode mudar a decisão" abaixo é uma **proposta** de quem escreveu os ADRs, baseada no critério da
seção seguinte. O revisor pode discordar e reclassificar.

## Critérios para cada ADR

- [ ] **Decisão verificável.** Dá para dizer, de cada afirmação central, se foi cumprida ou não.
- [ ] **Dependências.** Os ADRs de que ele depende já foram aceitos, ou são aceitos junto. Aceitar um antes do
  outro pressupõe a decisão que ainda não foi tomada.
- [ ] **Evidência.** Cada afirmação sobre o PostgreSQL ou sobre uma biblioteca tem uma sonda em `script/` que
  passou, ou está marcada como hipótese.
- [ ] **Limites aceitos.** Cada garantia declara o nível (estrutural, transacional, verificável por testes,
  operacional, experimental ou fora da garantia), e o revisor aceita o que ficou de fora.
- [ ] **Questões em aberto classificadas.** Uma questão **pode mudar a decisão** se a resposta altera o que o
  ADR decide; nesse caso se resolve antes do aceite. Se só ajusta um parâmetro ou um detalhe de implementação,
  ela é **adiável**. Os números marcados como hipótese (por exemplo "10 tentativas") são valores iniciais, não
  decisões.
- [ ] **Testes de aceitação.** O ADR lista testes que dá para executar e diz com que ambiente (PostgreSQL real,
  os mesmos papéis de produção).
- [ ] **Texto coerente.** Nenhuma frase contradiz outro ADR ou repete como pendência o que outro já decidiu.

## Ordem de revisão

A ordem segue as dependências ("Depende de" no cabeçalho de cada ADR). Os ADRs de uma rodada não dependem uns
dos outros, então podem ser revisados em qualquer ordem entre si.

| Rodada | ADRs | Depende de |
|---|---|---|
| 1 | 016, 001, 002 (**aceitos**) | nada |
| 2 | 003, 004, 005, 006, 007, 008, 015, 017 (**aceitos**) | só da rodada 1 |
| 3 | 010, 011, 012, 013, 014, 018, 020, 021 (**aceitos**) | rodadas 1 e 2 |
| 4 | 009, 019 (**aceitos**) | 009 depende do 014 (rodada 3); 019, do 020 e do 013 (rodada 3) |

O índice sugere começar pelos que a fundação usa: 016, 001, 004, 005, 007 e 003. Todos estão nas rodadas 1 e 2.

## Visão geral

A coluna "Evidência" lista as sondas que conferem o que o ADR afirma sobre o PostgreSQL ou sobre bibliotecas.
Onde está "nenhuma", o ADR é uma decisão de projeto e o que o sustenta são os testes de aceitação, ainda sem
implementação.

A CI reverifica a cada PR, no PostgreSQL 17 e no 18, as sondas `sonda_adr002`, `sonda_adr003`, `sonda_adr009`,
`sonda_adr011`, `sonda_adr015` e `sonda_adr019`. As de `sonda_adr006` (exige `RUBY_BOX=1`) e `sonda_pooler`
(exige um PgBouncer) são manuais: parte da evidência dos ADRs 003, 005, 006 e 008 vem de resultados que a CI não repete.

| ADR | Rodada | Depende de | Evidência | Testes de aceitação | Questões em aberto |
|---|---|---|---|---|---|
| 016 Ciclo de vida da operação | 1 | | nenhuma | 11 | 5 (deixadas a outros) |
| 001 Grafo da Aplicação e IR | 1 | | compilador da fase 0 | 11 (fase 0) | 3 |
| 002 Somente PostgreSQL | 1 | | `sonda_adr002` | 5 | 3 |
| 003 Sequel e repositórios | 2 | 002 | `sonda_adr003`, `sonda_pooler` | 11 | 6 |
| 004 Capacidades e Effect Boundary | 2 | 016 | compilador da fase 0 (testes 2 e 3) | 8 | 4 |
| 005 RLS e contexto assinado | 2 | 016, 002 | `sonda_adr002`, `sonda_pooler` | 13 | 5 (deixadas a outros) |
| 006 Isolamento de domínios | 2 | 001 | `sonda_adr006` | 7 | 5 |
| 007 Comando e adaptadores | 2 | 016 | compilador da fase 0 (regras de rota; teste 6 em parte) | 9 | 4 |
| 008 Ordem e continuidade dos eventos | 2 | 016, 002 | `sonda_adr002`, `sonda_pooler` | 9 | 3 |
| 015 Migrações expand/contract | 2 | 002, 001 | `sonda_adr015`, `sonda_adr002` | 12 | 6 |
| 017 Tipo `money` | 2 | 001 | compilador da fase 0 (literais `money`; teste 1 na IR) | 12 | 5 |
| 010 Adoção hospedada e modo serviço | 3 | 002, 003 | nenhuma (modo hospedado não exercitado) | 8 | 6 |
| 011 MCP com identidade delegada | 3 | 007, 016, 005 | `sonda_adr011` (o `FOR SHARE` da revogação) | 17 | 9 |
| 012 Canário em modo sombra | 3 | 004, 016 | `sonda_adr002` (`xid`); o campo `simulation` na IR | 13 | 6 |
| 013 Privacidade, auditoria e histórico | 3 | 016, 005 | compilador da fase 0 (`privacy`, payload de eventos, diff; teste 2) | 13 | 8 |
| 014 Outbox | 3 | 016, 008, 002 | `sonda_adr002` | 13 | 6 |
| 018 Camada de UI | 3 | 007, 016 | nenhuma sonda (o ERB da biblioteca padrão foi conferido à mão) | 16 | 7 |
| 020 Entrega live incremental | 3 | 005, 008, 016, 001 | nenhuma | 12 (11 do gate G4) | 7 |
| 021 Campos de transição | 3 | 016, 004 | compilador da fase 0 (testes 4 em parte e 8) | 9 | 2 |
| 009 Workflows | 4 | 016, 004, 014 | `sonda_adr009` | 13 | 7 |
| 019 Sinais efêmeros | 4 | 020, 008, 005, 013 | `sonda_adr019` | 13 | 6 |

## Por ADR

Em cada ADR, "limites" são as garantias que o próprio texto classifica abaixo de "verificável por testes" ou
"estrutural". "Pode mudar a decisão" é a proposta descrita no início.

### Rodada 1

**Aceitos.** Antes do aceite, os três foram relidos inteiros e receberam correções, porque um ADR aceito não é
editado: um erro de nome no 016 (`retry:` onde a IR usa `retry_safe`), as listas de dependentes do 016 e do 002, e
uma frase do 001 presa ao status "proposto". As decisões não mudaram. Os itens abaixo ficam como registro do que o
revisor precisou aceitar.

**ADR-016 · Ciclo de vida da operação**
- [ ] Limites: "evento entregue pelo menos uma vez, em ordem de commit" é operacional (depende do relay estar
  rodando); "efeito externo exatamente uma vez" é operacional (só com chave de idempotência aceita pelo
  provedor); a repetição segura após deadlock depende de o `call` respeitar o Effect Boundary (ADR-004).
- [ ] Pode mudar a decisão: nenhuma. As cinco questões são deixadas a outros ADRs (005, 008, 011), à medição da
  fase 1 (custo do HMAC) e à retenção da chave de idempotência (24 horas é hipótese).

**ADR-001 · Grafo da Aplicação compilado em IR versionada**
- [ ] Limites: "Ruby arbitrário obedece ao declarado" está fora da garantia estrutural; a autenticidade do
  pacote de release é operacional.
- [ ] O protótipo da fase 0 cobre só um subconjunto dos critérios (execução das operações, primitivas CRUD e
  garantias transacionais seguem pendentes). Aceitar a IR como contrato é aceitar que o formato evolui de forma
  explícita para UI, workflows e MCP.
- [ ] Pode mudar a decisão: nenhuma. As três questões estão no próprio ADR como "não bloqueiam a fase 0".

**ADR-002 · Somente PostgreSQL**
- [ ] Evidência: `sonda_adr002` (23 itens). O 17.11 e o 18.6 cumprem os 23; o 16.15 reprova nos dois itens que
  justificam o mínimo 17 e passa nos outros 21. O PostgreSQL 19 não foi encontrado no espelho usado e entra na
  matriz quando existir.
- [ ] Limites: "o ambiente cumpre os requisitos" é operacional; derivados do PostgreSQL ficam fora da garantia
  até passarem na conformidade.
- [ ] Aceitar o mínimo 17: exclui instalações antigas, e o modo serviço (ADR-010) é a saída.
- [ ] Pode mudar a decisão: nenhuma. As três questões são listas de referência e conveniências de ambiente.

### Rodada 2

**Aceitos: 003, 005, 006, 008 e 015.** Foram relidos inteiros antes do aceite e receberam correções de texto: as
listas de dependentes do 005 e do 008 estavam incompletas (faltavam 011, 013 e 019 no primeiro, e 019 no
segundo); o 015 chamava de "matriz do ADR-002" as três versões medidas, quando a matriz é 17 e 18; o 008 ganhou a
seção "Verificação preliminar", que separa o que as sondas conferem do que ainda não tem sonda; o 011 passou a
dizer que a extensão do contexto assinado é dele, e não do ADR-005. As decisões não mudaram. Os **004**, **007** e
**017** tinham, cada um, uma questão que podia mudar a decisão (marcada abaixo) e foram aceitos depois, cada um num
PR à parte, com a questão resolvida (veja o item de cada um). Com o 017, a rodada 2 está completa.

**ADR-003 · Sequel com camada fina de repositórios**
- [ ] Evidência: `sonda_adr003` (19 itens, no 16.15, 17.11 e 18.6) e `sonda_pooler` (8 itens, PgBouncer 1.26.1).
- [ ] Limites: "o `call` só alcança dados pelo repositório declarado" é estrutural com o limite do ADR-004;
  "substituir o Sequel sem tocar a aplicação" é experimental. O comportamento atrás de pooler foi medido só no
  PgBouncer 1.26.1; a regra de não usar statements nomeados fica como padrão portátil.
- [ ] Pode mudar a decisão: nenhuma. Duas questões viram limites declarados (outros poolers; `pg` com o Falcon em si).
  O índice pede resolver as questões deste ADR antes da persistência.

**ADR-004 · Capacidades e Effect Boundary** (aceito)
- [ ] Evidência: o compilador da fase 0 já faz a análise Prism do `call` (`direct_effect` para `Time.now`,
  `Date.today`, `Net::HTTP`, `File`, `SecureRandom` e semelhantes), aceita `unsafe_effect` com motivo e recusa
  capacidade externa em comando (`capability_boundary`): cobre os testes de aceitação 2 e 3. Os demais (host do
  `:http`, simulador, `retry_safe`, `vetra explain` e `vetra doctor`) dependem do runtime.
- [ ] Limites: "gem com conexão própria respeita o Effect Boundary" está fora da garantia.
- [ ] Pode mudar a decisão: **era a leitura externa em comandos** (cotação, CEP). Resolvida no §7 do ADR: não há
  capacidade de leitura externa nesta versão. O caminho é um handler ou um workflow, e um tipo `phase: :before`
  só entra por ADR novo, com um caso real, porque altera o ciclo de vida do ADR-016. Nenhum exemplo do módulo de
  referência precisa dela. A alternativa descartada foi adotá-la já.
- [ ] Adiável: granularidade da classificação de dependências, formato final do `effect` e a interação com o
  modo sombra (ADR-012).

**ADR-005 · RLS obrigatório com contexto assinado**
- [ ] Evidência: `sonda_adr002` (RLS com `FORCE`, combinação e troca de políticas, `security_invoker`) e
  `sonda_pooler` (o contexto por `set_config` local não vaza; um `SET` de sessão vaza).
- [ ] Limites: nenhum mecanismo do banco protege contra código comprometido no mesmo processo; a
  confidencialidade da chave do HMAC é operacional.
- [ ] Pode mudar a decisão: nenhuma. O modelo de escopos com vínculos múltiplos já tem declaração no compilador
  (`memberships`), mas o custo em política não foi medido. A frase sobre a versão mínima do PostgreSQL foi
  corrigida (a pendência já estava resolvida no ADR-002).
- [ ] Observação: o ADR-011 pede estender o contexto assinado. Aceitar este ADR é aceitar que o formato cresce.

**ADR-006 · Isolamento de domínios em três níveis, com `Ruby::Box` opcional**
- [ ] Evidência: `sonda_adr006` (13 itens; exige `RUBY_BOX=1`). A gem `pg` pré-compilada falha dentro da box
  (perde a libpq empacotada); compilada contra a libpq do sistema funciona.
- [ ] Limites: o isolamento de monkey patch é experimental; "falha de um domínio não derruba os outros" é
  operacional; o isolamento de segurança entre domínios está fora da garantia da box.
- [ ] Pode mudar a decisão: nenhuma. O `Ruby::Box` é opcional e o nível arquitetural é o padrão.

**ADR-007 · Comando como unidade única de operação e adaptadores de superfície** (aceito)
- [ ] Evidência: o compilador da fase 0 implementa as regras de rota do §4 (`route_target`, `webhook_idempotency`,
  `route_collision` e a conferência dos parâmetros de caminho). O DSL declara `expose http:`, `cli:`, `job:` e
  `webhook:`. `exposure_test.rb` cobre consulta por POST, comando por método seguro em webhook, nomes únicos por
  superfície, idempotência obrigatória de webhook, rotas ambíguas entre HTTP e webhook e vínculo único à
  operação. O caso comando por GET também é coberto na suíte anterior. Os demais testes de aceitação dependem
  do runtime; os adaptadores não foram implementados.
- [ ] Limites: nenhum; as cinco garantias são verificáveis por testes ou estruturais.
- [ ] Pode mudar a decisão: **era se uma exposição pode restringir o contrato** (aceitar menos campos que o
  comando) sem criar um comando novo. Resolvida no §7 do ADR: não pode. Uma entrada menor se resolve com campos
  opcionais ou com um comando fino que chama o original por composição. O ADR-011 já parte do contrato único, e o
  nó `route` do schema 0.1 não guarda projeção de campos. A alternativa descartada foi uma opção de `expose` que
  aceitasse só alguns campos.
- [ ] Adiável: formato da tarefa de terminal, devolução do resultado de um job, streaming.

**ADR-008 · Notificação como invalidação, ordem por `xid8` e continuidade**
- [ ] Evidência: `sonda_adr002` (tipo `xid8`; uma escrita aberta prende o `xmin`, uma leitura não) e
  `sonda_pooler` (atrás de um pooler em modo de transação o `LISTEN` entrega ao cliente que segura o backend).
  A regra de leitura por intervalo (§2), a versão por linha `_v` (§3) e a ressincronização (§4) **não têm sonda
  versionada**; o ADR declara isso e as deixa aos testes de aceitação 1, 2 e 4 a 8.
- [ ] Limites: "entrega em tempo hábil" é operacional.
- [ ] Pode mudar a decisão: nenhuma. Volume do `NOTIFY`, intervalo de leitura e retenção (1 s e 10 minutos são
  hipóteses) e partição da outbox dependem da matriz de carga.

**ADR-015 · Migrações expand/contract com análise de locks**
- [ ] Evidência: `sonda_adr015` (22 itens, no 16.15, 17.11 e 18.6; roda na CI no 17 e no 18) e `sonda_adr002`
  (troca de política atômica). As verificações de varredura contam `pg_stat_user_tables.seq_scan` em vez de
  comparar tempos.
- [ ] Limites: passos escritos à mão ficam fora da garantia.
- [ ] Pode mudar a decisão: nenhuma. Como o `db:plan` conhece o esquema atual (introspecção ou `db/schema.sql`) é
  escolha de projeto a fechar antes da persistência.

**ADR-017 · Tipo `money` nativo** (aceito)
- [ ] Evidência: o compilador da fase 0 recusa `Float` na serialização canônica da IR e confere os literais de
  `money` (texto decimal, até `precision - scale` dígitos inteiros e `scale` casas, com teste para `1.001`). Ele
  usa `scale` 2 por padrão e não conhece o expoente ISO 4217. Os demais testes dependem do runtime.
- [ ] Limites: nenhum; as oito garantias são verificáveis por testes ou estruturais, e a verificação do `scale`
  contra o expoente ainda não está implementada.
- [ ] Pode mudar a decisão: **era como o `scale` do campo e o expoente da moeda convivem**. Resolvida no §6 do
  ADR: sem `scale` declarado, o campo é monetário e o `scale` é o expoente da moeda; com `scale` maior, é de
  precisão estendida (preço unitário); `scale` menor que o expoente é erro de compilação. As alternativas
  descartadas foram a escala única sem relação com a moeda (o que o protótipo faz hoje), só o expoente sem
  precisão estendida e um tipo à parte para preço unitário. A moeda por tenant exige uma nova MENOR da IR e ficou
  como questão em aberto.
- [ ] Adiável: taxas de conversão, arredondamento por tenant, biblioteca de formatação, moedas sem ISO 4217.

### Rodada 3

**ADR-010 · Adoção hospedada em Rails ou modo serviço** (aceito)
- [ ] Evidência: nenhuma sonda e nada no protótipo (não há ponte com Rails). O ADR-003 registra que o modo
  hospedado com o Active Record não foi exercitado, e nenhuma sonda mede a gem `sequel-activerecord_connection`. O
  ADR passou a declarar isso numa seção "Verificação preliminar": a transação e o contexto de RLS compartilhados
  são hipótese até os cinco testes do ADR-003 rodarem.
- [ ] Limites: isolamento de tenant nas tabelas do Vetra no modo hospedado é transacional, condicionado;
  "nenhuma tabela com dois donos com escrita" e a consistência entre Rails e serviço são operacionais; o domínio
  Vetra não acessar models Rails fora das pontes é estrutural, com os limites do ADR-004.
- [ ] Pode mudar a decisão: **eram duas**. Resolvidas no ADR: (1) o Vetra não escreve em tabelas do Rails (§4),
  porque o grafo não enxerga os callbacks do Active Record e as etapas 6 e 7 do ADR-016 não valeriam; a escrita
  por uma ponte volta por ADR novo, com um caso real e uma medição. (2) O ator e o tenant vêm da sessão
  compartilhada do Rails, por um resolvedor que a aplicação declara, e nunca do corpo da requisição (§2); as
  permissões que existem só no Rails já seguem o ADR-020, §8.
- [ ] Adiável: menor versão do Rails, critérios de saída por domínio, convivência com migrações do Rails,
  gerador e deploy do modo independente.

**ADR-011 · MCP opt-in com identidade delegada** (aceito)
- [ ] Evidência: `sonda_adr011` (5 itens, no 16.15; roda na CI no 17 e no 18). O `FOR SHARE` da revogação (§2) foi
  conferido primeiro à mão e depois pela sonda: duas leituras com `FOR SHARE` não esperam uma pela outra, o
  `UPDATE` da revogação espera a transação que trava a linha e vale depois do commit dela, e uma operação que
  começa ou espera depois da revogação não obtém a linha. A IR 0.1 não representa a exposição MCP (o `surface`
  aceita `http`, `cli`, `job` e `webhook`) e o DSL aceita as quatro superfícies, sem MCP. O piso de sensibilidade, as delegações,
  as aprovações e o adaptador não existem.
- [ ] Limites: "argumentos hostis não ultrapassam o contrato" é verificável por testes, mas não é prova; "dado
  entregue ao agente não é repassado" está fora da garantia; o piso de sensibilidade cobre só o que a IR enxerga
  (ação, entidade e campo `money`), porque o `call` não é registrado; as recusas das etapas 1 a 3 ficam no log, não
  no Audit.
- [ ] Pode mudar a decisão: **eram duas**. Resolvidas no ADR: (1) quem classifica: todo comando exposto declara
  `approval: :required` ou `:none`, sem padrão, e o compilador deriva um piso (exclusão, vínculo de permissão,
  campo `money`) que não se baixa (§3). (2) A delegação: o contexto assinado mantém o delegante em `actor_id`, para
  o RLS nunca dar ao agente mais do que ao usuário, e ganha as claims `agent_id` e `delegation_id` dentro do `v1`;
  a revogação vale por `FOR SHARE` na etapa 6 (§2). As alternativas descartadas foram a classificação opcional, o
  agente como `actor_id` e derivar tudo do `call`.
- [ ] Adiável: autenticação do agente e transporte, canal e prazo da aprovação, validade e limite de taxa (e onde
  o contador mora), escopo por campo, leituras como ferramentas e exfiltração, se um deploy invalida aprovações
  pendentes, registro consultável das recusas, representação exata na IR, conjunto de testes adversariais.

**ADR-012 · Canário em modo sombra com capacidades simuladas** (aceito)
- [ ] Evidência: `sonda_adr002` (um `SELECT` simples não atribui `xid`, o `FOR UPDATE` atribui) e o campo
  `simulation` das capacidades na IR 0.1. O simulador, o repositório simulado e o cálculo de elegibilidade não
  existem. O comportamento do instantâneo exportado foi conferido à mão no PostgreSQL 16.15, sem sonda
  versionada, e o ADR o declara numa seção "Verificação preliminar".
- [ ] Limites: "a sombra não produz efeito externo" é estrutural com o limite do ADR-004; código fora do Effect
  Boundary está fora da garantia; "a cópia do tráfego não afeta a produção" é operacional.
- [ ] Pode mudar a decisão: **era como o repositório simulado representa leituras depois de escritas dentro da
  mesma operação.** Resolvida no §3: uma camada de escritas sobre o instantâneo, com leitura por id e consulta de
  uma entidade resolvidas em memória; o que o avaliador não resolve torna a amostra incomparável, descartada e
  contada. A releitura achou também que o instantâneo da sombra não tinha momento definido (aberto depois do
  commit da produção, a sombra veria o estado já alterado) e que o contexto da produção expira em 30 s; ambos
  foram corrigidos no ADR. As alternativas descartadas foram ignorar a leitura depois da escrita e tornar
  inelegível toda operação que lê depois de escrever.
- [ ] Adiável: formato do simulador, tolerâncias, orçamento e amostragem, `vacuum`, ordem entre requisições
  espelhadas.

**ADR-013 · Privacidade, auditoria e histórico, com criptografia por envelope** (aceito)
- [ ] Evidência: o compilador da fase 0 representa a classificação `privacy`, recusa um payload de evento que
  altere a privacidade do campo que projeta e sinaliza a mudança de privacidade no `graph:diff` (teste de
  aceitação 2). Nada do envelope, do KMS, do histórico ou da auditoria existe; o resto depende do runtime.
- [ ] Limites: eliminar o titular torna o histórico e a auditoria ilegíveis (operacional); a eliminação alcança
  os backups só de forma limitada; conformidade com a LGPD está fora da garantia.
- [ ] Pode mudar a decisão: **eram duas**. Resolvidas no ADR: (1) o titular é declarado, nunca inferido
  (`subject :self` ou `subject :relacao`, com sobrescrita por campo), e um campo pessoal sem titular é erro de
  compilação; a IR 0.1 não tem onde registrá-lo e exige uma nova MENOR. (2) A retenção obrigatória é declarada
  pelo controlador na entidade e adia só o que cobre: o dado sob retenção usa uma DEK própria da regra, e o resto
  é eliminado na hora. As alternativas descartadas foram inferir o titular, usar o ator como titular, uma DEK por
  linha, e adiar a eliminação do titular inteiro.
- [ ] Adiável: armazenamento de chaves, histórico por campos, formato e compactação, integridade da auditoria,
  algoritmo e formato do envelope, classificações além de `personal` e `sensitive`.

**ADR-014 · Outbox com entrega pelo menos uma vez** (aceito)
- [ ] Evidência: `sonda_adr002` (um `FOR UPDATE` atribui `xid`). A referência à sonda foi acrescentada ao texto.
  O protótipo recusa um handler que escreve por repositório e um evento interno sem consumidor. O relay, as
  entregas, o lease e a reentrega não existem.
- [ ] Limites: "cada evento chega pelo menos uma vez a cada handler" e "o efeito externo ocorre uma vez só" são
  operacionais.
- [ ] Pode mudar a decisão: **eram duas**. Resolvidas no ADR: (1) o handler age como um ator de sistema do tenant
  do evento, com a autoridade dos comandos que declara em `calls`; agir como o ator original exige a capacidade
  explícita e auditada do ADR-016 (§8). Não precisa de campo novo na IR. (2) O fan-out fica materializado por
  linha de entrega, como o texto já decidia; o cursor por handler volta por ADR novo, com medição. A alternativa
  descartada para o ator foi agir como o ator original, e um papel de sistema amplo.
- [ ] Adiável: tentativas máximas, espera e lease (hipóteses), partição, compatibilidade de versões de evento,
  publicação de eventos públicos. O índice pede resolver as questões deste ADR antes da persistência.

**ADR-018 · Camada de UI em módulos fora do núcleo, com ejeção em três níveis** (aceito)
- [ ] Evidência: nenhuma sonda. O ERB da biblioteca padrão (4.0.3) foi conferido à mão e não escapa a saída
  (`<%= "<b>&" %>` sai cru). Os módulos, o DSL (`ui :server`, `page`, `crud ui:` e `expose ui:` falham no
  protótipo), a representação na IR, o `vetra doctor` e os cabeçalhos de linha de base não existem.
- [ ] Limites: "uma tela ejetada reflete o contrato atual" é limitada (erro só para a referência literal que
  falha, aviso para o digest que difere); "a tela não ultrapassa a autorização" vale para o código que usa o
  runtime do Vetra, e uma página com conexão própria escapa (limite do ADR-004).
- [ ] Pode mudar a decisão: **era uma**. Resolvida no §5: todo arquivo entregue ao desenvolvedor nasce com um
  cabeçalho com o digest (SHA-256 do JCS, como no ADR-001) da projeção do contrato das operações a que se liga; o
  `vetra doctor` dá erro para o que prova de forma literal e aviso quando o digest difere, que é o caso de
  ausência (um campo obrigatório novo), e `vetra ui:resync` regrava o digest depois da revisão. A linha de base
  fica no arquivo, não na IR. As alternativas descartadas foram guardá-la na IR, usar o digest do grafo inteiro,
  reprovar o build a qualquer diferença e o merge de três vias.
- [ ] Adiável: o que o `vetra doctor` verifica em ERB dinâmico; como o `can?` é avaliado; sintaxe de `page`,
  `command_form`, `crud ui:` e `expose ui:` e a representação na IR (nova MENOR); o mecanismo do token anti-CSRF e o
  motor de template; autenticação e logs; versionamento dos módulos; acessibilidade e internacionalização.

**ADR-020 · Entrega live incremental**
- [ ] Limites: a revogação no modo `balanced` vale em até um intervalo (operacional); dados já entregues não são
  recolhidos (fora da garantia).
- [ ] Os 11 critérios do gate G4 dependem de implementação; o 8 e o 9 vêm do ADR-019 e o 10, do ADR-018. O 12
  é deste ADR.
- [ ] Pode mudar a decisão: **era** o evento de mudança de linha (quem o produz e o que carrega). A leitura
  integral mostrou que nenhum ADR o definia: o ADR-008 cita `(entidade, id, versão)`, o ADR-020 pedia `OLD` e `NEW`
  completos e o ADR-016 só define os eventos dos comandos. Quem revisa escolheu o trigger de linha gerado, sem
  campo pessoal; a decisão está na seção 10 do ADR. As demais questões são valores e hipóteses (por exemplo,
  passar para revisão por recurso com mais de 10 invalidações por minuto por tenant).

**ADR-021 · Campos de transição** (aceito)
- [ ] Evidência: o compilador da fase 0 já representa `set_by`, `guarded` e `transitions enforce:`; o contrato do
  CRUD gerado omite os campos e os valores protegidos (há teste); uma gravação literal de campo protegido por um
  comando fora da lista é recusada no boot (`transition_owner`); um valor protegido como `default:` é recusado
  (`guard_default`). A verificação na etapa 6, as telas, o trigger e o histórico dependem do runtime.
- [ ] Limites: a proteção contra SQL fora do repositório só existe com `enforce: :db` (trigger com o comando
  vindo do contexto assinado).
- [ ] Pode mudar a decisão: nenhuma, e a releitura integral confirmou isso: as duas questões (máquina de estados
  declarativa; `guarded:` para tipos além de enum) ampliam o recurso. Achou, porém, três lacunas de texto, já
  corrigidas: o trigger era só `BEFORE UPDATE` e um `INSERT` direto o contornava; o `vetra_migrator`, que o ADR
  libera, seria bloqueado pelo trigger por não ter contexto assinado; e a sintaxe de UI da regra 3 pertence ao
  ADR-018 (então ainda proposto).

### Rodada 4

**ADR-009 · Workflows duráveis por histórico de eventos e replay determinístico** (aceito)
- [ ] Evidência: `sonda_adr009` (14 itens, só biblioteca padrão; roda na CI no 17 e no 18). O motor da sonda usa
  `Fiber.yield` e `fiber.resume`, sem `Fiber::Scheduler`, e verifica que o workflow linear completa com cada
  efeito uma vez, que o replay depois de uma queda não repete o passo, que código alterado é detectado e que uma
  Fiber suspensa não é serializável. O bloqueio por `TracePoint` precisa de `:call` e `:c_call`, custa cerca de 4
  vezes e é uma lista de negação com furos (escaparam, entre outros, `Time.new`, `Date.today`, `SecureRandom`,
  `Kernel#system` e `TCPSocket`). O motor de workflows não existe.
- [ ] Limites: "os efeitos de um passo não se repetem após queda" é operacional; "o código não usa relógio,
  acaso, I/O ou threads" é estrutural, mas limitado; o bloqueio por `TracePoint` é rede de segurança de
  desenvolvimento, não garantia.
- [ ] Pode mudar a decisão: **eram duas**. Resolvidas no ADR: (1) o escalonador de fibras não entra nesta versão:
  o workflow linear suspende a Fiber a cada `ctx`, que é o que a sonda verifica, e só ramos concorrentes exigem o
  escalonador, que voltam por ADR novo (§5). (2) O workflow age como um ator de sistema do tenant da execução,
  com a autoridade dos comandos que declara, e o contexto assinado, que vale 30 s, é emitido a cada passo (§7).
  A alternativa descartada para o ator foi agir como quem iniciou a execução, que dura dias.
- [ ] Adiável: limite de tamanho do histórico, manutenção de versões antigas, sintaxe do DSL (o schema 0.1 não
  representa workflows), precisão dos temporizadores.

**ADR-019 · Sinais efêmeros autorizados pelo mesmo motor** (aceito)
- [ ] Evidência: `sonda_adr019` (5 itens, no 16.15, 17.11 e 18.6; roda na CI no 17 e no 18): limite do payload do
  `NOTIFY` (7.999 bytes passam, 8.000 falham), a notificação só no commit, as idênticas na mesma transação, o
  `LISTEN` por sessão e o volume de WAL de tabelas `UNLOGGED`. A autorização, o heartbeat e o crash da tabela não
  têm sonda versionada.
- [ ] Limites: a presença **não sobrevive a um crash do banco** (garantia não oferecida; a tabela `UNLOGGED` volta
  vazia e se recompõe pelos heartbeats); "entrega em tempo hábil" é operacional.
- [ ] Pode mudar a decisão: **era se o estado de presença é dado pessoal** para fins de privacidade (ADR-013).
  Resolvida no §3: sim, não sensível, com o usuário como titular; o identificador é mascarado nos logs e a
  eliminação remove as leases, sem cifra, porque o dado nunca vai para histórico, auditoria, outbox nem WAL. As
  alternativas descartadas foram tratá-la como dado não pessoal e como dado retido com cifra por titular.
- [ ] Adiável: valores de limitação de taxa e heartbeat (hipóteses), `autovacuum` da tabela de presença,
  comportamento num failover, limiar para adotar o Redis.

## O que já foi corrigido por esta revisão

- ADR-005: a "versão mínima do PostgreSQL" era listada como pendência, mas o ADR-002 já a fixou em 17. A frase
  agora remete ao ADR-002.
- ADR-014: a medição do `FOR UPDATE` passou a citar a sonda que a confere.
- ADR-005 e ADR-008: as listas "Dependem deste ADR" ficaram completas e rotuladas "na data do aceite" (005: 011,
  013, 019 e 020; 008: 014, 019 e 020).
- ADR-008: nova seção "Verificação preliminar" (o que tem sonda e o que não tem) e os tempos limite de transação
  entram entre as hipóteses.
- ADR-015: "as três versões da matriz do ADR-002" passou a "as três versões medidas"; cita o ADR-008 em
  "Relacionados".
- ADR-006: cita o ADR-014 em "Relacionados".
- ADR-011: a extensão do contexto assinado (identidade do agente e delegação) passou a ser deste ADR, porque o
  ADR-005 aceito não é editado; o formato `v1` já é versionado. Decisões sobre quem classifica os comandos
  sensíveis e sobre o delegante no `actor_id`. A releitura achou cinco lacunas, corrigidas: a IR 0.1 não representa
  a exposição MCP (exige uma nova MENOR); a aprovação pode chegar horas depois da autorização, então as etapas 1 a
  3 repetem e a aprovação é consumida uma vez; a entrada da aprovação pendente é dado pessoal fora do Audit e passou
  a ser cifrada pela DEK do titular; o texto prometia auditar as recusas, mas o ADR-016 (teste 1) diz que recusa não
  abre transação, então as recusas das etapas 1 a 3 vão ao log; e "suspender o agente em andamento" não tinha
  sentido transacional. Sete alternativas rejeitadas novas, uma verificação preliminar, cinco garantias novas, os
  testes de aceitação 13 a 17 e os ADRs 001 e 017 em "Relacionados".
- ADR-018: decisão sobre o versionamento da tela ejetada (cabeçalho com o digest da projeção do contrato, erro e
  aviso no `doctor`, `ui:resync`). A releitura achou seis lacunas, corrigidas: a garantia de que a tela não
  ultrapassa a autorização valia para qualquer código e passou a valer para o código que usa o runtime, com a
  análise do ADR-004 estendida à UI; uma página do nível 3 podia chamar um comando durante um `GET` e contornar o
  ADR-007, §4; o texto não tratava CSRF nem o escape de saída (o ERB padrão não escapa); `command_form` e
  `expose ui:` não diziam por qual exposição são servidos (pela `http` do comando); e a UI não está na IR 0.1
  (exige uma nova MENOR). Oito alternativas rejeitadas novas, três garantias novas, os testes de aceitação 11 a 16,
  uma verificação preliminar e os ADRs 001, 004, 010 e 021 em "Relacionados".
- ADR-009: decisões sobre o escalonador de fibras (fora desta versão) e o ator do workflow; o histórico do
  workflow, um terceiro lugar onde dado pessoal persiste, passou a ter os campos pessoais cifrados pela DEK do
  titular (ADR-013); o contrato de cancelamento, sinais e compensação, que a seção 2 citava sem definir, entrou
  nas questões em aberto; três alternativas rejeitadas, duas garantias, os testes de aceitação 11 a 13 e os ADRs
  005 e 013 em "Relacionados".
- ADR-012: decisão sobre a leitura depois de escrita no repositório simulado; o instantâneo da sombra passou a
  ser o da abertura da transação de produção (`pg_export_snapshot`), com a amostra descartada se não for importada
  a tempo; a sombra passou a usar um contexto assinado novo (o da produção expira em 30 s e daria "nenhuma
  linha" sem erro); seção "Verificação preliminar", quatro alternativas rejeitadas, duas garantias, os testes de
  aceitação 11 a 13 e os ADRs 005, 008, 014 e 020 em "Relacionados".
- ADR-019: decisão de que a presença é dado pessoal; a tabela de presença passou a declarar o `FORCE ROW LEVEL
  SECURITY` que o ADR-005 exige de toda tabela com tenant; o ADR-013 passou de "Relacionados" a "Depende de";
  duas alternativas rejeitadas, uma garantia e os testes de aceitação 12 e 13.
- ADR-021: o trigger de reforço no banco passou a ser `BEFORE INSERT OR UPDATE` (um `INSERT` direto o
  contornava); o trigger reconhece o `vetra_migrator`, e só ele; a sintaxe de UI é marcada como proposta (ADR-018);
  teste de aceitação 9 e o ADR-007 em "Relacionados".
- ADR-014: decisões sobre o ator de um handler e o fan-out por entrega; o ADR passou a refletir o ADR-013
  (campo pessoal cifrado no payload; KMS indisponível é retentável e DEK destruída vai a `dead`); o `event_id`
  é descrito ao lado de `seq` e `event_seq`; dependente (009) e os ADRs 005, 010 e 013 em "Relacionados".
- ADR-013: decisões sobre o titular do dado pessoal e a retenção legal; o ADR citava o ADR-005 para a auditoria
  somente de inclusão, mas o ADR-005 só lista privilégios das tabelas da aplicação, então a concessão passou a ser
  fixada no ADR-013; os eventos da outbox passaram a ter os campos pessoais cifrados pela DEK do titular; seis
  alternativas rejeitadas, três garantias e os testes de aceitação 11 a 13.
- ADR-010: decisões sobre a escrita em tabelas do Rails (o Vetra não escreve) e o ator da sessão do Rails, nova
  seção "Verificação preliminar" (modo hospedado não exercitado), uma alternativa rejeitada, duas garantias e os
  ADRs 007, 016 e 020 em "Relacionados".
- ADR-017: nova seção 6 (escala do campo e casas da moeda), três alternativas rejeitadas, duas garantias, os
  testes de aceitação 11 e 12 e o ADR-018 em "Relacionados".
- ADR-007: nova seção 7 (a exposição não restringe o contrato), lista de dependentes (011 e 018), ADRs 005, 009 e
  020 em "Relacionados" e o teste de aceitação 6 distingue a regra implementada do que o teste cobre.
- ADR-004: nova seção 7 (dado externo para um comando), lista de dependentes (009, 012 e 021) e o ADR-006 em
  "Relacionados"; a lista de revisão dava "nenhuma" evidência, mas o compilador da fase 0 cobre os testes 2 e 3.
- ADR-020: nova seção 10 (evento de mudança de linha por trigger gerado, sem campo pessoal), cabeçalho com o ADR-001
  e a lista de dependentes (019), e o prazo de 2 s do modo `strict` entre as hipóteses. O ADR-008 aceito não foi
  editado: a seção 10 estende o evento que ele cita.

## Depois do aceite

- Mudar de decisão gera um ADR novo que substitui o anterior.
- Resolver uma questão em aberto de um ADR aceito, sem mudar a decisão, gera um ADR de resolução (índice,
  "Convenção"). O ADR original só ganha a linha de cabeçalho que aponta para ele.
- O índice (`README.md`) passa a registrar o novo status de cada ADR.
- Antes de implementar a persistência, as questões em aberto dos ADRs 003, 005, 014 e 015 precisam estar
  tratadas por ADRs de resolução (índice, "Próximo passo", item 4).

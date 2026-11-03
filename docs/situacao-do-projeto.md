# Situação do projeto

Este arquivo reúne, num só lugar, o que já foi feito, o que espera uma decisão e o que ainda não existe. Ele não
substitui o [índice de ADRs](adr/README.md), a [lista de revisão](adr/revisao-de-aceite.md) nem a
[cobertura dos critérios da fase 0](fase-0-criterios.md): resume os três e aponta para eles.

- **Atualizado em:** 2026-11-03, sobre `ed0d90f`, com a sonda de ordem e continuidade dos eventos descrita neste commit.
  O fluxo voltou a ser integração direta na `main`, sem branches nem PRs; a proteção da branch passa a bloquear só
  force-push e exclusão.
- **Legenda:** `[x]` feito ou confirmado; `[ ]` pendente, incompleto ou não implementado. Cada pendência diz de
  quem é a decisão. "Quem revisa" é o mantenedor, que integra na `main`.

## Resumo

| Item | Situação |
|---|---|
| ADRs | 29 aceitos: os 21 fundadores, 5 ADRs de resolução (022 a 026), as evoluções de formato 027/028 e as declarações live 029; nenhum proposto |
| Testes do compilador e exemplos | 314 testes e 2.382 asserções, sem falhas; 133/133 códigos de diagnóstico exercitados, com verificação automática na tarefa da CI |
| Critérios da fase 0 (ADR-001) | 9 cobertos e 2 parciais (6 e 7); o 11 cobre os dados do compilador |
| CI registrada | Três checks verdes no push direto de `ed0d90f`, incluindo as sondas no PostgreSQL 17 e 18 ([execução 41602816769](https://github.com/vetra-framework/vetra/actions/runs/41602816769)) |
| Verificação local desta continuação | Nova sonda ADR-008: 10/10 verificações no PostgreSQL 18.6, com detecção de falhas introduzidas no intervalo e no trigger. A suíte do compilador permanece verde; grafos, IR e versão alpha.4 preservados |
| PRs e commits locais | #1 a #35 integrados; `money` em `635d926`; exposições em `7bd44cb`; verificações em `6263777`; membros do chat em `dbbd713`; README em `bb340ea`; inclusão por e-mail, correção de leitura e IR 0.2 em `694b34d`; correções de revisão no PR #36 |
| Sondas | 9 em `script/`, mais o simulador do gate da CI; 7 rodam na CI (002, 003, 008, 009, 011, 015 e 019) |
| Runtime | Não existe. Só o compilador da fase 0 foi implementado |

## Como manter este arquivo

- Todo commit que muda um status atualiza este arquivo **no mesmo commit**: marque `[x]`, anote o hash curto do
  commit (ou o número do PR, numa contribuição externa) e ajuste o resumo e a data. As mudanças entram direto na
  `main`, conforme o [fluxo de integração](graph-diff.md#fluxo-de-integração-e-ci).
- Os contadores de ADR saem dos próprios arquivos. Para conferi-los:

```bash
grep -l '^- Status: aceito' docs/adr/0*.md | wc -l
```

```bash
grep -l '^- Status: proposto' docs/adr/0*.md | wc -l
```

- Os testes são medidos com `bundle exec rake test:diagnostics`, que informa testes, asserções e cobertura dos
  códigos de diagnóstico. É a tarefa da CI e o padrão de `bundle exec rake`.
- Item novo entra como `[ ]`, com o responsável pela decisão. Item que deixou de valer é removido, não riscado.

## 1. Feito

- [x] Versão do compilador preparada como `0.1.0-alpha.4`, com lockfiles e quatro grafos reconstruídos.
  Publicação da gem continua sendo uma etapa separada.

**Compilador da fase 0** (DSL Ruby, registro congelado, build em IR 0.3, leitura da 0.1/0.2, validação)
- [x] `graph:build`, `graph:check`, `graph:validate`, `graph:diff` e `graph:link`
- [x] Todos os códigos de diagnóstico têm um teste que os dispara (#8)
- [x] Palavra-chave desconhecida ou ausente falha com `unsupported_option` e `missing_option`, nomeando o método e a
  linha da declaração (#10 e #11)
- [x] Critérios 1, 7 e 10 do ADR-001 conferidos item a item (#9)
- [x] Critério 11: os resultados dos quatro exemplos e os dados da vinculação atravessam Ractors sem cópia e
  permanecem congelados em profundidade. O núcleo carrega e executa build/check/validate/link/diff sem a
  constante pública `Ractor`. Três testes novos, sem implementar execução concorrente de operações
  (`6263777`)
- [x] Gravações literais por repositório exigem `access: read_write`, inclusive dentro de comandos. A revisão
  encontrou que a capacidade explícita `users_read` aceitava `create!`; agora falha com `write_boundary`, com
  teste de regressão no chat (`694b34d`)
- [x] IR 0.2 com `vetra.timestamps`: cada entidade tem `created_at` gerado, obrigatório e não nulo,
  incluindo raiz do tenant e junções implícitas. O campo sai das entradas CRUD e aceita índice e projeção em
  evento. Nomes reservados, atribuições literais e IR externa incompatível são recusados. O schema 0.1 é
  preservado e artefatos antigos continuam validando e vinculando sem conversão; check pede novo build.
  Quatorze testes novos cobrem determinismo, contratos, falhas, compatibilidade e diff. Os quatro exemplos
  foram reconstruídos e o chat usa `index :room_id, :created_at` (ADR-027 aceito; implementação em `694b34d`)


- [x] IR 0.3 com `vetra.structured_outputs`: consultas podem retornar coleções de registros e objetos
  compostos com referências a contratos. O compilador deriva a classificação pessoal dos contêineres;
  o validador recusa ciclos, referências inválidas, uso em contextos de escrita/eventos e rebaixamento da
  classificação. O diff propaga o uso de saída pelos contratos referenciados e trata troca de objeto/lista
  como quebra. Schemas 0.1 e 0.2 preservados, inclusive no link; ADR-028 em `cb7c0b5`.

- [x] Declarações `live` na IR 0.3 com `vetra.live`, modo strict por padrão e balanced explícito.
  O compilador deriva dependências de autorização, repositórios e saídas, incluindo as leituras das
  políticas e junções. Listas explícitas não podem omitir dependências conhecidas; análise incompleta
  exige lista explícita. `unsafe_effect`, SQL e capacidades externas são recusados. O validador confere
  IR externa; o diff destaca permissões e trata retirada de live como quebra. Vinte e um testes novos;
  ADR-029 em `ed0d90f`. Assinaturas e entrega em tempo real continuam pendentes.

**DSL**
- [x] Escopo por vínculo (`memberships`)
- [x] `many_to_many` por entidade de junção declarada ou gerada (#13)
- [x] Papéis, políticas, `crud`, `money`, `decimal`, `enum`, `slug`, privacidade, índices e chaves compostas por
  tenant
- [x] `money` sem `scale` segue o expoente da moeda da aplicação; uma escala explícita inferior é recusada
  (`money_scale`), e uma superior permite precisão estendida. A tabela ISO 4217 é local; moedas sem expoente
  definido falham com `money_currency`. Entidades, entradas de operações, contratos CRUD e payloads de eventos
  estão cobertos por 12 testes novos (`635d926`; fonte da tabela no ADR-026 aceito)
- [x] `expose http:`, `cli:`, `job:` e `webhook:` no DSL, conforme o ADR-007, mantendo uma única operação,
  contrato e autorização. Nomes são únicos por superfície; HTTP e webhook compartilham a detecção de rotas
  ambíguas; webhook exige comando com `idempotency: :required` explícito. Consultas recusam POST, job e
  webhook. O mini CRM declara as quatro superfícies de `win_lead`; 15 testes novos cobrem geração, falhas,
  vinculação e diff (`7bd44cb`)

**Exemplos**
- [x] O chat declara `add_member` e `remove_member`, com IDs tipados, autorização pela sala, política do dono,
  rotas HTTP e recusa de remover o proprietário. Os nove testes de `chat_test.rb` cobrem a IR, a vinculação e
  os corpos com duplos de memória. Comandos são explícitos, sem geração automática, executor ou revogação
  live (`dbbd713`)
- [x] O chat declara `add_member_by_email` como comando interno, sem superfícies de exposição. A busca usa
  `users_read`, normalização `downcase` e e-mail pessoal com índice único declarado. Usuário ausente ou
  ambíguo falha com a mesma mensagem, sem alterar membros. A rota HTTP foi retirada para evitar descoberta
  de cadastros; convites com aceite e a política de descoberta continuam pendentes. Os 16 testes do chat
  cobrem contratos, corpos, falhas e ausência de rota; não há executor nem índice real no banco.


- [x] `my_rooms` e `room_page` no chat, com autorização explícita e repositórios de leitura. A primeira
  retorna uma lista de salas; a segunda, sala e até 100 mensagens ordenadas por criação e ID. As exposições
  são `GET /rooms` e `GET /rooms/:room_id/page`. Os 25 testes novos cobrem formas, privacidade, contextos,
  diffs, compatibilidade e corpos em memória (`cb7c0b5`). `room_page` agora declara live com dependências
  de sala, mensagem, vínculo e usuário. Não há execução HTTP, entrega live ou expansão de membros/autores.

**CI e sondas**
- [x] `sonda_adr008.rb`: dez verificações em PostgreSQL real de intervalos `xid8`, commits invertidos,
  rollback, polling após queda do LISTEN, duas sessões ouvintes, `_v` sob lock, SQL direto, savepoints,
  snapshots novos e timeout. Passou localmente no PostgreSQL 18.6 e entrou na CI do 17 e 18.
  Duas falhas introduzidas em cópias temporárias foram detectadas; a limpeza removeu o schema mesmo com
  resultado negativo. [Relatório e limites](sondas/adr008.md). Não implementa o distribuidor nem a
  ressincronização por retenção/failover.
- [x] Diff em PRs contra o SHA da base e em pushes da main contra o SHA anterior. Falha audível em base
  ausente, tratamento explícito do primeiro push e relatório de revisão no resumo do job. Quebras
  intencionais exigem justificativa para o par exato de digests em `.github/graph-compatibility.json`.
  Oito testes do gate e 17 cenários de simulação passaram nesta revisão.
- [x] `sonda_adr011.rb` executável; os demais modos do Git foram preservados. O aviso experimental é
  silenciado apenas durante a criação de Ractors no teste, com restauração da configuração anterior.
- [x] Proteção da main redefinida em 2026-11-03 para integração direta: sem PR nem checks prévios, com
  force-push e exclusão bloqueados, inclusive para admins. O mantenedor roda a suíte e o gate antes do push
  ([fluxo](graph-diff.md#fluxo-de-integração-e-ci)). Configuração em `.github/main-protection.json`, aplicada
  pelo mantenedor e conferida por leitura da API; o push direto de `a1c4dad` passou com os três checks verdes.
- [x] CI com testes, `graph:check`, `graph:validate`, `graph:link` e o gate de diff contra a base (o gate falha
  quando não consegue ler a base, #6)
- [x] `test:diagnostics` executa a suíte uma vez e confere os códigos realmente criados em `Diagnostic.new`
  contra o catálogo extraído com Prism. Código literal sem emissão, ou emissão sem literal reconhecido,
  faz a tarefa falhar; códigos faltantes incluem as origens. Seis testes verificam o instrumento e seu status
  de falha; a CI foi configurada para a nova tarefa (`6263777`). Cobertura por código, não por ramo
- [x] Sondas de banco no PostgreSQL 17 e 18 (002, 003, 008, 009, 011, 015 e 019). A 011 (o `FOR SHARE` da revogação da
  delegação, que só estava conferido à mão no 16.15) entrou em #35
- [x] Verdicts das sondas por contagem de varreduras e por relógio do servidor, não por tempo de parede (#7)
- [x] Lista de revisão dos ADRs (#7) e auditoria dos critérios do ADR-001 (#8)

**ADRs**
- [x] Os 21 ADRs estão escritos
- [x] Rodada 1 aceita: 016, 001 e 002 (#12)
- [x] Rodada 2 aceita por inteiro: 003, 005, 006, 008 e 015 (#14), 004 (#16), 007 (#18) e 017 (#19)
- [x] Rodada 3 aceita por inteiro: 020 (#15), 010 (#20), 013 (#21), 014 (#22), 021 (#23), 012 (#25), 011 (#27) e
  018 (#28)
- [x] Rodada 4 aceita por inteiro: 019 (#24) e 009 (#26)
- [x] ADR-020 passou a definir o evento de mudança de linha (trigger gerado, sem campo pessoal), que nenhum ADR
  definia (#15)
- [x] ADR-004 decidiu o dado externo para comandos: sem capacidade de leitura externa nesta versão (#16)
- [x] ADR-007 decidiu que uma exposição não restringe o contrato do comando; uma entrada menor usa campos
  opcionais ou um comando fino (#18)
- [x] ADR-017 decidiu como o `scale` do campo e o expoente da moeda convivem: sem `scale` declarado o campo segue
  a moeda; com `scale` maior é de precisão estendida; `scale` menor que o expoente é erro de compilação (#19)
- [x] ADR-010 decidiu que o Vetra não escreve em tabelas do Rails e que o ator vem da sessão do Rails, por um
  resolvedor declarado pela aplicação (#20)
- [x] ADR-013 decidiu que o titular do dado pessoal é declarado, nunca inferido, e que a retenção legal adia só o
  que cobre, com uma DEK própria da regra; os eventos da outbox passaram a ter os campos pessoais cifrados (#21)
- [x] ADR-014 decidiu que o handler age como um ator de sistema do tenant do evento, com a autoridade dos
  comandos que declara em `calls`, e que o fan-out fica materializado por entrega (#22)
- [x] ADR-021 foi relido por inteiro e corrigido sem decisão a tomar: o trigger de reforço no banco passou a
  cobrir também o `INSERT`, e o `vetra_migrator` passou a ser reconhecido por ele (#23)
- [x] ADR-019 decidiu que a presença é dado pessoal do usuário, mascarada nos logs e removida na eliminação, sem
  cifra; e passou a declarar o `FORCE ROW LEVEL SECURITY` da tabela de presença (#24)
- [x] ADR-012 decidiu como o repositório simulado trata a leitura depois de escrita (camada de escritas sobre o
  instantâneo; amostra incomparável quando o avaliador não resolve) e corrigiu o momento do instantâneo da sombra
  (o da abertura da transação de produção) e o contexto assinado dela (um novo, porque o da produção expira em
  30 s) (#25)
- [x] ADR-009 decidiu que a primeira versão dos workflows não tem escalonador de fibras (o workflow linear
  suspende a Fiber a cada `ctx`, como a sonda verifica) e que o workflow age como um ator de sistema do tenant da
  execução, com um contexto assinado emitido a cada passo; o histórico do workflow passou a ter os campos
  pessoais cifrados (#26)
- [x] ADR-011 decidiu que todo comando exposto ao MCP declara `approval: :required` ou `:none`, sem padrão, e que o
  compilador deriva um piso que não se baixa (exclusão, vínculo de permissão, campo `money`); o contexto assinado
  mantém o delegante em `actor_id` e ganha as claims `agent_id` e `delegation_id`; a revogação vale por `FOR SHARE`
  na etapa 6. A releitura corrigiu cinco lacunas: a IR 0.1 não representa a exposição MCP, a aprovação precisa
  repetir a autorização, a entrada da aprovação pendente é dado pessoal e passou a ser cifrada, as recusas das
  etapas 1 a 3 vão ao log e não ao Audit, e "suspender o agente" ganhou sentido transacional (#27)
- [x] ADR-018 decidiu que todo arquivo de tela entregue ao desenvolvedor carrega o digest da projeção do contrato
  de que partiu (a linha de base fica no arquivo, não na IR); o `vetra doctor` dá erro para a referência literal
  que falha e aviso quando o digest difere, e `vetra ui:resync` regrava o digest. A releitura corrigiu seis
  lacunas: a garantia de autorização da tela vale para o código que usa o runtime (com a análise do ADR-004
  estendida à UI), uma página não executa comando num `GET`, o CSRF e o escape de saída (o ERB padrão não escapa)
  passaram a ser tratados, `command_form` e `expose ui:` são servidos pela exposição `http` do comando, e a UI
  não está na IR 0.1 (#28)
- [x] Regra para resolver as questões em aberto de um ADR aceito, que não é editado: um ADR de resolução, com cinco
  tratamentos (decidida, medição, valor inicial, já resolvida, adiada), uma linha de cabeçalho no ADR original e
  uma tabela no índice (#29)
- [x] ADR-022 resolveu as seis questões em aberto do ADR-003: poolers e `pg` sob o Falcon viraram medições com
  critério (o Falcon já tem resultado preliminar: quatro requisições simultâneas de 1 s em 1,05 s, contra 4,02 s do
  controle); os registros são um `Data` por entidade, congelado em profundidade; `uses :sql` fica fora da fase 1; o
  analisador passa a recusar `Sequel`, `ActiveRecord` e `PG` num `call`, que hoje o compilador aceita (#30)
- [x] ADR-023 resolveu as cinco questões em aberto do ADR-005: o custo do contexto assinado é uma medição com
  limiar (preliminar: cerca de 0,2 ms por instrução sobre o RLS ingênuo, por instrução e não por linha); a política
  de escopo por vínculo passa a amarrar tenant e ator como condições não correlacionadas na subconsulta, porque a
  forma correlacionada fez `Seq Scan` na tabela de vínculos a cada instrução (16,7 a 19,7 ms com 200 mil vínculos,
  contra 2,05 a 2,23 ms com o tenant amarrado); relatórios entre tenants ficam adiados; SSO e a versão mínima do
  PostgreSQL já estavam resolvidos (#31)
- [x] ADR-024 resolveu as seis questões em aberto do ADR-014: os padrões viraram valores iniciais (10 tentativas,
  espera de 10 s dobrando até 30 min, cerca de 72 min até `dead`, timeout de 30 s e lease de 60 s); a outbox e as
  entregas são particionadas por tempo, nunca por tenant, com purga por `DETACH` e `DROP` (medido: 23 ms contra 344
  ms de `DELETE` para um dia de 100 mil linhas) e as entregas `dead` fora das partições; o ator de sistema de um
  handler é autorizado pela lista `calls`, com a claim `system_actor` e a condição `is_system_actor()` nas
  políticas de escopo; uma mudança incompatível de evento é um evento novo emitido junto com o antigo; publicar
  para fora é um handler com capacidade externa (#32)
- [x] ADR-025 resolveu as seis questões em aberto do ADR-015: o `db:plan` planeja contra o retrato commitado
  `db/schema.sql` (a CI aplica os planos num PostgreSQL descartável para conferi-lo) e o `db:migrate` verifica o
  alvo por introspecção; no PostgreSQL 16.15 o `CREATE INDEX CONCURRENTLY` não vale em tabela particionada e o
  `ADD FOREIGN KEY ... NOT VALID` é recusado nela (o que abre uma lacuna no padrão do ADR-015, §4, resolvida com
  índice por partição e chave por partição); a chave composta por tenant custa o mesmo que a simples na validação,
  e o custo extra é o índice único de apoio; a fase contract só roda com a prova de batimentos em `vetra.instances`;
  um `enum` é `text` com `CHECK`, não o tipo nativo (#33)
- [x] As questões em aberto dos ADRs 003, 005, 014 e 015, que o índice pedia tratar antes da persistência, estão
  tratadas (ADR-022 a 025) (#33)
- [x] O compilador passou a aplicar duas decisões já aceitas (primeiro código depois dos ADRs de resolução): o
  analisador recusa `Sequel`, `ActiveRecord` e `PG` num `call` como efeito direto, liberável por `unsafe_effect`
  (ADR-022, §6), e o `graph:diff` trata a lista `calls` de um handler como `permissions` (ADR-024, §4). Três
  testes novos (#34)
- [x] `docs/situacao-do-projeto.md` (#17)

Os PRs #1 a #5 reúnem a análise e as correções iniciais, a verificação do Sequel e do `pg` contra um PostgreSQL
real, o escopo por vínculo, as sondas no PostgreSQL 17 e 18 e no PgBouncer, e os três pontos da revisão externa
(troca atômica de política RLS, `memberships` e o gate da CI).

## 2. ADRs

A rodada é a da [lista de revisão](adr/revisao-de-aceite.md).

**Aceitos**
- [x] **001** Grafo da Aplicação e IR (rodada 1, #12)
- [x] **002** Somente PostgreSQL (rodada 1, #12)
- [x] **003** Sequel e camada fina de repositórios (rodada 2, #14)
- [x] **004** Capacidades e Effect Boundary (rodada 2, #16)
- [x] **005** RLS e contexto assinado (rodada 2, #14)
- [x] **006** Isolamento de domínios em três níveis (rodada 2, #14)
- [x] **007** Comando e adaptadores (rodada 2, #18)
- [x] **008** Ordem e continuidade dos eventos (rodada 2, #14)
- [x] **009** Workflows por histórico e replay (rodada 4, #26)
- [x] **010** Adoção hospedada e modo serviço (rodada 3, #20)
- [x] **011** MCP com identidade delegada (rodada 3, #27)
- [x] **012** Canário em modo sombra (rodada 3, #25)
- [x] **013** Privacidade, auditoria e histórico (rodada 3, #21)
- [x] **014** Outbox com entrega pelo menos uma vez (rodada 3, #22)
- [x] **015** Migrações expand/contract (rodada 2, #14)
- [x] **016** Ciclo de vida da operação (rodada 1, #12)
- [x] **017** Tipo `money` (rodada 2, #19)
- [x] **018** Camada de UI em módulos (rodada 3, #28)
- [x] **019** Sinais efêmeros (rodada 4, #24)
- [x] **020** Entrega live incremental (rodada 3, #15)
- [x] **021** Campos de transição (rodada 3, #23)

**ADRs de resolução** (questões em aberto de um ADR aceito, pela regra do índice)
- [x] **022** Resolução das questões em aberto do ADR-003 (#30)
- [x] **023** Resolução das questões em aberto do ADR-005 (#31)
- [x] **024** Resolução das questões em aberto do ADR-014 (#32)
- [x] **025** Resolução das questões em aberto do ADR-015 (#33)

**Aceitos nesta revisão**
- [x] **026** Tabela de expoentes ISO 4217 no compilador: resolve a origem da tabela do ADR-017 e adia a escolha
  da biblioteca de formatação até a implementação da borda de UI/API. Implementação integrada; aceite
  registrado em 2026-11-02 por solicitação do mantenedor
- [x] **027** `created_at` implícito e IR 0.2: geração pelo relógio do futuro repositório, exclusão das
  entradas CRUD e compatibilidade com artefatos 0.1. Implementação integrada; aceite registrado em
  2026-11-02 por solicitação do mantenedor

- [x] **028** Contratos compostos e coleções de consultas: IR 0.3, referência a contratos de registros,
  classificação pessoal derivada e preservação dos schemas anteriores; integrado em `cb7c0b5`
- [x] **029** Declarações live e dependências verificáveis, incluindo leituras de autorização; integrado
  em `ed0d90f`, sem runtime de assinaturas

## 3. Decisões e trabalho que dependem de quem revisa

- [ ] Decidir se o ADR-020 ganha uma sonda (trigger de linha, releitura por grupo)
- [ ] Decidir se a `sonda_adr015` ganha os quatro casos do ADR-025 (índice e chave em tabela particionada, chave
  composta por tenant, `CHECK` de `enum`), com CI no PostgreSQL 17 e 18
- [ ] Decidir quais das questões em aberto dos demais ADRs aceitos merecem um ADR de resolução agora. Nenhuma
  bloqueia a persistência; o ADR-009 tem a do ator de sistema de um workflow, que o ADR-024 já responde em regra

## 4. Fase 0: critérios do ADR-001

Detalhe e evidência em [fase-0-criterios.md](fase-0-criterios.md).

- [x] **1** Schema válido, exemplos com e sem tenant, falhas estruturais
- [x] **2** Cada regra semântica tem um caso que a dispara
- [x] **3** Mesmo resultado entre checkouts, descoberta embaralhada, vetores Unicode
- [x] **4** O hash reproduz o valor; mudanças invalidam o build
- [x] **5** Versão suportada, MENOR ou MAIOR futura, recurso não implementado
- [ ] **6** Produção recusa IR ausente, adulterada ou incompatível. Parcial: não há servidor de produção
- [ ] **7** Contratos CRUD, políticas e transições equivalem aos três exemplos da proposta. Parcial por desenho: o
  DSL recusa 4 construtos de 14 no blog, 4 de 6 no mini CRM e 4 de 9 no chat
- [x] **8** Mesma IR gera saídas idênticas; `graph:check` detecta edição e desatualização
- [x] **9** O diff distingue remoção, renomeação, capacidade nova, permissão e só origem
- [x] **10** Registro congelado, implementação ausente ou duplicada, recarga como unidade. Coberto, com uma
  limitação de desenho mantida por decisão: o `binding` não guarda o digest da implementação, que fica na IR
- [x] **11** Compartilhamento real dos dados imutáveis entre Ractors, sem transportar closures, e núcleo
  funcional sem a constante pública `Ractor` (`ractor_test.rb`; não implementa executor concorrente)

## 5. Ainda não implementado

**No DSL** (falham de forma audível, não viram anotação)
- [ ] `auth` e a geração de usuários e vínculos
- [ ] `ui`, MCP e workflows
- [ ] Configuração `realtime` (a declaração `live` já é compilada e validada)
- [ ] `rate_limit:` em `can` e `rounding:` em `currency`
- [ ] Moeda por tenant (a conferência do `scale` contra a moeda da aplicação já está implementada)
- [ ] O titular (`subject`) e a retenção (`retention`) de dado pessoal
- [ ] Consulta sem `returns` e sem `authorize`: os exemplos da proposta as omitem, e o compilador exige as duas
- [ ] SQL explícito e metadados de dependência por gem
- [ ] Políticas por atributo do ator além de `id`

**Nos exemplos**
- [ ] Geração automática dos comandos de vínculo de `many_to_many`: o chat já declara `add_member` e
  `remove_member` explicitamente; a geração prevista no PDF não existe

**Runtime**
- [ ] Execução das primitivas CRUD e dos comandos (hoje são descritores reconhecidos, sem executor)
- [ ] Adaptadores HTTP, CLI, job e webhook em execução, incluindo resolução do ator/tenant e deduplicação;
  as exposições e a exigência de idempotência já são compiladas e validadas
- [ ] Persistência e o Vetra Data
- [ ] Modo hospedado em Rails: adaptador Rack, resolvedor do ator e pontes somente leitura para models do Rails
- [ ] Privacy, Audit e History em execução: criptografia por envelope, KMS, eliminação e exportação
- [ ] Sinais efêmeros em execução: "digitando", presença por lease e a limitação de taxa
- [ ] Modo sombra em execução: simulador determinístico, repositório simulado e relatório de divergências
- [ ] Workflows duráveis em execução: histórico, replay, temporizadores, sinais e versões
- [ ] MCP em execução: adaptador, delegações, aprovações, limite de taxa e o piso de sensibilidade no compilador
- [ ] Camada de UI em execução: módulos, páginas, formulários por contrato, ejeção, cabeçalho de linha de base e
  `vetra doctor`
- [ ] Servidor de produção e cache de compilação
- [ ] RLS, entrega de eventos e consultas live em execução. As garantias dos ADRs aceitos valem como decisão, não
  como código

## 6. Lacunas de evidência e limites conhecidos

- [ ] **ADR-008:** a sonda de intervalos e `_v` já existe e entra na CI do PostgreSQL 17 e 18. O distribuidor,
  checkpoints persistidos, retenção e ressincronização por mudança de cluster/timeline continuam pendentes.
  As sessões da sonda não exercitam múltiplos processos de aplicação, carga ou transações preparadas
- [ ] **ADR-020:** sem sonda; a declaração e as dependências de live já são compiladas pelo ADR-029, mas
  os 12 critérios de entrega ainda dependem do runtime
- [ ] **ADR-004:** o protótipo cobre os testes de aceitação 2 e 3. Os outros seis dependem do runtime, e o erro de
  `uses` inexistente não foi conferido
- [ ] **ADR-009:** o motor de workflows, o histórico e a sintaxe não existem, e o schema 0.1 não representa
  workflows. A `sonda_adr009` verifica o replay em Fiber (sem escalonador), o código alterado e a Fiber não
  serializável, e mede o `TracePoint`. O contrato de cancelamento, sinais concorrentes e compensação ainda não
  está especificado; ramos concorrentes exigem um escalonador determinístico e um ADR novo
- [ ] **ADR-011:** a IR 0.1 não representa a exposição MCP (o `surface` aceita `http`, `cli`, `job` e `webhook`;
  é preciso uma nova MENOR com `vetra.mcp`) e o DSL aceita as quatro superfícies, sem MCP. As delegações, as aprovações, o
  adaptador, o limite de taxa e o piso de sensibilidade não existem. O `FOR SHARE` da revogação tem a
  `sonda_adr011` (5 itens, rodando na CI no 17 e no 18). O piso cobre só o que a IR enxerga, porque o `call` não é
  registrado; as recusas das etapas 1 a 3 ficam no log, não no Audit
- [ ] **ADR-018:** os módulos de UI, o DSL (`ui :server`, `page`, `crud ui:` e `expose ui:` falham no protótipo), a
  representação na IR (nova MENOR com `vetra.ui`), o `vetra doctor` e `vetra ui:resync` não existem; a CLI só tem
  `graph:*`. O ERB da biblioteca padrão (4.0.3) não escapa a saída, conferido à mão, sem sonda versionada: o motor
  precisa ser outro ou configurado para isso. Como o `can?` é avaliado e o mecanismo do token anti-CSRF estão em
  aberto. A garantia de que a tela não ultrapassa a autorização vale para o código que usa o runtime; uma página
  com conexão própria escapa
- [ ] **ADR-012:** o simulador, o repositório simulado e o cálculo de elegibilidade não existem; o grafo só traz o
  campo `simulation` das capacidades. O comportamento do instantâneo exportado (a sombra parte do estado anterior
  à escrita da produção; importar depois que a produção terminou falha) foi conferido à mão no PostgreSQL 16.15,
  sem sonda versionada. A fração de amostras úteis depende de a sombra importar o instantâneo antes do commit da
  produção, e precisa ser medida
- [ ] **ADR-019:** o protótipo não tem sinais efêmeros nem presença. A sonda mede o limite do `NOTIFY`, a entrega
  só no commit, as notificações idênticas, o `LISTEN` por sessão e o WAL da tabela `UNLOGGED`; a autorização, o
  heartbeat, a limitação de taxa e o comportamento num crash ou failover não têm sonda versionada
- [ ] **ADR-021:** o protótipo representa `set_by`, `guarded` e `transitions enforce:`, omite os campos e valores
  protegidos do contrato do CRUD, recusa a gravação literal por um comando fora da lista (`transition_owner`) e o
  valor protegido como `default:` (`guard_default`). A verificação na etapa 6, as telas administrativas, o trigger
  e o histórico dependem do runtime, e a sintaxe de UI pertence ao ADR-018
- [ ] **ADR-014:** o protótipo recusa um handler que escreve por repositório e um evento interno sem consumidor,
  mas o relay, as entregas, o lease e a reentrega não existem. O tratamento do ator de sistema já foi decidido
  no ADR-024, §4, e ainda não foi implementado; a IR 0.1 não representa um papel de sistema
- [ ] **ADR-013:** o protótipo cobre só a classificação `privacy`, a validação do payload dos eventos e o diff de
  privacidade (teste de aceitação 2). Nada do envelope, do KMS, do histórico ou da auditoria existe. Declarar o
  titular e a retenção exige uma nova MENOR da IR, porque `privacy` é fechado
- [ ] **ADR-010:** o modo hospedado com o Active Record não foi exercitado, e nenhuma sonda mede a gem
  `sequel-activerecord_connection`. A transação e o contexto de RLS compartilhados e os cinco testes do ADR-003 são
  hipótese até rodarem contra um Rails real. O protótipo não tem ponte com Rails
- [ ] **ADR-017:** a escala por moeda da aplicação e a precisão estendida estão implementadas e testadas em
  `635d926`, com tabela local de expoentes (SIX, publicação de 2026-09-17; fonte definida no ADR-026). A
  aritmética, o rateio, o arredondamento, a formatação e a validação HTTP ainda dependem do runtime; a moeda por
  tenant exige uma nova MENOR da IR
- [ ] **ADR-007:** as quatro superfícies são declaradas no DSL e validadas na IR 0.1. O teste de aceitação 6
  cobre comando por GET e consulta por POST. Nomes únicos por superfície, colisões entre HTTP e webhook,
  idempotência obrigatória de webhook e vínculo único ao comando estão cobertos em `exposure_test.rb`.
  Os adaptadores, a tradução da entrada/saída, a transação comum e a idempotência em execução continuam
  dependentes do runtime
- [ ] **Sondas manuais:** `sonda_pooler` (precisa de PgBouncer) e `sonda_adr006` (precisa de `RUBY_BOX=1`) não rodam
  na CI. Parte da evidência dos ADRs 003, 005, 006 e 008 vem delas
- [ ] **PostgreSQL 19:** entra na matriz da CI quando existir uma imagem
- [ ] **Persistência:** as questões em aberto dos ADRs 003, 005, 014 e 015 estão tratadas por ADRs de resolução
  (022 a 025), mas os valores iniciais e as medições que eles registram estão por fazer, e nada da persistência
  existe (veja os itens ADR-022 a ADR-025 abaixo)
- [ ] **ADR-022:** as medições pendentes são a `sonda_pooler` contra o pooler da aplicação, o `pg` sob o Falcon em
  Ruby 4.0.9 com o adaptador Rack (hoje só medido em Ruby 3.3.6) e o custo dos registros no repositório real. O
  analisador do compilador já recusa `Sequel`, `ActiveRecord` e `PG` num `call` (#34), mas a regra sobre
  interpolação em `uses :sql` espera a capacidade `uses :sql`, que não existe
- [ ] **ADR-023:** o custo do contexto assinado foi medido só num protótipo descartável, no PostgreSQL 16.15, com um
  cliente e sem `WITH CHECK`, comparação em tempo constante, concorrência nem pooler; o gate da fase 1 (0,5 ms por
  instrução e 25% da latência do comando, hipóteses) está por medir no 17 e no 18. O gerador de políticas não
  existe, então a forma da política de escopo e o aviso do `db:plan` sobre o índice da tabela de vínculo ainda não
  estão implementados. A autenticação (como a credencial escolhe a empresa) não tem ADR
- [ ] **ADR-024:** a partição foi medida só no PostgreSQL 16.15, com carga sintética, um cliente, sem escrita
  concorrente nem `VACUUM`; o gate na matriz do G4 está por medir. Nada foi implementado: a outbox e as entregas
  particionadas, `vetra.dead_deliveries`, a claim `system_actor`, a função `is_system_actor()` e a condição nas
  políticas de escopo não existem. O `graph:diff` já classifica `calls` de um handler como `permissions` (#34), mas
  o compilador não avisa sobre o timeout do handler. O DSL só declara `handler` com `calls`, e a IR 0.1 não tem
  timeout nem papel por handler
- [ ] **ADR-025:** conferido só no PostgreSQL 16.15, à mão: índice e chaves em tabela particionada, a chave composta
  por tenant em 1 milhão de linhas e as limitações do `enum` nativo. O comportamento do `NOT VALID` em tabela
  particionada no 17 e no 18, o custo na escrita do índice de apoio da chave composta e que uma partição nova herda
  o índice do pai estão por medir. O desenho do contract (`vetra.instances`, `vetra.schema_state`, `plan_seq`) não
  tem protótipo, e nada do `db:plan`, do retrato `db/schema.sql` e do mapa de `enum` para `text` com `CHECK`
  existe
- [ ] **ADR-020:** como o trigger de instrução da revisão de autorização obtém o tenant em escritas sem contexto,
  como o preenchimento do `vetra_migrator`; custo da releitura de campos pessoais por grupo

Limite documentado, sem ação prevista: os hashes não autenticam o pacote.

## 7. Próximos passos propostos

Ordem sugerida; cada passo é um ou mais commits na `main`, e o aceite só vale quando o mantenedor o integra.

1. [ ] Fechar as lacunas declarativas da fase 0 e os critérios 6 e 7, com os exemplos da proposta. A escala
   por moeda de `money`, as exposições do ADR-007 e os comandos explícitos de membros do chat, incluindo
   inclusão por e-mail, estão implementados, assim como o `created_at` implícito na IR 0.2. Os demais itens
   seguem pendentes nas seções 4 e 5. As consultas do chat já têm coleções e contratos compostos na IR 0.3.
   No chat, `room_page` também declara live com dependências verificadas. Faltam a geração automática dos
   comandos de vínculo, expansões de membros/autores, entrega live, autenticação, UI e realtime
2. [ ] Começar a persistência (o Vetra Data): os pré-requisitos de ADR estão tratados. É código e testes, e só
   começa quando quem revisa pedir

# Situação do projeto

Este arquivo reúne, num só lugar, o que já foi feito, o que espera uma decisão e o que ainda não existe. Ele não
substitui o [índice de ADRs](adr/README.md), a [lista de revisão](adr/revisao-de-aceite.md) nem a
[cobertura dos critérios da fase 0](fase-0-criterios.md): resume os três e aponta para eles.

- **Atualizado em:** 2026-11-11: o `Runner` fecha as oito etapas (K19, [ADR-047 proposto](adr/047-fechamento-transacional-do-runner.md)): grava os eventos do
  `emits` na etapa 7, liga a chave de idempotência às etapas 4 e 7 (com a repetição do resultado em JSON), devolve um `Outcome` com o status do ADR-016 (422, 403, 404,
  409, 500) e repete por serialização e deadlock só quando a operação é segura; auditada pelo Codex em cinco rodadas. O `Runner` autoriza cada acesso dos repositórios e o estado final, e o ator de sistema é admitido pelos
  `calls` do handler (K18, [ADR-046 proposto](adr/046-autorizacao-dos-acessos-e-estado-final.md)); auditada pelo Codex em quatro rodadas. O avaliador Ruby percorre `many_to_many` na C16 (dono → junção → alvo, com tenant a cada salto), o que
  torna executáveis as três políticas `members` do chat; a borda interna e o `Runner` das etapas 1 a 5 e 8 estão implementados na K17
  ([ADR-045 proposto](adr/045-borda-interna-e-runner.md)): contrato de identidade, fatos e autoridade de revisão, com
  implementações de referência (marcador composto nos CRMs, geração em processo em blog e chat), primitivas CRUD e de vínculo e
  as duas contagens de transações; auditada pelo Codex em três rodadas. 2026-11-10: os limites da unidade estão implementados na C15 (`statement_timeout`, `lock_timeout` e
  isolamento por operação, verificador dos limites de sessão que protegem o `xmin` e erros retentáveis próprios; o
  `vetra_app` passa a exigir `transaction_timeout` e `idle_in_transaction_session_timeout` no bootstrap). Entrada e autorização em Ruby estão implementadas na C13
  ([ADR-044 proposto](adr/044-entrada-e-autorizacao-em-ruby.md)): contratos estritos com `Values`, papéis,
  escopo por vínculo, registro referenciado e campos, sem abrir unidade, com fatos e revisão resolvidos pela
  borda confiável. `uses` não concede leitura implícita; limite de taxa sem contadores e contexto de sistema
  recebem recusa explícita. Sonda de concordância Ruby/RLS executada no PostgreSQL 17 e 18 (68/68). A integração no despacho e nos acessos é da K17/K18. A operação tem o registro de idempotência (K16, [ADR-043](adr/043-registro-de-idempotencia-da-operacao.md), aceito):
  tabela `vetra.idempotency`, API e purga, ainda sem o executor. O contexto assinado tem o ator de sistema de um handler (K15, ADR-024, §4), com custo que pede decisão
  do mantenedor. O compilador recusa campos e predicados de grupos de enum que colidem com
  métodos do registro `Data` (C12), com diagnóstico próprio e reserva compartilhada com os repositórios.
  A construção dos registros tem conversão imediata de leitura (C11,
  [ADR-042 proposto](adr/042-construcao-dos-registros.md)), com entrada estrita preservada; o gate de 10% continua
  aberto: a construção caiu de 136%-167% para 40%-56% da consulta no PostgreSQL 17 e 18, e a decisão do orçamento é do mantenedor. A política de escopo
  por vínculo usa a forma lista (K14, ADR-041). O [Vetra Data](vetra-data.md) tem unidade de trabalho, emissor Ruby e repositórios
  gerados da IR, com registros `Data` imutáveis, consulta restrita, transições protegidas e vínculos idempotentes.
  A outbox tem armazenamento e emissão (K11, ADR-040 aceito): blog, mini CRM e CRM com revendas ganham o plano
  `0002_expand`, com a outbox e as entregas particionadas por tempo, e o comando grava o evento na unidade de
  trabalho. O relay materializa e entrega os eventos a consumidores simulados, com lease, tentativas e entrega
  morta, e a manutenção cria, recupera e purga as partições (K12, no `0003_expand`). Planos incrementais aditivos e
  `db:migrate` com retomada estão implementados. A medição preliminar do custo do contexto (K13) fecha a rodada 4:
  o contexto assinado fica abaixo do limiar na maior parte das rodadas, e a política de escopo e a construção dos
  registros ficam acima, o que leva a ADRs novos. O executor parcial está implementado; o runner dos handlers tem implementação
  na C14, com [ADR-048 proposto](adr/048-execucao-dos-handlers-de-sistema.md), auditado pelo Claude, com a sonda em 12/12 no 17 e no 18. A IR permanece 0.6; o chat conserva
  seus artefatos.
- **Legenda:** `[x]` feito ou confirmado; `[ ]` pendente, incompleto ou não implementado. Cada pendência diz de
  quem é a decisão. "Quem revisa" é o mantenedor, que integra na `main`.

## Resumo

| Item | Situação |
|---|---|
| ADRs | 42 aceitos (001 a 041 e 043) e seis propostos (042, 044, 045, 046, 047 e 048), com o índice em [adr/README.md](adr/README.md); construção dos registros usa conversão imediata, com o gate de custo aberto |
| Testes do compilador, dados e exemplos | 808 testes e 17.476 asserções, sem falhas; 259/259 códigos de diagnóstico exercitados, com verificação automática na tarefa da CI |
| Entrada e autorização Ruby (C13) | 27 testes/760 asserções novos sem banco, com os quatro grafos e os caminhos da sonda por mock. Contratos estritos, lógica SQL de NULL, papéis, vínculo/revenda/tenant, campos, revisão e recusas específicas. Quatro exemplos em check, validação com fontes e link; quatro planos sem mudanças e gate sem diferenças. Sonda em modo 100755, executada no 17.11 e no 18.6 (68/68) e na CI; a contagem de zero transações é a do pool do runtime. Integrada em `8a224a1`, com a CI verde ([execução 42859941056](https://github.com/vetra-framework/vetra/actions/runs/42859941056)). |
| Limites da unidade (C15) | 13 testes novos sem banco e a sonda `sonda_limites_unidade.rb`, em modo 100755, com 15 verificações no 17.11 e no 18.6 (verificador recusa 5 combinações e aceita o login real, estouros de `lock_timeout` e `statement_timeout` com rollback total e sem evento, `SERIALIZABLE`/40001, morte do backend por `transaction_timeout` e por transação ociosa com o `xmin` avançando e o relay entregando, restauração dos parâmetros por banco). As sondas `vetra_data` (23), `repositorios` (72), `outbox` (36), `relay` (38), `idempotencia` (83) e `autorizacao_ruby` (68) passam nos dois servidores com o novo bootstrap. Custo medido do verificador: 0,18 ms/op no 17 e 0,11 ms/op no 18 (mediana de 300 leituras), e não os 57 µs do mock. Quatro exemplos em check, validação com fontes e link, `db:plan` sem mudanças e gate sem diferenças. Integrada em `a5b339d`, com a CI verde ([execução 42893712044](https://github.com/vetra-framework/vetra/actions/runs/42893712044)). |
| Borda interna e Runner (K17) | 26 testes novos sem banco (dois bancos simulados, o da operação e o da borda) e um do linker, mais a sonda `sonda_runner.rb`, em modo 100755, com 26 verificações no 17.11 e no 18.6: um comando de cada exemplo pelo `Runner` em dois pools de `vetra_app`, as duas contagens de transações (zero na operação nas recusas, a da borda não é zero), `Failure` desfeita, invalidação depois do commit, revogação durante a admissão e autoridade fora do ar, mais a ordem commit/publicação e o desfazer de uma escrita antes do `fail!`. Quatro exemplos em check, validação com fontes e link; a IR não muda. Integrada em `074c75c`, com a CI verde ([execução 43023877656](https://github.com/vetra-framework/vetra/actions/runs/43023877656)). |
| `many_to_many` no avaliador (C16) | 10 testes novos (6 em `execution_authorization_test.rb` e 4 no `Runner`; um removido, a recusa antiga) com as políticas reais do chat (membro, não membro, dono, outra sala, tenant a cada salto, chave composta, NULL, percursos com mais de um salto) e a sonda `sonda_autorizacao_chat.rb`, em modo 100755, com 30 verificações no 17.11 e no 18.6 contra o EXISTS equivalente escrito à mão em SQL; a sonda do Runner passa a 27. Quatro exemplos em check, validação com fontes e link; a IR não muda. Integrada em `8fb069f`, com a CI verde ([execução 43035403713](https://github.com/vetra-framework/vetra/actions/runs/43035403713)). |
| Autorização dos acessos (K18) | 30 testes novos sem banco (26 com bancos simulados que respondem por tabela, e 4 na autorização) e a sonda `sonda_acessos.rb`, em modo 100755, com 21 verificações no 17.11 e no 18.6: no chat (sem RLS), o filtro de `my_rooms`, a recusa de `add_member_by_email` no corpo, `add_member` e `remove_member` mudando o que o membro novo lê; no blog (sem RLS), a troca de autor recusada no estado final e desfeita; no CRM com revendas (RLS), a troca de revenda recusada e desfeita, o isolamento de tenant e o ator de sistema pelos `calls`. Quatro exemplos em check, validação com fontes e link; a IR não muda. Integrada em `6304b3f`, com a CI verde na segunda tentativa ([execução 43053053477](https://github.com/vetra-framework/vetra/actions/runs/43053053477); a primeira falhou numa sonda sem relação com a K18, veja o quadro). |
| Fechamento do Runner (K19) | 26 testes novos sem banco (bancos simulados que respondem por tabela: evento na etapa 7, claim, replay, chave reutilizada, cada status, repetição por serialização e deadlock, recusa de repetir) e a sonda `sonda_fechamento.rb`, em modo 100755, com 13 verificações no 17.11 e no 18.6, com duas transações concorrentes reais (serialização e deadlock repetidos com sucesso e sem evento duplicado; `unsafe_effect` sem repetir). Quatro exemplos em check, validação com fontes e link; a IR não muda. Integrada em `ba60d88`, com a CI verde ([execução 43090719902](https://github.com/vetra-framework/vetra/actions/runs/43090719902)). |
| Handlers de sistema (C14) | 14 testes novos sem banco (relay simulado com lease e bancos simulados: dois handlers com chaves distintas e a mesma chave no provedor, queda depois do commit com replay sem nova escrita nem emissão, ocorrências estáveis, comando fora de `calls`, saída pessoal como falha permanente, timeout total com recuperação por outro worker e durante o COMMIT, tenant do evento, retenção da chave em `pending`, `done` e `dead`) e a sonda `sonda_handlers.rb`, em modo 100755, com 12 verificações no 17.11 e no 18.6, com o relay real, SIGKILL do worker entre o commit e o `complete`, retenção e purga pelo `vetra_relay` e o timeout total. Quatro exemplos em check, validação com fontes e link; a IR não muda. Integrada em `0627646`; a execução da CI desse commit ficou presa em `queued` no GitHub, e a CI verde é a do commit de registro seguinte ([execução 43152061333](https://github.com/vetra-framework/vetra/actions/runs/43152061333)). |
| Colisões de nomes no compilador (C12) | Dez testes/970 asserções na execução isolada: campos e predicados de enum, diagnóstico com ponteiro e origem, ganchos privados recusados, funções privadas do `Kernel` aceitas com construção, leitura e `with`, preservação do artefato e concordância com os repositórios, inclusive com métodos e mudanças de visibilidade após o carregamento. Quatro exemplos em check, validação com fontes e link, quatro planos sem mudanças e gate sem diferenças; IR 0.6 preservada |
| Construção dos registros (C11) | Nove testes/1.735 asserções novos sem banco, incluindo a medição da sonda com Sequel.mock. Quatro exemplos em check, validação com fontes e link; quatro planos sem mudanças; gate contra origin/main sem diferenças. Sonda em modo 100755, executada no 17.11 e no 18.6 (5/5); construção de 40% a 56% da consulta, gate aberto e decisão do orçamento pendente |
| Critérios da fase 0 (ADR-001) | 9 cobertos e 2 parciais (6 e 7); o 11 cobre os dados do compilador |
| CI registrada | Três checks verdes no push direto de `ebed54a`, incluindo a sonda ADR-020 no PostgreSQL 17 e 18 ([execução 41641228179](https://github.com/vetra-framework/vetra/actions/runs/41641228179)) |
| Verificação local da C5 | 35 testes de esquema e 311 asserções; 11 diagnósticos próprios cobertos. Quatro fixtures SQL integrais e grafos em check, validação com fontes e link (52, 36, 49 e 64 nós). Gate contra `origin/main` (`cc013b7`): zero mudanças nos quatro grafos. `git diff --check` passa; nenhum script mudou de modo. Aplicação conferida na auditoria da C5/K7 (detalhes abaixo). |
| Verificação da C6 | Planos com 33 passos no blog e no mini CRM, 49 no chat e 59 no mini CRM com revendas. No PostgreSQL 18.6: bootstrap repetível, sonda do contexto assinado 58/58 com o plano aplicado pelo `vetra_migrator` sem superusuário, sonda ADR-031 59/59, retratos com donos e `--check` nos quatro exemplos |
| Entrega da C7 | Planos com 33 passos no blog, 49 no chat, 90 no mini CRM e 179 no CRM com revendas; espelhos em db/policies conferidos sem banco. Sonda de RLS e integridade 103/103 no PostgreSQL 18.6, no job db-plan da CI no 17 e 18; retratos regenerados pelo Claude |
| Verificação da C9 | 32 testes novos; oito diagnósticos novos cobertos. Suíte completa: 543 testes/8.819 asserções, sem falhas. Quatro exemplos em check, validação com fontes e link; quatro planos sem mudanças. Gate contra `origin/main` (`219236c`): zero diferenças nos quatro grafos. Sonda aditiva com sintaxe conferida e modo 100755; execução no 17/18 e inclusão na CI pendentes da auditoria |
| Repositórios do Vetra Data | 35 testes/865 asserções sem banco: geração e leitura dos `Data` das 13 entidades dos quatro exemplos, CRUD, locks, consulta restrita, vínculos, recusas e dez corpos Ruby de comandos/consultas. Suíte completa: 583 testes/9.792 asserções, 216/216 diagnósticos. Quatro exemplos em check, validação com fontes e link; quatro planos sem mudanças. Gate contra `origin/main` (`047e03d`): zero diferenças nos grafos. Sonda 72/72 no PostgreSQL 18.6 e no 17 e 18 da CI ([execução 42282609424](https://github.com/vetra-framework/vetra/actions/runs/42282609424)), modo 100755; integrada em `5c15ebf`; os resultados estão no guia. Campos que colidem com métodos do registro são recusados (`data_record_type`). Sem alteração de banco ou dependências |
| PRs e commits | #1 a #36 integrados; depois, commits diretos na `main`: IR 0.3 em `cb7c0b5`, live em `ed0d90f`, sondas 008 e 020 em `0beb473` e `ebed54a`, gerador SQL em `61efbb8`. Tarefas dos agentes em [tarefas-dos-agentes.md](tarefas-dos-agentes.md) |
| Sondas | 31 em `script/`, incluindo a dos handlers (12 verificações, no 17 e no 18), a do fechamento (13 verificações, no 17 e no 18), a dos acessos (21 verificações, no 17 e no 18), a de autorização do chat (30 verificações, no 17 e no 18), a do Runner (27) e a de autorização Ruby (68) e o simulador do gate; medição do custo do contexto ([relatório](sondas/custo-contexto.md)), relay (38), outbox (36), repositórios (72), `db:migrate` incremental (16), diferenças aditivas (99), Vetra Data (23), plano incremental (18), idempotência (83), contexto assinado (78), RLS/integridade (112) e `db:migrate` (21) no job de planos 17/18, além das sondas anteriores na CI |
| Runtime | Unidade de trabalho, emissor HMAC, repositórios gerados da IR, avaliador Ruby das etapas 2/3, borda de referência, `Runner` das oito etapas (K17 e K19, com eventos, idempotência, status e repetição) e a guarda dos acessos (K18) implementados, com carregamento explícito. A C14 liga o relay aos handlers e comandos com identidade de sistema, chaves de evento e timeout total; auditoria e sonda real pelo Claude pendentes. Histórico e auditoria das operações seguem na rodada 6 |

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

- [x] Handlers de sistema (C14, [ADR-048 proposto](adr/048-execucao-dos-handlers-de-sistema.md)): `Execution::HandlerRunner` reserva as entregas pelo `Relay`, monta a identidade de
  sistema do tenant do evento, roda o `call` do handler e o faz chamar os comandos de `calls` por `call_command`, pelo `Runner`, com a chave de idempotência derivada de handler,
  evento e ocorrência (origem `event`), a mesma chave no provedor externo e a retenção até a entrega sumir, inclusive `dead`; timeout total de 30 s com lease de 60 s,
  que desfaz a unidade aberta e preserva a lease. Reprocessamento de `dead`, histórico e cifra são da rodada 6.
- [x] Fechamento do Runner (K19, [ADR-047 proposto](adr/047-fechamento-transacional-do-runner.md)): eventos do `emits` na etapa 7, idempotência na unidade (claim na etapa 4,
  resultado na 7, repetição em JSON), `Outcome` com o status do ADR-016 e a indicação de resposta retentável, `run!` que levanta, e repetição por serialização e deadlock (até 3, com
  espera crescente) só sem `unsafe_effect` nem `retry_safe: false`. Os handlers rodam pela C14 (`HandlerRunner`); histórico e cifra são da rodada 6.
- [x] Autorização dos acessos (K18, [ADR-046 proposto](adr/046-autorizacao-dos-acessos-e-estado-final.md)): a `AccessGuard` que o `Runner`
  instala na unidade decide cada `find!`, `lock!`, `create!`, `update!`, `delete!`, vínculo e coleção por ação, registro e campos, com fatos
  lidos na própria transação; reautoriza o estado final antes do commit (`data_authorization_final`); `Authorization#decide` é a decisão
  única da admissão e dos acessos; consulta de coleção admitida pelo papel e filtrada por linha; o ator de sistema é admitido pelos `calls`
  do handler. O fechamento com eventos e idempotência é da K19; os handlers rodam pela C14.
- [x] `many_to_many` no avaliador (C16, emenda ao [ADR-044](adr/044-entrada-e-autorizacao-em-ruby.md)): `Predicate` percorre
  dono → junção → alvo pelas duas FKs, com tenant a cada salto e chave composta inteira; a junção e o alvo entram nos fatos
  (`traversed`, `fact_plan`, `policy_entities`) e na invalidação da geração em processo; omitir uma entidade do percurso recusa mesmo com
  um salto vazio. `chat.read_room`, `read_message` e `create_message` passam a ser decididos pelo avaliador.
- [x] Borda interna e `Runner` (K17, [ADR-045 proposto](adr/045-borda-interna-e-runner.md)) em `Vetra::Execution`: `Edge` com
  identidade, fatos e autoridade de revisão injetados; `DatabaseAuthority` (marcador `[revisão SQL, geração da identidade]`),
  `InProcessAuthority` (um processo, publicada depois do commit ou da falha) e `DatabaseFacts` (pool próprio da borda, limite de
  linhas); `Runner` das etapas 1 a 5 e 8 com `Outcome` para as recusas 1 a 3 e ganchos vazios para as etapas 6 e 7; primitivas CRUD e
  de vínculo; `LinkedGraph#run_implementation`; descritor `builtin` sem `executor: "pending"`. Sem eventos, idempotência nem
  autorização dos acessos (K18, K19).
- [x] Limites da unidade (C15, fase B da rodada 5): `UnitOfWork#transaction(statement_timeout:, lock_timeout:,
  isolation:)` com `set_config(..., true)` na transação externa (nunca em savepoint), tetos de 30 s e 10 s e máximo de
  120.000 ms, verificador `Limits` dos parâmetros de sessão do papel (`transaction_timeout`,
  `idle_in_transaction_session_timeout`, bootstrap operacional fora dos planos) e tradução única dos erros do banco
  (`Conflict(:lock_timeout)`, `StatementTimeout`, `SerializationFailure`, deadlock), que condenam a unidade e são
  retentáveis; sem repetição automática (K19). Sonda de 15 verificações no 17 e no 18 e na CI.
- [x] Entrada e autorização em Ruby (C13, [ADR-044 proposto](adr/044-entrada-e-autorizacao-em-ruby.md)) em
  `Vetra::Execution`: valida contratos com os tipos/erros de `Values`, avalia `authorize` por papel, tenant,
  vínculo, registro referenciado e campos e conserva a semântica SQL de NULL. Recebe fatos imutáveis e
  confirmação autoritativa da revisão da borda; fatos incompletos/obsoletos, predicados fora do subconjunto,
  dependência de `rate_limit:` e contexto de sistema recusam com diagnóstico próprio. `uses` não concede dados
  implicitamente. Modelos, planos, retratos e IR 0.6 preservados. A sonda de concordância com o RLS está em modo 100755, com 68 verificações, executada no 17 e no 18 e na CI; a
  contagem de "zero transações" é a do pool do runtime (o `pg_stat_database` foi descartado, por publicar com atraso). Provedor da borda e despacho são da K17; acessos, NEW e `calls` de sistema são da K18.
  Contratos aninhados existentes são validados nas saídas de consultas; a IR continua recusando entrada
  aninhada de comando. O aceite do ADR é do mantenedor.

- [x] Registro de idempotência da operação (K16, [ADR-043](adr/043-registro-de-idempotencia-da-operacao.md), aceito por delegação do
  mantenedor), em **toda** aplicação: a tabela `vetra.idempotency` tem chave única `UNIQUE NULLS NOT DISTINCT (tenant, comando, chave)`, que
  vale também no contexto global (blog e chat) sem tenant sentinela, o hash da entrada e o principal (a mesma chave com outra entrada ou
  outro principal é recusada da mesma forma, sem devolver o resultado), o resultado em JSON de até 64 KiB medido pelo banco sobre o `jsonb`
  normalizado, e a origem `adapter` ou `event` (só com outbox). A aplicação lê, grava a chave e só atualiza `result`, nunca apaga; o papel de
  manutenção `vetra_relay` purga (`Relay#purge_idempotency` e `vetra idempotency:purge`), com retenção de 24 horas para o adaptador e, para o
  evento, enquanto a entrega existir, inclusive a `dead`, a partir de um corte fixado uma vez no relógio do PostgreSQL. `Vetra::Data::Idempotency`
  reivindica na etapa 4 e conclui na 7, com o claim ligado à transação que o emitiu. O `Differ` cria a seção inteira num passo, e cada exemplo
  ganhou um plano (blog `0004`, chat `0002`, mini CRM `0005`, CRM com revendas `0006`). A sonda `sonda_idempotencia.rb` cobre repetição,
  rollback, concorrência real, `lock_timeout`, RLS, privilégios, limites e purga (83 verificações no 17 e no 18). O uso pelo executor é da K19
  e o custo da escrita no caminho quente, da K20. Integrada em `146128a`, com a CI verde
      ([execução 42849596612](https://github.com/vetra-framework/vetra/actions/runs/42849596612)).

- [x] Ator de sistema (K15, [ADR-024](adr/024-resolucao-das-questoes-do-adr-014.md), §4, decisões 2 e 3), só em aplicação com tenant: o
  contexto assinado leva `system_actor` (o identificador do handler) no lugar de `actor_id`, e o banco exige exatamente um dos dois.
  `vetra.current_actor()` devolve NULL para o ator de sistema, `vetra.is_system_actor()` (boolean, falso em qualquer falha) diz qual é,
  e as tabelas com escopo ganham a permissiva `vt_system` ao lado das políticas de escopo, com o isolamento de tenant ainda
  `RESTRICTIVE`: o ator de sistema alcança o tenant do evento inteiro, e não mais. O `Differ` passou a traduzir a troca das rotinas de
  contexto, e a guarda de rotinas reconhece as três definições exatas. O mini CRM ganha o plano `0004_expand` e o CRM com revendas, o
  `0005_expand`; blog e chat (globais) não mudam, byte a byte. `Context`, `ContextIssuer` e `UnitOfWork` aceitam `system_actor` só no escopo
  de tenant. As sondas de contexto (78) e de RLS (112) cobrem a adulteração do token e o alcance do ator de sistema. A medição de custo
  ([relatório](sondas/ator-de-sistema.md)) mostra que a `vt_system` encarece o ator comum, de +0,03 a +0,45 ms na leitura por chave e de
  +0,83 a +1,84 ms nas varreduras: a decisão entre manter assim, uma função única de contexto ou um papel de banco próprio é do mantenedor.
  A autorização do comando pelo `calls` do handler continua do executor (K18). Não cumpre o teste 6 do ADR-023. Integrada em `e84dc76`, com a CI verde
  ([execução 42831231168](https://github.com/vetra-framework/vetra/actions/runs/42831231168)).

- [x] Recusa de colisões de nomes no compilador (C12, ADR-022, §3): `graph:build` e `graph:check` emitem
  `field_name_collides_with_record` durante a normalização, com origem, ponteiro do campo ou grupo de enum
  e sugestão de renomear. A reserva de um `Data` vazio com `Record` cobre os métodos públicos e protegidos,
  os privados cujo dono não é `Kernel` e os ganchos privados do `Kernel` chamados pelo Ruby/Data no registro.
  As demais funções privadas do `Kernel`, como `format`, `open`, `select`, `test`, `system` e `load`, são
  aceitas como campos; a mesma regra vale para os predicados de enum. A reserva é compartilhada com a defesa
  `data_record_type` dos repositórios e consultada a cada checagem. Testes conferem as duas bordas,
  construção, leitura, `with` e mudanças de visibilidade após o carregamento. IR 0.6, modelos, grafos e
  planos dos quatro exemplos preservados. Integrada em `35d4a99`, com a CI verde
  ([execução 42817593744](https://github.com/vetra-framework/vetra/actions/runs/42817593744)).

- [x] Conversão imediata de leitura dos registros (C11, [ADR-042 proposto](adr/042-construcao-dos-registros.md)),
  separada da validação estrita da entrada: monta `Money`, JSON e UTC, mantém a faixa de datas e o congelamento
  profundo e evita a segunda cópia dos valores. O mesmo `Data` conserva igualdade, inspeção, `to_h`, `with`,
  predicados e compartilhamento entre Ractors. Medição Ruby compara a C10, o novo leitor, a construção sob demanda
  com leitura integral e o piso de alocação; os resultados fundamentam a escolha no ADR. A sonda de custo mede a
  construção sobre as linhas da consulta e mantém o limiar vigente de 10%. O gate não está cumprido: no
  PostgreSQL 17.11 e 18.6 a construção custa de 7 a 10 µs por registro, de 40% a 56% da consulta (antes, de 136% a 167%).
  Aceite e decisão do orçamento pelo mantenedor pendentes. Banco, planos, modelos,
  retratos e IR 0.6 preservados. Integrada em `c204ae1`, com a CI verde
  ([execução 42759473001](https://github.com/vetra-framework/vetra/actions/runs/42759473001)).

- [x] Forma da política de escopo por vínculo (K14, [ADR-041](adr/041-forma-da-politica-de-escopo.md), aceito por
  delegação do mantenedor): a política gerada passa a testar a unidade da linha contra a lista de unidades do ator,
  lida uma vez por instrução, com as concessões da ação fundidas num só predicado (`EXISTS` continua sob `NOT`, sem
  vínculo do ator ou com FK composta). O `mini_crm_revendas` ganha o plano `0004_expand` com a troca atômica das
  políticas; os outros exemplos não mudam. A escrita foi medida por ação com 1 milhão de vínculos
  ([relatório](sondas/escopo-por-acao.md)): a lista acrescenta de +0,2 a +1,6 ms por instrução, menos que a forma
  anterior em todas as células, mas fica acima de 1 ms em quase todo `UPDATE` e `DELETE` por chave; o piso vem das
  referências ao contexto (ADR-024, §4). A sonda `sonda_escopo.rb` confere por conjunto de IDs, nas quatro ações e
  na mudança de unidade, que a política real e as seis formas concedem o mesmo, e roda na CI com medição curta. Não
  cumpre o teste 6 do ADR-023. Integrada em `4456826`, com a CI verde
  ([execução 42751564660](https://github.com/vetra-framework/vetra/actions/runs/42751564660)).

- [x] Medição preliminar e informativa do custo do contexto assinado e dos registros (K13), pela sonda
  `sonda_custo_contexto.rb`, no PostgreSQL 17 e 18, com 16 clientes, 3 rodadas alternadas e os papéis de produção
  ([relatório](sondas/custo-contexto.md)). Não cumpre o teste de aceitação 6 do ADR-023, que exige falhar acima do
  limiar: esse gate continua pendente. O contexto assinado acrescenta de 0,2 a 0,4 ms por instrução na maior parte das
  rodadas, abaixo do limiar de 0,5 ms, com três de doze estimativas acima no 18 (inconclusivo). Com 1 milhão de vínculos, a política
  de escopo gerada acrescenta de 0,8 a 2,8 ms na leitura, acima do limiar de 1 ms; a forma com a lista do ator reduz o
  acréscimo, mas fica em torno do limiar com 100 revendas no 18, e nenhuma das duas foi medida em escrita. Construir
  10.000 registros custa de 72% a 193% da consulta, acima do limiar de 10% do ADR-022, §3. A sonda roda no job de
  planos da CI, onde a dispersão é maior, e a medição não serve como gate numa CI compartilhada ([execução 42672241740](https://github.com/vetra-framework/vetra/actions/runs/42672241740)).
  Integrada em `3a9c3b2`.

- [x] Relay, entregas e manutenção da outbox (K12, [ADR-040](adr/040-papeis-e-rls-da-outbox.md), §§ 3 e 4): o
  bootstrap cria o `vetra_relay`, e o `0003_expand` do blog e dos dois CRMs traz a guarda do papel, o checkpoint, as
  políticas e concessões do relay e a rotina `vetra.outbox_maintain`. `Vetra::Data::Relay` lê a outbox por faixas de
  `xid8` abaixo do xmin, materializa uma entrega por handler, reserva por lease com `SKIP LOCKED`, repete com espera
  crescente e leva a `dead` com a cópia para `vetra.dead_deliveries`. A manutenção (também `vetra outbox:maintain`)
  cria as partições diárias, recupera uma `DEFAULT` populada e purga por `DETACH`/`DROP` sem tocar pendências; o
  `db:migrate` reconhece só as partições idênticas à `DEFAULT` com o intervalo do dia. A sonda passa 38/38 no
  PostgreSQL 17.11 e no 18.6, também na CI ([execução 42378937385](https://github.com/vetra-framework/vetra/actions/runs/42378937385)). Integrado em `3c9d6ff`.

- [x] Outbox, armazenamento e emissão (K11, [ADR-040](adr/040-papeis-e-rls-da-outbox.md) aceito):
  `vetra.outbox` e `vetra.deliveries` particionadas por tempo, com partição `DEFAULT`, e `vetra.dead_deliveries`,
  no plano `0002_expand` do blog, do mini CRM e do CRM com revendas, gerado pelo plano incremental num passo.
  A aplicação só insere, pelas colunas do evento, e a política de `INSERT` exige o tenant e o ator do contexto;
  `created_at`, `xid8` e `seq` vêm do banco. `Repositories#emit!` grava os eventos que o comando declara, com o
  payload projetado e um `pg_notify` só com o tenant; um payload com campo pessoal desfaz a unidade inteira. O
  retrato normaliza o nome herdado do NOT NULL nas partições, que o `pg_dump` 18 escreve e o 17 não. São 11 testes e
  223 asserções sem banco; a sonda passa 36/36 no PostgreSQL 17.11 e no 18.6, também na CI
  ([execução 42367368631](https://github.com/vetra-framework/vetra/actions/runs/42367368631)). Integrada em `0fff3ee`.

- [x] Repositórios do [Vetra Data](vetra-data.md) gerados da IR e vinculados à unidade/capacidade:
  busca, lock, criação, atualização por registro ou ID, exclusão, consulta restrita e vínculos de
  `many_to_many`, incluindo o dono na criação. Tenant e relógio vêm da unidade; transições conferem o
  comando e o estado relido no banco. Cada entidade tem um `Data` congelado em profundidade, compartilhável
  entre Ractors, com predicados de grupos de enum. São 35 testes/865 asserções sem banco, incluindo os
  dez corpos Ruby de comandos e consultas dos quatro exemplos. A sonda passa 72/72 no
  PostgreSQL 18.6 e roda no job de planos da CI. O avaliador Ruby anterior à unidade está implementado;
  autorização nos acessos, reautorização final e despacho continuam pendentes na K17/K18.

- [x] Infraestrutura do [Vetra Data](vetra-data.md): `transaction`, `read`, `compose` e `rollback!`, com
  `pg_auto_parameterize`, concorrência por fibra, sem statements nomeados e contexto instalado uma vez na
  transação externa. Guarda transacional usada pelos terminais dos repositórios; contexto global sem tenant fictício nem token,
  com identidades SQL NULL. Emissor com validade de 30 s/teto de 120 s, segredo por configuração/ambiente e
  inspeção/logs sensíveis redigidos. Sequel 5.110.0 e pg 1.7.0 nos cinco lockfiles, conferidos fora de development;
  compilador sem carga dessas gems. A C8 tem 17 testes/308 asserções e nove diagnósticos novos. Integrada em
  `a98c4de`, com o checksum do `sequel` corrigido em `75dd5e2`. Sonda 23/23 no PostgreSQL 17 e 18 da CI
  ([execução 42223531863](https://github.com/vetra-framework/vetra/actions/runs/42223531863)), com `vetra_app` entrando por senha própria do servidor descartável.
  [ADR-039](adr/039-unidade-de-trabalho-e-repositorios.md) aceito em 2026-11-06 pelo Claude, por delegação do mantenedor, após a auditoria da C8.

- [x] Versão do compilador preparada como `0.1.0-alpha.5`, com lockfiles e quatro grafos reconstruídos.
  Publicação da gem continua sendo uma etapa separada.

**Mapeamento físico inicial**

- [x] `Vetra::SQL::Schema`: IR validada para modelo profundamente congelado e DDL determinístico de banco
  vazio, separado em schemas, tabelas/chaves/índices e FKs. Inclui tenant implícito, raiz distinta de tabelas
  globais, junções e FKs compostas opcionais, sem alterar a IR. [Guia](db-schema-sql.md).
- [x] `vetra db:plan` (K7): plano inicial em `db/plans/` com fase, lock e custo por passo e transação única; retrato
  `db/schema.sql` pelo `pg_dump` normalizado de um banco descartável; `--check` na CI no PostgreSQL 17 e 18, num job
  próprio, verde nos dois ([execução 41902986720](https://github.com/vetra-framework/vetra/actions/runs/41902986720)). Os quatro exemplos têm plano e retrato. [Guia](db-plan.md).
- [x] `vetra db:migrate` (K8): aplica o plano inicial como `vetra_migrator`, com o hash de cada plano em
  `vetra.migrations` na mesma transação, lock consultivo de migrador único, `lock_timeout` de 3 s com novas
  tentativas, recusa de banco não vazio, de plano alterado e de deriva, e retomada. Sonda no PostgreSQL 17 e 18.
  [Guia](db-migrate.md).
- [x] Fundação do plano incremental (K9, ADR-038):
  - cada plano tem um modelo físico versionado em `db/models/`, encadeado por SHA-256, contra o qual o próximo plano é
    calculado sem conexão;
  - planos `por_passo`, com passos fora de transação (`CREATE INDEX CONCURRENTLY`);
  - o último plano é regenerado pela IR, e o gate prende os planos e modelos da base, com no máximo um plano novo por
    aplicação em cada integração;
  - `--check` e `--snapshot` aplicam os planos entrando como `vetra_migrator`, num servidor em que ele não administre
    outro banco, tablespace ou parâmetro nem tenha outra sessão, com filtro de instruções globais, guarda de papéis do
    gerador atual e catálogo conferido antes e depois;
  - com mais de um plano, o `--check` prova a convergência com o plano inicial da IR;
  - o retrato ganhou uma linha `-- vetra:base` por plano.

  Fundação integrada em `5fa7a3a`, com a sonda em 18/18 no PostgreSQL 17 e 18 da CI ([execução 42215134526](https://github.com/vetra-framework/vetra/actions/runs/42215134526)). [Guia](db-plan.md).
- [x] Diferenças aditivas entre modelos (C9, [guia](db-plan.md#diferenças-aditivas)): tabela completa, colunas
  anuláveis ou com default constante, índices `CONCURRENTLY`, únicas com índice de apoio antes da FK composta,
  FKs `NOT VALID`/`VALIDATE`, enum alargado sem janela sem CHECK e políticas RLS trocadas atomicamente.
  Funções de revisão/transição substituídas com assinatura preservada; instalação da revisão com lock e guardas
  no mesmo passo, sem zerar revisões. Nome `NNNN_expand` e bytes regeneráveis, filtro em cada passo e espelho
  completo da segurança atual. Tabelas novas só recebem DML depois de toda a segurança instalada; troca de trigger
  preserva `ENABLE ALWAYS` na mesma transação. Remoções e demais formas sem tradução são recusadas sem artefatos parciais.
- [x] Sonda `script/sonda_plano_aditivo.rb`, no job de planos da CI no PostgreSQL 17 e 18:
  - 13 cenários, com replay e convergência, dados preservados e restrições válidas;
  - seis escritas concorrentes que concluem sob `ShareUpdateExclusive`, em tabelas de 1 milhão de linhas;
  - catálogo global preservado.

  99/99 no PostgreSQL 18.6, em 106 s, e no 17 e 18 da CI ([execução 42235979068](https://github.com/vetra-framework/vetra/actions/runs/42235979068)). Integrada em `e2bdd14`.
- [x] `db:migrate` incremental (K10): planos por passo aplicados com registro em `vetra.migration_steps`, retomada do
  passo seguinte, índice válido de uma tentativa anterior aceito e inválido refeito, `lock_timeout` com novas tentativas
  por passo, base conferida pela linha `-- vetra:base`, começo do plano registrado (passo 0), catálogos fora do dump
  conferidos antes dos passos, definição inteira do índice conferida na retomada e `pg_dump` com `--lock-wait-timeout`.
  Sonda de 16 verificações no PostgreSQL 18.6 e no 17 e 18 da CI ([execução 42251208776](https://github.com/vetra-framework/vetra/actions/runs/42251208776)), com queda em cada passo e num plano que
  começa por índice. Integrada em `2db989c`. [Guia](db-migrate.md#retomada).
- [x] Quatro fixtures SQL integrais em `test/fixtures/sql`, comparadas byte a byte na suíte sem banco.
- [x] DDL dos quatro exemplos aplicado pelo Claude no PostgreSQL 18.6 (13 tabelas, 15 FKs), com integridade entre
  tenants, `money`, `enum`, comprimento e FKs adiáveis conferidos; no 17, pelo `db:plan --check` da K7 na CI.

**Papéis e contexto assinado**

- [x] `Vetra::SQL::Context.roles_sql` gera bootstrap global separado e repetível; o plano apenas confere
  atributos e vínculos de `vetra_app`, `vetra_migrator` e `vetra_owner`. Nenhum papel é alterado pelo
  executor temporário. O operador cria o banco com `vetra_migrator` como dono; o plano é aplicável por
  ele sem superusuário e concede CREATE no banco a `vetra_owner` para receber os schemas. Os membros
  SECURITY INVOKER de `pgcrypto` conservam EXECUTE; a aplicação não tem USAGE no schema privado.
- [x] Plano inicial com `vetra_private.keys` vazia, contexto HMAC-SHA256, validade, rotação por estados,
  donos fixos, concessões mínimas e classificação de todos os passos. Chaves ficam fora dos artefatos.
- [x] Guarda de autorização reconhece somente as duas funções exatas por assinatura, schema, dono,
  atributos, configuração e hash do corpo; reutiliza `vetra` do plano sem substituir infraestrutura.
- [x] Testes sem banco para geração, identificadores, classificação, hashes e retrato com donos.
  `sonda_contexto_assinado.rb` verifica o plano gerado, privilégios e tokens válidos/recusados, rotação e
  mutações da exceção, aplicando os planos com session_user/current_user `vetra_migrator` e sem poderes
  administrativos: 58/58 no PostgreSQL 18.6, e na CI no 17 e 18.
- [x] ADR-036 aceito em 2026-11-05 pelo Claude, por delegação do mantenedor. Autenticação, emissão em runtime, contexto visitante/global e keys:rotate
  continuam pendentes.

**RLS e integridade no plano inicial**

- [x] Tenant restritivo com ENABLE/FORCE, inclusive raiz por id, e permissivas por ação para escopos
  SQL por ator/vínculos. Tabelas sem escopo têm permissiva true e RBAC na aplicação, inclusive
  administração de vínculos; blog e chat permanecem globais, sem tenant ou revisão inventados.
- [x] Espelho de RLS/transições em `db/policies/`; os três modos de `db:plan` recusam divergência antes
  do banco. Revisão do ADR-031 composta sem BEGIN/COMMIT interno, com guardas depois dos REVOKEs.
- [x] Triggers invoker dos CRMs conferem entrada/saída de guarded e alterações set_by, com contexto
  validado antes de extrair cmd; somente o migrador dispensa contexto. Sem nova exceção C2.
- [x] Testes sem banco e sonda de 103 verificações, com planos aplicados como migrador e acessos
  permitidos/recusados como aplicação; matriz db-plan 17/18. [Guia](db-rls.md).
- [x] ADR-037 aceito em 2026-11-05 pelo Claude, por delegação do mantenedor, após a auditoria da C7.
- [ ] Políticas de administração dos vínculos (por exemplo `memberships`): hoje têm permissiva `true` dentro do
  tenant, e uma sessão `vetra_app` com SQL arbitrário poderia criar o próprio vínculo; a aplicação faz esse RBAC
  (limite do ADR-037).

**Compilador da fase 0** (DSL Ruby, registro congelado, build em IR 0.6, leitura da 0.1/0.2/0.3/0.4/0.5, validação)
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
- [x] C1 (`58993e2`): `many_to_many` gera `add_<singular>` e
  `remove_<singular>`, contratos de IDs tipados, autorização pelo dono e descritores sem executor.
  `commands: false` desliga por relação; colisões e junções incompatíveis são recusadas. Validação de
  IR externa, link com semântica anterior e diff cobertos. Recurso introduzido na IR 0.4 com
  `vetra.relation_commands` quando há geração; schemas 0.1/0.2/0.3 preservados, sem geração retroativa.
  A IR 0.3 recusa o novo requisito e as novas primitivas. O [ADR-032](adr/032-comandos-gerados-de-vinculo.md)
  está aceito; o chat conserva seus comandos explícitos e os critérios 6/7 continuam parciais.
- [x] Papéis, políticas, `crud`, `money`, `decimal`, `enum`, `slug`, privacidade, índices e chaves compostas por
  tenant
- [x] `money` sem `scale` segue o expoente da moeda da aplicação; uma escala explícita inferior é recusada
  (`money_scale`), e uma superior permite precisão estendida. A tabela ISO 4217 é local; moedas sem expoente
  definido falham com `money_currency`. Entidades, entradas de operações, contratos CRUD e payloads de eventos
  estão cobertos por 12 testes novos (`635d926`; fonte da tabela no ADR-026 aceito)
- [x] C3: `currency` aceita `rounding: :half_up` ou `:half_even`,
  com padrão `half_up`. Desde a IR 0.5, o build emite `app.rounding` e `vetra.money_rounding` somente quando a opção
  é declarada, inclusive `half_up`; omissão mantém ambos ausentes. Os schemas 0.1 a 0.4
  ficam intactos e o link preserva suas semânticas. O diff marca troca efetiva como quebra potencial de
  valores, com revisão. O mini CRM com revendas declara a opção da proposta. O ADR-033 está aceito;
  cálculos, moeda e arredondamento por tenant continuam pendentes
- [x] C4: `can` aceita `rate_limit: "5/min"` e janelas como `"5/2min"`, com inteiros positivos e
  unidades explícitas. A política recebe limite, duração em segundos e chave por ator/tenant na IR 0.6;
  só grafos que usam o recurso exigem `vetra.rate_limit`. Validação de IR externa, link, preservação
  das versões 0.1 a 0.5 e diff cobertos por 22 testes. Apertar exige revisão; afrouxar ou remover é
  quebra potencial de segurança. Na rodada 2, o contrato preserva a admissão sem consumo de cotas
  quando alguma concessão aplicável autoriza a operação sem limite. Quando todas as que autorizam
  têm limite, a admissão exige e consome todas as cotas. O ADR-034 está aceito; contadores e execução
  continuam pendentes
- [x] `expose http:`, `cli:`, `job:` e `webhook:` no DSL, conforme o ADR-007, mantendo uma única operação,
  contrato e autorização. Nomes são únicos por superfície; HTTP e webhook compartilham a detecção de rotas
  ambíguas; webhook exige comando com `idempotency: :required` explícito. Consultas recusam POST, job e
  webhook. O mini CRM declara as quatro superfícies de `win_lead`; 15 testes novos cobrem geração, falhas,
  vinculação e diff (`7bd44cb`)

**Exemplos**
- [x] O chat declara `add_member` e `remove_member`, com IDs tipados, autorização pela sala, política do dono,
  rotas HTTP e recusa de remover o proprietário. Os nove testes de `chat_test.rb` cobrem a IR, a vinculação e
  os corpos com duplos de memória. Comandos são explícitos, sem executor ou revogação live (`dbbd713`);
  na C1 a relação usa `commands: false` para preservar esses corpos e suas exposições
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

- [x] O blog declara a permissão visitante `can :create, on: :comment`, com os quatro campos da proposta
  e `rate_limit: "5/min"`, além de leituras de posts publicados/comentários aprovados. Comentários têm
  `author_email` pessoal, CRUD e `approved` protegido pelo comando interno `approve_comment`.

**CI e sondas**
- [x] `db:authz:sql`: gera SQL determinístico da IR validada, sem conectar ou aplicar mudanças.
  Seleciona leituras das políticas e a raiz do tenant, usa armazenamento físico e gera três triggers por
  tabela, revisão transacional, privilégios restritos e preenchimento inicial. O SQL aceita `vetra`
  preexistente com o dono esperado (ADR-036); schemas customizados exigem criação nova. Recusa
  tipos/colunas incompatíveis, partições/herança e poderes perigosos, inclusive privilégios padrão herdados e
  papéis que a aplicação pode assumir por `SET ROLE` ou conceder a si com `ADMIN OPTION`, além de `REFERENCES`
  subscriptions de replicação lógica e papéis de acesso ao servidor; os triggers ficam `ENABLE ALWAYS` (K5). A
  CLI confere o pacote sem reavaliar o DSL. A C2 acrescenta a recusa, com lista, de funções e procedimentos
  `SECURITY DEFINER` preexistentes que conduzem a donos com poderes perigosos, por um fecho recursivo de
  `EXECUTE`, heranças e cadeias `SET ROLE`; DML comum dos donos é permitido, e a guarda roda depois dos
  `REVOKE`s para conferir também a infraestrutura nos papéis do fecho. 18 testes e 59 verificações do SQL
  aplicado em PostgreSQL 18.6; sonda ADR-031 na CI 17/18. Rotinas criadas depois da instalação continuam fora
  da conferência.
  [Guia e limites](db-authz-sql.md).
- [x] `sonda_adr020.rb`: treze verificações de revisão por tenant, sem depender do contexto da escrita;
  inclui lotes, troca de tenant, atomicidade e notificações, concorrência, privilégios, objetos temporários,
  decisão strict após revogação, falha fechada, snapshot antigo, evento sem conteúdo pessoal e releitura
  agrupada. Passou no PostgreSQL 18.6 e entrou na CI do 17 e 18. Quatro falhas introduzidas foram detectadas,
  com remoção dos schemas e papéis após sucesso e falha. [Relatório e limites](sondas/adr020.md).
  Os triggers, a decisão strict e o agrupamento são protótipos da sonda; o runtime continua pendente.
- [x] `sonda_adr008.rb`: dez verificações em PostgreSQL real de intervalos `xid8`, commits invertidos,
  rollback, polling após queda do LISTEN, duas sessões ouvintes, `_v` sob lock, SQL direto, savepoints,
  snapshots novos e timeout. Passou localmente no PostgreSQL 18.6 e entrou na CI do 17 e 18.
  Duas falhas introduzidas em cópias temporárias foram detectadas; a limpeza removeu o schema mesmo com
  resultado negativo. [Relatório e limites](sondas/adr008.md). Não implementa o distribuidor nem a
  ressincronização por retenção/failover (`0beb473`, com CI verde nos dois PostgreSQL).
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
- [x] Sondas de banco no PostgreSQL 17 e 18 (002, 003, 008, 009, 011, 015, 019, 020 e 031). A 011 (o `FOR SHARE` da revogação da
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
- [x] **030** Origem dos tenants no trigger de revisão do ADR-020: tabelas de transição e união de
  tenants antigos e novos, com incremento transacional (`ebed54a`)

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
- [x] **031** Geração inicial de SQL de revisão de autorização: CLI sem aplicação automática, checagens de
  pacote/banco/papéis e sonda que aplica o SQL gerado; integrado nesta continuação

- [x] **032** Comandos gerados de vínculo de `many_to_many`: nomenclatura, opt-out, colisões explícitas,
  contratos, autorização pelo dono e diff, na IR 0.4; integrado em `58993e2`, aceito em 2026-11-03 pelo Claude
  por delegação do mantenedor, mantendo a geração ligada por padrão

- [x] **033** Arredondamento monetário da aplicação e IR 0.5: `half_up`/`half_even`, padrão comercial,
  requisito semântico só com declaração e diff de valores; aceito em 2026-11-03 pelo Claude por delegação do
  mantenedor, após a auditoria da C3

- [x] **034** Limite de taxa por permissão e IR 0.6: sintaxe, unidade, janela móvel, chave por
  política/ator/tenant, concessão sem limite que dispensa as cotas, compatibilidade e diff de segurança; aceito
  em 2026-11-03 pelo Claude por delegação do mantenedor, após a auditoria da C4

- [x] **035** Mapeamento físico inicial: modelo e DDL de banco vazio; aceito em 2026-11-03 pelo Claude por delegação
  do mantenedor, após a auditoria da C5
- [x] **039** Unidade de trabalho, emissão do contexto e contrato dos repositórios; aceito em 2026-11-06 pelo
  Claude por delegação do mantenedor, após a auditoria da C8
- [x] **038** Fundação do plano incremental: modelo físico versionado, transação por passo, história ancorada no gate
  e contenção do `--check`; aceito em 2026-11-06 pelo Claude por delegação do mantenedor, após a auditoria da K9
- [x] **040** Papéis, RLS e armazenamento da outbox: tabelas particionadas, `INSERT` por coluna para a aplicação,
  relay `vetra_relay` e manutenção por rotinas fechadas; aceito em 2026-11-06 pelo Claude por delegação do
  mantenedor, após a auditoria da K11

## 3. Decisões e trabalho que dependem de quem revisa

- [x] Em 2026-11-03, por delegação do mantenedor, o Claude decidiu:
  - aceitar o ADR-032 e manter a geração dos comandos de vínculo ligada por padrão, e confirmar o aceite dos
    ADRs 028 a 031, auditados na K2;
  - levar à `sonda_adr015` os quatro casos do ADR-025 (índice e chave em tabela particionada, chave composta por
    tenant, `CHECK` de `enum`), com CI no PostgreSQL 17 e 18: tarefa K6, com [relatório](sondas/adr015.md);
  - não abrir agora ADR de resolução para as questões em aberto dos demais ADRs aceitos: nenhuma bloqueia a
    persistência, e cada uma será tratada quando o componente correspondente começar;
  - manter recusada a consulta sem `returns` nem `authorize`: contrato e autorização explícitos são regra de
    desenho, e o critério 7 continua parcial por isso.
- [ ] Mantenedor publicar a gem 0.1.0.pre.alpha.5: a rodada 2 do quadro terminou, e a publicação fixa os schemas
  0.4 a 0.6.

## 4. Fase 0: critérios do ADR-001

Detalhe e evidência em [fase-0-criterios.md](fase-0-criterios.md).

- [x] **1** Schema válido, exemplos com e sem tenant, falhas estruturais
- [x] **2** Cada regra semântica tem um caso que a dispara
- [x] **3** Mesmo resultado entre checkouts, descoberta embaralhada, vetores Unicode
- [x] **4** O hash reproduz o valor; mudanças invalidam o build
- [x] **5** Versão suportada, MENOR ou MAIOR futura, recurso não implementado
- [ ] **6** Produção recusa IR ausente, adulterada ou incompatível. Parcial: não há servidor de produção
- [ ] **7** Contratos CRUD, políticas e transições equivalem aos três exemplos da proposta. Parcial por desenho: o
  DSL recusa 4 construtos de 14 no blog, 3 de 6 no mini CRM e 4 de 9 no chat
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
- [ ] Moeda por tenant (a conferência do `scale` contra a moeda da aplicação já está implementada)
- [ ] O titular (`subject`) e a retenção (`retention`) de dado pessoal
- [ ] Consulta sem `returns` e sem `authorize`: os exemplos da proposta as omitem, e o compilador exige as duas
- [ ] SQL explícito e metadados de dependência por gem
- [ ] Políticas por atributo do ator além de `id`

**Runtime**
- [ ] Execução de `rate_limit:` por permissão: contadores compartilhados, janela móvel, reservas concorrentes
  e identidade anônima confiável, conforme o ADR-034
- [ ] Executor das primitivas CRUD, de vínculo de `many_to_many` e dos comandos (descritores reconhecidos,
  sem executor). Os repositórios já implementam CRUD, `include_on_create`, locks e idempotência dos vínculos
- [ ] Adaptadores HTTP, CLI, job e webhook em execução, incluindo resolução do ator/tenant e deduplicação;
  as exposições e a exigência de idempotência já são compiladas e validadas
- [ ] Executor de operações do Vetra Data, com `authorize` em Ruby, permissões por campo e reautorização do
  estado final; repositórios, unidade de trabalho e emissor Ruby já implementados
- [ ] Modo hospedado em Rails: adaptador Rack, resolvedor do ator e pontes somente leitura para models do Rails
- [ ] Privacy, Audit e History em execução: criptografia por envelope, KMS, eliminação e exportação
- [ ] Sinais efêmeros em execução: "digitando", presença por lease e a limitação de taxa
- [ ] Modo sombra em execução: simulador determinístico, repositório simulado e relatório de divergências
- [ ] Workflows duráveis em execução: histórico, replay, temporizadores, sinais e versões
- [ ] MCP em execução: adaptador, delegações, aprovações, limite de taxa e o piso de sensibilidade no compilador
- [ ] Camada de UI em execução: módulos, páginas, formulários por contrato, ejeção, cabeçalho de linha de base e
  `vetra doctor`
- [ ] Servidor de produção e cache de compilação
- [ ] Entrega de eventos e consultas live em execução; RLS é gerado no plano inicial, sem runtime de operações

## 6. Lacunas de evidência e limites conhecidos

- [ ] **ADR-008:** a sonda de intervalos e `_v` já existe e entra na CI do PostgreSQL 17 e 18. O distribuidor,
  checkpoints persistidos, retenção e ressincronização por mudança de cluster/timeline continuam pendentes.
  As sessões da sonda não exercitam múltiplos processos de aplicação, carga ou transações preparadas
- [ ] **ADR-020:** a sonda e a resolução da origem do tenant (ADR-030) já existem. O gerador de triggers
  de revisão integra o plano inicial (ADR-031); assinaturas autenticadas, entrega, modo balanced,
  auditoria e os 12 critérios integrados continuam pendentes do runtime. O agrupamento e a decisão strict
  da sonda são demonstrações
- [ ] **ADR-004:** o protótipo cobre os testes de aceitação 2 e 3. Os outros seis dependem do runtime, e o erro de
  `uses` inexistente não foi conferido
- [ ] **ADR-009:** o motor de workflows, o histórico e a sintaxe não existem, e o schema 0.1 não representa
  workflows. A `sonda_adr009` verifica o replay em Fiber (sem escalonador), o código alterado e a Fiber não
  serializável, e mede o `TracePoint`. O contrato de cancelamento, sinais concorrentes e compensação ainda não
  está especificado; ramos concorrentes exigem um escalonador determinístico e um ADR novo
- [ ] **ADR-011:** a IR 0.1 não representa a exposição MCP (o `surface` aceita `http`, `cli`, `job` e `webhook`;
  é preciso uma nova MENOR com `vetra.mcp`) e o DSL aceita as quatro superfícies, sem MCP. As delegações, as aprovações, o
  adaptador, os limites próprios de agente/delegação e o piso de sensibilidade não existem.
  O limite do papel já é declarado em `can` na IR 0.6, sem executor (ADR-034). O `FOR SHARE` da revogação tem a
  `sonda_adr011` (5 itens, rodando na CI no 17 e no 18). O piso cobre só o que a IR enxerga, porque o `call` não é
  registrado; as recusas das etapas 1 a 3 ficam no log, não no Audit
- [ ] **ADR-018:** os módulos de UI, o DSL (`ui :server`, `page`, `crud ui:` e `expose ui:` falham no protótipo), a
  representação na IR (nova MENOR com `vetra.ui`), o `vetra doctor` e `vetra ui:resync` não existem; a CLI tem
  `graph:*` e `db:authz:sql`. O ERB da biblioteca padrão (4.0.3) não escapa a saída, conferido à mão, sem sonda versionada: o motor
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
  valor protegido como `default:` (`guard_default`). Os repositórios conferem transições antes do DML a partir
  de OLD relido com lock e do cmd da unidade. O plano gera os triggers db; a reautorização na etapa 6,
  as telas administrativas, os eventos e o histórico dependem do runtime, e a sintaxe de UI pertence ao ADR-018
- [ ] **ADR-014:** o protótipo recusa um handler que escreve por repositório e um evento interno sem consumidor,
  tem relay, entregas, lease e reentrega. O runner dos handlers da C14 aplica `calls`, identidade do tenant do evento,
  idempotência e timeout total (sonda em 12/12 no 17 e no 18). Reprocessamento
  auditado de `dead`, cifra, histórico e auditoria continuam na rodada 6; a IR não ganha papel de sistema
- [ ] **ADR-013:** o protótipo cobre só a classificação `privacy`, a validação do payload dos eventos e o diff de
  privacidade (teste de aceitação 2). Nada do envelope, do KMS, do histórico ou da auditoria existe. Declarar o
  titular e a retenção exige uma nova MENOR da IR, porque `privacy` é fechado
- [ ] **ADR-010:** o modo hospedado com o Active Record não foi exercitado, e nenhuma sonda mede a gem
  `sequel-activerecord_connection`. A transação e o contexto de RLS compartilhados e os cinco testes do ADR-003 são
  hipótese até rodarem contra um Rails real. O protótipo não tem ponte com Rails
- [ ] **ADR-017:** a escala por moeda da aplicação e a precisão estendida estão implementadas e testadas em
  `635d926`, com tabela local de expoentes (SIX, publicação de 2026-09-17; fonte definida no ADR-026). A
  aritmética, o rateio, o arredondamento, a formatação e a validação HTTP ainda dependem do runtime. A
  declaração de arredondamento da aplicação está na IR 0.5 (C3); a moeda por tenant exige uma nova MENOR da IR
- [ ] **ADR-007:** as quatro superfícies são declaradas no DSL e validadas na IR 0.1. O teste de aceitação 6
  cobre comando por GET e consulta por POST. Nomes únicos por superfície, colisões entre HTTP e webhook,
  idempotência obrigatória de webhook e vínculo único ao comando estão cobertos em `exposure_test.rb`.
  Os adaptadores, a tradução da entrada/saída, a transação comum e a idempotência em execução continuam
  dependentes do runtime
- [ ] **Sondas manuais:** `sonda_pooler` (precisa de PgBouncer) e `sonda_adr006` (precisa de `RUBY_BOX=1`) não rodam
  na CI. Parte da evidência dos ADRs 003, 005, 006 e 008 vem delas
- [ ] **PostgreSQL 19:** entra na matriz da CI quando existir uma imagem
- [ ] **Persistência:** as questões em aberto dos ADRs 003, 005, 014 e 015 estão tratadas por ADRs de resolução
  (022 a 025). O modelo físico, o DDL de banco vazio (ADR-035) e o plano inicial com retrato (`db:plan`) estão implementados;
  as diferenças aditivas e os repositórios estão implementados, e o `db:migrate` aplica o plano inicial e os
  incrementais, passo a passo; executor, outbox e medições restantes continuam pendentes (veja ADR-022 a ADR-025 abaixo)
- [ ] **ADR-022:** o custo dos registros no repositório real foi medido (K13): de 72% a 193% da consulta, acima do
  limiar de 10%. A C11 implementa a conversão imediata de leitura após medir também a construção sob demanda
  ([ADR-042 proposto](adr/042-construcao-dos-registros.md)); o gate segue aberto: a construção caiu para 40%-56% da consulta no 17 e no 18 e a decisão do
  orçamento é do mantenedor.
  Continuam pendentes a `sonda_pooler` contra o pooler da aplicação e o `pg` sob o Falcon em Ruby 4.0.9 com o
  adaptador Rack (hoje só medido em Ruby 3.3.6). O
  analisador do compilador já recusa `Sequel`, `ActiveRecord` e `PG` num `call` (#34), mas a regra sobre
  interpolação em `uses :sql` espera a capacidade `uses :sql`, que não existe
- [ ] **ADR-023:** a medição informativa (K13) no 17 e no 18, com 16 clientes, `WITH CHECK` e a comparação em tempo
  constante, deu de 0,2 a 0,4 ms por instrução para o contexto assinado na maior parte das rodadas, abaixo do limiar
  de 0,5 ms, com três de doze estimativas acima no 18 (inconclusivo). A política de escopo com 1 milhão de vínculos ficou acima do
  limiar de 1 ms na leitura (de 0,8 a 2,8 ms), o que levou ao ADR-041 (K14): a forma lista, medida também em escrita, fica de
  +0,2 a +1,6 ms e acima de 1 ms em quase todo `UPDATE` e `DELETE` por chave, e o piso vem das referências ao contexto
  (baixá-lo é decisão futura sobre a função de contexto). O
  teste de aceitação 6 (medição na CI que falha acima do limiar) continua pendente. Faltam o pooler, ausente na CI, e a
  medição de 25% da latência por comando, que espera o executor (rodada 5, K20); o teste 6 segue pendente. O gerador de políticas
  compõe o plano inicial com a forma tenant/ator não correlacionada e recusa vínculo sem índice físico
  tenant/ator. A autenticação (como a credencial escolhe a empresa) não tem ADR
- [ ] **ADR-024:** a partição foi medida só no PostgreSQL 16.15, com carga sintética, um cliente, sem escrita
  concorrente nem `VACUUM`; o gate na matriz do G4 está por medir. A outbox e as entregas particionadas,
  `vetra.dead_deliveries`, o relay e a manutenção existem desde a K11 e a K12 (ADR-040); a claim `system_actor`, a função `is_system_actor()` e a condição nas
  políticas de escopo não existem. O `graph:diff` já classifica `calls` de um handler como `permissions` (#34), mas
  o compilador não avisa sobre o timeout do handler. O DSL só declara `handler` com `calls`, e a IR 0.1 não tem
  timeout nem papel por handler
- [ ] **ADR-025:** a [sonda](sondas/adr015.md) confere, no PostgreSQL 17 e 18 da CI, o índice e as chaves em tabela
  particionada (o 18 aceita `NOT VALID` na chave do pai), a herança do índice por partição nova, a chave composta
  por tenant com o índice de apoio, o `VALIDATE` sem bloquear escrita e o `enum` por `CHECK` (K6). O custo na
  escrita do índice de apoio sob carga continua por medir. O desenho do contract (`vetra.instances`, `vetra.schema_state`, `plan_seq`) não
  tem protótipo. `db:plan`, retrato `db/schema.sql` e enum como texto com CHECK estão implementados;
  os retratos incluem RLS, revisão e transições (C7)
- [ ] **ADR-030/020/031:** revisão integrada ao plano inicial; faltam upgrades e a chave de revisão de aplicações sem
  tenant; exercitar particionamento, cascatas, combinações de eventos e deadlocks entre instruções.
  O custo de reler campos pessoais por grupo continua por medir no gate G4

Limite documentado, sem ação prevista: os hashes não autenticam o pacote.

## 7. Próximos passos propostos

Ordem sugerida; cada passo é um ou mais commits na `main`, conforme o [quadro dos agentes](tarefas-dos-agentes.md).
O que já foi feito está na seção 1; aqui só ficam os passos que faltam.

1. [ ] Persistência, rodada 5: um executor **parcial** do ADR-016, sem histórico, auditoria nem adaptadores, em duas
   fases. A fase A traz as duas decisões que a medição da K13 pediu (a forma da política de escopo, **decidida na K14**, e a
   construção dos registros, implementada na C11 com ADR-042 proposto e gate aberto), o ator de sistema (K15, implementado; custo
   pendente de decisão do mantenedor), a
   idempotência (K16, implementada) e a autorização em Ruby (C13, ADR-044 proposto); a fase B, o executor (despacho,
   autorização nos acessos dos repositórios, eventos, idempotência e repetição) e os handlers de sistema, foi
   **replanejada na P5** (parecer do Codex em duas rodadas, aprovada): C15 (limites da unidade), K17 (borda e despacho), C16
   (`many_to_many` no avaliador), K18, K19, C14 e K20, nessa ordem; a C15, a K17, a C16, a K18 e a K19 estão integradas; a C14 está integrada e a K20 é a próxima. Planejada no [plano da persistência](plano-persistencia.md#rodada-5-decisões-da-k13-ator-de-sistema-idempotência-autorização-e-executor-parcial), com as tarefas K14 a K20 e C11 a C14
   no quadro, depois de um parecer do Codex que devolveu a primeira versão. **Entra primeiro:** a persistência já está
   pronta para recebê-la, e a única decisão que vai ao mantenedor é o teste 6 do ADR-023, que continua pendente.
2. [ ] Fechar as lacunas declarativas da fase 0, com os exemplos da proposta. São dois grupos diferentes:
   - **As cinco famílias que o DSL ainda recusa nos exemplos da proposta** (critério 7, parcial por desenho):
     `auth`, a UI, `realtime`, a consulta sem `returns` e sem `authorize`, e o escopo por vínculo sem o `has_many`
     inverso. Nenhuma está na rodada 5, e cada uma depende de algo diferente: `auth` não tem ADR de autenticação; a UI
     tem o ADR-018 aceito e espera a implementação e a sua representação no grafo; `realtime` espera o distribuidor do
     live; a consulta sem `returns` e sem `authorize` **já foi decidida como recusada** (seção 3, 2026-11-03), e só um
     novo aceite do mantenedor a reabre; o escopo por vínculo sem o inverso ainda não tem desenho e **pode ser
     antecipado**, porque não depende do executor.
   - **Outras pendências, que não pertencem ao critério 7:** `subject` e `retention`, cujo desenho declarativo
     **pode ser antecipado**, porque só a execução depende da cifra do ADR-013, como foi com `rate_limit:` (exige IR
     0.7 e um ADR); e as famílias da seção 5 sem destino ainda, como a moeda por tenant e as políticas por atributo
     do ator além de `id`, que esperam um ADR.

   O critério 6 depende de existir um servidor de produção. Cada família vira tarefa ao planejar a rodada 6 e as
   seguintes, e as que podem ser antecipadas entram antes se o mantenedor assim priorizar. Já estão implementados a
   escala por moeda de `money`, as exposições do ADR-007, os comandos explícitos de membros do chat, o `created_at`
   implícito (IR 0.2), as consultas do chat com coleções e contratos compostos (IR 0.3) e o live de `room_page`, a
   geração automática dos comandos de vínculo (C1, ADR-032), `rounding:` em `currency` (C3, ADR-033, IR 0.5) e
   `rate_limit:` em `can` (C4, ADR-034, IR 0.6) e a recusa no compilador de campos e predicados de enum que colidem
   com métodos do registro `Data` (C12).
3. [ ] Persistência, rodada 6: os adaptadores HTTP, CLI, job e webhook; a cifra dos campos pessoais, o histórico e a
   auditoria, com o que a conformidade integral com o ADR-016 pede; o distribuidor do live; a fase contract
   (`vetra.instances` e `vetra.schema_state`); os contadores de `rate_limit:`; e o modo hospedado em Rails. Entra
   depois da rodada 5 e será planejada ao fim dela, como esta foi

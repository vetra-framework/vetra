# Situação do projeto

Este arquivo reúne, num só lugar, o que já foi feito, o que espera uma decisão e o que ainda não existe. Ele não
substitui o [índice de ADRs](adr/README.md), a [lista de revisão](adr/revisao-de-aceite.md) nem a
[cobertura dos critérios da fase 0](fase-0-criterios.md): resume os três e aponta para eles.

- **Atualizado em:** 2026-10-31, sobre a main `5e550dc` (PR #30).
- **Legenda:** `[x]` feito ou confirmado; `[ ]` pendente, incompleto ou não implementado. Cada pendência diz de
  quem é a decisão. "Quem revisa" é quem integra o PR.

## Resumo

| Item | Situação |
|---|---|
| ADRs | 23 aceitos: os 21 fundadores e 2 ADRs de resolução (022 e 023) |
| Testes do compilador | 191 testes e 1.325 asserções, sem falhas; os 123 códigos de diagnóstico são disparados por algum teste |
| Critérios da fase 0 (ADR-001) | 8 cobertos e 3 parciais |
| CI da main | Verde no PR #30: `test` e sondas no PostgreSQL 17 e 18 |
| PRs | #1 a #30 integrados |
| Sondas | 7 em `script/`, mais o simulador do gate da CI; 5 rodam na CI (002, 003, 009, 015 e 019) |
| Runtime | Não existe. Só o compilador da fase 0 foi implementado |

## Como manter este arquivo

- Todo PR que muda um status atualiza este arquivo **no mesmo PR**: marque `[x]`, anote o número do PR e ajuste o
  resumo e a data.
- Os contadores de ADR saem dos próprios arquivos. Para conferi-los:

```bash
grep -l '^- Status: aceito' docs/adr/0*.md | wc -l
```

```bash
grep -l '^- Status: proposto' docs/adr/0*.md | wc -l
```

- Os testes são medidos com `bundle exec rake test`, que informa o número de testes e de asserções.
- Item novo entra como `[ ]`, com o responsável pela decisão. Item que deixou de valer é removido, não riscado.

## 1. Feito

**Compilador da fase 0** (DSL Ruby, registro congelado, IR 0.1, validação)
- [x] `graph:build`, `graph:check`, `graph:validate`, `graph:diff` e `graph:link`
- [x] Todos os códigos de diagnóstico têm um teste que os dispara (#8)
- [x] Palavra-chave desconhecida ou ausente falha com `unsupported_option` e `missing_option`, nomeando o método e a
  linha da declaração (#10 e #11)
- [x] Critérios 1, 7 e 10 do ADR-001 conferidos item a item (#9)

**DSL**
- [x] Escopo por vínculo (`memberships`)
- [x] `many_to_many` por entidade de junção declarada ou gerada (#13)
- [x] Papéis, políticas, `crud`, `money`, `decimal`, `enum`, `slug`, privacidade, índices e chaves compostas por
  tenant

**CI e sondas**
- [x] CI com testes, `graph:check`, `graph:validate`, `graph:link` e o gate de diff contra a base (o gate falha
  quando não consegue ler a base, #6)
- [x] Sondas de banco no PostgreSQL 17 e 18 (002, 003, 009, 015 e 019)
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

Não há ADR proposto: nenhuma decisão de ADR espera quem revisa.

## 3. Decisões e trabalho que dependem de quem revisa

- [ ] Decidir se o ADR-008 ganha `script/sonda_adr008.rb` (regra de leitura por intervalo, trigger `_v` e
  ressincronização), com CI no PostgreSQL 17 e 18
- [ ] Decidir se o ADR-020 ganha uma sonda (trigger de linha, releitura por grupo)
- [ ] Decidir se o ADR-011 ganha `script/sonda_adr011.rb` (`FOR SHARE` contra a revogação), com CI no PostgreSQL
  17 e 18

## 4. Fase 0: critérios do ADR-001

Detalhe e evidência em [fase-0-criterios.md](fase-0-criterios.md).

- [x] **1** Schema válido, exemplos com e sem tenant, falhas estruturais
- [x] **2** Cada regra semântica tem um caso que a dispara
- [x] **3** Mesmo resultado entre checkouts, descoberta embaralhada, vetores Unicode
- [x] **4** O hash reproduz o valor; mudanças invalidam o build
- [x] **5** Versão suportada, MENOR ou MAIOR futura, recurso não implementado
- [ ] **6** Produção recusa IR ausente, adulterada ou incompatível. Parcial: não há servidor de produção
- [ ] **7** Contratos CRUD, políticas e transições equivalem aos três exemplos da proposta. Parcial por desenho: o
  DSL recusa 4 construtos de 14 no blog, 4 de 6 no mini CRM e 6 de 9 no chat
- [x] **8** Mesma IR gera saídas idênticas; `graph:check` detecta edição e desatualização
- [x] **9** O diff distingue remoção, renomeação, capacidade nova, permissão e só origem
- [x] **10** Registro congelado, implementação ausente ou duplicada, recarga como unidade. Coberto, com uma
  limitação de desenho mantida por decisão: o `binding` não guarda o digest da implementação, que fica na IR
- [ ] **11** Compartilhamento de dados entre Ractors. Parcial: a extensão não existe, e o núcleo roda sem ela

## 5. Ainda não implementado

**No DSL** (falham de forma audível, não viram anotação)
- [ ] `auth` e a geração de usuários e vínculos
- [ ] `ui`, MCP e workflows
- [ ] Consultas `live` e `realtime`
- [ ] `rate_limit:` em `can` e `rounding:` em `currency`
- [ ] Moeda por tenant e a conferência do `scale` de `money` contra o expoente da moeda
- [ ] O titular (`subject`) e a retenção (`retention`) de dado pessoal
- [ ] Consulta sem `returns` e sem `authorize`: os exemplos da proposta as omitem, e o compilador exige as duas
- [ ] SQL explícito e metadados de dependência por gem
- [ ] Políticas por atributo do ator além de `id`

**Nos exemplos**
- [ ] Os comandos `add_member` e `remove_member` do chat
- [ ] O `created_at` implícito

**Runtime**
- [ ] Execução das primitivas CRUD e dos comandos (hoje são descritores reconhecidos, sem executor)
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

- [ ] **ADR-008:** a regra de leitura por intervalo, o trigger `_v` e a ressincronização não têm sonda versionada.
  Foram conferidos à mão só no PostgreSQL 16.15
- [ ] **ADR-020:** sem sonda; o que o sustenta são os 12 critérios, ainda sem implementação
- [ ] **ADR-004:** o protótipo cobre os testes de aceitação 2 e 3. Os outros seis dependem do runtime, e o erro de
  `uses` inexistente não foi conferido
- [ ] **ADR-009:** o motor de workflows, o histórico e a sintaxe não existem, e o schema 0.1 não representa
  workflows. A `sonda_adr009` verifica o replay em Fiber (sem escalonador), o código alterado e a Fiber não
  serializável, e mede o `TracePoint`. O contrato de cancelamento, sinais concorrentes e compensação ainda não
  está especificado; ramos concorrentes exigem um escalonador determinístico e um ADR novo
- [ ] **ADR-011:** a IR 0.1 não representa a exposição MCP (o `surface` aceita `http`, `cli`, `job` e `webhook`;
  é preciso uma nova MENOR com `vetra.mcp`) e o DSL só tem `expose http:`. As delegações, as aprovações, o
  adaptador, o limite de taxa e o piso de sensibilidade não existem. O `FOR SHARE` da revogação foi conferido à
  mão no PostgreSQL 16.15, sem sonda versionada. O piso cobre só o que a IR enxerga, porque o `call` não é
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
  mas o relay, as entregas, o lease e a reentrega não existem. Como a política `authorize` de um comando trata o
  ator de sistema de um handler é questão aberta; um papel de sistema exigiria uma nova MENOR da IR
- [ ] **ADR-013:** o protótipo cobre só a classificação `privacy`, a validação do payload dos eventos e o diff de
  privacidade (teste de aceitação 2). Nada do envelope, do KMS, do histórico ou da auditoria existe. Declarar o
  titular e a retenção exige uma nova MENOR da IR, porque `privacy` é fechado
- [ ] **ADR-010:** o modo hospedado com o Active Record não foi exercitado, e nenhuma sonda mede a gem
  `sequel-activerecord_connection`. A transação e o contexto de RLS compartilhados e os cinco testes do ADR-003 são
  hipótese até rodarem contra um Rails real. O protótipo não tem ponte com Rails
- [ ] **ADR-017:** o protótipo usa `scale` 2 por padrão e não conhece o expoente ISO 4217: um app em JPY aceitaria
  `100.50` e um em BHD recusaria `1.234`. A verificação do `scale` contra o expoente depende de uma tabela de
  expoentes ainda não adotada; a moeda por tenant exige uma nova MENOR da IR
- [ ] **ADR-007:** o protótipo implementa as regras de rota do §4, mas o teste de aceitação 6 só é exercitado na
  direção comando por `GET`; a direção consulta por `POST` está implementada e sem teste. O DSL declara só
  `expose http:`, então `cli`, `job` e `webhook` existem apenas na IR. Os demais testes dependem do runtime
- [ ] **Sondas manuais:** `sonda_pooler` (precisa de PgBouncer) e `sonda_adr006` (precisa de `RUBY_BOX=1`) não rodam
  na CI. Parte da evidência dos ADRs 003, 005, 006 e 008 vem delas
- [ ] **PostgreSQL 19:** entra na matriz da CI quando existir uma imagem
- [ ] **Persistência:** as questões em aberto dos ADRs 003, 005, 014 e 015 precisam estar tratadas por ADRs de
  resolução antes de implementá-la. O 003 (ADR-022) e o 005 (ADR-023) estão tratados; faltam 014 e 015
- [ ] **ADR-022:** as medições pendentes são a `sonda_pooler` contra o pooler da aplicação, o `pg` sob o Falcon em
  Ruby 4.0.9 com o adaptador Rack (hoje só medido em Ruby 3.3.6) e o custo dos registros no repositório real. O
  analisador do compilador ainda aceita `Sequel.connect`, `ActiveRecord::Base.connection` e `PG.connect` num
  `call`, e a ampliação decidida no ADR-022 não foi implementada
- [ ] **ADR-023:** o custo do contexto assinado foi medido só num protótipo descartável, no PostgreSQL 16.15, com um
  cliente e sem `WITH CHECK`, comparação em tempo constante, concorrência nem pooler; o gate da fase 1 (0,5 ms por
  instrução e 25% da latência do comando, hipóteses) está por medir no 17 e no 18. O gerador de políticas não
  existe, então a forma da política de escopo e o aviso do `db:plan` sobre o índice da tabela de vínculo ainda não
  estão implementados. A autenticação (como a credencial escolhe a empresa) não tem ADR
- [ ] **ADR-020:** como o trigger de instrução da revisão de autorização obtém o tenant em escritas sem contexto,
  como o preenchimento do `vetra_migrator`; custo da releitura de campos pessoais por grupo
- [ ] **Diagnósticos:** nada impede que um código de diagnóstico novo nasça sem teste. A medição por rastreio não
  faz parte do repositório

Limite documentado, sem ação prevista: os hashes não autenticam o pacote.

## 7. Próximos passos propostos

Ordem sugerida; cada passo é um PR, e o aceite só vale quando quem revisa o integra.

1. [ ] Fechar as lacunas declarativas da fase 0 e os critérios 6, 7 e 11, com os exemplos da proposta
2. [ ] Tratar, por ADR de resolução (um PR por ADR, um de cada vez), as questões em aberto dos ADRs aceitos 014 e
   015, que precisam estar tratadas antes de implementar a persistência. O 003 (ADR-022) e o 005 (ADR-023) já estão

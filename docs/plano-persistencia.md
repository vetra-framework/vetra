# Plano da persistência

A persistência transforma o grafo em banco PostgreSQL 17+, por plano versionado, com papéis, contexto
assinado e RLS. O mapeamento físico está no ADR-035 aceito; o bootstrap dos papéis globais e o contexto
assinado estão no [ADR-036](adr/036-papeis-e-contexto-assinado.md), também aceito. Responsáveis e decisões de auditoria ficam no [quadro dos agentes](tarefas-dos-agentes.md).
A rodada 3 levou cada exemplo de um banco vazio ao plano inicial aplicado; a rodada 4 fez esse banco evoluir e ser
usado pelo Vetra Data; a rodada 5 faz o Vetra Data executar operações com um executor parcial, sem histórico, auditoria nem adaptadores.

## Rodada 6: superfícies executáveis (planejada em 2026-11-12)

Planejada pelo Claude, por delegação do mantenedor, depois de uma reavaliação do projeto inteiro (abaixo), com o parecer do Codex incorporado (primeira rodada devolvida; as mudanças estão nas seções abaixo).

### Reavaliação do projeto (2026-11-12)

- **O que está sólido.** O núcleo declarativo (compilador, IR 0.6, diff e gate de compatibilidade, quatro exemplos), a camada de dados inteira (plano, RLS, contexto assinado, repositórios,
  outbox, relay, idempotência) e o executor parcial das oito etapas, com 808 testes, 259 códigos de diagnóstico exercitados, 32 arquivos `sonda_*.rb` (30 na matriz do PostgreSQL 17 e 18 da CI e dois manuais) e a CI verde. O protocolo de
  dois agentes funciona: a auditoria cruzada achou bloqueantes reais em todas as rodadas.
- **O que ainda não existe, e pesa mais.** (1) **Nenhuma superfície real**: o runtime só é alcançável por sondas, então não há requisição HTTP, comando de terminal, job nem webhook que o exercite, e
  os critérios 6 e 7 da fase 0 seguem parciais. (2) **O risco de desempenho do núcleo de segurança está aberto há duas rodadas**: o contexto assinado custa de 12% a 19% da latência com um cliente e, em estimativas de duas
  execuções distintas com 16 clientes (K20: 27% a 45%; K21, variante atual: 34% a 60%), bem mais no CRM com revendas; a
  construção dos registros fica em 38% a 44% da consulta (gate de 10%), e a decisão é do mantenedor. (3) **Dívida de decisão**: seis ADRs propostos (042, 044 a 048) sustentam código já integrado.
  (4) **Lacunas funcionais que as sondas da K20 expuseram**: `rate_limit:` sem contadores recusa a operação pública (o comentário do visitante do blog), `crm.win_lead` declara uma chave que a saída pessoal
  proíbe, o visitante do blog não lê nem o post publicado. (5) **Deriva documental**: o README ainda diz que a persistência e a execução não existem.
- **A estratégia que o ADR-010 pede.** Provar o Vetra num módulo real, hospedado. Antes do Rails, uma superfície **Rack sem dependência nova** prova o fluxo completo com HTTP de verdade e mostra onde o
  executor e o grafo ainda falham; o modo hospedado em Rails vem depois, sobre o mesmo adaptador.

### Objetivo e escopo

Ao fim da rodada, cada exposição que os exemplos declaram (`http`, `cli`, `job`, `webhook`) é alcançável por um adaptador que traduz a superfície para o `Runner`, resolve o ator e o tenant por uma credencial verificada (nunca por campos de identidade ou papéis não verificados do corpo, dos cabeçalhos ou dos parâmetros; a credencial em si, como `Authorization` ou o cookie de sessão, pode viajar em cabeçalho), extrai a chave de idempotência, traduz as três saídas de falha (ADR-007, §3) e chama o executor; e o limite de taxa por permissão tem contadores. A IR permanece 0.6.

**Os adaptadores desta rodada são experimentais e rodam sobre o executor parcial.** A etapa 7 do ADR-016 e o ADR-013 exigem histórico, auditoria e (para dado pessoal) cifra gravados junto dos dados, e o ADR-007 exige a
equivalência também do histórico: nada disso existe até a rodada 7. A rodada **não anuncia** as oito etapas completas nem a conformidade com o ADR-016; os adaptadores servem a uso restrito e a dados
descartáveis. Expor uma superfície pública com essas garantias depende da rodada 7 ou de uma exceção arquitetural **explícita do mantenedor**. O Claude propõe a exceção só se o mantenedor pedir.

**Reescopo em relação ao que a rodada 5 anunciou.** A rodada 5 reservou para a rodada 6 também a cifra dos campos pessoais, o histórico, a auditoria, o distribuidor do live, a fase contract e o modo hospedado em
Rails. Esta rodada fica com as superfícies, o contrato de identidade e os contadores, porque (a) as superfícies destravam a evidência (HTTP real, latência ponta a ponta, o critério 6) e não dependem da cifra;
(b) a cifra, o KMS, o histórico e a auditoria são um conjunto com o maior desconhecido do projeto e merecem rodada própria; (c) o modo hospedado precisa do adaptador pronto. **A conformidade integral com o ADR-016
passa à rodada 7.**

### Tarefas (uma por vez no checkout compartilhado, nesta ordem)

| ID | Tarefa | Responsável | Depende de |
|---|---|---|---|
| K22 | Documentação alinhada ao estado real: README (o runtime existe; IR 0.6), seções 5 a 7 da situação, gemspec e índice de ADRs; população das sondas e das medições dita com precisão | Claude | — |
| K23 | **Contrato da identidade e da borda pública** (ADR proposto): identidade, papéis e geração de atribuição coerentes; revogação; falha fechada; visitante explícito; identidade anônima estável, emitida e verificada; proibição de `system_actor` na entrada pública; autoridade entre processos (compartilhada ou limitada a um processo, com configuração que impede anunciar suporte distribuído) | Claude | K22 |
| K24 | Adaptador HTTP como aplicação Rack, sem dependência nova, sobre o contrato da K23: rota da IR para a operação, entrada de caminho, consulta e corpo JSON, perfis do `Runner` por rota, `Outcome` para HTTP, consultas só `GET`; requisitos da seção abaixo; ADR proposto | Claude | K23 |
| C17 | Contadores de `rate_limit:` (ADR-034), com o escopo da seção abaixo; ADR proposto | Codex | K24 |
| K25 | Incompatibilidade do `crm.win_lead` (chave exigida pelo job e pelo webhook, saída com e-mail): contrato de saída sem dado pessoal comum às superfícies, ou rotas declaradas pendentes da cifra; a recusa do executor é preservada. Se as rotas ficarem pendentes, a K27 prova a equivalência positiva (execução e replay pelas quatro superfícies) numa fixture descartável com saída não pessoal e quatro exposições, e distingue essa evidência das rotas dos exemplos que permanecerem pendentes | Claude | C17 |
| K26 | Adaptadores de CLI e de job sobre o mesmo núcleo, com a política de repetição por superfície | Claude | K25 |
| C18 | Adaptador de webhook: assinatura do provedor sobre os bytes originais, chave derivada do provedor, da conta e do evento, retenção compatível com as reentregas, verificação do carimbo de tempo assinado quando o provedor o oferece (com teste) e a limitação dos provedores sem esse mecanismo, porque assinatura válida e retenção não impedem reapresentar uma requisição capturada depois da purga da chave; ADR proposto | Codex | K24, K25 |
| K27 | Ponta a ponta por um servidor real nos quatro exemplos, equivalência entre as quatro superfícies, boot recusando IR ausente, adulterada ou incompatível (critério 6), medição da latência da superfície | Claude | K24, C17, K26, C18 |

Cada tarefa segue o protocolo (implementação sem commit, auditoria cruzada, decisão, commit e push, registro). Um ADR novo entra como `proposto`. A K24 pode rodar antes da C17 porque a ausência de contadores
**recusa** a operação limitada; liberar a operação limitada exige a C17 integrada.

### Requisitos que o parecer do Codex incorporou

- **Identidade (K23).** Campos de identidade ou papéis não verificados, vindos de cabeçalhos, parâmetros ou corpo, nunca atribuem autoridade; só a credencial verificada o faz. Os papéis recebidos vêm da mesma geração de atribuição que a borda lê (um papel antigo não acompanha uma geração nova). O visitante é uma identidade
  explícita, com identificador anônimo estável, emitido e verificado. `system_actor` não entra por uma superfície pública.
- **Autoridade entre processos (K23).** `InProcessAuthority` e a geração em memória dos exemplos de referência não observam outros processos; HTTP, CLI e workers separados ultrapassam esse limite. A rodada entrega a autoridade
  compartilhada ou limita a referência a um processo por uma configuração que recusa o modo distribuído.
- **Saída (K24).** O `Runner` não valida a saída do `call` contra o contrato em toda operação: sem chave, um valor fora do contrato volta como `ok` e só a serialização o recusa, depois do commit. Com chave de idempotência o `Runner` já valida na etapa 7 e termina `error` com ROLLBACK; **sem chave** termina `ok` com COMMIT. A K24 exige a validação **antes do COMMIT também sem chave**, no `Runner` e não no adaptador (que só descobriria depois de confirmar), para que uma resposta HTTP nunca diga sucesso sobre um valor inválido.
- **Entrada HTTP (K24).** Leitura do corpo limitada independentemente de `Content-Length`; limites de consulta, profundidade e quantidade de campos; JSON inválido, chaves duplicadas e conflitos entre caminho, consulta e corpo
  recusados; conversões pelo contrato, sem perda monetária; o servidor ou o proxy respondem por cabeçalhos e conexões lentas.
- **Credenciais e navegador (K24).** O modelo de credenciais é declarado; a proteção contra CSRF é do resolvedor quando há sessão, e o contrato a exige nos testes; CORS fechado por padrão, com origens explícitas; respostas pessoais e
  erros com cabeçalhos de cache que as impedem de ser guardadas.
- **Erros públicos (K24).** Resposta estável para registro inexistente ou invisível (404, sem diferenciar por diagnóstico interno), lista explícita de erros públicos sem valores, SQL, causas nem credenciais, e `Outcome` ganha o status de
  taxa excedida (429, com `Retry-After`), sem consulta ao banco pelo adaptador.
- **Tempo e custo (K24).** Perfis do `Runner` por rota, sem mutação compartilhada, e orçamento total que cobre o resolvedor, os fatos, as esperas de pool e de serialização, com cancelamento e limpeza seguros; o desfecho incerto de
  um timeout durante o COMMIT é documentado, e a recuperação é pela mesma chave **quando uma chave válida foi aceita**; sem ela (a idempotência das rotas HTTP atuais é opcional, e o `Runner` recusa chave para saída pessoal), um timeout depois de um possível commit deixa o resultado incerto e não autoriza repetição automática segura.
- **Retentabilidade (K24, K26, C18).** A política é por superfície e distingue a negação efetiva da indisponibilidade da infraestrutura (sempre recusando o acesso), com repetição limitada, falha definitiva e a resposta ao provedor; `retryable?`
  sozinho não decide.
- **Contadores (C17).** Janela móvel, reserva conjunta e consumo mesmo quando a execução posterior falha (ADR-034), com a reserva durável fora da transação reversível da operação; relógio do banco, concorrência, falha fechada,
  migração, privilégios, purga e continuidade entre builds; integração com o avaliador e com as guardas sem cobrar por linha nem de novo na etapa 6; regra de cobrança nas repetições internas; a dispensa de contador quando concessões sem
  limite já cobrem a autorização.
- **Idempotência ponta a ponta (K26, C18).** A chave é exigida conforme o nó `route`, antes do `Runner`; a derivação é estável por provedor, conta, evento e job, sem tentativa nem worker na chave; a retenção cobre as reentregas; os
  visitantes são isolados entre si (o principal nulo do registro atual não basta). A assinatura do webhook é verificada sobre os bytes originais antes da etapa 1 e vincula a credencial ao tenant. Concorrência, queda depois do commit e
  perda da resposta são testadas; **não se promete efeito externo exatamente uma vez**.
- **Testes (K24, K27).** `app.call(env)` direto, sem socket, para rotas opt-in, separação entre HTTP e webhook, entrada, erros e segurança; as quatro superfícies com a mesma identidade e a mesma entrada dão o mesmo estado, os mesmos eventos
  e o mesmo replay (ADR-007, teste de equivalência); boot recusando IR ausente, adulterada ou incompatível. O servidor da K27 é um servidor de teste mínimo em biblioteca padrão dentro da sonda: nenhuma dependência nova de runtime.
- **Achados de modelo (K25).** Correção de incompatibilidade é diferente de mudança de produto: onde não há requisito para conceder acesso, a recusa fica (o papel do chat não concede `delete` de sala). A leitura pública do blog e os
  campos expostos (o comentário inclui e-mail) são revisados explicitamente, sem ampliar permissão só para a sonda passar; mudança intencional vai ao gate com o motivo.

### Decisões do mantenedor que a rodada não espera

A saída para o custo da `vt_system`, se o resultado com 16 clientes reabre o ADR-005, o orçamento do gate de 10%, o aceite dos ADRs propostos e o teste 6 do ADR-023 continuam com o mantenedor e **não bloqueiam** nenhuma tarefa
desta rodada. O que a rodada propõe em ADR: o contrato de identidade e da borda pública (a `auth` como DSL segue fora) e o formato do limite de taxa. Os percentuais de contexto são **estimativas de execuções distintas**, não latência
HTTP medida com 16 clientes, e a medição dos registros é a do repositório, sem guarda nem fechamento.

### Fica para a rodada 7 e depois

Cifra dos campos pessoais (ADR-013), histórico, auditoria e a conformidade integral com o ADR-016 (rodada 7), com a **composição de comandos pelo `call`** (savepoint, ADR-016; o bloco só enxerga `fail!`) e o executor das capacidades determinísticas além de `core.clock` (`uuid`, `random`; o `Runner` as recusa; as externas já rodam nos handlers, e o ADR-004 as proíbe nos comandos), lacunas que a auditoria da K22 expôs; a **declaração de titular (`subject`) e a evolução da IR que ela pede são dependências da cifra** e entram na rodada 7, com o destino da
retenção (`retention`) esclarecido. Distribuidor do live e fase contract (`vetra.instances`, `vetra.schema_state`) na rodada 8, e o modo hospedado em Rails também; **adiar o Rails preserva o risco de adoção, não o resolve**, e o
Rack isolado não verifica a transação compartilhada com o Rails (ADR-010). Fora do escopo, sem perda: servidor próprio de produção, fila própria, vários provedores de webhook, streaming e ampliação de permissões; um adaptador injetável e uma
fixture de assinatura bastam. Sem rodada ainda: `auth`, moeda por tenant e políticas por atributo do ator.

## Rodada 5: decisões da K13, ator de sistema, idempotência, autorização e executor parcial

### Objetivo

Entregar um **executor parcial** do [ADR-016](adr/016-ciclo-de-vida-da-operacao.md) e as peças de que ele depende. A
rodada tem duas fases. Na **fase A**, as fundações, que não dependem do executor: as duas decisões que a medição da
K13 deixou acima do limiar, o ator de sistema, a idempotência e a autorização em Ruby. Na **fase B**, o executor e os
handlers de sistema, que o Claude **replaneja ao fim da fase A**, porque as decisões e as auditorias da fase A mudam
o que a fase B constrói.

Ao fim da rodada, um comando passa pelo executor contra o PostgreSQL 17 e 18, nos quatro exemplos, por um chamador
interno confiável que resolve o comando, o ator, os papéis e a chave de idempotência: a entrada é validada pelo
contrato, a política `authorize` é avaliada em Ruby, o `call` roda numa unidade de trabalho com as capacidades
autorizadas, o estado final é reautorizado, os eventos do `emits` entram na outbox sem que o `call` os grave, a chave
de idempotência é registrada na mesma transação, e um handler de um evento roda como o **ator de sistema** do tenant
do evento, com a autoridade dos seus `calls`.

**O que a rodada não cumpre do ADR-016, de propósito.** A etapa 7 grava só os eventos: o **histórico e a auditoria**
não existem, e dependem da cifra dos campos pessoais (ADR-013), que fica na rodada 6. Sem a cifra, a outbox continua
recusando payload com campo pessoal (ADR-040, §2). A etapa 1 não tem adaptador: um chamador interno confiável a
resolve. Os testes de aceitação do ADR-016 e do ADR-014 que dependem de histórico, de auditoria ou de adaptador ficam
explicitamente pendentes, e a **conformidade integral com o ADR-016 é da rodada 6**; esta rodada não a anuncia. A IR
permanece 0.6.

**Fica para a rodada 6** (cada item tem dependência própria): os adaptadores HTTP, CLI, job e webhook; a cifra dos
campos pessoais, o histórico e a auditoria; o distribuidor do live; a fase contract e `vetra.instances` e
`vetra.schema_state`; os contadores de `rate_limit:`; o modo hospedado em Rails.

### Entregas e dependências

As tarefas rodam nesta ordem, uma por vez no checkout compartilhado; a sonda de cada entrega do Codex roda com o
Claude, porque o sandbox do Codex não alcança o PostgreSQL. A numeração dos planos de banco segue o que for
efetivamente integrado, não a ordem desta tabela.

| Tarefa | Implementador | Dependência | Entrega |
|---|---|---|---|
| **Fase A** | | | |
| K14 — forma da política de escopo | Claude | K13 | ADR-041 proposto. Mede a **escrita** que a K13 não mediu, por ação: `INSERT` (`WITH CHECK`), `UPDATE` (`USING` e `WITH CHECK`) e `DELETE` (`USING`), com 1 milhão de vínculos, e compara as **permissões** por ação para gerente, vendedor, ator de papéis mistos e ator sem vínculos. Avalia as três formas: a gerada, a lista do ator calculada uma vez por instrução e a tabela materializada que o ADR-023 pede para avaliar. Se a forma nova valer, o gerador muda e os dois CRMs ganham um plano de troca atômica das políticas (C9), com a sonda de RLS refeita |
| C11 — construção dos registros | Codex | K13 | [ADR-042 proposto](adr/042-construcao-dos-registros.md): conversão imediata de leitura implementada, sem repetir validações garantidas pelo DDL nem a cópia de valores já imutáveis; monta `Money`, JSON e UTC e preserva as invariantes residuais de `Values`. Registros compartilháveis, predicados e entrada estrita preservados. Medição Ruby compara a C10, a leitura dedicada, a construção sob demanda com acesso completo e o piso de `Data.new`. A sonda mede construção diretamente sobre as linhas consultadas, mantendo o limiar de 10%; execução no 17/18 pelo Claude, aceite e decisão do orçamento pelo mantenedor pendentes |
| C12 — colisão de nomes no compilador — feita | Codex | — | `graph:build` e `graph:check` recusam campos e predicados de grupos de enum que colidem com métodos reservados do registro `Data`, com `field_name_collides_with_record`, ponteiro e sugestão de renomear. Compilador e `Repositories.new` compartilham a reserva: públicos e protegidos, privados cujo dono não é `Kernel` e ganchos privados do `Kernel` chamados pelo Ruby/Data no registro; as demais funções privadas do `Kernel` são aceitas. Ancestrais, visibilidade e dono são consultados a cada checagem; o runtime mantém `data_record_type` como defesa. IR 0.6, quatro grafos e planos preservados |
| K15 — ator de sistema | Claude | K14 | Implementa o [ADR-024](adr/024-resolucao-das-questoes-do-adr-014.md), §4, **só nas aplicações com tenant**: a claim `system_actor` no contexto assinado, `vetra.is_system_actor()` e a condição permissiva nas políticas de escopo, com o isolamento de tenant ainda `RESTRICTIVE`; um visitante não é ator de sistema. Inclui o que a C9 não entrega: a **tradução incremental** das rotinas de contexto (o `Differ` hoje recusa função nova ou alterada, e a exceção do ADR-036 reconhece só as funções atuais, de retorno `uuid`), a atualização estrita das guardas, o `Context` e a `UnitOfWork` aceitando `system_actor` sem `actor_id` num contexto de tenant, a convergência dos quatro exemplos (blog e chat não mudam) e testes de adulteração |
| K16 — idempotência da operação | Claude | K15 | ADR-043 proposto. `vetra.idempotency` nos quatro exemplos, com chave única por `(tenant, comando, chave)`, hash da entrada e resultado serializado. O ADR escolhe uma representação que valha para o **contexto global**, em que o tenant é nulo (blog e chat), sem inventar um tenant sentinela: por exemplo `UNIQUE NULLS NOT DISTINCT`. Decide privilégios e RLS, o limite do resultado guardado, a **retenção por origem** (as chaves de adaptador, 24 horas; as derivadas de um evento, enquanto a entrega existir, inclusive as `dead`) e **quem purga** nas aplicações sem outbox, como o chat. Testes de concorrência e de rollback; o `Differ` ganha a tradução da tabela e da rotina de purga |
| C13 — entrada e autorização em Ruby | Codex | C10 | [ADR-044 proposto](adr/044-entrada-e-autorizacao-em-ruby.md). `Vetra::Execution` valida a entrada com `Values` e avalia papel, escopo, registro referenciado e campos antes da unidade. Recebe fatos imutáveis da borda confiável, vinculados a catálogo/ator/tenant e revisão corrente, com recusa de fatos obsoletos ou incompletos. `uses` não concede leitura implícita; papéis vêm exclusivamente da borda. Concessões dependentes de `rate_limit:` e contextos de sistema são recusados com códigos próprios. Testes usam os quatro grafos; sonda de concordância Ruby/RLS do CRM com revendas e contagem de transações escrita, com execução 17/18 e inclusão na CI pelo Claude. Banco, modelos, retratos e IR 0.6 preservados |
| P5 — replanejamento da fase B | Claude | C13, K16 e o resto da fase A | Marco, não código: o Claude entrega o plano revisado da fase B com o que as decisões e as auditorias da fase A mudaram, o Codex o audita em modo somente leitura, o Claude decide os achados e o integra, e só então a K17 começa. O parecer atual não vale antecipadamente para o conteúdo replanejado, e o [AGENTS.md](../AGENTS.md) segue valendo: entrega, árvore congelada, auditoria cruzada e decisão |
| **Fase B** (replanejada na P5, 2026-11-10; veja [o replanejamento](#replanejamento-da-fase-b-p5)) | | | |
| C15 — limites da unidade e proteção do `xmin` | Codex | C13 | `UnitOfWork#transaction` ganha `statement_timeout:`, `lock_timeout:` e `isolation:` por operação (`READ COMMITTED` por padrão; `SERIALIZABLE` só por opção), aplicados com `SET LOCAL` na transação mais externa, junto do contexto e nunca dentro de um savepoint, e recusa valor fora de faixa. `transaction_timeout` e `idle_in_transaction_session_timeout` (ADR-008, §5; 30 s e 10 s como valores propostos) são parâmetros do papel `vetra_app` no bootstrap operacional, nunca num plano; um verificador (`Vetra::Data::Limits`) lê o valor efetivo na abertura e recusa a unidade quando falta. Sonda no PostgreSQL 17/18 (execução pelo Claude): a transação que passa do limite é encerrada, o `xmin` volta a avançar e o relay entrega o que estava atrás dela. Corrige também `Repository#execute`, que hoje converte `55P03` (`lock_timeout`) e `57014` (`statement_timeout`) no mesmo `data_database` genérico: os dois passam a erros próprios e retentáveis, sem SQL nem mensagem do driver, a unidade os desfaz por inteiro, e o mapeamento para 409 e para a resposta retentável é da K19 (o ADR-016 exige rollback e erro retentável). Testes sem banco e sonda com os dois estouros. Sem banco novo, plano novo nem IR nova |
| K17 — executor I: borda, despacho e primitivas | Claude | C15 | ADR-045 proposto: a borda interna e a autoridade de revisão que o ADR-044, §1 deixou para a borda. `Vetra::Execution::Runner` com as etapas 1 a 5 e 8 como passos nomeados, para que as tarefas seguintes preencham as etapas 4, 6 e 7 sem reescrever o despacho. A **borda** é um contrato com três colaboradores injetados (resolução de identidade, tenant, papéis e chave; provedor de `Snapshot`; autoridade de `current_revision`) e uma implementação de referência, em `lib/`, para as sondas e para uso local: o provedor lê pelo banco numa **conexão própria, fora do pool da operação**, e a autoridade é, nos CRMs, o marcador composto `[revisão de vetra.authz_revisions, geração da identidade]`, lido numa só instrução e com a geração da identidade entregue pela borda para as mudanças externas de papéis (SSO), e, em blog e chat, uma geração **em processo**, que o `Runner` publica depois do commit de todo comando que grava uma entidade percorrida por alguma política ou uma atribuição de papel (derivado da IR) e que a borda publica quando uma atribuição muda fora do `Runner`. A geração em processo vale para **um** processo: escritas de outro processo não a movem, e o ADR-045 diz isso, sem fingir que a detecta. Autoridade ausente, divergente ou fora do ar recusa (`data_authorization_snapshot`). Vincula as capacidades do `uses` e executa as primitivas CRUD e de vínculo; o descritor do linker deixa de dizer `executor: "pending"` (cinco testes e dois guias mudam, a IR não). Documenta o limite da composição: o `cmd` externo é mantido nos savepoints, e um comando composto não empresta a autoridade de transição de outro (ADR-039). Sonda: um comando de cada exemplo pelo `Runner`, no 17 e no 18, em contexto de tenant e global, ainda sem eventos nem idempotência; a contagem de transações sai em **duas**, a da operação (zero nas recusas) e a do provedor (que não é zero). A sonda exige também o contrato de invalidação do ADR-044, §1: depois do commit que muda um papel ou um vínculo o marcador avança e o snapshot antigo é recusado; a revogação durante a admissão recusa pela segunda conferência; e a autoridade ausente, divergente ou fora do ar recusa sem transportar a exceção |
| C16 — `many_to_many` no avaliador | Codex | C13 | Estende `Execution::Predicate` e `Snapshot` ao `exists` por `many_to_many` (a junção com as duas chaves e o filtro de tenant a cada salto), que o chat usa em três das suas seis políticas (`members`: ler sala, ler e criar mensagem) e que a C13 recusa. Sem isso o chat só executa criar sala, apagar a própria mensagem e administrar membros. Emenda o ADR-044, ainda proposto. O chat não tem RLS (ADR-031), então a sonda compara a decisão Ruby com o `EXISTS` equivalente escrito à mão sobre as mesmas linhas (membro, não membro, dono, outra sala); execução pelo Claude. Sem banco, plano nem IR novos |
| K18 — executor II: autorização nos acessos | Claude | K15, K17, C16 | Aplica a autorização aos **acessos dos repositórios**, que hoje (`Repository#execute`) verificam só capacidade de escrita, unidade e tenant: leituras, escritas e registros além do principal, por ação, registro e campo (o `uses` não concede dados, ADR-044, §2, então `chat.add_member_by_email` **recusa**, e isso é o resultado esperado). Traz o **coletor de fatos dentro da unidade**, que o plano anterior não previa: o `Snapshot` da C13 é a única entrada do avaliador, e a reautorização do estado final (etapa 6) precisa de fatos lidos na mesma transação, derivados do percurso das políticas. O ramo de sistema aplica os `calls` nas etapas 3 e 6, como o ADR-024 manda, e a C13 deixa de recusar o contexto de sistema só nesse ramo. Estende a sonda de concordância Ruby/RLS com a troca de revenda no `update` (teste 4 do ADR-016) e com sondas de registros adicionais, campos e consultas globais, inclusive no blog e no chat, que não têm RLS e dependem só disto |
| K19 — executor III: fechamento transacional | Claude | K16, K18 | Os eventos do `emits` entram na etapa 7 sem que o `call` os grave; a idempotência na etapa 4: o `Runner` passa o `Claim` emitido por `claim!` ao `complete!` **na mesma unidade** (a biblioteca recusa qualquer outro objeto), e cada nova tentativa reemite o claim. `data_idempotency_key_reuse` vira 422 e `Conflict(:lock_timeout)`, 409; `fail!` vira 422, conflito 409 e erro inesperado 500; o ADR da tarefa decide o código de `data_idempotency_result` (resultado acima de 64 KiB). Um comando cuja saída leva campo pessoal e que recebe chave é **recusado antes da etapa 4**, porque o resultado não pode ser guardado em claro (ADR-043, §4). A **repetição** (no máximo 3, com espera crescente) de falha de serialização ou deadlock repete a operação externa inteira, depois do rollback, e só quando **nenhuma capacidade é `retry_safe: false` e o comando não declara `unsafe_effect`** (ADRs 004, §5, e 022, §6); as três tentativas internas do `claim!` não são essa repetição. Sondas de deadlock e serialização, sem evento duplicado, e a recusa da repetição com `unsafe_effect` |
| C14 — handlers de sistema | Codex | K19 | O runner que reserva as entregas pelo `Relay`, monta o contexto do ator de sistema do tenant do evento e roda o `call` do handler, que só chama os comandos de `calls`, pelo executor. O runner impõe o **timeout total do handler** (30 s por padrão, com lease de 60 s, ADR-024, §1), que nem os timeouts das capacidades nem os das instruções SQL substituem. A chave de idempotência do comando é **derivada do handler e do `event_id`** (por exemplo `<handler>:<event_id>`, dentro dos 255 caracteres ASCII do ADR-043), com principal `system:<handler>` e origem `event` (só em aplicação com outbox), e passada ao provedor. A unicidade é `(tenant, comando, chave)` e o principal não a separa: uma chave só do `event_id` faria dois handlers do mesmo evento que chamam o mesmo comando colidirem em `data_idempotency_key_reuse`, então a fixture tem **dois handlers** no mesmo evento chamando o mesmo comando, e o teste os exige distintos; o despachante do Effect Boundary é desta tarefa. Os dois handlers dos exemplos (`notify_sales` e `notify_seller`, ambos em aplicações com tenant) têm `calls: []`, então a tarefa traz uma fixture com tenant e um handler que realmente chama um comando; blog e chat não têm ator de sistema (ADR-024, §4). O `graph:diff` já classifica `calls` como permissão (`lib/vetra/graph/diff.rb`): a tarefa só o confere. Testes: queda depois do commit do comando e antes da conclusão da entrega, repetição do evento sem repetir a escrita, o provedor simulado recebendo a mesma chave, comando fora de `calls` recusado, expiração do timeout total com recuperação por outro worker, e a retenção das chaves derivadas de um evento enquanto a entrega existir, inclusive `dead`. O **reprocessamento** de uma entrega `dead` (comando explícito e auditado, ADR-014, §4) é da rodada 6, porque pede a auditoria |
| K20 — ponta a ponta e medição por comando | Claude | C14 | Sonda dos quatro exemplos pelo executor, com o handler de sistema e o relay, no 17 e no 18, na CI. Os casos esperados incluem as **recusas que a rodada assume**: `chat.add_member_by_email` (sem concessão de `users_read`) e o comentário do visitante no blog (`rate_limit:` sem contador). Refaz a medição do ADR-023 com o executor: o percentual da latência de cada comando de referência, a contagem das validações de contexto por instrução, o **custo da escrita em `vetra.idempotency`** (o mesmo comando com e sem chave, que o ADR-043 deixou para esta medição, porque a latência total não o isola), o ator comum **com e sem** a condição `vt_system` (o custo que a K15 deixou à decisão do mantenedor), a construção dos registros contra o gate de 10% do ADR-022 e o pooler transacional, que a K13 deixou de fora. O teste 1 do ADR-016 é relatado com as duas contagens da K17 e não como "zero transações do fluxo". O teste de aceitação 6 do ADR-023 **continua pendente**: relatar percentuais não o cumpre, e os limiares não mudam para acomodar um resultado. Qualquer mudança de contrato desse teste é decisão formal do mantenedor |

### Replanejamento da fase B (P5)

Escrito pelo Claude em 2026-11-10, com a fase A integrada (K14, C11, C12, K15, K16 e C13, todas com a CI verde), para o
parecer do Codex. O plano anterior da fase B vale só onde esta seção não o muda.

**O que a fase A mudou.**

| Resultado da fase A | Efeito na fase B |
|---|---|
| **C13 e ADR-044 (proposto):** o avaliador não abre transação e só vê os fatos que a borda entrega, com a revisão confirmada fora do pool da operação | A K17 passa a conter a **borda** (contrato, implementação de referência e ADR-045). A K18 ganha o **coletor de fatos dentro da unidade**: a reautorização do estado final precisa de fatos lidos na mesma transação, e o `Snapshot` é a única entrada do avaliador |
| O ADR-044 lê o teste 1 do ADR-016 como "zero transações **da operação**": quem resolve os fatos no banco por chamada paga essa transação antes da admissão | A K17 mede duas contagens e a K20 as relata; nenhuma tarefa anuncia "zero transações do fluxo". O aceite do ADR-044 **não bloqueia** a fase B: o provedor de fatos é injetável, e se o mantenedor preferir a transação curta de leitura (alternativa 1 do ADR) a implementação troca o provedor, mas a decisão também revê a etapa 3 e o teste 1, e a medição os refaz: a injeção reduz o retrabalho, não o elimina |
| O avaliador recusa de forma fechada o que está fora do subconjunto, e três das seis políticas do chat (ler sala, ler e criar mensagem) dependem de `members` (`many_to_many`) | Nova **C16** antes da K18. Sem ela o chat ponta a ponta se reduz a criar sala, apagar a própria mensagem e administrar membros |
| `uses` não concede dados (ADR-044, §2) | `chat.add_member_by_email` **recusa** na K18, e a K20 o conta como resultado esperado; tornar o caso executável é uma decisão de modelo para a rodada 6 |
| `rate_limit:` sem contador recusa com `data_authorization_rate_limit` | O comentário do visitante no blog recusa na K20 (esperado); os contadores são da rodada 6 |
| K15: a condição `vt_system` encarece o ator comum (cada referência a função de contexto revalida o token) e a C13 recusa o contexto de sistema | A K18 habilita o ramo de sistema só pelos `calls`; a K20 mede o ator comum com e sem a condição. A saída (função única de contexto ou papel de banco próprio) é decisão do mantenedor, tomada com esses números |
| K16: o claim é um objeto emitido na unidade e conferido por identidade; o resultado tem teto de 64 KiB e não guarda campo pessoal; a origem `event` só existe com outbox | A K19 passa o claim pela unidade, trata o resultado acima do teto e recusa antes da etapa 4 o comando com saída pessoal e chave; a C14 usa a origem `event` só nas aplicações com outbox |
| K14 e K15: a política de escopo é a forma lista e a sonda de concordância Ruby/RLS (68 verificações) é a rede de proteção | A K18 estende essa sonda (troca de revenda no `update`, registros adicionais) em vez de criar outra |
| C11: a construção dos registros caiu para 40%–56% da consulta, ainda acima do gate de 10% | A K20 remede com o executor e relata; o limiar só muda por decisão do mantenedor (ADR-042) |
| ADR-024, §4, decisão 4: o `graph:diff` já trata `calls` como permissão | A C14 só confere; não reimplementa |

**Por que esta ordem.** C15 antes da K17, porque o `Runner` aplica os limites por operação. K17 antes da C16 e da K18,
porque a K18 precisa do despacho e do contrato de fatos. C16 antes da K18, porque a sonda do chat depende dela. K19
depois da K18, porque o fechamento reautoriza o estado final. C14 depois da K19, porque o handler é uma operação com
idempotência derivada. K20 por último. Cada tarefa roda uma por vez e passa pelo protocolo do [AGENTS.md](../AGENTS.md);
as do Codex são auditadas pelo Claude, e as do Claude pelo Codex. A fase B não gera plano de banco por si: um plano
novo só vem se o mantenedor decidir a saída da `vt_system`, e então entra como tarefa própria, uma integração por
aplicação.

**O que a fase B espera do mantenedor.** Nada disto bloqueia uma tarefa; cada item tem o ponto em que passa a bloquear.

| Decisão | Recomendação do Claude | Passa a bloquear |
|---|---|---|
| Aceite do ADR-044 e do que ele muda no teste 1 do ADR-016 | Aceitar, com as duas contagens relatadas | O fechamento da fase B; os adaptadores da rodada 6 |
| Saída para o custo da `vt_system` | Decidir com os números da K20, depois de medir | O fechamento da K20 |
| Aceite do ADR-042 e orçamento do gate de 10% | Decidir com a medição da K20 | O fechamento da K20 |
| Modelo da leitura de `chat.user` pelo `add_member_by_email` | Rodada 6 | Nada nesta rodada |
| Teste 6 do ADR-023 | Continua pendente | Nada nesta rodada |

**Riscos novos.**

- **A autoridade de revisão de referência vale para um processo.** Em blog e chat ela é uma geração em memória, que o ADR-044 só aceita
  como contrato da borda; a distribuída fica para o modo hospedado e os adaptadores. O ADR-045 diz isso e a K17 não a vende como
  solução multiprocesso.
- **O provedor de referência abre uma transação.** Ele lê pelo banco, e a sonda deve mostrar essa contagem separada da operação; esconder
  essa leitura dentro do avaliador contraria o ADR-044.
- **A C16 amplia um ADR proposto.** A emenda ao ADR-044 entra na entrega e na auditoria; o ADR segue proposto.
- **`transaction_timeout` por papel.** O valor vem do bootstrap operacional, fora do plano; a conferência da C15 recusa a unidade se ele
  faltar, e a sonda prova o encerramento. Um ambiente sem o parâmetro não executa operações, e isso é intencional.
- **Tamanho da K18.** Concentra o coletor, os acessos e o ramo de sistema. Se a auditoria da K17 mostrar que o contrato de fatos ainda se
  mexe, a K18 se divide em K18a (coletor e acessos) e K18b (ramo de sistema) antes de começar, com novo parecer.

**O que a rodada continua não cumprindo do ADR-016.** O histórico e a auditoria (etapa 7), o adaptador (etapa 1) e os testes de aceitação 1, 2 e 10 em sua forma integral: o teste 1 fica com as duas contagens, o 2 sem o histórico (a parte de dados, evento e idempotência é verificada nesta rodada) e o 10 com os adaptadores da rodada 6.

### Decisões que a rodada precisa tomar

Cada decisão entra como ADR `proposto` na tarefa que a implementa e é aceita depois da auditoria, como nas rodadas
anteriores. Nenhuma muda o formato da IR.

- **ADR-041 (K14), forma da política de escopo.** A K13 mediu só leitura: a política gerada acrescentou de 0,8 a
  2,8 ms por instrução com 1 milhão de vínculos (limiar de 1 ms), e a forma com a lista do ator ficou entre −0,6 e
  +1,8 ms, em torno do limiar com 100 revendas no 18. O ADR decide com a escrita medida por ação e as permissões
  comparadas, e a escolha altera a política de todas as tabelas com escopo por vínculo.
- **ADR-042 (C11), construção dos registros.** A construção custou de 72% a 193% da consulta, contra um limiar de 10%.
  A conversão imediata de leitura foi escolhida após medir também a construção sob demanda em Ruby; os números e
  as alternativas estão no [ADR proposto](adr/042-construcao-dos-registros.md). No PostgreSQL 17 e 18 a construção
  caiu de 136%-167% para 40%-56% da consulta, ainda acima dos 10%. Esse gate permanece aberto até a decisão do mantenedor; um
  orçamento absoluto é proposta, sem alterar silenciosamente o critério. A C11 não muda banco, planos nem IR.
- **ADR-043 (K16), idempotência da operação.** O ADR-016 descreve o contrato, mas não o esquema, o contexto global, a
  retenção por origem nem quem purga onde não há outbox.
- **ADR-044 proposto (C13), autorização em Ruby.** Implementado o avaliador com fatos resolvidos antes da operação e
  confirmação autoritativa da revisão, `uses` sem concessão implícita de dados e papéis atribuídos pela borda. O
  aceite é do mantenedor. A K17 integra o provedor de fatos/revisão; a K18 aplica a autorização aos acessos e ao
  estado final. O acesso adicional a `chat.users_read` permanece sem concessão no grafo atual e deverá recusar na
  K18; as políticas de `many_to_many` passaram a ser avaliadas na C16. A IR 0.6 só admite
  contratos estruturados em saídas de consultas; a C13 os valida recursivamente sem estendê-los à entrada de comandos.
- **O teste 6 do ADR-023 (K20).** Fica pendente; só o mantenedor pode alterar o seu contrato.

### Riscos e verificações

- **Duas tarefas mudam as políticas de escopo (K14 e K15).** A K15 depende da K14, e cada uma entra numa integração
  própria: o gate recusa mais de um plano novo por aplicação por integração.
- **Autorização em Ruby contra o RLS.** Avaliar a política em Ruby pode divergir do RLS do banco; a sonda confere os
  dois lados nos mesmos casos de CRUD, por tenant, ator e revenda. A C13 recusa o contexto de sistema; seu caminho
  por `calls` é da K18. No blog e no chat, que não têm RLS, a autorização do executor é a única barreira; a K18
  as cobre com sondas próprias. A autenticidade e a invalidação dos fatos são obrigações operacionais da borda:
  um TTL ou NOTIFY eventualmente consistente não confirma revisão corrente (ADR-044).
- **O executor é o primeiro uso do contexto assinado fora de sondas.** A K20 mede o custo por instrução dos comandos
  reais, e uma regressão acima do limiar da K13 volta como achado, não como ajuste silencioso.
- **Repetição de operação.** Só é segura sem efeito externo; as duas condições (`retry_safe` e `unsafe_effect`) são
  checadas, e a sonda força uma falha de serialização para provar as duas saídas.
- **A idempotência é uma tabela nova com crescimento.** A retenção e a purga entram no ADR-043, e a purga não pode
  depender de a aplicação ter outbox.
- **Sondas.** Cada entrega do Codex roda no PostgreSQL 17 e 18 com o Claude; mudança de SQL exige suíte, grafos, gate e
  a sonda afetada, como nas regras abaixo.

## Rodada 4: plano incremental, repositórios e outbox

### Objetivo

Um banco que já recebeu o plano inicial recebe as mudanças do modelo por planos incrementais seguros (ADR-015 e
ADR-025), e o Vetra Data lê e grava nele como `vetra_app`. O código Ruby emite o contexto assinado, os
repositórios gerados fazem as leituras e as gravações, e os eventos entram na outbox na mesma transação (ADR-003 e
ADR-022, ADR-014 e ADR-024, ADR-008). Ao fim da rodada:

- os três exemplos com eventos (blog e os dois CRMs) recebem um `0002` com a outbox, gerado pelo plano
  incremental e aplicado por `db:migrate` sobre o banco da rodada 3;
- uma sonda grava pelos repositórios numa unidade de trabalho e emite o evento; o relay materializa as entregas e
  as leva a consumidores simulados, no PostgreSQL 17 e 18. Os handlers reais, com o ator de sistema e os comandos
  dos `calls`, dependem do executor da rodada 5;
- o custo do contexto assinado por instrução tem uma medição preliminar, na matriz do ADR-023. A medição por
  comando volta com o executor (rodada 5, K20); o gate do teste de aceitação 6 do ADR-023 continua pendente.

A IR permanece 0.6: nada desta rodada muda o formato do grafo.

### Entregas e dependências

As tarefas rodam nesta ordem, uma por vez no checkout compartilhado:

| Tarefa | Implementador | Dependência | Entrega |
|---|---|---|---|
| K9 — fundação do plano incremental | Claude | — | ADR-038 aceito. Modelo físico versionado e vinculado a cada plano, com formato próprio e versão, gerado e nunca editado à mão. Modo de transação por passo no formato do plano, e executor descartável que aplica passos fora de transação. Cadeia dos planos, filtro de instruções globais, aplicação como `vetra_migrator` e catálogo de papéis conferido, no lugar da regeneração dos planos antigos (ver as decisões abaixo). `--check` com N planos e convergência; diferenças aditivas pelo consumidor da C9 |
| C8 — unidade de trabalho e contexto emitido | Codex | — | Implementados a unidade de trabalho e o emissor Ruby, conforme o [ADR-039](adr/039-unidade-de-trabalho-e-repositorios.md): transação externa, savepoints, `read_only`, guarda por fibra e contexto global sem token nem tenant fictício. `sequel` e `pg` são dependências de runtime com janela `~>`, sem carga no compilador. Sonda escrita para auditoria do Claude no 17/18; [guia](vetra-data.md) |
| C9 — diferenças aditivas | Codex | K9 | Implementada a diferença entre o modelo versionado e a IR, em passos expand classificados: tabela nova, coluna anulável, coluna `NOT NULL` com default constante, índice `CONCURRENTLY` fora de transação, índice único de apoio antes da FK composta, FK `NOT VALID` seguida de `VALIDATE`, `CHECK` de `enum` alargado e troca atômica de política. As demais mudanças são recusadas com código próprio, sem plano parcial. `db:plan` grava `NNNN_expand.sql` e o modelo, com nome e conteúdo determinísticos; atualiza o espelho completo da segurança atual. A sonda `sonda_plano_aditivo.rb` cobre 13 cenários, dados, convergência e escrita concorrente em 1 milhão de linhas (99 verificações esperadas). Execução e inclusão na CI pelo Claude no 17/18; [guia](db-plan.md) |
| K10 — `db:migrate` incremental | Claude | K9 e C9 | Progresso por passo em `vetra.migration_steps`, com a linha do plano em `vetra.migrations` junto do último passo, passos fora de transação, `lock_timeout` e novas tentativas por passo. A base de cada plano é conferida antes de aplicá-lo, e a execução retoma do passo seguinte ao último concluído, conferindo o estado intermediário. A sonda interrompe em cada passo, inclusive depois de um DDL fora de transação e antes do registro, com o índice válido ainda não registrado e com o índice inválido |
| C10 — repositórios gerados | Codex | C8 | Implementados `Repositories.new(document)` e `bind(capability_id, unit:)`, com um repositório e um `Data` imutável por entidade. Operações de registro, locks, vínculos idempotentes, `include_on_create` e consulta restrita passam pela guarda da unidade. Tenant vem do contexto; defaults, downcase, slug e created_at seguem ADR-035/027. Capacidade e unidade somente leitura recusam escrita; transições conferem OLD do banco e cmd. Erros públicos não carregam SQL/valores do driver. A sonda `sonda_repositorios.rb` executa os corpos reais dos quatro exemplos, inclusive concorrência de vínculos, com 72/72 verificações no 17/18 da CI. [Contrato e resultados](vetra-data.md#sonda-dos-repositórios) |
| K11 — outbox: armazenamento e emissão | Claude | K10 e C8 | Implementado conforme o [ADR-040](adr/040-papeis-e-rls-da-outbox.md), aceito: `vetra.outbox` e `vetra.deliveries` particionadas por tempo, com partição `DEFAULT`, e `vetra.dead_deliveries`, no `0002_expand` do blog, do mini CRM e do CRM com revendas, criado pelo plano incremental num passo. A aplicação só insere, por coluna e com o tenant e o ator do contexto; `created_at`, `xid8` e `seq` vêm do banco. `Repositories#emit!` grava os eventos do comando com o payload projetado; um campo pessoal desfaz a unidade inteira. Sonda `sonda_outbox.rb` com 36 verificações. [Guia](vetra-data.md#emissão-de-eventos) |
| K12 — relay, entregas e manutenção | Claude | K11 | Implementado conforme o [ADR-040](adr/040-papeis-e-rls-da-outbox.md), §§ 3 e 4: `vetra_relay` no bootstrap, e o `0003_expand` dos três exemplos com eventos traz a guarda do papel, o checkpoint, as políticas e concessões do relay e a rotina `vetra.outbox_maintain`. `Vetra::Data::Relay` faz o relay por faixas de `xid8`, a reserva por lease, as tentativas e a entrega morta, com consumidores simulados; a manutenção cria, recupera e purga as partições, e a deriva só aceita as idênticas à `DEFAULT`. Sonda `sonda_relay.rb` com 38 verificações. [Guia](vetra-data.md#relay-entregas-e-manutenção) |
| K13 — custo do contexto, medição preliminar | Claude | C10 | Medição **informativa** pela sonda `sonda_custo_contexto.rb` no 17 e no 18, com 16 clientes, 3 rodadas alternadas e os papéis de produção ([relatório](sondas/custo-contexto.md)); não cumpre o teste de aceitação 6 do ADR-023, que exige falhar acima do limiar, e esse gate continua pendente. O contexto assinado acrescenta de 0,2 a 0,4 ms por instrução na maior parte das rodadas, abaixo do limiar de 0,5 ms, mas com três de doze estimativas acima no 18 (inconclusivo). Com 1 milhão de vínculos, a política de escopo gerada acrescenta de 0,8 a 2,8 ms na leitura, acima do limiar de 1 ms; a forma com a lista do ator reduz o acréscimo, mas fica em torno do limiar com 100 revendas no 18, e nenhuma das duas formas foi medida em escrita. Construir 10.000 registros custa de 72% a 193% da consulta, acima do limiar de 10%. Os dois resultados acima do limiar levam a ADRs novos. Não há pooler na CI; o percentual por comando volta com o executor |

Fora as dependências da tabela, a ordem é só a da árvore compartilhada: a C8 não depende da K9. A sonda de cada
entrega do Codex roda com o Claude, porque o sandbox do Codex não alcança o PostgreSQL.

### Decisões que a rodada precisa tomar

Cada decisão entra como ADR `proposto` na tarefa que a implementa e é aceita depois da auditoria.

- **ADR-038 aceito (K9, C9 e K10), a base do plano incremental.** O ADR-025, §1 manda planejar contra o retrato e
  reserva a introspecção à verificação. A decisão é planejar contra um **modelo físico versionado**, gravado pelo
  `db:plan` junto com cada plano e vinculado a ele por hash, para que o `db:plan` continue sem conexão e os estados
  históricos possam ser comparados. O `--check` reaplica os planos num banco descartável e confere o modelo e o
  retrato contra o resultado: a introspecção fica na verificação, como o ADR-025 decide. O §1 compara com
  `db/schema.sql`, e o plano incremental passa a comparar com o modelo. Por isso o ADR-038 diz expressamente como
  complementa o §1, cobrindo também segurança e infraestrutura além das tabelas das entidades, e o replay prova a
  equivalência entre modelo, planos e retrato. O ADR-038 fixa também:
  - o formato versionado do modelo;
  - o modo de transação por passo no formato do plano;
  - o registro por passo, a conferência do estado intermediário na retomada e a da base antes de cada plano;
  - o que o `--check` confere quando há N planos.
- **Segurança do servidor da CI sem regenerar planos antigos (K9).** Hoje o `--check` só aplica um plano igual ao
  que a IR gera, e essa é a proteção do servidor: a classificação por prefixo não basta, porque um passo com
  `CREATE TABLE` seguido de `COMMENT ON DATABASE` recebe classificação conhecida. Um plano antigo não pode ser
  regenerado de uma IR que já mudou. O planejamento previa trocar essa proteção por validação integral das formas
  permitidas, com modelos exatos para rotinas e blocos procedurais. Na K9, o ADR-038 decidiu outro caminho: a
  validação integral exigiria um parser de PL/pgSQL e um registro de modelos ligado a cada versão dos geradores. A
  proteção ficou assim:
  - o último plano continua regenerado e comparado byte a byte, e a cadeia de SHA-256 dos modelos prende os
    anteriores;
  - um filtro de texto recusa instruções sobre objetos globais (papel, tablespace ou outro banco) e de sessão. Os
    privilégios do banco corrente que o plano inicial concede (ADR-036) passam;
  - os planos são aplicados por uma conexão que entra como `vetra_migrator`, separada da conexão administrativa que
    cria o banco temporário;
  - o catálogo dos papéis Vetra é conferido antes e depois.
- **[ADR-039](adr/039-unidade-de-trabalho-e-repositorios.md), aceito (C8 e C10), a unidade de trabalho e os repositórios.**
  - As operações e a consulta restrita, com as formas usadas pelos corpos dos exemplos, implementadas nos
    repositórios gerados e exercitadas pela sonda integrada.
  - Os erros de registro ausente e de conflito, e a forma do registro, conforme o ADR-022, §3.
  - A API da unidade de trabalho e de onde o emissor lê a chave e o `kid`.
  - O **contexto global**: blog e chat não têm tenant, e o ADR-036 exige tenant e ator UUID, reservando visitante
    e global para um contrato posterior. O ADR-039 define esse contrato sem inventar tenant para eles.
- **[ADR-040](adr/040-papeis-e-rls-da-outbox.md) (K11 e K12), aceito, os papéis e o RLS da outbox.** O ADR-024 decide a partição e as entregas, mas não diz com
  que papel o relay lê a outbox de todos os tenants, nem se ela tem RLS. O ADR-040 decide os privilégios de quem
  grava, do relay e da manutenção, sem usar o `vetra_migrator` no runtime. Um papel global novo entra no bootstrap
  operacional do ADR-036, nunca num plano. O ADR-040 também decide como a deriva reconhece as partições
  operacionais, conferindo limites, vínculo ao pai, índices, donos e privilégios.

### Diferenças aditivas implementadas

O `Planner` e o `Migrator` usam a diferença segura por padrão. O último plano é regenerável contra o modelo
anterior, e o espelho `db/policies/0001_seguranca.sql` mostra somente a segurança completa da IR atual; a troca
atômica de políticas está no plano. O índice único de apoio é construído antes de anexar a chave única e antes
da FK, que usa `NOT VALID` e `VALIDATE`. O enum ganha um CHECK auxiliar validado antes da troca final de nomes.
Funções de transição/revisão com a mesma assinatura usam `CREATE OR REPLACE`; a instalação da revisão reúne o
lock, os triggers, os REVOKEs e as guardas num passo atômico, sem reinicializar os dados de revisão.
A substituição de trigger conserva `ENABLE ALWAYS` no mesmo passo. Tabelas novas só recebem o GRANT de DML
para a aplicação depois de toda a segurança instalada.

Remoções, renomeações, tipos físicos, preenchimento necessário, enum estreitado, tenant alterado e instruções sem
tradução têm diagnósticos próprios e não gravam plano parcial. O [guia](db-plan.md#diferenças-aditivas) especifica
passos, locks, custos, recusas e a sonda. São detalhes do ADR-038 aceito; não exigem um ADR substituto. O formato
físico e a IR permanecem nas versões atuais, e os artefatos dos exemplos conservavam somente `0001` nesta entrega (os planos incrementais vieram depois).

O [`db:migrate`](db-migrate.md) aplica os planos incrementais no banco real (K10): registro por passo em
`vetra.migration_steps`, com o começo do plano marcado depois da conferência da base pela linha `-- vetra:base`;
retomada do passo seguinte; índice da tentativa anterior aceito só com a mesma definição, e inválido refeito;
tentativas de `lock_timeout` por passo; e catálogos fora do dump conferidos antes dos passos.

### Repositórios implementados

O [Vetra Data](vetra-data.md) gera as classes de repositório e de registro a partir da IR validada, usando
o mesmo modelo de atribuições do ADR-035. As capacidades vinculadas pelo linker determinam `read` ou
`read_write`. Todas as operações terminais exigem a unidade ativa na fibra e aplicam o filtro de tenant,
inclusive na raiz; os CRMs têm ainda o RLS do plano. Registros `Data`, dinheiro e decimais são imutáveis;
consultas restritas não expõem dataset. Transições comparam o estado relido e travado no banco com o comando
da unidade antes do DML. O relógio único da operação fornece created_at em UTC com microssegundos.

Os métodos derivados de `many_to_many` travam o dono, conferem os dois registros, usam `ON CONFLICT` sobre o
par da junção na inclusão e preservam os vínculos de `include_on_create`. A sonda executa todos os corpos
Ruby de comandos e consultas dos quatro exemplos, com os argumentos vinculados, e disputa o mesmo dono
em dois backends para conferir inclusão e remoção idempotentes. As revendas são preparadas pelo migrador,
pois o plano existente só concede leitura em `dealers`; os corpos operam como `vetra_app` pelos repositórios.
São 72 verificações, todas passando no PostgreSQL 18.6 e no job de planos da CI, com a
[lista de resultados](vetra-data.md#sonda-dos-repositórios).

A avaliação de `authorize` em Ruby e de permissões por campo antes da unidade está implementada na C13
(ADR-044 proposto). A integração no despacho/acessos e a reautorização do estado final são da K17/K18;
o fechamento de eventos/idempotência, da K19, e histórico/auditoria continuam na rodada 7. Blog e chat usam
contexto global e autorização da aplicação, conforme ADR-037/039. O contrato do ADR-039 foi preservado; nenhum modelo, plano, retrato,
espelho ou grafo dos exemplos muda, e a IR permanece 0.6. Nenhuma dependência foi acrescentada.

### Riscos e verificações

- **Modelo e versões.** A introspecção e o `pg_dump` mudam entre versões principais. O modelo conferido pelo
  replay precisa sair igual no 17 e no 18, como o retrato já sai.
- **Passos fora de transação.** Com `CONCURRENTLY`, um plano deixa de ser tudo ou nada. Cada passo precisa ser
  registrado e retomável. Um índice inválido de uma falha anterior é detectado e refeito, nunca aceito. Um índice
  válido criado antes de uma queda, mas ainda não registrado, também é reconhecido.
- **Dependências de runtime.** `sequel ~> 5.110` e `pg ~> 1.7` são dependências de runtime (ADR-022, §5),
  resolvidas localmente nos cinco lockfiles. O compilador não carrega nenhuma das duas. Os grafos têm só os
  hashes de entrada/digest atualizados por causa dos lockfiles; os modelos e os artefatos SQL não mudam.
- **Partições operacionais.** A manutenção cria partições que o retrato não tem. A deriva precisa aceitá-las sem
  aceitar uma partição adulterada. A sonda roda a manutenção, depois o `db:migrate` sem deriva, e recusa uma
  partição alterada.
- **Chave do emissor.** Fica só na memória do processo: nunca vai para log, mensagem de erro ou artefato. Os
  testes geram chaves próprias. Configuração entrega bytes binários, ou o ambiente entrega kid e segredo
  hexadecimal; não há leitura de chave de artefato. A chamada de contexto é excluída dos logs SQL do Sequel.
- **Contexto global.** Blog e chat usam unidade sem emissor, tenant ou token. Ator UUID ou visitante ficam no
  contexto Ruby; as funções SQL devolvem NULL e a autorização é da aplicação. A guarda recusa tabela
  multiempresa nesse modo. Isso usa o plano atual, sem alterar banco; reforço de identidade global no banco
  exigirá plano incremental e contrato próprios.
- **Evidência da unidade de trabalho.** Testes sem banco cobrem token, sigilo, transações, parametrização,
  fibras e recusas. A sonda `sonda_vetra_data.rb` confere os efeitos no banco (23 verificações, descritas no
  [guia](vetra-data.md#sonda-no-postgresql-17-e-18)) no job de planos da CI, no PostgreSQL 17 e 18.
- **Outbox e o `xmin`.** Uma transação longa atrasa o relay de todos os tenants (ADR-008, §5). A sonda confere a
  continuidade dos intervalos com transações concorrentes e com uma transação que é desfeita.
- **Determinismo.** As partições diárias dependem da data, então não entram no plano: o plano cria o pai e a
  `DEFAULT`, e a manutenção cria as demais. Uma emissão anterior à primeira manutenção cai na `DEFAULT`, e o
  PostgreSQL recusa anexar uma partição cujo intervalo tem linhas nela. A K12 prepara as partições antes de
  liberar quem grava, e uma sonda recupera uma `DEFAULT` populada sem perder nem duplicar eventos.

### Fora da rodada 4

**Planejamento anterior, substituído** pelo recorte da [rodada 5](#rodada-5-decisões-da-k13-ator-de-sistema-idempotência-autorização-e-executor-parcial) e pela rodada 6 (veja o destino de cada item abaixo da lista). Ficavam para a rodada 5:

- o executor das oito etapas do ADR-016 e os adaptadores, e com eles o gate do ADR-023 por comando;
- os handlers reais, com o ator de sistema (`is_system_actor`, ADR-024, §4) e a autoridade dos `calls`;
- `vetra.instances`, `vetra.schema_state` e a fase contract (ADR-025, §5), que precisam de processos com
  batimento;
- o preenchimento em lotes, as mudanças de tipo e as renomeações declaradas;
- as políticas de administração dos vínculos, dentro do limite que o ADR-037 já documenta;
- a cifra dos campos pessoais (ADR-013) e o distribuidor do live.

Destino no planejamento atual: o executor das oito etapas, a medição do ADR-023 por comando (o teste 6 continua pendente) e os handlers de sistema estão na rodada 5, o executor sem histórico nem auditoria; os adaptadores estão na rodada 6, a cifra, o histórico e a auditoria na 7, e a fase contract e o distribuidor do live na 8; o preenchimento em lotes, as mudanças de tipo, as renomeações declaradas e as políticas de administração dos vínculos ainda não têm rodada.

Cada uma dessas mudanças de modelo é recusada com código próprio pela diferença aditiva, sem plano parcial.

## Rodada 3 (concluída)

### Estado e objetivo

`Vetra::SQL::Schema` gera o DDL puro das tabelas, chaves e índices dos quatro exemplos. `db:plan` gera o
plano inicial determinístico com fase, lock e custo por passo, transação única e `lock_timeout` de 3 s.
O plano confere papéis existentes, instala `pgcrypto`, cria `vetra_private.keys` vazia e as funções
`vetra.current_tenant()`/`current_actor()`, atribui donos e concede os privilégios mínimos de runtime.
Os papéis são criados por bootstrap operacional separado; nenhum plano cria objetos globais.

`--snapshot` e `--check` aplicam o plano num banco temporário. O retrato inclui donos e privilégios,
sem `--no-owner`. Os planos dos quatro exemplos incluem o contexto, e os retratos saem desses planos. A
sonda do contexto assinado aplica o plano como `vetra_migrator`, dono do banco, sem superusuário. O
[guia](db-plan.md) descreve bootstrap, provisionamento por parâmetros, rotação e resultados esperados.
Nenhuma chave, nem mesmo de teste, entra nos artefatos.

O plano dos CRMs inclui ENABLE/FORCE RLS, tenant restritivo (inclusive raiz por id), permissivas de
escopo, revisão de autorização e triggers de transição. `db/policies/` espelha a segurança aplicada
pelo plano, com divergência recusada antes de acessar o banco. O [ADR-037](adr/037-politicas-e-transicoes-no-plano-inicial.md)
define a tradução das concessões e seus limites; o [guia](db-rls.md) descreve a sonda integrada.
O [`db:migrate`](db-migrate.md) aplica o plano num banco real como `vetra_migrator`. O emissor Ruby e a unidade de
trabalho do [Vetra Data](vetra-data.md) usam essa infraestrutura; repositórios, executor de operações e outbox
continuam pendentes.

### Entregas e dependências da rodada 3

| Tarefa | Implementador | Dependência | Entrega |
|---|---|---|---|
| C5 — mapeamento físico | Codex | — | ADR-035 aceito, modelo puro e DDL determinístico dos quatro exemplos, identificadores validados |
| K7 — planos e retrato | Claude | C5 | `db:plan`, executor comum, retrato e `--check`, CI no PostgreSQL 17/18 |
| C6 — papéis e contexto | Codex | K7 | ADR-036 aceito, bootstrap global separado, donos, privilégios, contexto HMAC e sonda no PostgreSQL 17/18 |
| C7 — RLS e integridade | Codex | C6 | ADR-037 aceito; tenant restritivo, permissivas de escopo em `db/policies/`, revisão nos planos, triggers de transição e sonda de RLS e integridade no PostgreSQL 17/18 |
| K8 — executor persistente | Claude | C7 | `db:migrate` ([guia](db-migrate.md)): hashes em `vetra.migrations`, lock consultivo, tentativas de lock_timeout, banco vazio ou registrado, deriva e retomada, com sonda no PostgreSQL 17/18 |

Só um implementa por vez no checkout compartilhado. O Claude executa as sondas no 17 e 18 na auditoria
das entregas do Codex. Plano incremental expand/migrate/contract com dados, `CONCURRENTLY`, `NOT VALID`,
lotes, repositórios sobre Sequel, outbox e `vetra.instances` ficam fora do plano inicial.

### Decisões físicas e de segurança

- IDs UUID com default v4; texto com checks de comprimento; `bigint`, `numeric(p,s)`, `boolean`, `date`,
  timestamp com fuso/microssegundos e `jsonb`. `enum` é texto com CHECK e `money` usa valor/moeda com
  check de par e moedas compatíveis. A nulidade vem de `nullable`; `created_at` vem do repositório.
- Identificadores ASCII minúsculos, até 63 bytes, validados e citados; colisões são erros. Nomes derivados
  usam hash da estrutura. Não se aceita SQL de predicado parcial ou de default fornecido pelo grafo.
- FKs de tenant implícito também são criadas. Raiz tem escopo próprio; relações entre filhas usam chave
  composta por tenant, sem duplicar junções. MATCH SIMPLE permite vendedor opcional; FKs NO ACTION,
  DEFERRABLE INITIALLY IMMEDIATE, criadas depois das tabelas e chaves únicas, inclusive em ciclos.
- Papéis pertencem ao cluster, preparados uma vez pelo operador e conferidos pelo plano. `vetra_owner`
  possui schemas/tabelas/funções e não faz login. O migrador herda esse papel, com BYPASSRLS. A aplicação
  não tem vínculos, propriedade, DDL ou acesso privado; recebe DML, USAGE e as duas funções de contexto.
- O operador cria o banco vazio com `vetra_migrator` como dono; ele aplica o plano sem superusuário.
  O plano concede CREATE no banco a `vetra_owner` para receber os schemas. `pgcrypto` é instalada em
  `vetra_private`, sem alterar EXECUTE dos membros SECURITY INVOKER; a aplicação não tem USAGE no schema.
  A CI mantém `postgres` em `--snapshot`/`--check`. Esses comandos não alteram papéis.
- Contexto `v1.kid.payload.mac`, HMAC-SHA256 validado no banco a cada instrução, sem cache de sessão,
  comparação de 32 bytes sem saída antecipada por conteúdo, validade padrão de 30 s e teto de 120 s.
  Chaves são provisionadas por parâmetros, fora do plano. `verify_only` permite rotação normal;
  `revoked` falha fechada na próxima instrução READ COMMITTED.
- A exceção da guarda de rotinas da C2 confere assinatura, schema, dono, atributos, configuração e hash
  do corpo exatos. Nome/schema isolados não dão confiança. A sonda recusa cópias e mutações.

### Riscos e verificações da rodada 3

- **Donos e retrato:** `pg_dump` da mesma versão principal do servidor; normalização conserva OWNER,
  ACLs, RLS e corpos de funções. O `--check` da CI confere os retratos no 17 e no 18.
  A sonda aplica em dois bancos e verifica que o catálogo de papéis não mudou.
- **Contexto:** o HMAC/lookup custa uma chamada por função e instrução com InitPlan; usar tenant e ator
  faz duas. O gate do ADR-023 (0,5 ms/instrução e 25% da latência do comando) requer medição com RLS,
  concorrência e pooler no 17/18. PL/pgSQL não garante tempo constante de máquina. REPEATABLE READ pode
  conservar chave revogada no snapshot; emissão/rotação e escolha de isolamento são operacionais.
- **RLS:** blog e chat não têm tenant e `db:authz:sql` os recusa (ADR-031). Não se inventa tenant nem
  revisão para eles. A sonda integrada programa 103 verificações de acessos permitidos e recusados,
  inclusive raiz, FKs, views invoker e funções invoker; execução 17/18 pertence à auditoria.
  Contexto assinado inicial exige UUIDs
  de tenant/ator; visitante/global sem essas identidades precisa de contrato posterior.
- **Escopo e transições:** sem escopo SQL, a permissiva `true` deixa o RBAC na aplicação, inclusive
  administração de vínculos. Predicados sem tradução são registrados no espelho. Os triggers invoker
  dos CRMs validam o token antes de ler cmd e não ampliam a exceção C2. Revisão é composta sem
  BEGIN/COMMIT interno, com guardas depois dos REVOKEs. Eventos e histórico continuam no runtime.
- **K8:** introspecção deve reconhecer banco vazio e cada etapa concluída, sem comparar só com o
  retrato final. Precisa recusar deriva, plano alterado e segundo migrador, conservar o lock consultivo
  e registrar DDL/conclusão atomicamente. Uma interrupção deve permitir retomada verificável.

## Regras

Todo identificador é validado antes de interpolar e usa aspas. Valores operacionais e segredos nunca
entram no SQL versionado. Cada comando novo recebe fase, lock e custo na classificação; uma ausência
é erro. Todo artefato é função dos arquivos versionados e reproduzível na CI. A IR permanece 0.6;
um recurso novo precisará de versão MENOR e `requires` conforme ADR-001. Mudança em SQL exige suíte,
grafos, gate e sonda afetada; sintaxe local da sonda não substitui aplicação no PostgreSQL.

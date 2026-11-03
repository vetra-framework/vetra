# Tarefas dos agentes

Quadro das tarefas divididas entre o Codex e o Claude, conforme [AGENTS.md](../AGENTS.md). Cada linha diz quem
está com a tarefa, a situação e a auditoria. O mantenedor define prioridades e pode trocar responsáveis.

Situações: `a fazer`, `em andamento`, `em auditoria`, `devolvida`, `concluída`.

## Rodada 1 (2026-11-03)

| ID | Tarefa | Responsável | Situação | Commit | Auditoria e parecer |
|---|---|---|---|---|---|
| K1 | Registrar o fluxo entre agentes: `AGENTS.md`, `CLAUDE.md` e este quadro | Claude | concluída | ver histórico | Parecer do Codex pedido |
| K2 | Auditar as entregas do Codex de `cb7c0b5` a `61efbb8` | Claude | concluída | — | Resultado abaixo |
| K3 | Atualizar a linha de commits do resumo da situação e formalizar as linhas de cabeçalho permitidas em ADR aceito | Claude | concluída | ver histórico | Parecer do Codex pedido |
| C1 | Geração automática dos comandos de vínculo de `many_to_many` (parte do critério 7) | Codex | concluída | `58993e2` | Devolvida na rodada 1, aprovada na rodada 2; ADR-032 proposto; CI verde ([auditoria](#auditoria-c1)) |
| K4 | Protocolo novo: os dois implementam, auditoria cruzada, decisão e envio pelo Claude; lacunas do parecer | Claude | concluída | `e761f05` | Pedido do mantenedor; incorpora o parecer do Codex sobre `1aca944` |
| K5 | `db:authz:sql`: fechar os caminhos que contornam a revisão (papéis assumíveis por `SET ROLE`, `ADMIN OPTION`, `REFERENCES`, `session_replication_role`) | Claude | concluída | `fb41921` | Rodadas 1 a 3 devolvidas pelo Codex; rodada 4 aprovada com ajuste não bloqueante; CI verde, sonda 29/29 no PostgreSQL 17 e 18 ([auditoria](#auditoria-k5)) |
| C2 | `db:authz:sql`: recusar ou listar para revisão as rotinas `SECURITY DEFINER` existentes que a aplicação pode executar e que pertencem a papéis com poder de escrita, `TRUNCATE` ou `TRIGGER` nas tabelas protegidas (achado da auditoria da K5) | Codex | concluída | `4588b78` | Rodadas 1 e 2 devolvidas pelo Claude; rodada 3 aprovada; CI verde, sonda 59/59 no PostgreSQL 17 e 18 ([auditoria](#auditoria-c2)) |

### C1: escopo

- Gerar, a partir de `many_to_many`, os comandos de inclusão e remoção do vínculo previstos na proposta, com
  contrato tipado, autorização pela entidade dona da relação e descritor de primitiva, sem executor.
- Decidir num ADR `proposto` como a geração convive com comandos declarados explicitamente (o chat já declara
  `add_member` e `remove_member`), como se chamam, como se desligam e o que entra no diff.
- Testes de compilação, diagnóstico das recusas, exemplos reconstruídos, gate sem quebra não declarada e docs
  (`fase-0.md`, critérios e situação) coerentes.
- Entregar sem commit, com o relatório do protocolo.

## Rodada 2 (2026-11-03)

O mantenedor delegou ao Claude as decisões pendentes. Decidido: ADR-032 aceito, com a geração ligada por padrão;
ADRs 028 a 031 confirmados; nenhuma questão em aberto vira ADR de resolução agora; a consulta sem `returns` nem
`authorize` continua recusada. O Codex não alcança o PostgreSQL no sandbox, então as tarefas com sonda ficam com
o Claude e as de compilador podem ir para os dois.

| ID | Tarefa | Responsável | Situação | Commit | Auditoria e parecer |
|---|---|---|---|---|---|
| C3 | `rounding:` em `currency` (construto da proposta hoje recusado, critério 7): ADR proposto, DSL, IR em nova MENOR conforme o ADR-001 §4, validador, diff e docs | Codex | concluída | este commit | Rodada 1 devolvida pelo Claude; rodada 2 aprovada; ADR-033 aceito por delegação ([auditoria](#auditoria-c3)) |
| K6 | `sonda_adr015`: os quatro casos do ADR-025 (índice e chave em tabela particionada, chave composta por tenant, `CHECK` de `enum`), na CI do PostgreSQL 17 e 18 | Claude | a fazer | — | Auditoria pelo Codex |
| C4 | `rate_limit:` em `can` (construto da proposta hoje recusado, critério 7), depois da C3 e no mesmo formato | Codex | a fazer | — | — |

Depois desta rodada: a gem alpha.5 pode ser publicada pelo mantenedor, e o passo seguinte é começar a
persistência.

## Auditoria C3

Implementado pelo Codex sobre `ea03024`; auditado pelo Claude; decisão do Claude.

**Rodada 1 — devolvida.** ADR-033 proposto, IR 0.5 com `app.rounding` e `vetra.money_rounding`, tabela única de
recursos por versão em `Schema::VERSIONS`. Verificado: 371 testes, 3.414 asserções, 142/142; gate sem quebra;
quatro exemplos em check, validação com fontes e link.

| Achado do Claude | Bloqueia | Decisão do Claude |
|---|---|---|
| Todo build materializava `half_up` e exigia `vetra.money_rounding`, até no blog e no chat, sem `money`: todo consumidor teria de implementar arredondamento para ler qualquer grafo, ao contrário do padrão da C1 | sim | Ajustar: campo e requisito só quando a aplicação declara `rounding:` |
| Trocar o modo é quebra potencial mesmo sem campo `money` | não | Não ajustar: conservador e justificado no ADR |

**Rodada 2 — aprovada.** Só o mini CRM com revendas tem o campo e o requisito. Suíte com 371 testes e 3.482
asserções, 142/142; gate sem quebra; quatro exemplos passam; `git diff --check` limpo, sem mudança de modo. O
Claude aceitou o ADR-033 por delegação do mantenedor e tirou dos docs a narrativa de entrega sem commit.

## Auditoria C1

Implementado pelo Codex sobre `1aca944`; auditado pelo Claude; decisão do Claude.

**Rodada 1 — devolvida.** Suíte, exemplos e gate passavam (348 testes, 141/141 diagnósticos), mas a entrega
acrescentava o recurso `vetra.relation_commands` à IR 0.3 e alterava `docs/ir/v0.3.schema.json`. O ADR-001 (§4)
exige nova MENOR para recurso semântico novo e diz que schemas publicados são imutáveis; o schema 0.3 já tinha
saído na gem 0.1.0.pre.alpha.4, publicada no RubyGems em 2026-11-03 13:08 UTC (conferido pela API do RubyGems).

**Rodada 2 — aprovada.** O schema 0.3 voltou a ser idêntico ao de `HEAD`; a IR 0.4 é um schema novo, igual ao
0.3 exceto pela versão e pelo requisito novo; 0.1, 0.2 e 0.3 continuam aceitas com suas regras, e um documento
0.3 com o requisito ou a primitiva nova é recusado. Verificado pelo Claude: 351 testes e 2.906 asserções, sem
falhas; 141/141 diagnósticos; quatro exemplos em check, validação com fontes e link; gate contra `origin/main`
sem quebra, com a troca de `ir_version` para revisão nos quatro grafos; `git diff --check` limpo.

| Achado | Bloqueia | Decisão do Claude |
|---|---|---|
| Recurso novo dentro da IR 0.3 e schema publicado alterado | sim | Ajustar (feito na rodada 2) |
| A geração vem ligada por padrão, enquanto `crud` é opt-in | não | Não ajustar agora: segue a proposta e está registrado no ADR-032; decisão do mantenedor no aceite do ADR |
| Listas de versões repetidas em `schema.rb`, normalizador, validador e linker | não | Não ajustar agora: o padrão já existia; vale uma tabela de versões quando surgir a 0.5 |
| Nenhum exemplo exercita a geração (o chat usa `commands: false`) | não | Não ajustar: os 20 testes de `relation_commands_test.rb` cobrem a geração e as recusas |

## Auditoria C2

Implementado pelo Codex sobre `de84819`; auditado pelo Claude; decisão do Claude. O sandbox do Codex recusou
sockets Unix e TCP em loopback, então a sonda completa foi rodada pelo Claude, no PostgreSQL 18.6, contra o
gerador novo e contra o de `fb41921` (resto da árvore igual).

**Rodada 1 — devolvida.** Guarda antes da infraestrutura, com o critério de papéis da K5 para quem executa e
para o dono. Sonda 55/55; 33/55 contra `fb41921`.

| Achado do Claude | Bloqueia | Decisão do Claude |
|---|---|---|
| Cadeia de definers: `a()` de dono sem poder, executável por `PUBLIC`, chama `b()`, privada, cujo dono tem `TRUNCATE`; reproduzido no PostgreSQL 18 (tabela esvaziada) sem recusa | sim | Ajustar: fecho recursivo dos papéis alcançáveis por `EXECUTE` de definers |
| A recusa não exige `USAGE` no schema da rotina | não | Não ajustar: conservador; registrar no guia |

**Rodada 2 — devolvida.** Fecho com `UNION`, ciclos encerrados, recusa listando entradas, intermediárias e
rotinas perigosas. Sonda 58/58; 34/58 contra `fb41921`.

| Achado do Claude | Bloqueia | Decisão do Claude |
|---|---|---|
| `INSERT`, `UPDATE` e `DELETE` do dono contavam como poder perigoso, mas DML dispara os triggers `ALWAYS` e incrementa a revisão; erro de especificação do Claude na rodada 1, que recusaria funções de escrita comuns | sim | Ajustar: mesmo modelo de poderes da aplicação (`TRUNCATE`, `TRIGGER`, `REFERENCES`, propriedade, atributos, `ADMIN`, subscriptions, papéis de servidor) |
| A guarda rodava antes da infraestrutura e não conferia, nos donos alcançados, escrita nas revisões, `EXECUTE` nas funções novas e `CREATE` no schema, alcançáveis por privilégios padrão globais do instalador | sim | Ajustar: guarda depois dos `REVOKE`s, conferindo os privilégios efetivos |

**Rodada 3 — aprovada.** Sonda 59/59 no PostgreSQL 18.6, inclusive o `DELETE` por definer de dono só com DML
(revisão de 1 a 2) e as três recusas por privilégios padrão globais; 35/59 contra `fb41921`. Suíte com 355
testes e 2.984 asserções, sem falhas; 141/141 diagnósticos; gate sem alterações; `git diff --check` limpo; modo
`100755` da sonda preservado. O Claude enxugou nos docs a narrativa de rodadas e sandbox, deixando os números
finais. Limite que permanece, documentado no guia: rotinas, corpos e concessões alterados depois da instalação.

## Auditoria K5

Implementado pelo Claude sobre `58993e2`; auditado pelo Codex em modo somente leitura; decisão do Claude.

**Rodada 1 — devolvida pelo Codex.** A correção de `SET ROLE` estava certa (a semântica de `pg_has_role(...,
'SET')` inclui o próprio papel e cadeias), mas três caminhos anteriores contornavam a revisão do mesmo jeito.

| Achado do Codex | Bloqueia | Decisão do Claude |
|---|---|---|
| `GRANT SET ON PARAMETER session_replication_role` permite `replica`, que suprime os triggers | sim | Ajustar de outro modo: triggers `ENABLE ALWAYS`, que vale também para concessões feitas depois da instalação, em vez de só recusar quem tem o poder hoje |
| `REFERENCES` nas tabelas protegidas, inclusive por coluna, não era revogado nem conferido | sim | Ajustar: revogar e recusar, também em papéis assumíveis |
| `ADMIN OPTION` deixa a aplicação conceder a si um papel que hoje não pode assumir | sim | Ajustar: recusar `ADMIN OPTION` da aplicação ou de papel assumível sobre outro papel |
| A edição tirou o bit de execução de `script/sonda_adr031.rb` | não | Ajustar: modo `100755` restaurado |
| A suíte não rodou no sandbox somente leitura do auditor (276 erros de temporários) | não | Não ajustar o código; o Claude repete a suíte antes do envio |

**Rodada 2 — devolvida pelo Codex.** Os três caminhos da rodada 1 ficaram fechados; o Codex rodou a suíte e
conferiu que não alterou a árvore.

| Achado do Codex | Bloqueia | Decisão do Claude |
|---|---|---|
| Uma subscription criada pela aplicação (`pg_create_subscription`) escreve sem disparar triggers por instrução, mesmo `ALWAYS` | sim | Ajustar: recusar uso de `pg_create_subscription` e posse de subscriptions por papel que a aplicação usa |
| `MEMBER WITH ADMIN OPTION` atravessa vínculos `INHERIT FALSE, SET FALSE`: falso positivo com o `ADMIN` implícito de um criador `CREATEROLE` | sim | Ajustar: contar só o `ADMIN` de papéis que a aplicação assume ou herda (`pg_auth_members`), com o caso legítimo na sonda |
| `pg_restore --data-only --disable-triggers` volta os triggers de `ALWAYS` para a habilitação comum | não | Ajustar: documentar a conferência de `tgenabled` depois de um restore assim |
| Contagem da suíte desatualizada no resumo da situação | não | Ajustar no envio |

**Rodada 3 — devolvida pelo Codex.** O falso positivo do criador ficou corrigido; o Codex reproduziu no
PostgreSQL 18.6 dois desvios por cadeia mista e um poder de servidor.

| Achado do Codex | Bloqueia | Decisão do Claude |
|---|---|---|
| `app -SET-> ponte -INHERIT-> administrador`: o `ADMIN` do administrador é utilizável depois de `SET ROLE ponte`, e a consulta não o via (TRUNCATE com revisão parada) | sim | Ajustar: "utilizável" passa a ser o que herda algum papel assumível, não só a aplicação |
| Mesma cadeia com a posse de uma subscription existente | sim | Ajustar com o mesmo critério |
| `pg_execute_server_program` permitiu truncar o arquivo físico da tabela | sim | Ajustar: recusar os três papéis predefinidos de acesso a arquivos e programas do servidor |

**Rodada 4.** Sonda 29/29 no PostgreSQL 18.6, com os três cenários do Codex; contra o gerador de `61efbb8`, as
dez verificações que detectam os caminhos fechados falham (19/29). Suíte com 352 testes e 2.932 asserções.
PostgreSQL 17 só na CI: o WSL tem o cliente, não o servidor.

**Rodada 4 — aprovada com ajuste não bloqueante.** O Codex confirmou os três bloqueantes fechados, também em
cadeias `SET → SET → INHERIT → INHERIT`, sem falso positivo com `pg_read_all_data` ou `pg_monitor`, e repetiu a
suíte (352 testes, 0 falhas, 141/141).

| Achado do Codex | Bloqueia | Decisão do Claude |
|---|---|---|
| Função `SECURITY DEFINER` preexistente do proprietário, executável pela aplicação, faz `TRUNCATE` sem revisão | não | Ajustar documentando o limite no guia; a correção vira a tarefa C2 do Codex, por ser outra classe de problema |

## Auditoria K2: entregas do Codex de `cb7c0b5` a `61efbb8`

Verificado em 2026-11-03 sobre `61efbb8` (a primeira versão deste registro dizia `2d37e15` por engano; o
parecer do Codex apontou a divergência).

**Correção posterior:** o parecer do Codex achou uma lacuna que esta auditoria não viu. O gerador conferia só os
privilégios da aplicação, não os de papéis que ela pode assumir por `SET ROLE` com `INHERIT FALSE`; um
`TRUNCATE` obtido assim apaga vínculos sem incrementar a revisão. A K5 corrige.

**Aprovado.** Suíte com 328 testes e 2.532 asserções, sem falhas, e 137/137 códigos de diagnóstico; os quatro
exemplos passam em check, validação com fontes e link; o gate contra `2cb2700` não aponta quebra e lista para
revisão a IR 0.3, as consultas `my_rooms` e `room_page` e suas rotas; a gem 0.1.0.pre.alpha.5 é construída em
modo estrito. O gerador `db:authz:sql` valida todos os identificadores antes de interpolá-los, usa aspas nos
nomes e literais escapados, recusa papéis privilegiados e não gera SQL parcial.

**Pontos para o mantenedor:**

1. Os ADRs 028 a 031 foram marcados `aceito` pelo próprio agente, na integração. Pelo protocolo novo, o aceite é
   do mantenedor: confirme ou devolva cada um.
2. Os ADRs aceitos 008, 020 e 030 ganharam linhas de cabeçalho (`Evidência posterior`, `Implementação
   posterior`) que a convenção não previa. Não mudam decisões; a K3 as formaliza como referências permitidas.
3. A linha "PRs e commits locais" do resumo parava no PR #36; a K3 a atualiza.
4. A versão 0.1.0.pre.alpha.5 está commitada e não publicada; a alpha.4 publicada não tem os metadados novos.

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
| C1 | Geração automática dos comandos de vínculo de `many_to_many` (parte do critério 7) | Codex | concluída | este commit | Devolvida na rodada 1, aprovada na rodada 2; ADR-032 proposto ([auditoria](#auditoria-c1)) |

### C1: escopo

- Gerar, a partir de `many_to_many`, os comandos de inclusão e remoção do vínculo previstos na proposta, com
  contrato tipado, autorização pela entidade dona da relação e descritor de primitiva, sem executor.
- Decidir num ADR `proposto` como a geração convive com comandos declarados explicitamente (o chat já declara
  `add_member` e `remove_member`), como se chamam, como se desligam e o que entra no diff.
- Testes de compilação, diagnóstico das recusas, exemplos reconstruídos, gate sem quebra não declarada e docs
  (`fase-0.md`, critérios e situação) coerentes.
- Entregar sem commit, com o relatório do protocolo.

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

## Auditoria K2: entregas do Codex de `cb7c0b5` a `61efbb8`

Verificado em 2026-11-03 sobre `2d37e15`.

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

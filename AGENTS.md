# Vetra — instruções para agentes

Vale para todo agente que trabalha neste repositório (Codex, Claude e outros). Responda e documente em
português brasileiro. O estado do projeto está em [docs/situacao-do-projeto.md](docs/situacao-do-projeto.md);
as decisões, em [docs/adr](docs/adr/README.md); o quadro de tarefas, em
[docs/tarefas-dos-agentes.md](docs/tarefas-dos-agentes.md).

## Fluxo de trabalho

- Trabalhe **direto na `main`**. Não crie branches de trabalho nem worktrees.
- **Nunca abra pull request** por iniciativa própria; só quando o mantenedor pedir com essas palavras.
- **Push só quando o mantenedor pedir.** Nunca use force-push nem reescreva commits já publicados; uma correção
  é sempre um novo commit.
- Antes de cada push, rode a suíte e o gate (detalhes em
  [docs/graph-diff.md](docs/graph-diff.md#fluxo-de-integração-e-ci)):

  ```sh
  bundle exec rake test:diagnostics
  bundle exec ruby script/check_graph_compatibility.rb --base origin/main
  ```

- Ao mudar o modelo de um exemplo, rode `graph:build` nele e commite o `.vetra/graph.json` junto. Uma quebra
  intencional vai para `.github/graph-compatibility.json` no mesmo commit, com o motivo.
- Todo commit que muda um status atualiza `docs/situacao-do-projeto.md` no mesmo commit.
- Mensagens de commit em português, no formato `tipo(escopo): descrição`; um assunto por commit (separe mudança
  de formato da IR de mudanças nos exemplos).
- Não publique a gem nem mude configurações do GitHub; essas ações são do mantenedor.

## Divisão entre agentes

| Papel | Quem | O quê |
|---|---|---|
| Implementação | Codex | Código e testes do compilador, IR, DSL, geradores e, depois, do runtime; ADR proposto e docs da própria mudança |
| Auditoria | Claude | Confere cada entrega do Codex antes do commit: diff, suíte, exemplos, gate, convenções e coerência dos docs |
| Processo e manutenção | Claude | CI, scripts, release da gem, coerência de `docs/situacao-do-projeto.md` e do índice de ADRs, tarefas pontuais |
| Parecer | Codex | Revisa as mudanças do Claude e as conclusões das auditorias, e aponta o que discorda |
| Decisões | Mantenedor | Prioridades, aceite de ADR, push, publicação da gem e configurações do GitHub |

O quadro em [docs/tarefas-dos-agentes.md](docs/tarefas-dos-agentes.md) diz quem está com cada tarefa. Só o
responsável por uma tarefa em andamento edita a árvore; os dois agentes compartilham o mesmo checkout.

## Protocolo de entrega e auditoria

1. **Implementar sem commitar.** O implementador deixa as mudanças na árvore de trabalho, roda a suíte, os
   exemplos e o gate, e termina com um relatório curto: o que mudou, como verificou, o que ficou de fora e
   quais riscos vê.
2. **Auditar.** O auditor revisa o diff completo e repete as verificações. Aprovada, a entrega vira commit na
   `main` com a linha `Auditado-por: <agente>` no corpo da mensagem. Reprovada, os achados voltam ao implementador
   e a tarefa continua com ele.
3. **Registrar.** O quadro de tarefas recebe o commit, o resultado da auditoria e o parecer, quando houver.
4. **ADR.** Um ADR novo entra como `proposto`. Só o mantenedor muda o status para `aceito`; um agente registra o
   aceite quando o mantenedor o der.

## Ambiente

- Ruby 4.0.9 (`.ruby-version`) via rbenv dentro do WSL (Ubuntu 24.04). Rode Ruby, Bundler e Git **dentro do
  WSL**: o Git do Windows, pelo caminho `\\wsl.localhost`, mostra falsas mudanças de modo (`100755 → 100644`)
  nos scripts; não as commite.
- As sondas de banco (`script/sonda_*.rb`) exigem `DATABASE_URL` de um banco descartável.

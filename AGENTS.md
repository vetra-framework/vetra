# Vetra — instruções para agentes

Vale para todo agente que trabalha neste repositório (Codex, Claude e outros). Responda e documente em
português brasileiro. O estado do projeto está em [docs/situacao-do-projeto.md](docs/situacao-do-projeto.md);
as decisões, em [docs/adr](docs/adr/README.md); o quadro de tarefas, em
[docs/tarefas-dos-agentes.md](docs/tarefas-dos-agentes.md).

## Fluxo de trabalho

- Trabalhe **direto na `main`**. Não crie branches de trabalho nem worktrees.
- **Nunca abra pull request** por iniciativa própria; só quando o mantenedor pedir com essas palavras.
- **Commit e push são do Claude**, depois da auditoria e da decisão descritas abaixo; o Codex nunca commita
  nem faz push. Nunca use force-push nem reescreva commits já publicados; uma correção é sempre um novo commit.
- Antes de cada push, com a árvore limpa (o gate lê os arquivos do disco, não o commit), atualize a referência
  remota e rode a suíte e o gate (detalhes em [docs/graph-diff.md](docs/graph-diff.md#fluxo-de-integração-e-ci)):

  ```sh
  git fetch origin && git status --short   # deve sair vazio
  bundle exec rake test:diagnostics
  bundle exec ruby script/check_graph_compatibility.rb --base origin/main
  ```

- Mudança em SQL gerado ou em comportamento de banco também roda as sondas afetadas (`script/sonda_*.rb`) num
  PostgreSQL descartável; a suíte não aplica SQL.
- Ao mudar o modelo de um exemplo, rode `graph:build` nele e commite o `.vetra/graph.json` junto. Uma quebra
  intencional vai para `.github/graph-compatibility.json` no mesmo commit, com o motivo.
- Todo commit que muda um status atualiza `docs/situacao-do-projeto.md` no mesmo commit.
- Mensagens de commit em português, no formato `tipo(escopo): descrição`; um assunto por commit (separe mudança
  de formato da IR de mudanças nos exemplos).
- Não publique a gem nem mude configurações do GitHub; essas ações são do mantenedor. Preparar a release
  (versão, gemspec, build de conferência) pode ser tarefa de agente.

## Divisão entre agentes

| Papel | Quem | O quê |
|---|---|---|
| Implementação | Codex e Claude | Cada tarefa do quadro tem um implementador: código, testes, ADR proposto e docs da própria mudança |
| Auditoria cruzada | O outro agente | O Claude audita as entregas do Codex; o Codex audita as do Claude, em modo somente leitura |
| Decisão e envio | Claude | Decide o que fazer com cada achado, commita e faz o push quando a entrega está conforme |
| Mantenedor | Denilson | Prioridades, aceite de ADR, publicação da gem e configurações do GitHub; pode rever qualquer decisão |

O quadro em [docs/tarefas-dos-agentes.md](docs/tarefas-dos-agentes.md) diz quem está com cada tarefa. Os dois
agentes compartilham o mesmo checkout, então **só um implementa por vez**: a árvore pertence ao implementador da
tarefa `em andamento` e fica congelada enquanto ela está `em auditoria`.

## Protocolo de entrega, auditoria e decisão

1. **Implementar sem commitar.** O implementador deixa as mudanças na árvore de trabalho, roda a suíte, os
   exemplos, o gate e as sondas afetadas, e termina com um relatório curto: base (`git rev-parse HEAD`), o que
   mudou, como verificou, o que ficou de fora e quais riscos vê. A tarefa passa a `em auditoria`.
2. **Auditar.** O outro agente revisa o diff completo contra a base informada e repete as verificações. Cada
   achado diz o arquivo e a linha, a evidência e se bloqueia ou não.
3. **Decidir.** O Claude decide cada achado: `ajustar` (volta ao implementador, ou o Claude ajusta quando o
   implementador é ele) ou `não ajustar`, com o motivo registrado. Uma divergência que só o mantenedor pode
   resolver, como o aceite de um ADR, fica anotada no quadro e não bloqueia o resto.
4. **Enviar.** Conforme, o Claude commita na `main` com as linhas `Implementado-por:` e `Auditado-por:` no corpo
   da mensagem e faz o push depois das verificações do fluxo de trabalho, com a árvore limpa.
5. **Registrar.** O quadro recebe o commit, os achados, a decisão de cada um e o resultado do CI.
6. **ADR.** Um ADR novo entra como `proposto`. Só o mantenedor muda o status para `aceito`; um agente registra o
   aceite quando o mantenedor o der.

## Ambiente

- Ruby 4.0.9 (`.ruby-version`) via rbenv dentro do WSL (Ubuntu 24.04). Rode Ruby, Bundler e Git **dentro do
  WSL**: o Git do Windows, pelo caminho `\\wsl.localhost`, mostra falsas mudanças de modo (`100755 → 100644`)
  nos scripts; não as commite.
- As sondas de banco (`script/sonda_*.rb`) exigem `DATABASE_URL` de um banco descartável.

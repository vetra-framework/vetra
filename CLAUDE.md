# Vetra — instruções para agentes

Responda e documente em português brasileiro. O estado do projeto está em
[docs/situacao-do-projeto.md](docs/situacao-do-projeto.md); as decisões, em [docs/adr](docs/adr/README.md).

## Fluxo de trabalho

- Trabalhe e faça commit **direto na `main`**. Não crie branches de trabalho nem worktrees.
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

## Ambiente

- Ruby 4.0.9 (`.ruby-version`) via rbenv dentro do WSL (Ubuntu 24.04). Rode Ruby, Bundler e Git **dentro do
  WSL**: o Git do Windows, pelo caminho `\\wsl.localhost`, mostra falsas mudanças de modo (`100755 → 100644`)
  nos scripts; não as commite.
- As sondas de banco (`script/sonda_*.rb`) exigem `DATABASE_URL` de um banco descartável.

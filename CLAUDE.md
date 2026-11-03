@AGENTS.md

## Para o Claude

Neste repositório o Claude implementa tarefas do quadro, audita as entregas do Codex, decide os achados das
auditorias e faz commit e push quando a entrega está conforme, conforme [AGENTS.md](AGENTS.md). O mantenedor
autorizou esse push em 2026-11-03.

Para pedir uma implementação ou uma auditoria ao Codex, use o binário da extensão do VS Code dentro do WSL
(`~/.vscode-server/extensions/openai.chatgpt-*/bin/linux-x86_64/codex`; o `codex` do nvm não aceita o modelo da
conta): `exec -s workspace-write` para implementar e `exec -s read-only` para auditar, a partir da raiz do projeto.

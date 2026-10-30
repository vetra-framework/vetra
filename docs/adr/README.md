# Registro de decisões arquiteturais (ADRs)

A proposta técnica lista 21 decisões fundadoras. Hoje cada uma é só uma linha de tabela; nenhuma foi escrita
por completo. Cada ADR deve ser escrito antes da implementação do componente correspondente.

## Escritos

| ADR | Título | Status |
|---|---|---|
| [004](004-capacidades-e-effect-boundary.md) | Capacidades e Effect Boundary | proposto |
| [005](005-rls-e-contexto-assinado.md) | RLS obrigatório com contexto assinado | proposto |
| [008](008-ordem-e-continuidade-dos-eventos.md) | Notificação como invalidação, ordem por xid8 e continuidade | proposto |
| [016](016-ciclo-de-vida-da-operacao.md) | Ciclo de vida da operação | proposto |
| [020](020-entrega-live-incremental.md) | Entrega live incremental | proposto |
| [021](021-campos-de-transicao.md) | Campos de transição | proposto |

**Próximo passo:** os ADRs 001 (Grafo compilado em IR) e 002 (somente PostgreSQL) são os fundadores que
faltam; os demais (003, 006, 007, 009 a 015, 017 a 019) seguem a ordem das fases do roadmap. Antes de
implementar a fase 0, o ADR-001 precisa definir o esquema da IR e sua política de compatibilidade.

## Convenção

- Um arquivo por decisão, nomeado `NNN-titulo-curto.md` (por exemplo, `016-ciclo-de-vida-da-operacao.md`).
- Use o modelo abaixo.
- Um ADR aceito não é editado; uma mudança de decisão gera um novo ADR que o substitui.

## Modelo

```markdown
# ADR-NNN: Título

- Status: proposto | aceito | substituído por ADR-NNN
- Data: AAAA-MM-DD

## Contexto

O problema e as forças em jogo.

## Decisão

O que foi decidido.

## Alternativas rejeitadas

O que foi considerado e por que não foi escolhido.

## Consequências

O que passa a valer, incluindo os custos e os limites.

## Garantia

Nível (estrutural, transacional, verificável por testes, operacional ou experimental), mecanismo e testes.
```

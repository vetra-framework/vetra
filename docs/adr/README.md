# Registro de decisões arquiteturais (ADRs)

A proposta técnica lista 21 decisões fundadoras. Os PDFs registram o estado da proposta naquela revisão;
os documentos abaixo desenvolvem essas decisões. Cada ADR deve ser escrito antes da implementação do
componente correspondente. Todos os ADRs escritos ainda têm status **proposto**.

## Escritos

| ADR | Título | Status |
|---|---|---|
| [001](001-grafo-da-aplicacao-e-ir.md) | Grafo da Aplicação compilado em IR versionada | proposto |
| [002](002-somente-postgresql.md) | Somente PostgreSQL | proposto |
| [004](004-capacidades-e-effect-boundary.md) | Capacidades e Effect Boundary | proposto |
| [005](005-rls-e-contexto-assinado.md) | RLS obrigatório com contexto assinado | proposto |
| [008](008-ordem-e-continuidade-dos-eventos.md) | Notificação como invalidação, ordem por xid8 e continuidade | proposto |
| [016](016-ciclo-de-vida-da-operacao.md) | Ciclo de vida da operação | proposto |
| [020](020-entrega-live-incremental.md) | Entrega live incremental | proposto |
| [021](021-campos-de-transicao.md) | Campos de transição | proposto |

O ADR-001 agora especifica o [esquema IR 0.1](../ir/README.md) e sua política de compatibilidade, atendendo
à pendência documental anterior à fase 0. A aceitação das decisões e os testes do compilador/runtime
continuam pendentes; o esquema e os exemplos não constituem uma implementação.

O [protótipo da fase 0](../fase-0.md) já compila e valida um subconjunto do DSL e
[compara versões da IR](../graph-diff.md); ainda não cobre todos os critérios do ADR-001. O runtime e suas
garantias continuam pendentes.

**Próximo passo:** ampliar a fase 0 com vinculação validada de implementações, mantendo os testes dos
contratos existentes. Os ADRs restantes (003, 006, 007, 009 a 015, 017 a 019) devem ser
escritos antes dos respectivos componentes, seguindo as dependências do roadmap.

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

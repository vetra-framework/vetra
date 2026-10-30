# Registro de decisões arquiteturais (ADRs)

A proposta técnica lista 21 decisões fundadoras. Hoje cada uma é só uma linha de tabela; nenhuma foi escrita
por completo. Cada ADR deve ser escrito antes da implementação do componente correspondente.

## Escritos

| ADR | Título | Status |
|---|---|---|
| [016](016-ciclo-de-vida-da-operacao.md) | Ciclo de vida da operação | proposto |

**Próximo passo:** com o ADR-016 escrito, os ADRs 004 (capacidades e Effect Boundary), 005 (RLS e contexto
assinado) e 020 (entrega live incremental) podem ser detalhados. O 005 resolve as questões que o 016 deixou
para ele: formato do contexto assinado, emissão, validade e rotação da chave.

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

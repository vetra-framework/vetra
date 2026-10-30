# Registro de decisões arquiteturais (ADRs)

A proposta técnica lista 21 decisões fundadoras. Os PDFs registram o estado da proposta naquela revisão;
os documentos abaixo desenvolvem essas decisões. Cada ADR deve ser escrito antes da implementação do
componente correspondente. Todos os ADRs escritos ainda têm status **proposto**.

## Escritos

| ADR | Título | Status |
|---|---|---|
| [001](001-grafo-da-aplicacao-e-ir.md) | Grafo da Aplicação compilado em IR versionada | proposto |
| [002](002-somente-postgresql.md) | Somente PostgreSQL | proposto |
| [003](003-sequel-e-camada-fina-de-repositorios.md) | Sequel com camada fina de repositórios | proposto |
| [004](004-capacidades-e-effect-boundary.md) | Capacidades e Effect Boundary | proposto |
| [005](005-rls-e-contexto-assinado.md) | RLS obrigatório com contexto assinado | proposto |
| [006](006-isolamento-de-dominios-em-tres-niveis.md) | Isolamento de domínios em três níveis, com Ruby::Box opcional | proposto |
| [007](007-comando-como-unidade-unica-e-adaptadores.md) | Comando como unidade única de operação e adaptadores de superfície | proposto |
| [008](008-ordem-e-continuidade-dos-eventos.md) | Notificação como invalidação, ordem por xid8 e continuidade | proposto |
| [009](009-workflows-por-historico-e-replay.md) | Workflows duráveis por histórico de eventos e replay determinístico | proposto |
| [010](010-adocao-hospedada-e-modo-servico.md) | Adoção hospedada em Rails ou modo serviço | proposto |
| [013](013-privacidade-auditoria-e-historico.md) | Privacy, Audit e History separados, com criptografia por envelope | proposto |
| [014](014-outbox-entrega-pelo-menos-uma-vez.md) | Outbox com entrega pelo menos uma vez | proposto |
| [015](015-migracoes-expand-contract.md) | Migrações expand/contract com análise de locks | proposto |
| [016](016-ciclo-de-vida-da-operacao.md) | Ciclo de vida da operação | proposto |
| [017](017-tipo-money.md) | Tipo money nativo | proposto |
| [018](018-camada-de-ui-em-modulos.md) | Camada de UI em módulos fora do núcleo, com ejeção em três níveis | proposto |
| [019](019-sinais-efemeros.md) | Sinais efêmeros autorizados pelo mesmo motor | proposto |
| [020](020-entrega-live-incremental.md) | Entrega live incremental | proposto |
| [021](021-campos-de-transicao.md) | Campos de transição | proposto |

O ADR-001 agora especifica o [esquema IR 0.1](../ir/README.md) e sua política de compatibilidade, atendendo
à pendência documental anterior à fase 0. A aceitação das decisões e os testes do compilador/runtime
continuam pendentes; o esquema e os exemplos não constituem uma implementação.

O [protótipo da fase 0](../fase-0.md) já compila e valida um subconjunto do DSL,
[compara versões da IR](../graph-diff.md) e [vincula blocos Ruby ao artefato aprovado](../graph-link.md).
Ainda não cobre todos os critérios do ADR-001. Execução das operações, primitivas CRUD e garantias
transacionais continuam pendentes.

**Próximo passo:** fechar as lacunas declarativas e os critérios restantes da fase 0 com os exemplos da
proposta. Os ADRs restantes (006, 007, 009 a 015, 017 a 019) seguem as dependências do roadmap, antes dos
respectivos componentes. O ADR-003 fixa a camada de dados; a persistência ainda exige o ADR de migrações
e o teste de compatibilidade do Sequel e do `pg` com Ruby 4.0.x, que ele deixa em aberto.

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

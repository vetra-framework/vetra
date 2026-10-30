# Registro de decisões arquiteturais (ADRs)

A proposta técnica lista 21 decisões fundadoras. Os PDFs registram o estado da proposta naquela revisão;
os documentos abaixo desenvolvem essas decisões. Cada ADR deve ser escrito antes da implementação do
componente correspondente. **Os 21 ADRs estão escritos**, e todos ainda têm status **proposto**: nenhum foi
aceito, e nenhum componente além do compilador da fase 0 foi implementado.

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
| [011](011-mcp-com-identidade-delegada.md) | MCP opt-in com identidade delegada, aprovação para sensíveis e limite de taxa | proposto |
| [012](012-canario-em-modo-sombra.md) | Canário em modo sombra com capacidades simuladas | proposto |
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

## Sondas

Alguns ADRs se apoiam em comportamentos de bibliotecas e do PostgreSQL. Em vez de afirmá-los de memória,
cada um tem uma sonda em `script/`, fora da suíte do compilador, que o confere e pode ser repetida em outra
versão. Todas passaram em Ruby 4.0.9. As que usam banco passaram no PostgreSQL 16.15, 17.11 e 18.6, e a CI as roda no 17
e no 18 (job `postgres`).

| Sonda | ADR | O que confere |
|---|---|---|
| `script/sonda_adr002.rb` | [002](002-somente-postgresql.md) | Os requisitos de PostgreSQL: versão mínima, RLS com `FORCE`, combinação e troca de políticas, `security_invoker`, `xmin`, timeouts, `pgcrypto` |
| `script/sonda_adr003.rb` | [003](003-sequel-e-camada-fina-de-repositorios.md) | Parametrização, contexto por `set_config`, savepoints, travas, fibras e agendador |
| `script/sonda_adr006.rb` | [006](006-isolamento-de-dominios-em-tres-niveis.md) | O que o `Ruby::Box` isola e não isola, e gems nativas dentro dele |
| `script/sonda_adr009.rb` | [009](009-workflows-por-historico-e-replay.md) | Replay em Fiber e os limites do bloqueio por `TracePoint` (só biblioteca padrão) |
| `script/sonda_adr015.rb` | [015](015-migracoes-expand-contract.md) | Nível de lock e custo de cada DDL, e a fila de locks |
| `script/sonda_adr019.rb` | [019](019-sinais-efemeros.md) | Limites do `NOTIFY` e o volume de WAL de tabelas `UNLOGGED` |
| `script/sonda_pooler.rb` | [003](003-sequel-e-camada-fina-de-repositorios.md), [005](005-rls-e-contexto-assinado.md), [008](008-ordem-e-continuidade-dos-eventos.md) | O que um pooler em modo de transação faz com contexto, statements nomeados e `LISTEN` (precisa de um PgBouncer à parte) |

Para repetir as sondas de banco no PostgreSQL 17 e na versão estável mais recente (ADR-002), aponte
`DATABASE_URL` para um banco **descartável**; cada script informa o que cria e remove.

## Próximo passo

1. **Revisar e aceitar** os ADRs, começando pelos que a fundação usa: 016, 001, 004, 005, 007 e 003. A
   [lista de revisão](revisao-de-aceite.md) traz a ordem, os critérios e o que conferir em cada um. Um ADR
   aceito não é editado; uma mudança de decisão gera outro que o substitui.
2. **Acompanhar as sondas na CI** (PostgreSQL 17 e 18) e, quando o PostgreSQL 19 estiver disponível, incluí-lo
   na matriz. A sonda do pooler exige um PgBouncer e não roda na CI.
3. **Fechar as lacunas declarativas e os critérios restantes da fase 0** com os exemplos da proposta.
4. Antes de implementar a persistência, resolver as questões em aberto dos ADRs 003, 005, 014 e 015.

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

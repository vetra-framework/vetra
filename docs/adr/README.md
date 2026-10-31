# Registro de decisões arquiteturais (ADRs)

A proposta técnica lista 21 decisões fundadoras. Os PDFs registram o estado da proposta naquela revisão;
os documentos abaixo desenvolvem essas decisões. Cada ADR deve ser escrito antes da implementação do
componente correspondente. **Os 21 ADRs estão escritos e os 21 estão aceitos** (001 a 021). Os ADRs de resolução
(022 em diante) tratam as questões em aberto de um ADR aceito, sem mudar a decisão (veja a [Convenção](#convenção));
há três até agora (022, 023 e 024). Nenhum componente além do compilador da fase 0 foi implementado.

## Escritos

| ADR | Título | Status |
|---|---|---|
| [001](001-grafo-da-aplicacao-e-ir.md) | Grafo da Aplicação compilado em IR versionada | aceito |
| [002](002-somente-postgresql.md) | Somente PostgreSQL | aceito |
| [003](003-sequel-e-camada-fina-de-repositorios.md) | Sequel com camada fina de repositórios | aceito |
| [004](004-capacidades-e-effect-boundary.md) | Capacidades e Effect Boundary | aceito |
| [005](005-rls-e-contexto-assinado.md) | RLS obrigatório com contexto assinado | aceito |
| [006](006-isolamento-de-dominios-em-tres-niveis.md) | Isolamento de domínios em três níveis, com Ruby::Box opcional | aceito |
| [007](007-comando-como-unidade-unica-e-adaptadores.md) | Comando como unidade única de operação e adaptadores de superfície | aceito |
| [008](008-ordem-e-continuidade-dos-eventos.md) | Notificação como invalidação, ordem por xid8 e continuidade | aceito |
| [009](009-workflows-por-historico-e-replay.md) | Workflows duráveis por histórico de eventos e replay determinístico | aceito |
| [010](010-adocao-hospedada-e-modo-servico.md) | Adoção hospedada em Rails ou modo serviço | aceito |
| [011](011-mcp-com-identidade-delegada.md) | MCP opt-in com identidade delegada, aprovação para sensíveis e limite de taxa | aceito |
| [012](012-canario-em-modo-sombra.md) | Canário em modo sombra com capacidades simuladas | aceito |
| [013](013-privacidade-auditoria-e-historico.md) | Privacy, Audit e History separados, com criptografia por envelope | aceito |
| [014](014-outbox-entrega-pelo-menos-uma-vez.md) | Outbox com entrega pelo menos uma vez | aceito |
| [015](015-migracoes-expand-contract.md) | Migrações expand/contract com análise de locks | aceito |
| [016](016-ciclo-de-vida-da-operacao.md) | Ciclo de vida da operação | aceito |
| [017](017-tipo-money.md) | Tipo money nativo | aceito |
| [018](018-camada-de-ui-em-modulos.md) | Camada de UI em módulos fora do núcleo, com ejeção em três níveis | aceito |
| [019](019-sinais-efemeros.md) | Sinais efêmeros autorizados pelo mesmo motor | aceito |
| [020](020-entrega-live-incremental.md) | Entrega live incremental | aceito |
| [021](021-campos-de-transicao.md) | Campos de transição | aceito |
| [022](022-resolucao-das-questoes-do-adr-003.md) | Resolução das questões em aberto do ADR-003 | aceito |
| [023](023-resolucao-das-questoes-do-adr-005.md) | Resolução das questões em aberto do ADR-005 | aceito |
| [024](024-resolucao-das-questoes-do-adr-014.md) | Resolução das questões em aberto do ADR-014 | aceito |

O ADR-001 agora especifica o [esquema IR 0.1](../ir/README.md) e sua política de compatibilidade, atendendo
à pendência documental anterior à fase 0. A decisão foi aceita, mas os testes do compilador/runtime
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
| `script/sonda_adr002.rb` | [002](002-somente-postgresql.md), [005](005-rls-e-contexto-assinado.md), [008](008-ordem-e-continuidade-dos-eventos.md), [014](014-outbox-entrega-pelo-menos-uma-vez.md), [015](015-migracoes-expand-contract.md) | Os requisitos de PostgreSQL: versão mínima, RLS com `FORCE`, combinação e troca de políticas, `security_invoker`, `xmin`, timeouts, `pgcrypto` |
| `script/sonda_adr003.rb` | [003](003-sequel-e-camada-fina-de-repositorios.md) | Parametrização, contexto por `set_config`, savepoints, travas, fibras e agendador |
| `script/sonda_adr006.rb` | [006](006-isolamento-de-dominios-em-tres-niveis.md) | O que o `Ruby::Box` isola e não isola, e gems nativas dentro dele |
| `script/sonda_adr009.rb` | [009](009-workflows-por-historico-e-replay.md) | Replay em Fiber e os limites do bloqueio por `TracePoint` (só biblioteca padrão) |
| `script/sonda_adr015.rb` | [015](015-migracoes-expand-contract.md) | Nível de lock e custo de cada DDL, e a fila de locks |
| `script/sonda_adr019.rb` | [019](019-sinais-efemeros.md) | Limites do `NOTIFY` e o volume de WAL de tabelas `UNLOGGED` |
| `script/sonda_pooler.rb` | [003](003-sequel-e-camada-fina-de-repositorios.md), [005](005-rls-e-contexto-assinado.md), [008](008-ordem-e-continuidade-dos-eventos.md) | O que um pooler em modo de transação faz com contexto, statements nomeados e `LISTEN` (precisa de um PgBouncer à parte) |

Para repetir as sondas de banco no PostgreSQL 17 e na versão estável mais recente (ADR-002), aponte
`DATABASE_URL` para um banco **descartável**; cada script informa o que cria e remove.

## Próximo passo

1. **Os 21 ADRs estão aceitos.** As quatro rodadas da [lista de revisão](revisao-de-aceite.md) foram concluídas.
   Um ADR aceito não é editado; uma mudança de decisão gera outro que o substitui, e uma questão em aberto dele se
   resolve por um ADR de resolução (veja a [Convenção](#convenção)).
2. **Acompanhar as sondas na CI** (PostgreSQL 17 e 18) e, quando o PostgreSQL 19 estiver disponível, incluí-lo
   na matriz. A sonda do pooler exige um PgBouncer e não roda na CI.
3. **Fechar as lacunas declarativas e os critérios restantes da fase 0** com os exemplos da proposta.
4. Antes de implementar a persistência, tratar as questões em aberto dos ADRs 003, 005, 014 e 015, cada ADR por
   um ADR de resolução (veja a [Convenção](#convenção)). O 003 (ADR-022), o 005 (ADR-023) e o 014
   (ADR-024) estão tratados; falta o 015.

## Questões em aberto resolvidas

Os ADRs de resolução ficam registrados aqui, com o ADR que resolvem e as questões que tratam.

| ADR de resolução | Resolve | Questões e tratamento |
|---|---|---|
| [022](022-resolucao-das-questoes-do-adr-003.md) | 003 | 1 poolers (medição); 2 `pg` sob o Falcon (medição); 3 registros (decidida e medição); 4 `uses :sql` (decidida); 5 atualização (valor inicial e adiada); 6 analisador (decidida) |
| [023](023-resolucao-das-questoes-do-adr-005.md) | 005 | 1 custo do HMAC (medição); 2 vínculos múltiplos (decidida, medição e adiada); 3 relatórios entre tenants (adiada); 4 SSO (já resolvida); 5 versão do PostgreSQL (já resolvida) |
| [024](024-resolucao-das-questoes-do-adr-014.md) | 014 | 1 padrões (valor inicial); 2 cursor por handler (já resolvida e adiada); 3 partição (decidida); 4 `authorize` do ator de sistema (decidida); 5 versões de evento (decidida); 6 eventos públicos (decidida e adiada) |

## Convenção

- Um arquivo por decisão, nomeado `NNN-titulo-curto.md` (por exemplo, `016-ciclo-de-vida-da-operacao.md`).
- Use o modelo abaixo.
- Um ADR aceito não é editado; uma mudança de decisão gera um novo ADR que o substitui.
- Uma questão em aberto de um ADR aceito se resolve por um **ADR de resolução**, como descrito a seguir.

### Resolver uma questão em aberto de um ADR aceito

Resolver uma questão **não muda a decisão** do ADR aceito; completa-a. Se a resposta mudasse o que o ADR decide,
não seria resolução, e sim um ADR que o substitui. Como o ADR aceito não é editado, a resolução vive num ADR novo,
com número próprio, no [modelo de resolução](#modelo-de-adr-de-resolução). Ele entra pelo caminho de qualquer ADR:
um PR, e o aceite só vale quando quem revisa o integra.

Cada questão tratada recebe um de cinco tratamentos:

| Tratamento | O que o ADR de resolução traz |
|---|---|
| Decidida | A decisão, as alternativas rejeitadas e o efeito; os testes de aceitação, quando muda comportamento |
| Medição | O que medir, em que ambiente, e **qual resultado decide o quê**: um critério de gate, não uma promessa solta |
| Valor inicial | O valor (por exemplo, "10 tentativas"), o motivo e a medição que pode revisá-lo |
| Já resolvida | O ADR e a seção que a decidiram |
| Adiada | Por que não bloqueia e **o que a faz voltar** (um gatilho) |

1. Uma questão está **tratada** quando tem um dos cinco tratamentos, com o conteúdo que ele pede. "Medição" e
   "Valor inicial" contam como tratadas: têm critério e dono, mas não foram medidas. É nesse sentido que o índice
   pede resolver as questões antes da persistência.
2. O ADR original recebe **uma única linha** no cabeçalho, `- Questões resolvidas por: ADR-NNN`, e nada mais: a
   decisão e a seção de questões ficam como foram aceitas. É da mesma natureza da linha `substituído por` do modelo.
3. O índice registra a resolução na tabela "Questões em aberto resolvidas".

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

## Modelo de ADR de resolução

```markdown
# ADR-NNN: Resolução das questões em aberto do ADR-MMM

- Status: proposto | aceito
- Data: AAAA-MM-DD
- Resolve: ADR-MMM (as questões 1, 3 e 4)
- Depende de: ADR-MMM e os ADRs que as respostas usam

## Contexto

Por que estas questões precisam de resposta agora: o que da implementação depende delas.

## Questões

### 1. A questão, como está no ADR original

- Tratamento: decidida | medição | valor inicial | já resolvida | adiada
- Resposta: o que o tratamento pede (tabela da Convenção).

## Consequências

O que passa a valer, incluindo os custos e os limites.

## Garantia

Nível, mecanismo e testes das questões decididas.
```

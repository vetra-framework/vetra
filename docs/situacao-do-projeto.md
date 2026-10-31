# Situação do projeto

Este arquivo reúne, num só lugar, o que já foi feito, o que espera uma decisão e o que ainda não existe. Ele não
substitui o [índice de ADRs](adr/README.md), a [lista de revisão](adr/revisao-de-aceite.md) nem a
[cobertura dos critérios da fase 0](fase-0-criterios.md): resume os três e aponta para eles.

- **Atualizado em:** 2026-10-31, sobre a main `b70b7f0` (PR #19).
- **Legenda:** `[x]` feito ou confirmado; `[ ]` pendente, incompleto ou não implementado. Cada pendência diz de
  quem é a decisão. "Quem revisa" é quem integra o PR.

## Resumo

| Item | Situação |
|---|---|
| ADRs | 13 aceitos e 8 propostos, de 21 |
| Testes do compilador | 191 testes e 1.325 asserções, sem falhas; os 123 códigos de diagnóstico são disparados por algum teste |
| Critérios da fase 0 (ADR-001) | 8 cobertos e 3 parciais |
| CI da main | Verde no PR #16: `test` e sondas no PostgreSQL 17 e 18 |
| PRs | #1 a #19 integrados |
| Sondas | 7 em `script/`, mais o simulador do gate da CI; 5 rodam na CI (002, 003, 009, 015 e 019) |
| Runtime | Não existe. Só o compilador da fase 0 foi implementado |

## Como manter este arquivo

- Todo PR que muda um status atualiza este arquivo **no mesmo PR**: marque `[x]`, anote o número do PR e ajuste o
  resumo e a data.
- Os contadores de ADR saem dos próprios arquivos. Para conferi-los:

```bash
grep -l '^- Status: aceito' docs/adr/0*.md | wc -l
```

```bash
grep -l '^- Status: proposto' docs/adr/0*.md | wc -l
```

- Os testes são medidos com `bundle exec rake test`, que informa o número de testes e de asserções.
- Item novo entra como `[ ]`, com o responsável pela decisão. Item que deixou de valer é removido, não riscado.

## 1. Feito

**Compilador da fase 0** (DSL Ruby, registro congelado, IR 0.1, validação)
- [x] `graph:build`, `graph:check`, `graph:validate`, `graph:diff` e `graph:link`
- [x] Todos os códigos de diagnóstico têm um teste que os dispara (#8)
- [x] Palavra-chave desconhecida ou ausente falha com `unsupported_option` e `missing_option`, nomeando o método e a
  linha da declaração (#10 e #11)
- [x] Critérios 1, 7 e 10 do ADR-001 conferidos item a item (#9)

**DSL**
- [x] Escopo por vínculo (`memberships`)
- [x] `many_to_many` por entidade de junção declarada ou gerada (#13)
- [x] Papéis, políticas, `crud`, `money`, `decimal`, `enum`, `slug`, privacidade, índices e chaves compostas por
  tenant

**CI e sondas**
- [x] CI com testes, `graph:check`, `graph:validate`, `graph:link` e o gate de diff contra a base (o gate falha
  quando não consegue ler a base, #6)
- [x] Sondas de banco no PostgreSQL 17 e 18 (002, 003, 009, 015 e 019)
- [x] Verdicts das sondas por contagem de varreduras e por relógio do servidor, não por tempo de parede (#7)
- [x] Lista de revisão dos ADRs (#7) e auditoria dos critérios do ADR-001 (#8)

**ADRs**
- [x] Os 21 ADRs estão escritos
- [x] Rodada 1 aceita: 016, 001 e 002 (#12)
- [x] Rodada 2 aceita por inteiro: 003, 005, 006, 008 e 015 (#14), 004 (#16), 007 (#18) e 017 (#19)
- [x] Rodada 3 aceita em parte: 020 (#15) e 010 (#20)
- [x] ADR-020 passou a definir o evento de mudança de linha (trigger gerado, sem campo pessoal), que nenhum ADR
  definia (#15)
- [x] ADR-004 decidiu o dado externo para comandos: sem capacidade de leitura externa nesta versão (#16)
- [x] ADR-007 decidiu que uma exposição não restringe o contrato do comando; uma entrada menor usa campos
  opcionais ou um comando fino (#18)
- [x] ADR-017 decidiu como o `scale` do campo e o expoente da moeda convivem: sem `scale` declarado o campo segue
  a moeda; com `scale` maior é de precisão estendida; `scale` menor que o expoente é erro de compilação (#19)
- [x] ADR-010 decidiu que o Vetra não escreve em tabelas do Rails e que o ator vem da sessão do Rails, por um
  resolvedor declarado pela aplicação (#20)
- [x] `docs/situacao-do-projeto.md` (#17)

Os PRs #1 a #5 reúnem a análise e as correções iniciais, a verificação do Sequel e do `pg` contra um PostgreSQL
real, o escopo por vínculo, as sondas no PostgreSQL 17 e 18 e no PgBouncer, e os três pontos da revisão externa
(troca atômica de política RLS, `memberships` e o gate da CI).

## 2. ADRs

A rodada é a da [lista de revisão](adr/revisao-de-aceite.md). "Decisão" é a pergunta que o ADR deixa a quem revisa.

**Aceitos**
- [x] **001** Grafo da Aplicação e IR (rodada 1, #12)
- [x] **002** Somente PostgreSQL (rodada 1, #12)
- [x] **003** Sequel e camada fina de repositórios (rodada 2, #14)
- [x] **004** Capacidades e Effect Boundary (rodada 2, #16)
- [x] **005** RLS e contexto assinado (rodada 2, #14)
- [x] **006** Isolamento de domínios em três níveis (rodada 2, #14)
- [x] **007** Comando e adaptadores (rodada 2, #18)
- [x] **008** Ordem e continuidade dos eventos (rodada 2, #14)
- [x] **010** Adoção hospedada e modo serviço (rodada 3, #20)
- [x] **015** Migrações expand/contract (rodada 2, #14)
- [x] **016** Ciclo de vida da operação (rodada 1, #12)
- [x] **017** Tipo `money` (rodada 2, #19)
- [x] **020** Entrega live incremental (rodada 3, #15)

**Propostos, com decisão de quem revisa**
- [ ] **013** Privacidade, auditoria e histórico (rodada 3). Decisão: como se identifica o titular de um campo
  pessoal; como o controlador declara retenção obrigatória por exceção legal e como isso convive com a
  eliminação.
- [ ] **014** Outbox (rodada 3). Decisão: qual é o ator de um handler (hipótese: ator de sistema limitado ao tenant
  do evento); fan-out por entrega ou cursor por handler.
- [ ] **011** MCP com identidade delegada (rodada 3). O 007 já está aceito. Decisão: quem classifica os comandos
  como sensíveis; formato da delegação, que estende o contexto assinado `v1` do ADR-005.
- [ ] **018** Camada de UI em módulos (rodada 3). O 007 já está aceito. Decisão: como o gerador versiona os
  templates ejetados e detecta que o contrato mudou.

**Propostos, esperando outro ADR**
- [ ] **009** Workflows por histórico e replay (rodada 4). Depende do 014. Decisão: viabilidade e custo do escalonador
  de fibras determinístico; quem é o ator de um workflow.
- [ ] **019** Sinais efêmeros (rodada 4). Depende do 020, já aceito. Decisão: presença é dado pessoal? Depende do
  013.

**Propostos, a reler antes de propor o aceite**
- [ ] **012** Canário em modo sombra (rodada 3). O 004 já está aceito. Decisão: como o repositório simulado
  representa leituras depois de escritas na mesma operação.
- [ ] **021** Campos de transição (rodada 3). O 004 já está aceito. A lista de revisão não vê questão que mude a
  decisão, mas essa classificação também era "nenhuma" no ADR-020 e escondia uma lacuna. Reler inteiro.

## 3. Decisões e trabalho que dependem de quem revisa

- [ ] Responder as decisões dos ADRs acima, ou aprovar uma recomendação redigida em PR próprio (um PR por ADR, um
  de cada vez na branch de trabalho)
- [ ] Definir uma regra para resolver as questões em aberto de um ADR **já aceito**, que não é editado. Hoje
  não há caminho formal
- [ ] Decidir se o ADR-008 ganha `script/sonda_adr008.rb` (regra de leitura por intervalo, trigger `_v` e
  ressincronização), com CI no PostgreSQL 17 e 18
- [ ] Decidir se o ADR-020 ganha uma sonda (trigger de linha, releitura por grupo)

## 4. Fase 0: critérios do ADR-001

Detalhe e evidência em [fase-0-criterios.md](fase-0-criterios.md).

- [x] **1** Schema válido, exemplos com e sem tenant, falhas estruturais
- [x] **2** Cada regra semântica tem um caso que a dispara
- [x] **3** Mesmo resultado entre checkouts, descoberta embaralhada, vetores Unicode
- [x] **4** O hash reproduz o valor; mudanças invalidam o build
- [x] **5** Versão suportada, MENOR ou MAIOR futura, recurso não implementado
- [ ] **6** Produção recusa IR ausente, adulterada ou incompatível. Parcial: não há servidor de produção
- [ ] **7** Contratos CRUD, políticas e transições equivalem aos três exemplos da proposta. Parcial por desenho: o
  DSL recusa 4 construtos de 14 no blog, 4 de 6 no mini CRM e 6 de 9 no chat
- [x] **8** Mesma IR gera saídas idênticas; `graph:check` detecta edição e desatualização
- [x] **9** O diff distingue remoção, renomeação, capacidade nova, permissão e só origem
- [x] **10** Registro congelado, implementação ausente ou duplicada, recarga como unidade. Coberto, com uma
  limitação de desenho mantida por decisão: o `binding` não guarda o digest da implementação, que fica na IR
- [ ] **11** Compartilhamento de dados entre Ractors. Parcial: a extensão não existe, e o núcleo roda sem ela

## 5. Ainda não implementado

**No DSL** (falham de forma audível, não viram anotação)
- [ ] `auth` e a geração de usuários e vínculos
- [ ] `ui`, MCP e workflows
- [ ] Consultas `live` e `realtime`
- [ ] `rate_limit:` em `can` e `rounding:` em `currency`
- [ ] Moeda por tenant e a conferência do `scale` de `money` contra o expoente da moeda
- [ ] Consulta sem `returns` e sem `authorize`: os exemplos da proposta as omitem, e o compilador exige as duas
- [ ] SQL explícito e metadados de dependência por gem
- [ ] Políticas por atributo do ator além de `id`

**Nos exemplos**
- [ ] Os comandos `add_member` e `remove_member` do chat
- [ ] O `created_at` implícito

**Runtime**
- [ ] Execução das primitivas CRUD e dos comandos (hoje são descritores reconhecidos, sem executor)
- [ ] Persistência e o Vetra Data
- [ ] Modo hospedado em Rails: adaptador Rack, resolvedor do ator e pontes somente leitura para models do Rails
- [ ] Servidor de produção e cache de compilação
- [ ] RLS, entrega de eventos e consultas live em execução. As garantias dos ADRs aceitos valem como decisão, não
  como código

## 6. Lacunas de evidência e limites conhecidos

- [ ] **ADR-008:** a regra de leitura por intervalo, o trigger `_v` e a ressincronização não têm sonda versionada.
  Foram conferidos à mão só no PostgreSQL 16.15
- [ ] **ADR-020:** sem sonda; o que o sustenta são os 12 critérios, ainda sem implementação
- [ ] **ADR-004:** o protótipo cobre os testes de aceitação 2 e 3. Os outros seis dependem do runtime, e o erro de
  `uses` inexistente não foi conferido
- [ ] **ADR-010:** o modo hospedado com o Active Record não foi exercitado, e nenhuma sonda mede a gem
  `sequel-activerecord_connection`. A transação e o contexto de RLS compartilhados e os cinco testes do ADR-003 são
  hipótese até rodarem contra um Rails real. O protótipo não tem ponte com Rails
- [ ] **ADR-017:** o protótipo usa `scale` 2 por padrão e não conhece o expoente ISO 4217: um app em JPY aceitaria
  `100.50` e um em BHD recusaria `1.234`. A verificação do `scale` contra o expoente depende de uma tabela de
  expoentes ainda não adotada; a moeda por tenant exige uma nova MENOR da IR
- [ ] **ADR-007:** o protótipo implementa as regras de rota do §4, mas o teste de aceitação 6 só é exercitado na
  direção comando por `GET`; a direção consulta por `POST` está implementada e sem teste. O DSL declara só
  `expose http:`, então `cli`, `job` e `webhook` existem apenas na IR. Os demais testes dependem do runtime
- [ ] **Sondas manuais:** `sonda_pooler` (precisa de PgBouncer) e `sonda_adr006` (precisa de `RUBY_BOX=1`) não rodam
  na CI. Parte da evidência dos ADRs 003, 005, 006 e 008 vem delas
- [ ] **PostgreSQL 19:** entra na matriz da CI quando existir uma imagem
- [ ] **Persistência:** as questões em aberto dos ADRs 003, 005, 014 e 015 precisam estar resolvidas antes de
  implementá-la
- [ ] **ADR-020:** como o trigger de instrução da revisão de autorização obtém o tenant em escritas sem contexto,
  como o preenchimento do `vetra_migrator`; custo da releitura de campos pessoais por grupo
- [ ] **Diagnósticos:** nada impede que um código de diagnóstico novo nasça sem teste. A medição por rastreio não
  faz parte do repositório

Limite documentado, sem ação prevista: os hashes não autenticam o pacote.

## 7. Próximos passos propostos

Ordem sugerida; cada passo é um PR, e o aceite só vale quando quem revisa o integra.

1. [ ] ADRs 013 e 014: redigir as recomendações
2. [ ] Reler 011, 012, 018 e 021 por inteiro; redigir a recomendação onde houver decisão e propor o aceite onde
   não houver lacuna
3. [ ] Com o 014 aceito, tratar o 009; com o 013, o 019
4. [ ] Fechar as lacunas declarativas da fase 0 e os critérios 6, 7 e 11, com os exemplos da proposta

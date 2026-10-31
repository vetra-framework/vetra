# ADR-025: Resolução das questões em aberto do ADR-015

- Status: proposto
- Data: 2026-10-31
- Resolve: ADR-015 (as seis questões em aberto)
- Depende de: ADR-015 (migrações expand/contract), ADR-001 (IR), ADR-005 (papéis e RLS), ADR-024 (tabelas
  particionadas do framework)
- Relacionados: ADR-002 (somente PostgreSQL), ADR-008 (o `xmin`), ADR-010 (modo hospedado), ADR-021 (campos de
  transição)

## Contexto

O ADR-015 foi aceito com seis questões em aberto, e o índice pede tratá-las antes de implementar a persistência.
Este ADR não muda a decisão do ADR-015 (plano em etapas expand, migrate e contract, classificado por lock e
custo, com `lock_timeout` por passo, caminho só para frente, renomeação nunca inferida e troca atômica de
política). Ele responde o que o ADR-015 deixou aberto, pela regra de resolução do índice.

| # | Questão | Tratamento |
|---|---|---|
| 1 | Como o `db:plan` conhece o esquema atual | Decidida |
| 2 | Tamanho de lote, pausa e `lock_timeout` padrão | Valor inicial |
| 3 | Tabelas particionadas: índices e chaves por partição | Decidida e medição |
| 4 | Custo das chaves estrangeiras compostas por tenant | Decidida e medição |
| 5 | Coordenar a fase contract com o deploy e provar que o código antigo saiu | Decidida |
| 6 | Mudanças de tipo de `enum` e dos valores permitidos | Decidida |

## Questões

### 1. Como o `db:plan` conhece o esquema atual

- Tratamento: **decidida**.
- **Decisão: o `db:plan` planeja contra um retrato commitado, `db/schema.sql`, não contra um banco vivo.** O plano
  tem de ser uma função de artefatos versionados, para ser reproduzível num PR e conferível na CI, como o
  `graph:check` é para o grafo. Um banco vivo (o de desenvolvimento de quem rodou o comando, o de staging) pode
  estar em outro estado, e o mesmo comando daria planos diferentes.
- **Como fecha o circuito:**
  1. O retrato `db/schema.sql` é o `pg_dump --schema-only` do banco de referência depois de aplicados todos os
     planos de `db/plans/` em ordem, em um banco descartável.
  2. `vetra db:plan` compara a IR com esse retrato e grava o próximo plano.
  3. `vetra db:plan --check`, na CI, cria um PostgreSQL descartável, aplica os planos, confere que o retrato
     commitado é o resultado e que a IR atual não tem diferença pendente em relação a ele. Falha se algum dos dois
     divergir (teste 10 do ADR-015).
  4. `vetra db:migrate` no banco de verdade faz uma **verificação prévia por introspecção**: os objetos que o
     plano toca precisam estar como o retrato base diz, e o `vetra.migrations` precisa estar no plano anterior.
     Se divergir (alguém mexeu à mão), recusa sem aplicar nada.
- **A introspecção fica, então, na verificação, não no planejamento.** É o lado fiel do que o ADR-015 pesava; o
  arquivo é o lado revisável. Os exemplos da proposta já mostram um `db/schema.sql` descrito como "retrato do
  banco".
- **Alternativas rejeitadas:**
  - **Introspectar o banco no momento do plano:** o plano depende de onde foi gerado, e a CI não tem esse banco.
  - **Comparar a IR com a IR anterior, sem banco:** descreveria o que mudou no modelo, mas não o que existe no
    banco (passos escritos à mão, deriva) e não serve para o primeiro plano.

### 2. Tamanho de lote, pausa e `lock_timeout` padrão

- Tratamento: **valor inicial**. Todos são hipóteses.
- **`lock_timeout`: 3 s**, como o ADR-015 propõe. Quando estoura (`55P03`), o passo é repetido com espera de 1, 2,
  4, 8 e 16 s, com variação aleatória; depois de 5 tentativas o passo falha e a execução retoma dele (o ADR-015, §5
  já retoma do passo seguinte ao último concluído).
- **Preenchimento em lotes:** começa com **1.000 linhas por commit**. Se um lote levar mais de 200 ms, o tamanho cai
  à metade (mínimo 100); se levar menos de 50 ms, dobra (máximo 10.000). A **pausa entre lotes é igual à duração do
  lote** (no máximo metade do tempo trabalhando). Enquanto a idade do `xmin` passar de 10 s (a métrica do ADR-008,
  §5), o preenchimento espera.
- **O que os revisa:** o preenchimento de uma tabela de 100 milhões de linhas deve terminar numa janela noturna
  (até 8 h) sem subir em mais de 10% a latência p95 da aplicação (limiares hipóteses). Se não, a pausa e o teto do
  lote são ajustados.

### 3. Tabelas particionadas: índices e chaves por partição

- Tratamento: **decidida** (índices) e **medição** (chave estrangeira nas versões da matriz).
- **Conferido no PostgreSQL 16.15** (à mão; limites na seção "Verificação preliminar"):
  - `CREATE INDEX CONCURRENTLY` **não** vale na tabela particionada (`cannot create index on partitioned table ...
    concurrently`).
  - `CREATE INDEX ... ON ONLY <pai>` cria o índice do pai **inválido**; um `CREATE INDEX CONCURRENTLY` em cada
    partição e um `ALTER INDEX <pai> ATTACH PARTITION <índice da partição>` por partição o tornam válido.
  - `ADD FOREIGN KEY ... NOT VALID` **não** vale na tabela particionada (`cannot add NOT VALID foreign key on
    partitioned table ... This feature is not yet supported`). Numa partição sozinha, vale. A chave completa
    (que valida) no pai vale.
  - `ADD CHECK ... NOT VALID` e o `VALIDATE CONSTRAINT` valem no pai.
- **Decisão 1: o padrão para índice em tabela particionada com dados** é `ON ONLY` no pai, `CONCURRENTLY` em cada
  partição e `ATTACH`, nessa ordem, como passos do plano. Uma partição nova deve herdar o índice do pai, e criá-lo
  numa partição vazia é imediato (comportamento documentado do PostgreSQL, não exercitado aqui; o teste 3 o
  confere).
- **Decisão 2: a chave estrangeira em tabela particionada que já tem dados** usa `NOT VALID` e `VALIDATE` **por
  partição** enquanto o pai não aceitar `NOT VALID`. Até a medição abaixo mostrar o contrário, o gerador trata a
  chave do pai de uma tabela particionada cheia como passo **fora da garantia**, marcado no relatório (varre todas
  as partições sob `ShareRowExclusive`).
- **As tabelas particionadas do framework (ADR-024) nascem vazias** na primeira migração, então a chave do pai e
  os índices nelas são imediatos e não passam por esses padrões.
- **Qual resultado decide o quê.** Estender a `sonda_adr015` com estes quatro casos e rodá-la no PostgreSQL 17 e 18
  da CI. Se o 17 ou o 18 aceitarem `NOT VALID` no pai particionado, o padrão da decisão 2 passa a ser o mesmo das
  tabelas comuns (ADR-015, §4) nas versões que aceitarem. Se o `CREATE INDEX CONCURRENTLY` passar a valer no pai, o
  `ON ONLY` com `ATTACH` deixa de ser necessário nelas.

### 4. Custo das chaves estrangeiras compostas por tenant em tabelas grandes

- Tratamento: **decidida** (a ordem dos passos) e **medição** (o custo na escrita).
- **Medido** (PostgreSQL 16.15, tabelas de 1 milhão de linhas, duas execuções): a chave composta
  `(company_id, p_id)` referenciando `(company_id, id)` custa o mesmo que a simples na validação.

| Passo | Chave simples | Chave composta por tenant |
|---|---|---|
| `ADD FOREIGN KEY ... NOT VALID` | 0,7 a 1,4 ms | 0,5 a 1,2 ms |
| `VALIDATE CONSTRAINT` | 663 a 666 ms | 602 a 690 ms |

  O custo extra da composta não está na chave: está no **índice único `(company_id, id)` na tabela referenciada**,
  exigido por ela e redundante para a unicidade (o `id` já é a chave primária). Construí-lo com `CREATE UNIQUE INDEX
  CONCURRENTLY` levou 1,25 s para 1 milhão de linhas e ocupa 30 MB, contra 21 MB da chave primária.
- **Decisão: o índice único de apoio é um passo do plano, na fase expand, antes da chave.** A ordem fica: `CREATE
  UNIQUE INDEX CONCURRENTLY` na tabela referenciada, `ADD FOREIGN KEY ... NOT VALID`, `VALIDATE CONSTRAINT` (o
  padrão do ADR-015, §4). O plano mostra o índice e o custo estimado dele ao revisor.
- **O que fica por medir:** o custo na escrita, de manter o índice a mais na tabela referenciada e de checar a
  chave composta a cada inserção na filha, sob carga. Entra na `sonda_adr015` (teste de aceitação 4). **Qual
  resultado decide o quê:** se manter o índice a mais aumentar a latência p95 de uma inserção em mais de 10%
  (hipótese) em tabela de 1 milhão de linhas, a decisão de gerar a chave composta em todas as relações do mesmo
  tenant (ADR-005, §6) é reaberta por ADR novo.

### 5. Coordenar a fase contract com o deploy e provar que o código antigo saiu de produção

- Tratamento: **decidida**.
- **A prova está no banco, não na ferramenta de deploy.** Cada processo do Vetra (web, worker, relay) se registra
  em `vetra.instances` ao subir e renova um batimento (padrão: a cada 15 s, hipótese), com o número de sequência do
  último plano de que o seu build conhece (`plan_seq`). A fase contract de um passo declara de qual `plan_seq` em
  diante o código não usa mais o que ele remove.
- **A fase contract só roda se**, no momento da execução: nenhuma instância com batimento recente (menos de 3
  intervalos, 45 s) tem `plan_seq` menor que o exigido; e já passou uma carência (padrão: 5 minutos, hipótese)
  desde que a última instância antiga sumiu.
- **O que impede uma corrida.** Ao subir, um processo confere o `plan_seq` do seu build com o `plan_seq` mínimo
  gravado em `vetra.schema_state` pelo último contract aplicado, e **se recusa a subir** se o build for mais antigo.
  Assim uma imagem antiga que o orquestrador reinicie depois do contract não consegue rodar contra o esquema novo.
- **O papel da ferramenta de deploy** (por exemplo, o Kamal) é só disparar: um gancho de pós-deploy chama
  `vetra db:migrate --phase contract`, e a verificação acima decide. O ADR não depende dos ganchos de nenhuma
  ferramenta específica.
- **Limite.** Código fora do Vetra que lê o que o contract remove (o Rails hospedeiro do ADR-010, um relatório, uma
  ferramenta externa) não se registra. O contract que remove um objeto lido por fora exige uma **confirmação
  explícita** no plano (`--confirm-externos`), e fica registrado quem a deu.
- **Alternativa rejeitada:** confiar no sinal de fim de deploy da ferramenta. Prova que o deploy terminou, não que
  nenhum processo antigo (um worker, um job agendado) continua rodando.
- `vetra.instances` não é uma tabela de tenant: não tem dado de empresa nem RLS, e o papel `vetra_app` a escreve,
  como escreve `vetra.outbox` (ADR-014).

### 6. Mudanças de tipo de `enum` e dos valores permitidos

- Tratamento: **decidida**.
- **Hoje nenhum ADR decide o tipo SQL de um `enum`.** A IR 0.1 guarda os valores e os grupos (`values`, `groups`),
  não o tipo no banco.
- **Decisão 1: um `enum` é uma coluna `text` com uma restrição `CHECK (col IN (...))`, nunca um tipo `ENUM` nativo
  do PostgreSQL.** Conferido no 16.15: o tipo nativo **não tem `DROP VALUE`** (`syntax error at or near "VALUE"`), e
  um valor acrescentado com `ADD VALUE` **não pode ser usado na mesma transação** (`unsafe use of new value`), o
  que quebra um plano que acrescenta o valor e já o usa. Remover um valor exigiria recriar o tipo. A restrição
  `CHECK` se troca pelo padrão `NOT VALID` e `VALIDATE` do ADR-015, §4.
- **Decisão 2: acrescentar um valor é expand.** Cria-se a restrição nova, mais larga, com `NOT VALID`, valida-se e
  remove-se a antiga. Nenhuma linha existente pode violar uma restrição mais larga.
- **Decisão 3: remover um valor é em fases.** Primeiro o código deixa de gravá-lo (a fase contract exige a prova da
  questão 5); o preenchimento em lotes move as linhas que ainda o têm (migrate); só então a restrição mais estreita
  entra com `NOT VALID`, é validada, e a antiga sai.
- **Decisão 4: renomear um valor nunca é inferido.** É acrescentar o novo, migrar as linhas e remover o antigo,
  como a renomeação de coluna (ADR-015, §1).
- **Alternativa rejeitada:** o tipo `ENUM` nativo, pelas duas limitações acima.
- O `graph:diff` já classifica a mudança de valores de um `enum` como mudança de contrato, e o plano acrescenta o
  passo de armazenamento.

## Consequências

- O ADR-015 passa a ter todas as questões tratadas. As que decidem estrutura (o retrato, o índice em tabela
  particionada, a ordem da FK composta, a prova do contract, o `enum` como `text` com `CHECK`) estão fechadas;
  duas têm medições com critério (a FK em tabela particionada nas versões da matriz e o custo de escrita da FK
  composta); o lote e a pausa são valores iniciais.
- O gerador de migrações passa a ter: `db/schema.sql` como base do plano, a verificação prévia por introspecção, o
  padrão de índice em tabela particionada, o índice único de apoio da FK composta, `vetra.instances` e
  `vetra.schema_state`, e o mapa de `enum` para `text` com `CHECK`. O compilador do protótipo não gera SQL hoje, e
  este ADR não altera nada nele.
- A `sonda_adr015` ganha quatro casos (índice e FK em tabela particionada, FK composta, `CHECK` de `enum`) quando a
  persistência for implementada.
- Cada processo do Vetra escreve um batimento periódico no banco.
- O custo para o desenvolvedor: a CI precisa de um PostgreSQL descartável para o `db:plan --check`. A CI do
  repositório já tem um.

## Garantia

| Garantia | Nível | Mecanismo |
|---|---|---|
| O plano é função de artefatos versionados | Estrutural | `db/schema.sql`, `db/plans/` e a IR; `db:plan --check` |
| Um deploy não aplica um plano num banco que mudou à mão | Transacional | Verificação prévia por introspecção e `vetra.migrations` |
| O contract não roda enquanto uma instância antiga está viva | Operacional | Batimentos em `vetra.instances` e carência |
| Uma imagem antiga não sobe contra o esquema depois do contract | Verificável por testes | `plan_seq` mínimo em `vetra.schema_state` |
| Acrescentar ou remover um valor de `enum` não parte o código N-1 | Verificável por testes | `text` com `CHECK` trocado por `NOT VALID` e `VALIDATE`, em fases |
| Código fora do Vetra que lê o removido | **Fora da garantia** | Confirmação explícita, registrada |

Testes de aceitação das questões decididas:

1. O `db:plan --check` falha quando o retrato commitado não é o resultado dos planos, e quando a IR mudou e o plano
   não.
2. O `db:migrate` recusa um banco cuja estrutura toca divergiu do retrato base, sem aplicar nenhum passo.
3. Um índice em tabela particionada com dados é criado por `ON ONLY`, `CONCURRENTLY` por partição e `ATTACH`, e o
   pai fica válido; uma partição nova já nasce com o índice.
4. Estendida a `sonda_adr015` com a FK composta por tenant: o índice único de apoio vem antes da chave, e a
   validação não bloqueia escrita. A mesma sonda confere, no 17 e no 18, o comportamento do `NOT VALID` na tabela
   particionada.
5. O contract é recusado enquanto uma instância com `plan_seq` menor tem batimento recente, e aplicado depois da
   carência.
6. Um processo cujo build tem `plan_seq` menor que o mínimo de `vetra.schema_state` se recusa a subir.
7. Acrescentar um valor de `enum` não deixa o código antigo falhar; remover um valor só roda depois que nenhuma
   linha o tem e nenhuma instância antiga o grava.
8. Um contract que remove um objeto marcado como lido por fora não roda sem `--confirm-externos`.

## Verificação preliminar

Conferido à mão, **sem sonda versionada**, num banco descartável do PostgreSQL 16.15 (não o 17 nem o 18):

- Tabela particionada em 3 partições, 30 mil linhas: `CREATE INDEX CONCURRENTLY` no pai falha; `ON ONLY` mais
  `CONCURRENTLY` por partição e `ATTACH` deixam o índice do pai válido (inválido logo depois do `ON ONLY`); `ADD
  FOREIGN KEY ... NOT VALID` no pai falha, e vale numa partição; a chave que valida vale no pai; `CHECK ... NOT
  VALID` e o `VALIDATE` valem no pai.
- Duas tabelas de 1 milhão de linhas (64 MB e 71 MB): `CREATE UNIQUE INDEX CONCURRENTLY (company_id, id)` em 1.247
  ms (30 MB); a chave simples e a composta, duas execuções cada, nos tempos da questão 4.
- Tipo `ENUM` nativo: `ALTER TYPE ... DROP VALUE` não existe; `ADD VALUE` seguido do uso do valor na mesma
  transação falha.
- Procurado nos ADRs e na documentação, sem achar decisão sobre o tipo SQL de um `enum`; a IR guarda `values` e
  `groups` e o `storage` da entidade só tem tabela, esquema e chave primária.

**O que isto não cobre.** Não foi exercitado o PostgreSQL 17 nem o 18, a escrita concorrente, o custo de manter o
índice de apoio sob carga, o lote adaptativo nem o `vetra.instances`: o desenho da questão 5 não tem protótipo. Os
tempos são de uma máquina e de um volume, e fixam ordens de grandeza. Nada foi criado como código ou teste no
repositório: o banco e os scripts eram descartáveis e foram removidos.

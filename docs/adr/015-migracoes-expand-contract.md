# ADR-015: Migrações expand/contract com análise de locks

- Status: proposto
- Data: 2026-10-30
- Depende de: ADR-002 (somente PostgreSQL), ADR-001 (Grafo da Aplicação e IR)
- Relacionados: ADR-005 (papéis do banco e políticas RLS), ADR-008 (o `xmin` e a entrega de eventos), ADR-016
  (ciclo de vida da operação)

## Contexto

No Rails, uma migração roda o DDL com o comportamento de lock padrão do PostgreSQL. Duas armadilhas se repetem:

1. **Comandos que parecem inofensivos seguram um lock exclusivo por muito tempo** (reescrever a tabela,
   varrê-la para validar uma restrição) e derrubam a aplicação enquanto isso.
2. **Um DDL que espera um lock também bloqueia quem chega depois dele.** O pedido de lock entra numa fila, e as
   leituras comuns que chegam em seguida esperam atrás dele, mesmo sem conflitar com quem o DDL espera.

O Vetra gera o esquema a partir do grafo, então gera também o DDL, e isso o torna responsável por não
produzir migrações que parem o sistema. A proposta registra a decisão como "migrações expand/contract com
análise de locks", rejeitando o "SQL gerado aplicado diretamente". O risco listado é "locks e
indisponibilidade".

## Decisão

**A mudança de modelo gera um plano de migração em etapas, versionado e revisável. Cada passo é classificado
pelo lock que pede e pelo custo que tem, e só roda com limite de espera para o lock.**

### 1. Do grafo ao plano

- `vetra db:plan` compara a IR (`.vetra/graph.json`) com o esquema atual e grava um **plano** em `db/plans/`.
  O plano é texto revisável: lista os passos em SQL, em que fase cada um roda e o lock que pede.
- `vetra db:migrate` aplica o plano com o papel `vetra_migrator`. A credencial desse papel existe só no
  pipeline de deploy; a aplicação em runtime nunca a usa (ADR-005).
- O plano deve estar no Git e `vetra db:plan --check` falha quando ele diverge da IR, como o `graph:check` faz
  com o grafo.
- O gerador só produz DDL de PostgreSQL (ADR-002). As políticas de RLS geradas ficam em `db/policies/`,
  versionadas junto com o plano (ADR-005).
- **Renomeação nunca é inferida.** Uma coluna ou tabela só é renomeada quando a entidade declara o nome
  anterior (`was:`, que a IR registra em `previous_names` e `previous_ids`). Sem a declaração, uma remoção e
  uma adição são duas mudanças.

### 2. Três fases

| Fase | O que faz | Compatível com o código antigo? |
|---|---|---|
| **Expand** | Acrescenta o que o código novo precisa, sem tirar nada | Sim |
| **Migrate** | Preenche dados em lotes e, se preciso, mantém os dois lados sincronizados | Sim |
| **Contract** | Remove o que o código novo não usa mais | Só depois que nenhuma instância antiga roda |

- Depois do expand, as versões N-1 e N do código funcionam. É essa a condição para deploy sem parada.
- Cada fase pode ser aplicada em um deploy diferente, e o plano diz qual. O contract é a única fase que
  exige a certeza de que o código antigo saiu de produção.
- O caminho é para frente. Desfazer uma migração é escrever outra, não executar um `down`.

### 3. Análise de locks

Cada passo do plano recebe uma classificação, que é a mesma que o `vetra db:plan` mostra ao revisor. Os valores
abaixo foram medidos pela sonda `script/sonda_adr015.rb` (22 de 22 verificações) nos PostgreSQL **16.15, 17.11
e 18.6**, com Ruby 4.0.9, usando uma tabela de 1 milhão de linhas. Os níveis de lock e a diferença entre as
formas foram **iguais nas três versões**:

| Operação | Lock na tabela | Custo medido |
|---|---|---|
| `ADD COLUMN` nulo | `AccessExclusive` (breve) | Sem reescrita |
| `ADD COLUMN ... NOT NULL DEFAULT <constante>` | `AccessExclusive` (breve) | Sem reescrita |
| `ADD COLUMN ... DEFAULT <volátil>` (ex.: `random()`) | `AccessExclusive` | **Reescreve a tabela** |
| `ALTER COLUMN TYPE int -> bigint` | `AccessExclusive` | **Reescreve a tabela** |
| `RENAME COLUMN`, `DROP COLUMN` | `AccessExclusive` (breve) | Só catálogo |
| `CREATE INDEX` | `Share` (bloqueia escritas) | Varre a tabela |
| `CREATE INDEX CONCURRENTLY` | `ShareUpdateExclusive` | Não roda dentro de transação |
| `ADD FOREIGN KEY` | `ShareRowExclusive` nas duas tabelas | Varre a tabela |
| `ADD FOREIGN KEY ... NOT VALID` | `ShareRowExclusive` nas duas tabelas | ~1 ms (não varre) |
| `ADD CHECK ... NOT VALID` | `AccessExclusive` (breve) | Não varre |
| `VALIDATE CONSTRAINT` | `ShareUpdateExclusive` (e `RowShare` na tabela referenciada) | ~110 ms (varre, sem bloquear escrita) |
| `SET NOT NULL` sem `CHECK` validado | `AccessExclusive` | ~120 ms (varre sob lock exclusivo) |
| `SET NOT NULL` com `CHECK (col IS NOT NULL)` validado | `AccessExclusive` (breve) | ~1 ms |
| `ENABLE`/`FORCE ROW LEVEL SECURITY`, `CREATE`/`ALTER`/`DROP POLICY` | `AccessExclusive` (breve) | Só catálogo |

Os tempos são de uma máquina e de um volume (por exemplo, `SET NOT NULL` sem `CHECK` levou de 116 a 186 ms nas
medições, e com o `CHECK` validado, 1 ms); o que importa é a **diferença entre as formas**. A sonda a confere
pelo que o servidor registra, se a operação **varre** a tabela (contador de varreduras sequenciais), e não pelo
relógio: o tempo oscila com checkpoint, autovacuum e a carga da máquina, e a sonda o mostra só como indício.
O contador deu 1 varredura sem o `CHECK` validado e 0 com ele, e 0 em `ADD FOREIGN KEY ... NOT VALID` contra 1
em `VALIDATE CONSTRAINT`, nas três versões medidas (a matriz do ADR-002 é 17 e 18; a 16 entra como referência).

Observação importante: `ADD FOREIGN KEY ... NOT VALID` **não reduz o nível de lock**; reduz a **duração**,
porque a varredura vai para o `VALIDATE CONSTRAINT`, que não bloqueia escritas.

### 4. Padrões seguros que o gerador aplica

- **Coluna `NOT NULL` em tabela existente:** `ADD COLUMN` nulo, preenchimento em lotes, `ADD CONSTRAINT CHECK
  (col IS NOT NULL) NOT VALID`, `VALIDATE CONSTRAINT`, `SET NOT NULL`, remoção do `CHECK`.
- **Chave estrangeira (inclusive as compostas por tenant):** `NOT VALID` e depois `VALIDATE`.
- **Índice em tabela com dados:** `CREATE INDEX CONCURRENTLY`, fora de transação. Uma falha deixa um índice
  inválido; o plano verifica a existência de índices inválidos e os recria.
- **Mudança de tipo e default volátil:** coluna nova, preenchimento em lotes, troca de leitura e escrita, e só
  então a remoção da antiga, em fases separadas.
- **Renomeação declarada:** coluna nova, escrita nos dois lados durante o deploy, preenchimento, troca de
  leitura e, na fase contract, remoção da antiga. `RENAME` direto quebraria o código antigo.
- **Política RLS que muda:** a troca é **atômica e indivisível**: `ALTER POLICY` (que troca `USING` e
  `WITH CHECK`) ou `DROP POLICY` seguido de `CREATE POLICY` **na mesma transação**, quando muda o comando ou a
  classificação permissiva/restritiva, que o `ALTER POLICY` não altera. A política nova preserva `USING`,
  `WITH CHECK`, comando e classificação que o grafo declara. Os dois passos nunca ficam em etapas ou deploys
  separados. Criar a nova antes de remover a antiga, em passos distintos, **expõe a união dos acessos**: as
  políticas permissivas se combinam por OR, então o acesso que deveria ser revogado continua valendo até o
  `DROP`, e um plano interrompido no meio deixa a união permanente (medido: um leitor viu o conjunto antigo, a
  união e só então o novo). Dentro de uma transação, esses comandos seguram `AccessExclusive` até o commit: os
  leitores esperam e depois enxergam apenas o estado novo, nunca a união nem o vazio. Uma falha desfaz a
  transação e preserva a política anterior.

### 5. Todo passo roda com limite de espera

- Cada passo que pede lock forte roda com `lock_timeout` curto (padrão proposto: 3 s) e é **repetido com
  espera crescente** quando estoura (SQLSTATE `55P03`). Sem esse limite, o DDL na fila bloqueia as leituras
  que chegam depois dele (medido: uma leitura simples estourou o `statement_timeout` enquanto um `ALTER TABLE`
  esperava atrás de uma transação aberta).
- Preenchimentos rodam em lotes pequenos, com commit entre eles e pausa configurável, para não segurar
  transação longa (que atrasaria o `xmin` e a entrega de eventos, ADR-008).
- Um único migrador roda por vez, serializado por um lock consultivo. O estado de cada passo fica em
  `vetra.migrations`, e uma execução interrompida retoma do passo seguinte ao último concluído.

### 6. O que a análise não cobre

- Só as formas de DDL da tabela acima são classificadas. Um passo escrito à mão (SQL explícito num plano) fica
  **fora da garantia** e é marcado como tal no relatório.
- A classificação diz o lock e o custo esperados, não prevê o tempo em um banco concreto: isso depende do
  volume e da carga.

## Alternativas rejeitadas

- **Aplicar diretamente o SQL gerado** (a alternativa da proposta): cada mudança de modelo viraria um risco de
  indisponibilidade, e o revisor não veria o lock de cada passo.
- **Migrações escritas à mão como no Rails:** devolve ao desenvolvedor o conhecimento sobre locks, que é o que
  o gerador deveria carregar.
- **Janela de manutenção:** resolve o lock, mas contradiz o objetivo de deploy sem parada.
- **`down` automático:** não restaura dados preenchidos nem remove com segurança o que o código novo já usa.
  Roll-forward é mais previsível.
- **Criar a política nova antes de remover a antiga, em passos separados** (era o procedimento deste ADR): a
  união temporária concede acesso que devia ser revogado, e um plano interrompido a torna permanente.
- **Inferir renomeações por semelhança de nome ou tipo:** pode apagar dado. A renomeação é sempre declarada
  (ADR-001).
- **Ferramentas externas de mudança online como requisito:** o núcleo precisa funcionar só com PostgreSQL.

## Consequências

- Deploy sem parada, ao custo de mudanças em mais etapas, algumas em deploys diferentes.
- O revisor lê, no plano, o lock e o custo de cada passo, e o diff arquitetural (`graph:diff`) já separa as
  mudanças de contrato das de armazenamento.
- Tabelas grandes exigem preenchimento em lotes, que é lento por desenho.
- Quem escreve SQL à mão num plano assume a responsabilidade e é identificado no relatório.
- A mesma sonda serve de teste de regressão quando o PostgreSQL mudar o comportamento de algum DDL.

## Garantias e seus níveis

| Garantia | Nível | Mecanismo |
|---|---|---|
| Cada passo conhecido é classificado por lock e custo | Verificável por testes | Tabela acima conferida pela sonda em cada versão da matriz |
| Nenhum passo espera um lock além do limite | Transacional | `lock_timeout` por passo, com repetição |
| Código N-1 e N funcionam depois do expand | Verificável por testes | Suíte executada contra o esquema expandido |
| Plano revisável e sem divergência da IR | Estrutural | `db:plan --check` |
| A troca de uma política não concede a união dos acessos nem nega a todos | Transacional e verificável por testes | `ALTER POLICY` ou `DROP` + `CREATE` na mesma transação (`script/sonda_adr002.rb`) |
| Passos escritos à mão | **Fora da garantia** | Marcados no relatório |

## Testes de aceitação

1. Para cada forma de DDL da tabela, o plano gerado traz o lock e o custo medidos na sonda.
2. Depois da fase expand, a suíte da versão anterior e a da atual passam contra o mesmo banco.
3. Um passo que não obtém o lock em `lock_timeout` falha sem efeito colateral e é repetido.
4. Durante um passo à espera de lock, uma leitura comum não espera mais que o `lock_timeout`.
5. Um `SET NOT NULL` em tabela de 1 milhão de linhas segura o lock exclusivo por tempo da ordem de
   milissegundos, não da varredura.
6. Um `CREATE INDEX CONCURRENTLY` interrompido é detectado como inválido e recriado.
7. Uma renomeação só é gerada com `was:` declarado; sem ele, o plano traz remoção e adição.
8. Um preenchimento em lotes não deixa transação aberta além do lote (o `xmin` avança durante ele).
9. Duas execuções simultâneas de `db:migrate` não aplicam o mesmo passo duas vezes.
10. `db:plan --check` falha quando a IR mudou e o plano não.
11. A suíte e a sonda rodam no PostgreSQL 17 e na versão estável mais recente (ADR-002).
12. Com um leitor consultando durante a troca de uma política, ele vê o estado antigo e depois o novo, nunca a
    união nem o vazio; uma falha no `CREATE` preserva a política anterior; a política nova mantém `USING`,
    `WITH CHECK`, comando e classificação permissiva/restritiva do grafo.

## Questões em aberto

- Como o `db:plan` conhece o esquema atual: introspecção do banco ou `db/schema.sql`. A introspecção é mais
  fiel; o arquivo é mais simples de revisar.
- Tamanho de lote, pausa e `lock_timeout` padrão (3 s é hipótese) e como se adaptam à carga.
- Tabelas particionadas e a criação de índices e chaves em cada partição.
- Custo de criar as chaves estrangeiras compostas por tenant em tabelas grandes (ADR-005).
- Como coordenar a fase contract com o processo de deploy (por exemplo, Kamal) e como provar que o código
  antigo saiu de produção.
- Mudanças de tipo de `enum` e de valores permitidos, que o diff arquitetural já classifica como contrato.

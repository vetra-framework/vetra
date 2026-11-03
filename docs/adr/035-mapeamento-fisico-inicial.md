# ADR-035: Mapeamento físico inicial do grafo para PostgreSQL

- Status: aceito
- Aceite: 2026-11-03, pelo Claude por delegação do mantenedor, após a auditoria da C5, com o DDL dos quatro exemplos aplicado no PostgreSQL 18.6.
- Data: 2026-11-03
- Depende de: ADR-001, ADR-002, ADR-005, ADR-017, ADR-021, ADR-025, ADR-026 e ADR-027

## Contexto

A IR descreve entidades, tipos, relações, índices e atribuição, mas não decide sua representação física.
A persistência precisa de um modelo determinístico e do DDL de um banco vazio antes de produzir planos.
Os quatro exemplos incluem aplicações globais, tenant implícito, raiz global de tenant, junções e uma
FK opcional composta por tenant. Traduzir apenas `belongs_to` perderia a integridade do tenant implícito.

## Decisão

### 1. Tipos e representação

| Tipo lógico | Armazenamento e motivo |
|---|---|
| `id` | `uuid` em todas as colunas, inclusive ator externo sem entidade. PK simples `id NOT NULL`, com UUID v4 gerado por `pg_catalog.gen_random_uuid()` no banco, disponível no PostgreSQL 17 sem extensão. Referências não recebem esse default. O repositório pode fornecer UUID já alocado para simulação; a geração padrão é do banco. UUID informado como literal deve ter a forma hexadecimal completa com hífens; geração v4 não restringe as versões armazenáveis. |
| `string`, `text`, `email` | `text`; `min:`/`max:` viram `CHECK` de `char_length` (caracteres, não bytes), sem tamanho implícito. Evita mudar o tipo ao alterar um limite. `slug` já é `string` com geração no repositório, sem expressão SQL de geração. |
| `integer` | `bigint`, inteiro assinado de 64 bits; evita o limite de 32 bits. Literais continuam sujeitos ao intervalo seguro da IR; não se impõe esse limite JSON ao armazenamento. |
| `decimal` | `numeric(precision, scale)` da IR, sem arredondamento durante a geração. `CHECK` recusa `NaN`. Escala/precisão e arredondamento de valores em execução permanecem nos contratos e no repositório. |
| `boolean` | `boolean`, sem default implícito `false`. |
| `date` | `date`, dia civil sem horário nem fuso. Defaults literais restringem-se a anos 0001 a 9999. |
| `timestamp` | `timestamp(6) with time zone`, instante com precisão de microssegundos. Literais precisam de `Z` ou deslocamento `±HH:MM`, ano 0001 a 9999 e até seis casas; são serializados em UTC. O repositório usará o mesmo contrato na borda. O fuso original não é preservado. |
| `json` | `jsonb`, para igualdade e índices futuros; a forma textual, ordem das chaves e espaços não são preservados. |
| `enum` | `text` com `CHECK IN`, já decidido pelo ADR-025 §6. Grupos não criam tipos ou colunas. |
| `money` | Duas colunas `<campo>_amount numeric(p,s)` e `<campo>_currency text`, como o ADR-017. Ambas herdam `nullable`; `CHECK` garante nulas juntas, recusa `NaN` e limita a moeda aos códigos da tabela ISO do ADR-026 cujo expoente cabe na escala. O valor não recebe uma moeda silenciosa no banco. |
| `record`, `collection` | Formas de saída, sem armazenamento: a validação da IR já as recusa em entidades. |

`email` não impõe tamanho, regex, extensão `citext` ou unicidade implícitos. Sem `normalize`, a unicidade
usa a igualdade textual do banco. Com `normalize: downcase`, o repositório normaliza e um `CHECK (col =
lower(col))` recusa gravações fora da forma normalizada; a chave única continua sobre a coluna comum.
Isso permite usá-la como destino de FK, sem índice de expressão. `downcase` também vale para os demais
tipos textuais. A collation/locale do banco participa de `lower` e da igualdade: a implantação deve fixá-la
e a auditoria deve conferir entradas Unicode; este gerador não promete igualdade Unicode independente
de locale entre Ruby e PostgreSQL. Limites de comprimento ou normalização em tipos não textuais são recusados.

### 2. Nulidade, defaults e regras de atribuição

Somente `nullable` decide `NOT NULL`; `required` trata da entrada. Um campo opcional com default pode ser
não nulo, e um timestamp de transição obrigatório na entrada pode ser nulo no banco.

Defaults literais viram constantes SQL tipadas; `null` vira `DEFAULT NULL`. Dinheiro desdobra também o
default nas duas colunas. Um default que não cabe no tipo físico, comprimento ou normalização é recusado,
em vez de gerar DDL que criaria uma tabela com um default inutilizável. SQL fornecido pelo usuário não é
aceito. Os únicos valores no DDL são literais declarativos versionados (defaults, enums e moedas),
serializados por tipo e escapados como `E'…'`, inclusive barras e apóstrofos. `U+0000`, inclusive em chaves
ou valores de defaults JSON, recebe diagnóstico porque PostgreSQL `text`/`jsonb` não o armazena.

Defaults `current_actor` e `current_tenant`, geração de slug e atribuições de transição ficam no modelo
em `assignments`, para o repositório, sem `DEFAULT` SQL nem consulta ao contexto durante a geração.
`created_at` é não nulo, mas **não** recebe `now()` ou outro default de banco: pertence ao relógio do
repositório da operação, fixado uma vez na criação (ADR-027), em UTC com microssegundos.

`set_by` e `guarded` conservam as colunas, seus defaults permitidos e checks de tipo. O modelo conserva
os comandos donos, valores protegidos e `transitions.enforce`. Não transforma a guarda de transição num
`CHECK` que proibiria para sempre o valor protegido. Os triggers que conferem o comando com `enforce: db`
pertencem à C7; na C5, a existência da coluna não garante a proteção de transições.

### 3. Nomes, índices e colisões

Schemas e tabelas vêm de `entity.storage`; colunas usam o nome do campo, exceto o desdobramento de `money`.
Não se infere renomeação a partir de `previous_names`/`previous_ids`. Não se pluraliza de novo.
Todo identificador interpolado é validado: `[a-z][a-z0-9_]*`, ASCII, até **63 bytes**, sempre entre aspas
duplas. Nomes explícitos longos são recusados; nunca se deixa o PostgreSQL truncá-los silenciosamente.
Colunas de sistema (`tableoid`, `xmin`, `cmin`, `xmax`, `cmax`, `ctid`) e schemas `pg_*`,
`information_schema`, `vetra` e `vetra_private` são reservados; os dois últimos ficam para a infraestrutura.

Nomes gerados são `vt_<espécie>_<32 hex de SHA-256>`, com espécies `pk`, `uq`, `ix`, `ck` e `fk`.
O hash usa o JSON canônico da identidade física: `[schema, tabela, espécie, ...partes]`. As partes são
colunas para PK/única/índice; subtipo e campo para check; colunas locais, `[schema,tabela]` de destino e
colunas remotas para FK. Não dependem do digest do grafo, nome da aplicação, ordinal ou nome lógico do
índice da IR. Alterar a ordem de declarações não renomeia objetos. Uma mudança de expressão de check
mantém sua identidade, para que o planejador compare a expressão. Os nomes de índice da IR são validados,
mas não são os nomes físicos. Uma colisão de hash também é recusada, nunca resolvida com contador de ordem.

O gerador detecta tabelas duplicadas, colunas sobrepostas (incluindo `money`) e colisões de constraints
por tabela e de relações por schema (tabelas e índices, inclusive índices de PK/únicas). Não há truncamento
nem sufixo silencioso. Índices de mesmo tipo e mesmas colunas são deduplicados por estrutura.

Chaves únicas são constraints `UNIQUE` não adiáveis, com o índice único B-tree que o PostgreSQL cria.
Nulos continuam distintos (padrão PostgreSQL). `constraints.unique` também é honrada se uma IR externa
válida não trouxer o índice redundante. Índices lógicos de dinheiro expandem para valor e moeda, nessa
ordem. Índices de entidades com tenant começam pelo campo de tenant (ADR-005); a PK global `id` é a exceção
já prevista nesse modelo. Cada entidade com tenant ganha a única `(tenant, id)`, mesmo se ausente na IR;
é o índice de apoio da FK composta (ADR-025 §4). Índices nas colunas de FK são adicionados quando nenhuma
PK/única/índice existente cobre esse prefixo. Não há índices implícitos em colunas globais sem FK.

Índices parciais (`where`), embora representáveis na IR, são **recusados** com diagnóstico próprio.
A linguagem de predicados inclui contexto, entradas e relações; aceitá-la como SQL imutável exigiria um
subconjunto e decisões adicionais. Não se ignora o predicado nem se promove unicidade parcial a integral.

### 4. FKs, junções e ordem de criação

Toda `belongs_to` produz uma FK sobre as chaves da IR, com tipos físicos e modificadores iguais de cada
lado. O destino precisa de PK ou chave única integral na mesma ordem. Não se inventa uma regra de unicidade
de negócio para fazer uma relação inválida funcionar. FKs entre entidades com tenant preservam o par
composto da IR; a única `(tenant, id)` está pronta antes da FK.

Ações são **`ON DELETE NO ACTION ON UPDATE NO ACTION`**, para evitar exclusões em cascata e mudanças
silenciosas de identidade. São **`DEFERRABLE INITIALLY IMMEDIATE`**: a integridade é imediata por padrão;
uma transação pode explicitamente adiar as FKs para inserir ou remover um ciclo. PKs e únicas permanecem
não adiáveis, como exige o alvo de uma FK no PostgreSQL.

Usa-se **`MATCH SIMPLE`**: qualquer componente nulo dispensa a referência. O tenant é sempre não nulo e
tem sua própria FK simples para a raiz, portanto `(company_id, seller_id NULL)` é válido sem dispensar a
integridade da empresa. Se `seller_id` for preenchido, o par tem de existir no mesmo tenant. A mesma regra
vale para tuplas maiores; não se inventa obrigatoriedade conjunta além do `nullable` declarado.

Junções já são entidades: recebem tabelas, PKs, únicas e FKs de suas próprias `belongs_to`, inclusive
junções geradas. `many_to_many` não cria outra tabela. `has_many` não duplica a FK inversa. Referências de
tipo `id.entity` sem relação não implicam FK automaticamente, com a exceção explícita do tenant abaixo.
FKs fisicamente idênticas são deduplicadas.

As tabelas têm ordem lexicográfica por `(schema, table, entity)`, não topológica. Há três blocos:
`schemas` (cria schemas de aplicação exceto `public`, que já existe), `tables` (todas as tabelas, checks,
PKs, únicas e índices) e `foreign_keys` (todos os `ALTER TABLE ADD … FOREIGN KEY`). Isso resolve ciclos de
criação, sem escolher uma entidade privilegiada. Não há `IF NOT EXISTS`, substituição de objetos, conexão,
transação embutida ou controle de lock: a K7 compõe as instruções em passos com essas propriedades.
Aplicar duas vezes deve falhar, e a atomicidade pertence ao aplicador.

### 5. Tenant e proteção da raiz

Toda entidade com `entity.tenant` recebe a FK simples de `tenant.field` para a PK `id` da raiz, mesmo
sem `belongs_to`: cobre `dealer` e `user` do mini CRM com revendas. A relação explícita equivalente é
deduplicada. A raiz exige PK simples UUID `id` não nulo e não recebe uma FK para si própria.
Este mapeamento inicial exige essa mesma forma de PK nas demais entidades, como o DSL já gera; IR externa
com outra PK recebe diagnóstico próprio, sem conversão ou descarte silencioso.

O modelo distingue `scope: tenant_root` (raiz, `tenant_column: id`), `tenant` (filhas, coluna da IR) e
`global` (aplicação sem tenant, coluna nula). O `tenant: null` da raiz **não** a classifica como tabela
global desprotegida. A C7 deve usar essa classificação para proteger explicitamente a raiz por `id`, além
das filhas; a C6 define os papéis. A C5 não instala RLS nem concede DML. Blog e chat continuam globais,
sem tenant inventado, política de tenant ou revisão de autorização; suas FKs comuns são preservadas.

### 6. Contrato do gerador e compatibilidade

`Vetra::SQL::Schema.new(document).generate` valida e copia a IR e devolve modelo, blocos de instruções,
SQL concatenado e avisos, todos profundamente congelados. Sem ambiente, relógio, fontes ou banco; os
literais JSON são canônicos, e nós, campos, relações, índices e valores de enum têm ordenação estável.
Documentos de IR anteriores conservam seus campos: não se acrescenta `created_at` retroativamente.

Não há recurso ou significado novo na IR, versão MENOR ou requisito em `requires`: armazenamento é um
consumidor derivado dos dados existentes, sem mudar sua interpretação lógica. Recusas próprias do
consumidor SQL não enfraquecem a validação do grafo. Um futuro recurso declarativo que mude a IR seguirá
o ADR-001 §4, com nova MENOR e requisito somente quando usado.

## Alternativas rejeitadas

- Sequência/`bigserial`: exige estado para alocar IDs e torna referências externas mais dependentes do banco.
  UUID v7: a função nativa não é comum ao PostgreSQL 17 e 18; não se introduz extensão só para gerar IDs.
  UUID somente no repositório: perde o default útil para inserções SQL, sem benefício necessário aqui.
- `varchar(max)` e comprimentos implícitos (255 ou 320 para email): tornam a mudança de limite uma alteração
  de tipo ou inventam restrições ausentes. `citext`, índice `lower(email)` ou normalização sempre ligada:
  mudam a igualdade declarada e, no caso de expressão, não servem como chave referenciada comum.
- `integer` de 32 bits, `float`, `timestamp` sem fuso, precisão variável por sessão e `json` textual: limitam
  capacidade, perdem exatidão/instante ou dificultam igualdade. ENUM nativo e dinheiro sem moeda já foram
  rejeitados pelos ADRs 025 e 017. Um `CHECK` de sintaxe de email duplicaria uma decisão de contrato inexistente.
- Nulidade por `required`, defaults de contexto via GUC e `created_at DEFAULT now()`: confundem entrada,
  contexto confiável e relógio determinístico do ADR-027.
- Nomes por ordinal, truncamento automático e resolução por contadores: variam com ordem e ocultam colisões.
  Usar `index.name` da IR perpetuaria o ordinal emitido pelo normalizador. Interpretar livremente `where`
  como SQL abriria uma fronteira insegura e poderia mudar a unicidade.
- `CASCADE`, `SET NULL`, `RESTRICT` ou FK sempre adiada: exclusão implícita, tentativa de anular tenant
  obrigatório ou impossibilidade de adiamento e de checagem imediata por padrão. `MATCH FULL` recusaria o
  vendedor opcional com tenant não nulo. Só FK simples entre filhas permitiria referências entre tenants.
- Ordenação topológica: falha em ciclos; gerar FK por `has_many`, `many_to_many` e todo `id.entity` duplicaria
  vínculos ou inventaria relações. Usar só `belongs_to` deixaria tenants implícitos órfãos.
- Tratar toda entidade `tenant: null` como global: deixaria a raiz do tenant sem proteção explícita.
- Incluir RLS, triggers ou migração incremental neste gerador: mistura decisões e responsabilidades das
  C6/C7, K7/K8 e da evolução sobre tabelas com dados.

## Consequências

A K7 recebe instruções separadas, sem precisar analisar um script para encontrar FKs ou limites de
transação. Índices únicos compostos ocupam espaço além da PK (custo já reconhecido pelo ADR-025).
UUIDs v4 têm localidade de índice inferior a sequências. A representação inicial vira contrato a manter
nos planos incrementais; não oferece renomeação inferida, atualização de banco existente ou permissões.

## Garantia

**Estrutural e verificável por testes sem banco:** tipos, nulidade, defaults, nomes/colisões, ordem,
FKs opcionais e cíclicas, junções, tenant implícito, raiz e aplicações globais; entrada copiada e saída
congelada. Quatro fixtures SQL integrais fixam o DDL dos exemplos, e a suíte exige emissão de todos os
diagnósticos novos. A aplicação no PostgreSQL 17 e 18, inclusive integridade e adiamento das FKs, cabe à
auditoria de banco; a suíte Ruby não prova execução do DDL. RLS e integridade das transições aguardam C7.

As escolhas usam as referências do PostgreSQL 17 para [constraints e FKs](https://www.postgresql.org/docs/17/ddl-constraints.html),
[UUID v4](https://www.postgresql.org/docs/17/functions-uuid.html),
[precisão e fuso](https://www.postgresql.org/docs/17/datatype-datetime.html) e
[identificadores e literais](https://www.postgresql.org/docs/17/sql-syntax-lexical.html).

# Fase 0: protótipo do compilador

O protótipo implementa o caminho **DSL Ruby → registro congelado → IR 0.6 → validação**, o diff arquitetural
e a vinculação validada de blocos Ruby do [ADR-001](adr/001-grafo-da-aplicacao-e-ir.md). É experimental.
Os 21 ADRs (001 a 021) foram aceitos. A fase 0 ainda não cumpriu todos os critérios de aceitação.
O compilador continua validando e vinculando as IRs 0.1 a 0.5 com seus schemas e semânticas originais.
Novos builds usam 0.6, com o `created_at` do [ADR-027](adr/027-created-at-implicito-e-ir-0-2.md) e os
retornos de consulta do [ADR-028](adr/028-contratos-compostos-e-colecoes-de-consultas.md) e as declarações
live do [ADR-029](adr/029-declaracoes-live-e-dependencias.md). O [ADR-032](adr/032-comandos-gerados-de-vinculo.md)
descreve os comandos gerados de `many_to_many`, disponíveis desde a IR 0.4 e sem executor. O
[ADR-033](adr/033-arredondamento-monetario-e-ir-0-5.md) declara o arredondamento em `currency`
desde a IR 0.5. O [ADR-034](adr/034-limite-de-taxa-por-permissao-e-ir-0-6.md) declara
`rate_limit:` por permissão na IR 0.6; a versão da gem permanece alpha.5.

## Executar

Usar Ruby 4.0.9, fixado em `.ruby-version`, e Bundler. Na raiz do repositório:

```sh
bundle install
bundle exec rake test:diagnostics
bundle exec bin/vetra graph:build --root examples/blog
bundle exec bin/vetra graph:check --root examples/blog
bundle exec bin/vetra graph:validate --root examples/blog --sources
bundle exec bin/vetra graph:build --root examples/mini_crm
bundle exec bin/vetra graph:check --root examples/mini_crm
bundle exec bin/vetra graph:validate --root examples/mini_crm --sources
bundle exec bin/vetra graph:build --root examples/mini_crm_revendas
bundle exec bin/vetra graph:check --root examples/mini_crm_revendas
bundle exec bin/vetra graph:validate --root examples/mini_crm_revendas --sources
bundle exec bin/vetra graph:build --root examples/chat
bundle exec bin/vetra graph:check --root examples/chat
bundle exec bin/vetra graph:validate --root examples/chat --sources
bundle exec bin/vetra graph:diff git:HEAD examples/blog/.vetra/graph.json --root examples/blog
bundle exec bin/vetra graph:link --root examples/blog
bundle exec bin/vetra graph:link --root examples/mini_crm
bundle exec bin/vetra graph:link --root examples/mini_crm_revendas
bundle exec bin/vetra graph:link --root examples/chat
```

Os diretórios em `examples/` contêm declarações Ruby reais, lockfiles e `.vetra/graph.json` gerado
e versionado. São recortes sem autenticação, UI ou persistência: o blog demonstra escopo do autor e
publicação; o CRM demonstra tenant, dinheiro, transição e um handler declarado; o `mini_crm_revendas`
reproduz o exemplo da proposta com revendas, vendedores e papéis por vínculo
(veja [escopo por vínculo](#escopo-por-vínculo)); o `chat` reproduz as salas e mensagens do exemplo 3, com
membros por relação muitos-para-muitos (veja [muitos-para-muitos](#relações-muitos-para-muitos)).
Cadastro, login e persistência de usuários e vínculos continuam fora: as entidades são declaradas à mão,
e não geradas por `auth`.

`bundle exec rake test:diagnostics` executa a suíte completa e exige que todos os códigos de diagnóstico
literais de `lib/` sejam emitidos por algum teste. É a tarefa usada na CI e também o padrão de `bundle exec rake`.
O catálogo é extraído com Prism; comentários e strings que apenas mencionam um código não contam. Código
sem emissão ou emitido sem declaração literal reconhecida faz a tarefa falhar. A verificação cobre códigos,
não cada ramo que reutiliza o mesmo código; os [limites da medição](fase-0-criterios.md#como-a-lacuna-do-critério-2-foi-medida)
continuam explícitos.

Para uma seleção parcial, usar `bundle exec rake test TEST=test/money_test.rb` ou
`bundle exec ruby -Itest test/money_test.rb`, sem a exigência de cobertura global. Os testes de Ractors
compartilham dados imutáveis de verdade; não executam operações da aplicação.

| Comando | Comportamento |
|---|---|
| `graph:build --root APP` | Reconstrói e valida tudo; grava `.vetra/graph.json` por substituição atômica |
| `graph:check --root APP` | Reconstrói e compara bytes, sem editar o artefato; divergência ou ausência falha |
| `graph:validate ARQUIVO` | Valida versão, recursos, schema, invariantes implementados e digest, sem avaliar o DSL |
| `graph:validate --root APP --sources` | Também confere arquivos e hashes; usa o grafo padrão quando não recebe arquivo |
| `graph:diff ANTERIOR POSTERIOR` | Compara arquivos/revisões Git validados; aceita texto ou JSON e sinaliza quebras potenciais |
| `graph:link --root APP` | Confere o artefato/pacote, recria o registro e vincula blocos Ruby; não executa operações |
| `db:authz:sql --root APP` | Confere o pacote sem avaliar o DSL e escreve SQL inicial de revisão por tenant; não conecta nem aplica |

Saída 0 significa sucesso, 1 indica erro de compilação/validação/arquivo e 2 indica uso incorreto da CLI.
Avisos vão para stderr e não mudam o código de sucesso. `graph:validate` sem `--sources` também aceita as
[fixtures documentais](ir/README.md), cujos hashes de arquivos são placeholders.
No diff, `--fail-on-breaking` adiciona a saída 3 quando houver quebra potencial; o
[guia de comparação](graph-diff.md) explica categorias, renomeações, limites e formato JSON.
O [guia de vinculação](graph-link.md) detalha a ordem das verificações e a API de metadados.
O [guia de SQL de autorização](db-authz-sql.md) descreve a instalação inicial gerada, seus privilégios,
locks e limites. O comando exige tenant e tabelas comuns; não é o planejador de migrações.

## DSL implementado

- `Vetra.app`, com `tenant`, `currency` (incluindo `rounding:`) e `locale`.
- `domain` e `depends_on`; ausência de fronteira explícita gera aviso.
- `entity`, com `id` e `created_at` implícitos, campos primitivos, `enum`, `money`, `decimal`, `slug`, defaults, privacidade, índices e
  `belongs_to`, incluindo chaves compostas para `same_tenant`, `has_many` como inverso de um `belongs_to` e
  `many_to_many` por uma entidade de junção declarada ou gerada, com comandos de vínculo gerados por padrão
  e `commands: false` para desligá-los por relação.
- `crud`: gera criação, leitura por ID, atualização e exclusão como nós de comandos/consulta, contratos,
  repositórios e rotas HTTP. Ainda não existe execução dessas primitivas.
- `roles`, `role`, `visitor`, `authenticated` e `can`; `manage` expande para as quatro ações CRUD.
  `where` aceita igualdade literal, `:current_actor` e relações declaradas. `scope` suporta
  `author`, `owner` e `seller` comparados com `actor.id` e, com `memberships`, o escopo por vínculo.
  `rate_limit: "5/min"` declara limite por permissão, ator e tenant, sem executor.
- `command` e `query`, com `input`, `returns :entidade`, `authorize`, `uses`, `call`, `unsafe_effect` e
  `expose http:`, `cli:`, `job:` e `webhook:`. Consultas também aceitam coleções, blocos de saída compostos
  e declarações `live` com dependências verificadas.
  `returns` é explícito porque não se infere retorno de Ruby
  arbitrário. Queries aceitam HTTP de leitura e CLI; jobs e webhooks exigem comandos.
- `event`, com projeção de campos, visibilidade e exigência de consumidor; `emits` pode inferir o evento
  interno e seu payload quando ele não foi declarado separadamente.
- `handler`, com `on`, `uses`, `calls`, `idempotent_by :event_id` e `call`; `effect` registra capacidades
  externas. `clock`, `uuid` e `random` geram metadados de capacidades determinísticas quando usados.

Cada `call` recebe a entrada/evento seguido dos parâmetros das capacidades na ordem de `uses`, com os
nomes declarados. Os parâmetros são conferidos e o bloco é registrado separadamente da IR; **nenhum
`call` é executado**. IDs e referências da IR são qualificados pelo domínio. O normalizador pode reordenar
o conjunto `uses` na IR, mas a vinculação original dos parâmetros fica fora dela e é conferida em
`graph:link`. A unidade vinculada expõe metadados congelados; as closures ficam privadas.

Declarações/opções não implementadas falham; não viram anotações nem desaparecem. Entre elas estão UI, MCP,
workflows, `auth` e geração de usuários/vínculos, metadados de dependências por gem, SQL explícito,
`realtime` e políticas baseadas em atributos materializados do
ator além de `id`. Uma palavra-chave desconhecida em qualquer declaração falha com `unsupported_option`, e uma
obrigatória ausente com `missing_option`; os dois nomeiam o método e apontam a linha da declaração. Os schemas
possuem algumas dessas representações; conhecer sua forma não significa que este consumidor saiba compilá-las.

O construtor não é um sandbox. As declarações são código de desenvolvimento confiável e devem ser
determinísticas; chamadas explícitas a constantes Ruby podem escapar da API. A análise Prism do corpo de
`call` cobre efeitos diretos conhecidos (inclusive o acesso direto ao banco por `Sequel`, `ActiveRecord` e `PG`,
que só `unsafe_effect` com motivo libera), construções dinâmicas conhecidas e gravações literais pelas
capacidades nomeadas. Não resolve fluxo de dados, aliases, helpers arbitrários, gems ou todos os efeitos
transitivos. `analysis.status: complete` só significa que esse analisador limitado não encontrou uma
construção dinâmica conhecida. Não constitui prova de pureza ou segurança.

Gravações literais reconhecidas exigem um comando e um repositório com `access: read_write`. Mesmo um
comando recebe `write_boundary` se tentar gravar por uma capacidade explícita de leitura, como `users_read`.


## Coleções e contratos compostos de consultas

`returns :room` continua representando um registro. `returns :room, collection: true` gera o contrato
`<consulta>.output`, com `collection: true` e os campos de cada item. A lista pode ser vazia. Para um objeto
com diferentes resultados, declare os campos:

```ruby
query :room_page do
  input :room_id, :id
  returns do
    record :room, entity: :room
    collection :messages, entity: :message
  end
  authorize :read, :room, record: :room_id
  uses :rooms, :messages
  call do |input, rooms, messages|
    room = rooms.find!(input.room_id)
    { room: room, messages: messages.where(room_id: room.id).order(:created_at, :id).last(100) }
  end
end
```

O bloco de saída também aceita campos primitivos, como `integer :count`. `optional: true` em um campo de
registro ou coleção permite ausência e null. Os tipos estruturados referenciam contratos de objeto, e a
classificação pessoal é derivada dos campos referenciados. Referências ausentes, ciclos, uso em entidades,
entradas, comandos ou eventos e rebaixamento de privacidade falham antes da vinculação. O grafo exige
`vetra.structured_outputs`; a forma é nova na IR 0.3, com os formatos anteriores preservados.

O chat declara `my_rooms` (`GET /rooms`) e `room_page` (`GET /rooms/:room_id/page`), com autorização explícita
e repositórios de leitura. A página traz no máximo as últimas 100 mensagens da sala, ordenadas por criação
e ID para desempate. São consultas compiláveis e corpos testados em memória; autorização em execução,
HTTP, paginação por cursor, expansão de membros/autores e entrega live continuam pendentes.

Comandos conservam o retorno de um registro. Coleções de escalares, listas de listas e contratos recursivos
não são suportados. O compilador não executa o corpo para inferir ou provar seu retorno: o futuro runtime
precisará validar os valores contra os contratos. O [ADR-028](adr/028-contratos-compostos-e-colecoes-de-consultas.md)
define esse incremento.

## Declarações live

Consultas podem declarar `live true`, com `mode: :strict` como padrão. `mode: :balanced` exige escolha
explícita. `live false` desativa a declaração e não aceita opções adicionais; comandos e handlers recusam
`live`, inclusive desativado. A declaração exige `vetra.live` na IR 0.3; consumidores 0.1 e 0.2 continuam
recusando esse recurso.

O compilador deriva um conjunto conservador de entidades a partir da autorização, dos repositórios e dos
contratos de saída. Inclui também as entidades lidas pelas políticas aplicáveis, percorrendo essas leituras
até não aparecerem dependências novas. No chat, `room_page` depende de `room`, `message`, `room_membership`
e `user`: a junção entra pela política de membros, mesmo sem um repositório recebido diretamente.

Uma lista explícita pode acrescentar entidades, mas precisa conter todas as dependências conhecidas,
incluindo as leituras das políticas das entidades extras:

```ruby
live true, depends_on: %i[room message room_membership user]
```

Uma análise Ruby incompleta exige essa lista e mantém o aviso `analysis_incomplete`. A lista não prova
as leituras de helpers arbitrários. Consultas live recusam `unsafe_effect`, SQL e capacidades externas;
aceitam repositórios de leitura e capacidades determinísticas. O validador verifica também o recurso e as
dependências de uma IR externa. O diff destaca mudanças como dependências e permissões; remover live é
quebra de contrato.

Esta etapa compila e valida metadados. Assinaturas, triggers, revogação transacional, releitura por grupo e
entrega WebSocket/SSE continuam pendentes. A configuração `realtime` ainda é recusada.
O [ADR-029](adr/029-declaracoes-live-e-dependencias.md) define o alcance e os limites desta etapa.

## Exposições HTTP, CLI, job e webhook

Cada exposição gera um nó `route`, representável desde a IR 0.1, apontando para a mesma operação. O contrato de entrada, a
autorização, as capacidades e o bloco `call` pertencem à operação, como decide o [ADR-007](adr/007-comando-como-unidade-unica-e-adaptadores.md).
O mini CRM demonstra as quatro superfícies em `win_lead`:

```ruby
expose http: "POST /leads/:lead_id/win"
expose cli: "leads:win"
expose job: "leads.win", idempotency: :required
expose webhook: "POST /webhooks/leads/:lead_id/win", idempotency: :required
```

- `http` e `webhook` recebem uma String `"MÉTODO /caminho"`. Comandos recusam `GET`, `HEAD` e `OPTIONS`;
  consultas só aceitam `GET` e `HEAD`. Todo parâmetro de caminho precisa existir no contrato de entrada.
- `cli` e `job` recebem nome não vazio, como String ou Symbol, único dentro de sua superfície em toda a
  aplicação. O mesmo nome pode existir uma vez em CLI e outra em job. Uma consulta pode declarar CLI;
  jobs e webhooks exigem comando.
- `idempotency` é `optional` por padrão. Webhook exige `idempotency: :required` explícito. A omissão ou a
  opção `optional` falha com `webhook_idempotency`, antes de escrever o artefato.
- Várias superfícies podem ser declaradas numa chamada, como `expose cli: :publicar, job: :publicar`. Nesse
  caso compartilham a opção `idempotency` daquela chamada. Exposições separadas podem exigir valores distintos.
- HTTP e webhook disputam o mesmo espaço de método/caminho. Nomes de parâmetros diferentes, trechos fixos
  sobrepostos com parâmetros e o par `GET`/`HEAD` entram na verificação de ambiguidade.
- Uma exposição não projeta nem restringe os campos do contrato: opções como `fields:` falham. UI e MCP
  continuam sem suporte. Erros de argumentos de `expose` identificam o arquivo e a linha da exposição;
  erros semânticos da rota também trazem o ponteiro JSON e a origem da operação que a gerou.

Os identificadores gerados contam por superfície: `crm.win_lead.http_1`, `.cli_1`, `.job_1` e `.webhook_1`.
Acrescentar uma exposição CLI não renomeia as rotas HTTP existentes. Rotas novas aparecem no `graph:diff`
como mudanças de superfície e permissão que exigem revisão.

Este suporte é declarativo: `graph:link` vincula o bloco uma única vez. O protótipo ainda não tem servidor
HTTP, terminal para executar comandos de negócio, fila de jobs nem recebimento de webhooks; a exigência de
idempotência é metadado validado, sem deduplicação em execução.

## Limite de taxa por permissão

`can :create, on: :comment, rate_limit: "5/min"` reproduz a permissão visitante do blog da proposta.
O DSL aceita strings `"N/unidade"` ou `"N/J<unidade>"`, com limite e janela inteiros positivos,
sem espaços ou zeros à esquerda; unidades `s`, `min` e `h`. Por exemplo, `"5/2min"` declara cinco
admissões em uma janela móvel de 120 segundos. Limite e duração em segundos cabem no inteiro seguro
positivo da IR. Tipos, valores ou unidades inválidos falham com `rate_limit`, origem de `can` e
ponteiro `/rate_limit`.

Na IR 0.6, a política recebe `rate_limit: { limit: 5, window_seconds: 60, key: "actor_tenant" }`.
O requisito `vetra.rate_limit` só entra quando alguma política usa o recurso. A contagem é por política,
ator e tenant confiáveis, compartilhada pelas ações e superfícies que usam a permissão. Sem tenant,
usa-se o marcador de ausência da aplicação. O visitante requer identidade anônima estável verificada
pelo futuro runtime; sem ela, a operação limitada deve ser recusada.

O limite não concede acesso, não altera predicados, campos ou dependências e não substitui os controles
adicionais do MCP (ADR-011) ou dos sinais por tópico (ADR-019). Ele qualifica a concessão em que foi
declarado: se alguma política aplicável autoriza a operação sem limite, ela é admitida sem verificar
nem consumir cotas dessas políticas. Só quando todas as políticas que a autorizam têm limite, todas
precisam permitir a admissão, que conta em todas; alternar entre elas não multiplica cotas. No blog,
a concessão administrativa sem limite preserva esse acesso mesmo que a permissão limitada do visitante
também se aplique ao ator. O blog inclui comentários com `approved` protegido por
`set_by: :approve_comment`, sem UI. O compilador e o link apenas declaram e conferem o contrato;
não há executor, relógio ou armazenamento de contadores.

O [ADR-034](adr/034-limite-de-taxa-por-permissao-e-ir-0-6.md) fixa o contrato. Os schemas 0.1
a 0.5 não mudam e recusam campo e requisito novos. O link preserva os formatos anteriores e não pode
descartar um limite explícito para auditar um grafo antigo. O diff exige revisão para adicionar ou
apertar; afrouxar, remover ou mudar de forma inconclusiva é quebra potencial de segurança, inclusive
quando a política limitada inteira é removida.

## Dinheiro e escala por moeda

`money :valor` usa precisão 19 e a escala da moeda da aplicação: 2 para BRL/USD, 0 para JPY, 3 para BHD e
4 para CLF. `scale:` explícito pode ser igual ou maior que o expoente; um valor menor falha com `money_scale`.
Isso vale para entidades e entradas de comando/consulta e se propaga aos contratos CRUD, retornos e eventos.
`decimal` continua com escala padrão 2.

```ruby
Vetra.app :catalogo do
  currency "BHD"
end

# Dentro de uma entidade:
money :total                       # precision: 19, scale: 3
money :preco_unitario, scale: 4     # precisão estendida
```

A tabela de expoentes é local e distribuída com o compilador, derivada da List One da SIX, publicada em
2026-09-17. Sua origem, manutenção e limites estão no [ADR-026](adr/026-tabela-de-expoentes-iso-4217.md).
Se houver campo `money`, uma moeda da aplicação desconhecida ou sem expoente definido falha com `money_currency`,
mesmo com `scale:` explícito. Não há consulta à rede nem suposição de duas casas.

Um `default` monetário precisa trazer uma moeda suportada cujo expoente caiba na escala do campo, e uma string
decimal que caiba em `precision`/`scale`. Valores excedentes falham com `field_default`; não são arredondados.
A moeda por tenant, o arredondamento, a formatação e a validação HTTP em execução continuam pendentes. As IRs
0.1 e 0.2 guardam `scale` numérico explícito com a mesma representação monetária.

`currency "BRL", rounding: :half_up` declara o modo da aplicação. Os modos aceitos são `half_up`
(empate para longe de zero) e `half_even` (empate para o último algarismo par), como símbolo ou string.
O padrão é `half_up`, inclusive sem `currency` declarado. Desde a IR 0.5, o build emite `app.rounding` e exige
`vetra.money_rounding` somente quando há declaração de `rounding:`, inclusive `half_up` e mesmo sem
campos `money`. Sem a declaração, campo e requisito ficam ausentes. Nome ou tipo inválido falha com
`money_rounding`. O modo governa somente conversão
e divisão cujo resultado exceda a escala de destino, nunca soma ou subtração; defaults excedentes
continuam recusados. A execução dos cálculos continua pendente.

O [ADR-033](adr/033-arredondamento-monetario-e-ir-0-5.md) detalha os desempates e o alcance.
Na IR externa 0.5, omissão significa `half_up`; campo presente exige o requisito. Os schemas 0.1 a 0.4
não mudam e recusam campo/requisito novos. O diff compara modos efetivos: explicitar o padrão não muda
valores, mas trocar o modo é quebra potencial com revisão obrigatória, na categoria `values`.

## Data de criação implícita

Novos builds geram `created_at` em todas as entidades, incluindo a raiz do tenant e as junções implícitas.
O campo é um `timestamp` obrigatório e não nulo, com `generate: { kind: "timestamp", on: "create" }` na
entidade. A regra existe desde a IR 0.2 e exige `vetra.timestamps`, conforme o [ADR-027](adr/027-created-at-implicito-e-ir-0-2.md).

O campo participa do contrato de registro, pode ser projetado em eventos e pode ser usado em índices.
Não aparece nas entradas CRUD de criação e atualização. O nome é reservado nas entidades; redeclará-lo
falha com `reserved_field`. Atribuições literais reconhecidas por repositório falham com
`generated_field_write`, inclusive em um `create!`. Isso não altera campos de filtro chamados `created_at`
em entradas de operações.

No chat, `index :room_id, :created_at` agora reproduz a proposta. A compilação não consulta o relógio:
somente registra que o futuro repositório atribuirá a data na criação, usando o relógio determinístico da
operação. Persistência, preenchimento de linhas antigas e `updated_at` continuam pendentes.

O schema 0.1 não foi alterado. `graph:validate`, `graph:diff` e `graph:link` continuam lendo artefatos
0.1, sem adicionar campos durante a vinculação. `graph:check` exige reconstrução porque compara com um
novo build 0.6; use `graph:build` e revise o diff para adotar a geração. A mudança de versão e do requisito
aparece no diff para revisão, além dos campos e índices.

## Escopo por vínculo

`roles scope: :dealer` (ou `crud scope: :dealer`) restringe um papel às revendas em que o ator tem vínculo
com aquele papel. O vínculo é uma entidade comum, declarada pela aplicação, que aponta ao escopo e ao ator
e guarda o papel num `enum`:

```ruby
entity :membership do
  tenant :company
  belongs_to :user, same_tenant: true
  belongs_to :dealer, same_tenant: true
  enum :role, %w[vendedor gerente]
  memberships of: :dealer, actor: :user, role: :role
end

entity :dealer do
  tenant :company
  string :name, required: true
  has_many :memberships, entity: :membership, by: :dealer
end
```

O compilador não acrescenta nenhum conceito à IR 0.1. O escopo vira um predicado `exists` já existente,
percorrendo as relações do registro até o vínculo, e `reads` passa a incluir a revenda e o vínculo:

```json
{"op":"exists","relation":["dealer","memberships"],
 "where":{"op":"and","terms":[
   {"op":"eq","left":{"kind":"field","path":["user_id"]},"right":{"kind":"actor","path":["id"]}},
   {"op":"eq","left":{"kind":"field","path":["role"]},"right":{"kind":"literal","value":"vendedor"}}]}}
```

- O nome do papel (`:vendedor`) é o valor comparado: ele precisa constar no `enum` do vínculo, e um papel
  anônimo não pode ter escopo por vínculo.
- `has_many` não declara chave própria: usa a de um `belongs_to` da entidade de destino, indicado por
  `by:`, e é recusado quando ele não existe (`relation_inverse`). O validador da IR confere o mesmo.
- O registro precisa alcançar a revenda por um `belongs_to` com o nome do escopo; a própria entidade do
  escopo também pode receber permissões (`can :read, on: :dealer`). Para um papel sem escopo numa
  declaração `roles scope:`, use `scope: nil` (acesso dentro do tenant).
- A identidade de um escopo é a **entidade que o `belongs_to` do vínculo referencia** (com o domínio), e não o
  nome da relação. Dois domínios independentes podem declarar, cada um, `memberships of: :dealer` para a sua
  própria revenda; cada papel usa o vínculo da revenda que a sua entidade referencia (ou da própria entidade,
  quando ela é a revenda), inclusive entre domínios. Dois vínculos para a **mesma** entidade de escopo são
  ambíguos.
- `memberships` duplicado para a mesma entidade de escopo, relação ausente, enum ausente ou anulável, e escopo
  sem declaração ou sem relação com a entidade autorizada são erros de compilação, nunca um predicado mais
  permissivo.
- Cada papel gera as próprias políticas, com o próprio valor de `role` no predicado. O compilador não
  define hierarquia entre papéis (gerente não implica vendedor) nem como as políticas de um ator com mais
  de um papel se combinam: isso é do motor de autorização, que ainda não existe. O exemplo impede
  vínculos repetidos com um índice único em usuário, revenda e papel.
- Os escopos `author`, `owner` e `seller` continuam comparando o campo com `actor.id` quando não há
  `memberships` para o nome.

A tradução em RLS não existe ainda: o ADR-005 prevê políticas SQL geradas para esse escopo, que dependem do
Vetra Data. O predicado é o contrato que essa geração vai consumir.

## Relações muitos-para-muitos

`many_to_many` liga duas entidades por uma terceira, a **junção**. A aplicação pode declará-la como entidade
comum (`through:`) ou deixar o compilador gerá-la (sem `through:`, ver "Junção gerada" abaixo).

```ruby
entity :room do
  belongs_to :owner, entity: :user, default: :current_actor
  string :name, required: true, max: 80
  many_to_many :members, entity: :user, through: :room_membership, include: :owner
end

entity :room_membership do
  belongs_to :room
  belongs_to :user
  index :room_id, :user_id, unique: true
end
```

Na IR 0.1 a relação usa campos que o schema já tem, com este significado:

- `through` referencia a junção. `local_fields` e `target_fields` são as chaves do dono e do alvo que a
  junção referencia (`["id"]`, ou `[tenant, "id"]` com `same_tenant`), as mesmas dos `belongs_to` dela.
- `include_on_create` (de `include:`) lista `belongs_to` do dono que apontam para o alvo; o proprietário da
  sala entra como membro na criação. É dado do grafo: nenhum comando o executa ainda.
- A junção precisa ter **exatamente um** `belongs_to` para o dono e um para o alvo. Auto-relações (amigos de
  um usuário) têm dois para a mesma entidade e são recusadas (`relation_through`), pois a IR não registra
  qual coluna é qual.
- `include:` que não cite um `belongs_to` do dono para o alvo é erro (`relation_include`). O validador da IR
  confere as mesmas regras, inclusive em artefatos vindos de fora.
- Políticas aceitam `where: { members: :current_actor }` e a forma aninhada
  `where: { room: { members: :current_actor } }`. O predicado é um `exists` pela relação, e `reads` inclui a
  junção, senão o validador acusa `policy_reads`.

### Junção gerada

Sem `through:`, o compilador gera a junção como um nó comum da IR, com `generated_from` apontando o dono:

```ruby
entity :tag do
  string :name, required: true, unique: true, normalize: :downcase
end

entity :post do
  many_to_many :tags # alvo: blog.tag; junção gerada: blog.post_tag
end
```

- **Alvo.** Sem `entity:`, é a entidade do mesmo domínio com o nome da relação no singular (`tags` vira `tag`,
  `companies` vira `company`). Se ela não existir, `relation_target` manda declará-la ou informar `entity:`.
- **Nome.** `<dono>_<relação no singular>`: `blog.post_tag`, `chat.room_member`. A regra é mínima de propósito;
  para outro nome, declare a junção e use `through:`.
- **Forma.** Um `belongs_to` para cada lado (`post_id`, `tag_id`) e um índice único sobre o par. Com tenant, a
  junção herda o tenant da aplicação, os dois `belongs_to` usam `same_tenant` e o índice começa pelo campo do
  tenant.
- **Recusas** (`relation_through`): auto-relação, nome que colide com uma entidade declarada e um lado com tenant
  e o outro sem. Nos três casos, declare a junção e use `through:`.
- Os nomes de tabela da proposta (`posts_tags`, `room_memberships`) não são reproduzidos: a junção gerada segue a
  convenção das demais entidades (`post_tags`, `room_members`). A persistência ainda não existe, então isso não
  afeta nada hoje.

### Comandos gerados de vínculo

Por padrão, cada `many_to_many` gera os comandos `add_<relação no singular>` e
`remove_<relação no singular>` no domínio do dono. `many_to_many :tags` gera `add_tag` e `remove_tag`;
`members` gera `add_member` e `remove_member`. A regra mínima de singular é a mesma usada na junção.
`commands: true` explicita o padrão; `commands: false` desliga os dois comandos, sem mudar a relação ou
sua junção. Outros valores falham com `relation_commands_option`.

Cada comando recebe somente `<dono>_id` e `<alvo>_id` (nomes locais das entidades), obrigatórios, não nulos
e tipados; o tenant vem do contexto, sem campo gravável na entrada. Retorna o registro do dono e autoriza
a ação `add_<singular>` ou `remove_<singular>` pelo ID dele. Usa somente seu repositório `read_write`,
respeitando `repository:` customizado. Nenhuma rota, política ou emissão de evento é gerada. A aplicação
precisa conceder a ação pela política do dono; a mera declaração da relação não concede acesso.

Desde a IR 0.4, o grafo exige `vetra.relation_commands` ao gerar esses comandos e registra `implementation: { kind: "builtin", name:
"many_to_many.add.tags" }` (ou `many_to_many.remove.tags`). O nome da relação e a entidade autorizada
identificam a junção, os dois lados e as chaves. `generated_from` aponta o dono. O link retorna
`executor: "pending"`, sem closure Ruby e sem executar operações. O futuro executor deverá autorizar e
travar o dono, incluir sem duplicar, remover vínculo ausente sem erro e recusar remoção dos alvos indicados
por `include_on_create`, como o proprietário da sala. Estas são obrigações do descritor, ainda sem execução.

As recusas são explícitas:

- `relation_command_collision`: o nome gerado colide com comando, consulta, handler ou outra geração.
  Comandos explícitos não substituem os gerados automaticamente. Renomeie a declaração ou use
  `commands: false` e declare os comandos que a aplicação precisa.
- `relation_command_junction`: a junção não tem índice único exatamente sobre o par (com tenant, quando
  houver), tem chaves opcionais/protegidas ou incompatíveis, tenant inconsistente ou campos adicionais
  obrigatórios ou não nulos sem default/geração. Uma junção com dados de negócio exige comandos explícitos.
- `relation_command_contract`: os nomes locais do dono e do alvo coincidem ou a IR externa altera a entrada,
  saída, autorização, origem ou capacidades exigidas pela primitiva. O validador também recusa relação
  inexistente e efeitos extras; não basta a IR passar no schema.

O diff trata comandos e contratos gerados como os demais nós: adição exige revisão de permissões e
capacidades; desligar a geração remove contratos/comandos e produz quebras potenciais. Trocar a primitiva
por Ruby no mesmo ID exige revisão de implementação, sem inferir equivalência. Alterar a relação usada
pela primitiva também destaca implementação e permissões, inclusive ao mudar `through` ou `include:`.
As IRs 0.1/0.2/0.3 continuam validando, comparando e vinculando sem geração retroativa, com seus schemas
publicados inalterados. Um documento 0.3 com o requisito ou com a primitiva de vínculo é recusado; um novo build 0.6
adota o padrão e exige revisão. O [ADR-032](adr/032-comandos-gerados-de-vinculo.md) está aceito.

### Comandos de membros no chat

O exemplo `examples/chat` usa `commands: false` na relação de membros e declara `add_member` e
`remove_member` explicitamente como comandos Ruby. Ambos
recebem `room_id` e `user_id`, obrigatórios e não nulos, tipados para `chat.room` e `chat.user`. A autorização
aponta para a sala de `room_id`, e os dois comandos usam apenas a capacidade `rooms`, retornando o contrato da
sala. A política segue a proposta:

```ruby
can :add_member, :remove_member, on: :room, where: { owner: :current_actor }
```

O corpo de cada comando trava a sala antes de chamar `rooms.add_member!` ou `rooms.remove_member!`. A remoção
recusa o `user_id` do dono com `fail!`, preservando o vínculo inicial do proprietário.

`add_member_by_email` recebe `room_id` e `email`, retorna a sala e reutiliza a ação `add_member` da mesma
política do dono. Usa `rooms` e a capacidade de somente leitura `users_read`: trava a sala antes da busca,
consulta até dois usuários pelo e-mail e inclui o ID apenas se houver um resultado. Nenhum resultado ou um
e-mail ambíguo falha no campo `email`, sem alterar membros. O contrato da entrada e a entidade `user` declaram
normalização `downcase` e classificação pessoal do e-mail; a normalização ainda depende do futuro runtime.
O e-mail do usuário declara unicidade e gera um índice único sobre o valor normalizado. A checagem de
ambiguidade permanece como defesa para dados inconsistentes; ausência e ambiguidade usam a mesma mensagem.

Esse comando é **interno, sem exposição HTTP, CLI, job ou webhook**. A política de dono da sala não é
autorização para descobrir quem tem cadastro: qualquer autenticado pode criar uma sala. Uma resposta
genérica também não esconderia a inclusão observável na lista de membros. Reexpor a busca depende de um
fluxo de convite e aceite do destinatário ou de uma política explícita de descoberta de usuários, junto
com autenticação e limites de uso. Nenhum desses fluxos foi implementado neste protótipo.

As exposições são:

| Comando | Método | Caminho |
|---|---|---|
| `chat.add_member` | POST | `/rooms/:room_id/members` |
| `chat.remove_member` | DELETE | `/rooms/:room_id/members/:user_id` |

`test/chat_test.rb` confere contratos, política do dono, rotas, vínculo dos blocos e a recusa dessas escritas
quando declaradas como consulta, além da ausência de qualquer superfície para a busca por e-mail.
Testes unitários dos corpos usam um repositório em memória e um contexto de
`fail!` de teste para conferir inclusão, remoção, retorno da sala, recusa de remover o dono e falhas da busca
por e-mail. A vinculação confere também a ordem dos parâmetros de `rooms` e `users_read`. Esses testes não
implementam o executor do framework, autorização em execução, transações, RLS ou revogação live. Build e link
continuam sem executar os corpos.

A geração automática está disponível, mas o chat a desliga para preservar os corpos Ruby, a regra de
remoção do dono e as exposições existentes. Tirar `commands: false` mantendo esses arquivos falha com
`relation_command_collision`. Os comandos explícitos são representáveis desde a IR 0.1. O `created_at`
implícito, presente desde a IR 0.2, participa do índice de mensagens com `room_id`.

## Integridade e limites

O manifesto inclui `app/`, `lib/`, configuração não secreta em `config/`, `Gemfile`, `Gemfile.lock` e
`.ruby-version`. Segredos convencionais (`secrets`, `credentials`, `.env`, `.enc`, `.key`, `.pem`) ficam
fora. Links de arquivo não podem escapar da raiz; diretórios simbólicos são recusados neste incremento.
Nomes secretos fora dessas convenções não são identificáveis automaticamente: não colocar segredos nas
declarações. Hashes cobrem bytes dos arquivos; seus conteúdos não são embutidos no grafo.

A IR usa JCS restrito aos tipos do ADR: strings Unicode preservadas, chaves ordenadas por UTF-16 e
inteiros seguros; números de ponto flutuante são recusados. O digest exclui apenas `digest` na raiz.
Normalização mantém arrays posicionais e a ordem dos enums. O schema local é verificado por
[json_schemer](https://github.com/davishmcclurg/json_schemer), sem resolver referências pela rede.

O compilador verifica referências, namespaces, fronteiras/ciclos entre domínios, origens e hashes de
implementação, campos/defaults, donos de transição, dependências declarativas de políticas, capacidades,
payloads, consumidores obrigatórios, rotas e renomeações explícitas. Não aplica políticas SQL, não instala
triggers no banco da aplicação e não chama serviços. `transitions enforce: :db` continua sendo metadado:
o gerador SQL inicial cobre somente revisões de autorização, sem triggers de transição.
Nem toda relação semântica possível no schema tem uma implementação; recursos fora do subconjunto
suportado devem ser recusados, não tratados como seguros.

O arquivo versionado sempre é recompilado nos comandos de build/check. `graph:link` exige o artefato
existente e não o substitui: carrega declarações confiáveis para registrar as closures e audita o modelo
em memória contra a IR aprovada. `.vetra/cache/` é ignorado. Cache de compilação, servidor de produção e
execução de operações ainda não existem. `graph:validate --sources` permanece uma verificação de dados
e integridade, sem carregamento de código ou vinculação. Hashes não autenticam o pacote.

## Cobertura e continuação

Os testes exercitam os exemplos com/sem tenant, reprodução entre checkouts, Unicode/JCS, JSON com chaves
repetidas, imutabilidade/compartilhamento da IR, alterações e remoções de fontes, contratos CRUD,
defaults/valores protegidos, efeitos diretos, limites de capacidades, permissões, eventos e erros da CLI.
O diff cobre direção de contratos, renomeações, ordem posicional, metadados, impacto indeterminado de
permissões e leitura de revisões/tags em repositórios temporários, sem executar o DSL ou alterar o checkout.
A vinculação cobre assinatura/origem dos blocos, correspondência exata do registro, fontes e artefato
antes/depois do carregamento e recusa de mudanças sem reconstrução automática. Primitivas CRUD e de vínculo são
descritores reconhecidos com executor pendente; os testes não demonstram execução transacional.
A [CI](../.github/workflows/ci.yml) executa os testes e confere os grafos dos exemplos no Ruby fixado.
As sondas de PostgreSQL são executadas separadamente; a [sonda do ADR-008](sondas/adr008.md) verifica
intervalos, continuidade e versão por linha, sem implementar a entrega live.
A [sonda do ADR-020](sondas/adr020.md) acrescenta revisão de autorização e demonstrações de decisão strict
e releitura agrupada; os triggers ainda não são gerados da IR e não há runtime integrado.
A [cobertura dos critérios do ADR-001](fase-0-criterios.md) cruza cada um dos 11 testes de aceitação com a suíte
e registra o que foi fechado: os 143 códigos de diagnóstico do compilador são disparados por algum teste,
conferidos pela tarefa `test:diagnostics`.

Os próximos incrementos da fase 0 são a ampliação do subconjunto declarativo e o fechamento dos critérios
restantes com os exemplos da proposta e medições. A suíte deverá acompanhar cada expansão.
Depois, o motor de comandos e o Vetra Data precisam de seus ADRs, PostgreSQL real e testes transacionais;
as garantias de RLS, entrega de eventos e live continuam pendentes dessas implementações.

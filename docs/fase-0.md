# Fase 0: protótipo do compilador

O protótipo implementa o caminho **DSL Ruby → registro congelado → IR 0.1 → validação**, o diff arquitetural
e a vinculação validada de blocos Ruby do [ADR-001](adr/001-grafo-da-aplicacao-e-ir.md). É experimental.
Os ADRs 001, 002, 003, 004, 005, 006, 007, 008, 010, 013, 014, 015, 016, 017, 020 e 021 foram aceitos e os
demais continuam propostos. A fase 0 ainda não cumpriu todos os critérios de aceitação.

## Executar

Usar Ruby 4.0.9, fixado em `.ruby-version`, e Bundler. Na raiz do repositório:

```sh
bundle install
bundle exec rake test
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

| Comando | Comportamento |
|---|---|
| `graph:build --root APP` | Reconstrói e valida tudo; grava `.vetra/graph.json` por substituição atômica |
| `graph:check --root APP` | Reconstrói e compara bytes, sem editar o artefato; divergência ou ausência falha |
| `graph:validate ARQUIVO` | Valida versão, recursos, schema, invariantes implementados e digest, sem avaliar o DSL |
| `graph:validate --root APP --sources` | Também confere arquivos e hashes; usa o grafo padrão quando não recebe arquivo |
| `graph:diff ANTERIOR POSTERIOR` | Compara arquivos/revisões Git validados; aceita texto ou JSON e sinaliza quebras potenciais |
| `graph:link --root APP` | Confere o artefato/pacote, recria o registro e vincula blocos Ruby; não executa operações |

Saída 0 significa sucesso, 1 indica erro de compilação/validação/arquivo e 2 indica uso incorreto da CLI.
Avisos vão para stderr e não mudam o código de sucesso. `graph:validate` sem `--sources` também aceita as
[fixtures documentais](ir/README.md), cujos hashes de arquivos são placeholders.
No diff, `--fail-on-breaking` adiciona a saída 3 quando houver quebra potencial; o
[guia de comparação](graph-diff.md) explica categorias, renomeações, limites e formato JSON.
O [guia de vinculação](graph-link.md) detalha a ordem das verificações e a API de metadados.

## DSL implementado

- `Vetra.app`, com `tenant`, `currency` e `locale`.
- `domain` e `depends_on`; ausência de fronteira explícita gera aviso.
- `entity`, campos primitivos, `enum`, `money`, `decimal`, `slug`, defaults, privacidade, índices e
  `belongs_to`, incluindo chaves compostas para `same_tenant`, `has_many` como inverso de um `belongs_to` e
  `many_to_many` por uma entidade de junção declarada ou gerada.
- `crud`: gera criação, leitura por ID, atualização e exclusão como nós de comandos/consulta, contratos,
  repositórios e rotas HTTP. Ainda não existe execução dessas primitivas.
- `roles`, `role`, `visitor`, `authenticated` e `can`; `manage` expande para as quatro ações CRUD.
  `where` aceita igualdade literal, `:current_actor` e relações declaradas. `scope` suporta
  `author`, `owner` e `seller` comparados com `actor.id` e, com `memberships`, o escopo por vínculo.
- `command` e `query`, com `input`, `returns :entidade`, `authorize`, `uses`, `call`, `unsafe_effect` e
  `expose http:`. `returns` é explícito porque não se infere retorno de Ruby arbitrário.
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
workflows, consultas live, `auth` e geração de usuários/vínculos, metadados de dependências por gem, SQL explícito,
`realtime`, `rate_limit:` em `can`, `rounding:` em `currency` e políticas baseadas em atributos materializados do
ator além de `id`. Uma palavra-chave desconhecida em qualquer declaração falha com `unsupported_option`, e uma
obrigatória ausente com `missing_option`; os dois nomeiam o método e apontam a linha da declaração. O schema 0.1
possui algumas dessas representações; conhecer sua forma não significa que este consumidor saiba compilá-las.

O construtor não é um sandbox. As declarações são código de desenvolvimento confiável e devem ser
determinísticas; chamadas explícitas a constantes Ruby podem escapar da API. A análise Prism do corpo de
`call` cobre efeitos diretos conhecidos, construções dinâmicas conhecidas e gravações literais pelas
capacidades nomeadas. Não resolve fluxo de dados, aliases, helpers arbitrários, gems ou todos os efeitos
transitivos. `analysis.status: complete` só significa que esse analisador limitado não encontrou uma
construção dinâmica conhecida. Não constitui prova de pureza ou segurança.

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

Ainda não existem: os comandos `add_member`/`remove_member` e o `created_at` implícito do exemplo da proposta (o
índice de mensagens usa só `room_id`).

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
triggers e não chama serviços. `transitions enforce: :db` é apenas metadado até existir o gerador SQL.
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
antes/depois do carregamento e recusa de mudanças sem reconstrução automática. Primitivas CRUD são
descritores reconhecidos com executor pendente; os testes não demonstram execução transacional.
A [CI](../.github/workflows/ci.yml) executa os testes e confere os grafos dos exemplos no Ruby fixado.
A [cobertura dos critérios do ADR-001](fase-0-criterios.md) cruza cada um dos 11 testes de aceitação com a suíte
e registra o que foi fechado: os 123 códigos de diagnóstico do compilador são disparados por algum teste.

Os próximos incrementos da fase 0 são a ampliação do subconjunto declarativo e o fechamento dos critérios
restantes com os exemplos da proposta e medições. A suíte deverá acompanhar cada expansão.
Depois, o motor de comandos e o Vetra Data precisam de seus ADRs, PostgreSQL real e testes transacionais;
as garantias de RLS, entrega de eventos e live continuam pendentes dessas implementações.

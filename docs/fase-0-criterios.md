# Fase 0: cobertura dos critérios do ADR-001

O [ADR-001](adr/001-grafo-da-aplicacao-e-ir.md) lista 11 testes de aceitação para a fase 0. Este documento cruza
cada um com a suíte atual e registra o que está coberto, o que está parcial e o que é lacuna. Ele não declara a
fase 0 concluída: o [protótipo](fase-0.md) cobre parte dos critérios.

Verificação em 2026-11-03, Ruby 4.0.9, base `131478b9ec9b25a12074189dfa9c9248805197fb`:
**428 testes e 4.618 asserções**, sem falhas, erros ou testes ignorados; **154/154 códigos**
exercitados em `bundle exec rake test:diagnostics`. São 35 ADRs aceitos.

O build usa IR 0.6. `rate_limit:` em `can` declara limite por política, ator e tenant e só exige
`vetra.rate_limit` quando usado. Os 22 testes de `rate_limit_test.rb` cobrem sintaxe positiva com unidade
e janela, canonicalização em segundos, IR externa, compatibilidade das versões 0.1 a 0.5, link sem
execução, adulterações e diff de segurança. O teste do blog também confere a concessão administrativa
sem limite.
O contrato admite a operação sem consumir cotas se alguma concessão aplicável a autoriza
sem limite; se todas as que autorizam têm limite, exige e consome todas as cotas. Essa admissão conjunta
depende do futuro runtime e ainda não tem teste operacional. Schemas 0.1 a 0.5 permanecem idênticos à base.

Os quatro exemplos passam em check, validação com fontes e link: blog com 52 nós, mini CRM com 36,
mini CRM com revendas com 49 e chat com 64. O gate contra `origin/main` (`cc013b7`) não encontra mudanças
nos modelos ou metadados dos quatro grafos. A IR e os schemas publicados permanecem inalterados.

O mapeamento físico inicial do [ADR-035](adr/035-mapeamento-fisico-inicial.md) tem 35 testes e
311 asserções em `schema_sql_test.rb`: tipos, nulidade, defaults, nomes, colisões, FKs, ciclos,
tenant implícito, raiz e aplicações globais. Quatro fixtures integrais fixam o DDL; os 11 novos códigos
de diagnóstico são exercitados pela suíte. A aplicação do DDL no PostgreSQL 17/18 cabe à auditoria do
Claude; não há resultado de banco registrado. Planos, migração, papéis, RLS e triggers seguem pendentes.

`git diff --check` passa e não há mudanças de modo em scripts. Os critérios 6 e 7 continuam parciais:
blog recusa 3 de 14 construtos conferidos, mini CRM 3 de 6 e chat 4 de 9. Contadores de taxa, identidades
anônimas, execução de operações e demais componentes de runtime continuam pendentes.

## Como a lacuna do critério 2 foi medida

O critério 2 pede que "cada regra semântica tenha um caso que a dispara". Procurar o nome do código nos testes
não basta: um teste pode disparar a regra e conferir só a falha. A primeira medição usou um gancho temporário em
`Diagnostic.new` e em `Error.single`, registrando os códigos **efetivamente criados**, comparados aos literais
encontrados nos pontos de emissão de `lib/`.

A verificação agora faz parte do repositório. `test/support/diagnostic_coverage.rb` extrai com Prism os códigos
literais passados a `issue`, `fail!`, `error`, `Error.single` e `Diagnostic.new(code:)`, com arquivo e linha de
cada ocorrência. São 154 códigos em 247 pontos de emissão. O carregador de teste
`diagnostic_coverage_runner.rb` instrumenta `Diagnostic.new`, que também recebe o que `Error.single` constrói,
e confere a cobertura depois da suíte. Códigos sem emissão e códigos emitidos sem declaração literal
reconhecida fazem a tarefa terminar com erro. A instrumentação existe só no processo de teste, fora da gem.

Executar `bundle exec rake test:diagnostics` ou `bundle exec rake`. A CI usa a primeira forma, sem executar a
suíte duas vezes. `rake test` continua disponível para seleção parcial sem a exigência global. Os seis testes
de `diagnostic_coverage_test.rb` cobrem catálogo sem falsos positivos de comentários/texto, códigos sem emissão,
emissão repetida, código desconhecido, Ruby inválido, catálogo vazio e o status de falha do carregador mesmo
quando o teste selecionado passa.

Limites: a medição cobre **códigos**, não cada ramo nem cada ponto que reutiliza um código. Ela não distingue
regra inalcançável de regra sem teste, nem verifica a qualidade das asserções. Um código calculado dinamicamente
num ramo nunca executado não aparece no catálogo; se emitido sem literal reconhecido, falha. Subprocessos não
alimentam o rastreio do processo principal. Algumas regras só são alcançáveis por uma IR montada à mão, e esse
continua sendo o caminho de teste para elas.

O diagnóstico `field_name_collides_with_record` é declarado na normalização e documentado nos
[nomes de campo do DSL](fase-0.md#nomes-de-campo-e-grupos-de-enum) e no
[catálogo do Vetra Data](vetra-data.md#diagnósticos-e-sigilo). `record_names_test.rb` exercita a recusa de
campos e predicados de enum, ponteiro, mensagem, origem, nomes legais e concordância com a defesa dos
repositórios. A reserva cobre métodos públicos e protegidos, privados cujo dono não é `Kernel` e os ganchos
privados do `Kernel` chamados pelo Ruby/Data; as demais funções privadas do `Kernel` são aceitas como campos
ou predicados de enum. Os testes cobrem construção, leitura e `with`, além de métodos e mudanças de
visibilidade após o carregamento. Sua emissão integra o mesmo gate automático do catálogo.

## Matriz dos 11 critérios

| # | Critério (resumo) | Situação | Evidência ou lacuna |
|---|---|---|---|
| 1 | Schema válido, exemplos com/sem tenant, falhas estruturais | Coberto | Exemplos documentais com e sem tenant passam pelo validador (`canonical_test`) e os exemplos compilam (`compiler_test`). Falham estruturalmente: versão futura, propriedade desconhecida, nó e referência de `kind` errados, operador desconhecido, número de ponto flutuante, **propriedade obrigatória ausente**, **decimal ou `money` com valor numérico** (`test_missing_required_properties_fail_structurally`, `test_decimal_and_money_literals_must_not_be_json_numbers`) e o próprio schema é válido no metaschema do Draft 2020-12 (`test_schema_is_a_valid_draft_2020_12_document`). |
| 2 | Cada regra semântica tem caso que a dispara | Coberto, com verificação na CI | A medição inicial encontrou 78 de 121 códigos; `diagnostics_test.rb` cobriu os 43 que faltavam. A suíte atual, incluindo `money_test.rb`, `timestamp_test.rb`, `query_output_test.rb`, `live_test.rb`, `authorization_sql_test.rb`, `relation_commands_test.rb`, `rounding_test.rb`, `rate_limit_test.rb` e `schema_sql_test.rb`, emite os 154 códigos do catálogo. `test:diagnostics` falha se faltar um código e informa suas origens. Limite: cobertura por código, não por ramo ou ponto de emissão. |
| 3 | Mesmo resultado entre checkouts, descoberta embaralhada, vetores Unicode | Coberto | Reprodução em diretórios diferentes, vetores JCS, ordem de enums e arrays posicionais já eram cobertos. `test_discovery_order_does_not_change_the_graph_bytes` embaralha a ordem em que o `Find` entrega os caminhos (3 sementes) e confere os mesmos bytes; ele confere também que a ordem mudou e falha se o compilador deixar de ordenar (verificado removendo `.sort` de `manifest.rb` numa cópia). |
| 4 | O hash reproduz o valor; mudanças invalidam o build | Coberto | `digest_excludes_only_root_digest_and_preserves_array_order`, `helpers_lockfile_additions_and_removals_invalidate_sources`, `mutating_policy_invalidates_digest`. |
| 5 | Versão suportada, MENOR/MAIOR futura, recurso não implementado | Coberto | `future_versions_features_and_unknown_properties_are_rejected`, `future_format_unknown_features_and_invalid_json_fail_before_registration`, `timestamp_test.rb`, `query_output_test.rb`, `relation_commands_test.rb`, `rounding_test.rb` e `rate_limit_test.rb`: leitura e link de 0.1/0.2/0.3/0.4/0.5 com semânticas antigas, incluindo retornos estruturados e live na 0.3; rebuild em 0.6 e revisão explícita da versão nos quatro exemplos, sem quebra. O schema e a validação semântica exatos recusam o requisito ou a primitiva de vínculo na 0.3 e o campo/requisito de arredondamento em 0.1 a 0.4, além do campo/requisito de taxa em 0.1 a 0.5; 0.7, 1.0 e recursos desconhecidos são recusados. Não há conversão automática. |
| 6 | Produção recusa IR ausente, adulterada ou incompatível | Parcial | O carregador recusa artefato ausente, não canônico, adulterado ou de versão não suportada (`link_test`), e a perda do cache descartável só recompila a mesma IR. Não há servidor de produção para exercitar o resto. |
| 7 | Contratos CRUD, políticas e transições equivalem aos três exemplos da proposta | Parcial, por desenho | Os testes cobrem as propriedades dos contratos CRUD (campos de dono, valores protegidos, tenant, chaves compostas e timestamps gerados). Os exemplos do repositório são recortes do subconjunto implementado, e os exemplos documentais são recortes didáticos que divergem do compilado. Conferidos construto a construto contra a proposta: no blog, 3 de 14 recusados; no mini CRM, 3 de 6; no chat, 4 de 9. Todos falham de forma audível. |
| 8 | Mesma IR gera saídas idênticas; `graph:check` detecta edição e desatualização | Coberto | `repeated_builds_in_different_directories_have_identical_bytes`, `check_detects_missing_edited_and_noncanonical_artifacts_without_overwriting`, `executable_reports_stale_graph_without_stack_trace`. |
| 9 | Diff distingue remoção, renomeação, capacidade nova, permissão, só origem | Coberto | 26 testes em `diff_test.rb` e 4 em `diff_source_test.rb`. `exposure_test.rb` também confere que adicionar CLI conserva as identidades HTTP e aparece como nova superfície com revisão de permissão. |
| 10 | Registro congelado, implementação ausente ou duplicada, recarga como unidade | Coberto, com uma limitação de desenho (mantida) | Declaração tardia (`registry_frozen`, `compiler_test`), implementação ausente ou duplicada (`linker_test`) e recarga bem-sucedida (`link_test`) estão cobertas. Limitação: a troca do **código** na recarga não é observável pela API pública (o `binding` guarda caminho e linha, não o digest da implementação, e as closures são privadas). Detalhes na seção abaixo. |
| 11 | Com Ractors, a cópia de dados é compartilhável; o núcleo passa sem a extensão | Coberto para os dados do compilador | `ractor_test.rb` compartilha os resultados dos quatro exemplos e os dados da vinculação com identidade preservada, recalcula o digest no receptor e recusa mutações profundas. Um subprocesso remove `Ractor` antes de carregar o Vetra e executa build/check/validate/link/diff nos quatro exemplos. Closures ficam no processo dono; execução concorrente de operações não foi implementada. |

## Os 43 códigos que antes não eram emitidos

Agrupados pelo arquivo que os emite. Cada um tem agora um caso em `test/diagnostics_test.rb`: o validador e as
declarações são tabelas de casos (`test_validator_emits_<código>` e `test_declaration_emits_<código>`), e os
quatro que dependem do ambiente têm teste próprio.

- **Validador (20):** `authorize_record`, `crud_repository`, `decimal_scale`, `dependency_unclassified`,
  `domain_unrestricted`, `duplicate_guard`, `duplicate_index`, `duplicate_input`, `duplicate_relation`,
  `enum_group`, `field_constraints`, `field_generation`, `field_rename`, `guard_value`, `implementation_ref`,
  `predicate_input`, `relation_key`, `sql_boundary`, `tenant_index`, `tenant_root`. Os casos alteram a IR de
  exemplo à mão, porque o validador também verifica IR que não veio do DSL (um artefato lido do disco) e o
  normalizador nunca produz alguns desses estados; `implementation_ref` e `tenant_root` são dois exemplos
  conferidos no código. Não foi verificado, regra a regra, quais as demais são alcançáveis pelo DSL.
- **Normalizador (10):** `app_missing`, `authorize_missing`, `crud_enum`, `field_missing`, `handler_idempotency`,
  `predicate_relation`, `reserved_field`, `route_format`, `tenant_mismatch`, `tenant_reference`.
- **DSL (5):** `domain_mismatch`, `domain_required`, `missing_implementation`, `unsafe_reason`,
  `unsupported_option`.
- **Arquivos e CLI (8):** `domain_name`, `duplicate_app`, `input_missing` e `input_symlink` são casos de
  declaração; `project_root`, `artifact_path`, `git_unavailable` e `schema_reference` têm teste próprio
  (`git_unavailable` esvazia o `PATH`, e `schema_reference` troca o caminho do schema por uma cópia com referência
  externa, restaurando-o em seguida).

## Conferência item a item dos critérios 1, 7 e 10

Feita em 2026-10-30 e 2026-10-31 com sondas avulsas, fora do repositório, e sem criar testes.

**Critério 1.** O schema declara `$schema` do Draft 2020-12 e é válido nesse metaschema (`JSONSchemer.valid_schema?`).
Remover uma propriedade obrigatória (`fields` de uma entidade, `app` da raiz, `authorize` de um comando) produz
`schema`. Um `money` com `amount` numérico produz `schema`, e o mesmo valor como string (`"12.00"`) é aceito. Um
operador desconhecido produz `schema`. Os três primeiros ganharam teste em `validator_test.rb`, e cada um falha se o
schema for enfraquecido (verificado em cópias descartáveis: sem `app` obrigatório, `amount` livre e schema inválido).
A lacuna era de teste, não de código. O `delete("required")` de `validator_test` testa uma regra semântica de campo,
não uma propriedade obrigatória do schema.

**Critério 7.** O `docs/ir/README.md` declara que os exemplos documentais são recortes didáticos, então a diferença
para o compilado (por exemplo, contratos `post_input` contra `*.input`, nenhum comando CRUD no documental) é
esperada e não é defeito. A comparação possível é contra o DSL da proposta (`docs/exemplos/`). No blog, cada
construto foi aplicado sozinho sobre `examples/blog`:

- **Aceitos (11):** `slug` com `from:` e `unique:`, `text`, `belongs_to :author, entity: :user, default:
  :current_actor` (com uma entidade `user` declarada), `normalize: :downcase` com `unique:`, a entidade `comment`
  com `email` pessoal, `boolean` com default e `set_by:` de um comando declarado, o papel visitante com
  `where:`, `can ... fields:`, `role :admin` com `can :manage, on: %i[...]` e `many_to_many :tags` com a entidade
  `tag` declarada (a junção é gerada), além de `rate_limit: "5/min"` em `can :create, on: :comment` (C4, IR 0.6).
- **Recusados (3):** `ui:` em `crud` e em `expose` e uma consulta sem `returns` nem
  `authorize`. Todos falham de forma audível, como o `fase-0.md` promete.

No mini CRM, a base foi `examples/mini_crm_revendas`, que reproduz o exemplo da proposta. Cada diferença entre a
proposta e o repositório foi aplicada sozinha:

- **Aceitos (3):** `currency "BRL", rounding: :half_up` (C3, IR 0.5), os papéis exatamente como na proposta
  (sem as leituras de `dealer`, `company`, `user` e `membership` que o repositório acrescenta) e o `lead` sem `transitions enforce: :db`.
- **Recusados (3):** `auth :token, memberships: :dealer`, o `dealer` sem
  `has_many :memberships` (o escopo por vínculo exige o inverso explícito, `scope_inverse`) e o `win_lead` sem
  `returns :lead`.

No chat, a base foi `examples/chat`:

- **Aceitos (5):** `can :add_member, :remove_member, on: :room, where: { owner: :current_actor }`, o comando
  `add_member_by_email` com `authorize :add_member` e `input :email, :email`, e `many_to_many :members, entity: :user,
  include: :owner` sem nenhuma junção declarada (antes era recusado), e `index :room_id, :created_at`
  usando a geração da IR 0.2, além de `live true` com dependências conservadoras na IR 0.3.
  O repositório agora declara `add_member` e `remove_member` explicitamente, com contrato de IDs, política do
  dono, rotas e recusa de remover o proprietário. `add_member_by_email` também está declarado, com contrato
  explícito de retorno, busca por capacidade de leitura e recusa de e-mail ausente ou ambíguo. A geração
  automática dos comandos de vínculo do PDF está implementada na C1; o chat usa `commands: false` para
  preservar as regras e exposições desses comandos explícitos. Reativá-la com os mesmos nomes é erro de colisão.
- **Recusados (4):** `auth :password`, `ui :server`, `realtime :websocket, fallback: :sse` e uma consulta sem
  `returns` nem `authorize`.

Os três exemplos juntos recusam cinco famílias: `auth`, UI, `realtime`, consulta sem contrato/autorização
explícitos e escopo por vínculo sem o `has_many` inverso. O `created_at` implícito é compilado desde a
IR 0.2, `live true` desde a 0.3, comandos de vínculo desde a 0.4, `rounding:` desde a 0.5 e `rate_limit:`
desde a 0.6. Essas declarações não implementam o runtime. Palavras-chave desconhecidas falham com
`unsupported_option`; obrigatórias ausentes, com `missing_option`, nomeando o método e a linha da declaração.

**Critério 10.** Uma recarga bem-sucedida troca a IR: o digest muda e a unidade antiga continua intacta. O
`binding` de uma operação guarda `kind`, `operation`, `ref`, `source` (caminho e linha), `parameters` e
`arguments`. Não guarda o digest da implementação, que fica na IR. Editar o texto do corpo de um `call` mudou o
documento e deixou o `binding` idêntico. A troca do código não é verificável pela API pública, porque as closures
são privadas e nenhum `call` é executado. Afirmar essa troca exigiria expor o digest da implementação no
`binding`, o que é uma decisão de projeto. A decisão foi **manter a limitação**: o digest já está na IR da unidade
e as closures são privadas por desenho.

## O que continua em aberto

A escala monetária por moeda da aplicação (ADR-017, §6) passou a ser normalizada e validada: os 12 testes de
`money_test.rb` cobrem moedas com 0, 2, 3 e 4 casas, precisão estendida, erro de escala insuficiente, defaults,
contratos CRUD, entradas de operações, eventos e IR externa. Isso não fecha o critério 7 nem os testes HTTP do
ADR-017: a sintaxe futura dos exemplos e o runtime continuam pendentes.

As exposições do ADR-007 agora são compiladas de `expose http:`, `cli:`, `job:` e `webhook:` para a IR 0.1.
Os 15 testes de `exposure_test.rb` cobrem o vínculo único à operação, nomes por superfície, rotas ambíguas,
métodos HTTP, consulta por POST, idempotência obrigatória de webhook, diagnósticos e IR externa. O mini CRM
declara as quatro superfícies; o `graph:diff` contra `635d926` mostra três rotas adicionadas, todas para
revisão, e nenhuma quebra potencial. Os adaptadores ainda não existem, e o critério 7 continua parcial.

Os 16 testes de `chat_test.rb` cobrem os comandos explícitos `add_member`, `add_member_by_email` e
`remove_member`, incluindo contratos tipados, política do dono, rotas, alteração de membros em duplos de
memória e busca por e-mail ausente ou ambíguo. Build e link apenas registram os três blocos. O compilador
também recusa uma gravação literal por `users_read` em um comando (`write_boundary`), além das escritas em
consultas. Isso preenche a ausência dos comandos no exemplo; a autorização em execução,
a normalização da entrada no runtime e a revogação live continuam pendentes. A busca por e-mail ficou
interna, sem superfícies, e o e-mail declara unicidade; convites com aceite continuam pendentes. O critério 7
segue parcial.

Os 16 testes de `rounding_test.rb` declaram `half_up` e `half_even` na aplicação, com padrão comercial
preservado. Desde a IR 0.5, o build emite campo e requisito `vetra.money_rounding` somente quando há declaração
de `rounding:`, inclusive `half_up`; omissão conserva ambos ausentes. O diff compara o modo efetivo e exige revisão de
quebra potencial de valores quando ele muda; explicitar o padrão não altera valores. Defaults com casas
excedentes continuam recusados. Campo/requisito novos são recusados em 0.1 a 0.4, e o link mantém as
semânticas antigas, incluindo comandos de vínculo da 0.4. O alcance é conversão e divisão com mais casas
que a escala de destino, nunca soma ou subtração; executar esses cálculos continua fora desta fase.
O ADR-033 foi aceito em 2026-11-03, e os critérios 6 e 7 continuam parciais.

Os 23 testes de `relation_commands_test.rb` cobrem a geração de inclusão/remoção por `many_to_many` na IR 0.4,
contratos de dois IDs tipados, autorização pela entidade dona, repositório customizado, tenant, junção
implícita, opt-out e colisões com comandos explícitos ou outras operações. Recusam opções inválidas,
junções sem unicidade, chaves opcionais/incompatíveis, dados obrigatórios adicionais e IR adulterada.
O link retorna o descritor `builtin` (sem `executor` desde a K17) e preserva artefatos 0.1/0.2/0.3, incluindo retornos estruturados e live
na 0.3, sem geração retroativa. A 0.3 recusa o requisito e as primitivas de vínculo; 0.7 é recusada como
MENOR futura. Os quatro exemplos têm revisão de `ir_version` 0.3 → 0.4, sem quebra. O diff cobre adição com
revisão de permissões, remoção como quebra, troca por Ruby e mudança da relação que altera a primitiva.
O ADR-032 foi aceito em 2026-11-03. Inclusão, remoção, preservação dos vínculos de `include:` e suas garantias
transacionais ainda dependem do executor; o critério 7 segue parcial.

Os 14 testes de `timestamp_test.rb` cobrem `created_at` em entidades e junções, contratos CRUD e de registro,
o índice composto do chat, projeções em evento, determinismo sem relógio e recusas de geração inválida ou
atribuição explícita. O schema 0.1 permanece inalterado; o link audita o artefato nessa versão, sem gerar
campos novos. O diff registra versão, requisito e campos da evolução 0.2. A atribuição no repositório,
atualizações e migrações de dados antigos ainda dependem do runtime.


Os 25 testes de `query_output_test.rb` cobrem as saídas de `my_rooms` e `room_page`, os tipos de registros e
coleções, classificação pessoal derivada, contexto de uso, ciclos e referências, capacidade de leitura e
diffs de garantias aninhadas. Os corpos são exercitados em memória para ordem, filtro da sala, limite de
100 mensagens e sala ausente. `returns` e `authorize` permanecem explícitos; a sintaxe implícita dos PDFs,
expansões de relações e entrega live continuam pendentes. O critério 7 segue parcial.

Os 21 testes de `live_test.rb` cobrem modos, opções inválidas, dependências derivadas de repositórios,
saídas e políticas, junções de autorização, listas explícitas, análise incompleta, limites de capacidade,
IR externa, preservação dos consumidores anteriores e diff de permissão. `graph:link` conserva os metadados
sem executar o corpo. O trigger de revisão, as assinaturas, a revogação e o transporte do ADR-020 continuam
pendentes; os critérios 6 e 7 permanecem parciais.

- O critério 1 está fechado. O 7 segue parcial por desenho: os três exemplos já foram conferidos construto a
  construto, e o que o DSL ainda recusa está listado acima. O 10 mantém a limitação do `binding` descrita acima.
- Um caso do validador prova que a regra dispara sobre uma IR montada à mão, não que o DSL consegue alcançá-la.
  Para as regras que o normalizador impede de chegar ao validador, isso é o esperado: o validador existe para
  recusar uma IR que não veio do compilador.
- A verificação automática impede um código literal novo de passar na CI sem emissão na suíte. Quem
  acrescentar outro ramo com um código já coberto ainda precisa escrever o teste desse ramo; a contagem por
  código não prova essa cobertura.

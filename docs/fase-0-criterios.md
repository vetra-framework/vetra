# Fase 0: cobertura dos critérios do ADR-001

O [ADR-001](adr/001-grafo-da-aplicacao-e-ir.md) lista 11 testes de aceitação para a fase 0. Este documento cruza
cada um com a suíte atual e registra o que está coberto, o que está parcial e o que é lacuna. Ele não declara a
fase 0 concluída: o [protótipo](fase-0.md) cobre parte dos critérios.

Medição de 2026-10-30, com Ruby 4.0.9. Antes de `test/diagnostics_test.rb` (commit `03e7264`): 136 testes e 1.007
asserções, sem falhas. Depois: 180 testes e 1.217 asserções, sem falhas.

## Como a lacuna do critério 2 foi medida

O critério 2 pede que "cada regra semântica tenha um caso que a dispara". Procurar o nome do código nos testes
não basta: um teste pode disparar a regra e conferir só a falha. Por isso a suíte foi executada com um gancho
temporário em `Diagnostic.new` e em `Error.single`, os dois pontos por onde passa todo diagnóstico, registrando
os códigos **efetivamente criados**. O resultado foi comparado com os códigos literais encontrados nos pontos de
emissão de `lib/`. O gancho não faz parte do repositório, e a instrumentação não alterou o resultado da suíte.

Limites da medição: ela só enxerga códigos escritos como literal no ponto de emissão (nenhum código emitido veio
de fora dessa lista) e não distingue uma regra inalcançável de uma regra sem teste. Algumas regras do validador
só são alcançáveis por uma IR montada à mão, não pelo DSL, e um teste que monta a IR é o caminho para elas.

## Matriz dos 11 critérios

| # | Critério (resumo) | Situação | Evidência ou lacuna |
|---|---|---|---|
| 1 | Schema válido, exemplos com/sem tenant, falhas estruturais | Coberto, com 3 lacunas de teste | Cobertos: exemplos documentais com e sem tenant passam pelo validador (`canonical_test`) e os exemplos compilam (`compiler_test`); versão futura, propriedade desconhecida, nó e referência de `kind` errados, operador desconhecido e número de ponto flutuante. **Sem teste, com comportamento correto (conferido):** propriedade obrigatória ausente, decimal ou `money` com valor numérico e validade do próprio schema no metaschema do Draft 2020-12. Detalhes na seção abaixo. |
| 2 | Cada regra semântica tem caso que a dispara | Coberto | Medido: eram 78 de 121 códigos de diagnóstico emitidos pela suíte. `test/diagnostics_test.rb` acrescenta um caso para cada um dos 43 que faltavam, e a suíte agora emite os 121. Cada caso confere o código, o ponteiro JSON e, quando a regra aponta um nó, a origem. |
| 3 | Mesmo resultado entre checkouts, descoberta embaralhada, vetores Unicode | Coberto | Reprodução em diretórios diferentes, vetores JCS, ordem de enums e arrays posicionais já eram cobertos. `test_discovery_order_does_not_change_the_graph_bytes` embaralha a ordem em que o `Find` entrega os caminhos (3 sementes) e confere os mesmos bytes; ele confere também que a ordem mudou e falha se o compilador deixar de ordenar (verificado removendo `.sort` de `manifest.rb` numa cópia). |
| 4 | O hash reproduz o valor; mudanças invalidam o build | Coberto | `digest_excludes_only_root_digest_and_preserves_array_order`, `helpers_lockfile_additions_and_removals_invalidate_sources`, `mutating_policy_invalidates_digest`. |
| 5 | Versão suportada, MENOR/MAIOR futura, recurso não implementado | Coberto, exceto o que depende de uma evolução | `future_versions_features_and_unknown_properties_are_rejected`, `future_format_unknown_features_and_invalid_json_fail_before_registration`. Leitura anterior e conversão só podem ser testadas quando existir a primeira evolução do formato. |
| 6 | Produção recusa IR ausente, adulterada ou incompatível | Parcial | O carregador recusa artefato ausente, não canônico, adulterado ou de versão diferente (`link_test`), e a perda do cache descartável só recompila a mesma IR. Não há servidor de produção para exercitar o resto. |
| 7 | Contratos CRUD, políticas e transições equivalem aos três exemplos da proposta | Parcial, por desenho | Os testes cobrem as propriedades dos contratos CRUD (campos de dono, valores protegidos, tenant, chaves compostas). Os exemplos do repositório são recortes do subconjunto implementado, e os exemplos documentais são recortes didáticos que divergem do compilado (49 e 58 mudanças no `graph:diff`). No blog da proposta, 5 de 14 construtos ainda são recusados pelo DSL. Mini CRM e chat não foram conferidos construto a construto. |
| 8 | Mesma IR gera saídas idênticas; `graph:check` detecta edição e desatualização | Coberto | `repeated_builds_in_different_directories_have_identical_bytes`, `check_detects_missing_edited_and_noncanonical_artifacts_without_overwriting`, `executable_reports_stale_graph_without_stack_trace`. |
| 9 | Diff distingue remoção, renomeação, capacidade nova, permissão, só origem | Coberto | 25 testes em `diff_test.rb` e 4 em `diff_source_test.rb`. |
| 10 | Registro congelado, implementação ausente ou duplicada, recarga como unidade | Coberto, com uma limitação de desenho | Declaração tardia (`registry_frozen`, `compiler_test`), implementação ausente ou duplicada (`linker_test`) e recarga bem-sucedida (`link_test`) estão cobertas. Limitação: a troca do **código** na recarga não é observável pela API pública (o `binding` guarda caminho e linha, não o digest da implementação, e as closures são privadas). Detalhes na seção abaixo. |
| 11 | Com Ractors, a cópia de dados é compartilhável; o núcleo passa sem a extensão | Parcial | `Ractor.make_shareable` é conferido nos documentos e na vinculação (`compiler_test`, `link_test`). O compartilhamento entre Ractors é opcional no ADR-001 e não existe como extensão; o núcleo roda sem ele. |

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

Feita em 2026-10-30 com sondas avulsas, fora do repositório, e sem criar testes.

**Critério 1.** O schema declara `$schema` do Draft 2020-12 e é válido nesse metaschema
(`JSONSchemer.valid_schema?`). Remover uma propriedade obrigatória (`fields` de uma entidade, `app` da raiz,
`authorize` de um comando) produz `schema`. Um `money` com `amount` numérico produz `schema`, e o mesmo valor como
string (`"12.00"`) é aceito. Um operador desconhecido produz `schema`. Nenhum dos três primeiros tem teste. A
lacuna é de teste, não de código. O `delete("required")` de `validator_test` testa uma regra semântica de campo,
não uma propriedade obrigatória do schema.

**Critério 7.** O `docs/ir/README.md` declara que os exemplos documentais são recortes didáticos, então a diferença
para o compilado (por exemplo, contratos `post_input` contra `*.input`, nenhum comando CRUD no documental) é
esperada e não é defeito. A comparação possível é contra o DSL da proposta (`docs/exemplos/`). No blog, cada
construto foi aplicado sozinho sobre `examples/blog`:

- **Aceitos (9):** `slug` com `from:` e `unique:`, `text`, `belongs_to :author, entity: :user, default:
  :current_actor` (com uma entidade `user` declarada), `normalize: :downcase` com `unique:`, a entidade `comment`
  com `email` pessoal, `boolean` com default e `set_by:` de um comando declarado, o papel visitante com
  `where:`, `can ... fields:` e `role :admin` com `can :manage, on: %i[...]`.
- **Recusados (5):** `many_to_many :tags` sem entidade de junção declarada (a geração automática é documentada
  como não implementada), `ui:` em `crud` e em `expose`, `rate_limit:` em `can` e uma consulta sem `returns` nem
  `authorize`. Todos falham de forma audível, como o `fase-0.md` promete.

**Critério 10.** Uma recarga bem-sucedida troca a IR: o digest muda e a unidade antiga continua intacta. O
`binding` de uma operação guarda `kind`, `operation`, `ref`, `source` (caminho e linha), `parameters` e
`arguments`. Não guarda o digest da implementação, que fica na IR. Editar o texto do corpo de um `call` mudou o
documento e deixou o `binding` idêntico. A troca do código não é verificável pela API pública, porque as closures
são privadas e nenhum `call` é executado. Afirmar essa troca exigiria expor o digest da implementação no
`binding`, o que é uma decisão de projeto.

## O que continua em aberto

- As lacunas dos critérios 1, 7 e 10 estão detalhadas na seção anterior.
- Um caso do validador prova que a regra dispara sobre uma IR montada à mão, não que o DSL consegue alcançá-la.
  Para as regras que o normalizador impede de chegar ao validador, isso é o esperado: o validador existe para
  recusar uma IR que não veio do compilador.
- A medição por rastreio de códigos não faz parte do repositório. Quem acrescentar uma regra nova precisa
  acrescentar o caso correspondente; nada ainda impede que um código novo nasça sem teste.

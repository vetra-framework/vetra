# Fase 0: cobertura dos critérios do ADR-001

O [ADR-001](adr/001-grafo-da-aplicacao-e-ir.md) lista 11 testes de aceitação para a fase 0. Este documento cruza
cada um com a suíte atual e registra o que está coberto, o que está parcial e o que é lacuna. Ele não declara a
fase 0 concluída: o [protótipo](fase-0.md) cobre parte dos critérios.

Medição de 2026-10-30, no commit `03e7264`, com Ruby 4.0.9: 136 testes e 1.007 asserções, sem falhas.

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
| 1 | Schema válido, exemplos com/sem tenant, falhas estruturais | Parcial | Cobertos: versão futura, propriedade desconhecida, nó e referência de `kind` errados, número de ponto flutuante (`validator_test`, `canonical_test`, `compiler_test`). Não conferido item a item: propriedade obrigatória ausente. O código `schema_reference` nunca é emitido. |
| 2 | Cada regra semântica tem caso que a dispara | **Lacuna medida** | 78 dos 121 códigos de diagnóstico são emitidos pela suíte; **43 nunca são** (lista abaixo). |
| 3 | Mesmo resultado entre checkouts, descoberta embaralhada, vetores Unicode | Parcial | Cobertos: reprodução em diretórios diferentes, vetores JCS, ordem de enums, arrays posicionais. **Lacuna:** nenhum teste embaralha a ordem de descoberta. A implementação já ordena (`paths.uniq.sort` em `manifest.rb`), então falta o teste, não o código. |
| 4 | O hash reproduz o valor; mudanças invalidam o build | Coberto | `digest_excludes_only_root_digest_and_preserves_array_order`, `helpers_lockfile_additions_and_removals_invalidate_sources`, `mutating_policy_invalidates_digest`. |
| 5 | Versão suportada, MENOR/MAIOR futura, recurso não implementado | Coberto, exceto o que depende de uma evolução | `future_versions_features_and_unknown_properties_are_rejected`, `future_format_unknown_features_and_invalid_json_fail_before_registration`. Leitura anterior e conversão só podem ser testadas quando existir a primeira evolução do formato. |
| 6 | Produção recusa IR ausente, adulterada ou incompatível | Parcial | O carregador recusa artefato ausente, não canônico, adulterado ou de versão diferente (`link_test`), e a perda do cache descartável só recompila a mesma IR. Não há servidor de produção para exercitar o resto. |
| 7 | Contratos CRUD, políticas e transições equivalem aos três exemplos da proposta | Parcial | Contratos CRUD sem campos protegidos, defaults e chaves compostas por tenant são testados. A equivalência exata com os três exemplos da proposta não foi conferida item a item. |
| 8 | Mesma IR gera saídas idênticas; `graph:check` detecta edição e desatualização | Coberto | `repeated_builds_in_different_directories_have_identical_bytes`, `check_detects_missing_edited_and_noncanonical_artifacts_without_overwriting`, `executable_reports_stale_graph_without_stack_trace`. |
| 9 | Diff distingue remoção, renomeação, capacidade nova, permissão, só origem | Coberto | 25 testes em `diff_test.rb` e 4 em `diff_source_test.rb`. |
| 10 | Registro congelado, implementação ausente ou duplicada, recarga como unidade | Coberto, com uma ressalva | `only_a_sealed_registry_can_be_published`, `missing_and_unexpected_implementations_are_rejected`, `missing_or_duplicate_declaration_is_rejected`. A falha de uma recarga preserva o grafo anterior (`failed_relink_keeps_previously_returned_graph_unchanged`); a recarga bem-sucedida como unidade não foi conferida individualmente. |
| 11 | Com Ractors, a cópia de dados é compartilhável; o núcleo passa sem a extensão | Parcial | `Ractor.make_shareable` é conferido nos documentos e na vinculação (`compiler_test`, `link_test`). O compartilhamento entre Ractors é opcional no ADR-001 e não existe como extensão; o núcleo roda sem ele. |

## Os 43 códigos que a suíte nunca emite

Agrupados pelo arquivo que os emite. Cada um é uma regra declarada no compilador que nenhum teste dispara hoje.

- **Validador (20):** `authorize_record`, `crud_repository`, `decimal_scale`, `dependency_unclassified`,
  `domain_unrestricted`, `duplicate_guard`, `duplicate_index`, `duplicate_input`, `duplicate_relation`,
  `enum_group`, `field_constraints`, `field_generation`, `field_rename`, `guard_value`, `implementation_ref`,
  `predicate_input`, `relation_key`, `sql_boundary`, `tenant_index`, `tenant_root`.
- **Normalizador (10):** `app_missing`, `authorize_missing`, `crud_enum`, `field_missing`, `handler_idempotency`,
  `predicate_relation`, `reserved_field`, `route_format`, `tenant_mismatch`, `tenant_reference`.
- **DSL (5):** `domain_mismatch`, `domain_required`, `missing_implementation`, `unsafe_reason`,
  `unsupported_option`.
- **Arquivos e CLI (8):** `artifact_path` e `project_root` (compilador), `domain_name` (carregador de
  declarações), `git_unavailable` (diff por revisão), `input_missing` e `input_symlink` (manifesto),
  `duplicate_app` (registro), `schema_reference` (esquema).

## Como fechar a lacuna

A lacuna do critério 2 se fecha com um caso por código, preferindo uma tabela de casos (entrada que dispara,
código esperado, ponteiro JSON e origem) a 43 testes isolados. O critério 3 pede um teste que embaralhe a ordem
de descoberta dos arquivos e compare os bytes. Os critérios 1, 7 e 10 pedem a conferência item a item descrita
na matriz. Conforme o [índice dos ADRs](adr/README.md), isso faz parte de "fechar as lacunas declarativas e os
critérios restantes da fase 0".

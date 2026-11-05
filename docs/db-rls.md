# RLS e integridade no plano inicial

`vetra db:plan` gera RLS, revisão e transições para banco vazio. As decisões estão no
[ADR-037](adr/037-politicas-e-transicoes-no-plano-inicial.md), junto dos ADRs 005, 021,
023, 030/031 e 036. O [guia de planos](db-plan.md) descreve papéis e chaves.

## Artefatos e limites

- `db/plans/0001_inicial.sql` contém todos os passos aplicáveis, numa transação.
- `db/policies/0001_seguranca.sql` espelha as instruções RLS/transições e registra o que fica na
  aplicação. É material para revisão; não se aplica separadamente.
- `db:plan`, `--snapshot` e `--check` recusam plano ou espelho divergente da IR antes de acessar o
  banco. Um arquivo extra em `db/policies/` também é divergência (`db_policies_stale`).
- Em banco nunca aplicado, remova o plano inicial e execute `db:plan` para regenerar plano/espelho
  juntos. Banco existente exige migração incremental; remover arquivo não migra o banco.
- `db/schema.sql` vem de `--snapshot`, com pg_dump da mesma versão principal do servidor, e conserva
  RLS, donos, ACLs, funções e triggers.

No mini CRM, `companies` e `leads` têm tenant restritivo e permissiva `true`. No CRM com revendas,
`companies`, `users` e `memberships` têm essa permissiva; `dealers` só permite leitura do escopo, e
`leads` tem permissivas por ação, consultando os vínculos do ator. Gerente exclui leads de sua revenda;
vendedor lê/cria/atualiza, e um ator com vários vínculos alcança várias revendas do mesmo tenant.
Todas as tabelas, inclusive a raiz por `id`, têm ENABLE/FORCE e USING/WITH CHECK de tenant.

A permissão SQL das tabelas sem escopo não implementa o RBAC inteiro. Em particular, administrar
`memberships` exige autorização da aplicação; SQL arbitrário como vetra_app pode modificar esses
vínculos dentro do tenant. Campos, papéis sem vínculo materializado e limites de taxa também ficam no
runtime. Predicados fora do subconjunto do ADR-037 são registrados no espelho e ficam na aplicação.
Blog e chat não têm tenant: sem RLS de tenant/escopo nem revisão; o plano registra essa limitação.
Não há views no plano inicial; futuras views precisam de `security_invoker = true`.

As transições dos CRMs rejeitam INSERT protegido, entrada ou saída de `won` com comando indevido.
`crm.win_lead` pode realizar essas alterações. A fixture da sonda cobre também `set_by`: ausência,
default e valor conservado são permitidos; alterar, preencher ou limpar exige comando dono.
O trigger sempre exige contexto válido, salvo para o migrador. Não executa os comandos, eventos ou
histórico: essas obrigações pertencem ao runtime.

## Sonda no PostgreSQL 17 e 18

Num cluster descartável, execute o bootstrap do [guia](db-plan.md#bootstrap-e-contexto-assinado) e:

```sh
DATABASE_URL=... bundle exec ruby script/sonda_rls_integridade.rb
```

São esperadas **103 verificações**: 28 no mini CRM, 36 no CRM com revendas, 38 na fixture `set_by`
e uma conferência final dos papéis. Cada linha informa a expectativa e `OK`/`FALHA`; qualquer falha
produz saída 1. A sonda usa superusuário só para criar/remover seus três bancos, pertencentes a
vetra_migrator, e montar as observações auxiliares. Aplica o plano sob SESSION AUTHORIZATION do
migrador, sem superusuário/CREATEDB/CREATEROLE, e exercita DML sob SESSION AUTHORIZATION de vetra_app.
Chaves e tokens são aleatórios, apenas em memória, provisionados por parâmetros; não são impressos.
Os bancos são removidos no ensure; papéis globais preexistentes não são removidos nem alterados.

| Verificação | Resultado esperado |
|---|---|
| Plano gerado e guardas após REVOKEs | Aplicação integral pelo migrador, sem erro |
| SELECT permitido em cada tenant | Lead e raiz próprios, contagem positiva e IDs exatos |
| INSERT/UPDATE/DELETE dentro do tenant/escopo | Uma linha por operação e revisão +1 a cada escrita |
| UPDATE da raiz própria | Uma linha e revisão +1 |
| SELECT/UPDATE/DELETE de outro tenant ou revenda | Zero linhas; revisão estável |
| INSERT com outro tenant, raiz ou revenda | SQLSTATE `42501` |
| UPDATE que troca tenant ou revenda | SQLSTATE `42501` por WITH CHECK |
| FK com seller de outro tenant | `23503`; seller do mesmo tenant é permitido |
| Sem contexto ou token inválido | SELECT vazio em todas as tabelas, UPDATE/DELETE zero, INSERT `42501` |
| Claim cmd adulterada sem reassinar | INSERT protegido `42501` |
| Revisão e rollback | Incremento visível na transação; rollback desfaz dados e contador |
| View security_invoker e função invoker | Acesso permitido à linha própria; nenhuma linha extra |
| Transições genéricas e comando dono | new → contacted permitido; won só entra/sai pelo dono; conservar valor é permitido |
| set_by com NULL/default/valor novo | Default e valor conservado permitidos; alterações só pelo dono ou migrador |
| Segundo vínculo do ator | Mais uma revenda visível e revisão +1; rollback desfaz o vínculo |
| Ator sem vínculo | Nenhum lead; raiz do tenant continua visível |
| Catálogo global de papéis | Idêntico antes/depois dos três planos |

`script/sonda_contexto_assinado.rb` continua cobrindo validade, MAC, rotação e mutações da exceção C2;
reexecuta somente as guardas porque a infraestrutura de revisão já pertence ao plano. Ambas as sondas
entram no job `db-plan`, matriz 17/18. Testes Ruby e `ruby -c` não substituem a execução no banco.

## Diagnósticos

| Código | Recusa |
|---|---|
| `security_literal` | U+0000 em literal de política/transição |
| `security_scope_index` | Vínculo sem índice físico com prefixo tenant/ator |
| `security_policy_cycle` | Ciclo de dependências entre políticas SQL |
| `security_transition_default` | set_by com default de contexto e enforce db |
| `db_policies_stale` | Espelho ausente, alterado ou com arquivos adicionais |

Identificadores passam pelas validações físicas e `Context.quote`; não se recebe SQL cru da IR.
O executor persistente, retomada, introspecção, deriva, locks consultivos e hashes de planos pertencem
à K8. Upgrades com dados e desempenho sob concorrência/pooler são trabalho posterior.

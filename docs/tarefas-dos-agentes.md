# Tarefas dos agentes

Quadro das tarefas divididas entre o Codex e o Claude, conforme [AGENTS.md](../AGENTS.md). Cada linha diz quem
está com a tarefa, a situação e a auditoria. O mantenedor define prioridades e pode trocar responsáveis.

Situações: `a fazer`, `em andamento`, `em auditoria`, `devolvida`, `concluída`.

## Rodada 1 (2026-11-03)

| ID | Tarefa | Responsável | Situação | Commit | Auditoria e parecer |
|---|---|---|---|---|---|
| K1 | Registrar o fluxo entre agentes: `AGENTS.md`, `CLAUDE.md` e este quadro | Claude | concluída | ver histórico | Parecer do Codex pedido |
| K2 | Auditar as entregas do Codex de `cb7c0b5` a `61efbb8` | Claude | concluída | — | Resultado abaixo |
| K3 | Atualizar a linha de commits do resumo da situação e formalizar as linhas de cabeçalho permitidas em ADR aceito | Claude | concluída | ver histórico | Parecer do Codex pedido |
| C1 | Geração automática dos comandos de vínculo de `many_to_many` (parte do critério 7) | Codex | concluída | `58993e2` | Devolvida na rodada 1, aprovada na rodada 2; ADR-032 proposto; CI verde ([auditoria](#auditoria-c1)) |
| K4 | Protocolo novo: os dois implementam, auditoria cruzada, decisão e envio pelo Claude; lacunas do parecer | Claude | concluída | `e761f05` | Pedido do mantenedor; incorpora o parecer do Codex sobre `1aca944` |
| K5 | `db:authz:sql`: fechar os caminhos que contornam a revisão (papéis assumíveis por `SET ROLE`, `ADMIN OPTION`, `REFERENCES`, `session_replication_role`) | Claude | concluída | `fb41921` | Rodadas 1 a 3 devolvidas pelo Codex; rodada 4 aprovada com ajuste não bloqueante; CI verde, sonda 29/29 no PostgreSQL 17 e 18 ([auditoria](#auditoria-k5)) |
| C2 | `db:authz:sql`: recusar ou listar para revisão as rotinas `SECURITY DEFINER` existentes que a aplicação pode executar e que pertencem a papéis com poder de escrita, `TRUNCATE` ou `TRIGGER` nas tabelas protegidas (achado da auditoria da K5) | Codex | concluída | `4588b78` | Rodadas 1 e 2 devolvidas pelo Claude; rodada 3 aprovada; CI verde, sonda 59/59 no PostgreSQL 17 e 18 ([auditoria](#auditoria-c2)) |

### C1: escopo

- Gerar, a partir de `many_to_many`, os comandos de inclusão e remoção do vínculo previstos na proposta, com
  contrato tipado, autorização pela entidade dona da relação e descritor de primitiva, sem executor.
- Decidir num ADR `proposto` como a geração convive com comandos declarados explicitamente (o chat já declara
  `add_member` e `remove_member`), como se chamam, como se desligam e o que entra no diff.
- Testes de compilação, diagnóstico das recusas, exemplos reconstruídos, gate sem quebra não declarada e docs
  (`fase-0.md`, critérios e situação) coerentes.
- Entregar sem commit, com o relatório do protocolo.

## Rodada 2 (2026-11-03)

O mantenedor delegou ao Claude as decisões pendentes. Decidido: ADR-032 aceito, com a geração ligada por padrão;
ADRs 028 a 031 confirmados; nenhuma questão em aberto vira ADR de resolução agora; a consulta sem `returns` nem
`authorize` continua recusada. O Codex não alcança o PostgreSQL no sandbox, então as tarefas com sonda ficam com
o Claude e as de compilador podem ir para os dois.

| ID | Tarefa | Responsável | Situação | Commit | Auditoria e parecer |
|---|---|---|---|---|---|
| C3 | `rounding:` em `currency` (construto da proposta hoje recusado, critério 7): ADR proposto, DSL, IR em nova MENOR conforme o ADR-001 §4, validador, diff e docs | Codex | concluída | `1a8ee02`, `3221157` | Rodada 1 devolvida pelo Claude; rodada 2 aprovada; ADR-033 aceito por delegação; CI verde ([auditoria](#auditoria-c3)) |
| K6 | `sonda_adr015`: os quatro casos do ADR-025 (índice e chave em tabela particionada, chave composta por tenant, `CHECK` de `enum`), na CI do PostgreSQL 17 e 18 | Claude | concluída | `77685b0` | Rodada 1 devolvida pelo Codex; rodada 2 aprovada; CI verde, sonda 31/31 no PostgreSQL 17 e 18 ([auditoria](#auditoria-k6)) |
| C4 | `rate_limit:` em `can` (construto da proposta hoje recusado, critério 7), depois da C3 e no mesmo formato | Codex | concluída | `bcc7651` | Rodada 1 devolvida pelo Claude; rodada 2 aprovada; ADR-034 aceito por delegação; CI verde ([auditoria](#auditoria-c4)) |

Rodada concluída. A gem alpha.5 pode ser publicada pelo mantenedor, e o passo seguinte é começar a persistência.

## Rodada 3 (2026-11-03)

Persistência: do grafo a um banco criado por plano versionado, com papéis e RLS, aplicado por `db:migrate`. O
objetivo, a lacuna de decisão, os riscos e as regras estão no [plano da persistência](plano-persistencia.md), que
incorpora o parecer do Codex.

| ID | Tarefa | Responsável | Situação | Commit | Auditoria e parecer |
|---|---|---|---|---|---|
| C5 | Mapeamento físico: ADR-035 proposto e função pura da IR para o modelo de esquema e o DDL de um banco vazio | Codex | concluída | `a9b2bfc` | Aprovada na rodada 1; ADR-035 aceito por delegação; CI verde ([auditoria](#auditoria-c5)) |
| K7 | `db:plan`: formato do plano, executor comum em banco descartável, retrato `db/schema.sql` e `--check` na CI | Claude | concluída | `c6c68e6`, `9f48cd7` | Rodadas 1 a 4 devolvidas pelo Codex; rodada 5 aprovada; CI verde, `--check` no PostgreSQL 17 e 18 ([auditoria](#auditoria-k7)) |
| C6 | Papéis, `vetra_private`, contexto assinado e provisionamento mínimo das chaves | Codex | concluída | `0feaedd`, `4bd4a39` | Rodada 1 devolvida pelo Claude; rodada 2 aprovada; ADR-036 aceito por delegação; CI verde, sonda 58/58 no PostgreSQL 17 e 18 ([auditoria](#auditoria-c6)) |
| C7 | RLS de tenant e de escopo, revisão de autorização como passos do plano e triggers de `transitions enforce: db` | Codex | concluída | `afb3009`, `92aa04f` | Rodada 1 devolvida pelo Claude; rodada 2 aprovada; ADR-037 aceito por delegação; CI verde, sonda 103/103 no PostgreSQL 17 e 18 ([auditoria](#auditoria-c7)) |
| K8 | `db:migrate`: `vetra.migrations`, lock consultivo, `lock_timeout` com novas tentativas, verificação prévia e retomada | Claude | concluída | `da3dda9`, `5b15437` | Rodadas 1 a 3 devolvidas pelo Codex; rodada 4 aprovada; CI verde, sonda 21/21 no PostgreSQL 17 e 18 ([auditoria](#auditoria-k8)) |

Rodada concluída. Todos os exemplos vão do banco vazio ao plano inicial aplicado por `db:migrate`.

## Rodada 4 (2026-11-05)

Persistência, parte 2: o banco da rodada 3 evolui por plano incremental, e o Vetra Data grava nele pelos
repositórios, com contexto emitido em Ruby e eventos na outbox. O objetivo, as decisões a tomar, os riscos e o que
fica para a rodada 5 estão no [plano da persistência](plano-persistencia.md#rodada-4-plano-incremental-repositórios-e-outbox).
O planejamento foi decidido pelo Claude, por delegação do mantenedor, e incorpora o parecer do Codex (abaixo). As
tarefas seguem a ordem da tabela.

| ID | Tarefa | Responsável | Situação | Commit | Auditoria e parecer |
|---|---|---|---|---|---|
| K9 | Fundação do plano incremental: ADR-038, modelo físico versionado e cadeia, modo de transação por passo, história ancorada no gate, filtro de instruções globais, aplicação como `vetra_migrator` com guarda de papéis e catálogo conferido, `--check` com N planos e convergência | Claude | concluída | `5fa7a3a` | Rodadas 1 a 5 devolvidas pelo Codex; rodada 6 aprovada; ADR-038 aceito por delegação; CI verde, sonda 18/18 no PostgreSQL 17 e 18 ([auditoria](#auditoria-k9)) |
| C8 | Unidade de trabalho sobre o Sequel, `sequel` e `pg` como dependências de runtime, emissão do contexto assinado em Ruby e contexto global: ADR-039 proposto | Codex | a fazer | — | — |
| C9 | Diferenças aditivas do modelo para a IR em passos expand classificados, com recusa audível do resto | Codex | a fazer | — | — |
| K10 | `db:migrate` incremental: progresso por passo, passos fora de transação, índices válidos e inválidos não registrados, base e estado intermediário conferidos, retomada | Claude | a fazer | — | — |
| C10 | Repositórios gerados da IR, com registros `Data` congelados, métodos de vínculo e consulta restrita; corpos dos quatro exemplos contra o banco | Codex | a fazer | — | — |
| K11 | Outbox, armazenamento e emissão: ADR-040 proposto (papéis e RLS), tabelas particionadas no `0002` dos exemplos com eventos, gravação na unidade de trabalho | Claude | a fazer | — | — |
| K12 | Relay, entregas e manutenção com consumidores simulados: lease, tentativas, entrega morta, partições e purga reconhecidas pela deriva | Claude | a fazer | — | — |
| K13 | Custo do contexto assinado por instrução, medição preliminar na matriz do ADR-023, e construção dos `Data` (ADR-022, §3) | Claude | a fazer | — | — |

### Parecer do Codex sobre o plano

Pedido sobre `088e317`, em modo somente leitura. O Codex devolveu a primeira versão do plano; a decisão de cada
achado é do Claude.

| Achado do Codex | Bloqueia | Decisão do Claude |
|---|---|---|
| A classificação por prefixo não substitui a proteção atual do `--check`, que só aplica um plano igual ao regenerado: um passo com `CREATE TABLE` e `COMMENT ON DATABASE` passa | sim | Ajustar: a K9 entrega validação integral das formas, modelos exatos de rotinas, execução sem privilégio administrativo e a exceção estrita dos privilégios do banco corrente |
| Introspectar o banco no planejamento contraria o ADR-025, §1, que reserva a introspecção à verificação | sim | Ajustar: modelo físico versionado e vinculado ao plano, conferido pelo replay e pelo retrato no `--check`; o ADR-038 declara essa leitura do §1 |
| A K9 prometia `CONCURRENTLY` e N planos, mas o executor descartável envolve o plano inteiro numa transação | sim | Ajustar: a K9 vira a fundação (modelo, formato, validação e executor) e as diferenças aditivas vão para a C9; a K10 cobre a queda depois do DDL fora de transação, inclusive com o índice válido não registrado. A C8 deixa de depender da K9 |
| As partições criadas pela manutenção apareceriam como deriva no `db:migrate` | sim | Ajustar: o ADR-040 decide como a deriva as reconhece; a K12 tem sonda que aceita a manutenção e recusa uma partição adulterada |
| A K11 prometia entregar a handlers, mas o executor e o ator de sistema ficam para a rodada 5 | sim | Ajustar: a outbox foi dividida em K11 (armazenamento e emissão) e K12 (relay com consumidores simulados); handlers reais vão para a rodada 5. O ADR-040 cobre quem grava, o relay e a manutenção, sem `vetra_migrator` no runtime |
| Blog e chat são globais, e o ADR-036 exige tenant e ator; faltavam formas usadas pelos corpos, como os métodos de vínculo | sim | Ajustar: o ADR-039 define o contexto global sem inventar tenant; a C10 lista `update!` por registro e por ID, `first(n)`/`last(n)`, `add_member!`/`remove_member!`, atribuições de contexto, normalização e geração |
| A K12 não especificava a matriz do gate do ADR-023 e não podia medir o percentual por comando sem executor | sim | Ajustar: K13 como medição preliminar por instrução na matriz do ADR-023, com o gate dos `Data`; o percentual por comando vai para a rodada 5, e uma fusão de funções exige ADR |
| O `pg` continua como dependência de desenvolvimento | não | Ajustar: a C8 promove `sequel` e `pg` |
| A situação ainda dava a aplicação de migrações como pendente | não | Ajustar: distingue o plano inicial aplicado do incremental pendente |

Na segunda rodada, o Codex aprovou o plano e confirmou os nove achados como resolvidos. Restaram dois achados não
bloqueantes:

| Achado do Codex | Bloqueia | Decisão do Claude |
|---|---|---|
| O plano chama de "leitura" do ADR-025, §1 o que é comparar com outro artefato | não | Ajustar: o ADR-038 diz expressamente como complementa o §1, inclusive segurança e infraestrutura, e o replay prova a equivalência entre modelo, planos e retrato |
| Faltava a recuperação de uma partição `DEFAULT` populada antes da primeira manutenção | não | Ajustar: a K12 prepara as partições antes de liberar quem grava, com uma sonda de recuperação sem perda nem duplicação |

## Auditoria K9

Implementado pelo Claude sobre `d70a00f`; auditado pelo Codex; decisão do Claude. As sondas e o `--check` foram rodados
pelo Claude no PostgreSQL 18.6; o 17 roda no job `db-plan` da CI. O ADR-038 troca a validação integral prevista no
planejamento por regeneração do último plano, história ancorada no gate e contenção; o Codex avaliou a troca.

**Rodada 1 — devolvida pelo Codex.**

| Achado do Codex | Bloqueia | Decisão do Claude |
|---|---|---|
| A cadeia aceitava uma história editada com os hashes recalculados na mesma árvore: nenhuma âncora fora da entrega | sim | Ajustar: o gate confere `db/plans/` e `db/models/` contra a base integrada (arquivo da base inalterado; arquivo novo só depois dos da base) |
| O `vetra_migrator` pode ser dono de outro banco no mesmo servidor, e as ACLs e parâmetros desse banco não entravam no catálogo | sim | Ajustar: o servidor em que o migrador administra outro banco é recusado antes de criar o temporário; o catálogo inclui dono, ACL e parâmetros de todos os bancos |
| A convergência por igualdade textual recusaria uma coluna acrescentada, que fica no fim da tabela | sim | Ajustar: a convergência ignora só a ordem das linhas de cada `CREATE TABLE`; o retrato segue exato. A sonda converge com uma coluna nova |
| A consulta do catálogo lia `pg_authid` mesmo sem superusuário | sim | Ajustar: a senha é lida numa consulta separada, só com superusuário |
| O `db:migrate` aplicaria um segundo plano `unica` num banco vazio | sim | Ajustar: qualquer plano pendente depois do inicial é recusado com `db_migrate_incremental` |
| O filtro recusava identificadores e literais válidos, como uma coluna `copy` | sim | Ajustar: o filtro lê só o código, sem comentários, literais e identificadores; os corpos `$...$` continuam lidos |
| A libpq podia completar o login do migrador com `PGPASSWORD`, `~/.pgpass` ou um `service` do administrador | sim | Ajustar: o login não herda `passfile` nem `service`, e as variáveis de login da libpq saem do ambiente durante a conexão |

**Rodada 2 — devolvida pelo Codex.** Os ajustes de precondição, catálogo de bancos, `pg_authid`, recusa no
`db:migrate` e login do migrador foram confirmados. O Codex considerou a troca da validação integral aceitável em
princípio, condicionada aos dois primeiros achados abaixo.

| Achado do Codex | Bloqueia | Decisão do Claude |
|---|---|---|
| O gate aceitava dois planos novos, e só o último é regenerado: um `0002` com `DELETE` passou com a cadeia recalculada | sim | Ajustar: no máximo um plano novo por aplicação em cada integração, inclusive numa aplicação nova |
| A convergência ordenava linhas soltas, inclusive dentro de literais de várias linhas | sim | Ajustar: ordena definições inteiras de coluna e restrição, com os literais intactos |
| `pg_catalog."set_config"(...)`, com o nome entre aspas, passava pelo filtro | não | Ajustar: o identificador entre aspas chamado como função é conferido pelo nome |

**Rodada 3 — devolvida pelo Codex.** O limite de um plano novo, inclusive em aplicação nova, foi confirmado.

| Achado do Codex | Bloqueia | Decisão do Claude |
|---|---|---|
| Tablespaces ficavam fora da precondição e do catálogo, e o filtro aceitava `GRANT ... ON TABLESPACE` | sim | Ajustar: a precondição recusa tablespace e parâmetro que o migrador administra; o catálogo inclui tablespaces e ACLs de parâmetros; o filtro recusa `ON DATABASE`, `ON TABLESPACE` e `ON PARAMETER` |
| A convergência removia o CR antes do LF dentro de literais | sim | Ajustar: tira só o LF de cada linha |
| Um comentário entre o nome entre aspas e o parêntese escondia a chamada | não | Ajustar: espaços e comentários, inclusive aninhados, são pulados antes do parêntese |
| O caminho que grava o modelo de um plano inicial antigo não conferia o espelho de políticas | não | Ajustar: o espelho é conferido antes de gravar o modelo |

**Rodada 4 — devolvida pelo Codex.** A rodada foi pedida em 2026-11-06, depois que o limite de uso da conta do Codex
interrompeu a primeira tentativa em 2026-11-05. Os quatro ajustes da rodada 3 foram confirmados.

| Achado do Codex | Bloqueia | Decisão do Claude |
|---|---|---|
| A precondição ignorava `pg_database_owner`, que o dono do banco temporário recebe: um GRANT OPTION para ele em outro banco passaria | sim | Ajustar: a precondição considera todos os papéis que o migrador exerce (ele, os herdados ou assumíveis por `SET`, `PUBLIC` e `pg_database_owner`) |
| Os poderes do migrador só eram conferidos pela guarda do próprio plano, que é editável: um migrador promovido a superusuário receberia os passos | sim | Ajustar: a conexão administrativa roda a guarda de papéis do gerador atual antes de qualquer plano, o executor confere a identidade e os atributos da sessão, e o catálogo inclui todos os papéis do servidor |
| Identificadores com escape Unicode (`U&"set\005fconfig"`) escondiam o nome da função | não | Ajustar: o filtro recusa `U&"..."` e `U&'...'`, que o gerador nunca emite |

**Rodada 5 — devolvida pelo Codex.** Os ajustes da rodada 4 foram confirmados.

| Achado do Codex | Bloqueia | Decisão do Claude |
|---|---|---|
| Um plano pode encerrar, com `pg_terminate_backend`, outra sessão do `vetra_migrator` em outro banco, sem privilégio e sem mudar catálogo | sim | Ajustar: o servidor com outra sessão do migrador aberta é recusado antes de criar o banco temporário. Uma sessão que entre durante a aplicação fica registrada como fora da garantia (efeito de disponibilidade, num servidor que já precisa ser descartável) |

**Rodada 6 — aprovada pelo Codex**, sem achados. O Codex considerou a troca da validação integral tecnicamente
aceitável para a K9: a regeneração do último plano, a história imutável contra a base e o limite de um plano novo
por integração sustentam a garantia da história integrada. Antes da integração, a proteção depende das precondições
do servidor descartável, do login restrito e do catálogo, com as exclusões declaradas no ADR-038. Suíte com 493
testes, 7.890 asserções e 186/186 diagnósticos. Sondas no PostgreSQL 18.6: plano incremental 18/18, contexto 58/58,
RLS 103/103 e `db:migrate` 21/21. ADR-038 aceito pelo Claude por delegação do mantenedor.

**Envio.** Commit `5fa7a3a` na `main`. A CI ([execução 42215134526](https://github.com/vetra-framework/vetra/actions/runs/42215134526)) passou nos cinco jobs. No job de planos, o PostgreSQL 17.11 e
o 18.6 deram plano incremental 18/18, contexto 58/58, RLS 103/103 e `db:migrate` 21/21, com o `--check` dos quatro
exemplos aplicado como `vetra_migrator`, que entrou com a senha própria do servidor descartável.

## Auditoria K8

Implementado pelo Claude sobre `8ab5f1b`; auditado pelo Codex; decisão do Claude. As sondas e a CLI conectada foram rodadas
pelo Claude no PostgreSQL 18.6; o 17 roda no job `db-plan` da CI.

**Rodada 1 — devolvida pelo Codex.**

| Achado do Codex | Bloqueia | Decisão do Claude |
|---|---|---|
| A deriva não via os privilégios do próprio banco, que o `pg_dump --schema-only` não inclui: um `GRANT CREATE ON DATABASE` dado depois à aplicação passaria | sim | Ajustar: privilégios do banco conferidos pelo catálogo, antes e depois de aplicar |
| A conferência de banco vazio era uma lista de catálogos e deixava passar uma collation, que só aparecia na deriva depois do commit, com a mensagem "Nada foi alterado" | sim | Ajustar: todo catálogo local com OID a partir de 16384 e o `public` com dono e ACL padrão; mensagem própria para a deriva depois do commit |
| A sonda podia esperar sem prazo e não limpar os bancos | não | Ajustar: prazos e `ensure` |
| O guia do `db:plan` dizia que o `db:migrate` não existia | não | Ajustar |

**Rodada 2 — devolvida pelo Codex.**

| Achado do Codex | Bloqueia | Decisão do Claude |
|---|---|---|
| Uma subscription do banco não era vista (catálogo compartilhado, fora do dump do migrador) | sim | Ajustar: conferida por `pg_subscription.subdbid` |
| Um large object com OID explícito baixo não era visto | sim | Ajustar: qualquer linha em `pg_largeobject_metadata` |

**Rodada 3 — devolvida pelo Codex.**

| Achado do Codex | Bloqueia | Decisão do Claude |
|---|---|---|
| Parâmetros por banco ou por papel no banco (`ALTER DATABASE/ROLE ... SET`), como `session_replication_role = replica`, que desliga a checagem das FKs, não eram vistos | sim | Ajustar: qualquer linha de `pg_db_role_setting` do banco |
| Rótulos de segurança em objetos do sistema não eram vistos | sim | Ajustar: `pg_seclabel` e `pg_shseclabel` do banco; a sonda não os cria, porque exigem provider |
| Publicações | não | Não ajustar o código: já eram vistas; caso acrescentado à sonda |
| Comentários em objetos do sistema | não | Não ajustar: não mudam execução nem permissões; limite documentado |

**Rodada 4 — aprovada pelo Codex**, com um ajuste de texto no plano da persistência, feito pelo Claude.

Verificado pelo Claude no PostgreSQL 18.6: sonda do `db:migrate` 21/21, sem banco nem configuração restante. Ela cobre
aplicação e registro do hash; segunda execução; registro inacessível à aplicação; segundo migrador; superusuário e
aplicação recusados; deriva de esquema, de privilégio do banco, de large object e de parâmetro por banco; plano alterado;
banco com tabela, collation, privilégio padrão, subscription, publicação, large object de OID baixo, parâmetro por banco
ou de papel no banco recusado sem aplicar nada; nova tentativa de `lock_timeout` que aplica; tentativas esgotadas com
retomada; e conexão derrubada no meio do plano com retomada. A CLI conectada como `vetra_migrator` aplica e, na segunda
vez, não acha nada pendente. Sondas de RLS 103/103 e do contexto 58/58; `--check` nos quatro exemplos. Suíte com 477
testes e 7.548 asserções, 179/179.

O commit `da3dda9` foi feito fora do protocolo durante a auditoria, com o estado da rodada 1 e mensagem fora do
formato; não foi reescrito, porque já estava publicado. O `5b15437` traz as correções das rodadas 2 a 4 e o registro da
auditoria. Na CI ([execução 42056786455](https://github.com/vetra-framework/vetra/actions/runs/42056786455)), a sonda do
`db:migrate` passou 21/21, a de RLS 103/103 e a do contexto 58/58 no PostgreSQL 17.11 e no 18.6, com o `--check` dos
quatro exemplos nos dois. Com a K8, a rodada 3 está concluída.

## Auditoria C7

Implementado pelo Codex sobre `f461cb0`; auditado pelo Claude; decisão do Claude. As sondas e os retratos foram rodados
pelo Claude no PostgreSQL 18.6; o 17 roda no job `db-plan` da CI.

**Rodada 1 — devolvida por um ajuste.** ADR-037 proposto: `ENABLE`/`FORCE` RLS em toda tabela com tenant e na raiz, uma
restritiva de tenant por `(SELECT vetra.current_tenant())` (pelo `id` na raiz), permissiva `true` nas entidades sem escopo
SQL e permissivas por ação nas que têm escopo; `db/policies/` como espelho conferido contra a IR e nunca aplicado à parte;
revisão do ADR-031 composta no plano sem transação aninhada; triggers de `transitions enforce: db` `SECURITY INVOKER`,
sem definer novo. Verificado: suíte com 470 testes, 172/172; sonda do contexto assinado 58/58; sonda ADR-031 59/59;
retratos regenerados e `--check` nos quatro exemplos; sonda nova de RLS e integridade 100/103.

| Achado do Claude | Bloqueia | Decisão do Claude |
|---|---|---|
| A sonda chamava `token('cmd' => ...)`, que no Ruby 4 vira argumento de palavra-chave (`ArgumentError`) e derrubava a mesma verificação nos três cenários | sim | Ajustar: hash explícito; com essa mudança numa cópia, 103/103 |
| As tabelas de vínculo têm permissiva `true` dentro do tenant, e uma sessão `vetra_app` com SQL arbitrário poderia criar o próprio vínculo | não | Não ajustar agora: o ADR-037 registra o limite e a situação do projeto o lista como pendência |

**Rodada 2 — aprovada.** No PostgreSQL 18.6, a sonda de RLS e integridade passou 103/103: acessos permitidos no tenant e
no escopo, recusas entre tenants (leitura, escrita, troca de tenant, raiz, FK para outro tenant), sem contexto e com
token inválido, revisão incrementada nas escritas permitidas e desfeita no rollback, e transições permitidas e recusadas,
inclusive `set_by`. A sonda do contexto assinado continua 58/58, e o `--check` passa nos quatro exemplos. O Claude aceitou
o ADR-037 por delegação do mantenedor e acertou nos docs o estado final.

Na CI ([execução 42038274235](https://github.com/vetra-framework/vetra/actions/runs/42038274235)), a sonda de RLS e
integridade passou 103/103 e a do contexto assinado 58/58 no PostgreSQL 17.11 e no 18.6, e o `--check` conferiu os
quatro retratos nos dois.

## Auditoria C6

Implementado pelo Codex sobre `07737ca`; auditado pelo Claude; decisão do Claude. O sandbox do Codex não alcança o
PostgreSQL: as sondas, o bootstrap e os retratos foram rodados pelo Claude no PostgreSQL 18.6; o 17 roda na CI.

**Rodada 1 — devolvida.** ADR-036 proposto: bootstrap dos papéis à parte e repetível, plano que só confere papéis,
`vetra_owner` dono dos objetos, `vetra_app` com DML, `USAGE` e as duas funções de contexto, token
`v1.kid.payload.mac` com HMAC-SHA256 verificado no banco, chaves em `vetra_private.keys` fora dos artefatos, e exceção
exata (assinatura, dono, atributos, configuração e hash do corpo) na guarda de rotinas da C2. Verificado: suíte com 454
testes, 167/167; bootstrap duas vezes; `--snapshot` e `--check` nos quatro exemplos; sonda ADR-031 59/59; a sonda nova
57/57 só numa cópia corrigida em `/tmp`.

| Achado do Claude | Bloqueia | Decisão do Claude |
|---|---|---|
| O plano inicial exigia superusuário para revogar `EXECUTE` dos membros do `pgcrypto`, o que o ADR-002 §3 e o ADR-005 não admitem e que serviços gerenciados não oferecem | sim | Ajustar: `pgcrypto` em `vetra_private`, onde a aplicação não tem `USAGE`, sem revogar os membros; o migrador, dono do banco, aplica o plano; a sonda aplica como `vetra_migrator` |
| A sonda não rodava: `base64` fora do Ruby 4, comparação de UTF-8 com binário e parâmetro de conexão vazio | sim | Ajustar |
| O custo do HMAC por instrução não foi medido (ADR-023) | não | Não ajustar: fica para a rodada de medições |

**Rodada 2 — aprovada.** Suíte com 457 testes e 6.122 asserções, 167/167; bootstrap repetível; a sonda do contexto
assinado passou 58/58, com o plano aplicado pelo `vetra_migrator` (dono do banco, sem superusuário, `CREATEDB` ou
`CREATEROLE`); sonda ADR-031 59/59; retratos regenerados pelo Claude com donos e `--check` nos quatro exemplos, sem
banco temporário restante. O Claude aceitou o ADR-036 por delegação do mantenedor e acertou nos docs o estado final.

Na CI ([execução 42030652797](https://github.com/vetra-framework/vetra/actions/runs/42030652797)), a sonda do contexto
assinado passou 58/58 no PostgreSQL 17.11 e no 18.6, e o `--check` conferiu os retratos com donos nos dois.

## Auditoria K7

Implementado pelo Claude sobre `e0ee3ad`; auditado pelo Codex; decisão do Claude. O sandbox do Codex não alcança o
PostgreSQL, então a aplicação real foi feita pelo Claude no PostgreSQL 18.6; o 17 roda no job `db-plan` da CI.

**Rodada 1 — devolvida pelo Codex.**

| Achado do Codex | Bloqueia | Decisão do Claude |
|---|---|---|
| Uma URL com senha mal codificada fazia a CLI imprimir a mensagem do driver com a senha | sim | Ajustar: erros de URL e conexão viram `db_connection` com classe e SQLSTATE |
| A normalização do retrato tirava linhas `--` e `SET` e espaços também dentro de literais e corpos de função, e dois esquemas diferentes davam o mesmo retrato | sim | Ajustar: `StatementScanner` acompanha literais, comentários de bloco e instruções abertas; a normalização só age entre instruções |
| `--snapshot` aplicava planos editados sem conferir a IR, e um `COMMENT ON DATABASE` chegaria ao servidor | sim | Ajustar: `--snapshot` só aplica planos que a IR gera, como o `--check` |
| A suíte falhava com os `db/` dos exemplos copiados pelos testes | sim | Ajustar: `with_app` remove `db/`, artefato gerado como `.vetra/` |
| Um default com uma linha `-- vetra:` era lido como marcador e o plano gerado era recusado | sim | Ajustar: o leitor do plano usa o mesmo scanner; marcadores só contam entre instruções |
| O formato só tem a transação única; `CREATE INDEX CONCURRENTLY` exigirá passos fora de transação | não | Não ajustar agora: registrado no guia como pré-requisito da rodada 4 |

**Rodada 2 — devolvida pelo Codex.**

| Achado do Codex | Bloqueia | Decisão do Claude |
|---|---|---|
| A normalização tirava o CR de `CRLF` dentro de literais, e `'a
b'` e `'a
b'` davam o mesmo retrato | sim | Ajustar: só o LF delimitador sai de cada linha |
| Um default com CR saía cru no plano, e o segundo `db:plan` recusava o próprio plano | sim | Ajustar: o gerador da C5 escreve caracteres de controle como escapes de E-string; os fixtures da C5 não mudaram |

**Rodada 3 — devolvida pelo Codex.**

| Achado do Codex | Bloqueia | Decisão do Claude |
|---|---|---|
| Um `PGSERVICE` herdado podia levar o `pg_dump` a outro servidor ou banco | sim | Ajustar: o `pg_dump` recebe em `--dbname` os parâmetros efetivos da conexão temporária e roda sem as variáveis `PG*` herdadas; a senha vai só em `PGPASSWORD` |

**Rodada 4 — devolvida pelo Codex.**

| Achado do Codex | Bloqueia | Decisão do Claude |
|---|---|---|
| `target_session_attrs` ficava de fora, e com vários hosts o `pg_dump` podia escolher outro servidor | sim | Ajustar: o servidor efetivo é fixado. Ao reproduzir, o Claude achou um defeito anterior: a conexão ao banco temporário reenviava a lista de hosts e falhava no servidor somente leitura; ela também fica fixa no servidor da conexão administrativa |
| `options` ficava de fora | sim | Ajustar: preservado, com teste do parse pela libpq |

**Rodada 5 — aprovada pelo Codex**, sem achados novos.

Verificado pelo Claude no PostgreSQL 18.6: `db:plan`, `--snapshot` e `--check` nos quatro exemplos, inclusive com
`PGSERVICE`, `PGDATABASE` e `PGHOST` herdados apontando para outro servidor, e com uma URL de dois servidores cujo
primeiro é somente leitura (`target_session_attrs=read-write` e `options`), sem banco temporário restante; a classificação
de lock de cada passo, aplicando os passos um a um com as tabelas já criadas (34 passos sobre tabelas existentes com o
lock declarado; os 13 `CREATE TABLE` só travam a tabela nova). Suíte com 447 testes e 4.804 asserções, 166/166.

Na CI ([execução 41902986720](https://github.com/vetra-framework/vetra/actions/runs/41902986720)), o `--check` passou nos
quatro exemplos no PostgreSQL 17 e no 18: o `pg_dump` 17 reproduz o retrato gerado no 18, o que também confirma no 17
o DDL da C5.

## Auditoria C5

Implementado pelo Codex sobre `131478b`; auditado pelo Claude; decisão do Claude.

**Rodada 1 — aprovada.** ADR-035 proposto e `Vetra::SQL::Schema`, função pura da IR para um modelo congelado e o
DDL de um banco vazio em três blocos (schemas, tabelas com chaves e índices, FKs), com fixtures dos quatro exemplos.
Suíte com 428 testes e 4.618 asserções, 154/154 diagnósticos; gate sem alterações nos grafos.

O Claude aplicou o DDL no PostgreSQL 18.6, um banco vazio por exemplo: 19/19 verificações. O SQL é igual aos
fixtures; os quatro exemplos criam 13 tabelas e 15 FKs numa transação, sem índice inválido, e uma segunda aplicação
falha (`42P07`). No mini CRM com revendas: lead com vendedor nulo é aceito e recebe UUID v4; revenda ou vendedor de
outro tenant é recusado (`23503`); `users` e `dealers` têm FK para a raiz mesmo sem `belongs_to`; `money` exige o
par, recusa `NaN` e moeda com mais casas que a escala (`23514`); `enum` e comprimento são conferidos; as FKs adiáveis
permitem inverter a ordem de inserção numa transação; excluir uma empresa com filhas é recusado. O PostgreSQL 17
entra na CI com a K7.

| Ponto | Bloqueia | Decisão do Claude |
|---|---|---|
| A coluna de moeda aceita qualquer código ISO cujo expoente cabe na escala, não só a moeda da aplicação | não | Não ajustar: o ADR-017 permite valores em outras moedas e deixa a moeda padrão para a entrada |
| `downcase` depende da collation do banco | não | Não ajustar: registrado no ADR-035; a implantação fixa a collation |

## Auditoria C4

Implementado pelo Codex sobre `6b371d3`; auditado pelo Claude; decisão do Claude.

**Rodada 1 — devolvida.** ADR-034 proposto, `rate_limit: "N/[J]unidade"` normalizado em `limit`, `window_seconds`
e `key: actor_tenant`, IR 0.6 com `vetra.rate_limit` só quando usado, schemas 0.1 a 0.5 intactos, diff que trata
afrouxar ou remover como quebra potencial. O blog reproduz a permissão do visitante da proposta. Suíte com 393
testes, 143/143, e gate sem quebra.

| Achado do Claude | Bloqueia | Decisão do Claude |
|---|---|---|
| A regra "todos os limites aplicáveis valem, mesmo com concessão sobreposta sem limite" faz uma permissão limitada reduzir o acesso já concedido por outra; no blog, o `admin` com `manage` em comentários ficaria a 5/min | sim | Ajustar: concessão sem limite admite sem consumir cotas; só quando todas as concessões são limitadas, todas precisam permitir e a admissão conta em todas |
| IDs das políticas dependem da ordem das declarações, e a continuidade das cotas entre builds fica para o runtime | não | Não ajustar: registrado como questão em aberto |

**Rodada 2 — aprovada.** A regra nova está no ADR, com a anterior entre as alternativas rejeitadas. Suíte com 393
testes e 4.307 asserções, 143/143; gate sem quebra; quatro exemplos em check, validação com fontes e link;
`git diff --check` limpo, sem mudança de modo. Os testes usam o exemplo do blog, por isso o formato e o exemplo vão
num só commit, como na C1. O Claude aceitou o ADR-034 por delegação do mantenedor.

## Auditoria K6

Implementado pelo Claude sobre `3221157`; auditado pelo Codex em modo somente leitura; decisão do Claude. A sonda
foi rodada pelo Claude no PostgreSQL 18.6 (31/31: 22 do ADR-015 e 9 do ADR-025); o 17 roda na CI. O 18 aceita
`NOT VALID` na chave estrangeira do pai particionado, o que, pela regra do ADR-025 §3, alinha essa versão ao padrão
das tabelas comuns ([relatório](sondas/adr015.md)).

**Rodada 1 — devolvida pelo Codex.**

| Achado do Codex | Bloqueia | Decisão do Claude |
|---|---|---|
| Uma falha depois do `VALIDATE` deixava a transação aberta e a remoção das tabelas esperando pelo lock; o bloco do `ENUM` podia deixar a sessão abortada | sim | Ajustar: fechar as sessões e desfazer a transação em `ensure`; conferido com uma falha provocada, sem sobra no banco |
| `DROP VALUE` responde `0A000` também no 17, não `42601` | não | Ajustar: exigir `0A000` e corrigir o relatório |
| As recusas aceitavam qualquer erro | não | Ajustar: `0A000` para `CONCURRENTLY` no pai e `42809` para a chave `NOT VALID` no pai antes do 18 |

**Rodada 2 — aprovada pelo Codex**, sem achados novos; suíte com 371 testes, 142/142, e gate repetidos por ele.

## Auditoria C3

Implementado pelo Codex sobre `ea03024`; auditado pelo Claude; decisão do Claude.

**Rodada 1 — devolvida.** ADR-033 proposto, IR 0.5 com `app.rounding` e `vetra.money_rounding`, tabela única de
recursos por versão em `Schema::VERSIONS`. Verificado: 371 testes, 3.414 asserções, 142/142; gate sem quebra;
quatro exemplos em check, validação com fontes e link.

| Achado do Claude | Bloqueia | Decisão do Claude |
|---|---|---|
| Todo build materializava `half_up` e exigia `vetra.money_rounding`, até no blog e no chat, sem `money`: todo consumidor teria de implementar arredondamento para ler qualquer grafo, ao contrário do padrão da C1 | sim | Ajustar: campo e requisito só quando a aplicação declara `rounding:` |
| Trocar o modo é quebra potencial mesmo sem campo `money` | não | Não ajustar: conservador e justificado no ADR |

**Rodada 2 — aprovada.** Só o mini CRM com revendas tem o campo e o requisito. Suíte com 371 testes e 3.482
asserções, 142/142; gate sem quebra; quatro exemplos passam; `git diff --check` limpo, sem mudança de modo. O
Claude aceitou o ADR-033 por delegação do mantenedor e tirou dos docs a narrativa de entrega sem commit.

## Auditoria C1

Implementado pelo Codex sobre `1aca944`; auditado pelo Claude; decisão do Claude.

**Rodada 1 — devolvida.** Suíte, exemplos e gate passavam (348 testes, 141/141 diagnósticos), mas a entrega
acrescentava o recurso `vetra.relation_commands` à IR 0.3 e alterava `docs/ir/v0.3.schema.json`. O ADR-001 (§4)
exige nova MENOR para recurso semântico novo e diz que schemas publicados são imutáveis; o schema 0.3 já tinha
saído na gem 0.1.0.pre.alpha.4, publicada no RubyGems em 2026-11-03 13:08 UTC (conferido pela API do RubyGems).

**Rodada 2 — aprovada.** O schema 0.3 voltou a ser idêntico ao de `HEAD`; a IR 0.4 é um schema novo, igual ao
0.3 exceto pela versão e pelo requisito novo; 0.1, 0.2 e 0.3 continuam aceitas com suas regras, e um documento
0.3 com o requisito ou a primitiva nova é recusado. Verificado pelo Claude: 351 testes e 2.906 asserções, sem
falhas; 141/141 diagnósticos; quatro exemplos em check, validação com fontes e link; gate contra `origin/main`
sem quebra, com a troca de `ir_version` para revisão nos quatro grafos; `git diff --check` limpo.

| Achado | Bloqueia | Decisão do Claude |
|---|---|---|
| Recurso novo dentro da IR 0.3 e schema publicado alterado | sim | Ajustar (feito na rodada 2) |
| A geração vem ligada por padrão, enquanto `crud` é opt-in | não | Não ajustar agora: segue a proposta e está registrado no ADR-032; decisão do mantenedor no aceite do ADR |
| Listas de versões repetidas em `schema.rb`, normalizador, validador e linker | não | Não ajustar agora: o padrão já existia; vale uma tabela de versões quando surgir a 0.5 |
| Nenhum exemplo exercita a geração (o chat usa `commands: false`) | não | Não ajustar: os 20 testes de `relation_commands_test.rb` cobrem a geração e as recusas |

## Auditoria C2

Implementado pelo Codex sobre `de84819`; auditado pelo Claude; decisão do Claude. O sandbox do Codex recusou
sockets Unix e TCP em loopback, então a sonda completa foi rodada pelo Claude, no PostgreSQL 18.6, contra o
gerador novo e contra o de `fb41921` (resto da árvore igual).

**Rodada 1 — devolvida.** Guarda antes da infraestrutura, com o critério de papéis da K5 para quem executa e
para o dono. Sonda 55/55; 33/55 contra `fb41921`.

| Achado do Claude | Bloqueia | Decisão do Claude |
|---|---|---|
| Cadeia de definers: `a()` de dono sem poder, executável por `PUBLIC`, chama `b()`, privada, cujo dono tem `TRUNCATE`; reproduzido no PostgreSQL 18 (tabela esvaziada) sem recusa | sim | Ajustar: fecho recursivo dos papéis alcançáveis por `EXECUTE` de definers |
| A recusa não exige `USAGE` no schema da rotina | não | Não ajustar: conservador; registrar no guia |

**Rodada 2 — devolvida.** Fecho com `UNION`, ciclos encerrados, recusa listando entradas, intermediárias e
rotinas perigosas. Sonda 58/58; 34/58 contra `fb41921`.

| Achado do Claude | Bloqueia | Decisão do Claude |
|---|---|---|
| `INSERT`, `UPDATE` e `DELETE` do dono contavam como poder perigoso, mas DML dispara os triggers `ALWAYS` e incrementa a revisão; erro de especificação do Claude na rodada 1, que recusaria funções de escrita comuns | sim | Ajustar: mesmo modelo de poderes da aplicação (`TRUNCATE`, `TRIGGER`, `REFERENCES`, propriedade, atributos, `ADMIN`, subscriptions, papéis de servidor) |
| A guarda rodava antes da infraestrutura e não conferia, nos donos alcançados, escrita nas revisões, `EXECUTE` nas funções novas e `CREATE` no schema, alcançáveis por privilégios padrão globais do instalador | sim | Ajustar: guarda depois dos `REVOKE`s, conferindo os privilégios efetivos |

**Rodada 3 — aprovada.** Sonda 59/59 no PostgreSQL 18.6, inclusive o `DELETE` por definer de dono só com DML
(revisão de 1 a 2) e as três recusas por privilégios padrão globais; 35/59 contra `fb41921`. Suíte com 355
testes e 2.984 asserções, sem falhas; 141/141 diagnósticos; gate sem alterações; `git diff --check` limpo; modo
`100755` da sonda preservado. O Claude enxugou nos docs a narrativa de rodadas e sandbox, deixando os números
finais. Limite que permanece, documentado no guia: rotinas, corpos e concessões alterados depois da instalação.

## Auditoria K5

Implementado pelo Claude sobre `58993e2`; auditado pelo Codex em modo somente leitura; decisão do Claude.

**Rodada 1 — devolvida pelo Codex.** A correção de `SET ROLE` estava certa (a semântica de `pg_has_role(...,
'SET')` inclui o próprio papel e cadeias), mas três caminhos anteriores contornavam a revisão do mesmo jeito.

| Achado do Codex | Bloqueia | Decisão do Claude |
|---|---|---|
| `GRANT SET ON PARAMETER session_replication_role` permite `replica`, que suprime os triggers | sim | Ajustar de outro modo: triggers `ENABLE ALWAYS`, que vale também para concessões feitas depois da instalação, em vez de só recusar quem tem o poder hoje |
| `REFERENCES` nas tabelas protegidas, inclusive por coluna, não era revogado nem conferido | sim | Ajustar: revogar e recusar, também em papéis assumíveis |
| `ADMIN OPTION` deixa a aplicação conceder a si um papel que hoje não pode assumir | sim | Ajustar: recusar `ADMIN OPTION` da aplicação ou de papel assumível sobre outro papel |
| A edição tirou o bit de execução de `script/sonda_adr031.rb` | não | Ajustar: modo `100755` restaurado |
| A suíte não rodou no sandbox somente leitura do auditor (276 erros de temporários) | não | Não ajustar o código; o Claude repete a suíte antes do envio |

**Rodada 2 — devolvida pelo Codex.** Os três caminhos da rodada 1 ficaram fechados; o Codex rodou a suíte e
conferiu que não alterou a árvore.

| Achado do Codex | Bloqueia | Decisão do Claude |
|---|---|---|
| Uma subscription criada pela aplicação (`pg_create_subscription`) escreve sem disparar triggers por instrução, mesmo `ALWAYS` | sim | Ajustar: recusar uso de `pg_create_subscription` e posse de subscriptions por papel que a aplicação usa |
| `MEMBER WITH ADMIN OPTION` atravessa vínculos `INHERIT FALSE, SET FALSE`: falso positivo com o `ADMIN` implícito de um criador `CREATEROLE` | sim | Ajustar: contar só o `ADMIN` de papéis que a aplicação assume ou herda (`pg_auth_members`), com o caso legítimo na sonda |
| `pg_restore --data-only --disable-triggers` volta os triggers de `ALWAYS` para a habilitação comum | não | Ajustar: documentar a conferência de `tgenabled` depois de um restore assim |
| Contagem da suíte desatualizada no resumo da situação | não | Ajustar no envio |

**Rodada 3 — devolvida pelo Codex.** O falso positivo do criador ficou corrigido; o Codex reproduziu no
PostgreSQL 18.6 dois desvios por cadeia mista e um poder de servidor.

| Achado do Codex | Bloqueia | Decisão do Claude |
|---|---|---|
| `app -SET-> ponte -INHERIT-> administrador`: o `ADMIN` do administrador é utilizável depois de `SET ROLE ponte`, e a consulta não o via (TRUNCATE com revisão parada) | sim | Ajustar: "utilizável" passa a ser o que herda algum papel assumível, não só a aplicação |
| Mesma cadeia com a posse de uma subscription existente | sim | Ajustar com o mesmo critério |
| `pg_execute_server_program` permitiu truncar o arquivo físico da tabela | sim | Ajustar: recusar os três papéis predefinidos de acesso a arquivos e programas do servidor |

**Rodada 4.** Sonda 29/29 no PostgreSQL 18.6, com os três cenários do Codex; contra o gerador de `61efbb8`, as
dez verificações que detectam os caminhos fechados falham (19/29). Suíte com 352 testes e 2.932 asserções.
PostgreSQL 17 só na CI: o WSL tem o cliente, não o servidor.

**Rodada 4 — aprovada com ajuste não bloqueante.** O Codex confirmou os três bloqueantes fechados, também em
cadeias `SET → SET → INHERIT → INHERIT`, sem falso positivo com `pg_read_all_data` ou `pg_monitor`, e repetiu a
suíte (352 testes, 0 falhas, 141/141).

| Achado do Codex | Bloqueia | Decisão do Claude |
|---|---|---|
| Função `SECURITY DEFINER` preexistente do proprietário, executável pela aplicação, faz `TRUNCATE` sem revisão | não | Ajustar documentando o limite no guia; a correção vira a tarefa C2 do Codex, por ser outra classe de problema |

## Auditoria K2: entregas do Codex de `cb7c0b5` a `61efbb8`

Verificado em 2026-11-03 sobre `61efbb8` (a primeira versão deste registro dizia `2d37e15` por engano; o
parecer do Codex apontou a divergência).

**Correção posterior:** o parecer do Codex achou uma lacuna que esta auditoria não viu. O gerador conferia só os
privilégios da aplicação, não os de papéis que ela pode assumir por `SET ROLE` com `INHERIT FALSE`; um
`TRUNCATE` obtido assim apaga vínculos sem incrementar a revisão. A K5 corrige.

**Aprovado.** Suíte com 328 testes e 2.532 asserções, sem falhas, e 137/137 códigos de diagnóstico; os quatro
exemplos passam em check, validação com fontes e link; o gate contra `2cb2700` não aponta quebra e lista para
revisão a IR 0.3, as consultas `my_rooms` e `room_page` e suas rotas; a gem 0.1.0.pre.alpha.5 é construída em
modo estrito. O gerador `db:authz:sql` valida todos os identificadores antes de interpolá-los, usa aspas nos
nomes e literais escapados, recusa papéis privilegiados e não gera SQL parcial.

**Pontos para o mantenedor:**

1. Os ADRs 028 a 031 foram marcados `aceito` pelo próprio agente, na integração. Pelo protocolo novo, o aceite é
   do mantenedor: confirme ou devolva cada um.
2. Os ADRs aceitos 008, 020 e 030 ganharam linhas de cabeçalho (`Evidência posterior`, `Implementação
   posterior`) que a convenção não previa. Não mudam decisões; a K3 as formaliza como referências permitidas.
3. A linha "PRs e commits locais" do resumo parava no PR #36; a K3 a atualiza.
4. A versão 0.1.0.pre.alpha.5 está commitada e não publicada; a alpha.4 publicada não tem os metadados novos.

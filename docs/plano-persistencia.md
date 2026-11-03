# Plano da persistência (rodada 3)

Este plano leva o Vetra do grafo a um banco PostgreSQL de verdade, criado por um plano versionado, com papéis
e RLS e aplicado por `db:migrate`. Os ADRs que a persistência usa estão aceitos: 002 (somente PostgreSQL 17+),
003 e 022 (Sequel e repositórios), 005 e 023 (papéis, RLS e contexto assinado), 015 e 025 (planos expand/contract,
retrato `db/schema.sql`, lotes e `lock_timeout`), 017 e 026 (`money`), 021 (campos de transição), 027
(`created_at`), 020, 030 e 031 (revisão de autorização). As tarefas e quem as faz estão no
[quadro dos agentes](tarefas-dos-agentes.md#rodada-3-2026-11-03). O Codex deu parecer sobre o rascunho
("de acordo com ressalvas"); as ressalvas estão incorporadas abaixo.

## Objetivo da rodada

Partindo de um banco vazio, cada exemplo deve:

1. gerar um primeiro plano em `db/plans/` e o retrato `db/schema.sql`, de forma determinística;
2. passar em `vetra db:plan --check` na CI, no PostgreSQL 17 e 18;
3. ser aplicado por `vetra db:migrate`, que recusa um banco divergente sem aplicar nada;
4. nos exemplos com tenant, isolar os tenants pelo RLS: com o papel `vetra_app`, uma sessão de um tenant lê e grava
   o que pode e não lê nem grava linhas de outro.

Ficam para a rodada 4: o plano incremental (mudar um modelo que já tem banco, com as fases expand, migrate e
contract, `CONCURRENTLY`, `NOT VALID` e lotes), os repositórios do Vetra Data sobre o Sequel, a outbox e o
`vetra.instances`.

## Lacuna de decisão

Nenhum ADR decide o mapeamento físico. A C5 propõe o ADR-035 para fechá-lo antes de qualquer DDL. Ele precisa
decidir:

- **Tipos:** o `id` (sequência ou UUID, qual versão, e quem gera), `string` (com o `max:` como `CHECK` de tamanho ou
  `varchar`), `text`, `email` (e a relação entre normalização e unicidade), `integer`, `decimal`, `boolean`, `date`,
  `timestamp` (com ou sem fuso) e `json` (`json` ou `jsonb`). `slug` é `string` com geração; `record` e `collection`
  são formas de contrato de saída, sem armazenamento.
- **Nulidade e defaults:** a nulidade vem de `nullable`, não de `required` (que trata da entrada); defaults
  literais e de contexto; `created_at` vem do relógio do repositório (ADR-027), não de um default do banco.
- **Nomes físicos:** nomes estáveis de tabela, coluna, índice e constraint, o limite de 63 bytes, colisões
  (inclusive com as colunas desdobradas de `money`) e índices parciais aceitos ou recusados.
- **Chaves estrangeiras:** ações de exclusão e atualização, nulos (o `seller` opcional do mini CRM com revendas
  precisa de FK composta que aceite vendedor nulo), adiamento, e a ordem de criação (tabelas e chaves únicas antes
  das FKs, o que resolve ciclos). Junções já são entidades; `has_many` não duplica a FK inversa.
- **Tenant:** a FK para a raiz também vale quando o tenant é implícito e não há `belongs_to` (`dealer` e `user` do
  mini CRM com revendas), e a raiz do tenant (`companies`, com `tenant` nulo na IR) se distingue de uma aplicação
  sem tenant e tem proteção explícita.
- **Campos de transição:** `set_by` e `guarded` mantêm suas colunas; com `transitions enforce: db` (os dois CRMs),
  exigem triggers (ADR-021), que entram na C7.

Já estão decididos o `enum` como `text` com `CHECK` (ADR-025, §6), o `money` como `numeric(precision, scale)` com
a coluna da moeda e o `CHECK` de par (ADR-017), as FKs compostas por tenant com o índice único de apoio (ADR-005,
§6, e ADR-025, §4) e os índices começando pelo tenant (ADR-005, §6).

## Incrementos

| Ordem | Tarefa | Quem | Depende de | Pronto quando |
|---|---|---|---|---|
| 1 | **C5** Mapeamento físico: ADR-035 proposto e uma função pura da IR para o modelo de esquema e para o DDL de um banco vazio | Codex | — | Testes sem banco cobrem os quatro exemplos e cada tipo; saída determinística; identificadores validados antes de interpolar |
| 2 | **K7** `vetra db:plan`: formato do plano em `db/plans/` (passos, fase, lock, custo e unidade transacional), o executor comum que aplica planos num banco descartável, o retrato `db/schema.sql` e o `db:plan --check` na CI | Claude | C5 | Os quatro exemplos têm plano e retrato commitados; `--check` falha com plano, retrato ou IR divergentes; CI verde no 17 e 18 |
| 3 | **C6** Papéis e contexto assinado: bootstrap de `vetra_app`, `vetra_migrator` e `vetra_owner`, schema `vetra_private`, funções do contexto (ADR-005 e ADR-023) e o provisionamento mínimo das chaves para teste, com segredos fora dos artefatos | Codex | K7 | Geração determinística; o Claude confere numa sonda tokens válidos, expirados e adulterados |
| 4 | **C7** RLS e integridade no banco: política restritiva de tenant e permissivas de escopo em `db/policies/`, a revisão de autorização do ADR-031 como passos do plano e os triggers de `transitions enforce: db` (ADR-021) | Codex | C6 | O Claude confere numa sonda acessos permitidos e recusados entre tenants, inclusive por FK, view e função, e as transições recusadas |
| 5 | **K8** `vetra db:migrate`: `vetra.migrations` com o hash de cada plano, lock consultivo mantido durante toda a execução, `lock_timeout` de 3 s com novas tentativas (ADR-025, §2), verificação prévia por introspecção e retomada | Claude | C7 | Sonda no 17 e 18: aplica do zero, retoma depois de uma interrupção, recusa deriva, plano alterado e um segundo migrador |

Só um agente implementa por vez, porque o checkout é compartilhado; por isso as tarefas seguem em sequência. As
que precisam de banco ficam com o Claude, porque o sandbox do Codex não alcança o PostgreSQL; nas do Codex, o
Claude roda as sondas na auditoria. Cada tarefa que acrescenta passos regenera o retrato, e o `--check` da K7 passa
a cobri-los.

## Riscos já identificados

- **C5:** gerar FKs só a partir de `belongs_to` deixaria de fora o tenant implícito (ver a lacuna acima).
- **K7:** o `pg_dump` muda entre o 17 e o 18. A normalização do retrato não pode esconder diferenças de dono,
  privilégios ou RLS. A tabela de locks do ADR-015, §3 não cobre a criação de tabelas, funções e triggers; a K7
  acrescenta essas classificações para o banco vazio.
- **C6:** a guarda de rotinas da C2 (`lib/vetra/sql/authorization.rb`) recusa funções `SECURITY DEFINER` executáveis
  pela aplicação cujo dono tem poder sobre as tabelas protegidas, e as funções de contexto do ADR-005 têm essa forma.
  A C6 decide como reconhecer as funções do próprio framework sem enfraquecer a guarda, por exemplo pela assinatura,
  pelo dono, pelo schema e pelo hash do corpo. Ela também decide qual schema cada parte usa.
- **C7:** o blog e o chat não têm tenant, e o `db:authz:sql` os recusa (ADR-031). Não se inventa tenant: neles não
  há política de tenant nem revisão, e essa limitação fica registrada. A sonda precisa provar também os acessos
  permitidos, para que o isolamento não passe só porque ninguém acessa nada.
- **K8:** a verificação prévia não pode comparar só com o retrato final, ou recusaria o banco vazio e uma retomada
  legítima. Ela reconhece a base e cada etapa concluída, confere o hash dos planos e registra o DDL e a conclusão de
  forma atômica. O SQL da revisão de autorização já traz `BEGIN` e `COMMIT`. Por isso, para compô-lo num plano, a
  unidade transacional precisa ser explícita.

## Regras para as tarefas

- O gerador de DDL valida todo identificador antes de interpolá-lo e usa aspas, como o `db:authz:sql`. Nenhum
  valor de dado entra no texto do SQL.
- Cada artefato gerado (`db/plans/`, `db/schema.sql`, `db/policies/`) é função de arquivos versionados e
  reproduzível na CI, como o `.vetra/graph.json`.
- Um recurso novo na IR segue o ADR-001, §4 (MENOR nova e `requires` só quando usado). A expectativa é que esta
  rodada não precise mudar a IR, porque o mapeamento é derivado do que ela já guarda. Se precisar, o ADR-035 diz
  por quê.
- O banco nasce vazio nesta rodada, então os padrões para tabelas com dados ficam para a rodada 4. O plano já
  registra fase, lock e custo, para que o formato não mude quando eles chegarem.

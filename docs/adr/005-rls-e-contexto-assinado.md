# ADR-005: RLS obrigatório com contexto assinado

- Status: proposto
- Data: 2026-10-30
- Depende de: ADR-016 (ciclo de vida da operação), ADR-002 (somente PostgreSQL)
- Dependem deste ADR: ADR-020 (entrega live incremental)

## Contexto

Em aplicações multiempresa, o isolamento entre tenants costuma depender de lembrar o escopo em cada consulta.
Um filtro esquecido vaza dados de outra empresa. O PostgreSQL oferece row-level security (RLS), que move a
barreira para o banco, mas o RLS só é tão forte quanto a forma de dizer ao banco **qual é o tenant** da
operação.

A abordagem comum é gravar o tenant numa variável de sessão (`SET app.tenant = '42'`) e fazer a política
ler essa variável. O problema: variáveis customizadas podem ser alteradas por qualquer SQL que rode na
conexão. Uma injeção de SQL, ou uma gem com acesso à conexão, troca o tenant com uma linha. Um sinalizador
"verificado" gravado na mesma sessão não resolve, porque também pode ser forjado.

A proposta técnica exige: papel de aplicação sem superusuário e sem `BYPASSRLS`, `FORCE ROW LEVEL SECURITY`,
políticas com `USING` e `WITH CHECK`, contexto assinado validado no banco, negação por padrão e testes com os
papéis de produção. Este ADR fecha o desenho, incluindo as questões que a proposta deixou abertas: formato,
emissão, validade e rotação da chave do contexto assinado.

## Decisão

### 1. Papéis do banco

| Papel | Pode | Não pode |
|---|---|---|
| `vetra_app` | `SELECT`, `INSERT`, `UPDATE`, `DELETE` nas tabelas da aplicação; executar `vetra.current_tenant()` e `vetra.current_actor()` | Ser dono de tabela; `BYPASSRLS`; superusuário; ler o schema `vetra_private`; criar objetos |
| `vetra_migrator` | Criar e alterar objetos (DDL); backfill de dados de tenant (tem `BYPASSRLS`) | Ser usado pela aplicação em runtime; a credencial existe só no pipeline de deploy |
| `vetra_owner` | Ser dono do schema `vetra_private` e das funções de validação | Fazer login |

- A aplicação em runtime conecta **sempre** como `vetra_app`. Desenvolvimento e teste usam os mesmos papéis,
  senão o RLS não é exercitado (`vetra new` cria os três).
- Toda tabela multiempresa tem `ENABLE` e `FORCE ROW LEVEL SECURITY`.

### 2. Contexto assinado

O contexto é um token assinado, emitido pela aplicação na etapa 4 do ADR-016 (abrir a unidade de trabalho) e
gravado na transação mais externa com `SET LOCAL vetra.ctx = '<token>'`.

**Formato** (texto compacto, três partes separadas por ponto):

```
v1.<kid>.<payload>.<mac>
```

- `kid`: identificador da chave que assinou (permite rotação).
- `payload`: JSON em base64url com `tenant_id`, `actor_id`, `op_id` (identificador da operação, também
  gravado na auditoria), `cmd` (nome do comando em execução, usado pelo reforço no banco dos campos de
  transição, ADR-021), `iat` e `exp` (segundos desde a época) e, se for operação de operador de plataforma,
  `operator_id`.
- `mac`: HMAC-SHA256 sobre `v1.<kid>.<payload>`.

**Validação no banco.** As políticas não leem a variável; chamam uma função:

```sql
CREATE POLICY tenant_isolation ON leads
  USING      (company_id = (SELECT vetra.current_tenant()))
  WITH CHECK (company_id = (SELECT vetra.current_tenant()));
```

`vetra.current_tenant()` é `STABLE`, `SECURITY DEFINER` e dona do `vetra_owner`, com
`SET search_path = pg_catalog, pg_temp` fixado para impedir sequestro por objetos de mesmo nome. A função:

1. Lê `current_setting('vetra.ctx', true)`; se estiver ausente ou vazia, devolve `NULL`.
2. Separa o token, procura o `kid` em `vetra_private.keys` e recusa chaves `revoked`.
3. Recalcula o HMAC com `pgcrypto` e compara em tempo constante.
4. Confere a validade: `iat - 5 s <= transaction_timestamp() <= exp`.
5. Devolve o `tenant_id` do payload, ou `NULL` em qualquer falha.

Comparar `company_id = NULL` nunca é verdadeiro, então **qualquer falha resulta em nenhuma linha visível**
(negação por padrão). Não há erro que revele por que o token foi recusado.

**Por que `(SELECT ...)`.** O PostgreSQL executa uma subconsulta não correlacionada uma vez por instrução
(InitPlan), em vez de uma vez por linha. O custo é um HMAC e uma leitura da tabela de chaves por **instrução**,
não por linha.

**O resultado validado nunca vai para uma variável de sessão.** A função revalida a cada instrução. Um
`SET vetra.ctx = ...` forjado por SQL injetado só funciona com um token assinado válido, que quem injeta não
consegue produzir sem a chave.

### 3. Emissão, validade e rotação da chave

- **Emissão.** A aplicação assina o token com a chave `active`, que vem de `config/secrets.enc`. A chave nunca
  é gravada em log, trace, mensagem de erro nem dump do banco da aplicação.
- **Validade.** `exp = iat + 30 s` por padrão (máximo configurável de 120 s). A validade é conferida contra o
  **início da transação** (`transaction_timestamp()`), não contra o relógio corrente. Uma transação longa não é
  cortada no meio; mas um token roubado não serve para abrir uma transação 30 segundos depois.
- **Relógios.** Aplicação e banco devem usar NTP. A tolerância de 5 s cobre a diferença normal; fora dela,
  as operações falham fechadas (nenhuma linha) e o `vetra doctor` acusa a divergência.
- **Armazenamento da chave no banco.** Tabela `vetra_private.keys (kid, secret, status, not_before)` no schema
  `vetra_private`, ao qual `vetra_app` não tem nenhum privilégio. Só a função `SECURITY DEFINER` lê. Estados:
  `active` (assina e valida), `verify_only` (só valida) e `revoked`.
- **Rotação normal.** A cada 90 dias (padrão): cria-se a nova chave como `active`; a anterior vira
  `verify_only` durante a validade máxima do token mais uma margem (5 minutos); depois é removida. Nenhuma
  operação em andamento falha por causa da rotação.
- **Rotação de emergência.** A chave comprometida vai direto para `revoked`: os tokens dela deixam de valer na
  próxima instrução, e as operações em curso falham fechadas (nenhuma linha) e são repetidas com a chave nova.
- **Quem rotaciona.** O comando `vetra keys:rotate`, rodado com o papel `vetra_migrator`. A aplicação em
  runtime nunca consegue escrever na tabela de chaves.

### 4. Regras do contexto na transação

- `SET LOCAL` só na transação mais externa, nunca dentro de um savepoint, pois seria desfeito no rollback do
  savepoint (ADR-016).
- Consulta multiempresa **fora de transação** é recusada pelo Vetra Data com erro explícito, nunca com
  resultado vazio. Leituras (consultas) também abrem uma transação, marcada como `READ ONLY`.
- O contexto não sobrevive ao fim da transação (efeito do `SET LOCAL`), o que é compatível com PgBouncer em
  modo de transação. A conexão volta ao pool sem contexto; isso é teste obrigatório. Medido atrás do PgBouncer
  1.26.1 em modo de transação, com um pool de uma conexão (`script/sonda_pooler.rb`): o contexto por
  `set_config(..., true)` não vazou para o cliente seguinte, e um `SET` de sessão **vazou**. O contexto precisa
  ser local à transação, e a emissão com `set_config` (e não `SET LOCAL`, que não aceita parâmetro) é o que o
  ADR-003 usa.
- A conexão `LISTEN` dedicada das consultas reativas não carrega contexto de tenant e não lê dados de tenant;
  só recebe identificadores (ADR-008).

### 5. O que o RLS garante e o que fica com a aplicação

- **RLS garante a fronteira de tenant** e, quando a entidade declara `scope:` expressível em SQL a partir de
  tabelas do próprio banco, também o escopo (por exemplo, a revenda do ator). As políticas de escopo são
  geradas e ficam em `db/policies/` como SQL revisável.
- **A aplicação avalia o resto** do RBAC contextual: campos visíveis, regras por estado, limites de taxa. O RLS
  é a última barreira, não a única.
- Toda tabela que define permissão (vínculos, papéis, escopos) tem um trigger que incrementa a revisão de
  autorização do tenant na mesma transação (pilar 4).

### 6. Demais requisitos de esquema

- **Views** com `security_invoker = true` (PostgreSQL 15 ou superior). Sem isso, rodam com os privilégios do
  dono e contornam o RLS. O gerador recusa criar view sem a opção.
- **FKs compostas** `(company_id, id)` nas relações entre entidades do mesmo tenant. A verificação de
  integridade referencial ignora o RLS e revelaria a existência de IDs de outro tenant; a FK composta evita o
  vazamento e garante `same_tenant`.
- **Índices** sempre começam por `company_id`, para que a política não degrade o plano.

### 7. Acesso entre tenants

Um operador da plataforma que precisa agir em outra empresa **age como aquele tenant**: o token é emitido com o
`tenant_id` alvo e o `operator_id` preenchido. O RLS continua ligado e vê **um tenant por vez**. A capacidade é
explícita e auditada: cada operação grava operador, tenant alvo e justificativa.

Relatórios consolidados sobre vários tenants não passam por este mecanismo; exigem um papel de banco e um
caminho de leitura próprios, a decidir em ADR separado.

## Alternativas rejeitadas

- **Isolamento só na aplicação** (escopo por convenção, `default_scope`): depende de disciplina em cada
  consulta e não protege contra SQL não confiável.
- **Tenant em variável de sessão, com ou sem sinalizador "verificado"**: qualquer SQL na conexão consegue
  alterá-la. O sinalizador pode ser forjado da mesma forma. Rejeitado também na rodada 7 da proposta.
- **Um schema ou um banco por tenant**: o isolamento seria mais forte, mas migrações, pools de conexão e
  consultas entre tenants ficam muito mais caros, e o Vetra mira muitos tenants pequenos.
- **Um papel de banco por tenant** (`SET ROLE`): não escala com milhares de tenants e depende de `SET ROLE`,
  que o mesmo código com acesso à conexão também chamaria.
- **Validar o token na aplicação e confiar no banco**: o banco passa a aceitar qualquer afirmação da aplicação,
  incluindo a de código comprometido que apenas reutiliza a conexão.
- **Mover a chave para variável de ambiente do servidor PostgreSQL ou arquivo**: não é viável em serviços
  gerenciados e dificulta a rotação.

## Consequências

- Cada instrução SQL sobre tabela multiempresa paga um HMAC e uma leitura de `vetra_private.keys`. O custo é
  uma hipótese; precisa ser medido já na fase 1, com RLS ligado e os papéis de produção.
- Há uma dependência de `pgcrypto` (disponível em serviços gerenciados comuns), de NTP nos servidores e de um
  procedimento operacional para a rotação.
- A função `SECURITY DEFINER` é código de segurança crítico e tem revisão obrigatória, testes de mutação e
  fica em `db/policies/`.
- O desenvolvimento local exige os três papéis no banco, o que torna o `vetra new` menos trivial que um
  `createdb`. O gerador cuida disso.
- Diagnóstico: um token expirado ou com chave revogada se manifesta como "nenhuma linha", não como erro.
  `vetra explain` e o `vetra doctor` precisam mostrar a causa a partir do lado da aplicação.

## Níveis de ameaça e garantia

| Ameaça | Proteção | Limite |
|---|---|---|
| Erro de programação (filtro esquecido) | RLS com negação por padrão; contexto validado a cada instrução | Depende de o contexto ser definido corretamente |
| SQL não confiável (injeção, gem) | Privilégio mínimo; token assinado que o atacante não consegue forjar | Um HMAC por instrução; a chave precisa ser bem guardada |
| Código comprometido no mesmo processo | Nenhum mecanismo do banco é suficiente | O código tem o que a aplicação tem, inclusive tokens válidos |

Isolamento entre empresas: **transacional** (RLS) e **verificável por testes**. A confidencialidade da chave é
**operacional**.

## Testes de aceitação

1. Sem token, a consulta devolve zero linhas; fora de transação, o Vetra Data recusa com erro.
2. Token com MAC adulterado, `kid` desconhecido, chave `revoked` ou expirado: zero linhas.
3. Token válido de um tenant não lê, não atualiza nem insere em outro (`USING` e `WITH CHECK`).
4. `SET vetra.ctx` com um tenant diferente e sem MAC válido: zero linhas.
5. Um `SET LOCAL` em savepoint revertido não deixa o contexto trocado nem perdido para o resto da transação.
6. A conexão devolvida ao pool não carrega contexto da operação anterior.
7. View sem `security_invoker` é recusada pelo gerador; um teste adversarial confirma o vazamento sem ela.
8. A FK composta recusa referência cruzada e não revela a existência de IDs de outro tenant.
9. Remover uma política ou cláusula RLS quebra algum teste (teste de mutação).
10. Rotação normal não derruba operação em andamento; rotação de emergência falha fechada.
11. O papel `vetra_app` não lê `vetra_private`, não é dono de tabela e não tem `BYPASSRLS`.
12. A suíte roda com PostgreSQL real e os mesmos papéis de produção.

## Questões que este ADR deixa para outros

- Custo medido do HMAC por instrução e da leitura da tabela de chaves: medição da fase 1.
- Modelo de escopos com vínculos múltiplos (usuário em várias unidades e empresas) e seu custo em política.
- Relatórios consolidados entre tenants: ADR separado.
- Permissões vindas de fora do banco (SSO) e como geram revisão de autorização: ADR-020.
- Versão mínima do PostgreSQL: este ADR já exige 15 ou superior (`security_invoker`); `xid8` pede 13 ou superior.

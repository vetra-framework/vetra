# ADR-023: Resolução das questões em aberto do ADR-005

- Status: proposto
- Data: 2026-10-31
- Resolve: ADR-005 (as cinco questões que ele deixa para outros)
- Depende de: ADR-005 (RLS e contexto assinado), ADR-002 (somente PostgreSQL), ADR-020 (revisão de autorização)
- Relacionados: ADR-015 (índices e políticas no plano de migração), ADR-016 (ciclo de vida da operação)

## Contexto

O ADR-005 foi aceito com cinco questões em "Questões que este ADR deixa para outros", e o índice pede tratá-las
antes de implementar a persistência. Este ADR não muda a decisão do ADR-005 (RLS com `FORCE`, isolamento de tenant
`RESTRICTIVE`, contexto assinado `v1` validado no banco a cada instrução, papéis `vetra_app`, `vetra_migrator` e
`vetra_owner`). Ele responde o que o ADR-005 deixou aberto, pela regra de resolução do índice.

| # | Questão | Tratamento |
|---|---|---|
| 1 | Custo do HMAC por instrução e da leitura da tabela de chaves | Medição, com resultado preliminar |
| 2 | Escopos com vínculos múltiplos e o custo em política | Decidida (modelo e forma da política), medição e adiada (autenticação) |
| 3 | Relatórios consolidados entre tenants | Adiada |
| 4 | Permissões vindas de fora do banco (SSO) | Já resolvida |
| 5 | Versão mínima do PostgreSQL | Já resolvida |

## Questões

### 1. Custo do HMAC por instrução e da leitura da tabela de chaves

- Tratamento: **medição**, com resultado preliminar.
- **Resultado preliminar** (à mão, sem sonda versionada; limites na seção "Verificação preliminar"). Um protótipo
  descartável da função `vetra.current_tenant()` do ADR-005 (`SECURITY DEFINER`, HMAC-SHA256 pelo `pgcrypto`,
  leitura da tabela de chaves, decodificação e validade) e da política `RESTRICTIVE`, medido com `pgbench` e o
  papel de aplicação sem `BYPASSRLS`, num cliente só, no PostgreSQL 16.15:

| Variante | Busca por chave (1 linha) | Varredura do tenant (4.000 linhas) |
|---|---|---|
| Sem RLS, com o filtro escrito à mão | 0,24 a 0,26 ms | 0,32 a 0,36 ms |
| RLS ingênuo (`current_setting`, sem assinatura) | 0,32 a 0,33 ms | 0,40 a 0,42 ms |
| **RLS com contexto assinado** (ADR-005) | **0,52 a 0,54 ms** | **0,62 a 0,63 ms** |

  A função sozinha custa cerca de 0,12 ms por chamada. A diferença do contexto assinado para o RLS ingênuo é de
  **cerca de 0,2 ms por instrução**, a mesma na busca por chave e na varredura de 4.000 linhas. Isso confirma o
  que o ADR-005 afirma (§2, "Por que `(SELECT ...)`"): o custo é por **instrução**, não por linha.
- **O que medir de verdade (fase 1).** O mesmo, com os papéis de produção (`vetra_app`), no PostgreSQL 17 e no 18
  (a matriz da CI), com 16 clientes simultâneos, atrás do pooler em modo de transação, incluindo `INSERT` e
  `UPDATE` com `WITH CHECK`, a comparação do MAC em tempo constante (o protótipo não a implementa) e os comandos de
  referência dos três exemplos, para contar quantas instruções sobre tabela multiempresa cada um emite.
- **Qual resultado decide o quê.** O custo é aceito se, na medição da fase 1, o acréscimo do contexto assinado
  sobre o RLS ingênuo ficar em **até 0,5 ms por instrução** (hipótese de limiar; o preliminar é 0,2 ms) **e** em
  até **25%** da latência mediana de cada comando de referência (hipótese). Se passar de qualquer um dos dois, o
  desenho do ADR-005 volta por ADR novo, com a alternativa medida. O ADR-005 proíbe guardar o resultado validado
  numa variável de sessão (§2), então a saída não é um cache nela.

### 2. Escopos com vínculos múltiplos e o custo em política

- Tratamento: **decidida** (o modelo e a forma da política), **medição** (o custo no ambiente de produção) e
  **adiada** (como a credencial escolhe a empresa).
- **Decisão 1: o contexto tem um tenant e um ator.** Uma pessoa com identidade em várias empresas recebe **um
  contexto por empresa**; trocar de empresa é outra operação, com outro contexto, nunca uma troca dentro da
  transação (ADR-016 já a proíbe). Num app com tenant, o usuário é por tenant (`tenant :company` na entidade `user`
  do exemplo do mini CRM), então a pessoa é um usuário por empresa. Como a credencial escolhe a empresa na
  autenticação **fica adiado**: é questão de um ADR de autenticação, que não existe, e o DSL recusa `auth` hoje. O
  gatilho é a decisão de implementar `auth`.
- **Decisão 2: um ator com vários vínculos dentro do tenant** (várias unidades) já é o caso que o escopo por vínculo
  expressa: uma linha de vínculo por unidade e papel. Não exige nada novo, e o custo **não depende do número de
  vínculos do ator** (1, 10 ou 100 vínculos: 1,94 a 2,17 ms numa varredura de 1.334 candidatas).
- **Decisão 3: a forma da política gerada.** A subconsulta de vínculo carrega o tenant e o ator como condições **não
  correlacionadas**, lidas do contexto, e correlaciona só a unidade de escopo:

```sql
CREATE POLICY escopo ON leads AS PERMISSIVE
  USING (EXISTS (SELECT 1 FROM memberships m
                  WHERE m.company_id = (SELECT vetra.current_tenant())
                    AND m.user_id    = (SELECT vetra.current_actor())
                    AND m.dealer_id  = leads.dealer_id
                    AND m.role       = 'vendedor'));
```

  Por quê, medido. Com a forma que correlaciona também o tenant (`m.company_id = leads.company_id`), o planejador
  escolheu um `hashed SubPlan` com **`Seq Scan` na tabela de vínculos inteira a cada instrução**, e o custo passou a
  crescer com o tamanho dela: uma varredura custou 2,7 a 3,1 ms com 10 mil vínculos e **16,7 a 19,7 ms com 200
  mil**. Com o tenant e o ator amarrados, o plano usa um `Index Only Scan` pelo prefixo `(company_id, user_id)` da
  chave e a mesma varredura custa **2,05 a 2,23 ms na tabela de 200 mil**, menos que os 2,7 a 3,1 ms da forma
  correlacionada na de 10 mil. Não medi a forma com o tenant amarrado na tabela de 10 mil: que o custo não cresce
  com a tabela vem do plano (índice pelo prefixo), e o teste de aceitação 2 o confere. O resultado visível é o mesmo
  (1, 10 e 100 vínculos: 40, 400 e 4.000 linhas nas duas formas): a restritiva do ADR-005 já limita a linha ao
  tenant do contexto, então `m.company_id` igual ao tenant e igual ao da linha selecionam o mesmo conjunto.
- **Decisão 4: o índice.** O gerador da tabela de vínculo garante um índice cuja ponta é `(company_id, user_id, ...)`.
  A chave `(company_id, user_id, <unidade>, role)` já serve, e o ADR-005 (§6) já exige que os índices comecem por
  `company_id`. O `db:plan` (ADR-015) acusa uma tabela de vínculo sem esse índice.
- **Alternativa rejeitada:** uma tabela materializada do escopo efetivo de cada ator. É mais um lugar para manter
  consistente com a revisão de autorização (ADR-020), e a medição acima não mostra necessidade. Volta por ADR novo se
  a medição da fase 1 mostrar que a política não basta.
- **Qual resultado decide o quê.** Na medição da questão 1, repetir a varredura com escopo por vínculo, com a
  tabela de vínculos em ordem de milhões de linhas. Se o acréscimo da política de escopo passar de **1 ms por
  instrução** (hipótese) sobre a mesma consulta com o contexto assinado, a tabela materializada acima é avaliada,
  por ADR novo.

### 3. Relatórios consolidados entre tenants

- Tratamento: **adiada**.
- O ADR-005, §7 já diz que um relatório sobre vários tenants não passa pelo mecanismo do operador de plataforma e
  exige um papel de banco e um caminho de leitura próprios. Enquanto não existir, **nenhum caminho do Vetra lê mais
  de um tenant**: a ausência é intencional, e o `operator_id` não serve a isso.
- **O que a faz voltar (gatilho):** o primeiro requisito real de um relatório entre empresas. Ele entra como ADR
  próprio, que define o papel de banco, o que ele lê e como é auditado.

### 4. Permissões vindas de fora do banco (SSO)

- Tratamento: **já resolvida**. O ADR-020, §8 as define: grupos e papéis do provedor são materializados em
  tabelas do banco por um comando (por exemplo, `sync_identity_memberships`), chamado no login e por webhook, e o
  trigger da tabela de permissão gera a revisão de autorização. Para o que não for materializável, existe
  `authz.touch!(tenant)` e uma idade máxima da assinatura (15 minutos, hipótese).

### 5. Versão mínima do PostgreSQL

- Tratamento: **já resolvida**. O ADR-002 fixa a versão mínima em 17. A questão já citava isso; os recursos do
  ADR-005 começam antes (`security_invoker` pede 15 ou superior; `xid8`, 13 ou superior).

## Consequências

- O ADR-005 passa a ter todas as questões tratadas. A única medição que decide algo é a do custo do contexto
  assinado (questão 1), com limiar; a da política de escopo (questão 2) a acompanha. Nenhuma bloqueia o desenho da
  persistência.
- O gerador de políticas (que ainda não existe) tem uma forma obrigatória para o escopo por vínculo, e a tabela de
  vínculo tem um índice obrigatório. O compilador do protótipo não gera SQL de política hoje, então nada nele muda.
- Uma consequência do modelo: quem tem identidade em várias empresas tem vários usuários, um por tenant. Reunir as
  identidades é assunto de autenticação.
- O custo do contexto assinado entra no orçamento de cada comando: a ordem de grandeza é 0,2 ms por instrução sobre
  tabela multiempresa, e um comando que emite muitas instruções paga mais.

## Garantia

| Garantia | Nível | Mecanismo |
|---|---|---|
| O custo da política de escopo não cresce com o tamanho da tabela de vínculos | Verificável por testes | Forma da política e índice `(company_id, user_id, ...)`; teste sobre o plano |
| A política de escopo seleciona as mesmas linhas com o tenant amarrado | Verificável por testes | Teste de equivalência contra a forma correlacionada |
| Um contexto tem um tenant e um ator | Estrutural | Formato do contexto (ADR-005); sem troca de tenant na operação (ADR-016) |
| O custo do contexto assinado fica dentro do limiar | Operacional | Medição da fase 1 |

Testes de aceitação das questões decididas:

1. A política de escopo por vínculo gerada tem o tenant e o ator como condições não correlacionadas, e correlaciona
   só a unidade de escopo.
2. Numa tabela de vínculos de 200 mil linhas, o plano da política de escopo não faz `Seq Scan` nela.
3. A política gerada e a forma correlacionada devolvem as mesmas linhas, para atores com 1, 10 e 100 vínculos.
4. O `db:plan` acusa uma tabela de vínculo sem índice que comece por `(company_id, user_id)`.
5. Uma pessoa com identidade em duas empresas recebe contextos distintos, e uma operação não troca de tenant.
6. A medição da fase 1 (questões 1 e 2) roda na CI, no PostgreSQL 17 e 18, com os papéis de produção, e falha se
   passar dos limiares.

## Verificação preliminar

Conferido à mão, **sem sonda versionada**, num banco descartável do PostgreSQL 16.15 (o ambiente não tinha o 17 nem
o 18), em um sandbox de 4 CPUs, um cliente por vez, conexão local por TCP, tabelas de 200 mil linhas (o tenant medido
tem 4.000), duas execuções de 6 segundos por variante, com o papel de aplicação sem `BYPASSRLS` e `FORCE ROW LEVEL
SECURITY`:

- Antes de medir, a isolação foi conferida: sem contexto, nenhuma linha; com o token válido, as 4.000 linhas do
  tenant; com o último caractere do MAC alterado, nenhuma.
- Questão 1: `BEGIN; SELECT 1; COMMIT` custa 0,18 a 0,19 ms; com `set_config`, 0,25 a 0,26 ms; com
  `vetra.current_tenant()`, 0,37 ms. A tabela da questão 1 tem as demais variantes.
- Questão 2, política original (correlacionada): com 10 mil vínculos, 2,66 a 3,10 ms (1 vínculo), 2,76 a 2,86 ms (10)
  e 2,87 a 2,93 ms (100); com 200 mil vínculos, 16,7 a 19,7 ms. Política com o tenant amarrado: 1,94 a 2,17 ms com 1,
  10 e 100 vínculos, na tabela de 200 mil. Busca por chave com escopo: 0,66 a 0,70 ms (10 mil vínculos) e 0,78 a
  0,88 ms (200 mil, tenant amarrado), contra 0,52 a 0,54 ms só com o contexto assinado.

**O que isto não cobre.** O protótipo não compara o MAC em tempo constante, não tem `WITH CHECK` medido nem
concorrência, não passa por pooler, roda num sandbox compartilhado e não é o PostgreSQL 17 nem o 18. Os números são
ordens de grandeza para fixar limiares, não resultado de gate. Nada foi criado como código ou teste no repositório:
o banco, os papéis e os scripts do `pgbench` eram descartáveis e foram removidos.

# ADR-041: Forma da política de escopo por vínculo

- Status: aceito
- Aceite: 2026-11-10, pelo Claude por delegação do mantenedor, após a auditoria da K14 (aprovada na rodada 2), com a sonda do escopo em 4/4 no PostgreSQL 17.11 e 18.6.
- Data: 2026-11-09
- Depende de: ADR-005, ADR-023, ADR-024, ADR-037 e ADR-038
- Substitui em parte: ADR-023 (questão 2, decisão 3), só na **forma do SQL**; as demais decisões do ADR-023 valem
- Evidência: [medição da K14](../sondas/escopo-por-acao.md)

## Contexto

O ADR-023 fixou, na questão 2, a política de escopo por vínculo como um `EXISTS` correlacionado só pela unidade,
com o tenant e o ator lidos do contexto, e pôs uma hipótese de 1 ms por instrução de acréscimo. A medição da K13
cobriu só a leitura e achou de 0,8 a 2,8 ms com 1 milhão de vínculos; a forma com a lista do ator calculada uma vez
ficou em torno do limiar. O ADR-023 também deixou a tabela materializada do escopo efetivo para um ADR novo, caso a
política não bastasse.

A K14 mede o que faltava: a escrita por ação (`INSERT`, `UPDATE` e `DELETE`), com 1 milhão de vínculos, e compara as
permissões que cada forma concede. Este ADR decide a forma com esses números.

## Decisão

### 1. A forma: a lista de unidades do ator, lida uma vez por instrução

A política de escopo por vínculo passa a testar a unidade da linha contra a lista de unidades do ator:

```sql
CREATE POLICY vt_scope_read ON leads AS PERMISSIVE FOR SELECT TO vetra_app
  USING (leads.dealer_id = ANY (ARRAY(
    SELECT m.dealer_id FROM memberships AS m
     WHERE m.company_id = (SELECT vetra.current_tenant())
       AND m.role IN ('gerente', 'vendedor')
       AND m.user_id = (SELECT vetra.current_actor()))));
```

Nada é correlacionado com a linha além da unidade. O planejador avalia a lista como um `InitPlan`, uma vez por
instrução, e o índice do vínculo (prefixo tenant e ator, ADR-023, decisão 4) continua sendo o caminho de acesso.

### 2. Quando a forma lista vale, e quando o `EXISTS` continua

A forma lista só é gerada quando **todas** as condições valem; fora delas o gerador mantém o `EXISTS` do ADR-023:

1. **Posição positiva.** Nenhum `NOT` acima do predicado. `unidade = ANY (lista)` é `NULL`, e não `false`, quando a
   unidade da linha é nula ou a lista tem `NULL`; sob a negação a diferença muda o resultado.
2. **Um vínculo e uma coluna de correlação.** A relação reduz a um único `belongs_to`/`has_many` e correlaciona uma
   só coluna além do tenant. Uma FK composta continua `EXISTS`.
3. **Predicado preso ao ator em todos os ramos.** Cada ramo do predicado do vínculo traz a igualdade de um campo com
   `actor.id`, e esse campo não é a coluna do tenant (com tenant e ator iguais, ela selecionaria todos os vínculos do tenant). Assim a lista tem o tamanho dos vínculos do ator, e não o da tabela de destino: um `belongs_to` para
   uma tabela grande sem filtro por ator continua `EXISTS`, em vez de materializar milhões de linhas num array.

Dentro do `WHERE` da lista, `NULL` e `false` excluem a linha do mesmo jeito, então a polaridade recomeça positiva.

### 3. O OR das concessões é normalizado antes de gerar o SQL

As permissivas são por ação (ADR-037): o OR dos predicados das concessões da ação. O gerador normaliza esse OR com
equivalências **exatas** da lógica de três valores, e a mesma normalização vale para qualquer `or` do predicado:

- `EXISTS(p1) OR EXISTS(p2)` sobre a mesma relação vira `EXISTS(p1 OR p2)`;
- `(A AND B1) OR (A AND B2)` vira `A AND (B1 OR B2)`, e `A OR (A AND B)` vira `A`;
- `campo = a OR campo = b` vira `campo IN (a, b)`, só com literais não nulos (a igualdade com `NULL` usa
  `IS NOT DISTINCT FROM` e fica de fora).

Com isso, gerente e vendedor do CRM com revendas deixam de ser duas subconsultas e viram uma lista com
`role IN ('gerente', 'vendedor')`, e a referência ao ator aparece uma vez. Cada referência a
`vetra.current_tenant()` ou `vetra.current_actor()` revalida o token (ADR-024, §4) e custa de 0,2 a 0,3 ms, então
reduzir as referências é parte do ganho.

Uma concessão fora do subconjunto SQL continua virando `true` sob a restritiva, com a nota no espelho, **por
concessão**: ela não entra na normalização e não arrasta as outras.

### 4. O que não muda

- O isolamento de tenant continua uma política `RESTRICTIVE` separada (ADR-005). A forma lista só troca o corpo das
  permissivas de escopo.
- Ausência de concessão da ação continua negando a ação; `UPDATE` confere `USING` e `WITH CHECK`; `INSERT` só tem
  `WITH CHECK`; `DELETE` só `USING`.
- O subconjunto do predicado, a verificação do índice do vínculo e a recusa de ciclos de políticas (ADR-037) não
  mudam. Só o aplicativo `mini_crm_revendas` tem escopo por vínculo nos exemplos: o `mini_crm`, o blog e o chat não
  mudam de plano.
- As **permissões** são as mesmas: a medição compara, por ação e por ator, o conjunto de IDs que cada forma
  concede, contra a política real do plano.

## Medição

PostgreSQL 17.11 e 18.6, 16 clientes em processos próprios, 3 rodadas alternadas de 1,5 s por série, 1 milhão de
vínculos, custo por instrução = (mediana de 11 instruções − mediana de 1) / 10. Acréscimo sobre o controle com só o
tenant, em ms, faixa entre os atores medidos (mediana das rodadas de cada ator). Os relatórios completos, com as
rodadas e a matriz de atores, estão em [escopo-por-acao.md](../sondas/escopo-por-acao.md).

| Ação | Gerada hoje, PG 18 | Lista, PG 18 | Gerada hoje, PG 17 | Lista, PG 17 |
|---|---|---|---|---|
| `SELECT` por chave | +0,81 a +1,25 | +0,55 a +0,92 | +1,09 a +1,32 | +0,46 a +0,83 |
| `SELECT` varredura do tenant | +1,47 a +1,67 | +0,23 a +0,53 | +1,47 a +1,90 | +0,20 a +1,15 |
| `INSERT` | +0,73 a +1,80 | +0,51 a +0,74 | +0,71 a +1,47 | +0,58 a +0,67 |
| `UPDATE` por chave | +1,86 a +2,74 | +1,58 a +1,62 | +1,63 a +2,22 | +0,84 a +1,14 |
| `DELETE` por chave | +1,74 a +1,89 | +1,41 a +1,62 | +1,46 a +1,47 | +1,10 a +1,14 |

Com um ator de **1.000 unidades** (só leitura), a lista fica em +0,70 (chave) e +0,81 (varredura) no 18, e +1,08 e
+1,61 no 17, contra +1,40 e +1,99 no 18 e +2,29 e +2,83 no 17 da forma gerada hoje.

## Alternativas rejeitadas

| Alternativa | Por que não |
|---|---|
| `EXISTS` correlacionado, como hoje | Nunca é a melhor forma nos dados medidos: a lista é menor em todas as células, de 0,03 a 1,55 ms |
| `unidade IN (SELECT ...)` | Empata com a lista nas escritas, dentro da dispersão das rodadas, e perde nas leituras (varredura de +0,82 a +1,19 contra +0,23 a +0,53 no 18); com 1.000 unidades não escala melhor que a lista (+0,97 e +1,78 no 18; +1,64 e +3,14 no 17), o que derruba a hipótese de que o hash ganharia em listas grandes |
| Um `EXISTS` único com `role IN (...)` | Só fusiona as concessões; o custo fica próximo da forma gerada |
| Tabela materializada do escopo efetivo | Ganha de 0,1 a 0,8 ms sobre a lista nas operações por chave (menos no `UPDATE` do vendedor de 10 unidades no 17, onde perde por 0,25 ms), mas perde nas varreduras (+0,79 a +1,37) e exige manter uma tabela derivada consistente com a revisão de autorização (ADR-020); a diferença não paga essa manutenção |
| Duas chamadas de contexto extras | É só calibração: mede o custo de cada referência (de 0,2 a 0,3 ms), que explica boa parte do acréscimo |

## Consequências

- **O limiar de 1 ms por instrução do ADR-023 continua não cumprido em `UPDATE` e `DELETE`.** A forma lista fica
  de +0,84 a +1,62 nessas ações: acima de 1 ms em quase todas as células (a exceção é o `UPDATE` do vendedor de 10
  unidades no 17, com +0,84) e, no 17, também em uma varredura de gerente de 100 unidades (+1,15). O piso
  vem das referências ao contexto: dobram no `UPDATE` (`USING` e `WITH CHECK`), e nenhuma forma de escopo as elimina.
  Baixar esse piso é outra decisão, sobre a função de contexto (uma função única, ou uma validação mais barata,
  ADR-024, §4), e **não** cabe aqui. O gatilho é a medição por comando da K20; o teste de aceitação 6 do ADR-023
  continua pendente e só o mantenedor muda o seu contrato.
- O plano de troca atômica das políticas (C9) entra no `mini_crm_revendas` como `0004_expand`; é o único plano novo
  desse aplicativo nesta integração. A K15 (ator de sistema) acrescenta a sua condição às mesmas políticas num plano
  seguinte.
- Listas muito maiores que as medidas (1.000 unidades por ator) não foram medidas. Espera-se que a forma lista
  só se torne ruim em listas bem maiores, mas isso não foi medido; se o uso real as produzir, o gatilho é o `EXPLAIN`
  da política e um ADR novo.
- A normalização do OR vale para todo predicado `or`, não só para o escopo por vínculo; nenhum exemplo atual muda de
  SQL por isso fora do `mini_crm_revendas`.

## Testes de aceitação

1. O plano do `mini_crm_revendas` tem a forma lista nas quatro ações, com uma subconsulta por ação e uma referência
   ao ator, e o `mini_crm`, o blog e o chat não mudam de plano.
2. `NOT` sobre o vínculo e vínculo sem igualdade com o ator mantêm o `EXISTS` (teste do gerador).
3. A normalização do OR funde as concessões da mesma relação, fatora o termo comum e junta igualdades, e deixa de fora
   o `NULL` literal (teste do gerador).
4. A sonda confere, por ação e por ator (gerente de 1, 10, 100 e 1.000 unidades, vendedor de 10, papéis mistos e sem
   vínculos), que a política real do plano e cada forma concedem o mesmo conjunto de IDs e o mesmo que uma
   expectativa independente, nas quatro ações e, no `UPDATE`, também na mudança de unidade (origem pelo `USING`, destino
   pelo `WITH CHECK`), e que o plano não varre a tabela de vínculos inteira com 1, 10 e 100 unidades.
5. `db:plan --check` confere o plano e o retrato no PostgreSQL 17 e no 18, e a sonda de RLS passa nos dois.

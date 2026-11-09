# Custo do contexto assinado e da construção dos registros: medição preliminar e informativa (K13)

Medição da questão 1 e da questão 2 do [ADR-023](../adr/023-resolucao-das-questoes-do-adr-005.md) e do gate do
[ADR-022, §3](../adr/022-resolucao-das-questoes-do-adr-003.md), pela sonda `script/sonda_custo_contexto.rb`, no
PostgreSQL 17.11 e no 18.6, em 2026-11-09.

**O que esta medição é e não é.** É preliminar e **informativa**: fixa ordens de grandeza e aponta o que precisa de
ADR novo. Ela **não cumpre o teste de aceitação 6 do ADR-023**, que exige uma medição na CI que falhe acima dos
limiares: a sonda só falha nas conferências funcionais (isolamento, equivalência das formas, plano, papéis) e relata
os limiares como dentro, inconclusivo ou acima. O gate do teste 6 continua pendente. O gate por comando (25% da
latência do comando) só existe com o executor da rodada 5.

## Como foi medido

- **Banco e papéis.** Cada exemplo é aplicado pelo `db:migrate` como `vetra_migrator`, com os planos versionados. Os
  dados são carregados como superusuário, com o comando no contexto onde o trigger de transição exige. Toda medição
  roda como `vetra_app`, o papel de produção, sem `BYPASSRLS`.
- **Carga.** 16 clientes simultâneos, cada um num processo próprio com a sua conexão, porque threads do mesmo processo
  Ruby disputariam o GVL e a latência mediria o cliente. Cada série dura 3 s depois de 0,5 s de aquecimento; um
  cliente que falha na preparação derruba a série com erro, sem travar. A estatística é a mediana da latência da
  transação.
- **Custo por instrução.** Cada transação abre, instala o contexto da variante (`set_config`) e emite 1 ou 11 vezes a
  mesma instrução. O custo por instrução é a diferença entre as medianas das duas séries, dividida por 10. Isso só
  cancela o `BEGIN`, o `set_config` e o `COMMIT` **se** o custo for aditivo e estável; com 16 clientes em laço fechado,
  a taxa de transações e a contenção mudam entre as séries. Por isso há **3 rodadas**, com a ordem das duas séries
  alternada e a ordem das variantes girada a cada rodada, e o relatório mostra a mediana e o intervalo das rodadas.
  Nas instruções que escrevem, cada série parte da tabela limpa (as linhas inseridas são apagadas e há `VACUUM
  ANALYZE`). A sonda também imprime as latências brutas e o número de amostras de cada série.
- **Questão 1.** Três cópias da tabela `leads` do mini CRM, com os mesmos dados (50 tenants de 4.000 linhas) e índices,
  sem os triggers de transição: sem RLS com o filtro à mão, com RLS ingênuo (`current_setting`) e com a forma da
  política do plano, com `vetra.current_tenant()`, que valida o token com a chave e compara o MAC em tempo constante. A
  diferença entre a segunda e a terceira é só a função de contexto. Antes de medir, a sonda confere o isolamento: sem
  contexto, nenhuma linha; com o token, as 4.000 do tenant; com o último caractere do MAC alterado, nenhuma.
- **Questão 2.** O CRM com revendas, com 200 tenants, 40.000 revendas e **1.000.127 vínculos**. No tenant medido há
  seis atores: gerentes de 1, 10 e 100 revendas, um vendedor de 10, um de papéis mistos (gerente em três revendas e
  vendedor em outras três, com uma delas em comum) e um sem vínculos. Os 4.000 leads ficam nas 100 primeiras revendas.
  Os seis entram na conferência funcional; as séries temporizadas cobrem os gerentes e o vendedor, e **o ator misto e o
  sem vínculos não são temporizados**.
  A leitura com a política de escopo gerada pelo plano é comparada a um **controle** que só tem a política de tenant e
  a uma **forma alternativa** que calcula uma vez por instrução a lista de revendas do ator, com a mesma semântica da
  política de leitura gerada (gerente **ou** vendedor da revenda do lead). A sonda confere, por **conjunto de IDs** e
  não por contagem, que a forma alternativa devolve exatamente os leads da gerada para os seis atores, e que o plano
  das duas formas não varre a tabela de vínculos, com 1, 10 e 100 revendas. O controle não é uma terceira forma
  equivalente: ele devolve os 4.000 leads do tenant e serve só como linha de base de custo.
- **Gate do ADR-022.** 10.000 leads por `repository.all`, em uma unidade de leitura, contra a mesma consulta pelo
  Sequel sem construir os registros, mediana de 7 execuções. É uma **aproximação** do cenário do ADR: o lead do CRM com
  revendas tem 9 campos lógicos e 10 colunas físicas, não 10 campos.

## Resultados

### Questão 1: contexto assinado sobre RLS ingênuo (ms por instrução; mediana de 3 rodadas, mínimo a máximo)

PostgreSQL 18.6:

| Instrução | Sem RLS | RLS ingênuo | Contexto assinado | Acréscimo assinado − ingênuo |
|---|---|---|---|---|
| Busca por chave | 0,291 (0,229 a 0,315) | 0,308 (0,272 a 0,327) | 0,648 (0,524 a 0,828) | +0,322 (+0,252 a +0,520) |
| Varredura do tenant (4.000 linhas) | 1,144 (1,076 a 1,518) | 1,137 (1,102 a 1,328) | 1,550 (1,337 a 1,567) | +0,222 (+0,200 a +0,465) |
| `UPDATE` com `WITH CHECK` | 0,328 (0,286 a 0,689) | 0,425 (0,307 a 0,623) | 0,792 (0,684 a 1,351) | +0,376 (+0,367 a +0,728) |
| `INSERT` com `WITH CHECK` | 0,481 (0,468 a 0,772) | 0,783 (0,655 a 1,121) | 1,396 (0,877 a 1,429) | +0,308 (+0,222 a +0,613) |

PostgreSQL 17.11:

| Instrução | Sem RLS | RLS ingênuo | Contexto assinado | Acréscimo assinado − ingênuo |
|---|---|---|---|---|
| Busca por chave | 0,175 (0,164 a 0,189) | 0,191 (0,185 a 0,204) | 0,363 (0,346 a 0,376) | +0,172 (+0,160 a +0,172) |
| Varredura do tenant (4.000 linhas) | 0,700 (0,665 a 0,748) | 0,704 (0,678 a 0,708) | 0,904 (0,881 a 0,996) | +0,226 (+0,177 a +0,288) |
| `UPDATE` com `WITH CHECK` | 0,396 (0,375 a 0,399) | 0,387 (0,384 a 0,409) | 0,728 (0,693 a 0,788) | +0,319 (+0,306 a +0,404) |
| `INSERT` com `WITH CHECK` | 0,362 (0,334 a 0,431) | 0,388 (0,378 a 0,399) | 0,597 (0,567 a 0,614) | +0,198 (+0,179 a +0,236) |

Sobre todas as instruções e rodadas, o acréscimo do contexto assinado tem **mediana de 0,212 ms no 17** (de 0,160 a
0,404 ms: dentro do limiar de 0,5 ms em todas as rodadas) e **mediana de 0,344 ms no 18** (de 0,200 a 0,728 ms: a
mediana está dentro, mas **três das doze estimativas** passam do limiar: a busca por chave (+0,520), o `UPDATE`
(+0,728) e o `INSERT` (+0,613), então o veredito no 18 é **inconclusivo**). A dispersão entre rodadas é maior no 18,
onde a medição foi mais ruidosa, e uma rodada anterior com um método mais curto já tinha dado um acréscimo de
0,487 ms no `UPDATE` do 17. A conclusão é por **ordem de grandeza**: o acréscimo
por instrução fica de 0,2 a 0,4 ms na maior parte das rodadas, abaixo do limiar, sem folga que permita afirmar mais. O
custo é por instrução e não por linha, como o ADR-023 previa: na varredura de 4.000 linhas o acréscimo não cresce.
No 18 nenhum acréscimo da questão 1 ficou abaixo de +0,2 ms nas doze estimativas; o menor valor negativo do relatório,
−0,560 ms, é da questão 2 (lista do ator do vendedor), e é ruído de medição.

### Questão 2: política de escopo com 1 milhão de vínculos (ms por instrução; mediana de 3 rodadas, mínimo a máximo)

Só **leitura** (`SELECT count(*)`); a forma alternativa não tem política de escrita, e os resultados não dizem nada
sobre `INSERT`, `UPDATE` ou `DELETE` com escopo.

PostgreSQL 18.6:

| Ator | Linhas | Controle, só o tenant | Política gerada | Acréscimo da gerada | Lista do ator | Acréscimo da lista |
|---|---|---|---|---|---|---|
| Gerente de 1 | 40 | 1,115 (0,990 a 1,319) | 3,627 (3,339 a 3,788) | +2,308 (+2,224 a +2,798) | 1,491 (1,399 a 1,544) | +0,283 (+0,225 a +0,501) |
| Gerente de 10 | 400 | 1,186 (1,125 a 1,294) | 3,707 (3,598 a 4,139) | +2,521 (+2,473 a +2,845) | 1,644 (1,466 a 1,677) | +0,382 (+0,341 a +0,458) |
| Gerente de 100 | 4.000 | 1,154 (1,105 a 1,331) | 3,451 (3,379 a 3,537) | +2,225 (+2,206 a +2,345) | 2,203 (1,934 a 2,912) | +1,098 (+0,603 a +1,758) |
| Vendedor de 10 | 400 | 0,666 (0,648 a 1,321) | 2,146 (1,980 a 2,163) | +1,331 (+0,826 a +1,496) | 0,784 (0,760 a 0,882) | +0,136 (−0,560 a +0,215) |

PostgreSQL 17.11:

| Ator | Linhas | Controle, só o tenant | Política gerada | Acréscimo da gerada | Lista do ator | Acréscimo da lista |
|---|---|---|---|---|---|---|
| Gerente de 1 | 40 | 0,691 (0,630 a 0,706) | 2,054 (1,983 a 2,206) | +1,348 (+1,292 a +1,576) | 0,796 (0,784 a 0,832) | +0,126 (+0,105 a +0,154) |
| Gerente de 10 | 400 | 0,729 (0,700 a 0,742) | 2,312 (2,222 a 2,342) | +1,570 (+1,493 a +1,642) | 0,956 (0,928 a 0,992) | +0,256 (+0,185 a +0,264) |
| Gerente de 100 | 4.000 | 0,794 (0,742 a 0,800) | 2,178 (2,160 a 3,014) | +1,378 (+1,366 a +2,272) | 1,431 (1,425 a 1,533) | +0,631 (+0,631 a +0,791) |
| Vendedor de 10 | 400 | 0,807 (0,793 a 0,896) | 2,700 (2,687 a 2,910) | +1,907 (+1,881 a +2,014) | 1,089 (0,957 a 1,125) | +0,229 (+0,150 a +0,296) |

A política gerada acrescenta de **0,8 a 2,8 ms** sobre o controle (mediana de 1,57 ms no 17 e de 2,27 ms no 18),
**acima do limiar de 1 ms**: a mediana de cada ator fica acima do limiar, e só a rodada mais favorável do vendedor no
18 (+0,826 ms) fica abaixo. O plano das duas formas não varre a tabela de vínculos inteira, com 1, 10 e 100 revendas; esta medição usa um
único volume de vínculos (1 milhão) e 4.000 leads candidatos, então não mostra por si só como o custo varia com o
tamanho da tabela ou com o número de leads.

A forma com a lista do ator calculada uma vez por instrução tem acréscimo bem menor na maior parte dos casos (de 0,11 a
0,50 ms), mas **cresce com o tamanho da lista**: com 100 revendas ela vai a +0,631 ms no 17 e a **+1,098 ms no 18** (de
+0,603 a +1,758), isto é, em torno do limiar de 1 ms. Portanto a medição **não mostra que essa forma resolve o caso
maior** de forma robusta; mostra que ela reduz o acréscimo e muda a forma como o custo cresce.

### ADR-022, §3: construção dos registros

| | Consulta pelo Sequel | Repositório (consulta e registros) | Construção | Construção / consulta (mediana das medianas) | Por execução (mediana, mínimo a máximo) |
|---|---|---|---|---|---|
| PostgreSQL 18.6 | 170,9 ms | 455,5 ms | 284,6 ms | 167% | 151% (72% a 193%) |
| PostgreSQL 17.11 | 193,2 ms | 456,4 ms | 263,2 ms | 136% | 142% (109% a 153%) |

Construir 10.000 registros, com a coerção e o congelamento em profundidade de cada campo, custa cerca de 26 a 28 µs
por registro, de **72% a 193% da consulta em qualquer execução, sempre acima do limiar de 10%**. Esta é uma
aproximação do cenário do ADR (9 campos lógicos, 10 colunas): ela captura o custo adicional do repositório sobre a
mesma consulta, mas não é literalmente a carga de 10 campos.

## O que decide

- **Questão 1: dentro na ordem de grandeza; inconclusivo no 18.** O desenho do contexto assinado do ADR-005 não é
  contrariado, mas a folga é pequena e, no 18, três das doze estimativas passam do limiar. Uma medição com mais rodadas, numa máquina
  mais quieta e com o pooler, e o gate de 25% por comando, ficam para quando houver o executor. Nada aqui dispensa o
  teste de aceitação 6 do ADR-023.
- **Questão 2: acima do limiar.** Pela regra do ADR-023, uma alternativa é avaliada por ADR novo. Duas formas ficam
  candidatas, a tabela materializada que o ADR-023 já cita e a política com a lista do ator calculada uma vez por
  instrução; a medição de leitura mostra que a segunda reduz o acréscimo, mas não prova que cabe no limiar com 100
  revendas, e não cobre as políticas de escrita. O ADR novo precisa medir as duas, com `WITH CHECK`.
- **ADR-022, §3: acima do limiar.** Pela regra do ADR-022, construir o registro sob demanda é avaliado por ADR novo,
  com uma coerção mais barata dos valores que vêm do banco, que hoje passam pela mesma validação da entrada.

## O que isto não cobre

- Não há pooler transacional na CI, então a medição atrás do pooler (ADR-023, questão 1) continua pendente.
- O ambiente é uma máquina de desenvolvimento com WSL e 22 núcleos lógicos, não o hardware de produção, e as duas
  versões rodaram em momentos diferentes e com ruído diferente: não compare o 17 com o 18 a partir destes números.
- O custo por instrução vem da diferença entre séries de 1 e de 11 instruções, que só vale se o custo for aditivo e
  estável. As rodadas alternadas e as latências brutas expõem a falha dessa hipótese, mas não a eliminam.
- Os testes de escrita com escopo, o gate por comando, a `sonda_pooler` contra o pooler da aplicação e o `pg` sob o
  Falcon (ADR-022) não são medidos aqui.

A sonda roda também no job de planos da CI, no 17 e no 18, com 2 rodadas de 1,5 s por série. Ela falha só nas
conferências funcionais; os limiares são relatados como dentro, inconclusivo ou acima.

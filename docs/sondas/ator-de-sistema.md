# Ator de sistema: custo da política `vt_system` (K15)

Relatório da medição que acompanha a implementação do ator de sistema ([ADR-024](../adr/024-resolucao-das-questoes-do-adr-014.md),
§4) na K15. **Medição informativa**: ela não cumpre o teste de aceitação 6 do ADR-023, que continua pendente, e nenhum limiar mudou.
Script: [`script/sonda_escopo.rb`](../../script/sonda_escopo.rb), com a forma nova f7 e o filtro `VETRA_ESCOPO_FORMAS`.

## O que foi medido

A K14 ([escopo-por-acao.md](escopo-por-acao.md)) fixou a forma lista (f2) como a política de escopo por vínculo. A K15 acrescenta a
permissiva `vt_system` (`FOR ALL`, com `vetra.is_system_actor()` em `USING` e `WITH CHECK`), que é a política real do plano atual.
A **f7** é a f2 mais essa permissiva; as duas são medidas contra o controle **f0** (só o tenant), com o método da K14: 1 milhão de
vínculos, 16 clientes em processos próprios, 3 rodadas alternadas de 1,5 s, custo por instrução = (mediana de 11 instruções − mediana
de 1) / 10, como `vetra_app`, **para atores comuns** (gerente de 10 e de 100 unidades, vendedor de 10). O que se mede é o que o ator de
sistema **custa a quem não é** ator de sistema. Antes de medir, a sonda confere por conjunto de IDs que a f7 concede o mesmo que a
política real do plano, nas quatro ações (4/4 verificações no 17 e no 18). Acréscimo sobre f0, em ms (mediana; mínimo a máximo):

## PostgreSQL 18.6

| Ação | Ator | f0, custo absoluto | f2, ANY(ARRAY) | f7, f2 + política de sistema |
|---|---|---|---|---|
| SELECT por chave | gerente de 100 | 0,468 | +0,763 (+0,617 a +0,784) | +0,834 (+0,783 a +1,107) |
| SELECT por chave | vendedor de 10 | 0,655 | +0,656 (+0,524 a +0,782) | +1,110 (+1,089 a +1,333) |
| SELECT varredura do tenant | gerente de 100 | 0,949 | +1,213 (+0,925 a +1,508) | +2,663 (+2,618 a +3,273) |
| SELECT varredura do tenant | vendedor de 10 | 0,770 | +0,276 (+0,224 a +0,290) | +1,104 (+1,070 a +1,190) |
| INSERT (`WITH CHECK`) | gerente de 10 | 0,661 | +0,624 (+0,601 a +0,793) | +0,645 (+0,644 a +1,185) |
| INSERT (`WITH CHECK`) | gerente de 100 | 0,788 | +0,621 (+0,407 a +0,767) | +0,817 (+0,513 a +0,835) |
| INSERT (`WITH CHECK`) | vendedor de 10 | 0,873 | +0,709 (+0,557 a +0,811) | +0,837 (+0,764 a +0,856) |
| UPDATE por chave (`USING` e `WITH CHECK`) | gerente de 10 | 0,982 | +1,055 (+1,051 a +1,526) | +1,398 (+1,251 a +1,592) |
| UPDATE por chave (`USING` e `WITH CHECK`) | gerente de 100 | 0,924 | +1,302 (+1,196 a +1,493) | +1,602 (+1,589 a +1,672) |
| UPDATE por chave (`USING` e `WITH CHECK`) | vendedor de 10 | 0,970 | +1,267 (+1,122 a +1,364) | +1,367 (+1,337 a +1,399) |
| DELETE por chave (`USING`, desfeito) | gerente de 10 | 0,520 | +1,343 (+1,312 a +1,524) | +1,872 (+1,867 a +2,178) |
| DELETE por chave (`USING`, desfeito) | gerente de 100 | 0,725 | +1,593 (+1,528 a +1,924) | +2,355 (+2,259 a +2,722) |

## PostgreSQL 17.11

| Ação | Ator | f0, custo absoluto | f2, ANY(ARRAY) | f7, f2 + política de sistema |
|---|---|---|---|---|
| SELECT por chave | gerente de 100 | 0,460 | +0,644 (+0,554 a +0,665) | +0,678 (+0,657 a +0,717) |
| SELECT por chave | vendedor de 10 | 0,481 | +0,560 (+0,531 a +0,577) | +0,699 (+0,631 a +0,807) |
| SELECT varredura do tenant | gerente de 100 | 0,946 | +1,129 (+0,166 a +1,412) | +2,586 (+2,028 a +3,173) |
| SELECT varredura do tenant | vendedor de 10 | 1,285 | +0,404 (+0,063 a +0,689) | +2,243 (+1,813 a +2,322) |
| INSERT (`WITH CHECK`) | gerente de 10 | 0,724 | +0,615 (+0,567 a +1,035) | +0,837 (+0,810 a +1,194) |
| INSERT (`WITH CHECK`) | gerente de 100 | 0,850 | +0,624 (+0,079 a +0,781) | +0,781 (+0,208 a +1,769) |
| INSERT (`WITH CHECK`) | vendedor de 10 | 0,694 | +0,639 (+0,611 a +0,645) | +0,840 (+0,836 a +0,881) |
| UPDATE por chave (`USING` e `WITH CHECK`) | gerente de 10 | 0,883 | +0,955 (+0,953 a +1,405) | +1,598 (+1,320 a +1,763) |
| UPDATE por chave (`USING` e `WITH CHECK`) | gerente de 100 | 1,372 | +2,060 (+1,034 a +2,440) | +2,800 (+2,562 a +3,556) |
| UPDATE por chave (`USING` e `WITH CHECK`) | vendedor de 10 | 2,545 | +2,364 (+2,047 a +3,796) | +3,633 (+2,740 a +4,752) |
| DELETE por chave (`USING`, desfeito) | gerente de 10 | 1,062 | +2,458 (+2,003 a +2,537) | +2,971 (+2,870 a +3,066) |
| DELETE por chave (`USING`, desfeito) | gerente de 100 | 0,596 | +1,604 (+1,565 a +1,644) | +2,224 (+1,915 a +2,409) |

## O que os números mostram

- **A política de sistema encarece o ator comum.** Em relação à f2, a f7 acrescenta de **+0,03 a +0,45 ms** na leitura por chave e de
  **+0,02 a +0,22 ms** no `INSERT`; no `UPDATE` e no `DELETE` por chave, de **+0,10 a +1,27 ms** (a maior diferença, no 17, tem dispersão
  grande); e na **varredura do tenant**, de **+0,83 a +1,84 ms**, a maior alta.
- **Causa provável, não investigada com `EXPLAIN`.** Cada referência a uma rotina de contexto revalida o token (0,2 a 0,3 ms, K14), e a
  `vt_system` acrescenta uma por instrução (duas no `UPDATE`). A alta maior na varredura sugere ainda que o `OR` entre a permissiva de
  escopo e a de sistema impede o planejador de restringir a leitura pelo índice da lista do ator, como a f2 fazia sozinha. Confirmar
  pede um `EXPLAIN` por forma.
- **Com isso, o piso de 1 ms por instrução do ADR-023 fica mais longe.** A f2 já passava de 1 ms em quase todo `UPDATE` e `DELETE` por
  chave; com a f7, passa em todas as células de `UPDATE` e `DELETE` e também em todas as varreduras medidas (de +1,10 a +2,66 ms).
- **Limites desta medição.** Três rodadas por célula, sandbox compartilhado do WSL, 4 CPUs, sem pooler, e dispersão grande em algumas
  células (veja os mínimos e máximos; o `UPDATE` do vendedor de 10 no 17 tem controle f0 de 2,5 ms, ruído). Atores de 1 e de 1.000
  unidades não foram medidos nesta rodada.

## O que decidir (do mantenedor)

O ADR-024, §4 decidiu que o ator de sistema é uma **segunda condição permissiva** nas políticas de escopo, e a K15 o implementa assim. O
ADR já registra a saída se o custo passar do limiar: uma função única que devolve (tenant, ator, tipo) e valida uma vez. Esta medição
acrescenta uma segunda saída, que muda a decisão 2 do ADR e por isso pede um ADR novo, não um ajuste: dar ao ator de sistema um **papel de
banco próprio**, como o relay (ADR-040). A política do papel de sistema seria `TO vetra_system USING (true)`, e as políticas de escopo
ficariam só `TO vetra_app`, então o ator comum **não pagaria nada** pela existência do ator de sistema. O custo seria operacional (outro
login e outro pool para os handlers, e outro papel no bootstrap do ADR-036). Os dois caminhos podem ser medidos com a mesma sonda; o
gatilho é a medição por comando da K20.
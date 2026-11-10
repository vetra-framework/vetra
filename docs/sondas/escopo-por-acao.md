# Escopo por vínculo: custo por ação e permissões (K14)

Relatório da medição que decide o [ADR-041](../adr/041-forma-da-politica-de-escopo.md). **Medição informativa**: ela
não cumpre o teste de aceitação 6 do ADR-023, que continua pendente, e nenhum limiar mudou para acomodar o resultado.
Script: [`script/sonda_escopo.rb`](../../script/sonda_escopo.rb), subclasse da sonda de custo do contexto
([`custo-contexto.md`](custo-contexto.md)).

## Método

- **Banco.** O plano do `mini_crm_revendas` aplicado por `setup_example`, com 1.001.127 vínculos, sete atores (gerente
  de 1, 10, 100 e 1.000 unidades, vendedor de 10, papéis mistos e sem vínculos), 1.000 revendas e 4.000 leads nas
  revendas 1 a 100. Os papéis são os do plano; a aplicação (`vetra_app`) não tem `BYPASSRLS`.
- **Variantes.** Cada uma é uma cópia `bench.leads_<forma>` da tabela de leads, sem triggers, com a política de tenant
  `RESTRICTIVE` e as permissivas de escopo por ação (`SELECT`, `INSERT`, `UPDATE`, `DELETE`):

| Forma | O que é |
|---|---|
| f0 | Só o tenant: controle de custo |
| f1 | A política gerada antes da K14, um `EXISTS` correlacionado por papel |
| f2 | `unidade = ANY (ARRAY(SELECT ...))`, a lista do ator lida uma vez, com `role IN (...)` (a forma do ADR-041) |
| f3 | A mesma lista como `unidade IN (SELECT ...)` |
| f4 | Tabela materializada do escopo efetivo `(company_id, user_id, dealer_id)`, consultada como f1 |
| f5 | Um só `EXISTS` correlacionado com `role IN (...)` |
| f6 | f5 mais duas referências inúteis ao tenant, para calibrar o custo de cada chamada de contexto |

- **Custo.** 16 clientes em processos próprios (`fork`), 3 rodadas alternadas de 1,5 s por série; custo por instrução =
  (mediana de 11 instruções − mediana de 1) / 10. As tabelas mostram o **acréscimo sobre f0**, mediana das rodadas e,
  entre parênteses, mínimo e máximo. `DELETE` mede com `ROLLBACK`, para que as linhas voltem à série seguinte.
- **Ações.** `SELECT` por chave, `SELECT` varredura do tenant, `INSERT` (`WITH CHECK`), `UPDATE` por chave (`USING` e
  `WITH CHECK`) e `DELETE` por chave (`USING`).
- **Permissões.** Antes de medir, a sonda confere, **por conjunto de IDs** (não por contagem), que a política real do plano e f1 a f6 dão as
  mesmas permissões, por ação e por ator, e as mesmas que uma expectativa calculada sem consultar política alguma. As quatro
  ações rodam contra a tabela real e contra cada variante, e o `UPDATE` compara também a mudança de unidade: origem
  permitida e proibida (`USING`) e destino permitido, proibido e nulo (`WITH CHECK`), com os desfechos 1 linha, 0 linhas e erro, e que o plano de cada forma não varre a tabela de
  vínculos inteira com 1, 10 e 100 revendas. Em todas as execuções as 3 verificações funcionais passaram.

## PostgreSQL 18.6

| Ação | Ator | f0, custo absoluto | f1, gerada | f2, ANY(ARRAY) | f3, IN (SELECT) | f4, materializada | f5, EXISTS único | f6, f5 + 2 chamadas |
|---|---|---|---|---|---|---|---|---|
| SELECT por chave | gerente de 1 | 0,457 | +0,814 (+0,778 a +1,239) | +0,554 (+0,496 a +0,735) | +0,564 (+0,548 a +1,504) | +0,441 (+0,415 a +0,935) | +0,858 (+0,828 a +0,952) | +1,230 (+1,089 a +1,696) |
| SELECT por chave | gerente de 100 | 0,535 | +1,254 (+1,050 a +1,966) | +0,923 (+0,578 a +1,011) | +0,970 (+0,584 a +1,253) | +0,675 (+0,416 a +0,735) | +1,049 (+0,891 a +1,131) | +1,301 (+1,074 a +1,671) |
| SELECT por chave | vendedor de 10 | 0,547 | +1,172 (+1,149 a +1,710) | +0,649 (+0,545 a +0,675) | +0,600 (+0,577 a +0,671) | +0,443 (+0,363 a +0,476) | +0,867 (+0,761 a +0,917) | +1,279 (+1,173 a +2,924) |
| SELECT varredura do tenant | gerente de 1 | 0,775 | +1,605 (+1,430 a +1,700) | +0,225 (+0,213 a +0,255) | +0,816 (+0,740 a +1,087) | +0,792 (+0,698 a +1,119) | +1,056 (+1,002 a +1,200) | +1,375 (+1,291 a +1,471) |
| SELECT varredura do tenant | gerente de 100 | 0,839 | +1,467 (+1,422 a +1,536) | +0,534 (+0,458 a +0,608) | +1,188 (+1,131 a +1,373) | +1,068 (+1,025 a +1,117) | +1,433 (+1,311 a +1,564) | +1,592 (+1,571 a +1,691) |
| SELECT varredura do tenant | vendedor de 10 | 0,871 | +1,674 (+1,665 a +1,747) | +0,303 (+0,228 a +0,310) | +0,903 (+0,847 a +0,973) | +0,835 (+0,748 a +1,582) | +1,138 (+1,129 a +1,199) | +1,415 (+1,373 a +1,535) |
| INSERT (`WITH CHECK`) | gerente de 10 | 0,760 | +0,727 (+0,664 a +0,920) | +0,507 (+0,487 a +0,647) | +0,782 (+0,660 a +0,824) | +0,367 (+0,351 a +0,595) | +0,623 (+0,579 a +0,737) | +1,204 (+0,939 a +1,258) |
| INSERT (`WITH CHECK`) | gerente de 100 | 0,942 | +0,769 (+0,643 a +1,226) | +0,739 (+0,340 a +1,001) | +0,735 (+0,648 a +1,433) | +0,463 (+0,428 a +0,662) | +0,836 (+0,556 a +1,033) | +1,233 (+1,143 a +1,254) |
| INSERT (`WITH CHECK`) | vendedor de 10 | 0,852 | +1,797 (+1,425 a +2,301) | +0,616 (+0,588 a +0,734) | +0,835 (+0,673 a +1,081) | +0,542 (+0,451 a +0,813) | +0,735 (+0,582 a +0,894) | +1,052 (+1,014 a +1,170) |
| UPDATE por chave (`USING` e `WITH CHECK`) | gerente de 10 | 1,161 | +1,863 (+1,627 a +2,135) | +1,620 (+1,045 a +1,673) | +1,523 (+0,851 a +1,534) | +0,795 (+0,611 a +1,640) | +1,583 (+1,420 a +1,947) | +2,207 (+2,119 a +3,041) |
| UPDATE por chave (`USING` e `WITH CHECK`) | gerente de 100 | 1,196 | +2,132 (+2,085 a +2,166) | +1,583 (+1,446 a +1,883) | +1,678 (+1,501 a +2,436) | +1,291 (+0,979 a +1,382) | +2,582 (+1,677 a +2,733) | +2,453 (+2,291 a +2,560) |
| UPDATE por chave (`USING` e `WITH CHECK`) | vendedor de 10 | 1,154 | +2,741 (+2,667 a +2,882) | +1,586 (+1,188 a +1,907) | +1,523 (+1,297 a +1,897) | +1,014 (+0,819 a +2,176) | +1,747 (+1,485 a +1,954) | +2,549 (+2,417 a +2,937) |
| DELETE por chave (`USING`, desfeito) | gerente de 10 | 0,653 | +1,741 (+1,416 a +1,952) | +1,405 (+1,120 a +2,314) | +1,452 (+1,419 a +2,202) | +0,952 (+0,879 a +1,172) | +1,936 (+1,706 a +2,170) | +2,835 (+2,512 a +3,219) |
| DELETE por chave (`USING`, desfeito) | gerente de 100 | 0,494 | +1,893 (+1,446 a +2,054) | +1,624 (+0,999 a +1,667) | +1,231 (+1,151 a +1,663) | +0,946 (+0,932 a +0,971) | +1,574 (+1,513 a +1,892) | +2,197 (+1,874 a +2,223) |

## PostgreSQL 17.11

| Ação | Ator | f0, custo absoluto | f1, gerada | f2, ANY(ARRAY) | f3, IN (SELECT) | f4, materializada | f5, EXISTS único | f6, f5 + 2 chamadas |
|---|---|---|---|---|---|---|---|---|
| SELECT por chave | gerente de 1 | 0,599 | +1,090 (+1,003 a +1,258) | +0,577 (+0,541 a +0,593) | +0,565 (+0,536 a +0,604) | +0,372 (+0,328 a +0,403) | +0,869 (+0,838 a +0,927) | +1,249 (+1,148 a +1,563) |
| SELECT por chave | gerente de 100 | 0,533 | +1,322 (+1,183 a +1,526) | +0,832 (+0,754 a +1,023) | +0,924 (+0,754 a +0,963) | +0,731 (+0,596 a +0,771) | +1,170 (+1,063 a +1,321) | +1,438 (+1,210 a +2,083) |
| SELECT por chave | vendedor de 10 | 0,490 | +1,200 (+1,139 a +1,456) | +0,464 (+0,387 a +0,480) | +0,488 (+0,376 a +0,560) | +0,383 (+0,264 a +0,566) | +0,843 (+0,629 a +1,219) | +1,079 (+0,796 a +1,088) |
| SELECT varredura do tenant | gerente de 1 | 0,979 | +1,469 (+1,461 a +1,772) | +0,196 (+0,167 a +0,205) | +0,888 (+0,775 a +0,918) | +0,792 (+0,739 a +0,796) | +0,936 (+0,903 a +1,442) | +1,288 (+1,229 a +1,968) |
| SELECT varredura do tenant | gerente de 100 | 1,026 | +1,896 (+1,737 a +1,917) | +1,148 (+0,993 a +1,219) | +1,711 (+1,494 a +1,725) | +1,369 (+1,128 a +1,603) | +2,090 (+1,305 a +2,251) | +2,092 (+1,555 a +2,445) |
| SELECT varredura do tenant | vendedor de 10 | 0,940 | +1,754 (+1,576 a +1,961) | +0,203 (+0,181 a +0,427) | +1,144 (+0,913 a +1,502) | +0,816 (+0,696 a +0,937) | +1,194 (+1,099 a +1,236) | +1,491 (+1,247 a +1,809) |
| INSERT (`WITH CHECK`) | gerente de 10 | 0,684 | +0,712 (+0,695 a +0,794) | +0,582 (+0,582 a +0,633) | +0,620 (+0,588 a +0,653) | +0,439 (+0,406 a +0,491) | +0,833 (+0,779 a +1,017) | +1,147 (+1,076 a +1,569) |
| INSERT (`WITH CHECK`) | gerente de 100 | 0,781 | +0,813 (+0,775 a +0,819) | +0,599 (+0,506 a +0,826) | +0,702 (+0,497 a +0,780) | +0,538 (+0,315 a +0,717) | +0,819 (+0,796 a +0,887) | +1,082 (+1,022 a +1,192) |
| INSERT (`WITH CHECK`) | vendedor de 10 | 0,767 | +1,474 (+1,313 a +1,486) | +0,673 (+0,657 a +0,885) | +0,626 (+0,618 a +0,627) | +0,525 (+0,488 a +0,543) | +0,903 (+0,693 a +1,152) | +1,018 (+0,934 a +1,088) |
| UPDATE por chave (`USING` e `WITH CHECK`) | gerente de 10 | 1,200 | +1,630 (+1,525 a +1,968) | +1,072 (+0,981 a +1,472) | +1,205 (+1,146 a +1,608) | +0,995 (+0,678 a +1,189) | +1,844 (+1,052 a +1,907) | +2,212 (+2,174 a +2,259) |
| UPDATE por chave (`USING` e `WITH CHECK`) | gerente de 100 | 1,033 | +1,908 (+1,648 a +1,969) | +1,138 (+0,982 a +1,289) | +1,456 (+1,075 a +1,472) | +0,809 (+0,765 a +0,920) | +1,303 (+1,252 a +1,477) | +1,664 (+1,657 a +1,929) |
| UPDATE por chave (`USING` e `WITH CHECK`) | vendedor de 10 | 0,987 | +2,215 (+2,097 a +2,746) | +0,839 (+0,799 a +1,534) | +1,266 (+1,092 a +1,720) | +1,092 (+1,007 a +1,094) | +1,518 (+1,347 a +1,529) | +1,903 (+1,392 a +2,147) |
| DELETE por chave (`USING`, desfeito) | gerente de 10 | 0,453 | +1,471 (+1,204 a +1,485) | +1,140 (+0,991 a +1,832) | +1,022 (+0,873 a +1,531) | +0,948 (+0,808 a +1,118) | +1,089 (+0,763 a +1,687) | +1,764 (+1,564 a +1,838) |
| DELETE por chave (`USING`, desfeito) | gerente de 100 | 0,402 | +1,463 (+1,266 a +1,532) | +1,098 (+1,016 a +1,164) | +1,034 (+1,030 a +1,055) | +0,778 (+0,711 a +0,802) | +1,346 (+1,165 a +1,442) | +1,586 (+1,541 a +1,830) |

## Ator de 1.000 unidades (só leitura)

PostgreSQL 18.6:

| Ação | Ator | f0, custo absoluto | f1, gerada | f2, ANY(ARRAY) | f3, IN (SELECT) | f4, materializada | f5, EXISTS único | f6, f5 + 2 chamadas |
|---|---|---|---|---|---|---|---|---|
| SELECT por chave | gerente de 1000 | 0,428 | +1,401 (+1,368 a +1,471) | +0,701 (+0,643 a +0,718) | +0,966 (+0,845 a +1,194) | +0,894 (+0,876 a +0,910) | +0,961 (+0,930 a +0,965) | +1,707 (+1,366 a +1,906) |
| SELECT varredura do tenant | gerente de 1000 | 0,747 | +1,990 (+1,845 a +2,055) | +0,808 (+0,714 a +0,847) | +1,780 (+1,723 a +1,892) | +1,623 (+1,270 a +1,666) | +1,715 (+1,643 a +2,255) | +2,058 (+1,926 a +2,638) |

PostgreSQL 17.11:

| Ação | Ator | f0, custo absoluto | f1, gerada | f2, ANY(ARRAY) | f3, IN (SELECT) | f4, materializada | f5, EXISTS único | f6, f5 + 2 chamadas |
|---|---|---|---|---|---|---|---|---|
| SELECT por chave | gerente de 1000 | 0,712 | +2,286 (+2,119 a +2,306) | +1,081 (+0,743 a +1,085) | +1,636 (+1,409 a +1,872) | +1,165 (+1,053 a +1,360) | +1,961 (+1,354 a +1,978) | +1,915 (+1,908 a +3,181) |
| SELECT varredura do tenant | gerente de 1000 | 1,326 | +2,829 (+2,694 a +3,681) | +1,607 (+1,317 a +2,080) | +3,137 (+2,598 a +3,481) | +2,401 (+2,358 a +2,892) | +2,978 (+2,631 a +3,405) | +3,968 (+3,856 a +4,289) |

## O que os números mostram

- **A forma lista (f2) é a menor das formas sem tabela derivada nas leituras** (varredura: +0,20 a +1,15 ms contra
  +0,82 a +1,71 da f3) e **empata com a f3 nas escritas**: em algumas células de `UPDATE` e `DELETE` a f3 fica menor, por
  até 0,4 ms (o `DELETE` do gerente de 100 unidades no 18), mas os mínimos e máximos das rodadas se sobrepõem. A f1,
  a política gerada antes da K14, é maior que a f2 em todas as células, de 0,03 a 1,55 ms.
- **A f3 não escala melhor que a f2.** Com 1.000 unidades, f2 fica em +0,70 e +0,81 ms (18) e +1,08 e +1,61 ms (17);
  f3, em +0,97 e +1,78 ms (18) e +1,64 e +3,14 ms (17). A hipótese de que o hash da f3 ganharia em listas grandes não se
  confirma até 1.000 unidades.
- **A materializada (f4) ganha da f2 de 0,1 a 0,8 ms nas operações por chave** (a exceção é o `UPDATE` do vendedor de 10
  unidades no 17, onde a f2 é 0,25 ms menor), **mas perde nas varreduras** (+0,79 a +1,37
  ms contra +0,20 a +1,15) e exige manter uma tabela derivada.
- **O piso vem do contexto.** O custo de f6 − f5, duas referências a mais, indica da ordem de 0,2 a 0,3 ms por referência
  a `vetra.current_tenant()` ou `vetra.current_actor()` (ADR-024, §4), e `UPDATE` dobra as referências (`USING` e
  `WITH CHECK`). Em `UPDATE` e `DELETE` por chave quase toda célula passa de 1 ms: a f2 fica abaixo em uma só (o `UPDATE` do vendedor de 10
  unidades no 17, com +0,84) e a f4, em sete (de +0,78 a +0,99); baixar esse piso é decisão sobre a
  função de contexto, e não sobre a forma do escopo.
- **Limites desta medição.** Sandbox compartilhado do WSL, com dispersão entre rodadas de até 2x em algumas células
  (veja os mínimos e máximos); 4 CPUs; um só formato de tabela de vínculos; sem pooler. A CI tem dispersão maior e não
  serve como gate. Atores com mais de 1.000 unidades não foram medidos.
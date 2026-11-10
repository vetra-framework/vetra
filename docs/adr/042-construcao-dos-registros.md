# ADR-042: Construção dos registros

- Status: proposto
- Data: 2026-11-10
- Depende de: ADR-003, ADR-022 (§3), ADR-035 e ADR-039 (§5)
- Substitui em parte: ADR-022 (§3, só o custo e a forma de construção)

## Contexto

O ADR-022 escolheu um `Data` por entidade, com valores congelados em profundidade, sem escritores e com `with`.
Também pôs o gate: construir 10.000 registros de dez campos deve custar até 10% da consulta que os trouxe; acima
disso, avaliar construção sob demanda por ADR novo. A [K13](../sondas/custo-contexto.md#adr-022-3-construção-dos-registros)
mediu 26–28 µs por registro e 72%–193% da consulta, com medianas de 136%–167%. Era uma aproximação: o lead tem nove
campos lógicos e dez colunas, e a consulta levou aproximadamente 17–19 µs por linha.

A C10 usava `Values.coerce` tanto na entrada quanto na leitura. Cada campo lido repetia as verificações de tipo,
nulabilidade, enum, comprimento e precisão; depois, `Record#initialize` copiava novamente os valores já congelados.
Nem tudo pode ser delegado ao DDL: ainda é preciso formar dinheiro/JSON, entregar UTC e manter a faixa de anos de
`Values` (1 a 9999), menor que a do PostgreSQL.

### Medição em Ruby, sem banco

Reprodução: `bundle exec ruby script/medir_construcao_registros.rb`. Ruby 4.0.9, Sequel 5.110.0, WSL/Linux x86_64,
sem YJIT, GC ligado, 10.000 hashes já em memória, nove rodadas com ordem girada, após aquecimento de 1.000 linhas.
Cada variante recebe linhas novas e mutáveis, desserializadas **fora** da região medida; não se mede repetidamente
uma linha já congelada. A preparação do tipo, dos leitores e dos valores imutáveis do piso também fica fora.
A leitura integral usa acessos Ruby diretos gerados, sem reflexão por campo, nas duas alternativas.
O piso inclui `Data.new` com palavras-chave e a coleção de resultados, sem conversão nem congelamento profundo.

Dois perfis: o lead real do CRM com revendas (nove campos/dez colunas, dinheiro preenchido, vendedor nulo); e dez
campos lógicos/onze colunas: dois UUIDs, nome, email, enum, dinheiro, timestamp, date, decimal e JSON aninhado.
Valores, igualdade, `with` e leitura num Ractor do protótipo sob demanda são conferidos antes de medir.
Resultados em **µs por registro**, mediana (mínimo–máximo):

| Alternativa | Lead real | Dez campos mistos |
|---|---:|---:|
| (a) C10: validação estrita e cópia pelo construtor | 19,208 (18,110–19,785) | 30,380 (27,153–33,353) |
| (b) Conversão imediata de leitura | 3,937 (3,752–4,130) | 6,829 (6,549–7,664) |
| (b) Construir e ler todos os campos (controle) | 3,934 (3,820–4,323) | 6,963 (6,637–7,842) |
| (c) Sob demanda, somente construir | 1,286 (1,194–1,760) | 1,842 (1,685–2,048) |
| (c) Construir e ler todos os campos | 3,966 (3,719–4,276) | 6,884 (6,695–7,273) |
| (c) Construir e ler todos os campos duas vezes | 6,513 (6,287–6,739) | 11,996 (11,485–13,301) |
| Piso de `Data.new` | 0,494 (0,413–0,700) | 0,496 (0,462–0,690) |

São custos locais de CPU/alocação, não uma repetição da consulta PostgreSQL da K13. A dispersão é visível; os
decimais não significam precisão de produção. O caminho (b) reduz a mediana em 77%–80% frente ao (a). O piso
mostra que alocar o `Data` cabe num orçamento de aproximadamente 1,7 µs; as conversões e o congelamento destas
cargas ainda não cabem. Isto não prova um limite inferior para toda implementação Ruby possível.

## Decisão

### 1. Converter imediatamente, com um caminho exclusivo para linhas do banco

Escolher **(b)**, mantendo o mesmo `Data` por entidade, seus membros e predicados. `RowReader`, preparado uma vez
por entidade no catálogo, recebe somente hashes tipados pelo Sequel/pg, selecionados pelo repositório sobre o
DDL correspondente à IR. Não é uma API de entrada e não aceita linhas arbitrárias como contrato público.

- UUIDs, booleanos, inteiros e `numeric(p,s)` já são devolvidos pelo driver como valores Ruby adequados. O
  `BigDecimal` é imutável e já representa exatamente a escala física; não se faz conversão via Float, novo parse
  nem arredondamento. UUID vem canônico; a normalização do texto é garantida pelo CHECK gerado.
- Textos são congelados; se necessário, são transcodificados para UTF-8. Não se repetem tipo, nulidade, enum,
  comprimento, faixa de bigint, precisão/escala e moeda ISO garantidos pelo tipo/NOT NULL/CHECK do DDL.
- Dinheiro é montado das duas colunas num `Money` imutável, reaproveitando o decimal. Um par parcial é recusado.
  JSON perde os wrappers do Sequel e vira Hash/Array comum congelado em profundidade. Seus números Float precisam
  ser finitos: um número jsonb muito grande pode exceder a representação do parser Ruby.
- Timestamp é convertido para UTC e congelado; date é congelado. A faixa 1–9999 de ambos e a resolução de
  microssegundos do timestamp continuam sendo conferidas. Datas/instantes infinitos são recusados.
- O leitor verifica `Ractor.shareable?` no registro final. A construção interna usa `Data#initialize` nativo
  sobre os valores já convertidos, sem passar pela cópia de `Record#initialize` e sem adicionar métodos ao registro.
  Strings e datas da linha pertencem à leitura e podem ser congeladas no lugar; a linha não é exposta ao `call`.

`create!`, `update!`, identificadores e igualdades de consultas continuam passando pelo mesmo `Values.coerce`.
A leitura de `RETURNING`, de OLD sob lock e de exclusões usa o novo leitor, como os SELECTs. Construção pública
do tipo e `with` continuam copiando/congelando os atributos; `with` não ganha validação de domínio nova.

### 2. Falhas e contrato observável

Falha de conversão, coluna ausente, par monetário parcial, valor não compartilhável ou violação das invariantes
residuais gera **`data_read_value`**, com mensagem fixa `Linha do banco incompatível com o registro.` e `cause: nil`,
sem valores ou SQL. A ausência da linha continua sendo `RecordNotFound`. Não se promete detectar todo valor
forjado que viola o DDL: por exemplo, enum desconhecido ou NULL obrigatório em hash artificial não são revalidados.
O tipo/DDL aplicado e o driver constituem a garantia no lugar dessa defesa redundante da C10.

| Efeito para quem usa o registro | (a) Atual | (b) Escolhida | (c) Sob demanda avaliada |
|---|---|---|---|
| Igualdade, `eql?`, `hash` | Valores dos membros do mesmo `Data` | Idênticos em linhas válidas | Exigem sobrepor operações nativas para comparar valores lógicos; a linha crua não serve |
| `inspect`, `to_h`, pattern matching e `members` | Membros lógicos já convertidos | Idênticos | Protótipo inspeciona um Hash lógico; `to_h` e pattern matching convertem tudo e podem falhar; membros de instância são sobrepostos |
| `with` | Novo valor imutável quando há alterações | Idêntico, pela inicialização pública | Deve reconstruir a linha ou materializar; o protótipo reconstrói mantendo o tipo |
| Erros | `data_value`, durante leitura | `data_read_value`, durante leitura, só na fronteira acima | Erros de campo chegam no acesso; `to_h`, igualdade, `hash` e inspeção também podem falhar |
| Ordem de falha | Ordem dos campos da IR, depois cópia final | Ordem dos campos da IR, depois guarda de compartilhamento | Ordem dos acessos; um campo nunca lido pode nunca falhar |
| Identidade do valor de um campo | Estável | Estável | Dinheiro/JSON podem ser novos objetos em cada acesso, embora iguais |

Nenhuma promessa de imutabilidade, compartilhamento, ausência de escritores ou predicados do ADR-022/039 é
relaxada. Muda a garantia contra linhas artificiais inválidas, antes incidentalmente verificadas como entrada.

### 3. O gate permanece aberto

**O limiar vigente continua 10%, e a medição no PostgreSQL mostra que ele não é alcançado.** O Claude executou a sonda de
custo (`sonda_custo_contexto.rb`, com as condições da CI) no PostgreSQL 17.11 e 18.6, uma versão por vez e duas execuções
cada, com 10.000 leads e a mediana de sete rodadas por execução:

| Execução | Consulta | Construção direta | µs por registro | Construção / consulta |
|---|---:|---:|---:|---:|
| PostgreSQL 18.6, 1 | 166,6 ms | 92,5 ms | 9,25 | 56% |
| PostgreSQL 18.6, 2 | 182,0 ms | 72,4 ms | 7,24 | 40% |
| PostgreSQL 17.11, 1 | 176,6 ms | 78,3 ms | 7,83 | 44% |
| PostgreSQL 17.11, 2 | 204,1 ms | 100,7 ms | 10,07 | 49% |

Antes da C11 (K13), a construção da mesma carga custava de 263 a 285 ms (136% a 167%): a conversão imediata a reduz de
três a quatro vezes, mas a razão fica de 40% a 56%, quatro a cinco vezes o limiar. As rodadas variam muito (a construção,
de 50 a 167 ms), e o custo por registro no banco (7 a 10 µs) é maior que o da medição em Ruby (3,9 µs); a diferença não foi
investigada. A estimativa de cerca de 23% que a medição em Ruby sugeria estava errada. Nenhuma alternativa medida
resolve o custo total de dez campos nesse orçamento; a construção sob demanda só adia parte do trabalho.

A sonda PostgreSQL passa a cronometrar diretamente a conversão das mesmas linhas que a consulta trouxe, além
do repositório completo, evitando inferir construção pela subtração de duas consultas ruidosas. Relata a razão
construção/consulta, com o **mesmo 0,10**, e o custo absoluto. Continua informativa, como na K13; não anuncia aceite.

Cabe ao mantenedor decidir, com a medição acima, se mantém os 10% e pede outra implementação, ou adota um
orçamento absoluto. Uma proposta para discussão é mediana de até **10 µs por registro de dez campos mistos**
(100 ms para 10.000), na mesma carga Ruby, e repetição no ambiente de destino. Esse número **não é um gate novo**
nem passa a valer pelo aceite da otimização; alterar o critério exige decisão explícita do mantenedor. O lead medido no PostgreSQL ficou de 7,2 a 10,1 µs por registro:
o número proposto seria atendido no limite, e foi escolhido antes dessa medição, então uma regressão pequena o violaria.

## Alternativas rejeitadas

- **(a), manter a C10:** 19,208/30,380 µs, contra 3,937/6,829 µs da leitura dedicada, repetindo garantias do banco e
  copiando valores duas vezes. Continua como referência executável da medição e dos testes de equivalência.
- **(c), sob demanda sem memoização:** o protótipo guarda só a linha congelada num `Data`, expõe leitores dos campos,
  igualdade por valores, inspeção/`to_h`, predicado de enum e `with`, e é compartilhável inclusive na leitura por
  outro Ractor. O custo inicial cai para 1,286/1,842 µs; lendo todos os campos, 3,966/6,884 µs, na mesma ordem de
  (b), com faixas sobrepostas.
  Acesso repetido chega a 6,513/11,996 µs, e há erros tardios, identidade instável de subvalores e substituição dos
  métodos nativos do `Data`. O protótipo tem membro físico `_row`; uma implementação teria ainda de decidir a
  introspecção de classe e a serialização, além das sobreposições de instância. Sem workload que demonstre que a
  maioria dos campos fica sem acesso, o custo e a mudança de contrato não justificam a escolha.
- **(c), memoização mutável:** um Hash de cache, instâncias alteradas no primeiro acesso ou uma closure mutável
  retida no registro quebram o congelamento profundo/`Ractor.shareable?`. Um cache já completo custa conversão
  imediata; um cache externo por Ractor acrescenta retenção, sincronização e política de descarte. Não foi medido
  como solução conforme: não há protótipo de cache mutável que satisfaça estas garantias.

## Consequências

Em Ruby a leitura fica de quatro a cinco vezes mais barata, e no PostgreSQL a construção cai de três a quatro vezes, sem custo
escondido nos acessos. Banco, SQL,
planos, retratos, modelos e IR 0.6 permanecem iguais. A correspondência entre IR, DDL aplicado e configuração
do driver é requisito da leitura; mudar a decodificação do driver exige repetir os testes e a sonda.
O uso direto do inicializador nativo também exige repetir a conferência ao atualizar Ruby.

Ficam para a rodada 5: aceite deste ADR e decisão do orçamento pelo mantenedor e custo dos comandos
pelo executor (K20). Ator de sistema, idempotência, autorização e execução
das operações conservam as dependências do [plano](../plano-persistencia.md).

## Garantia

- **Verificável por testes:** equivalência com a C10 para os campos de todas as entidades dos quatro exemplos,
  mais integer/date/decimal/JSON; tipos, valores, igualdade, inspeção, `to_h`, `with`, predicados, congelamento e
  leitura num Ractor; linha corrompida recusada sem dados na exceção; entrada estrita preservada.
- **Estrutural:** os repositórios chamam o leitor apenas para linhas de SELECT/RETURNING, e usam `Values.coerce`
  na entrada. O leitor não adiciona escritores ao tipo. O DDL do ADR-035 garante as restrições delegadas.
- **Experimental:** o script Ruby compara (a), (b), (c) e o piso; a sonda PostgreSQL mede consulta, construção e
  repositório completo separadamente, mantendo o limiar do ADR-022. Só a execução real confirma a razão.

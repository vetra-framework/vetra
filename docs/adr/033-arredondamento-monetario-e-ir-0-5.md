# ADR-033: Arredondamento monetário da aplicação e IR 0.5

- Status: aceito
- Aceite: 2026-11-03, pelo Claude por delegação do mantenedor, após a auditoria da C3 (devolvida na rodada 1, aprovada na rodada 2).
- Data: 2026-11-03
- Depende de: ADR-001 (IR e compatibilidade), ADR-017 (money) e ADR-026 (expoentes ISO 4217)

## Contexto

O mini CRM da proposta declara `currency "BRL", rounding: :half_up`. O DSL recusa essa opção com
`unsupported_option`, embora o ADR-017 já defina o arredondamento comercial como padrão. A escala segue
o expoente da moeda ou a precisão estendida do campo (ADRs 017 e 026). Falta representar qual modo o
consumidor deve usar quando uma operação monetária precisa reduzir casas.

## Decisão

### Modos e alcance

`currency` aceita `rounding:` como símbolo ou string de um conjunto fechado:

| Modo | Regra de desempate na metade exata | Exemplos na escala 2 |
|---|---|---|
| `half_up` | Mais distante de zero (comercial) | `1.225 → 1.23`; `-1.225 → -1.23` |
| `half_even` | Último algarismo retido par | `1.225 → 1.22`; `1.235 → 1.24`; `-1.225 → -1.22` |

Ambos escolhem o valor representável mais próximo fora do empate. `half_up` conserva o nome do exemplo
da proposta; `half_even` oferece a alternativa mínima de desempate sem viés sistemático. Ausência de
`rounding:` significa **`half_up`**, inclusive quando `currency` é omitida. `nil`, booleanos, números e
nomes fora do conjunto são erros `money_rounding`, com origem e ponteiro `/app/rounding`.

O modo governa **somente conversão explícita e divisão** quando o resultado tem mais casas que a escala
de destino. A escala de destino é a do campo; sem precisão estendida, é o expoente da moeda. Não se
arredondam soma, subtração, comparação, valores já representáveis nem resultados intermediários.
Persistir ou exibir um valor já representável não dispara novo arredondamento. O rateio exato do ADR-017
continua distribuindo o resto em unidades mínimas; não é substituído por divisões arredondadas independentes.

Esta entrega declara e valida o contrato; não implementa aritmética, conversão, persistência ou
formatação. Defaults e entradas com casas excedentes continuam sujeitos à recusa de escala do ADR-017;
a opção não autoriza truncar ou corrigir literais durante o build. Moeda por tenant e arredondamento por
tenant ou por campo continuam fora desta decisão.

### Representação e compatibilidade

O modo vive em **`app.rounding`**, uma string opcional na **IR 0.5**. Ausência significa `half_up` em
todas as versões suportadas. O build emite o campo e inclui **`vetra.money_rounding`** em `requires`
somente quando a aplicação declara `rounding:`, inclusive `half_up` e mesmo sem campos `money`.
Sem a declaração, ambos ficam ausentes: o padrão do ADR-017 continua correto para consumidores que
não implementam o recurso. `requires` lista os recursos usados pelo documento, seguindo o mesmo
critério dos comandos gerados de vínculo da C1. Uma IR externa 0.5 que declara o campo precisa desse
requisito; sem o campo, vale o padrão, com ou sem o requisito. Não há propriedade nova em cada campo monetário.

É recurso semântico: o consumidor precisa interpretar o modo para calcular valores. Conforme o
ADR-001 §4, exige **nova MENOR e requisito**, não anotação nem alteração da IR 0.4. O schema 0.5 é novo,
fechado e autocontido; o campo opcional preserva os documentos anteriores, sem criar propriedade
obrigatória nova. Os schemas 0.1 a 0.4 ficam intactos. Validação, diff e link aceitam as cinco versões
com suas regras exatas, consultando uma tabela única de recursos por versão.

Um documento 0.1 a 0.4 com `app.rounding` ou `vetra.money_rounding` é recusado. A auditoria do link
normaliza na versão do artefato: conserva o padrão implícito dos grafos antigos, sem materializar campo
ou requisito novos. Uma declaração explícita de `rounding:`, mesmo `half_up`, não pode ser descartada
para produzir uma versão anterior. Não há conversão automática ou novo alvo público de compilação.

### Diff

O diff compara o **modo efetivo**, adotando `half_up` quando o campo está ausente. Tornar o padrão
explícito ou voltar a omiti-lo não altera valores; versão e requisitos continuam aparecendo para revisão.
Trocar o modo efetivo em qualquer direção é **quebra potencial de semântica de valores**, com revisão
obrigatória, no caminho `/app/rounding`, categoria `values`. Isso vale mesmo sem campo `money` atual,
pois a configuração também governa contratos e operações futuras. A comparação não executa cálculos
nem prova que dados existentes serão afetados.

## Alternativas rejeitadas

- Manter a IR 0.4 ou usar `annotations`: esconderia uma decisão que muda valores; viola o ADR-001 §4.
- Tornar `rounding` obrigatório no schema: exigiria nova MAIOR. Produtor e leitor preservam a omissão
  como `half_up`.
- Emitir campo e requisito em todo build: obrigaria consumidores a implementar arredondamento para ler
  grafos que não declaram o recurso, inclusive sem campos `money`.
- Adotar `half_even` como padrão: mudaria o significado dos grafos existentes e a decisão do ADR-017.
- Aceitar todos os modos de uma biblioteca Ruby: ampliaria o contrato por dependência de implementação.
- Arredondar defaults, soma ou subtração: esconderia erros de contrato e introduziria perda de precisão.
- Copiar o modo em cada tipo `money`: duplicaria uma configuração da aplicação e abriria conflitos.

## Consequências

- O mini CRM com revendas pode reproduzir `rounding: :half_up` da proposta.
- Todos os exemplos precisam de rebuild em 0.5 e revisão de versão, sem mudança de valores. Só o mini
  CRM com revendas declara o modo e exige o recurso; blog, chat e mini CRM mantêm o padrão implícito.
- Consumidores futuros devem implementar os dois modos antes de anunciar `vetra.money_rounding`.
- Grafos sem declaração de modo continuam acessíveis a consumidores da IR 0.5 que não implementam esse recurso.

## Testes de aceitação

1. Omissão de `rounding:` produz IR 0.5 sem campo nem requisito, com ou sem declaração de moeda e campos
   `money`. `half_up` e `half_even` explícitos produzem modo canônico e requisito, inclusive sem `money`.
   O digest é determinístico; check, validação com fontes e link conservam esses dados sem executar operações.
2. Tipos e nomes inválidos falham com `money_rounding`; palavras-chave desconhecidas continuam audíveis.
3. IR externa recusa modo inválido e campo sem requisito; schemas anteriores recusam campo e requisito.
4. Artefatos 0.1 a 0.4 continuam validando e vinculando sem mudança; a 0.4 conserva também os comandos
   gerados de vínculo e a 0.3 conserva saídas estruturadas e live.
5. O diff não considera a explicitação de `half_up` mudança de valores; todas as mudanças efetivas de
   modo são quebras potenciais com revisão, inclusive a remoção de `half_even`.
6. Defaults com casas excedentes continuam recusados nos dois modos, inclusive com precisão estendida.

## Garantia

Estrutural: schema fechado, tabela de recursos por versão e validação do requisito recusam contratos
incompatíveis. Verificável por testes: normalização, link, diagnósticos e classificação do diff são
cobertos por `rounding_test.rb` na tarefa `test:diagnostics`. Nenhuma garantia numérica ou transacional
de execução é reivindicada por esta implementação declarativa.

## Questões em aberto

- Execução dos cálculos e seus testes numéricos pertencem ao runtime do ADR-017. Este ADR fixa o
  contrato que eles deverão cumprir, sem adicionar executor à fase 0.

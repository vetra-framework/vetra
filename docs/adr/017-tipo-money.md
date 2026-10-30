# ADR-017: Tipo `money` nativo

- Status: proposto
- Data: 2026-10-30
- Depende de: ADR-001 (Grafo da Aplicação e IR)
- Relacionados: ADR-016 (ciclo de vida da operação), ADR-013 (histórico e auditoria)

## Contexto

Dinheiro é onde pequenos erros viram dinheiro de verdade. Os problemas conhecidos se repetem em quase toda
aplicação comercial:

- **Ponto flutuante.** `0.1 + 0.2` dá `0.30000000000000004` em `Float` e `0.3` em decimal exato. Somas e
  rateios com `Float` acumulam centavos que não existem.
- **Valor sem moeda.** Um número solto não diz se são reais ou dólares; somar os dois é um erro silencioso.
- **Formato misturado com valor.** `"1.234"` é mil duzentos e trinta e quatro no Brasil e um vírgula
  duzentos e trinta e quatro nos Estados Unidos. Guardar ou calcular com o formato de exibição é a origem de
  erros de separador.
- **Perda de precisão em JavaScript.** Um número JSON grande passa por `double` no cliente.
- **Arredondamento espalhado.** Cada tela arredonda de um jeito, e o total não bate com a soma das parcelas.

O Rails resolve boa parte com as gems `money` e `money-rails`. A vantagem do Vetra, como diz a proposta, está
na **integração por padrão**: contrato, tipos TypeScript, validação no grafo e idioma por requisição, sem
configuração.

## Decisão

**`money` é um tipo nativo do núcleo: um valor decimal exato e uma moeda, sempre juntos. O valor e o cálculo
nunca carregam formato; a apresentação só existe na borda.**

O desenvolvedor declara apenas `money :valor`. Moeda, precisão, arredondamento, formato e interpretação da
entrada vêm da configuração do tenant e do idioma de quem vê a tela.

### 1. Representação

| Camada | Forma |
|---|---|
| Entidade e IR | Campo do tipo `money`, com `precision` e `scale` (padrão 19 e 2); o schema 0.1 e o protótipo já o representam |
| Banco | Valor `numeric(precision, scale)` e código de moeda ISO 4217 (três letras), em colunas que existem juntas: ou as duas são nulas, ou nenhuma é, garantido por `CHECK` |
| API e eventos | Canônica: `{ "amount": "1234.56", "currency": "BRL" }`, com `amount` **string** |
| Literal na IR | A mesma forma canônica (ADR-001) |

- A moeda padrão é declarada na aplicação (`currency "BRL"`, que o protótipo já tem) e, como diz a proposta,
  pode ser a de cada tenant (ainda não implementado). Na entrada, `currency` pode ser omitida e assume a padrão;
  na saída, os dois campos sempre aparecem.
- O valor é decimal exato em todo o caminho (`BigDecimal` em Ruby, `numeric` no banco). Nunca `Float`.
- `precision` e `scale` são por campo. Transações usam as casas da moeda; preços unitários podem declarar mais
  casas (por exemplo, `scale: 4`).

### 2. `Float` é recusado

- O grafo recusa `Float` em campo monetário: literal na IR, `default` e valor derivado. A serialização
  canônica da IR já recusa qualquer número de ponto flutuante (o protótipo implementa isso).
- Em tempo de execução, uma entrada JSON cujo `amount` seja número (e não string) é recusada com erro de
  contrato (422, ADR-016). Aceitar número reintroduziria a perda de precisão que a string evita.
- O protótipo já valida os `default` literais de `money` e `decimal`: texto decimal, até `precision - scale`
  dígitos inteiros e `scale` casas.

### 3. Aritmética

- Somar, subtrair e comparar valores só é permitido na **mesma moeda**. `BRL + USD` é erro, nunca conversão
  implícita.
- Conversão entre moedas é uma operação explícita, com **taxa e data registradas** no resultado.
- Uma agregação que soma valores (`SUM`) agrupa por moeda. Somar sem agrupar quando existem moedas diferentes é
  erro, não um total sem sentido.

### 4. Arredondamento e rateio

- Arredondamento padrão **comercial (meio para cima)**, configurável por tenant. Arredonda **ao persistir e
  ao exibir**, nos pontos definidos, e não no meio de uma conta.
- **Rateio exato.** Dividir um total em N partes distribui o resto em unidades mínimas, uma a uma, a partir da
  primeira parcela, de modo que a soma das partes seja exatamente o total:

  | Total | Partes | Resultado |
  |---|---|---|
  | R$ 100,00 | 3 | 33,34 + 33,33 + 33,33 |
  | R$ 0,10 | 3 | 0,04 + 0,03 + 0,03 |
  | ¥ 100 (sem casas) | 3 | 34 + 33 + 33 |

  A unidade mínima vem do expoente da moeda (ISO 4217: 2 para BRL e USD, 0 para JPY, 3 para BHD), não de uma
  constante.

### 5. Apresentação e entrada, só na borda

| Aspecto | pt-BR | en-US |
|---|---|---|
| Exibição de BRL / USD | `R$ 1.234,56` / `US$ 1.234,56` | `R$1,234.56` / `$1,234.56` |
| Separador decimal | vírgula | ponto |
| Separador de milhar | ponto | vírgula |
| Entrada `"1.234"` em formulário | mil duzentos e trinta e quatro | um vírgula duzentos e trinta e quatro |

- **Moeda não é idioma.** Um americano vendo reais vê `R$1,234.56`; um brasileiro vendo dólares vê
  `US$ 1.234,56`. O símbolo vem da moeda; o formato, do idioma.
- Em pt-BR, o espaço entre o símbolo e o número é um **espaço não separável** (U+00A0). Comparar com um
  espaço comum falha, e isso é teste obrigatório.
- **Formulários** interpretam a entrada pelo idioma da requisição. **APIs** só aceitam o formato canônico.
- Logs, eventos e histórico guardam a forma canônica, nunca a formatada.

## Alternativas rejeitadas

- **`Decimal` solto com formatação manual** (a alternativa da proposta): cada tela formata e interpreta a
  seu modo, e a moeda fica fora do dado.
- **`Float` com arredondamento no final:** o erro acumulado depende da ordem das contas; não há arredondamento
  que o corrija em todos os casos.
- **Inteiro em centavos:** evita o `Float`, mas fixa duas casas para todas as moedas (JPY tem zero, BHD tem
  três) e obriga a converter em cada borda. O decimal exato com escala por campo cobre os dois usos.
- **Valor e moeda em campos independentes:** permite o estado inválido (valor sem moeda). Tratá-los como um
  tipo só o impede no contrato e no banco.
- **Aceitar `amount` numérico no JSON:** perde precisão em clientes JavaScript.
- **Delegar tudo à gem `money-rails`:** é a escolha certa num app Rails, mas o grafo precisa conhecer o tipo
  para validar contratos, gerar tipos TypeScript e recusar `Float`. O Vetra pode usar uma biblioteca de apoio
  por baixo sem expô-la.

## Consequências

- Sem erros de `Float`, de moeda ou de separador. O total de um rateio sempre fecha.
- Um tipo a mais no núcleo, com a sua tabela de formatos por idioma para manter.
- Dois campos de banco por campo `money`, com a restrição que os mantém juntos.
- Consultas e relatórios que somam valores precisam tratar moeda; o caso comum (uma moeda por tenant) não
  muda para o desenvolvedor.
- O `amount` em string obriga o cliente a usar um decimal, e o SDK TypeScript gerado deve expor o tipo
  adequado.

## Garantias e seus níveis

| Garantia | Nível | Mecanismo |
|---|---|---|
| `Float` não entra no grafo | Estrutural | Serialização canônica da IR e validação dos literais (implementadas no protótipo) |
| Valor e moeda existem juntos | Transacional | `CHECK` no banco, mais o contrato de entrada |
| `amount` numérico na API é recusado | Verificável por testes | Validação do contrato (etapa 2, ADR-016) |
| Moedas não se misturam | Verificável por testes | Erro na aritmética e na agregação |
| O rateio soma o total | Verificável por testes | Teste de propriedade sobre totais, partes e moedas |
| Formatação correta por idioma | Verificável por testes | Testes por idioma, incluindo o espaço não separável |

## Testes de aceitação

1. Um `default` ou literal com `Float` num campo `money` é recusado na compilação.
2. Uma entrada com `"amount": 12.5` (número) é recusada com 422; `"12.50"` é aceita.
3. Uma entrada sem `currency` assume a moeda padrão (da aplicação ou do tenant).
4. `BRL + USD` falha; a conversão explícita registra taxa e data.
5. O rateio de qualquer total em qualquer número de partes soma exatamente o total, para BRL, JPY e BHD.
6. `R$ 1.234,56` em pt-BR usa U+00A0 entre o símbolo e o número, e o teste falha com espaço comum.
7. Um brasileiro vendo USD vê `US$ 1.234,56`; um americano vendo BRL vê `R$1,234.56`.
8. No formulário, `1.234` vale 1234 em pt-BR e 1,234 em en-US; na API, só a forma canônica é aceita.
9. O banco recusa uma linha com valor e sem moeda, e o contrário.
10. Uma agregação sem agrupar por moeda, com duas moedas presentes, falha.

## Questões em aberto

- Como `scale` do campo e expoente da moeda convivem: o valor de uma transação deve ter no máximo as casas
  da moeda, e um preço unitário pode ter mais.
- Onde ficam as taxas de conversão e quem as fornece.
- Configuração de arredondamento por tenant e por campo, e se existem outros modos além do comercial.
- Biblioteca de formatação por idioma que o núcleo usa por baixo (dados de localidade), e como ela é
  testada.
- Moedas sem código ISO 4217 (cripto, pontos de fidelidade): fora do tipo `money` ou tipo à parte.

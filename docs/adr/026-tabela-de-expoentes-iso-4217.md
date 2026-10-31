# ADR-026: Tabela de expoentes ISO 4217 no compilador

- Status: proposto
- Data: 2026-10-31
- Resolve: ADR-017 (questão 4: origem e teste da tabela de expoentes; formatação adiada)
- Depende de: ADR-017 (tipo money), ADR-001 (IR e determinismo)

## Contexto

O ADR-017, §6, já decide que `money` sem `scale` segue o expoente da moeda da aplicação, que uma escala
explícita maior permite precisão estendida e que uma menor é erro. A IR 0.1 já guarda `precision` e `scale`,
mas o compilador usava sempre 2. Aplicar essa decisão exige escolher a fonte dos expoentes, parte da quarta
questão em aberto do ADR-017.

Esta proposta acompanha a implementação para revisão. Seu aceite depende da integração, conforme a
convenção do índice; as outras questões do ADR-017 continuam abertas.

## Questões

### 4. De onde vem a tabela de expoentes ISO 4217 e como é testada

- Tratamento: **decidida** (tabela) e **adiada** (biblioteca de formatação).
- **Fonte proposta:** a lista oficial de moedas e fundos correntes, List One, publicada pela
  [SIX, agência de manutenção da ISO 4217](https://www.six-group.com/en/products-services/financial-information/market-reference-data/data-standards.html).
  O [XML](https://www.six-group.com/dam/download/financial-information/data-center/iso-currrency/lists/list-one.xml)
  consultado em 2026-10-31 tem `Pblshd="2026-09-17"` e SHA-256
  `33139b438657d1cee116ba737807ea71d19d6de4b90f799a09c56f0cc6a1b0ff`.
- O compilador distribui uma tabela local em `lib/vetra/graph/currency.rb`, com os 165 códigos cujo
  `CcyMnrUnts` é numérico. Não consulta a rede durante compilação, validação ou vinculação. O arquivo registra
  URL, data de publicação, data de consulta e hash da fonte. Entradas repetidas por país viram um código só;
  os expoentes de todas as entradas do mesmo código precisam coincidir.
- Um código desconhecido, histórico ausente da lista ou com unidade mínima `N.A.` não ganha um expoente por
  suposição. Se a aplicação usa `money`, falha com `money_currency`, mesmo com `scale` explícito. `N.A.` não
  significa zero; metais e códigos sem unidade mínima definida ficam fora desta primeira tabela.
- A ausência de `scale` é resolvida durante a normalização, depois de carregar a aplicação. `decimal`
  conserva escala padrão 2. A IR continua com a escala numérica explícita e o mesmo schema 0.1: não precisa
  representar a origem desse número enquanto há uma moeda por aplicação.
- O validador também confere escalas de entidades e contratos lidos diretamente de uma IR. Uma escala
  inferior ao expoente da aplicação gera `money_scale`, com ponteiro JSON e origem. Um `default` monetário
  precisa ter moeda com expoente conhecido que caiba no campo, além de respeitar a precisão e a escala;
  falha com `field_default` sem arredondamento silencioso.
- **Manutenção:** a tabela é atualizada por uma mudança revisada no código, com nova versão do compilador
  ao publicar. Baixar a lista oficial, conferir publicação e hash, agrupar códigos por `CcyMnrUnts` numérico,
  comparar adições/remoções/alterações e rodar a suíte. Mudanças que invalidem grafos anteriores precisam
  explicitar a compatibilidade conforme o ADR-001; uma atualização da fonte não autoriza quebra silenciosa.
- **Alternativas rejeitadas:** buscar a lista durante o build (quebra reprodução e exige rede); uma lista
  só de BRL/JPY/BHD (recusa outras moedas representáveis sem motivo); assumir 2 para o código desconhecido
  ou 0 para `N.A.` (inventa precisão); acrescentar biblioteca de formatação só para consultar expoentes
  (acopla a fase 0 à apresentação ainda não implementada).
- **Formatação adiada:** escolher biblioteca e dados de localidade volta quando a borda de UI/API for
  implementada. A tabela não fornece símbolos, separadores, idioma nem arredondamento.

## Consequências

A compilação aplica a regra já aceita de escala por moeda, inclusive em entradas de operações, contratos CRUD
e payloads de eventos. Aplicações com BHD passam a gerar escala 3; as com JPY, escala 0. Artefatos dessas
aplicações precisam ser reconstruídos e revisados. Os quatro exemplos correntes em BRL preservam seus bytes.

Não há aritmética monetária, formatação, moeda por tenant nem validação HTTP em execução. Uma entrada de API
com escala inválida ainda não pode ser exercitada como 422, pois não existe runtime.

## Garantia

**Estrutural e verificável por testes:** `test/money_test.rb` cobre expoentes 0, 2, 3 e 4, escala explícita
igual/maior/menor, precisão insuficiente, defaults exatos, moedas sem expoente, entradas de comando/consulta,
payloads, contratos CRUD, leitura de IR externa e vinculação. A tabela foi comparada integralmente com o XML
de origem nesta mudança; os testes usuais são locais e não dependem da disponibilidade da SIX.

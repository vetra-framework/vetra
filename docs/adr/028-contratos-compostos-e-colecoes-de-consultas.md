# ADR-028: Contratos compostos e coleções de consultas

- Status: aceito
- Aceite: integração direta na main, após validação da implementação e dos exemplos nesta continuação. Confirmado em 2026-11-03 pelo Claude, por delegação do mantenedor, após a auditoria K2.
- Data: 2026-11-02
- Depende de: ADR-001 (IR e compatibilidade), ADR-007 (consultas e contratos), ADR-027 (IR 0.2)

## Contexto

As consultas `my_rooms` e `room_page` do chat retornam uma coleção e um objeto com sala e mensagens.
`returns :room` representa somente um registro. A IR 0.2 tem contratos planos e não distingue um objeto
com campos de uma coleção de objetos. Usar `json` ou anotações esconderia os contratos do grafo e do diff.

## Decisão

- Novos builds usam IR 0.3. Os schemas 0.1 e 0.2 permanecem inalterados; validação, diff e link continuam
  lendo cada versão com seu schema e semântica. O link audita na versão do artefato, sem conversão.
- `returns :room, collection: true` declara uma coleção de registros. O contrato gerado `<consulta>.output`
  guarda `collection: true` e os campos de cada item. Uma coleção vazia é válida; nulabilidade de item não
  é representada nesta versão.
- `returns do ... end` declara campos explícitos de saída. Além dos campos primitivos, `record :room,
  entity: :room` e `collection :messages, entity: :message` referenciam o contrato de registro da entidade.
  O descritor é `{ name: "record" | "collection", contract: <contract_ref> }`. Campos obrigatórios não são
  nulos; `optional: true` permite ausência e null, conforme as demais declarações de campo.
- Esses retornos são suportados em consultas. Comandos mantêm `returns :entidade`; entidades, entradas de
  operação e payloads de evento continuam com campos planos. Um contrato composto não pode ser reutilizado
  por esses contextos. O schema permite a representação; a validação confere o contexto de uso.
- A representação exige `vetra.structured_outputs`. Referências precisam existir, pertencer a um domínio
  declarado e respeitar `depends_on`. Contratos estruturados formam um grafo acíclico. Um campo de registro
  ou coleção aponta para um contrato de objeto, nunca para outro contrato raiz de coleção.
- O compilador deriva a classificação pessoal de um campo composto dos campos do contrato referenciado.
  Uma IR externa que rebaixe essa classificação é recusada. Isso descreve dados pessoais no contrato;
  a autorização e a projeção de campos em execução continuam a cargo do futuro runtime.
- O diff propaga o uso de saída pelos contratos referenciados: perder campos ou garantias em um registro
  aninhado é quebra de saída. Trocar objeto por coleção, ou o contrário, também é quebra. Não se infere
  a forma do retorno executando Ruby nem analisando o fluxo de dados do corpo.

## Exemplos

```ruby
query :my_rooms do
  returns :room, collection: true
  authorize :read, :room
  uses :rooms
  call { |_input, rooms| rooms.order(:name).all }
end

query :room_page do
  input :room_id, :id
  returns do
    record :room, entity: :room
    collection :messages, entity: :message
  end
  authorize :read, :room, record: :room_id
  uses :rooms, :messages
  call do |input, rooms, messages|
    room = rooms.find!(input.room_id)
    { room: room, messages: messages.where(room_id: room.id).order(:created_at, :id).last(100) }
  end
end
```

## Alternativas rejeitadas

- `returns :room` para uma lista: declara um contrato incompatível com o retorno real.
- `json` genérico: perde referências, privacidade e direção de compatibilidade dos campos.
- Inferir Ruby arbitrário: não resolve caminhos dinâmicos e exigiria uma garantia que o compilador não oferece.
- Alterar os schemas anteriores: aceitaria um novo significado com consumidores que o desconhecem.

## Limites e próximos passos

Não há execução de consultas, serialização HTTP, autorização em execução, paginação por cursor nem live.
O exemplo limita as mensagens a 100, com desempate por ID, e consulta registros simples: expansões de
relações como `with(:author)` e `with(:members)` ainda precisam de contratos explícitos próprios.
Coleções de escalares, listas de listas e contratos recursivos ficam fora deste incremento.

## Garantia

Estrutural e verificável por testes: contratos normalizados e tipados, referências e ciclos, classificação
pessoal, fronteiras de capacidade, contextos proibidos, digests, diffs de campos aninhados, vínculos em
0.1/0.2/0.3 e corpos do chat exercitados com repositórios em memória. Esses testes não são um executor.

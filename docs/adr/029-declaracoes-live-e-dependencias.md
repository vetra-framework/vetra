# ADR-029: Declarações live e dependências verificáveis

- Status: aceito
- Aceite: integração direta na main, após validação da implementação e dos exemplos nesta continuação. Confirmado em 2026-11-03 pelo Claude, por delegação do mantenedor, após a auditoria K2.
- Data: 2026-11-03
- Depende de: ADR-001 (IR e recursos), ADR-004 (capacidades), ADR-020 (entrega live), ADR-028 (saídas de consultas)

## Contexto

A IR já representa `query.live` com modo e entidades de dependência, mas o DSL recusa `live true`.
As consultas do chat já têm contratos explícitos. O próximo passo declarativo é registrar quais mudanças
podem invalidar uma consulta, incluindo as tabelas que definem sua autorização.

## Decisão

- A declaração é suportada pelo compilador na IR 0.3, com `vetra.live` em `requires`. O formato existente
  não muda. Os consumidores anteriores continuam recusando o recurso desconhecido; as semânticas de
  leitura de 0.1 e 0.2 são preservadas. A versão do compilador passa a `0.1.0-alpha.4`.
- Somente consultas podem declarar `live`. `live true` usa `mode: :strict`, inclusive sem tenant;
  `mode: :balanced` é uma opção explícita, sujeita à revisão do diff. `live false` desativa a declaração
  e não aceita opções adicionais. Declarações repetidas, valores e modos inválidos falham.
- `depends_on:` pode informar entidades adicionais. Sem a opção, o compilador calcula um conjunto
  conservador a partir da entidade autorizada, dos repositórios recebidos e dos contratos de saída.
  Referências tipadas a entidades nos contratos e seus contratos filhos também entram no conjunto.
- O conjunto inclui o fechamento das leituras das políticas de leitura dessas entidades, além da ação
  explícita de autorização da consulta. As relações e junções já constam em `policy.reads`; a validação
  dessas leituras continua obrigatória. As dependências de autorização das entidades extras também
  precisam estar declaradas. A lista final é única e ordenada por identidade.
- Uma lista explícita não pode omitir dependências conhecidas. Ela pode acrescentar leituras que o
  analisador não descobre. Análise Ruby incompleta exige uma lista explícita e mantém o aviso existente.
  `unsafe_effect` e capacidades de SQL ou efeitos externos são incompatíveis com live neste protótipo;
  repositórios de leitura e capacidades determinísticas permanecem permitidos.
- O validador aplica essas regras também à IR externa: exige o recurso, confere referências e recusa a
  omissão de dependências conhecidas. O diff classifica alterações de live como dependências e permissões,
  porque o modo afeta a garantia prevista de revogação.

## Exemplo

```ruby
query :room_page do
  input :room_id, :id
  returns do
    record :room, entity: :room
    collection :messages, entity: :message
  end
  authorize :read, :room, record: :room_id
  uses :rooms, :messages
  live true
  call do |input, rooms, messages|
    room = rooms.find!(input.room_id)
    { room: room, messages: messages.where(room_id: room.id).order(:created_at, :id).last(100) }
  end
end
```

O chat depende de `room`, `message`, `room_membership` e `user`. A junção entra pelas políticas de
membros, mesmo sem ser uma capacidade direta da consulta. Alterar sua composição precisa invalidar a
assinatura no futuro runtime.

## Limites

A lista é conservadora, não mínima. Uma referência de ID na saída ou uma leitura de política pode provocar
invalidação adicional. Ela também não prova a completude de Ruby arbitrário: helpers, aliases e leituras
não declaradas continuam fora da garantia da análise, mesmo com uma lista explícita.

Não há assinaturas em execução, trigger de revisão, trigger de mudança de linha, transporte WebSocket/SSE,
renderização em grupo ou revogação em execução. O compilador representa e verifica o contrato; a entrega
real e as garantias transacionais do ADR-020 continuam pendentes. `realtime` na configuração da aplicação
permanece recusado até existir um adaptador.

## Garantia

Estrutural e verificável por testes: modos e opções, limites de capacidade, derivação de dependências,
políticas e junções, leituras extras, análise incompleta, leitura de IR externa, determinismo, diff e
vinculação sem executar o corpo. Os schemas anteriores permanecem inalterados.

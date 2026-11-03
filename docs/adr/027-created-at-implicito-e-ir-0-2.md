# ADR-027: `created_at` implícito e IR 0.2

- Status: aceito
- Aceite: 2026-11-02, na revisão e correções solicitadas pelo mantenedor; código já integrado na main.
- Data: 2026-11-02
- Depende de: ADR-001 (IR e compatibilidade), ADR-003 (repositórios), ADR-004 (relógio determinístico)

## Contexto

O chat da proposta usa `index :room_id, :created_at` e ordena mensagens pela data de criação sem declarar
esse campo. O compilador não o gera. A IR 0.1 só representa geração de slug; acrescentar uma regra de
relógio por convenção de nome deixaria parte do comportamento fora do grafo.

A implementação foi integrada e o aceite foi registrado nesta revisão. Nenhum runtime é implementado
nesta continuação.

## Decisão

- O compilador passa a produzir IR 0.2. Cada entidade, inclusive a raiz de tenant e junções geradas, recebe
  um `created_at` obrigatório, não nulo, do tipo `timestamp`, com
  `generate: { kind: "timestamp", on: "create" }`. O nome fica reservado nas entidades, como `id`.
- O documento exige `vetra.timestamps`. A capacidade do consumidor de entender a geração é explícita;
  remover o requisito sem remover a representação falha. Quando o requisito está presente, todas as
  entidades precisam ter o campo com essa forma. A geração só é válida no campo `created_at` de entidade,
  sem default, `set_by`, `guarded`, normalização ou constraints concorrentes.
- O campo aparece nos contratos de registro, em projeções de eventos e em índices. A regra de geração
  pertence à entidade e não é copiada para o contrato de saída. Entradas CRUD de criação e atualização
  omitem o campo: ele não é entrada do cliente.
- Gravações literais reconhecidas por repositório não podem atribuir `created_at`, nem em `create!`.
  A atribuição pertence ao futuro repositório, usando seu relógio determinístico de criação; nenhuma
  chamada a `Time.now` é executada na compilação. O analisador mantém os limites de aliases e fluxo de
  dados do ADR-004.
- O valor será fixado uma vez na criação e preservado em atualizações. O runtime deve compartilhar o
  relógio da operação e da simulação; a política de fuso e precisão na borda volta com a persistência.
- `updated_at`, desligamento ou substituição da geração e preenchimento de dados antigos ficam adiados
  até o desenho das migrações e do repositório. A mudança do grafo não preenche linhas existentes.

## Compatibilidade

O schema 0.1 permanece inalterado. Validação, diff e vinculação continuam lendo 0.1 com suas próprias
regras, sem inventar timestamps. O link recompila a auditoria na versão do artefato; build e check usam
0.2. Um artefato 0.1 deve ser reconstruído e revisado para adotar a geração. Versões futuras e recursos
não implementados continuam recusados. O schema 0.2 é fechado e distribuído na gem.

A adição de campo gerado é aditiva no diff. A mudança de versão aparece como revisão de contrato; novos
requisitos e índices também exigem revisão. Nenhum dado de produção é migrado pelo compilador.

## Alternativas rejeitadas

- Declarar um timestamp obrigatório comum: permitiria ao cliente escolher a data nas entradas CRUD.
- Usar `set_by: :create_message`: declara um comando dono, mas não representa a origem do valor no relógio.
- Mudar o schema 0.1 ou usar `annotations`: consumidores antigos poderiam aceitar uma semântica que desconhecem.
- Acrescentar `updated_at` junto: atualização, operações sem mudança e migrações precisam de decisões próprias.

## Garantia

**Estrutural e verificável por testes:** entidades com e sem tenant, junção implícita, índice do chat,
contratos CRUD e de registro, projeção em evento, determinismo, recusa de nomes reservados e gravações,
IR externa inválida, vínculo de 0.1 e 0.2, leitura do schema exato e diff entre versões.
A atribuição e a imutabilidade no banco dependem do runtime e ainda não têm garantia transacional.

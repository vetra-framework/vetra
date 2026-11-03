# ADR-032: Comandos gerados de vínculo de many_to_many

- Status: aceito
- Aceite: 2026-11-03, pelo Claude por delegação do mantenedor, após a auditoria da C1 (`58993e2`).
- Data: 2026-11-03
- Depende de: ADR-001, ADR-007 e ADR-016

## Contexto

A proposta gera inclusão e remoção a partir de `many_to_many`. O compilador já representa a relação e a
junção, mas o chat declara `add_member` e `remove_member` em Ruby, incluindo a regra de preservar o dono.
Precisamos de uma geração determinística que não substitua código da aplicação nem conceda permissões.

## Decisão

1. Novos builds geram dois comandos por relação, por padrão, com ou sem junção explícita. O nome é
   `<domínio>.add_<relação no singular>` e `<domínio>.remove_<relação no singular>`: `members` produz
   `add_member` e `remove_member`. Usa-se a mesma regra mínima de singular da junção (consoante + `ies`
   vira `y`; retira-se `s` final, exceto em `ss`). Não há inflexão por idioma nem renomeação configurável.
2. `commands: false` desliga ambos os comandos daquela relação, mantendo junção, políticas, repositórios e
   `include:`. `commands: true` explicita o padrão. Outros valores são erros. Nomes que colidem com comandos,
   consultas, handlers ou outra geração são recusados com origem e orientação para desligar a geração ou
   renomear a declaração. Comandos explícitos nunca sobrescrevem nem são sobrescritos silenciosamente.
   O chat usa `commands: false`, preservando os corpos e exposições que já possui.
3. Cada entrada contém somente `<dono sem domínio>_id` e `<alvo sem domínio>_id`, obrigatórios, não nulos e
   tipados para suas entidades. Nomes iguais entre os dois lados são recusados. O retorno é o contrato de
   registro do dono. `authorize` exige a ação `add_<singular>` ou `remove_<singular>` sobre o dono, com
   `record` no ID dele. Usa-se somente seu repositório `read_write`, inclusive quando seu nome é customizado.
   Nenhuma política, rota, evento ou closure Ruby é gerada. Sem política aplicável, não há concessão implícita.
4. A implementação é um descritor `builtin` chamado `many_to_many.add.<relação>` ou
   `many_to_many.remove.<relação>`. A entidade de `authorize` identifica o dono, e a relação identifica alvo,
   junção, chaves e `include_on_create`. `generated_from` aponta o dono. Embora use campos já existentes,
   o descritor introduz semântica nova: novos builds usam a **IR 0.4**, com o requisito
   `vetra.relation_commands`, conforme o [ADR-001 §4](001-grafo-da-aplicacao-e-ir.md#4-compatibilidade-e-evolução).
   O schema 0.4 é fechado, autocontido e distribuído na gem; os schemas publicados 0.1/0.2/0.3 permanecem
   inalterados. Validação, diff e link aceitam essas versões com suas semânticas exatas, sem geração
   retroativa. Uma IR 0.3 com esse requisito ou com uma primitiva de vínculo é recusada. A mudança de
   `ir_version` aparece no diff como revisão, sem quebra. A versão da gem não muda nesta entrega.
5. O descritor significa incluir/remover o par de IDs pela junção, dentro do escopo do tenant, retornando o
   dono. A futura execução deve autorizar e travar o dono antes da alteração, conferir os dois registros,
   garantir inclusão sem duplicação e remoção de vínculo ausente sem erro. A remoção deve recusar qualquer
   alvo que corresponda aos `belongs_to` de `include_on_create`, preservando vínculos obrigatórios como o
   proprietário do chat. `include:` na criação continua sendo metadado; esta entrega não implementa executor.
6. A geração exige uma junção com os dois vínculos não opcionais e chaves coerentes, tenant consistente e
   índice único exatamente sobre o par (incluindo o tenant quando houver). Campos adicionais obrigatórios
   ou não nulos precisam de default ou geração; campos protegidos por `set_by`/`guarded` não são preenchidos pela primitiva.
   Uma junção que precisa de mais informação exige comandos explícitos e `commands: false`.
7. O validador confere também IR externa: recurso, relação, junção elegível, autorização, origem, entrada,
   saída, repositório e ausência de efeitos extras. O link reconhece os descritores com `executor: pending`.
   Build, validação e link não executam código de negócio.
8. O diff compara comandos e contratos gerados como os demais nós. Adições são aditivas e exigem revisão
   de permissões/capacidades; remoções (inclusive ao desligar geração) são quebras potenciais. Mudanças em
   `authorize`, `uses` e descritor exigem revisão, e contratos seguem as regras direcionais existentes.
   A troca de primitiva por Ruby no mesmo ID exige revisão de implementação; não se infere equivalência.
   Alterar a relação usada por uma primitiva (incluindo `through` ou `include_on_create`) exige também revisão
   de implementação e permissões, pois altera o significado do descritor mesmo mantendo seu nome.
   `commands:` não vira anotação da IR: o diff mostra seus efeitos nos nós e em `requires`.

## Alternativas rejeitadas

- Substituição automática por comandos explícitos: esconderia uma geração incompleta ou uma regra diferente.
- Prefixar sempre o dono (`add_room_member`): diverge da nomenclatura da proposta. Colisões exigem escolha
  explícita da aplicação; nomes customizados podem ser declarados em Ruby com a geração desligada.
- Gerar HTTP e permissões: a relação não define quem pode alterar vínculos nem uma superfície pública.
- Guardar execução em `annotations`: anotações não podem alterar semântica ou segurança.

## Consequências

Relações existentes adotam a geração após rebuild e revisão. O chat mantém seus comandos explícitos.
`crud` é opt-in, enquanto os comandos de vínculo são opt-out: a geração fica ligada por padrão e precisa
de `commands: false` para ser desligada. O padrão foi mantido no aceite: a declaração `many_to_many` já é a
escolha explícita da aplicação, como a linha `crud`; os comandos gerados não ganham rota, política nem
concessão, e o diff os mostra como adição a revisar. Assim a geração segue a proposta sem ampliar a superfície.
Junções com dados de negócio, nomes ambíguos ou colisões precisam desligar a geração. O diff não atribui
segurança à mera presença de uma política nem prova equivalência de Ruby.

## Garantia

Estrutural e verificável por testes: compilação determinística, contratos e autorização tipados, recusas
diagnosticadas, validação de IR externa, link sem executor, compatibilidade de artefatos anteriores e diff.
Atomicidade, RLS, idempotência, locks e preservação dos vínculos na execução dependem do futuro runtime e de
testes transacionais em PostgreSQL; os descritores não demonstram essas garantias operacionais.

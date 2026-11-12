# ADR-044: Entrada e autorização em Ruby

- Status: proposto
- Data: 2026-11-10
- Depende de: ADR-003, ADR-005, ADR-016, ADR-020, ADR-021, ADR-022, ADR-024 (§4), ADR-034 e ADR-037
- Implementação posterior: a recusa de concessão limitada (`data_authorization_rate_limit`) deu lugar à reserva de contadores do [ADR-051](051-contadores-duraveis-de-limite-de-taxa.md) (C17); o texto abaixo não muda

## Contexto

As etapas 2 e 3 do ADR-016 precedem a abertura da unidade de trabalho. `UnitOfWork#read` também abre
transação; usá-la para descobrir que um ator não tem acesso violaria a promessa de recusa sem transação.
O plano protege tenant e parte do escopo nos CRMs, mas deixa papéis, campos e comandos na aplicação
(ADR-037). Blog e chat são globais e dependem dessa barreira Ruby. O DSL ainda recusa `auth`; não existe
autenticação do framework da qual se possam deduzir papéis.

Outra ambiguidade aparece em `chat.add_member_by_email`: `authorize` exige ser dono da sala, mas o
`call` consulta `users_read` sem haver política de leitura de `chat.user`. Uma capacidade de repositório
indica um recurso usado pelo código; a IR não declara quais campos/linhas dessa leitura seriam uma
exceção às políticas. A decisão precisa ser explícita antes da autorização dos acessos da K18.

## Decisão

### 1. Fatos resolvidos antes da operação, sem transação de admissão

Escolhemos uma borda confiável que entrega **fatos já resolvidos**, através de um `Snapshot` imutável:
papéis completos do ator, revisão de autorização e registros necessários aos predicados e ao registro
referenciado. A fábrica do avaliador vincula o snapshot à instância que validou a IR e à tupla
`(scope, tenant_id, actor_id, system_actor)`. Não se reutilizam fatos entre catálogos, atores ou tenants.
Cada entidade fornecida contém a seleção completa necessária ao percurso da política; uma lista vazia
afirma ausência, enquanto uma entidade/campo ausente significa informação insuficiente e recusa. Não
se prova uma negação com dados incompletos. A borda entrega valores tipados de registros persistidos,
nunca um registro enviado pelo cliente como prova de propriedade ou de vínculo.

O avaliador não recebe pool, unidade nem repositório. `current_revision:` é uma função da borda que
confirma a revisão corrente para o contexto, sem acessar o pool da operação; deve ser uma confirmação
autoritativa, não apenas o número que veio no próprio snapshot. A igualdade é conferida antes de ler os
fatos e novamente antes de permitir. Ausência, divergência e falha dessa confirmação recusam com
`data_authorization_snapshot`, sem transportar a exceção do provedor. A revisão pode ser um marcador
composto imutável, por exemplo `[revisao_do_tenant, geracao_da_identidade]`.

**Contrato de atualização e invalidação da borda:**

1. A resolução lê registros, vínculos e revisão de forma consistente. Nos CRMs, usa a revisão
   transacional de `vetra.authz_revisions` do ADR-020/030/031. Mudanças externas de papéis/identidade
   acrescentam uma geração própria ao marcador; não se presume que um trigger conheça o SSO.
2. Antes de admitir outra operação depois de uma alteração confirmada, a autoridade publica o novo
   marcador e invalida os fatos antigos. A borda só publica o snapshot substituto depois de reconciliar
   todos os fatos que a política usa. Uma perda de continuidade, atraso de invalidação ou indisponibilidade
   deixa a confirmação indisponível e o avaliador recusa. Um consumidor de NOTIFY eventualmente
   consistente, sozinho, **não** cumpre esse contrato. É preciso uma confirmação atual ou um protocolo
   de concessão com validade coordenada com quem muda a autorização.
3. Blog e chat não ganham tenant nem revisão SQL fictícios. A borda mantém uma geração autoritativa
   global, abrangendo mudanças de registros usados nas políticas e de atribuições de papéis. Sem essa
   autoridade não há execução autorizada. Um relógio/TTL isolado não prova que não houve revogação.
4. Um snapshot não é uma autorização permanente. A K17 integra o provedor de fatos e revisão; a K18
   reautoriza os acessos e o estado final, usando os fatos atuais e respeitando o comando externo. O RLS
   dos CRMs continua verificando os vínculos atuais no banco. Como no ADR-020, uma operação cuja admissão
   já começou antes do commit de uma revogação pode terminar essa admissão; não se promete ordenação
   distribuída estrita. A C13 não implementa esse provedor, um cache distribuído ou o protocolo de concessão.

O teste de aceitação 1 do ADR-016 conserva a exigência de **zero transações da operação recusada**,
inclusive transações somente leitura, implícitas e savepoints, e zero aquisição do pool pelas etapas 2/3.
A medição começa na chamada ao avaliador, com fatos e confirmação disponíveis; a resolução anterior
pela borda é um trabalho separado, medido separadamente. Não é permitido esconder uma chamada a
`UnitOfWork#read` dentro de `check`, `current_revision` ou de uma resolução preguiçosa. Um chamador que
resolva fatos no banco a cada chamada paga esse custo antes da admissão e não pode anunciar zero
transações do fluxo completo desde a obtenção da identidade. Essa distinção integra o contrato público.

### 2. `uses` de leitura exige permissão explícita

`uses` **não concede** uma permissão implícita de dados. A admissão pela política `authorize` permite a
ação principal sobre a entidade/registro indicado; não libera todas as leituras/escritas do corpo. A
K18 autoriza cada acesso adicional por ação, registro e campos, sempre dentro do tenant/escopo do ator.
Uma capacidade `read` continua sendo necessária, mas não substitui uma política aplicável de leitura.

Portanto, a etapa 3 pode admitir `chat.add_member_by_email` para o dono da sala, mas a K18 deverá recusar
o acesso a `users_read` com o grafo atual. Tornar esse caso executável exige uma futura decisão de
permissão explícita do modelo, com projeção/filtro adequados; esta tarefa preserva os exemplos. Não se
infere uma exceção de campos a partir de `where(email).first(2)`: hoje o repositório devolve o registro
inteiro. No CRM, uma concessão Ruby nunca amplia o RLS e a ausência de RBAC SQL nas tabelas sem escopo
não concede RBAC Ruby. O limite é o mesmo do ADR-003: capacidade e autorização são requisitos cumulativos.

### 3. Papéis vêm exclusivamente da borda confiável

O chamador interno confiável resolve a identidade, o tenant e a atribuição completa de papéis no domínio
da aplicação. Pode fazê-lo a partir da identidade autenticada do hospedeiro ou de vínculos persistidos,
segundo o contrato anterior. Os papéis **não** vêm de parâmetros de entrada, cabeçalhos não verificados,
um nome de role SQL ou uma inferência de que todo UUID tem o papel `authenticated`.

O avaliador verifica contexto canônico (`Data::Context`), compatibilidade de escopo com a aplicação,
comando do contexto, vínculo do snapshot, atualidade da revisão e existência dos IDs completos dos papéis
na IR. Um papel não anônimo exige `actor_id`. A autenticidade dessa atribuição pertence à borda: uma
função Ruby no mesmo processo não autentica o chamador nem defende contra código comprometido (ADR-005).
Depois de selecionar as políticas dos papéis atribuídos, o avaliador ainda verifica os seus predicados:
declarar `crm.gerente` não fabrica um vínculo de gerente numa revenda.

Ausência de papéis significa **visitante**: só as políticas de papéis `anonymous: true` se aplicam. Essas
políticas também se somam às de um ator identificado, como exige o ADR-034. Sem papel anônimo na IR não
há concessão de visitante. `actor_id: nil` não é o ator de sistema: qualquer contexto com `system_actor`
é recusado com `data_authorization_system_actor`. Seu caminho por `calls` é exclusivamente da K18.

### API, entrada e semântica das políticas

O namespace é `Vetra::Execution`, carregado explicitamente por `require 'vetra/execution'`. Ele trata
admissão de operações, acima dos repositórios e da unidade do `Vetra::Data`; evita misturar autorização
com persistência e mantém o compilador sem carga de Sequel/pg. Os erros são `Vetra::Data::Error` e usam
diagnósticos de dados, sem valores, SQL ou exceções de provedores na mensagem/causa.

`Authorization#validate_input` valida o contrato do comando ou consulta e devolve hash com chaves String,
imutável em profundidade. Usa `Values.coerce` para tipos, nulidade, enum, comprimento, normalização,
decimal, dinheiro, datas, timestamp e JSON; rejeita campos extras e chaves duplicadas String/Symbol.
Preserva ausência opcional, distinta de NULL. `data_value` aponta o campo do contrato; campos extras
usam `data_input_fields`, sem reproduzir a chave recebida. O CRUD já recebe o contrato que omite
`set_by` e retira valores `guarded` (ADR-021); não se altera o contrato para permitir transições.

`Execution::Input` percorre também `record`/`collection` e coleções raiz de contratos existentes, com
ponteiros aninhados. A IR 0.6 **proíbe essas estruturas na entrada de comandos**; os quatro exemplos não
têm um comando com entrada aninhada. Os testes recursivos usam a saída real de `chat.room_page` e
`chat.my_rooms`, sem relaxar o validador, modificar modelos ou anunciar uma entrada que a IR não aceita.

`Authorization#check` executa entrada e autorização e devolve `Result` com `allowed?`, `diagnostics`,
`code`, `input` normalizada (somente se permitido) e `policy_ids` sem limite que sustentam a permissão.
Não despacha o `call`. `validate_input` isolado levanta `Data::Error`; `check` converte os erros de dados
em resultado de recusa. `inspect` dos fatos e resultados não mostra dados nem identidade.

O avaliador aceita `true`, AND, OR, NOT, igualdade, IN literal, `actor.id`, campo escalar local e EXISTS
por `belongs_to`/`has_many`/`many_to_many`, inclusive percursos com mais de uma relação e EXISTS aninhado. Filtra tenant
no registro principal e a cada salto, usando as chaves locais/remotas da IR. Em `many_to_many`, inverte
a FK da junção para o dono (chaves remotas do dono → locais da junção) e segue a FK da junção para o
alvo (locais da junção → remotas do alvo). As chaves compostas são comparadas inteiras; qualquer componente
NULL impede o casamento. Junção e alvo são filtrados pelo tenant do contexto em cada salto, inclusive
quando outro salto ou EXISTS vem depois. Avalia NULL com lógica de
três valores do SQL: igualdade com literal NULL corresponde a `IS NOT DISTINCT FROM`, e os demais
operandos NULL conservam o desconhecido sob NOT/IN. Uma política só concede se o resultado é `true`.
Literais de comparação são tipados pelo outro operando, como no SQL (UUID canônico, data, timestamp e
número exato), sem normalizar texto ou aplicar as restrições de entrada do campo. Comparações de famílias
incompatíveis e conversões sem suporte recusam com o mesmo código de predicado, inclusive sob NOT.
Em aplicações globais, os mesmos operadores funcionam sobre os fatos globais fornecidos pela borda;
isso não acrescenta RLS. Caminhos de campo compostos, money/JSON composto e operandos
fora desse subconjunto recusam com `data_authorization_predicate`. O percurso inteiro de **todas** as
políticas candidatas é conferido antes da avaliação; nem OR com true nem outra concessão esconde uma
política candidata sem suporte.

**Emenda C16.** O percurso pelas duas FKs torna executáveis as três políticas do chat baseadas em
`members` (ler sala, ler e criar mensagem por `room → members`), antes recusadas. O EXISTS quantifica
os alvos efetivamente vinculados, sem inferir que propriedade da sala equivale a associação. A junção
e o alvo integram `Predicate#traversed`, `Authorization#fact_plan` e `#policy_entities`: o provedor lê
ambos e o Runner invalida snapshots quando um comando escreve na junção. Todas as entidades percorridas
devem estar presentes no snapshot, mesmo se um salto anterior estiver vazio; lista vazia afirma ausência,
entidade omitida recusa. `DatabaseFacts` lê `chat.room_membership` inteira, com limite padrão de 10.000
linhas por entidade (consulta até 10.001 e recusa excesso, sem truncar). A extensão evita deixar metade
das políticas do chat inexecutável e usa as chaves já descritas na IR, sem mudar o subconjunto SQL do
ADR-037 nem inventar RLS para o chat (ADR-031).

Um `record:` seleciona OLD pelo ID validado da entrada, nos fatos persistidos e no tenant corrente.
Ausente, invisível ou sem concessão produzem a mesma recusa. Criação CRUD usa os campos fornecidos,
defaults tipados da entidade e o tenant do contexto para avaliar o candidato. Não se inventa associação
entre parâmetros de um comando Ruby arbitrário e campos da entidade: informação insuficiente recusa.
Consulta sem `record:` que precise de uma linha também não recebe aprovação irrestrita; filtragem dos
acessos de coleção é da K18. A avaliação de NEW na atualização continua na etapa 6, fora desta entrega.

Permissões por campo somam a cobertura das políticas cujo papel e predicado se aplicam à mesma linha.
O CRUD create/update exige todos os campos **fornecidos** (exceto o identificador de `record:`); defaults
e campos gerados pela infraestrutura não viram campos fornecidos pelo cliente. Leituras e comandos
Ruby exigem todos os campos da entidade por padrão. `fields:` é uma projeção/lista efetiva fornecida
pela borda confiável para integração na K18; nunca reduz os campos já fornecidos no CRUD. Ela não é um
parâmetro público do cliente nem autoriza os campos adicionais do `call` antecipadamente.

Se as concessões aplicáveis não cobrem os campos, a recusa é `data_authorization_fields`. Se cobrem,
mas dependem de alguma concessão limitada para completar essa cobertura, a recusa é
`data_authorization_rate_limit`. Uma cobertura completa por concessões sem limite permite sem consumir
cota, mesmo que também existam políticas limitadas aplicáveis. Não há contador ou simulação de cota.

## Alternativas rejeitadas

1. **Transação curta somente leitura para resolver concessões durante a admissão.** Seria mais simples
   integrar os repositórios atuais, mas alteraria expressamente a etapa 3 e o teste 1 do ADR-016. Os
   snapshots preservam esse contrato ao custo de uma autoridade de revisão na borda. Usar read sem
   contar sua transação ou confiar apenas em TTL/NOTIFY não é uma terceira alternativa válida.
2. **Concessão implícita por `uses`.** Tornaria `chat.add_member_by_email` executável, mas concederia leitura de
   registros inteiros e campos pessoais sem uma política revisável, e o escopo dessa autoridade não
   está expresso na IR. Inferir acesso apenas aos campos citados no corpo tampouco cobre métodos
   dinâmicos, retorno do registro e alterações posteriores do código. O preço da escolha explícita é
   manter a leitura adicional desse comando recusada na K18 até uma decisão do modelo.
3. **Papéis inferidos do login do framework, do SQL, do nome `authenticated` ou da entrada.** Não há
   login do framework nem claim de papel na IR/contexto assinado. Essas inferências concederiam acesso
   sem prova de atribuição. O chamador confiável já é a fronteira prevista para o executor parcial.
4. **Autorizar dentro de `Repository#execute` já nesta entrega ou incluir `calls` de sistema.** Misturaria
   C13 com K18 e usaria o ramo errado do ADR-024. A API produz a decisão de admissão; sua aplicação ao
   despacho/acessos e a reautorização continuam sendo entregas próprias.

## Consequências

Sem mudança de banco, planos, modelos, retratos, IR 0.6 ou dependências. O custo dos snapshots e da
confirmação autoritativa passa a ser uma obrigação explícita da borda, ainda não integrada ao executor.
Não se anuncia autorização completa dos repositórios nem conformidade integral com o ADR-016.
O aceite deste ADR, a execução da sonda no PostgreSQL 17/18 e sua inclusão na CI cabem à auditoria e ao
fluxo do repositório. O mantenedor decide o aceite; o ADR permanece proposto.

## Garantia

- **Verificável por testes:** IR dos quatro exemplos, entrada escalar e contratos estruturados existentes,
  papéis, visitante, contexto de sistema, OLD referenciado, escopo tenant/revenda, EXISTS, campos,
  rate_limit, falha fechada do predicado e da revisão. `test:diagnostics` exige todos os códigos exercitados.
- **Estrutural na API de admissão:** nenhuma dependência de conexão/unidade no avaliador. Sequel.mock
  conta zero SQL/transações nas recusas; um controle positivo confirma que conta BEGIN quando aberto.
- **Transacional a confirmar:** `script/sonda_autorizacao_ruby.rb` aplica os planos existentes como
  migrador, usa login real `vetra_app`, compara Ruby/RLS para as mesmas linhas e conta os BEGIN/COMMIT que o
  pool do runtime executa (logger do Sequel; o `pg_stat_database` publica com atraso e não resolve uma transação isolada). O [guia](../vetra-data.md#sonda-de-entrada-e-autorização-ruby) lista resultados esperados.
  `script/sonda_autorizacao_chat.rb` compara as três políticas `members` com EXISTS escrito à mão em SQL
  nas mesmas linhas, por login real `vetra_app`, e confere invalidação após add/remove_member. Sem RLS no
  chat, essa comparação verifica a concordância do predicado, sem anunciar uma barreira SQL de autorização.
- **Operacional:** autenticidade/completude dos fatos e papéis e atualidade da autoridade de revisão.
  A dupla conferência detecta mudança durante a avaliação, mas não implementa coordenação distribuída
  nem substitui as garantias transacionais do RLS ou a reautorização da K18.

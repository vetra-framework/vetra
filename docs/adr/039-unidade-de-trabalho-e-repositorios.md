# ADR-039: Unidade de trabalho, emissão do contexto e contrato dos repositórios

- Status: aceito
- Aceite: 2026-11-06, pelo Claude por delegação do mantenedor, após a auditoria da C8 (aprovada na rodada 1), com a sonda do Vetra Data em 23/23 no PostgreSQL 18.6.
- Data: 2026-11-06
- Depende de: ADR-003, ADR-005, ADR-016, ADR-022, ADR-023, ADR-035, ADR-036 e ADR-037

## Contexto

Os planos iniciais já estão integrados. O Vetra Data precisa usá-los sem alterar banco, IR, modelos físicos,
retratos ou espelhos. A C8 implementa a transação e o emissor; a C10 implementa os repositórios sob este contrato.
Isso cobre a abertura e a confirmação das etapas 4 a 8 do ADR-016, mas ainda não o executor, a reautorização,
idempotência, histórico, auditoria ou outbox.

## Decisão

### 1. Abertura, composição e falhas

O runtime carrega `vetra/data` explicitamente. `require "vetra"` e os comandos do compilador continuam sem
carregar Sequel/pg e sem conexão. `Vetra::Data.connect(url, **options)` cria um pool PostgreSQL como `vetra_app`,
com `pg_auto_parameterize`; `fiber_concurrency` é ativada antes de criar pools. Cada conexão é conferida no login.
O núcleo só usa datasets e expressões, sem `Sequel::Model` e sem `Dataset#prepare`/`call` (recusados).

`UnitOfWork.new(db, issuer:, scope: :tenant)` recebe um pool exclusivo da fábrica e um emissor. Só aceita um
pool de `Data.connect` ou um mock PostgreSQL para testes. A API é:

```ruby
work.transaction(tenant_id:, actor_id:, op_id:, cmd:, operator_id: nil) { |unit| ... }
work.read(tenant_id:, actor_id:, op_id:, cmd:) { |unit| ... }
# Dentro de uma das duas:
work.compose { |unit| ... }
work.rollback!
```

`op_id` é o UUID da operação, `cmd` é o identificador completo no grafo (também para consultas). O chamador
confiável resolve identidades antes da abertura; não são dados livres da entrada. A transação externa usa
`READ COMMITTED`. `read` abre a mesma unidade com `read_only: true`. O retorno do bloco só é devolvido após
commit. Não é permitido abrir `transaction`/`read` dentro de outra transação, nem adotar uma transação iniciada
fora da unidade. A ponte Rails fica para o contrato hospedado e seus cinco testes do ADR-003.

`compose` exige unidade ativa na fibra corrente e usa `savepoint: true`. Não recebe outro contexto, não troca
tenant/ator/operação/comando, não renova validade e não repete `set_config`. A claim `cmd` continua sendo a da
operação externa: compor não empresta a autoridade de transição de outro comando. Uma composição que precise
desse poder exige desenho posterior e não altera silenciosamente os triggers do ADR-037.

Exceções propagam após rollback, inclusive `Sequel::Rollback`, usado por `rollback!` (opção `rollback: :reraise`).
Uma exceção resgatada **fora** de `compose` permite continuar a transação externa, com o trecho desfeito. Se não
for resgatada, desfaz a operação inteira. Não se deve resgatar um erro SQL dentro do bloco que falhou: o banco
está abortado até o rollback. Não há repetição automática nesta camada; depende do executor e do Effect Boundary.
Hooks locais futuros usam `savepoint: true`; entrega de eventos continua pertencendo à outbox, nunca a um hook.

### 2. Emissor Ruby e segredos

`ContextIssuer.new(kid:, secret:, ttl: 30, clock: -> { Time.now })` recebe chave binária de pelo menos 32 bytes.
`ContextIssuer.from_env` lê `VETRA_CONTEXT_KID` e `VETRA_CONTEXT_SECRET_HEX` (hexadecimal estrito, ao menos 64
dígitos). Configuração pode entregar os bytes de um gerenciador de segredos ou de configuração cifrada; esta
entrega não implementa leitura de `config/secrets.enc`. Chave e kid devem corresponder ao provisionamento
operacional do ADR-036. Não são lidos da IR, dos planos ou de arquivo versionado. Rotação troca o emissor usado
por novas unidades; o runtime não administra `vetra_private.keys`.

`issue(tenant_id:, actor_id:, op_id:, cmd:, operator_id: nil)` devolve um `Token`. `Token#value` é a exportação
explícita e sensível para o protocolo; `inspect` e `to_s` são redigidos. O formato é exatamente:

1. JSON UTF-8 compacto, nesta ordem: `tenant_id`, `actor_id`, `op_id`, `cmd`, `iat`, `exp`, seguido de
   `operator_id` se informado. Não há claims de poder adicionais.
2. UUIDs canônicos minúsculos; `cmd` entre 1 e 255 caracteres Unicode, sem U+0000; tempos inteiros não negativos
   de até 12 dígitos. `iat = clock.call.to_i`, `exp = iat + ttl`.
3. Payload em base64url canônico sem padding nem quebras. Mensagem ASCII `v1.<kid>.<payload>`, com kid de 1 a 64
   caracteres `[A-Za-z0-9_-]`. MAC: HMAC-SHA256 dos bytes dessa mensagem, em base64url sem padding (43 caracteres).
4. Token `v1.<kid>.<payload>.<mac>`, até 8.192 bytes. `ttl` é inteiro entre 1 e 120 segundos, padrão 30.

O banco aceita JSON em qualquer ordem; a ordem acima fixa vetores reproduzíveis do emissor. Ele confere
`iat - 5 <= transaction_timestamp() <= exp`, `iat <= exp <= iat + 120`, `iat >= not_before` e status
`active`/`verify_only`, como o ADR-036. O tempo é o início da transação, não uma interrupção no meio dela.
Relógios sincronizados são requisito operacional. Emissão ocorre dentro da transação externa, antes do corpo.

`set_config('vetra.ctx', token, true)` usa parâmetros do protocolo e ocorre uma vez na transação mais externa.
O token nunca é contexto de sessão; commit/rollback o retiram antes da devolução da conexão ao pool. Não há
cache de identidade na conexão. O pool não deve ser usado para `SET` de sessão por código externo.

Segredo bruto, sua representação hexadecimal, token e parâmetros de assinatura nunca entram em logs, traces,
mensagens de erro ou `inspect` dos objetos do Vetra Data. A chamada sensível não passa pelo logger SQL do Sequel;
uma falha nela vira `data_context_install`, sem mensagem/cause do driver. Emissor, token e unidade têm inspeção
redigida. A aplicação deve respeitar o mesmo sigilo ao exportar `Token#value`, configurar logs do servidor e
instrumentar o driver; o Vetra não controla esses canais externos nem dumps de memória do processo.

### 3. Contexto global e visitante

`UnitOfWork.new(db, scope: :global)` é o contrato para uma aplicação cuja IR não declara tenant (blog e chat).
Usa as mesmas APIs, com `tenant_id: nil`; `actor_id` pode ser UUID ou `nil` para visitante. `op_id` e `cmd`
continuam obrigatórios. Esse modo **não emite token e não chama set_config**: `current_tenant()` e
`current_actor()` permanecem NULL. Ator, operador, comando e operação ficam só na unidade Ruby para autorização
e atribuição de campos pela C10. Nenhum tenant sentinela é criado e nenhum token inválido é apresentado ao banco.

O escopo é escolhido a partir da IR pelo runtime confiável, não pelo usuário. Uma unidade global recusa acesso
a tabela multiempresa. Uma unidade de tenant exige tenant e ator UUID, não admite visitante. Os planos globais
atuais não têm RLS de tenant/escopo nem revisão; a autorização desses exemplos depende da aplicação (ADR-037).
Reforçar identidade/guardas globais no banco exigirá outro contrato e plano incremental; não integra esta entrega.

### 4. Fronteira transacional para a C10

Cada operação do repositório executará seu SQL dentro de `unit.access(multi_tenant: true/false) { |db| ... }`.
A guarda exige a unidade **e** a transação do pool ativas na fibra corrente. Fora delas, levanta
`data_transaction_required` antes de consultar; nunca transforma ausência de transação em coleção vazia.
Para tabela multiempresa exige ainda escopo de tenant (`data_scope`). Um BEGIN externo não satisfaz a guarda.
`access` é infraestrutura para repositórios, não capacidade do `call`: nenhum dataset pode sair desse bloco.
A C8 entrega o mecanismo e testes com um acesso representativo; a C10 o aplica em toda operação terminal.
`unit.context.read_only?` informa a restrição da unidade, inclusive na composição, para recusar escritas antes
do SQL; o banco também a impõe.

### 5. Contrato dos repositórios (C10)

Um repositório por entidade, vinculado à unidade e à capacidade `read`/`read_write`, sem expor dataset, pool ou
SQL ao `call`. Toda leitura respeita escopo, tenant, autorização e campos visíveis; toda gravação reautoriza o
estado final na etapa 6. O RLS permanece barreira final, com os limites do ADR-037.

| Operação | Contrato |
|---|---|
| `find!(id)` | Registro visível ou `RecordNotFound`; registro inexistente e invisível são indistinguíveis |
| `lock!(id)` | Como find, com `FOR UPDATE`; exige capacidade de escrita e unidade gravável |
| `create!(**attributes)` | Gera valores e normaliza conforme ADR-035/027; devolve registro persistido |
| `update!(record_or_id, **attributes)` | Aceita o registro da entidade ou seu ID, sem confiar em tenant/escopo do objeto; devolve nova versão |
| `delete!(record_or_id)` | Remove registro visível, devolve o valor removido; ausência é `RecordNotFound` |
| `add_member!(owner_id, member_id)` / `remove_member!(owner_id, member_id)` | Vínculos declarados, autorização pelo dono e `include_on_create`; inclusão/remoção idempotentes sob corrida, conforme ADR-032 |
| `where(**equalities)` | Só igualdade em campos conhecidos; encadeamento por AND, sem SQL/arbitrários, joins ou blocos |
| `order(*fields)` | Campos conhecidos em ordem ascendente; ID desempata para ordem determinística |
| `first(n)` / `last(n)` / `all` | Terminais que devolvem Array de registros; n inteiro positivo; last mantém a ordem declarada no resultado |

A consulta restrita é um valor imutável, nunca um dataset. `first(n)` e `last(n)` exigem ordem determinística
(ID por padrão); `all` usa a mesma ordem. Não se oferece execução fora de uma unidade. Os corpos atuais usam
`where(email:).first(2)`, `order(:name).all` e `where(room_id:).order(:created_at, :id).last(100)`.

`Vetra::Data::RecordNotFound` e `Conflict` serão erros públicos da C10, com código estável e sem valores/SQL
do driver. Ausência visível é RecordNotFound; unicidade, FK, concorrência de serialização/deadlock são Conflict
com causa interna classificada e sem repetir operação nesta camada. Falha de autorização/transição é acesso
negado, não conflito. Capacidade somente leitura recusa métodos de escrita antes do SQL, além do READ ONLY.

O registro é um `Data` por entidade, congelado em profundidade na construção e em `with`, sem escritores nem
métodos de persistência (ADR-022 §3). Strings, coleções, valores monetários e datas são valores imutáveis;
`Ractor.shareable?` deve ser verdadeiro. Predicados dos grupos de enum (por exemplo, `terminal?`) pertencem ao
tipo gerado. A medição de 10.000 registros/10 campos, com congelamento, continua com o limite do ADR-022.

## Alternativas descartadas e limites

- Token global com tenant fictício, UUID zero ou claims nulas: não corresponde ao contrato do verificador nem
  ao modelo dos exemplos. O caminho global não usa identidade SQL.
- Alterar funções/políticas ou planos iniciais para aceitar global: quebra a história integrada e pertence ao
  plano incremental. Nenhuma mudança de banco é necessária para este contrato.
- Reassinar em cada savepoint: perde o contexto no rollback e muda autoridade no meio da operação.
- Adotar qualquer BEGIN existente: não prova quem instalou o contexto nem a propriedade da operação.
- SQL interpolado, statements nomeados e ORM com callbacks: contrariariam ADR-003/022.

Testes sem banco conferem vetores, limites, sigilo, parametrização, fibras, savepoints e guardas. A sonda
`script/sonda_vetra_data.rb` confere os efeitos transacionais, RLS e protocolo no PostgreSQL 17/18, no job de planos
da CI. Mocks não provam essas garantias. Custo, Falcon, ponte Rails, poolers,
repositórios, executor e outbox seguem com as entregas e medições próprias.

# Vetra Data

O Vetra Data abre unidades de trabalho PostgreSQL pelo Sequel, como `vetra_app`, e emite o contexto assinado
validado pelas funções dos planos atuais. O contrato está no [ADR-039](adr/039-unidade-de-trabalho-e-repositorios.md).
Os repositórios são gerados da IR e vinculados às capacidades e à unidade. O `Runner` (K17, K18 e K19) despacha as operações com a borda, a guarda dos acessos e o fechamento transacional (eventos, idempotência e repetição); os handlers ainda não existem nele.
`Vetra::Execution` valida a entrada e avalia a autorização antes da unidade, conforme o
[ADR-044 proposto](adr/044-entrada-e-autorizacao-em-ruby.md); a aplicação dessas decisões ao despacho e aos
acessos dos repositórios está no `Runner` (K17) e na guarda dos acessos (K18, ADR-046).

## Configurar o processo

```ruby
require 'vetra/data'

issuer = Vetra::Data::ContextIssuer.from_env
db = Vetra::Data.connect(ENV.fetch('DATABASE_URL'), max_connections: 8)
work = Vetra::Data::UnitOfWork.new(db, issuer: issuer)
document = Vetra::Graph::Compiler.new(root: app_root).read_artifact.document
repositories = Vetra::Data::Repositories.new(document)
```

`VETRA_CONTEXT_KID` identifica a chave ativa; `VETRA_CONTEXT_SECRET_HEX` contém ao menos 32 bytes aleatórios,
em hexadecimal estrito. Como alternativa, `ContextIssuer.new(kid:, secret:, ttl: 30)` recebe bytes binários
de configuração segura. Nunca versionar essas configurações, nem imprimir o emissor ou exportar tokens para
logs. O provisionamento da mesma chave e kid em `vetra_private.keys` é operacional, como no
[guia do banco](db-plan.md#bootstrap-e-contexto-assinado); o runtime não lê nem escreve a tabela privada.
O limite de validade é 120 s e o padrão é 30 s. `clock:` pode fornecer Time ou segundos inteiros nos testes.

`connect` usa `vetra_app` mesmo que a URL declare outro usuário e confere cada conexão no login. A unidade só
aceita pool dessa fábrica (ou mock PostgreSQL em testes). Use URL e senha
desse papel. O pool é exclusivo do runtime: não instale `SET` de sessão nele. `Sequel.extension :fiber_concurrency`
é ativada no carregamento de `vetra/data`; carregue-o antes de criar pools. `pg_auto_parameterize` configura os
datasets; `prepare`/`call` são recusados. Não há `Sequel::Model` nem conexão no `require`.

O compilador permanece independente: `require "vetra"` e `graph:*` não carregam Sequel ou pg. Ambas as gems são
dependências de runtime, com janelas `~> 5.110` e `~> 1.7`; as versões testadas são 5.110.0 e 1.7.0 nos cinco
lockfiles. Atualizá-los também exige reconstruir os manifestos dos grafos dos exemplos.

## Executar uma unidade

O runtime confiável resolve identidades e autorização antes da abertura:

```ruby
work.transaction(tenant_id: tenant.id, actor_id: actor.id,
                 op_id: operation_id, cmd: 'crm.create_lead',
                 statement_timeout: 5000, lock_timeout: 500, isolation: :read_committed) do |unit|
  leads = repositories.bind('crm.leads', unit: unit)
  lead = leads.create!(name: 'Cliente novo')
  unit.compose do
    leads.update!(lead, name: 'Cliente revisado')
  end
end

work.read(tenant_id: tenant.id, actor_id: actor.id,
          op_id: operation_id, cmd: 'crm.read_lead') do |unit|
  leads = repositories.bind('crm.leads_read', unit: unit)
  leads.order(:name).first(20)
end
```

O handler de um evento age como ator de sistema ([ADR-024](adr/024-resolucao-das-questoes-do-adr-014.md), §4), no tenant do
evento: o contexto leva `system_actor` (o identificador do handler, até 128 caracteres ASCII) no lugar de `actor_id`, e
exatamente um dos dois é obrigatório.

```ruby
work.transaction(tenant_id: event.tenant_id, system_actor: 'crm.on_lead_won',
                 op_id: operation_id, cmd: 'crm.create_followup') do |unit|
  # unit.context.system_actor? é verdadeiro e unit.context.actor_id é nil
end
```

Sem `actor_id`, `vetra.current_actor()` é NULL e as políticas de escopo por vínculo não casam; a permissiva `vt_system`
dá o alcance do tenant do evento. Eventos gravados por esse ator levam `actor_id` nulo. A autorização do comando pelo
`calls` do handler (etapas 3 e 6 do ADR-016) é do executor, nas tarefas seguintes da rodada 5.

UUIDs são canônicos minúsculos. `operator_id:` opcional também é UUID. A transação externa recebe
`set_config('vetra.ctx', token, true)` parametrizado uma única vez, antes do corpo. O contexto some no commit e
no rollback; não é renovado em savepoints. O relógio do emissor deve estar sincronizado com o banco. A validade
é conferida no início da transação, não interrompe uma transação longa.

`transaction`/`read` não adotam BEGIN externo nem outra unidade já aberta: use `compose`. `rollback!` levanta
`Sequel::Rollback`, que propaga depois da reversão. Outras exceções também propagam. Resgatar fora de `compose`
permite continuar o bloco externo depois do rollback do savepoint, salvo timeout, serialização ou deadlock, que
condenam a unidade inteira; sem resgate, toda a operação é desfeita.
Não há repetição automática, hooks de evento ou executor das oito etapas nesta camada.

O comando assinado é o externo, inclusive durante composição. Compor outro comando não concede a autoridade
dele aos triggers de transição; a reautorização futura deve respeitar esse limite.

`unit.context` é um valor imutável com as identidades, o comando e `read_only?`, disponível apenas dentro da unidade e na
fibra que a abriu. Nunca contém chave nem token. Cada operação terminal do repositório usa
`unit.access(multi_tenant: true/false) { |db| ... }`, sem devolver pool ou dataset ao código da aplicação.
A guarda recusa um acesso multiempresa fora da unidade com `data_transaction_required`, antes de executar SQL,
mesmo que exista um BEGIN externo.

`UnitOfWork.new(..., clock: -> { Time.now })` aceita o relógio da operação. Ele é lido uma vez na abertura,
convertido para UTC com microssegundos e compartilhado por `unit.now`, pelas criações e pelos savepoints.
Esse relógio é separado do relógio de validade do emissor. O runtime pode fornecer a mesma fonte determinística
às capacidades de relógio; os comandos do blog usam `now` para `published_at`.

### Limites e isolamento da unidade

`transaction` e `read` aceitam `statement_timeout:` e `lock_timeout:` como **inteiros em milissegundos de 0 a
120.000**, inclusive. Omitir preserva o valor efetivo da conexão; zero desliga somente aquele limite por operação.
`nil`, negativos, números fracionários, strings e valores acima do teto são `data_timeout`, antes de BEGIN e sem
repetir o valor no erro. O teto de dois minutos mantém esta API voltada a comandos curtos (ADR-016); não alonga os
limites operacionais de 30 s/10 s. Para importações e relatórios longos, divida o trabalho.

`isolation:` aceita exclusivamente `:read_committed` (padrão) e `:serializable`. Outro valor é `data_isolation`,
antes de BEGIN. O isolamento pertence à transação externa. Os timeouts são `set_config(nome, valor, true)` com
parâmetros do protocolo, equivalentes a **SET LOCAL**, instalados uma vez antes do corpo, junto do contexto.
Nunca são instalados dentro de `compose`, que não aceita opções de limites ou isolamento. Commit/rollback
restauram os valores anteriores, e rollback de savepoint preserva os limites externos.

`UnitOfWork.new` liga por padrão `limits: Vetra::Data::Limits.new`. O verificador exige os limites efetivos
`transaction_timeout > 0` e `idle_in_transaction_session_timeout > 0`, com tetos padrão de **30.000 ms e 10.000 ms**.
Ausência, zero, valor malformado ou acima do teto recusam a abertura com `data_limits`: o corpo não roda e a
transação é desfeita antes de instalar o contexto. Não configura esses parâmetros; eles vêm do
[bootstrap operacional](db-plan.md#bootstrap-e-contexto-assinado) do papel `vetra_app`, inclusive em aplicações globais.

Uma política operacional explícita pode mudar os tetos, sempre inteiros positivos até 120.000 ms:

```ruby
limits = Vetra::Data::Limits.new(transaction_timeout: 20_000, idle_in_transaction_session_timeout: 5000)
work = Vetra::Data::UnitOfWork.new(db, issuer: issuer, limits: limits)
```

Somente `limits: false` desliga a conferência; é opção da borda confiável para testes/ambientes controlados.
`nil`, `true` ou outra configuração são recusados. Desligar a conferência não instala proteção no servidor.
Os testes antigos que isolam contexto/repositório usam `false`; `test/data_limits_test.rb` exercita o padrão
ligado com `Sequel.mock`, incluindo valores ausentes/zero/excessivos, outra transação na mesma conexão e SQL parametrizado.

**Custo.** Uma única instrução `SELECT current_setting(..., true), current_setting(..., true)` lê os dois valores
na própria conexão de **cada transação externa**, antes do contexto; não há leitura por acesso, por registro nem
por savepoint. Não guardamos o resultado entre operações: um SET de sessão, outra conexão do pool ou um pooler
pode mudar o efetivo. A leitura comprova o valor efetivo, não a origem no catálogo do papel. Na medição local com
Sequel mock/Ruby 4.0.9, mediana de sete séries alternadas de 5.000 unidades vazias: 75,80 µs/op com verificação e
18,45 µs/op sem (diferença 57,35 µs/op). Isso inclui geração/registro de SQL do mock e **não mede rede nem PostgreSQL**.
A sonda de limites relata a mediana com/sem verificação no banco (três séries de 100 operações com leitura e
savepoint) e confere exatamente 300 leituras para 300 unidades verificadas. A latência real no 17/18 fica para
essa execução pelo Claude; não há cache que esconda configuração insegura.

**Erros retentáveis.** `55P03` produz `Conflict(:lock_timeout)` com `data_lock_timeout`: reaproveita a classificação
pública já usada pela idempotência e esperada pela K19, com um diagnóstico específico. `57014` produz
`StatementTimeout` com `data_statement_timeout` (o PostgreSQL também usa esse SQLSTATE para cancelamento externo;
a mensagem do driver não é inspecionada para distinguir). `40001` produz `SerializationFailure < Conflict`, com
`kind: :serialization` e `data_serialization`; deadlock permanece `Conflict(:deadlock)`/`data_conflict`.
Todos respondem `retryable? == true`, sem SQL, valores, mensagem nem causa do driver. Unicidade e FK continuam
`Conflict` sem indicação de repetição segura.

A classificação é comum aos repositórios, à emissão de eventos, à idempotência e às falhas no commit. Timeout,
serialização e deadlock **condenam a unidade inteira**, mesmo quando o corpo resgata o erro após `compose`:
novos acessos são recusados e o encerramento desfaz tudo, inclusive em saídas por `return`/`throw`.
A camada de dados não repete operações. A repetição, o mapeamento para 409 e a resposta do executor são do `Runner` ([ADR-047](adr/047-fechamento-transacional-do-runner.md)).
As demais exceções de SQL direto por `access` continuam propagando como antes; os repositórios as saneiam.

## Repositórios e registros

`Repositories.new(document)` valida e copia a IR pelo mapeamento físico do ADR-035, sem conexão. Gera uma classe
de repositório e um tipo Ruby `Data` para cada entidade. A fábrica pertence à borda confiável; o corpo `call`
recebe somente os repositórios que o vínculo da operação declara. `bind('crm.leads_read', unit:)` conserva o
acesso `read` da capacidade; uma consulta vinculada pelo linker já resolve `leads` para `leads_read`.

| Operação | Resultado e restrições |
|---|---|
| `find!(id)` | Registro ou `RecordNotFound`; ausência e invisibilidade têm a mesma mensagem/código |
| `lock!(id)` | Registro com `FOR UPDATE`; exige capacidade `read_write` e unidade gravável |
| `create!(**atributos)` | Registro devolvido por `INSERT RETURNING`, com defaults, geração e normalização |
| `update!(registro_ou_id, **atributos)` | Relê e trava a linha visível no banco, confere a transição e devolve nova versão |
| `delete!(registro_ou_id)` | Registro removido por `DELETE RETURNING`; ausência é `RecordNotFound` |
| `add_member!(owner_id, member_id)` / `remove_member!(owner_id, member_id)` | Métodos derivados de `many_to_many`, inclusive com `commands: false`; devolvem o dono |
| `where(**igualdades)` | Igualdades tipadas em campos conhecidos; chamadas sucessivas compõem AND |
| `order(*campos)` | Ascendente; ID acrescentado como desempate, ID por padrão |
| `first(n)` / `last(n)` / `all` | Arrays congelados de registros; `n` inteiro positivo; `last` mantém a ordem declarada |

Consulta é uma descrição imutável. Não aceita blocos, expressões SQL, listas como IN, joins ou projeções.
Não expõe dataset, pool ou SQL. Os valores são copiados ao construir a consulta. Cada terminal confere a unidade
na fibra atual, inclusive quando a consulta foi construída antes da abertura ou conservada depois do encerramento.

O tenant é filtro explícito nas operações, além do RLS, e vem exclusivamente de `unit.context`. A criação da
raiz usa esse tenant como ID. A entrada com coluna de tenant é recusada, mesmo que contenha o valor correto.
Atualização não aceita `id`, tenant ou `created_at`; criação aceita UUID já alocado nas entidades que não são
raiz, mas deixa o banco gerar o UUID por padrão. `created_at` é gerado uma vez pelo relógio da unidade.
Defaults literais e `current_actor`/`current_tenant`, `downcase` e slug de origem declarada são aplicados antes
do INSERT. Slugs usam decomposição Unicode, remoção de acentos e segmentos ASCII minúsculos separados por hífen;
colisão de chave única é `Conflict`, sem sufixo ou nova tentativa automática.

O repositório compara os campos `set_by` e os dois lados de `guarded` com o comando completo da unidade antes do
SQL de escrita. Uma alteração parte de OLD relido com lock, nunca do estado do objeto recebido. Preservar o valor
não constitui transição; defaults permitidos podem ser gravados na criação. Os triggers dos CRMs reforçam a
mesma regra. A comparação usa defaults já convertidos ao tipo do campo, inclusive dinheiro, datas e contexto.
Composição conserva o comando externo. Capacidade `read` e unidade READ ONLY recusam escrita e lock
antes de qualquer SELECT ou DML da operação.

`record_type('crm.lead')` devolve o tipo da entidade. Construção e `with` copiam e congelam em profundidade
strings, hashes, arrays e datas. O registro não tem escritores nem métodos de persistência, e é compartilhável
entre Ractors. Grupos de enum produzem predicados do tipo, como `lead.closed?`.

Na leitura de SELECT/RETURNING, o [ADR-042 proposto](adr/042-construcao-dos-registros.md) usa conversão imediata
própria para a linha tipada do Sequel/pg: o DDL garante tipo, nulidade, enum, comprimento e faixa; o leitor monta
`Money`, retira wrappers de JSON, entrega UTC e congela os valores sem a segunda cópia do construtor público.
`numeric(p,s)` já vem como `BigDecimal` exato na escala física. A faixa de anos 1–9999, microssegundos e números
JSON finitos continuam conferidos, assim como o compartilhamento do registro final. Strings/datas da linha podem
ser congeladas no lugar. Entrada de `create!`, `update!`, IDs e igualdades conserva toda a validação estrita.

Igualdade, `hash`, `inspect`, `to_h`, pattern matching e `with` mantêm o contrato do mesmo `Data`, com os valores
prontos antes do retorno. Falha de conversão, coluna ausente ou invariante residual produz `data_read_value`
durante a leitura, sem dados na mensagem ou na causa. O leitor confia na correspondência entre IR, DDL aplicado e
driver; não revalida todo hash artificial que viole o banco, como enum desconhecido ou NULL obrigatório.

A medição Ruby sem banco é reproduzível com `bundle exec ruby script/medir_construcao_registros.rb`; compara a
C10, a conversão escolhida, a construção sob demanda com acesso completo e o piso de `Data.new`. O custo medido
não declara cumprido o gate de 10% do ADR-022. A sonda PostgreSQL abaixo mantém esse limiar; seu resultado e
qualquer proposta de orçamento absoluto dependem, respectivamente, da auditoria e da decisão do mantenedor.

`graph:build` e `graph:check` recusam na normalização campos cujos nomes coincidam com métodos reservados do
registro, como `hash`, `class`, `with` e `public_send`. Grupos de enum também são recusados se o predicado
gerado colidir, como `frozen?` ou o método privado `enum_group?`.
O diagnóstico `field_name_collides_with_record` aponta o campo ou grupo e sugere renomeá-lo, conforme o
[DSL](fase-0.md#nomes-de-campo-e-grupos-de-enum). Compilador e runtime compartilham a reserva calculada dos
métodos de um `Data.define` vazio com `Record`: todos os públicos e protegidos, os privados cujo dono
não é `Kernel` e os ganchos privados do `Kernel` chamados pelo Ruby/Data no registro, listados no DSL.
Funções privadas do `Kernel` como `format`, `open`, `select`, `test`, `system` e `load` são aceitas como
campos; a mesma regra vale para os predicados de enum. A consulta aos ancestrais, à visibilidade e ao dono
ocorre a cada checagem. `Repositories.new` mantém a defesa `data_record_type` para IR recebida diretamente;
campos são conferidos antes de gerar os tipos.

Decimais são `BigDecimal`; `Vetra::Data::Money` é um `Data` imutável com `amount` BigDecimal e `currency` ISO 4217.
Entrada monetária recebe `{ amount: '123.45', currency: 'BRL' }` ou `Money`; moeda omitida usa a da aplicação.
Float, NaN, excesso de escala e estouro de precisão são recusados, sem arredondamento silencioso pelo banco.
Aritmética, rateio e formatação monetária continuam pendentes. Timestamp exige Time ou ISO 8601 com fuso e até
seis casas; a saída é UTC. JSON é convertido para jsonb, e dinheiro para as duas colunas físicas.

`RecordNotFound#code` é `data_record_not_found`. `Conflict#code` é `data_conflict` para `:unique`, `:foreign_key`
e `:deadlock`, `data_lock_timeout` para `:lock_timeout` e `data_serialization` para `:serialization`.
`StatementTimeout#code` é `data_statement_timeout`. Mensagem, `cause` e inspeção não carregam o erro,
SQL nem valores do driver. Recusa SQL de acesso é `data_access_denied`, não conflito. Não há repetição automática.
Erros SQL devem ser resgatados fora da unidade ou fora de `compose`, depois do rollback.

Os repositórios, **fora do `Runner`**, não aplicam `authorize`, papéis Ruby ou permissões por campo aos seus acessos: o
isolamento é o contexto da unidade e o RLS dos planos dos CRMs, nos limites do ADR-037, e a aplicação continua
responsável por autorizar as chamadas. **Sob o `Runner`**, a guarda do [ADR-046](adr/046-autorizacao-dos-acessos-e-estado-final.md)
autoriza cada acesso e o estado final (veja [Autorização dos acessos](#autorização-dos-acessos-pelo-runner)).
A emissão para a outbox e o relay estão descritos abaixo. O `Runner` das etapas 1 a 5 e 8 e a execução das
primitivas builtin estão em [Executar uma operação](#executar-uma-operação-pelo-runner); os handlers reais, o
histórico e a auditoria são entregas posteriores.

## Entrada e autorização antes da unidade

```ruby
require 'vetra/execution'

authorization = Vetra::Execution::Authorization.new(document)
context = Vetra::Data::Context.new(scope: :tenant, tenant_id: tenant_id,
                                  actor_id: actor_id, op_id: operation_id, cmd: 'crm.win_lead')
# Valores já resolvidos por uma borda confiável: não vêm da entrada do cliente.
snapshot = authorization.snapshot(context: context, roles: ['crm.gerente'],
                                  revision: resolved_revision, records: resolved_records)
result = authorization.check('crm.win_lead', input: { lead_id: lead_id }, context: context,
                             snapshot: snapshot, current_revision: revision_authority)
if result.allowed?
  # A K17 usa result.input (hash imutável com chaves String) para o despacho.
  # O Runner autoriza cada acesso e reautoriza o estado final antes do commit (ADR-046).
else
  result.diagnostics # Diagnósticos de dados, sem identidade, SQL ou valores recebidos.
end
```

`Authorization.new` copia/valida a IR pelo esquema existente, sem conexão. `validate_input(operation_id,
attributes)` pode ser usado isoladamente: devolve entrada tipada e imutável ou levanta `Data::Error`.
`check` reúne as etapas 2 e 3 e devolve `Result` com `allowed?`, `code`, `diagnostics`, `input` e
`policy_ids`. Em recusa, `input` é nil e `policy_ids` é vazio. Não chama o `call` nem abre a unidade.

A entrada é um Hash com chaves String ou Symbol, sem campos extras nem nomes duplicados entre as duas
formas. Tipos e erros vêm de `Values`: UUID, texto e limites, nulidade, enum, decimal/money exatos, datas,
UTC, JSON e downcase declarado. Não há conversão permissiva de strings em boolean/integer. Campos
opcionais ausentes continuam ausentes; NULL explícito exige `nullable`. O contrato CRUD preserva a
proteção de `set_by` e de valores `guarded`. `Execution::Input#validate(contract_id, value)` também
valida `record`/`collection` recursivamente nos contratos existentes. A IR 0.6 só admite essas estruturas
nas saídas de consultas: entrada aninhada de comando continua indisponível, sem alteração do formato.

`resolved_records` tem o formato `{ 'crm.lead' => [hashes], 'crm.dealer' => [hashes],
'crm.membership' => [hashes] }`. São registros persistidos tipados, lidos pela borda; chaves dos campos
podem ser String/Symbol, e são copiadas/congeladas. Deve haver todos os campos e linhas necessários aos
predicados, incluindo as relações percorridas. Lista vazia é uma ausência conhecida; entidade/campo
omitido é informação insuficiente e recusa, inclusive sob NOT. O avaliador filtra tenant em cada salto.
O registro de `authorize record:` vem desses fatos e é selecionado pelo ID da entrada validada.
Criação CRUD monta o candidato com entrada, defaults da entidade e tenant do contexto. Comandos Ruby
arbitrários sem `record:` não ganham um mapeamento inventado de parâmetros para campos; uma política
que precise de fatos indisponíveis recusa. Uma consulta de coleção sem `record:` é admitida pelo papel (sem fatos) e
filtrada linha a linha pela guarda do `Runner` (ADR-046); uma política sem suporte não recebe admissão provisória.

`revision_authority.call(context)` confirma o marcador atual; a confirmação acontece no começo e antes
de permitir. Ela pertence à borda, não pode consultar o pool da operação e não pode devolver cegamente
`snapshot.revision`. Nos CRMs o marcador inclui a revisão do ADR-020; mudanças externas de atribuição
de papéis precisam acrescentar uma geração de identidade. Blog/chat usam uma autoridade global da
borda, sem criar tenant ou revisão SQL. A borda deve reconciliar fatos e revisão, invalidar os antigos
antes de admitir operações posteriores à mudança e recusar quando não pode provar atualidade. Um TTL
ou um consumidor de NOTIFY eventualmente consistente, isoladamente, não cumpre isso. A C13 fornece a
interface e as recusas, **não o provedor operacional**; sua integração pertence à K17. O contrato completo
e a janela de revogação estão no ADR-044, §1.

Papéis são IDs completos existentes na IR, atribuídos exclusivamente pela borda confiável. Um papel
não anônimo exige `actor_id`; o nome `authenticated` não prova autenticação. Papéis não informados
significam visitante, com as políticas `anonymous: true` da aplicação; elas também se somam às dos
atores identificados. Os predicados ainda verificam os vínculos reais: declarar `crm.gerente` não
concede uma revenda. O contexto deve pertencer ao comando e ao escopo da aplicação. Um `system_actor` é autorizado
só pelos `calls` do handler de mesmo `id` (ADR-024, §4; ADR-046), sem papéis, fatos nem revisão.

O subconjunto suporta true, AND/OR/NOT, igualdade, IN literal, `actor.id`, campo escalar local e EXISTS
por belongs_to/has_many/many_to_many, com lógica SQL de NULL. `many_to_many` percorre dono → junção → alvo
pelas duas FKs da IR, compara as chaves inteiras e filtra tenant em ambos os saltos. Chave com NULL não
casa. Junção e alvo precisam estar no snapshot: lista vazia afirma ausência; entidade omitida recusa,
mesmo se um salto anterior não encontrar linhas. Um predicado candidato inteiro sem suporte provoca
recusa. Literais de comparação recebem o tipo do outro operando (UUID, data, timestamp ou número). Famílias
incompatíveis recusam em vez de transformar uma comparação inválida em concessão sob NOT. A recusa vale
inclusive quando há OR com true. Caminhos de campo compostos e comparação de money/JSON composto
permanecem fora. Campos permitidos são a união das políticas aplicáveis à mesma linha.
Create/update CRUD conferem os campos fornecidos pelo cliente, além de qualquer `fields:` explícito;
leituras/comandos Ruby exigem todos os campos da entidade por padrão. A borda pode fornecer `fields:`
para uma projeção/acesso efetivo; nunca para esconder um campo fornecido no CRUD.

Uma concessão limitada não autoriza execução enquanto não houver contadores: cobertura que dependa
dela resulta em `data_authorization_rate_limit`. Cobertura completa por concessões sem limite continua
permitindo sem consumir cota. No blog, o visitante não cria comentários, enquanto o administrador com
concessão aplicável sem limite pode criá-los.

`uses` não concede acesso de dados implícito. Ser dono da sala admite a ação principal de
`chat.add_member_by_email`; o acesso adicional a `users_read` é recusado no corpo, com `data_authorization_denied`, pela guarda do
`Runner` (ADR-046), porque o grafo atual não concede leitura de `chat.user`. O modelo é preservado, e o acesso não é liberado
por inferência do corpo Ruby.

| Código | Motivo |
|---|---|
| `data_value` | Tipo, nulidade, limite ou valor incompatível; ponteiro do contrato, sem o valor |
| `data_input_fields` | Objeto inválido, campo extra ou chaves duplicadas; sem repetir a chave recebida |
| `data_execution_operation` | Identificador não é comando/consulta da IR |
| `data_authorization_context` | Contexto, escopo, comando ou papéis incompatíveis |
| `data_authorization_snapshot` | Fatos incompletos, de outro catálogo/principal, obsoletos ou revisão indisponível |
| `data_authorization_denied` | Sem concessão aplicável, registro ausente/invisível ou fora de escopo |
| `data_authorization_fields` | As concessões não cobrem todos os campos solicitados |
| `data_authorization_predicate` | Política candidata fora do subconjunto suportado |
| `data_authorization_rate_limit` | Autorização depende de concessão limitada, sem contadores |
| `data_authorization_system_actor` | Contexto de sistema exige o caminho por `calls` |

### Sonda de entrada e autorização Ruby

```sh
DATABASE_URL=postgres://administrador@localhost/postgres \
  bundle exec ruby script/sonda_autorizacao_ruby.rb
```

Exige bootstrap ADR-036 e, quando necessária, `VETRA_APP_PASSWORD`. Cria/remove um banco próprio,
aplica a cadeia existente do CRM com revendas como `vetra_migrator` e abre login real `vetra_app`.
Não altera papéis globais, planos, retratos ou exemplos. Sintaxe e caminhos Ruby/SQL foram conferidos
sem banco; a execução PostgreSQL 17/18 e a inclusão na CI pertencem ao Claude. São **68 verificações
esperadas**, com os seguintes resultados:

| Verificações | Resultado esperado |
|---|---|
| Aplicação dos planos e login/contexto (2) | Cadeia aplica sem poder administrativo do migrador; current/session_user são vetra_app e contexto contém tenant/ator corretos |
| Matriz de quatro atores × quatro ações × três revendas (48) | Gerente permite CRUD só na primeira; vendedor permite read/create/update só na primeira; misto permite CRUD na primeira e read/create/update na segunda; sem vínculos recusa tudo; terceira revenda de outro tenant sempre recusada |
| Ator/tenant da terceira revenda × quatro ações × três revendas (12) | Só a terceira revenda permite, sem acesso às duas do primeiro tenant |
| Papel incorreto da borda (1) | Ruby recusa delete para papel vendedor mesmo que haja vínculo gerente; o RBAC de papéis não é uma garantia do RLS |
| Recusas e controle de contagem (2) | Recusas por papel, vínculo, revenda e entrada executam zero SQL no pool do runtime; abrir uma unidade executa BEGIN e COMMIT |
| Revogação (2) | DELETE do vínculo incrementa revisão e snapshot antigo recusa; fatos atualizados e RLS recusam o gerente revogado |
| Catálogo de papéis (1) | Idêntico antes/depois |

As tentativas SQL permitidas e recusadas são executadas independentemente da decisão Ruby e revertidas
para preservar os mesmos dados. Um erro SQL inesperado faz a verificação falhar; não vira acesso negado.
A contagem é a do pool do runtime, o único caminho de uma operação até o banco: o logger do Sequel não pode ver SQL
algum durante as recusas, e o controle positivo vê o BEGIN e o COMMIT da unidade. A preparação/resolução dos
fatos ocorre antes da medição. Não se confunde zero transações da admissão com zero custo da borda.

### Sonda de autorização do chat

```sh
DATABASE_URL=postgres://administrador@localhost/postgres \
  bundle exec ruby script/sonda_autorizacao_chat.rb
```

Exige o bootstrap ADR-036 e os dois `ALTER ROLE` da C15, além de `VETRA_APP_PASSWORD` quando necessária.
Cria/remove um banco próprio, aplica os planos existentes como `vetra_migrator` e usa dois pools com login
real `vetra_app`. O chat não tem RLS: a referência é um EXISTS escrito à mão em SQL, nas mesmas linhas,
sem alterar o tradutor SQL de políticas. A avaliação Ruby usa `DatabaseFacts` e a geração em processo.
São **30 verificações**, no 17 e no 18, e na CI:

| Verificações | Resultado esperado |
|---|---|
| Planos, logins e ausência de RLS (2) | Cadeia aplica como migrador; ambos os pools usam vetra_app e as quatro tabelas continuam sem RLS |
| Quatro atores × três operações × duas salas (24) | `read_room`, `read_message` e `create_message`: dono vinculado e membro permitem só na primeira sala; não membro (mesmo autor da mensagem) recusa ambas; membro da outra sala permite só nela; dono da segunda sala sem vínculo recusa |
| Completude dos fatos (1) | Junção contém os três vínculos das duas salas e alvo contém os quatro usuários |
| Add/remove_member (2) | Publicação só depois do commit, marcador avança, snapshot antigo recusa e fatos novos/SQL permitem após inclusão e recusam após remoção |
| Catálogo de papéis (1) | Idêntico antes/depois |

Cada decisão SQL é consultada mesmo quando Ruby recusa. Não se anuncia proteção SQL de autorização no chat.

## Executar uma operação pelo Runner

O `Runner` (K17, [ADR-045](adr/045-borda-interna-e-runner.md), proposto) despacha as etapas 1 a 5 e 8 do ADR-016 sobre o
grafo vinculado. Ele junta a **borda** (identidade, fatos e autoridade de revisão), o avaliador do ADR-044 e a unidade.

```ruby
require 'vetra/execution'

linked  = Vetra::Graph::Compiler.new(root: root).link
catalog = Vetra::Data::Repositories.new(linked.document)

# Dois pools de vetra_app: o da operação e o da borda, que lê os fatos fora dele.
operation_db = Vetra::Data.connect(url)
edge_db      = Vetra::Data.connect(url)

authority = Vetra::Execution::DatabaseAuthority.new(db: edge_db)      # CRMs (revisão SQL + geração da identidade)
# authority = Vetra::Execution::InProcessAuthority.new                 # blog e chat (um processo)
facts = Vetra::Execution::DatabaseFacts.new(
  catalog: catalog, authority: authority,
  unit: Vetra::Data::UnitOfWork.new(edge_db, issuer: issuer)          # scope: :global em blog e chat
)
edge = Vetra::Execution::Edge.new(
  identity: ->(credentials) { Vetra::Execution::Identity.new(tenant_id: ..., actor_id: ..., roles: [...]) },
  facts: facts, authority: authority
)
runner = Vetra::Execution::Runner.new(
  linked: linked, catalog: catalog, edge: edge,
  unit: Vetra::Data::UnitOfWork.new(operation_db, issuer: issuer),
  unit_options: { statement_timeout: 5_000, lock_timeout: 1_000 }      # C15
)

outcome = runner.run('crm.win_lead', { lead_id: id }, credentials: credentials)
outcome.ok? ? outcome.value : outcome.diagnostics
```

**`Outcome`.** As etapas 1 a 3 devolvem um `Outcome` com `status` `:ok`, `:unresolved` (identidade não resolvida; o código HTTP é do adaptador),
`:invalid` (entrada fora do contrato, 422) ou `:denied` (política, escopo, contexto ou fatos obsoletos, 403), com `diagnostics` e
`code`. Nenhuma delas toca o pool da operação. O que acontece depois da etapa 4, inclusive o `fail!` do `call`
(`Vetra::Execution::Failure`, com `field` e `reason` como dados), os conflitos e os timeouts da C15, termina com a unidade
desfeita por inteiro: `run` o devolve como `Outcome` (422, 409, 500...) e `run!` o levanta ([ADR-047](adr/047-fechamento-transacional-do-runner.md)). Uma operação que o grafo não tem levanta `data_execution_operation`.

**A borda.** `Edge.new(identity:, facts:, authority:)` recebe três objetos chamáveis. A identidade vem sempre da borda: o `Runner`
nunca lê tenant, ator ou papéis da entrada, e uma identidade com tenant numa aplicação global (ou sem tenant numa aplicação de
tenant) é recusada pelo contexto. Exceção de um colaborador vira recusa com código próprio (`execution_identity`,
`data_authorization_snapshot`), sem causa e sem a mensagem do provedor.

**A autoridade de revisão.** `DatabaseAuthority` devolve o marcador `[revisão de vetra.authz_revisions, geração da identidade]`,
lido numa só instrução em autocommit pelo pool da borda; `identity_changed!` publica a geração quando um papel muda fora do banco.
`InProcessAuthority` é uma geração em memória que o `Runner` publica **depois do commit, ou da falha**, de todo comando que usa um
repositório `read_write` de uma entidade lida por alguma política. Ela vale para **um** processo: escritas de outro processo, ou
direto no banco, não a movem. `DatabaseFacts` lê o marcador antes dos fatos, lê as linhas que as políticas candidatas percorrem
com o contexto do ator (o RLS filtra como filtra a operação) e **recusa**, em vez de truncar, passando de 10.000 linhas por
entidade.

**Capacidades e primitivas.** O `call` recebe, na ordem dos parâmetros, um repositório ligado à unidade ou o relógio da operação
(o instante da unidade); `uuid`, `random` e capacidades externas recusam com `execution_capability` até terem executor. A entrada
chega como um `Data` com todos os campos do contrato (o opcional ausente é `nil`), e o `call` só tem `fail!` além das capacidades.
`crud.create|read|update|delete` e `many_to_many.add|remove.<relação>` rodam pelos métodos do repositório. O descritor `builtin` do
linker não traz mais `executor: "pending"`, e o bloco Ruby só roda por `LinkedGraph#run_implementation`, a porta do `Runner`.

O percurso `members` do chat inclui `chat.room_membership` e `chat.user` no plano de fatos e nas entidades que
invalidam snapshots. O provedor lê a junção inteira, dentro do limite de 10.000 linhas (consulta 10.001 para detectar
excesso). `chat.read_room`, `chat.read_message` e `chat.create_message` admitem membros da sala; o dono precisa do vínculo
como os demais. Add/remove_member publicam a geração depois do commit e invalidam fatos anteriores.

**O que ainda não existe.** Os handlers de sistema (C14), o histórico e a auditoria, a composição de comandos pelo `call` e os adaptadores.
Um comando composto não empresta a autoridade de transição de outro (ADR-039).

### Duas contagens de transações

O ADR-044 lê o teste 1 do ADR-016 como **zero transações da operação**. A sonda conta as duas pontas pelo logger de cada pool: a
operação recusada nas etapas 1 a 3 não abre `BEGIN` no pool da operação, e a borda abre a sua transação para ler os fatos, que
**não** é zero. Nenhum relatório diz "zero transações do fluxo".

### Sonda do Runner

```sh
DATABASE_URL=postgres://administrador@localhost/postgres \
  bundle exec ruby script/sonda_runner.rb
```

Exige o bootstrap ADR-036, os dois `ALTER ROLE` do `vetra_app` (C15) e, quando necessária, `VETRA_APP_PASSWORD`. Cria um banco por
exemplo, aplica a cadeia como `vetra_migrator` e abre dois pools de `vetra_app`. São **27 verificações**, no 17 e no 18:

| Exemplo | Verificações |
|---|---|
| CRM com revendas (tenant, RLS) | `update_lead` (crud) com uma transação na operação e a da borda; consulta em transação somente leitura; `win_lead` (call Ruby) e a segunda tentativa como `Failure` desfeita; ator sem vínculo recusado com zero transações na operação; entrada inválida e identidade não resolvida sem SQL; papel errado na borda recusado; revogação durante a admissão pega pela segunda conferência; autoridade fora do ar recusa sem a exceção; marcador avança e o snapshot antigo é recusado depois do commit da revogação; geração da identidade invalida o snapshot; pool sem contexto residual |
| Blog (global, geração em processo) | `create_post` e `publish_post` com uma geração publicada depois de cada commit; consulta sem publicar; visitante recusado; `Failure` desfeita que ainda publica; snapshot antigo recusado depois de um comando; `delete_post`; a geração só é publicada depois do `COMMIT` e, num comando que escreve e depois falha (cópia temporária do blog), depois do `ROLLBACK`, com a escrita desfeita |
| Chat (global) | `create_room` cria a sala e o vínculo do dono pela primitiva e publica a geração; `read_room` permite ao dono vinculado sem publicar geração e recusa não membro sem transação da operação; papel desconhecido recusado |

`VETRA_SONDA_DEBUG=1` imprime, por chamada, o estado do `Outcome` e as duas contagens, nunca valores.

## Autorização dos acessos pelo Runner

O `Runner` instala uma `Execution::AccessGuard` na unidade de cada operação (K18, [ADR-046](adr/046-autorizacao-dos-acessos-e-estado-final.md),
proposto). O `uses` não concede dados (ADR-044, §2): cada acesso do `call` é decidido pelas políticas dos papéis da identidade, com fatos
lidos **na própria unidade**, e o estado final é reautorizado antes do commit.

| Acesso | Decisão |
|---|---|
| `find!`, `lock!` | `read` do registro, com todos os campos; o que o papel não lê vira `RecordNotFound`, como no RLS. `lock!` não exige `update` |
| `create!` | `create` sobre a linha candidata, antes do `INSERT` |
| `update!`, `delete!` | `read` e a ação, sobre o OLD lido sob lock (o `delete!` ganha um `SELECT ... FOR UPDATE`) |
| `add_member!`, `remove_member!` | `read` do dono e a ação do vínculo (`add_member`, `remove_member`) sobre o dono; alvo e junção fazem parte da ação |
| `where`, `order`, `first`, `last`, `all` | `read` por linha: a que o papel não lê some; o limite vale para as visíveis, lidas em lotes de 200 |

**Recusas.** Sem concessão alguma do papel para a ação na entidade, a recusa é explícita (`data_authorization_denied`), **antes de qualquer
consulta** (a resposta não pode depender de o registro existir) e mesmo numa coleção vazia: é o que acontece com `chat.add_member_by_email`, que usa `users_read` sem política de leitura de `chat.user`, e nada é gravado.
Campos não cobertos são `data_authorization_fields`; concessão com `rate_limit:` sem contadores, `data_authorization_rate_limit`.
Uma consulta de coleção sem `record:` é admitida pelo papel na etapa 3, sem fatos, e filtrada linha a linha no corpo.

**Fatos e cache.** Os fatos são as entidades que as políticas candidatas percorrem (com as junções), lidas pelo mesmo `fact_rows` do
provedor da borda, com o limite de 10.000 linhas por entidade. Há cache por entidade dentro da operação, descartado a cada escrita
dela. Não há marcador de revisão: os fatos nascem da transação que vai gravar.

**Savepoints.** `UnitOfWork#compose` devolve à guarda o ponto de retorno se uma exceção desfaz o savepoint (`break`, `return` e `throw` não desfazem): as escritas registradas dentro dele e os fatos
lidos deixam de valer. Apagar e recriar o mesmo `id` deixa a linha existente para a reautorização.

**Estado final (etapa 6).** Um `call` que sai por `throw` ou `break` nunca é confirmado (a transação é desfeita). Antes do commit, cada linha criada ou alterada é relida com fatos novos e decidida (`create` ou `update`) com
os campos gravados; a recusa é `data_authorization_final` e desfaz a unidade. Cobre a troca de revenda no `update` (teste 4 do ADR-016)
onde não há RLS; nos CRMs o `WITH CHECK` recusa primeiro, e as duas recusas concordam.

**Ator de sistema.** `Identity.new(tenant_id:, system_actor: 'crm.notify_sales')`: a etapa 3 autoriza o comando se, e somente se, ele
está nos `calls` do handler de mesmo `id`, sem papéis, fatos nem revisão; a guarda não aplica políticas de papéis, e o tenant do
evento segue isolado pelo repositório e pelo RLS (`vt_system`). O runner dos handlers é da C14.

### Sonda dos acessos

```sh
DATABASE_URL=postgres://administrador@localhost/postgres \
  bundle exec ruby script/sonda_acessos.rb
```

Mesmos requisitos da sonda do Runner. São **21 verificações**, no 17 e no 18:

| Exemplo | Verificações |
|---|---|
| Chat (sem RLS) | `my_rooms` só com as salas do membro; a sala nova lida na mesma operação que escreveu o vínculo (os fatos antigos são descartados); `room_page` com as mensagens da sala e a sala alheia recusada sem transação da operação; `add_member_by_email` recusado no corpo sem gravar; `add_member` e `remove_member` mudando o que o membro novo lê; não dono não administra membros; `create_room` com o vínculo do dono e o estado final reautorizado |
| Blog (sem RLS) | o autor lê e altera o post; passar o post a outro autor recusado no estado final, desfeito, com a geração publicada; criar em nome de outro recusado na admissão; o post alheio não é lido |
| CRM com revendas (RLS) | troca de revenda recusada e desfeita (teste 4 do ADR-016); alteração na própria revenda; lead de outro tenant inalcançável; o vendedor lê e não apaga; o ator de sistema executa o comando dos `calls` sem ler fatos, não alcança outro tenant nem comando fora dos `calls` |

## Fechamento do Runner: eventos, idempotência, status e repetição

O fechamento (K19, [ADR-047](adr/047-fechamento-transacional-do-runner.md), proposto) completa as etapas 4 e 7 do ADR-016.

```ruby
outcome = runner.run('blog.publish_post', { post_id: id }, credentials: credentials, idempotency_key: 'chave-do-adaptador')
outcome.status        # :ok, :unresolved, :invalid, :denied, :not_found, :failed, :conflict ou :error
outcome.http_status   # 200, 401, 422, 403, 404, 422, 409 ou 500
outcome.retryable?    # o cliente pode repetir (lock_timeout, statement_timeout, repetições esgotadas)
outcome.replayed?     # o valor é o JSON guardado, sem executar o call
outcome.attempts      # quantas vezes a operação foi tentada
runner.run!(...)      # levanta o erro de dados em vez de mapeá-lo (testes e diagnóstico)
runner.serialize('blog.publish_post', outcome.value) # a forma JSON que o registro guarda: só os campos do contrato de saída
```

**Eventos.** O `call` nunca grava um evento: depois da reautorização do estado final, o `Runner` grava os de `emits` com o payload projetado do
registro devolvido, na unidade; se o retorno não é o registro da entidade dos eventos, a unidade é desfeita (`data_event`).

**Idempotência.** O hash da entrada e o resultado guardado vêm do **contrato** (campos declarados, na forma canônica dos eventos, com os microssegundos dos
instantes), e não do que o `call` devolveu por inteiro: um campo fora do contrato nunca é gravado, e um valor que não tem os campos obrigatórios do contrato
desfaz a unidade (`data_idempotency_result`, 500). Um número não inteiro dentro de um campo JSON da entrada não tem forma canônica, e a chave é recusada
(`:invalid`, `data_idempotency_input`). A chave é reivindicada na etapa 4, dentro da unidade, e o resultado é guardado na etapa 7, na mesma transação; a repetição
devolve o JSON guardado, sem executar, escrever nem emitir. Uma consulta, uma chave fora do formato e um comando cuja saída leva campo pessoal
(direto ou em `record` e `collection`) recusam a chave antes da etapa 4 (`:invalid`): o resultado não pode ser guardado em claro. Chave
reutilizada com outra entrada ou outro principal é `:failed` (422).

| Origem | status |
|---|---|
| `fail!`, chave reutilizada | `:failed` (422) |
| registro que some no corpo | `:not_found` (404) |
| recusa de acesso no corpo (`data_authorization_*`) | `:denied` (403) |
| unicidade, chave estrangeira | `:conflict` (409) |
| `lock_timeout`, deadlock ou serialização que esgotou as repetições | `:conflict` (409), retentável |
| `statement_timeout` | `:error` (500), retentável |
| `data_idempotency_result`, outro erro de dados, exceção inesperada | `:error` (500) |

**Repetição.** Falha de serialização e deadlock repetem a operação inteira, a partir da etapa 3 e depois do rollback, até 3 vezes (50, 100 e
200 ms, com variação aleatória; `sleeper:` e `random:` são injetáveis), reivindicando a chave de novo. Só acontece quando nenhuma capacidade
em `uses` declara `retry_safe: false` e o comando não declara `unsafe_effect`; senão a falha sai como `:conflict` retentável. Os eventos e as
escritas de uma tentativa desfeita não existem: não há evento duplicado.

### Sonda do fechamento

```sh
DATABASE_URL=postgres://administrador@localhost/postgres \
  bundle exec ruby script/sonda_fechamento.rb
```

Mesmos requisitos da sonda do Runner. São **13 verificações**, no 17 e no 18: o evento do `emits` com o payload do registro; `fail!` (422) e o acesso
negado (403) sem evento nem transação; a chave guardando o resultado e a repetição sem executar nem emitir; a chave reutilizada (422); a chave
recusada antes de qualquer transação para uma consulta, uma chave ruim e uma saída pessoal; e, com **duas transações concorrentes de verdade**
em comandos de uma cópia temporária do blog, a falha de serialização e o deadlock repetidos com sucesso, sem evento duplicado, e a falha de
serialização num comando com `unsafe_effect` voltando como 409 retentável sem repetir. No CRM com revendas, o evento do `emits` no tenant do
contexto e a recusa da chave para a saída com o e-mail do lead.

## Emissão de eventos

`repositories.emit!(unit, record)` grava na outbox, na unidade de trabalho, os eventos que o comando da unidade
declara em `emits` a partir da entidade do registro (ADR-040, §2). É borda confiável, como `bind`: o runtime a chama
depois do `call` e antes do commit (etapa 7 do ADR-016); o corpo `call` não a recebe. Devolve os `event_id`.

```ruby
work.transaction(tenant_id:, actor_id:, op_id:, cmd: 'crm.win_lead') do |unit|
  lead = repositories.bind('crm.leads', unit: unit).update!(lead_id, status: 'won')
  repositories.emit!(unit, lead) # crm.lead.won, com o payload { "id": ... }
end
```

- O payload é a projeção declarada, com os tipos do contrato: decimais e dinheiro como texto exato na escala do
  campo (`{ "amount": "123.40", "currency": "BRL" }`), instantes em UTC com microssegundos e datas ISO 8601.
- A linha leva `event_id`, `event`, `version`, `tenant_id`, `actor_id`, `op_id` e `cmd` do contexto da unidade.
  `created_at`, `xid8` e `seq` vêm do banco; a aplicação não tem permissão para defini-los.
- O INSERT vai sem `RETURNING`, porque a aplicação não lê a outbox. O valor de cada coluna vai como argumento do
  protocolo (`pg_auto_parameterize`), sem instrução nomeada.
- Depois do INSERT, `pg_notify('vetra_outbox', tenant)` acorda quem lê a outbox; o texto é o tenant ou vazio,
  nunca o conteúdo do evento, e só chega no commit.
- A emissão exige unidade gravável, um comando que declare o evento e um registro desta IR (`data_event`).
- **Campo pessoal.** Até existir a cifra do ADR-013, §6, um payload com campo pessoal é recusado com
  `data_event_personal` e **condena a unidade**: a transação termina em rollback mesmo que o `call` resgate o
  erro, inclusive dentro de `compose` e numa saída por `throw`, `break` ou `return` (`rollback_on_exit`).

Com a manutenção em dia, cada evento cai na partição do seu dia; sem ela, na `DEFAULT`, que a manutenção recupera.
Os handlers reais, com o ator de sistema, são da rodada 5; o relay e as entregas estão descritos abaixo.

## Relay, entregas e manutenção

`Vetra::Data::Relay` roda como `vetra_relay` (ADR-040, §3), num pool próprio aberto por
`Relay.connect(url)`, que sobrescreve o usuário e confere cada conexão. Os handlers de cada evento vêm do grafo.
Cada operação abre e confirma a própria transação curta; chamá-la dentro de outra transação é recusado
(`data_relay_transaction`), porque a reserva não confirmaria antes do efeito.

```ruby
db = Vetra::Data::Relay.connect(ENV.fetch('DATABASE_URL'))
relay = Vetra::Data::Relay.new(db, document: document)
relay.maintain(ahead: 3, retention: 7) # antes de liberar quem grava, e uma vez por dia
relay.relay!                           # materializa as entregas de uma faixa de xid8
relay.work('crm.notify_sales') { |delivery| mailer.deliver(delivery.payload, key: delivery.event_id) }
```

- **`relay!`** lê a faixa `[checkpoint, pg_snapshot_xmin)` da outbox, em ordem de `xid8` e `seq` (ADR-008, §2), cria
  uma entrega por handler com `ON CONFLICT DO NOTHING` sobre `(handler, event_id, event_created_at)` e avança o
  checkpoint de `vetra.relay_checkpoints`, tudo numa transação curta. Uma transação aberta segura a faixa: nada
  dela nem depois dela é lido até ela terminar, então nenhum evento é pulado. Outro relay com o checkpoint
  travado recebe 0 sem esperar (`SKIP LOCKED`).
- **`reserve`** marca até `limit` entregas pendentes com `leased_until = agora + lease` (60 s por padrão), com
  `FOR UPDATE SKIP LOCKED`, e confirma na hora; devolve `Relay::Delivery`, congelado, com o payload do evento.
- **`work`** reserva **uma entrega por vez**, logo antes do efeito, para que o lease cubra o efeito inteiro; chama o
  bloco **fora de qualquer transação** do relay e conclui. `complete` e `failed` só valem
  para quem ainda tem o lease: depois que ele vence, outro worker pode repetir a entrega, e a conclusão atrasada
  devolve `false` (contada como `lost`). A deduplicação é do consumidor, pelo `event_id` (ADR-014, §3).
- **Falha.** Uma exceção comum repete com espera de `min(1800 s, 10 s × 2^(n−1))` ±20%; a décima falha, ou
  `Relay::PermanentFailure`, leva a entrega a `dead` e a copia, com o evento, para `vetra.dead_deliveries` na mesma
  transação (ADR-024). Só a classe do erro é guardada, nunca a mensagem.
- **Manutenção.** `maintain` chama a rotina `vetra.outbox_maintain`, `SECURITY DEFINER` de dono `vetra_owner`,
  executável só pelo relay. Ela cria as partições diárias, de dia UTC, de hoje até `ahead` dias, com RLS forçado e
  sem concessões. Recupera as linhas de uma `DEFAULT` populada, movendo-as para a partição do dia numa transação que
  segura quem grava, sem perder nem duplicar. E remove por `DETACH` e `DROP` as partições mais antigas que
  `retention` dias, exceto quando há entrega pendente no dia ou evento que o relay ainda não leu. A rotina trava,
  nesta ordem e antes de tudo, o checkpoint, a outbox e as entregas, já no modo mais forte de que precisa; o
  `relay!` trava o checkpoint e depois lê a outbox, e a reserva e a falha travam a outbox antes das entregas. Uma
  materialização em curso termina antes, as entregas dela contam como pendências, e não há ciclo de locks. Obtidos
  os locks, quem grava espera a manutenção terminar; o `lock_timeout` de 3 s limita só a espera da rotina por cada
  lock, e ela falha sem alterar nada se não os obtiver. As entregas
  mortas ficam em `vetra.dead_deliveries`, fora da purga. Devolve o que criou, recuperou, removeu e manteve.
  `vetra outbox:maintain [--ahead 3] [--retention 7]` faz o mesmo pela linha de comando, com `DATABASE_URL`
  carregando a senha do `vetra_relay`.
- Com RLS forçado também para o dono, a rotina age por políticas próprias do `vetra_owner` na outbox, nas
  entregas, nas partições `DEFAULT` e no checkpoint. O relay tem `SELECT` na outbox; `SELECT`, `INSERT` e `UPDATE`
  nas entregas; `SELECT` e `INSERT` nas entregas mortas; `SELECT` e `UPDATE` no checkpoint. Não lê as tabelas da
  aplicação, as chaves nem as partições diretamente, e a aplicação não executa a rotina.

## Idempotência da operação

`Vetra::Data::Idempotency` ([ADR-043](adr/043-registro-de-idempotencia-da-operacao.md)) é da borda confiável, dentro da unidade
de trabalho (etapas 4 e 7 do ADR-016); o `call` da aplicação nunca o recebe. O `Runner` a liga ao adaptador, por `run(..., idempotency_key:)`.

```ruby
work.transaction(tenant_id: tenant.id, actor_id: actor.id, op_id: operation_id, cmd: 'crm.create_lead') do |unit|
  idempotency = Vetra::Data::Idempotency.new(unit)
  claim = idempotency.claim!(command: 'crm.create_lead', key: request_key, input: input)
  next claim.result if claim.replay            # a repetição devolve o resultado guardado, sem executar
  result = execute(unit)                       # o call
  idempotency.complete!(claim, result)         # JSON de até 64 KiB, guardado na mesma transação
  result
end
```

- `claim!` insere `(tenant, comando, chave)` com o hash da entrada e o principal (o `actor_id`, `system:<handler>` do ator de
  sistema, ou nulo para o visitante). A mesma chave com outra entrada **ou** outro principal é `data_idempotency_key_reuse`, sem
  devolver o resultado nem dizer qual dos dois diferiu. Uma chave em uso por uma operação aberta faz o `INSERT` esperar: se a outra
  confirma, a repetição devolve o resultado dela; se desfaz, a chave é nossa; passado o `lock_timeout`, é `Conflict(:lock_timeout)`.
- A chave tem de 1 a 255 caracteres ASCII visíveis. A origem `:event` exige `event: { handler:, event_id:, event_created_at: }`, que
  a retenção usa; só existe numa aplicação com outbox.
- `complete!` guarda o resultado na mesma transação; o rollback da unidade desfaz a chave e o resultado juntos. Só aceita o claim
  novo que `claim!` emitiu nesta unidade (registrado por identidade do objeto): um replay, um claim de outra transação, um `Claim`
  construído à mão e uma segunda conclusão são `data_idempotency_state`, e o `UPDATE` exige `result IS NULL` e o mesmo principal. O
  resultado é JSON de até 64 KiB **no banco** (`octet_length(result::text)`, sobre o `jsonb` normalizado, com chaves repetidas reduzidas e
  números reescritos): o `CHECK` decide a fronteira, e Ruby só impõe o limite adicional de 1 MiB ao payload serializado.
  Enquanto a cifra do ADR-013 não existe, um resultado com campo pessoal não deve ser guardado em claro (o `Runner` o recusa antes da etapa 4).
- **Purga.** A aplicação nunca apaga chaves. `Relay#purge_idempotency(retention_hours: 24, batch: 1000)` apaga, em lotes, a partir de um corte fixado uma vez no relógio do PostgreSQL, as chaves de
  adaptador mais velhas que o prazo e, numa aplicação com outbox, as de evento cuja entrega já não existe (nem em `deliveries` nem em
  `dead_deliveries`) e que também passaram do prazo. `vetra idempotency:purge [--retention-hours 24] [--batch 1000]` faz o mesmo pela
  linha de comando, com `DATABASE_URL` carregando a senha do `vetra_relay`.

## Aplicações globais

Blog e chat usam `UnitOfWork.new(db, scope: :global)`, sem emissor. A transação recebe `op_id`, `cmd` e
`actor_id` UUID para autenticado ou `nil` para visitante; `tenant_id` e `system_actor` devem ser `nil` (não há ator de
sistema sem tenant). As identidades ficam em
Ruby: não há emissão nem instalação de contexto SQL, e as duas funções SQL retornam NULL. Isso corresponde ao plano atual,
sem RLS de tenant/escopo ou revisão nessas aplicações; a autorização é da aplicação. A unidade global recusa
`access(multi_tenant: true)`. Escolher esse modo depende da IR, nunca de parâmetro do usuário.

## Diagnósticos e sigilo

| Código | Significado |
|---|---|
| `data_key` | Kid/chave ausente ou fora do formato/tamanho |
| `data_validity` | TTL fora de 1 a 120 segundos inteiros |
| `data_context` | Identidades, comando ou relógio inválidos |
| `data_scope` | Escopo inválido, emissor ausente para tenant ou tabela multiempresa em unidade global |
| `data_connection` | Adaptador/login incompatível ou falha ao abrir pool como vetra_app |
| `data_named_statement` | Tentativa de prepare/call |
| `data_transaction_nested` | Tentativa de abrir unidade dentro de uma transação |
| `data_transaction_required` | Operação sem unidade e transação ativas na fibra |
| `data_context_install` | Falha ao instalar contexto; causa do driver omitida por sigilo |
| `data_repository` | Entidade/capacidade não encontrada na IR |
| `field_name_collides_with_record` | Normalização do DSL: campo ou predicado de grupo de enum colide com método do registro; aponta o campo/grupo e sugere renomear |
| `data_record_type` | Campo ou predicado de enum em colisão com método do registro |
| `data_relation` | Junção inelegível ou colisão de métodos gerados de vínculo |
| `data_field` | Campo desconhecido ou expressão usada como nome de campo |
| `data_value` | Valor inválido para o tipo, nulidade, limites ou precisão |
| `data_read_value` | Linha do banco incompatível na conversão ou nas invariantes residuais, sem causa/valores |
| `data_assignment` | Tentativa de atribuir identidade, tenant ou timestamp reservado |
| `data_query` | Bloco ou limite inválido na consulta restrita |
| `data_read_only` | Escrita/lock sem capacidade ou unidade gravável |
| `data_transition` | Alteração de transição fora do comando dono |
| `data_required_link` | Remoção de vínculo obrigatório de `include_on_create` |
| `data_record_not_found` | Registro ausente ou invisível |
| `data_conflict` | Unicidade, FK ou deadlock (`Conflict#kind`) |
| `data_lock_timeout` | Espera por lock excedida (55P03), `Conflict(:lock_timeout)`, retentável |
| `data_statement_timeout` | Instrução cancelada (57014), `StatementTimeout`, retentável |
| `data_serialization` | Conflito de serialização (40001), `SerializationFailure`, retentável |
| `data_timeout` | Timeout por operação ou teto do verificador fora do intervalo/tipo aceito |
| `data_isolation` | Isolamento diferente de `:read_committed`/`:serializable` |
| `data_limits` | Verificador inválido ou parâmetros efetivos ausentes, zero, malformados ou excessivos |
| `data_access_denied` | Banco recusou o acesso (42501) |
| `data_database` | Outra falha do banco, sem detalhes do driver |
| `data_event` | Emissão sem evento declarado pelo comando, registro de outra IR ou projeção inconsistente |
| `data_event_personal` | Payload com campo pessoal; a unidade inteira é desfeita |
| `data_relay_connection` | Pool do relay fora do `vetra_relay` ou falha ao abri-lo, sem detalhes do driver |
| `data_relay_handler` | Handler sem evento declarado no grafo |
| `data_relay_limit` | Limite, lease ou dias fora do intervalo aceito |
| `data_relay_transaction` | Operação do relay chamada dentro de outra transação |
| `data_idempotency_key_reuse` | A chave de idempotência já foi usada com outra entrada ou por outro principal (422), sem devolver o resultado |
| `data_idempotency_state` | A chave não tem resultado confirmado, ou o resultado foi concluído sem reivindicação |
| `data_idempotency_result` | Resultado que não é JSON válido ou passa de 64 KiB |
| `data_idempotency_input` | Entrada que não é JSON, e portanto não tem hash canônico |
| `data_idempotency_key` | Chave fora de 1 a 255 caracteres ASCII visíveis, ou origem sem os dados da retenção |

`Token#value` exporta explicitamente o token para o protocolo. Não o registre, nem chave/hexadecimal/argumentos
de assinatura. `inspect`/`to_s` do token, emissor, contexto e unidade são redigidos. O logger do Sequel não
recebe a chamada sensível nem sua falha; as demais instruções continuam observáveis. Logs do servidor,
instrumentação própria do driver e dumps de memória precisam da mesma política operacional de sigilo.

## Sonda no PostgreSQL 17 e 18

Com bootstrap do ADR-036 em cluster descartável e credencial de superusuário para criar/remover bancos:

```sh
DATABASE_URL=... VETRA_APP_PASSWORD=... bundle exec ruby script/sonda_vetra_data.rb
```

A sonda aplica os planos integrados do mini CRM e do blog sob `vetra_migrator`, com a mesma conferência de
identidade/poderes da sonda de contexto. Provisiona chave aleatória por parâmetros e abre **login real**
`vetra_app` pelo Sequel, com pool de uma conexão. Não altera papéis ou arquivos. São esperadas 23 verificações:

| Verificações | Resultado esperado |
|---|---|
| 1 e 18: aplicação dos dois planos | Migrador como usuário/sessão, sem superusuário/CREATEDB/CREATEROLE, dono do banco |
| 2: login do runtime | current_user e session_user são vetra_app |
| 3 e 4: fora da unidade | Duas identidades NULL; guarda Ruby recusa acesso antes do SQL |
| 5: vetor Ruby/banco | MAC do emissor idêntico ao hmac de pgcrypto para a mesma mensagem/chave |
| 6 a 8: abertura, commit e reutilização | Identidades corretas dentro; GUC ausente/vazia e identidades NULL fora e no próximo BEGIN, mesmo backend |
| 9 a 11: dois tenants e WITH CHECK | Ambos conseguem gravar; cada um só lê suas linhas; escrita cruzada falha 42501 |
| 12: savepoint | Alteração local desfeita, contexto preservado e exatamente um set_config na unidade |
| 13: exceção externa | Dados desfeitos e contexto limpo |
| 14: read_only | UPDATE falha 25006 e conexão volta limpa |
| 15: expiração | Duas identidades NULL e nenhuma linha de tenant |
| 16: revogação | Token inicialmente válido passa a NULL na instrução seguinte em READ COMMITTED |
| 17: protocolo | pg_prepared_statements vazio na conexão reutilizada |
| 19 a 22: blog global | Grava sem tenant/chave/token; visitante consulta em READ ONLY com savepoint; guarda recusa tabela multiempresa; statements nomeados vazios |
| 23: catálogo | Nenhum papel global alterado |

A numeração da saída é a ordem dos rótulos, sem IDs fixos; a tabela agrupa os resultados por assunto. A auditoria
executa a sonda no 17/18 e a inclui na CI. Até essa execução, só sintaxe e testes sem banco estão conferidos.
O custo com RLS/concorrência/pooler e a construção dos registros continuam sujeitos aos gates dos ADRs 022 e 023.

## Sonda dos limites da unidade

```sh
DATABASE_URL=... VETRA_APP_PASSWORD=... VETRA_RELAY_PASSWORD=... bundle exec ruby script/sonda_limites_unidade.rb
```

Exige cluster PostgreSQL 17/18 descartável e bootstrap ADR-036/040. Aplica os planos integrados do blog e mini CRM
como `vetra_migrator`, operações com login real `vetra_app` e relay/consumo como `vetra_relay`.
São esperadas **15 verificações**:

- Dois conjuntos de planos aplicados pelo migrador, sem poderes administrativos.
- Cinco recusas de abertura (dois parâmetros zero; cada um zero isoladamente; cada um acima do teto) e uma
  aceitação com os parâmetros corretos, sempre reabrindo o login após ALTER ROLE.
- Dois estouros reais em `Repository#lock!`: espera por lock com `lock_timeout` mais curto, e a mesma espera com
  `statement_timeout` mais curto. Confere tipo, diagnóstico, sigilo e rollback total, inclusive da linha e do evento
  anteriores ao savepoint, mesmo com resgate do erro, e restauração dos limites locais.
- READ COMMITTED padrão e SERIALIZABLE por opção: outra conexão confirma a alteração depois da leitura; a escrita
  obsoleta gera `SerializationFailure`, sem repetir e sem deixar a linha da unidade abortada.
- Uma medição com/sem o verificador, contando uma leitura conjunta por unidade e nenhuma adicional nos savepoints.
- Dois encerramentos pelo **servidor** no mini CRM: escritor em outro tenant mantém `xid` aberto, e um evento
  posterior confirmado fica atrás dele. Com `transaction_timeout` curto, o backend executa `pg_sleep`; com
  `idle_in_transaction_session_timeout` curto, fica sem consultas. A sonda observa o desaparecimento do backend
  antes de qualquer limpeza, o avanço do `xmin`, a ausência da linha abortada e o relay materializando e consumindo
  o evento por todos os handlers declarados, uma única vez.
- Restauração dos parâmetros e igualdade dos catálogos de papéis, vínculos e configurações.

Os limites de teste (3 s) são `ALTER ROLE vetra_app IN DATABASE <banco efêmero> SET ...`, isolados dos demais bancos;
o `ensure` os remove, encerra conexões e apaga os bancos próprios. Nunca altera configuração global preexistente.
O descarte forçado de backend só ocorre na limpeza de um teste que falhou e não conta como prova de timeout.
Sintaxe e mocks foram conferidos no sandbox; **a execução real, a medição e a inclusão na CI cabem ao Claude**.

## Sonda do relay

`script/sonda_relay.rb` usa o mini CRM e o blog num PostgreSQL 17 ou 18 descartável, com o bootstrap que cria o
`vetra_relay`. Aplica os três planos pelo `db:migrate`, grava eventos como `vetra_app` pelos comandos reais e roda o
relay, as entregas e a manutenção como `vetra_relay`, com consumidores simulados.

| Verificação | Resultado esperado |
|---|---|
| Planos e manutenção | Os três planos aplicam; a manutenção cria as partições de hoje a três dias e não repete; o `db:migrate` as aceita, e recusa uma com concessão a mais ou com intervalo errado |
| Relay | Eventos na partição do dia; uma entrega por handler, uma vez só; uma transação aberta segura a faixa; um rollback não gera entrega; outro relay com o checkpoint travado recebe 0; sem handlers, o checkpoint avança |
| Entregas (CRM) | Dois workers não reservam a mesma entrega; um worker que cai é repetido depois do lease, com um efeito no provedor com chave e dois sem; o efeito roda sem transação aberta; espera crescente sem a mensagem do erro; `dead` na décima falha e na falha definitiva, com a cópia |
| Partições (CRM) | Uma `DEFAULT` populada é recuperada sem perder nem duplicar; a purga mantém o dia com evento não lido ou entrega pendente e o remove depois, sem tocar as entregas mortas; com uma materialização em curso, a purga espera e mantém as entregas dela, e a criação de partição espera o relay e um worker sem deadlock |
| Isolamento | O relay não lê a aplicação, as chaves nem as partições e não grava na outbox; a aplicação não executa a manutenção nem lê entregas e checkpoint; nenhuma instrução nomeada; nenhum papel global alterado |

São 23 verificações no mini CRM, 14 no blog e a dos papéis: 38 no total, todas passando no PostgreSQL 17.11 e no
18.6.

## Sonda da outbox

`script/sonda_outbox.rb` usa os três exemplos com eventos num PostgreSQL 17 ou 18 descartável, com o bootstrap do
ADR-036. Aplica o `0001` como `vetra_migrator`, grava dados, aplica o `0002` e confere a forma das tabelas. Depois,
como `vetra_app`, roda o corpo real de `win_lead` ou `publish_post` e emite pela unidade de trabalho.

| Verificação | Resultado esperado |
|---|---|
| Planos e forma | O `0002` entra sobre dados; outbox e entregas particionadas com `DEFAULT`, entregas mortas sem partição, RLS forçado e dono `vetra_owner` |
| Emissão | Uma linha na `DEFAULT` com o `xid8` da transação, o payload projetado e o contexto; notificação só com o tenant, depois do commit |
| Rollback e ordem | Rollback depois da emissão não deixa linha nem notificação; eventos seguintes têm `xid8` e `seq` crescentes |
| Campo pessoal (CRMs) | O email projetado no `lead.won` desfaz a unidade, mesmo com o erro resgatado |
| Recusas | Outro tenant, outro ator, `created_at`, `xid8` e `seq` são recusados; `SELECT`, `UPDATE`, `DELETE`, `TRUNCATE`, as partições e as entregas também |
| Fim | Nenhuma instrução nomeada, conexão sem contexto e nenhum papel global alterado |

São 12 verificações em cada CRM, 11 no blog e a dos papéis: 36 no total, todas passando no PostgreSQL 17.11 e no
18.6.

## Sonda dos repositórios

```sh
DATABASE_URL=... VETRA_APP_PASSWORD=... bundle exec ruby script/sonda_repositorios.rb
```

Exige o mesmo bootstrap e PostgreSQL descartável 17/18. Aplica o plano inicial de cada exemplo como
`vetra_migrator`, abre login real `vetra_app`, provisiona chave efêmera nos CRMs e usa contexto global sem
token no blog/chat. O harness acessa deliberadamente as closures privadas já verificadas pelo linker e injeta
as capacidades na ordem vinculada; a capacidade de relógio é um valor que expõe apenas `now`.
As revendas são preparadas como `vetra_migrator`, depois da confirmação da raiz: o plano existente só
permite leitura em `dealers`. Usuários, vínculos e leads são criados pelos repositórios como `vetra_app`.
O harness não cria um executor público nem avalia políticas Ruby.
As 72 verificações são:

| Posição na saída | Verificação e resultado esperado |
|---|---|
| 1, 18, 37, 50 | Os quatro planos aplicam com usuário/sessão migrador, dono do banco e sem poderes administrativos |
| 2, 19 | Dois tenants criados pelos repositórios; tenant atribuído pelo contexto, created_at UTC, valor monetário exato e registro compartilhável |
| 3, 20 | Consulta, find e raiz veem somente o tenant corrente, nos dois sentidos |
| 4, 21 | ID inexistente e ID de outro tenant geram RecordNotFound idênticos |
| 5, 22 | Objeto de outra empresa com tenant forjado não permite update |
| 6, 23 | Tenant explícito e created_at na entrada são recusados |
| 7, 24 | Status protegido fora do comando falha antes do UPDATE e permanece new |
| 8, 25 | Corpo real de win_lead grava won com contexto assinado; closed? é verdadeiro |
| 9, 26 | Segundo win_lead falha pela regra do corpo e desfaz a unidade |
| 10, 27 | Saída de won pelo comando genérico também é recusada |
| 11, 28 | Unidade READ ONLY e capacidade read recusam escrita/lock |
| 12, 29 | PK duplicada produz Conflict unique |
| 13, 30 | Exclusão de raiz referenciada produz Conflict foreign_key |
| 14, 31 | Repositório fora da unidade falha explicitamente |
| 32 | Outro vendedor cria lead na revenda preparada pelo migrador, no mesmo tenant |
| 33 | RLS esconde esse lead do primeiro ator tanto em find quanto em update |
| 38 | Blog atribui autor, draft e approved false; published_at permanece nulo |
| 39 | Corpo real de find_post funciona com visitante, repositório read e unidade READ ONLY |
| 40 | approved e published_at não mudam fora de seus comandos |
| 41 | Corpo real de publish_post grava published e data do relógio, preservando created_at |
| 42 | Segunda publicação falha pela regra do corpo |
| 43 | Corpo real de approve_comment atualiza por ID e grava approved true |
| 44 | delete devolve o valor removido; find seguinte é RecordNotFound |
| 45 | FK de post inexistente produz Conflict foreign_key |
| 51 | Chat normaliza emails e cria vínculo do dono ao criar a sala |
| 52 | add_member real repetido mantém uma única junção |
| 53 | add_member_by_email real consulta igualdade/first(2) e inclui o membro |
| 54 | Email ausente é recusado pela regra do corpo |
| 55 | remove_member real repetido não falha e deixa o vínculo ausente |
| 56 | Corpo real recusa remover o dono |
| 57 | Repositório também recusa remover o dono, independentemente do corpo |
| 58 | Alvo inexistente é RecordNotFound antes de gravar junção |
| 59 | Email normalizado duplicado produz Conflict unique |
| 60 | 105 mensagens recebem autor e o mesmo created_at na operação |
| 61 | room_page real retorna as últimas 100 por created_at/id, ainda em ordem ascendente e congeladas |
| 62 | my_rooms real ordena nome e usa ID para desempatar |
| 63 | Consulta recusa campo desconhecido e bloco |
| 64 | Capacidade read recusa vínculo dentro de unidade gravável |
| 65 | Vínculo e terminal de consulta fora da unidade são recusados |
| 66, 67 | Dois backends disputam o lock do dono: inclusão sem duplicação e remoção ausente idempotente; nenhum statement nomeado no segundo backend |
| 46, 68 | Blog/chat não instalam token e mantêm identidades SQL NULL |
| 15, 34, 47, 69 | Inventário confirma execução de todos os corpos call de comandos e consultas de cada exemplo |
| 16, 35, 48, 70 | Nenhum statement nomeado no backend principal reutilizado |
| 17, 36, 49, 71 | Conexão devolvida sem contexto |
| 72 | Nenhum papel global alterado |

Sintaxe e execução dos corpos com `Sequel.mock` são conferidas sem banco. O Claude executa esta sonda no 17/18
e acrescenta a chamada à CI. Só a execução real confirma SQL, triggers, RLS e corridas; serialização/deadlock
são classificados nos testes sem banco. O gate de custo dos registros continua na medição do ADR-022.

## Sonda do custo do contexto e dos registros

`DATABASE_URL=... VETRA_APP_PASSWORD=... bundle exec ruby script/sonda_custo_contexto.rb`, com o mesmo bootstrap e
cluster descartável 17/18. As cinco conferências funcionais esperadas são:

| Verificação | Resultado esperado |
|---|---|
| Isolamento antes de medir | Sem contexto/MAC inválido, zero linhas; token válido vê só as 4.000 linhas do tenant |
| Escopo por vínculo | Os mesmos IDs da política real para gerentes, vendedor, papéis mistos e ator sem vínculos |
| Planos da leitura | Nenhum Seq Scan da tabela inteira de vínculos, com 1, 10 e 100 revendas |
| Registros | 10.000 valores iguais entre conversão direta e repositório completo, com Money, UTC e compartilhamento |
| Papéis | Nenhum papel global alterado |

Na parte de registros, sete rodadas alternam o repositório completo e a série Sequel + conversão das mesmas
linhas. A construção é cronometrada diretamente, com congelamento; não é a diferença entre duas consultas.
Relata ms totais, µs por registro e a razão construção/consulta, ainda contra **10%**. A carga real continua uma
aproximação de nove campos lógicos/dez colunas. O script Ruby cobre também dez campos mistos. Não há construção
sob demanda no caminho escolhido nem conversão transferida para acessos posteriores.

A execução no PostgreSQL 17.11 e 18.6 passa as cinco conferências e mede a construção em 7 a 10 µs por registro, de 40% a 56%
da consulta (antes da C11, de 136% a 167%): o gate de 10% do ADR-022 não é alcançado ([ADR-042](adr/042-construcao-dos-registros.md)).
Os limiares dos ADRs 022 e 023 continuam informativos na sonda, sem cumprir o teste de aceitação 6 do ADR-023.

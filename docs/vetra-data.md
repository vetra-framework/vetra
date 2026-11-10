# Vetra Data

O Vetra Data abre unidades de trabalho PostgreSQL pelo Sequel, como `vetra_app`, e emite o contexto assinado
validado pelas funções dos planos atuais. O contrato está no [ADR-039](adr/039-unidade-de-trabalho-e-repositorios.md).
Os repositórios são gerados da IR e vinculados às capacidades e à unidade. O executor de operações ainda não existe.

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
                 op_id: operation_id, cmd: 'crm.create_lead') do |unit|
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
permite continuar o bloco externo depois do rollback do savepoint; sem resgate, toda a operação é desfeita.
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

`RecordNotFound#code` é `data_record_not_found`. `Conflict#code` é `data_conflict`, e `kind` classifica
`:unique`, `:foreign_key`, `:serialization` ou `:deadlock`. Mensagem, `cause` e inspeção não carregam o erro,
SQL nem valores do driver. Recusa SQL de acesso é `data_access_denied`, não conflito. Não há repetição automática.
Erros SQL devem ser resgatados fora da unidade ou fora de `compose`, depois do rollback.

Ainda não são avaliados `authorize`, papéis Ruby, permissões por campo nem a reautorização do estado final
(etapa 6 do ADR-016). O isolamento disponível é o contexto da unidade e o RLS dos planos dos CRMs, nos limites
do ADR-037; a aplicação continua responsável por autorizar as chamadas, inclusive administração de vínculos.
A emissão para a outbox e o relay estão descritos abaixo; os handlers reais, o histórico, o executor das oito
etapas e a execução dos descritores builtin são entregas posteriores.

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

## Aplicações globais

Blog e chat usam `UnitOfWork.new(db, scope: :global)`, sem emissor. A transação recebe `op_id`, `cmd` e
`actor_id` UUID para autenticado ou `nil` para visitante; `tenant_id` e `system_actor` devem ser `nil` (não há ator de
sistema sem tenant). As identidades ficam em
Ruby: não há emissão nem `set_config`, e as duas funções SQL retornam NULL. Isso corresponde ao plano atual,
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
| `data_conflict` | Unicidade, FK, serialização ou deadlock |
| `data_access_denied` | Banco recusou o acesso (42501) |
| `data_database` | Outra falha do banco, sem detalhes do driver |
| `data_event` | Emissão sem evento declarado pelo comando, registro de outra IR ou projeção inconsistente |
| `data_event_personal` | Payload com campo pessoal; a unidade inteira é desfeita |
| `data_relay_connection` | Pool do relay fora do `vetra_relay` ou falha ao abri-lo, sem detalhes do driver |
| `data_relay_handler` | Handler sem evento declarado no grafo |
| `data_relay_limit` | Limite, lease ou dias fora do intervalo aceito |
| `data_relay_transaction` | Operação do relay chamada dentro de outra transação |

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

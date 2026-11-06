# Vetra Data

O Vetra Data abre unidades de trabalho PostgreSQL pelo Sequel, como `vetra_app`, e emite o contexto assinado
validado pelas funções dos planos atuais. O contrato está no [ADR-039](adr/039-unidade-de-trabalho-e-repositorios.md).
Repositórios gerados e o executor de operações ainda são entregas próprias; esta API é infraestrutura do runtime.

## Configurar o processo

```ruby
require 'vetra/data'

issuer = Vetra::Data::ContextIssuer.from_env
db = Vetra::Data.connect(ENV.fetch('DATABASE_URL'), max_connections: 8)
work = Vetra::Data::UnitOfWork.new(db, issuer: issuer)
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
  # A C10 fornecerá repositórios ligados a esta unidade.
  unit.compose do
    # Mesmo contexto, savepoint próprio.
  end
end

work.read(tenant_id: tenant.id, actor_id: actor.id,
          op_id: operation_id, cmd: 'crm.read_lead') do |unit|
  # Transação READ ONLY; composição mantém essa restrição.
end
```

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
fibra que a abriu. Nunca contém chave nem token. Para a C10, cada operação terminal do repositório usará
`unit.access(multi_tenant: true/false) { |db| ... }`, sem devolver pool ou dataset ao código da aplicação.
A guarda recusa um acesso multiempresa fora da unidade com `data_transaction_required`, antes de executar SQL,
mesmo que exista um BEGIN externo. A C8 testa a guarda; a C10 a aplica nos repositórios.

## Aplicações globais

Blog e chat usam `UnitOfWork.new(db, scope: :global)`, sem emissor. A transação recebe `op_id`, `cmd` e
`actor_id` UUID para autenticado ou `nil` para visitante; `tenant_id` deve ser `nil`. As identidades ficam em
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
O custo com RLS/concorrência/pooler e os registros da C10 continuam sujeitos aos gates dos ADRs 022 e 023.

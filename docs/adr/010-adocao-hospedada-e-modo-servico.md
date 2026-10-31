# ADR-010: Adoção hospedada em Rails ou modo serviço

- Status: aceito
- Data: 2026-10-30
- Depende de: ADR-002 (somente PostgreSQL), ADR-003 (Sequel e camada de repositórios)
- Relacionados: ADR-005 (RLS e contexto assinado), ADR-006 (isolamento de domínios), ADR-007 (comando e
  adaptadores), ADR-014 (outbox), ADR-015 (migrações), ADR-016 (ciclo de vida da operação), ADR-020 (entrega
  live)

## Contexto

Ninguém reescreve um sistema em produção para trocar de framework. Um framework novo que só serve para
projetos novos tem pouca chance de ser provado onde importa: num módulo comercial real, com dados e usuários
reais. A proposta diz que o Vetra "só se torna independente depois de provar vantagem medida em um módulo
comercial real" e, por isso, nasce como uma camada dentro de aplicações Rails existentes.

Isso cria dois problemas: **o Vetra precisa conviver com o Rails no mesmo processo e no mesmo banco**, e
**nem toda aplicação Rails pode hospedá-lo** (versão antiga de Ruby ou de Rails, outro banco).

## Decisão

**A adoção tem dois caminhos de entrada, o modo hospedado e o modo serviço, e só depois de um domínio provado
em produção existe o modo independente.** A migração é por domínio, nunca de uma vez.

### 1. Pré-requisito do modo hospedado

O app Rails hospedeiro precisa rodar em **Ruby 4** e em versão do Rails compatível, e usar **PostgreSQL**
(ADR-002). Aplicações em Ruby ou Rails antigos, ou com outro banco, **não podem** carregar o Vetra no mesmo
processo e usam o modo serviço.

### 2. Modo hospedado

- O Vetra é montado como **aplicação Rack dentro do Rails** e compartilha a sessão e a autenticação.
- **O ator vem da sessão do Rails.** O adaptador Rack resolve o ator e o tenant a partir da sessão compartilhada,
  por um resolvedor que a aplicação declara, e nunca do corpo da requisição (ADR-007, §2). O contexto assinado
  (ADR-005) é emitido na etapa 4 do ADR-016 com essa identidade. A forma do resolvedor é detalhe do adaptador.
  Papéis e grupos que existem só no Rails seguem o ADR-020, §8: são materializados em tabelas do Vetra por um
  comando, ou geram a revisão por `authz.touch!`.
- O Sequel **reutiliza a conexão do Active Record** (pela gem `sequel-activerecord_connection`, ADR-003), de
  modo que o código Rails e os comandos Vetra participam da **mesma transação** e do **mesmo contexto de
  RLS**.
- Os cinco testes obrigatórios são os do ADR-003 (item 10): o Active Record inicia a transação e o Sequel opera
  dentro dela; o inverso; uma exceção desfaz os dois; o rollback de um savepoint não dispara eventos nem
  callbacks indevidos; a conexão volta ao pool sem contexto da operação anterior.
- Para o RLS valer, a conexão compartilhada precisa usar um papel de banco **sem `BYPASSRLS` e sem
  superusuário** (ADR-005). Um papel de superusuário no app hospedeiro anularia o isolamento das tabelas do
  Vetra. É requisito de adoção, verificado por `vetra doctor`.

### 3. Modo serviço

- O Vetra roda como **serviço independente**, e a comunicação com o legado é por **API e por eventos via
  outbox** (ADR-014).
- Se o serviço **compartilha o banco** com o legado, cada tabela tem **um único dono**: ou é do Rails, ou é do
  Vetra, nunca dos dois com escrita.
- O serviço tem o seu próprio PostgreSQL quando o do legado não puder ser usado (versão abaixo da mínima do
  ADR-002, por exemplo).

### 4. Pontes

- **Models Active Record existentes** entram no Vetra como **fontes somente leitura**.
- **Eventos do Vetra** são publicados para o Rails por outbox.
- **Jobs do Rails** podem disparar comandos Vetra; o comando passa pelas oito etapas (ADR-016) como em
  qualquer superfície (ADR-007).
- **O Vetra não escreve em tabelas do Rails**, nem no modo hospedado nem no modo serviço. O grafo não enxerga as
  validações e os callbacks do Active Record, então as garantias das etapas 6 e 7 do ADR-016 (reautorização sobre
  o estado final, campos de transição, evento, histórico e auditoria) não valeriam para essas escritas. Para
  alterar dado do Rails, o Vetra publica um evento pela outbox, e um handler (ADR-014) aciona o Rails por API ou
  job; o Rails faz a escrita. Permitir a escrita por uma ponte exige um ADR novo, com um caso real e uma medição.

### 5. Fronteira entre as duas convenções

- Cada domínio é de um lado ou do outro, com **fronteira explícita** (ADR-006).
- É **proibido o acesso direto a models Rails** dentro de um domínio Vetra, fora das pontes. O analisador do
  ADR-001 deve tratar `ActiveRecord` num `call` como acesso fora do repositório (ADR-003).
- O esquema das tabelas do Vetra é gerado pelo plano de migração (ADR-015); as migrações do Rails continuam
  sendo as das tabelas do Rails.

### 6. Estrangulamento por domínio

- Domínios migram **um a um**, cada um com **critério de saída medido**. O critério é parte do planejamento do
  domínio, escolhido antes da migração, a partir das métricas da proposta (tempo para implementar uma mudança
  de regra, cenários de isolamento, latência p95).
- Um domínio só deixa o Rails depois que o critério de saída foi atingido.

### 7. Modo independente

Só depois de **ao menos um domínio em produção real**: gerador de projeto, boot e deploy próprios. Até lá, as
fases 0 a 2 do roadmap rodam hospedadas num app Rails 8.1 com Ruby 4, e as aplicações legadas usam o modo
serviço.

## Alternativas rejeitadas

- **Framework independente desde o início** (a alternativa da proposta): exige reescrever a aplicação e
  entregar tudo antes de provar qualquer coisa. É o risco da "síndrome do segundo sistema".
- **Só modo serviço:** funciona para qualquer legado, mas perde o caminho de adoção mais curto (mesma sessão,
  mesma transação, mesmo banco) para quem já está em Ruby 4.
- **Só modo hospedado:** deixaria de fora a maior parte dos sistemas existentes.
- **O Vetra escrevendo livremente em tabelas do Rails:** o grafo não vê validações nem callbacks do Active
  Record, então as garantias de transição e de evento não valeriam para essas escritas.
- **Escrita em tabelas do Rails por uma ponte declarada** (a hipótese que a proposta deixou em aberto): nenhum
  caso real a pede, e o problema é o mesmo, porque a ponte continua sem enxergar os callbacks. Adotá-la depois,
  por ADR novo, com um caso real e uma medição, é a saída.
- **Migrar o sistema inteiro de uma vez:** sem critério de saída por domínio, não há como saber se a aposta
  funciona.

## Consequências

- Há um **caminho real de adoção**, ao custo de duas convenções no mesmo repositório.
- O modo hospedado depende de uma ponte de terceiros (ADR-003) e de uma versão do Rails compatível com o
  Ruby 4.
- O Vetra depende de que o app hospedeiro use um papel de banco sem privilégio de contornar o RLS.
- Cada domínio migrado precisa de um critério de saída e de medição, o que dá trabalho.
- No modo serviço, a consistência entre Rails e Vetra é por eventos (eventual), não por transação.

## Garantias e seus níveis

| Garantia | Nível | Mecanismo |
|---|---|---|
| Rails e Vetra na mesma transação (modo hospedado) | Verificável por testes | Os cinco testes do ADR-003 |
| Isolamento de tenant nas tabelas do Vetra no modo hospedado | Transacional, condicionado | RLS, desde que o papel de banco não tenha `BYPASSRLS` |
| Nenhuma tabela com dois donos com escrita | Operacional | `vetra doctor` e a regra de dono único |
| Domínio Vetra não acessa models Rails fora das pontes | Estrutural, com os limites do ADR-004 | Análise do `call`; código que abra conexão própria escapa |
| O Vetra não escreve em tabela do Rails | Estrutural, com os limites do ADR-004 | Pontes somente leitura e a mesma análise do `call` |
| O ator vem da sessão do Rails, nunca do corpo da requisição | Verificável por testes | Resolvedor do adaptador Rack (ADR-007, §2) |
| Consistência entre Rails e serviço | Operacional | Eventos pela outbox, entrega pelo menos uma vez |

## Testes de aceitação

1. Os cinco testes de transação compartilhada entre Active Record e Sequel (ADR-003, item 10) passam.
2. O `vetra doctor` falha se a conexão compartilhada usa um papel com `BYPASSRLS` ou superusuário.
3. O Vetra montado como Rack no Rails compartilha a sessão e a autenticação: um usuário autenticado no Rails é
   o ator de um comando Vetra, e um corpo de requisição que traga outro ator não o altera.
4. Um model Rails existente é lido por uma ponte somente leitura, e uma tentativa de escrita pelo Vetra é
   recusada.
5. Um evento do Vetra chega ao Rails pela outbox; um job do Rails dispara um comando Vetra e passa pelas oito
   etapas.
6. No modo serviço, duas aplicações não escrevem na mesma tabela, e o `vetra doctor` acusa o contrário.
7. Um domínio sem critério de saída medido não é marcado como migrado.
8. Uma aplicação em Ruby ou Rails fora do pré-requisito é recusada no modo hospedado, com mensagem que
   aponta o modo serviço.

## Verificação preliminar

**O modo hospedado com o Active Record não foi exercitado.** O ADR-003 registra isso em "O que isto não cobre", e
nenhuma sonda do repositório mede a gem `sequel-activerecord_connection`. A transação e o contexto de RLS
compartilhados (§2) e os cinco testes do ADR-003 são, por isso, **hipótese** até rodarem contra um Rails real.
O que se mediu vale para o Sequel e o `pg` sozinhos (`script/sonda_adr003.rb`).

## Questões em aberto

- Escrita em tabelas do Rails pelo Vetra. Não adotada (§4). Volta por ADR novo, com um caso real e uma medição.
- Qual a menor versão do Rails compatível, e como o isolamento por fibras do Active Record se combina com o
  Falcon (a verificar na versão escolhida).
- A forma do resolvedor do ator no adaptador Rack (§2) e como uma entidade do Vetra referencia o usuário do
  Rails, que mora numa tabela de outro dono: chave estrangeira ou referência sem restrição.
- Quais são os critérios de saída padrão por domínio e quem os aprova.
- Como o Vetra convive com a política de migração do Rails quando as duas escrevem no mesmo esquema de banco.
- Gerador de projeto e deploy do modo independente: ficam para depois do primeiro domínio em produção.

# ADR-002: Somente PostgreSQL

- Status: aceito
- Data: 2026-10-30
- Dependem deste ADR (na data do aceite): 003 (Sequel e repositórios), 005 (RLS), 008 (ordem e continuidade dos
  eventos), 010 (adoção hospedada e modo serviço), 014 (outbox) e 015 (migrações)

## Contexto

A maior parte dos frameworks web tenta ser neutra quanto ao banco de dados. O custo dessa neutralidade é
trabalhar com o menor denominador comum: sem row-level security, sem `LISTEN`/`NOTIFY`, sem identificadores de
transação, sem `SKIP LOCKED`. Os mecanismos que o Vetra promete (isolamento multiempresa no banco, consultas
reativas, outbox sem perda, hierarquia de permissões auditável) usam esses recursos **como fundação**, não
como otimização opcional.

Se o núcleo suportasse vários bancos, cada garantia precisaria de uma implementação por banco, com testes
próprios, e a garantia real passaria a variar conforme o banco escolhido. Uma promessa de isolamento que vale
num banco e não em outro não é uma promessa.

## Decisão

**O núcleo do Vetra usa somente PostgreSQL.** MySQL, SQLite e outros bancos estão fora do escopo do núcleo.

### 1. Versão mínima: PostgreSQL 17

| Recurso | Usado por | Disponível a partir de |
|---|---|---|
| `ROW LEVEL SECURITY`, `FORCE ROW LEVEL SECURITY` | Isolamento multiempresa (ADR-005) | 9.5 |
| `security_invoker` em views | Views que respeitam o RLS (ADR-005) | 15 |
| `xid8`, `pg_current_xact_id()`, `pg_current_snapshot()`, `pg_snapshot_xmin()` | Ordem dos eventos (ADR-008) | 13 |
| `FOR UPDATE SKIP LOCKED` | Relay da outbox (ADR-014) | 9.5 |
| `LISTEN` / `NOTIFY` | Invalidação das consultas reativas (ADR-008) | Todas |
| Tabelas `UNLOGGED` | Presença e sinais efêmeros (ADR-019) | Todas |
| `transaction_timeout` | Evitar que uma transação longa segure o `xmin` (ADR-008) | **17** |
| Extensão `pgcrypto` | HMAC do contexto assinado (ADR-005) | Todas (extensão) |
| Replicação lógica | Reservado para uma evolução do transporte de eventos | 10 |

- A versão mínima é a **17**, pelo `transaction_timeout`. As demais exigências começam em versões anteriores.
- A **CI roda na versão mínima e na mais recente estável**. Uma versão nova entra na matriz assim que
  estiver disponível nos serviços gerenciados usados como referência.
- A mínima só sobe quando a versão atual sair do suporte da comunidade PostgreSQL, ou por razão técnica
  registrada em ADR. Subir a mínima é uma mudança anunciada com antecedência.

### 2. O que "somente PostgreSQL" significa na prática

- **Sem camada de abstração de banco no núcleo.** O SQL gerado e o SQL escrito à mão nos repositórios
  podem usar recursos do PostgreSQL diretamente. O Sequel é usado com o driver `pg` (ADR-003).
- **Sem SQLite nos testes.** Os testes rodam no PostgreSQL real, com os mesmos papéis de produção
  (ADR-005). Um banco "mais leve" para testes esconderia exatamente os erros que importam.
- **Extensões.** Só `pgcrypto` é obrigatória. Outras (por exemplo, `pg_trgm`) são opcionais e declaradas
  pela aplicação; o `vetra doctor` confere se estão instaladas.
- **Modo hospedado (adoção em apps Rails):** o app hospedeiro precisa usar PostgreSQL. Um Rails com outro
  banco não pode hospedar o Vetra; usa o modo serviço, com um PostgreSQL próprio para o Vetra.
- **Redis** é, no máximo, um adaptador opcional para sinais efêmeros (ADR-019). Nunca é um segundo banco da
  aplicação nem um requisito do núcleo.

### 3. Compatibilidade com serviços gerenciados e derivados

O Vetra exige poder: criar papéis e schemas, habilitar `pgcrypto`, usar `FORCE ROW LEVEL SECURITY`, abrir uma
conexão `LISTEN` direta (fora de pooler em modo de transação) e **não** exigir superusuário em runtime. Isso
é atendido por PostgreSQL gerenciado comum.

Bancos que se dizem compatíveis com PostgreSQL (derivados ou distribuídos) **não são suportados por
padrão**: RLS, `xid8` e `LISTEN` podem ter semântica diferente. Um derivado só passa a ser suportado depois
de passar na suíte de conformidade (`vetra doctor --conformance`), que testa justamente os recursos da
tabela acima, e fica listado na documentação como "verificado".

### 4. `vetra doctor` confere o ambiente

Versão do servidor, extensões, papéis do ADR-005 (sem `BYPASSRLS`, sem superusuário, não dono das tabelas),
`FORCE RLS` nas tabelas multiempresa, `LISTEN` direto, `transaction_timeout` e `idle_in_transaction_session_timeout`
configurados, sincronização de relógio entre aplicação e banco.

## Alternativas rejeitadas

- **Suporte multibanco** (MySQL, SQLite): cada garantia teria uma implementação por banco e os mecanismos
  centrais não têm equivalente. Rejeitado também na proposta.
- **Núcleo agnóstico com "melhorias" para PostgreSQL:** o isolamento e a entrega live variariam conforme o
  banco. Uma garantia opcional é uma garantia que alguém desliga sem perceber.
- **PostgreSQL mais Redis como requisitos:** adiciona uma peça operacional ao núcleo sem necessidade
  comprovada. Redis só entra quando a medição pedir.
- **Versão mínima 16:** era a hipótese da proposta. Sem `transaction_timeout`, o framework teria de proteger o
  `xmin` só com um vigia na aplicação, que é mais frágil.
- **Suportar qualquer banco "compatível com PostgreSQL" sem verificar:** transfere o risco ao usuário.

## Consequências

- Perde-se portabilidade: equipes que usam MySQL ou outro banco não podem adotar o Vetra no núcleo.
- Quem desenvolve precisa de um PostgreSQL local (o `bin/setup` cria um por contêiner, se for o caso), mesmo
  para testes rápidos.
- O Vetra ganha a possibilidade de empurrar regras para o banco (RLS, triggers, `CHECK`, FKs compostas) em
  vez de reimplementá-las em Ruby.
- A matriz de testes é pequena: duas versões de um só banco.
- A versão mínima 17 exclui instalações antigas; o modo serviço do Vetra (com seu próprio banco) é a saída
  para quem não pode atualizar o banco principal.

## Garantias e seus níveis

| Garantia | Nível | Mecanismo |
|---|---|---|
| O ambiente cumpre os requisitos do Vetra | Operacional | `vetra doctor` e `vetra doctor --conformance` |
| Os recursos usados existem na versão mínima | Verificável por testes | CI na mínima e na mais recente |
| Derivados do PostgreSQL | **Fora da garantia**, até passar na conformidade | Lista de "verificados" |

## Testes de aceitação

1. O boot recusa um servidor abaixo da versão mínima, com mensagem que cita a versão exigida e o recurso que
   a motiva.
2. O `vetra doctor` falha para: papel de aplicação com `BYPASSRLS`, tabela multiempresa sem `FORCE RLS`,
   `pgcrypto` ausente, `LISTEN` por pooler em modo de transação.
3. A CI executa toda a suíte nas duas versões da matriz.
4. O gerador de migrações não produz DDL de outro banco.
5. A suíte de conformidade passa em PostgreSQL gerenciado de referência e reporta qual recurso falha num
   derivado que não o implemente.

## Verificação preliminar

`script/sonda_adr002.rb` confere num servidor real os requisitos desta decisão. É o embrião do `vetra doctor` e
exige um superusuário e um banco descartável. Resultado de 2026-10-30, com Ruby 4.0.9:

| Versão | Resultado |
|---|---|
| **16.15** | **Não cumpre**, como esperado: reprova na versão mínima e no `transaction_timeout` (`unrecognized configuration parameter`), e passa nos demais 21 itens |
| **17.11** | Cumpre os 23 itens |
| **18.6** | Cumpre os 23 itens |

O que a sonda verifica, além da versão:

- O dono de uma tabela **ignora** a política de RLS sem `FORCE ROW LEVEL SECURITY` e é filtrado com ele.
- O papel de aplicação sem `BYPASSRLS` vê só o seu tenant; **sem contexto de tenant, não vê nenhuma linha**
  (negação por padrão); um papel com `BYPASSRLS` ignora a política, e por isso o `doctor` o proíbe.
- **Combinação de políticas:** um isolamento de tenant permissivo, somado a um escopo permissivo, **vaza**
  linhas de outro tenant; com o isolamento `RESTRICTIVE` não vaza; só políticas restritivas não concedem acesso
  a ninguém (ADR-005).
- **Troca de política** (ADR-015): criar a nova antes de remover a antiga expõe a união dos acessos; `DROP` +
  `CREATE` na mesma transação, ou `ALTER POLICY`, nunca expõem a união nem o vazio; uma falha preserva a política
  anterior; `ALTER POLICY` não altera `PERMISSIVE`/`RESTRICTIVE` nem o comando.
- Uma view comum contorna o RLS (executa com os privilégios do dono); uma view `security_invoker` o respeita.
- `xid8` e o `xmin` do snapshot: uma escrita aberta **prende** o `xmin`; uma leitura não atribui `xid`; um
  `FOR UPDATE` atribui (base do ADR-014).
- `transaction_timeout` e `idle_in_transaction_session_timeout` encerram a sessão.
- `SKIP LOCKED`, `pgcrypto` (HMAC-SHA256 contra um vetor de teste conhecido) e tabelas `UNLOGGED`.

A **versão estável mais recente** medida é a 18. A imagem do PostgreSQL 19 não foi encontrada no espelho usado,
então não afirmo nada sobre ela. A CI passa a rodar as sondas de banco no 17 e no 18 (job `postgres`); a suíte
do Vetra Data, que o teste de aceitação 3 também pede, ainda não existe.

## Questões em aberto

- Quais serviços gerenciados formam a lista de referência da CI e da conformidade.
- Se o Vetra deve oferecer um contêiner PostgreSQL pré-configurado (papéis e extensões) para
  desenvolvimento.
- Se algum derivado popular (PostgreSQL gerenciado com armazenamento distribuído) deve ser priorizado para
  verificação.

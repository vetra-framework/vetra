# ADR-003: Sequel com camada fina de repositórios

- Status: proposto
- Data: 2026-10-30
- Depende de: ADR-002 (somente PostgreSQL)
- Relacionados: ADR-004 (capacidades), ADR-005 (RLS e contexto assinado), ADR-008 (conexão `LISTEN`), ADR-016
  (ciclo de vida da operação)

## Contexto

O Vetra Data precisa de uma biblioteca para falar com o PostgreSQL. O que as decisões anteriores exigem dela:

- **Recursos nativos do PostgreSQL**, sem camada de neutralidade (ADR-002): `FOR UPDATE`, `SKIP LOCKED`,
  `xid8`, funções de contexto, tipos como `jsonb` e arrays.
- **Controle explícito de conexão e transação.** O contexto assinado é gravado na transação mais externa e
  nunca dentro de um savepoint (ADR-005, ADR-016). A conexão volta ao pool sem contexto. Uma operação tem uma
  transação, e a composição de comandos usa savepoints.
- **Nenhuma autoridade ambiente** (ADR-004). O `call` só alcança os dados por um repositório declarado em
  `uses`, já no escopo do ator e do tenant. Um `Lead.where(...)` global, como em Rails, é o que o Vetra quer
  tornar impossível.
- **Um único caminho de escrita.** As etapas 6 e 7 do ADR-016 (reautorizar sobre o estado final, conferir
  campos de transição, gravar evento, histórico e auditoria) rodam a partir do grafo. Callbacks de modelo
  criariam um segundo caminho.
- **Convivência com Rails** no modo hospedado: código Rails e comandos Vetra precisam participar da mesma
  transação e do mesmo contexto de RLS (proposta, estratégia de adoção).
- **Servidor com fibras.** A proposta usa Falcon, em que várias requisições compartilham uma thread.

A proposta registra a decisão como "Sequel com camada fina de repositórios e SQL explícito", em vez de um ORM
próprio ou do Active Record. Este ADR fecha o desenho e os limites dela.

## Decisão

**O acesso ao PostgreSQL usa o Sequel com o driver `pg`, atrás de uma camada fina de repositórios que o
Vetra constrói. Nenhum código gerado ou escrito pela aplicação fala com o Sequel diretamente.**

### 1. O que é do Sequel e o que é do Vetra

| Responsabilidade | Dono |
|---|---|
| Pool de conexões, protocolo, tipos do PostgreSQL, transações e savepoints, geração de SQL | Sequel |
| Repositório por entidade, escopo do ator e do tenant, contexto assinado, reautorização, campos de transição, outbox, histórico, auditoria | Vetra (Vetra Data) |

- O núcleo usa **datasets e expressões do Sequel**, não `Sequel::Model`. Hooks e plugins de modelo
  (`before_save`, `after_create`) seriam lógica de negócio fora das etapas 6 e 7 do ADR-016.
- O repositório é gerado a partir do grafo, um por entidade, e expõe operações nomeadas (buscar, travar,
  inserir, atualizar, remover, consultar). Não devolve um dataset: o `call` não consegue ampliar a consulta
  nem remover o escopo. Os registros devolvidos são valores imutáveis, sem métodos que gravem.
- A camada de repositórios é **a fronteira de dependência**: trocar o Sequel, se a manutenção externa
  deixar de acompanhar o Ruby, muda esta camada e não as aplicações (risco registrado na proposta).

### 2. SQL explícito, sempre parametrizado

- SQL escrito à mão é permitido onde o PostgreSQL oferece algo melhor que uma abstração (travas, `RETURNING`,
  `xid8`, consultas de política). Fica nos repositórios gerados ou na capacidade `uses :sql`, que aparece no
  relatório como **fora da garantia estrutural** (ADR-004). O RLS continua valendo.
- Valores nunca são concatenados no texto SQL. O núcleo ativa a extensão `pg_auto_parameterize` do Sequel,
  que envia strings, números, datas e blobs como parâmetros do protocolo. Por padrão o Sequel **literaliza**
  os valores; sem a extensão, a segurança dependeria de cada literalização estar correta.
- Limites conhecidos, documentados pelo próprio Sequel e cobertos por teste: o tipo de um parâmetro pode ser
  inferido errado (resolve-se com `Sequel.cast`); o PostgreSQL aceita no máximo 65 535 parâmetros por
  consulta; a mesma expressão usada em dois lugares precisa ser o mesmo objeto.
- A capacidade `uses :sql` recebe texto com marcadores e valores à parte. Interpolação de strings ou
  `Sequel.lit` montado com dados em um `call` deve ser sinalizada pela análise do ADR-001 como construção
  dinâmica. Essa análise tem os limites já documentados (não resolve fluxo de dados).

### 3. Transações e contexto

- A etapa 4 do ADR-016 abre a transação com `db.transaction`. A composição de comandos usa
  `savepoint: true`. Leituras (consultas) também abrem transação, com `read_only: true` (ADR-005).
- O contexto assinado é gravado com `set_config('vetra.ctx', <token>, true)`, que é o equivalente
  parametrizável do `SET LOCAL vetra.ctx = '...'` do ADR-005: `SET` não aceita parâmetros de protocolo,
  `set_config` aceita. Vale a mesma regra: uma vez, na transação mais externa.
- Consulta a tabela multiempresa **fora de transação** é recusada pela camada de repositórios, com erro
  explícito, nunca com resultado vazio (ADR-005).
- A entrega de eventos não depende dos hooks `after_commit` do Sequel. O evento é uma linha da outbox na
  mesma transação e o relay entrega depois do commit (ADR-016, ADR-008). Os hooks servem a efeitos locais ao
  processo e usam a opção `savepoint: true`, para que um trecho revertido não dispare o que só vale no
  commit.
- Travas de linha usam `for_update`; o relay da outbox usa `for_update` com `skip_locked`.
- O núcleo **não usa statements nomeados** (`Dataset#prepare`/`call`). Consultas com parâmetros usam o
  protocolo estendido sem nome, o que mantém a compatibilidade com pooler em modo de transação (ADR-005).

### 4. Conexões e concorrência

- Sob um servidor com fibras, o núcleo ativa `Sequel.extension :fiber_concurrency`, que passa a usar
  `Fiber.current` em vez de `Thread.current` como chave de concorrência. Sem isso, duas fibras da mesma thread
  poderiam compartilhar conexão e transação.
- A conexão `LISTEN` do ADR-008 **não é do Sequel nem do pool**: é uma conexão dedicada, direta ao banco, que
  não carrega contexto de tenant.
- A aplicação conecta como `vetra_app` (ADR-005). O pool nunca usa o papel de migração.

### 5. Modo hospedado

- O app Rails hospedeiro compartilha a conexão com o Sequel pela gem `sequel-activerecord_connection`, que
  sincroniza o estado das transações dos dois lados e suporta os hooks de transação do Sequel, inclusive com
  savepoint. Com Active Record 7.1 ou anterior ela exige também a gem `after_commit_everywhere`.
- Essa ponte é uma dependência de terceiros, restrita ao modo hospedado. O núcleo e o modo serviço não a
  usam. A versão é fixada no lockfile e atualizada junto com a suíte abaixo.
- São obrigatórios os cinco testes da proposta (item 10 dos testes de aceitação).

### 6. Fora do escopo

Geração e aplicação de migrações (planos expand/contract) pedem um ADR próprio. O Vetra não usa o DSL de
migração do Sequel: o plano é SQL explícito e revisável.

## Alternativas rejeitadas

- **ORM próprio:** pool, tipos do PostgreSQL, parâmetros, transações e savepoints são trabalho grande e já
  resolvido. A proposta registra o motivo: menos código a manter.
- **Active Record no núcleo:** acopla o Vetra ao Rails, que o modo serviço e o modo independente não têm.
  Seus callbacks e a consulta global por constante contradizem os ADRs 004 e 016. No modo hospedado ele
  convive com o Vetra pela ponte, sem ser a base.
- **`Sequel::Model` com plugins:** reintroduz callbacks e objetos mutáveis que gravam. O ganho de conveniência
  não compensa um segundo caminho de escrita.
- **Driver `pg` direto, sem Sequel:** o Vetra reescreveria pool, parâmetros, savepoints e conversão de tipos.
  A camada de repositórios já isola a dependência; trocar depois continua possível.
- **Expor o dataset ao `call`:** o escopo e o tenant deixariam de ser garantia estrutural, porque o código
  poderia remover filtros e acessar outras tabelas.

## Consequências

- Menos código a manter do que com um ORM próprio, ao custo de depender de um mantenedor central, como a
  proposta registra.
- O Vetra constrói e testa os repositórios e os escopos: é código a escrever.
- Quem vem do Active Record perde `Model.find` e callbacks; troca-os por repositórios e pelos comandos.
- `pg_auto_parameterize` pode exigir `Sequel.cast` em casos de tipo ambíguo, e limita consultas com muitos
  parâmetros.
- O núcleo precisa ser exercitado com as versões do Sequel e do `pg` que a matriz do ADR-002 usar, em Ruby 4.
- Código que abra conexão própria (Sequel, Active Record ou `pg` direto dentro de um `call`) escapa do
  Effect Boundary. É a fronteira de confiança do ADR-004: o analisador deve tratar `Sequel` e `ActiveRecord`
  como construções fora do repositório, o que depende de ampliar a análise do ADR-001.

## Garantias e seus níveis

| Garantia | Nível | Mecanismo |
|---|---|---|
| O `call` só alcança dados pelo repositório declarado, no escopo do ator e do tenant | Estrutural, com o limite do ADR-004 | Repositório sem dataset exposto; RLS como barreira final |
| Valores de usuário nunca entram no texto SQL | Verificável por testes | `pg_auto_parameterize`; teste sobre o SQL emitido |
| O contexto não vaza entre operações | Verificável por testes | Contexto local à transação; teste de devolução ao pool |
| Fibras não compartilham conexão nem transação | Verificável por testes | `fiber_concurrency`; teste com duas fibras |
| Savepoint revertido não dispara efeito de commit | Verificável por testes | Hooks com `savepoint: true` |
| Rails e Vetra na mesma transação (modo hospedado) | Verificável por testes | Ponte `sequel-activerecord_connection`; cinco testes |
| Substituir o Sequel sem tocar a aplicação | Experimental | Fronteira dos repositórios; nunca exercitada com outra biblioteca |

## Testes de aceitação

1. O SQL emitido por todo repositório gerado usa parâmetros; nenhum valor de entrada aparece literalizado.
2. `lock!` emite `FOR UPDATE`; a leitura do relay emite `FOR UPDATE SKIP LOCKED`.
3. Duas fibras na mesma thread usam conexões e transações distintas, e o contexto de uma não aparece na outra.
4. Depois do commit e depois do rollback, a conexão devolvida ao pool não tem `vetra.ctx` definido.
5. Um `after_commit(savepoint: true)` registrado dentro de um savepoint revertido não executa, e o
   `after_rollback(savepoint: true)` executa.
6. Consulta a tabela multiempresa fora de transação falha com erro explícito.
7. Nenhum arquivo gerado, nem `app/`, referencia `Sequel` fora da camada de dados.
8. A suíte passa atrás de um pooler em modo de transação, sem statements nomeados.
9. O `call` não obtém um dataset do repositório.
10. Modo hospedado, como na proposta:
    a. o Active Record inicia a transação e o Sequel opera dentro dela;
    b. o Sequel inicia a transação e o Active Record opera dentro dela;
    c. uma exceção desfaz as alterações dos dois;
    d. o rollback de um savepoint não dispara eventos ou callbacks indevidos;
    e. a conexão volta ao pool sem contexto de autorização da operação anterior.
11. Sequel e `pg` funcionam em Ruby 4.0.9, no PostgreSQL 17 e na versão estável mais recente (ADR-002).

## Questões em aberto

- Se o Sequel e o `pg` acompanham o Ruby 4.0.x sem ajustes. Não foi medido; é o teste 11.
- Se o driver `pg` cede a fibra durante uma consulta sob o agendador de fibras do Falcon, ou bloqueia a
  thread. Afeta a capacidade do servidor e precisa de medição.
- A forma dos registros devolvidos (valores imutáveis) e o custo de alocação em consultas grandes.
- Se `uses :sql` entra na fase 1 ou só depois dos repositórios gerados.
- A política de atualização do Sequel e da ponte com o Active Record: ritmo, janela de suporte e quem decide.
- Como o analisador do ADR-001 passa a sinalizar `Sequel`, `ActiveRecord` e interpolação em SQL.

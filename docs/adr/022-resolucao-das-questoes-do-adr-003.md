# ADR-022: Resolução das questões em aberto do ADR-003

- Status: aceito
- Data: 2026-10-31
- Resolve: ADR-003 (as seis questões em aberto)
- Depende de: ADR-003 (Sequel e repositórios), ADR-001 (analisador do `call`), ADR-004 (Effect Boundary)
- Relacionados: ADR-005 (contexto assinado), ADR-008 (conexão `LISTEN`), ADR-018 (código de UI)

## Contexto

O ADR-003 foi aceito com seis questões em aberto, e o índice pede tratá-las antes de implementar a persistência.
Este ADR não muda a decisão do ADR-003 (Sequel com o `pg`, atrás de uma camada fina de repositórios, sem
`Sequel::Model`, com SQL sempre parametrizado, sem statements nomeados e com `fiber_concurrency`). Ele só responde
o que o ADR-003 deixou aberto, pela regra de resolução do índice.

| # | Questão | Tratamento |
|---|---|---|
| 1 | Outros poolers e outras versões do PgBouncer | Medição |
| 2 | O `pg` cede a fibra sob o Falcon, e não só sob o agendador `async` | Medição, com resultado preliminar |
| 3 | A forma dos registros devolvidos e o custo de alocação | Decidida (forma) e medição (custo) |
| 4 | `uses :sql` na fase 1 | Decidida |
| 5 | Política de atualização do Sequel e da ponte com o Active Record | Valor inicial e adiada (quem decide) |
| 6 | Como o analisador sinaliza `Sequel`, `ActiveRecord` e interpolação em SQL | Decidida |

## Questões

### 1. Outros poolers e outras versões do PgBouncer

- Tratamento: **medição**.
- A regra do ADR-003, §3 já é o padrão portátil: o núcleo não usa statements nomeados e grava o contexto com
  `set_config(..., true)` dentro da transação. O que muda de um pooler para outro é se ele mantém o backend preso
  durante a transação e se aceita o protocolo estendido sem nome.
- **O que medir:** `script/sonda_pooler.rb`, que já se parametriza por `POOLER_URL`, contra o pooler da aplicação,
  em modo de transação e com um pool de uma conexão. A sonda confere primeiro que dois clientes reutilizam o mesmo
  backend, para um "não vazou" não ser vazio.
- **Qual resultado decide o quê.** Um pooler é **suportado**, com a versão registrada na documentação, se passam
  quatro verificações: o contexto por `set_config` local não vaza para o cliente seguinte; durante a transação o
  contexto fica preso ao cliente; consultas parametrizadas sem nome funcionam alternando clientes; e o Sequel com
  `pg_auto_parameterize` e `set_config` local funciona sem vazar. Se uma dessas falha, o pooler **não é suportado**.
  A verificação dos statements nomeados e a do `LISTEN` são informativas e não decidem nada: o núcleo não usa
  statements nomeados, e o `LISTEN` do ADR-008 já é uma conexão dedicada e direta.
- Medido até aqui: o PgBouncer 1.26.1, com `max_prepared_statements` em 0 e em 200 (ADR-003).

### 2. O `pg` sob o Falcon

- Tratamento: **medição**, com resultado preliminar.
- **Resultado preliminar (à mão, sem sonda versionada).** Um app Rack descartável sob o Falcon 0.57.0 (async 2.46.0),
  num **único processo** (`--count 1`), com Sequel 5.109.0, `pg` 1.7.0, `Sequel.extension :fiber_concurrency` e um
  pool de 8 conexões, em Ruby 3.3.6 e PostgreSQL 16.15. Cada requisição abria uma transação e esperava
  `pg_sleep(1)`. Uma requisição levou 1,03 s; **quatro simultâneas levaram 1,05 s** (duas execuções). O controle, no
  mesmo servidor, um laço de CPU de 1 s que bloqueia a thread, levou 4,02 s para as quatro. Logo o `pg` cede a
  fibra sob o Falcon em si, e as esperas das quatro requisições se sobrepõem num só worker.
- **O que falta:** o Ruby 4.0.9, que não foi possível instalar no ambiente desta medição, e o adaptador Rack do
  Vetra, que não existe.
- **Qual resultado decide o quê.** Quando existir o adaptador Rack, repetir a medição em Ruby 4.0.9 na CI, com
  quatro requisições simultâneas e o mesmo controle. Se as quatro levarem menos de 2 s (hipótese de limiar,
  contra os 4 s de um worker que bloqueia), a decisão do ADR-003 segue como está. Se levarem 2 s ou mais, o `pg`
  não está cedendo a fibra, e a escolha do Falcon como servidor volta por ADR novo; o `fiber_concurrency` continua
  valendo, porque o ADR-003 o exige por segurança, não por desempenho.

### 3. A forma dos registros devolvidos e o custo de alocação

- Tratamento: **decidida** (a forma) e **medição** (o custo).
- **Decisão: um `Data` por entidade**, gerado do grafo, com os campos da entidade. Os valores são congelados na
  construção, em profundidade (as strings que vêm do `pg` são mutáveis), então o registro é imutável de ponta a
  ponta e pode ser compartilhado entre Ractors sem cópia, como a IR (ADR-001). O registro não tem método que grave
  (ADR-003, §1). Quem quer outra versão do registro usa `with`, que devolve um novo.
- **Alternativas rejeitadas:**
  - **`Hash` congelado:** não tem nome de tipo, uma chave inexistente devolve `nil` em silêncio, e não há onde pôr
    o que o grafo sabe do campo.
  - **`Struct`:** tem escritores e atribuição por índice até ser congelado, e a imutabilidade dependeria de cada
    instância ser congelada. O `Data` não tem escritores e já nasce congelado.
  - **`Sequel::Model`:** rejeitado no ADR-003 (callbacks e objetos mutáveis que gravam).
- **Custo, medido só em ordem de grandeza** (Ruby 3.3.6): construir 10.000 registros de 10 campos custa cerca de
  6 ms com `Hash` congelado (6,13 ms), `Data` (5,97 ms) ou `Struct` congelado (6,21 ms). O `Data` aloca o dobro de
  objetos (20.001 contra 10.003), por causa do hash de palavras-chave da construção. A medição não inclui o
  congelamento em profundidade dos valores nem o Ruby 4.0.9.
- **Qual resultado decide o quê.** No repositório real, em Ruby 4.0.9 e com o congelamento em profundidade,
  construir 10.000 linhas de 10 campos não pode custar mais de 10% (hipótese de limiar) do tempo da consulta que as
  trouxe. Se custar, a alternativa a avaliar, por ADR novo, é construir o registro sob demanda, no acesso.

### 4. `uses :sql` na fase 1

- Tratamento: **decidida**. **`uses :sql` não entra na fase 1.** Entra depois dos repositórios gerados e depois da
  extensão do analisador da questão 6.
- **Por quê:**
  - Os três exemplos da proposta (mini CRM, blog e chat) não têm SQL escrito à mão em nenhum comando: as menções a
    SQL nos PDFs são o plano de migração (`db:plan`) e o `schema.sql`. Foi conferido pela extração do texto.
  - É a única porta para fora da garantia estrutural do ADR-003, §1 e §2. Sem o analisador que sinaliza
    interpolação (questão 6), seria uma porta sem fiscal.
  - Entrar depois é aditivo; tirar depois é mudar um contrato.
- **O que existe hoje:** o validador já emite `sql_boundary`, um aviso, para uma capacidade `type: sql` na IR
  (`lib/vetra/graph/validator.rb`); o DSL não declara `uses :sql`.
- **O que a faz voltar:** um caso real que os repositórios não expressam (por exemplo, uma consulta analítica com
  função de janela) **e** o analisador da questão 6 implementado.
- **Alternativa rejeitada:** incluí-la na fase 1 "para não bloquear ninguém". Pelo mesmo motivo acima, o custo de
  tê-la sem fiscal supera o de esperar.

### 5. Política de atualização do Sequel e da ponte com o Active Record

- Tratamento: **valor inicial** (ritmo e janela) e **adiada** (quem decide).
- **Valor inicial.**
  - O `Gemfile.lock` fixa a versão exata do Sequel, do `pg` e da ponte `sequel-activerecord_connection`. Uma
    atualização é um PR próprio, que roda a suíte e as sondas (a `sonda_adr003` já roda na CI no PostgreSQL 17 e
    18). A ponte só é atualizada com os cinco testes do item 10 do ADR-003 passando contra um Rails real.
  - Ritmo: revisar a cada versão menor do Sequel, do `pg` ou do Ruby, e na hora para correção de segurança.
  - Janela de suporte: a gem do Vetra Data declara o `sequel` e o `pg` com limite superior na próxima versão maior
    (por exemplo, `~> 5.109`). Só a versão menor fixada no lockfile é a testada.
  - **O que pode revisá-los:** o primeiro ciclo de atualização real. Se uma versão menor do Sequel quebrar a camada
    de repositórios, a janela passa a fixar a versão menor (`~> 5.109.0`).
- **Adiada: quem decide.** Depende da governança do projeto, que a proposta e o README deixam em aberto. Até
  lá, decide quem integra o PR da atualização, o mesmo que integra os demais. **Gatilho:** a definição da
  governança.

### 6. Como o analisador sinaliza `Sequel`, `ActiveRecord` e interpolação em SQL

- Tratamento: **decidida**.
- **O problema, conferido.** O `Analysis` do compilador (Prism) recusa hoje `Net::HTTP.get` num `call` com
  `direct_effect`, mas **aceita** `Sequel.connect`, `ActiveRecord::Base.connection` e `PG.connect`: numa cópia
  descartável do exemplo do blog, o `graph:build` terminou em OK com cada uma delas no `call` de `publish_post`. A
  lista `EFFECT_CLASSES` não as tem. É o que as consequências do ADR-003 já pedem para ampliar.
- **Decisão:**
  1. Uso direto das constantes `Sequel`, `ActiveRecord` e `PG`, e das aninhadas nelas (`Sequel::Database`,
     `ActiveRecord::Base`, `PG::Connection`), num `call` é **erro de boot**, da mesma classe que `Net::HTTP` e
     `File`. O `unsafe_effect` com motivo o libera, e o comando fica fora da garantia, inelegível para repetição e
     para o modo sombra (ADR-004, §5).
  2. Quando `uses :sql` existir (questão 4), o texto que ele recebe tem de ser um **literal com marcadores**, com os
     valores à parte. Uma string **interpolada** é erro de boot. Uma expressão que a análise não resolve (variável
     ou chamada de método) é **aviso**, porque o fluxo de dados não é resolvido (ADR-001).
  3. A mesma regra vale para o código de UI (ADR-018, §7): as páginas e os templates, compilados para Ruby, passam
     pela mesma análise.
- **O limite é o do ADR-004, §5:** a análise é um filtro, não uma prova. `const_get`, `send` e semelhantes
  continuam sendo aviso, e uma gem que abre conexão própria escapa.

## Consequências

- O ADR-003 passa a ter todas as questões tratadas. Duas são medições com critério (1 e 2), uma tem um custo a
  medir (3, a forma está decidida), uma é um valor inicial (5) e a quem decide falta a governança. Nenhuma bloqueia
  o desenho da persistência.
- O analisador do compilador precisa ser estendido (questão 6): hoje o `call` pode abrir uma conexão com o banco
  sem que o `graph:build` reclame. O protótipo não foi alterado por este ADR.
- Cada repositório gerado traz um `Data` próprio, e o congelamento em profundidade entra no custo da leitura.
- A lista de poolers suportados passa a ser um resultado de medição, não uma afirmação.

## Garantia

| Garantia | Nível | Mecanismo |
|---|---|---|
| O registro devolvido é imutável | Verificável por testes | `Data` com valores congelados em profundidade |
| Um `call` não referencia `Sequel`, `ActiveRecord` nem `PG` sem declarar `unsafe_effect` | Estrutural, limitado | Análise Prism no boot; é um filtro, não uma prova (ADR-004, §5) |
| Um pooler suportado não vaza o contexto | Verificável por testes | `script/sonda_pooler.rb` contra o pooler |
| O `pg` cede a fibra sob o servidor | Operacional | Medição preliminar à mão; a CI repete na fase 1 |

Testes de aceitação das questões decididas:

1. Um repositório gerado devolve `Data` congelado, com valores congelados em profundidade e sem escritor;
   `Ractor.shareable?` é verdadeiro.
2. Um `call` que referencia `Sequel`, `ActiveRecord` ou `PG` é recusado no boot; com `unsafe_effect` é aceito e o
   relatório o lista como fora da garantia.
3. Declarar `uses :sql` falha de forma audível enquanto a capacidade não existir.
4. Com `uses :sql`, uma string interpolada é recusada e um literal com marcadores é aceito.
5. A `sonda_pooler` roda contra o pooler declarado e as quatro verificações decisivas passam antes de ele entrar na
   lista de suportados.
6. A medição do `pg` sob o Falcon repete em Ruby 4.0.9 na CI, com o controle de CPU, quando o adaptador Rack
   existir.

## Verificação preliminar

Conferido à mão, **sem sonda versionada**, em Ruby 3.3.6 (o ambiente não tinha o 4.0.9; o projeto usa o 4.0.9) e
PostgreSQL 16.15:

- O `pg` sob o Falcon: 1,05 s para quatro requisições simultâneas num worker, contra 4,02 s do controle que
  bloqueia a thread (questão 2).
- O custo de construir 10.000 registros de 10 campos: 6,13 ms (`Hash`), 5,97 ms (`Data`) e 6,21 ms (`Struct`), com
  10.003, 20.001 e 20.001 objetos alocados (questão 3).
- O analisador aceita `Sequel.connect`, `ActiveRecord::Base.connection` e `PG.connect` num `call` e recusa
  `Net::HTTP.get` (questão 6).
- Os PDFs dos três exemplos não têm SQL escrito à mão em nenhum comando (questão 4).

Nada disto foi criado como código ou teste no repositório. As medições usaram um app e scripts descartáveis, fora
dele.

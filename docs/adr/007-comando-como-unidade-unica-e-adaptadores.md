# ADR-007: Comando como unidade única de operação e adaptadores de superfície

- Status: proposto
- Data: 2026-10-30
- Depende de: ADR-016 (ciclo de vida da operação)
- Relacionados: ADR-004 (capacidades), ADR-011 (MCP), ADR-014 (outbox), ADR-021 (campos de transição)

## Contexto

No Rails, a mesma regra costuma existir em mais de um lugar: no controller que atende o HTTP, no job que
repete a operação em segundo plano, na rake task de manutenção e na integração com um terceiro. Cada cópia
valida, autoriza, abre transação e registra auditoria do seu jeito, e as diferenças só aparecem em produção.

O ADR-016 já fixa que toda escrita passa pelas mesmas oito etapas e traz a tabela do que cada superfície pode
variar (timeout, idempotência, observações). Falta definir **o que é uma operação**, **como ela é exposta** e
**o que um adaptador pode e não pode fazer**. É a segunda metade da decisão 007 da proposta: o comando como
unidade única, com adaptadores que explicitam a semântica de cada superfície.

## Decisão

**Toda escrita é um comando; toda leitura é uma consulta. Uma operação tem uma identidade única no grafo
(`crm.win_lead`), independente de quantas superfícies a expõem.** A regra de negócio é escrita uma vez, no
`call` do comando.

### 1. Exposição é declarada e opt-in

- Um comando ou consulta só é alcançável por uma superfície se declarar `expose`. Nada é exposto por padrão,
  nem ao MCP (ADR-011).
- Cada exposição vira um nó `route` na IR, com `surface` em `http`, `cli`, `job` ou `webhook`, o destino
  (comando ou consulta) e a exigência de idempotência (`optional` ou `required`). O schema 0.1 já representa
  as quatro superfícies.

```ruby
command :win_lead do
  # ...
  expose http: "POST /leads/:lead_id/win"
end
```

- O CRUD gerado cria as rotas HTTP dos comandos e da consulta que gera (`POST /leads`, `GET /leads/:id`...).
  As demais superfícies são declaradas à mão por quem precisar delas.
- Várias exposições do mesmo comando são independentes: uma rota HTTP e uma tarefa de terminal chamam o mesmo
  contrato, a mesma política e a mesma transação.

### 2. O contrato do adaptador

Um adaptador é a camada que traduz uma superfície para o ciclo do ADR-016. Ele **faz**:

| Responsabilidade | Detalhe |
|---|---|
| Traduzir a entrada | Converte o formato da superfície (corpo JSON, argumentos, payload do job ou do webhook) para a entrada do contrato do comando |
| Resolver o ator e o tenant | A partir da credencial ou da sessão; nunca do corpo da requisição |
| Extrair a chave de idempotência | Cabeçalho, argumento, identificador do job ou do evento do provedor |
| Declarar `statement_timeout` e `lock_timeout` | Valores da superfície, dentro dos limites do ADR-016 |
| Traduzir as três saídas de falha | Entrada inválida, acesso negado e falha na execução, no vocabulário da superfície |

E **não faz**:

- decidir regra de negócio, ou escolher o que acontece com a entrada além de traduzi-la;
- abrir transação, nem validar ou autorizar com ela aberta (ADR-016);
- ler ou gravar dados, ou chamar outro comando;
- pular, reordenar ou repetir etapas por conta própria. A repetição por deadlock ou falha de serialização é do
  framework (ADR-016);
- elevar privilégio. O ator da operação é o da credencial; operar como outro ator exige uma capacidade
  explícita e auditada (ADR-016).

### 3. Tradução das saídas de falha por superfície

| Saída | HTTP | CLI | Job | Webhook |
|---|---|---|---|---|
| Entrada inválida | 422, com erros por campo | Código de saída diferente de zero, com mensagem por campo | Falha definitiva, sem repetição | 4xx |
| Acesso negado | 403, ou 404 quando revelar o registro vazaria sua existência | Código de saída diferente de zero | Falha definitiva, sem repetição | 4xx |
| Falha na execução | 422 para `fail!`, 409 para conflito, 500 para erro inesperado | Código de saída diferente de zero | Retentável, exceto `fail!` | 5xx quando retentável pelo provedor |

Os códigos de saída da CLI, o critério de repetição de jobs e o corpo exato da resposta do webhook são
detalhes de cada adaptador, documentados nele. O que não varia é o mapeamento das três saídas.

### 4. Regras que o grafo verifica nas exposições

O compilador do protótipo já recusa, para `http`: comando exposto por `GET`, `HEAD` ou `OPTIONS` e consulta
exposta por método que não seja `GET` ou `HEAD`; parâmetro de caminho que não existe no contrato de entrada; e
duas rotas ambíguas, inclusive as que só diferem pelo nome do parâmetro. Para `webhook`, recusa o destino que não
seja comando com idempotência obrigatória. Este ADR mantém essas regras e estende o princípio às demais
superfícies:

- `cli` e `job` exigem um nome único dentro da superfície; colisão é erro de compilação.
- `webhook` sempre tem `idempotency: required`, com o identificador do evento do provedor como chave.
- Um comando exposto por superfície que não consegue entregar a chave que ele exige é erro de compilação, não
  falha em produção.

### 5. Consultas

- Uma consulta tem o mesmo contrato de entrada e a mesma política que um comando, mas não escreve: roda numa
  transação `READ ONLY` (ADR-005) e não emite eventos.
- É exposta por `GET`, por CLI ou como assinatura live (ADR-020). Nunca por `POST`.
- Consultas não repetem efeito externo e dispensam chave de idempotência.

### 6. Composição não é superfície

Um comando que chama outro usa **savepoint** dentro da transação do primeiro (ADR-016). A chamada interna não
passa por adaptador, não abre outra transação e é reautorizada com o ator da operação externa.

## Alternativas rejeitadas

- **Controllers, services e jobs separados** (o estilo Rails): é o problema que motiva a decisão. A regra se
  duplica e cada cópia diverge.
- **Regra de negócio dentro do adaptador:** cada superfície teria o próprio comportamento, e a diferença entre
  HTTP e job voltaria a existir.
- **Expor tudo por padrão e restringir depois:** uma superfície nova passaria a alcançar comandos que ninguém
  decidiu expor. O opt-in torna a superfície de ataque uma lista explícita e revisável no diff arquitetural.
- **Um comando por superfície, compartilhando um service:** reintroduz a camada de service que o comando
  existe para substituir.
- **Adaptador com transação própria:** ver a alternativa equivalente rejeitada no ADR-016.

## Consequências

- Mudar uma regra é mudar um `call`; as superfícies herdam a mudança.
- Adicionar uma superfície nova a um comando existente é uma linha de `expose`, mas obriga a decidir a
  semântica daquela superfície (timeout, idempotência, tradução de erros).
- O diff arquitetural passa a mostrar exposições novas como mudança de superfície que exige revisão.
- O custo de ser opt-in: quem quer um comando também em CLI precisa dizê-lo, mesmo no caso óbvio.
- Cada adaptador é código do framework a manter e a testar; o contrato acima é o que impede que eles
  divirjam.

## Garantias e seus níveis

| Garantia | Nível | Mecanismo |
|---|---|---|
| Nada é alcançável por uma superfície sem `expose` | Estrutural | O grafo só gera rotas das exposições declaradas |
| Rotas ambíguas, método incompatível e parâmetro inexistente são erro de compilação | Estrutural | Validações do compilador (implementadas em `http` e `webhook` no protótipo) |
| Todas as superfícies produzem o mesmo resultado e o mesmo histórico para a mesma entrada | Verificável por testes | Teste de equivalência entre superfícies (ADR-016, teste 10) |
| Um adaptador não decide regra de negócio | Verificável por testes | Os adaptadores são pequenos e testados contra o contrato; não há como provar a ausência de lógica |

## Testes de aceitação

1. Um comando sem `expose` não é alcançável por nenhuma superfície, inclusive pelo MCP.
2. A mesma entrada enviada por HTTP, CLI, job e webhook produz o mesmo estado, o mesmo evento e o mesmo
   registro de histórico.
3. As três saídas de falha produzem a resposta esperada em cada superfície, e as duas primeiras não abrem
   transação.
4. Um webhook sem identificador de evento é recusado antes da etapa 1.
5. Duas exposições de CLI com o mesmo nome falham na compilação.
6. Uma rota `GET` para um comando e um `POST` para uma consulta falham na compilação (já cobertas no
   protótipo).
7. Um adaptador que tenta abrir transação ou pular a autorização é detectado pelo teste de contrato do
   adaptador.
8. Um comando chamado por composição é reautorizado com o ator externo e não passa por adaptador.

## Questões em aberto

- O formato da tarefa de terminal (`vetra crm:win_lead --lead-id ...` é uma hipótese) e como a CLI recebe
  entradas estruturadas.
- Como um comando exposto como job devolve o resultado a quem o enfileirou, e por quanto tempo o guarda.
- Streaming de resposta em HTTP e SSE: ficam fora do comando; entram como consulta live (ADR-020) ou como
  workflow (ADR-009).
- Se uma exposição pode restringir o contrato (aceitar menos campos que o comando) sem criar um comando novo.

# ADR-049: Identidade da borda pública

- Status: proposto
- Data: 2026-11-12
- Depende de: ADR-007 (adaptadores), ADR-044 (entrada e autorização em Ruby), ADR-045 (borda interna e Runner), ADR-005 (contexto assinado)
- Relacionados: ADR-010 (modo hospedado), ADR-016 (ciclo de vida), ADR-034 (limite de taxa), ADR-043 (idempotência), ADR-048 (handlers de sistema)

## Contexto

O ADR-045 deixou a borda interna como um contrato de três colaboradores injetados (identidade, fatos e autoridade), com implementações de referência
para um processo. Enquanto o chamador era interno e confiável, resolver a identidade era responsabilidade de quem chamava o `Runner`. A rodada 6 põe as
quatro superfícies (HTTP, CLI, job e webhook) na frente do `Runner`, e uma superfície pública muda o problema: a credencial vem de fora, o resolvedor é
código da aplicação (sessão, token, assinatura do provedor), e um defeito nele não pode conceder poder. O parecer do Codex sobre o plano da rodada 6
apontou o que faltava no contrato: a identidade, os papéis e a geração da atribuição coerentes entre si, o visitante como identidade explícita e estável,
a proibição do ator de sistema na entrada pública e a autoridade entre processos.

Este ADR define o contrato **entre o resolvedor da aplicação e a borda**. Ele não define como se autentica alguém (`auth` como DSL segue sem ADR), nem o
adaptador HTTP, que é o ADR seguinte.

## Decisão

### 1. O resolvedor devolve uma `Identity`, e só uma `Identity`

Uma superfície pública recebe a credencial e a entrega **sem interpretá-la** a um resolvedor que a aplicação implementa: `call(credentials)` devolve a
`Identity` (tenant, ator, papéis, geração), ou levanta. Campos de identidade ou papéis vindos do corpo, dos parâmetros ou de cabeçalhos **não verificados**
nunca atribuem autoridade; a credencial em si (`Authorization`, cookie de sessão, assinatura) pode viajar em cabeçalho e é verificada pelo resolvedor.
Exceção do resolvedor, de qualquer tipo, vira a recusa genérica `execution_identity` (401), sem causa nem mensagem (ADR-045, §1).

### 2. O guarda `PublicIdentity` confere o que o resolvedor devolveu

Entre o resolvedor e a borda fica `Execution::PublicIdentity`, que falha fechado, com código próprio e sem causa. **Ele confere forma e declaração, não autenticidade**: um resolvedor que copia do pedido um
UUID, um tenant e um papel declarados passa por ele, e a autenticidade da identidade é do resolvedor confiável (ADR-044). O que o guarda impede é que um defeito do resolvedor (ator de sistema, valor
malformado, papel que o grafo não declara) chegue à borda:

| Confere | Código |
|---|---|
| a identidade é uma `Identity` | `execution_identity` |
| **nunca** é um ator de sistema (o ator de sistema é só dos handlers, pelo `HandlerRunner`, ADR-048) | `execution_identity_system` |
| o ator é um UUID em minúsculas, **inclusive o do visitante** | `execution_identity_actor` |
| cada papel é texto e é um papel declarado no grafo | `execution_identity_role` |
| o tenant é um UUID numa aplicação com tenant e fica ausente numa global | `execution_identity_tenant` |
| a geração, se houver, é um inteiro não negativo | `execution_identity_generation` |

O guarda devolve uma identidade **canônica**: um `Identity` novo, com cópias **nativas** e congeladas dos valores conferidos (cada leitor é chamado uma vez, e o texto e a lista são copiados sem chamar `dup`, `to_s` nem `each` do objeto do resolvedor), de modo que uma subclasse
de leitores instáveis, um `String` ou um `Array` hostil, ou um texto mutável, não mudam o que se conferiu; quem decide se o objeto é uma `Identity` é o módulo (`===`), e não o objeto. Todo erro do resolvedor, de qualquer tipo, **e o de qualquer leitor da identidade**, vira o genérico `execution_identity` **dentro do próprio guarda**; a borda só mantém o código quando o colaborador é o
`PublicIdentity`, e o erro de dados de qualquer outro colaborador continua genérico, com o código que ele escolher descartado.

### 3. A geração da atribuição de papéis é coerente com a identidade

A `Identity` ganha `generation`: a geração da atribuição de papéis que o resolvedor leu **antes** de ler os papéis. O `Runner` confere, na etapa 3 e ao mesmo
tempo em que o avaliador confirma a revisão, que essa geração ainda é a corrente (`Edge#identity_current?`). Se não é, a operação termina **`unresolved` (401),
código `execution_identity_stale`**, e não 403: a credencial precisa ser resolvida de novo. Sem `generation` na identidade, nada é conferido. Com `generation` e
uma autoridade que não a lê, ou que falha ao lê-la, a resposta é não: **falha fechada**. A geração é a que a borda já publica quando um papel muda fora do banco
(`DatabaseAuthority#identity_changed!`, `InProcessAuthority#publish!`); a revogação de um papel é, portanto, uma publicação de geração, e uma identidade lida
antes dela é recusada. **Limite:** a conferência é na etapa 3. Uma revogação publicada entre a etapa 3 e o commit não é pega pela reautorização do estado final, que reutiliza os papéis recebidos e não
consulta a geração; é a janela que o ADR-044 já aceita para a revisão, e ela só fecha com a geração dentro da reautorização ou da transação, o que fica para a autoridade compartilhada (rodada 8).

### 4. O visitante é uma identidade anônima, estável, emitida e verificada

Um visitante **tem ator**: o ator anônimo. Sem ele, o limite de taxa por visitante (ADR-034, `actor_tenant`) e o isolamento entre visitantes da idempotência
(ADR-043, que hoje trata o principal nulo como um só) não têm sobre o que agir. `Execution::AnonymousIssuer` emite uma credencial `a1.<nonce>.<mac>` (nonce de
128 bits, MAC HMAC-SHA256 com o segredo da aplicação, de pelo menos 32 bytes) que a borda guarda (um cookie, por exemplo) e reapresenta. O ator é um UUID de
versão 8 **derivado do nonce por HMAC**: estável a cada reapresentação e em qualquer processo com o mesmo segredo, e impossível de escolher pelo cliente. A
verificação compara o MAC em tempo constante, recusa formato, tamanho, prefixo e codificação (só ASCII) errados, e nunca levanta. **Limite registrado:** quem não apresenta uma credencial
válida recebe outra, e o histórico do limite de taxa dele recomeça; o limite por visitante contém um cliente que se comporta, não um que descarta o cookie. Esse
limite pede o limite por IP ou por origem no hospedeiro, que fica fora do Vetra.

### 5. Autoridade entre processos: limitada por configuração, não escondida

`InProcessAuthority` e a geração da identidade em memória valem para **um** processo (ADR-045, §2). HTTP, CLI e workers separados ultrapassam esse limite, e uma
revogação num processo não chega aos outros. Esta rodada **não entrega** uma autoridade compartilhada; entrega o limite declarado: um adaptador que declara vários
processos chama `Execution.require_shared_authority!(edge)`, que recusa subir (`execution_authority_not_shared`) se a autoridade não declara `shared?`. As de
referência não declaram. O produto que roda em vários processos injeta a sua, que declara `shared?` e implementa `identity_generation_value`. A autoridade
compartilhada de referência tem dono: a rodada do modo hospedado (a 8), junto com o `sequel-activerecord_connection`.

## Alternativas rejeitadas

- **Confiar no resolvedor sem guarda.** Um resolvedor com defeito (ator de sistema, UUID malformado, papel que o grafo não declara) chegaria à borda. O guarda custa uma conferência barata e transforma esses defeitos em recusa;
  ele **não** prova autenticidade, que é do resolvedor (ADR-044).
- **Visitante sem ator.** Mantém o contexto sem `actor_id`, mas tira do visitante o limite de taxa e o isolamento da idempotência, que são justamente o que protege uma superfície pública.
- **Ator anônimo escolhido pelo cliente (um UUID no cookie).** O cliente passaria a escolher o próprio ator, e um atacante poderia assumir o de outro visitante.
- **Autoridade compartilhada agora, num banco.** Exige uma tabela e uma geração por transação do banco, e a decisão de onde a geração da identidade mora (no banco ou no Rails, no modo hospedado). Fica para a rodada 8, e a
  recusa do modo distribuído impede que alguém a anuncie antes.
- **Tratar a geração velha como 403.** O ator pode ter perdido o acesso (403) ou apenas ter os papéis desatualizados; o resolvedor é quem sabe, e um 401 manda a borda resolver de novo.

## Consequências

- O `Runner` passa a recusar com 401 uma identidade com geração substituída; identidades sem geração se comportam como antes, e os exemplos e as sondas existentes não mudam.
- O ator de sistema continua só dos handlers: uma identidade com `system_actor` não passa pelo guarda.
- O adaptador HTTP (ADR seguinte) e os contadores de `rate_limit:` assumem este contrato: o visitante tem ator, e a chave do limite é o ator anônimo.
- O limite por visitante não contém quem descarta a credencial; o limite por origem é do hospedeiro.
- Não há IR nova: nada do que este ADR decide aparece no grafo.

## Garantia

| Garantia | Nível | Mecanismo |
|---|---|---|
| Uma superfície pública nunca admite ator de sistema | Verificável por testes | `PublicIdentity` (`execution_identity_system`) |
| Um resolvedor com defeito não concede papel, tenant ou ator inválidos | Verificável por testes | Guarda com falha fechada |
| Papéis de uma geração substituída não autorizam | Verificável por testes, até a etapa 3 (não cobre a revogação entre a etapa 3 e o commit) | `Edge#identity_current?` no `Runner` (401) |
| O ator do visitante é estável e não é escolhido pelo cliente | Verificável por testes | `AnonymousIssuer` (HMAC, tempo constante) |
| Vários processos sem autoridade compartilhada não sobem | Operacional, na configuração | `Execution.require_shared_authority!` |

### Testes de aceitação

1. Uma identidade com `system_actor` é recusada; o código atravessa a borda; um resolvedor que levanta um erro de dados, inclusive com um código forjado, continua genérico.
2. Ator não UUID, papel não declarado (inclusive de outra aplicação e como símbolo), tenant em aplicação global, falta de tenant em aplicação com tenant e geração negativa ou textual são recusados, cada um com o seu código.
3. A credencial anônima verifica, tem ator estável entre instâncias com o mesmo segredo, ator diferente por visitante e ator UUID de versão 8; forjada, adulterada, de outro segredo, de formato ou tamanho errado, não verifica; uma credencial em outra codificação (UTF-16, UTF-32) ou com caractere não ASCII não verifica e não levanta.
4. Depois de `publish!`, uma identidade com a geração antiga termina `unresolved` com `execution_identity_stale`; com a geração nova, passa; sem geração, não é conferida; uma autoridade que não lê a geração, ou que falha, recusa.
5. Uma autoridade que não declara `shared?` é recusada por `require_shared_authority!`; uma que declara é aceita.
6. A identidade devolvida pelo guarda é uma cópia canônica e nativa: uma subclasse de leitores instáveis (`system_actor` nil na primeira leitura), um `String` cujo `dup` devolve outro papel, um `Array` que mente em `each` e `map`, e um texto mutável do resolvedor não mudam o que foi conferido; um leitor que levanta um erro de dados com código forjado vira o genérico.

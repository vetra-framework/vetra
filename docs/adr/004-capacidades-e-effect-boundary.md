# ADR-004: Capacidades e Effect Boundary

- Status: proposto
- Data: 2026-10-30
- Depende de: ADR-016 (ciclo de vida da operação)
- Relacionados: ADR-005 (RLS e contexto assinado), ADR-012 (modo sombra), ADR-013 (privacidade)

## Contexto

Em Rails, qualquer código alcança qualquer coisa: `Lead.where(...)` em qualquer lugar, `Net::HTTP.get` num
callback, `Time.now` num service. Isso torna impossível responder, só olhando o código, "o que esta operação
toca?". Também impede simular o relógio ou a rede em testes, executar uma versão nova em modo sombra sem
efeitos duplicados e repetir uma operação com segurança.

O princípio 4 da proposta diz: **nenhuma autoridade ambiente**. O código só acessa o que declarou: dados no
escopo do ator, hosts externos, serviços. Este ADR define o que é uma capacidade, o que forma o Effect
Boundary de uma operação e o alcance real dessa garantia em Ruby, que é uma linguagem dinâmica.

## Decisão

### 1. Capacidade

Uma **capacidade** é um objeto congelado que o framework entrega ao bloco `call` de um comando, handler ou
query, a partir da declaração `uses`. O bloco recebe só as capacidades que declarou:

```ruby
command :publish_post do
  uses :posts, :clock          # as duas únicas coisas que o call alcança
  call do |input, posts, clock|
    ...
  end
end
```

`uses` não é um contêiner de injeção de dependência: os nomes são resolvidos pelo grafo no boot. Um nome que
não existe é erro de boot, com a mensagem dizendo o que falta e a declaração exata a escrever.

### 2. Tipos de capacidade

| Tipo | Exemplos | Efeito | Onde pode ser usada |
|---|---|---|---|
| Repositório | `:posts`, `:leads` (um por entidade) | Lê e grava no escopo do ator e do tenant, sob RLS | Comandos, queries, handlers |
| Determinística | `:clock`, `:uuid`, `:random` | Nenhum efeito externo; valores simuláveis | Comandos, queries, handlers |
| Externa | `:mailer`, `:http`, `:storage`, serviços de terceiros | Efeito fora do banco | **Somente handlers e atividades de workflow** |
| Saída | `emits` (outbox) | Grava o evento na transação | Comandos (implícita) |

- **Comandos não usam capacidades externas.** É o que o ADR-016 impõe: dentro da transação, o único efeito
  externo é a outbox. Um comando que precisa de um efeito externo emite um evento e deixa o handler fazer.
- Uma capacidade externa é **declarada pela aplicação** com os dados que o framework precisa para
  interceptá-la:

```ruby
effect :mailer do
  idempotency_key true         # o provedor aceita chave de idempotência
  retry_safe      true         # repetir a chamada é seguro
  simulate        :memory      # como o simulador a substitui nos testes
end

effect :http do
  hosts "api.exemplo.com", "pagamentos.exemplo.com"   # lista fechada
  timeout 5
end
```

(Sintaxe proposta; nada disso existe ainda.)

- `:http` só alcança os hosts declarados. Qualquer outro host é recusado pela capacidade, com erro explícito.

### 3. Repositórios

- O repositório recebido por `uses :leads` só opera sobre a entidade `lead`, já dentro do escopo do ator e do
  tenant (ADR-005). Ele não expõe SQL cru.
- SQL explícito é uma capacidade à parte, `uses :sql`, e aparece no relatório como **fora da garantia
  estrutural** (o RLS continua valendo). É a exceção, não o caminho comum.
- Todo repositório grava pelas etapas 6 e 7 do ADR-016: reautorização sobre o estado final, campos de
  transição, evento, histórico, auditoria.

### 4. Effect Boundary

O **Effect Boundary** de uma operação é o conjunto de capacidades que ela declara. Tudo o que sai dele é
declarado e pode ser interceptado, porque toda chamada passa por um despachante do framework. O despachante
permite:

- **Registrar** a chamada (trace, auditoria, custos).
- **Simular** a capacidade (testes): relógio, UUID e aleatoriedade vêm de uma semente reproduzível; e-mail,
  HTTP e armazenamento vão para um duplo em memória, e falhas e atrasos podem ser injetados.
- **Substituir** a capacidade por uma versão simulada no modo sombra, para comparar versões sem duplicar
  efeitos reais.
- **Limitar** (timeout, taxa, hosts).

Operações com capacidades que não aceitam interceptação (`retry_safe: false`, sem simulação) ficam
**inelegíveis para o modo sombra** e não são repetidas automaticamente após deadlock (ADR-016).

### 5. O que o Vetra faz para impedir o escape, e o que não faz

Ruby é dinâmico; nada impede por completo `Net::HTTP.get` num bloco. Por isso o Vetra combina três
mecanismos, cada um com seu limite:

1. **Análise estática no boot.** O corpo do `call` é analisado (com Prism) e o uso direto de constantes
   conhecidas que fazem efeito (`Time.now`, `Date.today`, `SecureRandom`, `Net::HTTP`, `File`, `IO`, `Socket`,
   `Kernel#system`, `` ` `` e semelhantes) é **erro de boot**. Chamadas dinâmicas que a análise não consegue
   resolver (`send`, `const_get`, `eval`, `instance_variable_get`) geram **aviso**, ou exigem declaração
   explícita.
2. **Declaração de exceção.** `unsafe_effect "motivo"` num comando libera o uso direto, registra o comando
   como **fora da garantia** em `vetra explain` e no `vetra doctor`, e o torna inelegível para repetição e
   para o modo sombra.
3. **Classificação das dependências.** Cada gem carregada é classificada como **confiável**, **restrita** (só
   em handlers) ou **fora da garantia**. A classificação é declarada em `config/app.rb` (`trust`, `restrict`);
   uma gem não classificada aparece como fora da garantia no `vetra doctor`.

**Limites honestos:**

- A garantia vale para código que usa o runtime do Vetra. Uma gem que abre conexão própria com o banco ou a
  rede escapa das capacidades. Com o contexto assinado (ADR-005), uma conexão própria não consegue forjar o
  tenant, mas pode fazer I/O que ninguém interceptou.
- Código comprometido no mesmo processo tem o que a aplicação tem.
- A análise estática é um filtro, não uma prova: código que monta nomes de método em tempo de execução pode
  passar.
- Ruby::Box não é um sandbox de segurança e não entra neste mecanismo (ADR-006).

### 6. Relação com autorização

Ter a capacidade não é ter permissão. `uses :leads` entrega o repositório; quem pode ler ou gravar, e em que
escopo, é decidido pelas políticas e pelo RLS. A declaração `authorize` do comando continua obrigatória e é
conferida na etapa 3 do ADR-016.

## Alternativas rejeitadas

- **Acesso global** às entidades e serviços (constantes e `default_scope` à la Rails): torna o escopo uma
  convenção e impede interceptar e simular.
- **Injeção de dependência explícita estilo Java** (interfaces, fábricas, contêiner configurado): atende o
  princípio, mas viola o orçamento de conceitos da camada 1 e a regra de "sem cerimônia corporativa". `uses`
  entrega o mesmo resultado sem declarar interface.
- **Isolar cada comando num Ractor ou num Ruby::Box**: nenhum dos dois é um sandbox de segurança, ambos são
  experimentais e quebram extensões nativas. O núcleo não pode depender deles.
- **Interceptar `Kernel`, `Net::HTTP` e `Time` globalmente em runtime** (monkey patch): é frágil, afeta o
  código das gems e recria o problema de metaprogramação em runtime que o Vetra quer evitar.
- **Permitir efeitos externos em comandos**: contradiz o ADR-016 e impede repetição segura. Ver questão em
  aberto abaixo.

## Consequências

- Cada comando, handler e query tem uma lista legível do que toca. `vetra explain` mostra o Effect Boundary
  de uma operação.
- Os testes de simulação (pilar 8) viram uma consequência direta, em vez de uma biblioteca à parte: todo
  efeito já passa pelo despachante.
- O desenvolvedor escreve um pouco mais (`uses`, `effect`); em troca não escreve configuração de injeção nem
  mocks.
- Gems sem classificação ou que fazem I/O próprio ficam visíveis como fora da garantia, o que pode incomodar
  num ecossistema acostumado a "colocar a gem e usar".
- A análise estática é mais um custo de boot, coberto pelo cache da IR do grafo.

## Garantias e seus níveis

| Garantia | Nível | Mecanismo |
|---|---|---|
| Uma operação só alcança as capacidades que declarou | Estrutural | Declaração `uses` verificada no boot, para o que foi declarado |
| Uso direto de constantes de efeito conhecidas é recusado | Estrutural | Análise estática do `call`; não cobre código dinâmico |
| Efeitos pelo runtime podem ser simulados e interceptados | Verificável por testes | Despachante e simulador com semente |
| `:http` só alcança hosts declarados | Verificável por testes | Verificação no despachante |
| Gem com conexão própria respeita o Effect Boundary | **Fora da garantia** | Documentado e listado pelo `vetra doctor` |

## Testes de aceitação

1. `uses` com nome inexistente é erro de boot e a mensagem traz a declaração a escrever.
2. Um `call` com `Time.now`, `SecureRandom.hex` ou `Net::HTTP.get` é recusado no boot; com `unsafe_effect`, é
   aceito e marcado como fora da garantia.
3. Um comando que declara uma capacidade externa é recusado no boot.
4. `:http` recusa um host que não está na lista.
5. O simulador, com a mesma semente, produz o mesmo relógio, os mesmos UUIDs e a mesma sequência de falhas.
6. Um comando com capacidade `retry_safe: false` não é repetido após deadlock e é recusado no modo sombra.
7. `vetra explain` lista as capacidades de um comando, incluindo as marcadas como fora da garantia.
8. Uma gem não classificada aparece no relatório do `vetra doctor`.

## Questões em aberto

- **Leitura externa em comandos.** Um comando que precisa de um dado externo (cotação, CEP) hoje não pode
  chamá-lo. A saída atual é um handler que preenche o dado depois, ou um workflow. Vale um tipo de capacidade
  "leitura externa pré-transação" (`phase: :before`), chamada antes da etapa 4 e sem efeito? Decidir com um
  caso real do módulo de referência.
- **Granularidade da classificação de dependências.** Por gem, por constante ou por namespace.
- **Formato final do `effect`** e quem escreve os adaptadores (framework ou aplicação).
- **Interação com o modo sombra**: ADR-012 define como o simulador substitui cada tipo de capacidade.

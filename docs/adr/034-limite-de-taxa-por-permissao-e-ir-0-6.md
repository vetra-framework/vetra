# ADR-034: Limite de taxa por permissão e IR 0.6

- Status: aceito
- Aceite: 2026-11-03, pelo Claude por delegação do mantenedor, após a auditoria da C4 (devolvida na rodada 1, aprovada na rodada 2).
- Data: 2026-11-03
- Depende de: ADR-001 (IR e compatibilidade), ADR-007 (operações e superfícies), ADR-011 (MCP), ADR-016 (ciclo da operação) e ADR-019 (sinais efêmeros)

## Contexto

A [proposta técnica](../proposta-tecnica.pdf) prevê limites de taxa e remete ao
[blog](../exemplos/02-blog.pdf), que declara `rate_limit: "5/min"` em `can :create, on: :comment`.
O DSL recusava essa opção com `unsupported_option`. O [ADR-011](011-mcp-com-identidade-delegada.md) §5 exige limites por agente e delegação,
além dos limites do papel; o [ADR-019](019-sinais-efemeros.md) §2 limita sinais por tópico e ator. Falta representar o limite
de uma permissão sem confundi-lo com uma condição de autorização ou um controle de uma rota HTTP.

## Decisão

### Sintaxe e normalização

`can` aceita `rate_limit:` como **string**, na forma `"N/unidade"` ou `"N/J<unidade>"`, em que
`N` é o número de admissões e `J` é a duração da janela. A forma sem `J` significa uma unidade.
As unidades fechadas são `s` (segundo), `min` (minuto) e `h` (hora).
Exemplos: `"5/min"`, `"5/2min"`, `"1/30s"` e `"100/h"`. A notação `J<unidade>` significa apenas
a concatenação do inteiro e da unidade, sem espaços: `2min`.

Limite e duração são inteiros estritamente positivos, sem sinal, zeros à esquerda, fração ou espaços.
O limite e a duração convertida em segundos devem caber no intervalo inteiro seguro da IR
(`1..9007199254740991`). Não se aceitam símbolos, hashes, `nil`, booleanos, números avulsos, unidades
implícitas ou desconhecidas. A recusa usa `rate_limit`, ponteiro `/rate_limit` e arquivo/linha de `can`.
Palavras-chave desconhecidas continuam produzindo `unsupported_option`.

O normalizador acrescenta **somente à política gerada**:

```json
"rate_limit": { "limit": 5, "window_seconds": 60, "key": "actor_tenant" }
```

`5/min` e `5/60s` têm o mesmo descritor. O campo é opcional; omissão significa ausência de limite
declarado naquela política. Não há limite padrão, propriedade de rota nem configuração global nova.

### Unidade de contagem e chave

Cada política tem seu contador lógico, identificado pelo namespace da aplicação, **ID da política,
tenant e ator**. `key: "actor_tenant"` é o único modo admitido nesta versão. Tenant e ator vêm do
contexto confiável da operação; argumentos e parâmetros de rota não podem escolhê-los.
Aplicações sem tenant usam um marcador único de ausência, no namespace da aplicação.
O ator inclui tipo e identidade: usuário autenticado ou identidade anônima estável emitida e verificada
pelo runtime. Um visitante não pode usar `nil`, uma identidade global de todos os visitantes ou um ID
arbitrário enviado pelo cliente. Sem identidade confiável, o futuro executor deve recusar a operação
limitada. Este ADR não implementa sessões nem autenticação e não define IP como identidade do ator.

O limite governa o conjunto de ações e campos da política. Uma declaração com várias ações compartilha
o mesmo contador; `manage` conserva sua expansão CRUD. `on: %i[a b]` gera uma política por entidade,
cada uma com seu contador. Rotas, superfícies, IDs de registros e comandos distintos que usam a mesma
permissão não criam cotas extras. Políticas diferentes têm contadores diferentes, mesmo com o mesmo
descritor. Reordenar declarações pode mudar os IDs gerados; continuidade de contadores entre builds
pertence à integração futura com o runtime.

A janela é **móvel**, com no máximo `limit` admissões no intervalo dos últimos `window_seconds`
segundos. Quando todas as políticas que autorizam a operação têm limite, cada tentativa admitida conta
uma vez em todas elas, inclusive repetições idempotentes e falhas posteriores do executor. Se alguma
delas não tem limite, a admissão não consome cotas de nenhuma delas. Recusa de autorização ou de taxa
não é admissão.
Concorrência não pode admitir acima do limite. A implementação dos contadores, relógio e reservas
conjuntas permanece pendente; o build e o link não mantêm contadores nem oferecem essa garantia operacional.

### Relação com autorização, MCP e sinais

O descritor **não concede acesso**, não é predicado e não muda `actions`, `fields`, `predicate`, `reads`
ou a avaliação normal das políticas. O motor primeiro determina a autorização; uma operação negada
continua negada. O limite qualifica somente a concessão em que foi declarado; as concessões continuam
aditivas. Consideram-se as políticas aplicáveis ao ator que autorizam a operação para a entidade,
ação, campos e predicado em questão:

- Se alguma dessas políticas **não tem limite**, a operação é admitida sem verificar nem consumir
  as cotas de nenhuma delas.
- Só quando **todas têm limite**, todas precisam permitir a admissão antes de executar a operação,
  e a admissão conta em todas. A seleção não pode alternar entre políticas limitadas ou rotas para
  obter cotas adicionais.

Isso não substitui o controle antecipado do ADR-011: os limites próprios de **agente e delegação**
continuam adicionais e anteriores ao acesso ao banco, na etapa 1. O ator desta política é o delegante
do contexto assinado, como naquele ADR; o agente compartilha a cota dele e tem ainda as cotas próprias
do MCP. Tampouco substitui o limite **por tópico e ator** dos sinais efêmeros do ADR-019, que não são
operações autorizadas por `can`. Nada nesta entrega adiciona MCP, sinais ou execução de políticas.

### Formato, validação e link

É recurso semântico novo: entra na **IR 0.6**, com **`vetra.rate_limit`** em `requires`, conforme
o ADR-001 §4. O build só emite o requisito quando gera ao menos uma política com o campo. Um grafo
sem uso não exige implementação nova do consumidor. A gem continua alpha.5.

O schema 0.6 é fechado e autocontido. O objeto exige as três propriedades acima, inteiros positivos
seguros e a chave conhecida; não aceita propriedades extras. A validação semântica de IR externa
recusa campo sem requisito. Um requisito sem campo é permitido, como nos recursos opcionais anteriores.
Os schemas publicados **0.1 a 0.5 permanecem imutáveis**: recusam o novo campo e o novo requisito.
`Schema::VERSIONS` é a fonte única de versões e recursos suportados.

Validação, diff e link leem as seis versões com suas regras exatas. A normalização para auditoria de
artefatos antigos não pode descartar um limite declarado: falha com `ir_feature`. Sem a declaração,
o link conserva o documento antigo e seus bytes. Um limite adulterado, mesmo estruturalmente válido
e com digest recalculado, diverge dos fontes e impede o link. Todos os exemplos são reconstruídos em 0.6.

### Diff

Toda alteração do campo aparece em `/rate_limit`, categoria `permissions`, com revisão obrigatória
e `permission_impact: indeterminate`. O relatório não prova aumento ou redução efetiva de acesso.

| Mudança | Impacto |
|---|---|
| Adicionar um limite | `review` |
| Reduzir ou manter o número e aumentar ou manter a janela, com mudança efetiva | `review` (aperto) |
| Remover o limite, inclusive a política limitada inteira | `breaking` (quebra potencial de segurança) |
| Aumentar o número ou reduzir a janela, inclusive mudanças em direções opostas | `breaking` (afrouxamento ou comparação inconclusiva) |
| Trocar só a unidade por duração equivalente | Nenhuma mudança do campo |

Não basta comparar a razão média: `5/min` e `10/2min` permitem rajadas diferentes. O gate continua
exigindo justificativa pelos digests exatos para uma quebra intencional. Versão, requisito e manifesto
aparecem separadamente, conforme as regras já existentes.

## Alternativas rejeitadas

- Limite por rota: permitiria multiplicar a cota expondo a mesma operação em outras superfícies.
- Chave apenas por tenant: faria atores distintos disputarem uma cota coletiva; apenas por ator:
  misturaria a atividade dele em empresas diferentes.
- Chave configurável nesta versão: ampliaria a semântica sem necessidade do exemplo da proposta.
- Tratar o limite como concessão ou termo de predicado: misturaria autorização com admissão e poderia
  criar caminhos alternativos de acesso.
- Exigir todos os limites aplicáveis mesmo quando uma concessão sobreposta sem limite autoriza a
  operação (regra anterior): acrescentar uma permissão limitada reduziria o acesso já concedido por
  outra sem limite, contrariando o caráter aditivo das concessões. No blog, o `admin` com
  `can :manage, on: %i[post comment]` passaria a criar comentários a `5/min` se a permissão do
  visitante também se aplicasse a ele.
- Janela sem unidade, taxas fracionárias ou modos de rajada: introduziriam ambiguidade e novos contratos.
- Comparar somente a taxa média no diff: esconderia afrouxamentos de rajada.
- Acrescentar o recurso à IR 0.5 ou em `annotations`: violaria a evolução semântica do ADR-001.
- Emitir `requires` em todo grafo: imporia suporte ao recurso a aplicações que não o usam.

## Consequências

O blog declara a permissão visitante da proposta com `"5/min"`, o recorte de comentários e o comando
explícito de aprovação. A entidade preserva a proteção de `approved` por `set_by`; a UI permanece fora.
Se a permissão do visitante também se aplicar ao `admin`, sua concessão administrativa sem limite
continua permitindo criar comentários sem consumir a cota do visitante. Acrescentar uma concessão
limitada não reduz um acesso já autorizado por uma sem limite. Quando só há concessões limitadas,
a admissão conjunta impede multiplicar cotas alternando entre elas. Retirar a última concessão sem
limite sujeita a operação aos limites restantes; acrescentar uma sem limite aparece no diff como
permissão adicionada, conforme as regras existentes.
O limite é declaração verificável, sem aplicação de taxa nesta fase.

## Garantia e testes de aceitação

Garantia estrutural e verificável por testes: `rate_limit_test.rb`, executado por `test:diagnostics`, cobre
sintaxe, origem, janelas, canonicalização, emissão condicional, invariância dos predicados, políticas
com várias ações/entidades, IR externa, seis versões, link sem execução e adulterações, e diff nas duas
direções. O teste do blog também confere a concessão administrativa sobre comentários sem limite.
A admissão com concessões sobrepostas, a execução de operações e os contadores não têm garantia
operacional nesta implementação; deverão ter testes no futuro runtime.

## Questões em aberto

- Runtime: armazenamento compartilhado, relógio, algoritmo de janela móvel, atomicidade entre políticas,
  tratamento de falhas e continuidade das cotas ao trocar a versão do grafo. Esses mecanismos precisam
  cumprir o contrato e ser testados sob concorrência antes de anunciar execução de `vetra.rate_limit`.
- Autenticação: emissão e verificação da identidade anônima estável e prevenção de criação abusiva de
  identidades; não se promete resolver abuso anônimo apenas com uma cota por ator.
- Integração dos limites de papel com a etapa de admissão do ADR-016 e com os limites antecipados de
  agente/delegação do ADR-011, incluindo representação própria desses limites adicionais.

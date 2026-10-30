# ADR-018: Camada de UI em módulos fora do núcleo, com ejeção em três níveis

- Status: proposto
- Data: 2026-10-30
- Depende de: ADR-007 (comando e adaptadores), ADR-016 (ciclo de vida da operação)
- Relacionados: ADR-020 (entrega live), ADR-019 (sinais efêmeros), ADR-017 (formatação de dinheiro),
  ADR-013 (mascaramento)

## Contexto

O Exemplo 2 (blog) usa uma camada de UI no servidor: rotas de página ligadas a consultas, templates ERB,
formulários montados a partir do contrato de um comando e telas administrativas geradas. Ele mesmo registra a
lacuna: essa camada "ainda não está especificada e precisa de um ADR próprio antes de ser considerada parte do
Vetra".

Três tensões precisam de resposta:

1. **A UI é uma camada de apresentação, e o núcleo não pode depender dela.** O que dá valor ao Vetra (grafo,
   comandos, políticas, RLS) existe sem tela nenhuma, e muitos usuários terão só uma API.
2. **Telas geradas são genéricas.** Personalizar o visual obriga a "ejetar" a tela, e ejetar tende a cortar o
   vínculo com o contrato: o scaffold do Rails, depois de copiado, não sabe mais o que o modelo exige.
3. **A autorização não pode morar na tela.** Esconder um botão é apresentação; a exclusão de verdade é
   protegida no servidor.

O exemplo de blog também mostra honestamente o limite: os templates públicos têm o mesmo tamanho nos dois
frameworks. O Vetra **não simplifica a camada de apresentação**; o ganho está nas telas geradas e no vínculo
com os comandos.

## Decisão

**A UI é um conjunto de módulos fora do núcleo. O Turbo é o cliente no navegador. Uma tela pode ser ejetada em
três níveis, e a ejeção substitui a apresentação, nunca a autorização. O `vetra doctor` compara os templates
ejetados com o contrato.**

### 1. Módulos, e o núcleo não depende deles

| Módulo | Responsabilidade |
|---|---|
| `vetra-ui` | Páginas, layouts, templates ERB, formulários de comando |
| `vetra-turbo` | Cliente Turbo para as consultas live (ADR-020) |
| `vetra-admin` | Telas administrativas geradas (`crud ui: :admin`) |
| `vetra-react` | Cliente tipado para SPAs |

- Uma extensão pode usar qualquer componente do núcleo; o **núcleo nunca depende de uma extensão**.
- A camada só existe quando a aplicação a pede (`ui :server` em `config/app.rb`, e o diretório `app/ui/`). Sem
  ela, o Vetra serve uma API.

### 2. Dois modos de cliente

- **Modo servidor:** HTML renderizado no servidor, com o **Turbo** como cliente no navegador. Reaproveita um
  cliente maduro; o lado servidor do trecho live continua novo (ADR-020).
- **Modo API:** JSON, com **SDK TypeScript e OpenAPI gerados do grafo** para SPAs em Vue ou React. Valores
  monetários seguem a forma canônica, com `amount` em string (ADR-017).

### 3. Páginas, templates e formulários

- `page` liga uma rota a uma consulta e a um template:

```ruby
page "/posts/:slug", query: :post_by_slug, template: "posts/show"
```

- O template recebe **só** `input` (a entrada da consulta) e `result` (o que ela devolveu). Não alcança
  repositórios, comandos nem capacidades: a tela mostra o que a consulta devolveu, já filtrado pela política.
- Um formulário que dispara um comando é montado **a partir do contrato dele** (`command_form`): valida a
  entrada, aplica o limite de taxa do papel, reexibe a página com os erros em caso de falha e redireciona com
  uma mensagem em caso de sucesso. O comando é o mesmo das outras superfícies (ADR-007).
- Os predicados de visibilidade nos templates (`can?`) servem à **apresentação**; a decisão real continua no
  servidor (ADR-016, etapa 3 e etapa 6).
- Formato de dinheiro, datas e textos vêm do idioma da requisição, na borda (ADR-017).

### 4. Ejeção em três níveis

A tela gerada pode ser personalizada em níveis crescentes, e cada um deixa de herdar mais coisas:

| Nível | O que o desenvolvedor escreve | O que continua vindo do framework |
|---|---|---|
| **1. Slots** | Preenche pontos nomeados de um template gerado | Estrutura, formulário, validação, erros |
| **2. Template com props** | Substitui o template, que recebe props definidos pelo contrato | Dados, formulário opcional, autorização |
| **3. Página inteira** | Escreve a página e usa as consultas e os comandos que quiser | Consultas, comandos, políticas, RLS |

Os três níveis (slots, template com props, página inteira) vêm da proposta; a divisão do que cada um ainda herda
do framework, na terceira coluna, é a proposta deste ADR e pode mudar com a primeira implementação.

**A ejeção substitui a apresentação, nunca a autorização.** Uma tela ejetada continua falando com os mesmos
comandos e consultas, sob as mesmas políticas. Não existe ejeção que deixe a tela escrever ou ler o que o
ator não pode. É um dos critérios de aceitação do tempo real (gate G4): a tela ejetada usa os mesmos comandos
e as mesmas regras de autorização.

### 5. `vetra doctor` compara a tela ejetada com o contrato

Uma tela ejetada pode ficar para trás quando o contrato muda (um campo removido, um comando renomeado). O
`vetra doctor` compara os templates ejetados com o contrato atual e acusa a divergência que consegue provar: um
formulário que referencia um comando inexistente, um campo que não existe mais na entrada ou na saída, um
campo pessoal exibido sem a classificação esperada.

O limite é declarado: um template ERB é código, e só o que é referenciado de forma literal é verificável. Um
nome de campo montado dinamicamente escapa. O que fica verificável e o que fica de fora é questão em aberto.

### 6. Admin gerado e seus limites

`crud ui: :admin` gera as telas administrativas das entidades, e `expose ui:` coloca ações (como "Publicar") nas
telas, mostradas só quando a condição vale. O admin gerado é **genérico**: personalizar o visual exige ejetar, e
nesse ponto a vantagem em linhas diminui.

## Alternativas rejeitadas

- **Cliente JavaScript próprio** (a alternativa da proposta): um cliente de tempo real maduro já existe, e o
  Turbo o fornece. Escrever outro seria custo sem diferencial.
- **Scaffold copiado, sem vínculo com o contrato** (a alternativa da proposta): a tela copiada diverge do
  contrato em silêncio e passa a mentir sobre o que o comando aceita.
- **UI dentro do núcleo:** obrigaria quem só quer uma API a carregar uma camada de apresentação, e quebraria a
  regra de que o núcleo não depende de extensões.
- **Só SPA e API:** exclui o caso simples (blog, painel interno) em que HTML no servidor é mais barato.
- **Ejeção total sem regra:** a tela ejetada poderia contornar a autorização. Ejetar só a apresentação mantém a
  garantia.
- **Autorização no template:** esconder um botão não protege nada; vale só como apresentação.

## Consequências

- Reaproveita um cliente maduro. O Vetra constrói o lado servidor: páginas, formulários por contrato, admin e
  a renderização do live.
- Uma tela ejetada continua sob comandos e políticas, mas pode divergir do contrato; o `doctor` reduz esse
  risco sem eliminá-lo.
- A camada de apresentação não fica menor que a do Rails; o ganho está no que é gerado e no vínculo com o
  contrato.
- Em contrapartida, o Vetra precisa igualar o que o Rails já faz bem nessa borda (gerador de autenticação, limite
  de taxa nativo, filtragem de e-mail nos logs por padrão), ou a comparação perde.
- Quatro módulos a manter e a versionar com o núcleo.

## Garantias e seus níveis

| Garantia | Nível | Mecanismo |
|---|---|---|
| O núcleo funciona sem os módulos de UI | Estrutural | O núcleo não depende de extensões |
| Uma tela, ejetada ou não, não ultrapassa a autorização | Transacional e verificável por testes | Comandos e consultas sob políticas e RLS (ADR-016, ADR-005) |
| Esconder um controle não protege uma operação | Verificável por testes | A operação é recusada no servidor mesmo por requisição direta |
| Uma tela ejetada reflete o contrato atual | **Limitada** | `vetra doctor` verifica as referências literais; ERB dinâmico escapa |
| Valores monetários e dados pessoais seguem o contrato | Verificável por testes | Formatação na borda (ADR-017) e mascaramento (ADR-013) |

## Testes de aceitação

1. O núcleo, a API e a suíte do compilador funcionam sem nenhum módulo de UI instalado.
2. Uma `page` liga rota, consulta e template; o template só enxerga `input` e `result`.
3. Um `command_form` é gerado do contrato do comando e valida a entrada, aplica o limite de taxa do papel,
   reexibe os erros e redireciona no sucesso.
4. Uma tela ejetada nos três níveis chama os mesmos comandos; uma ação negada pela política é recusada também
   pela tela ejetada.
5. Um botão ausente na tela não impede nem permite a operação: a requisição direta é decidida pela política.
6. O `doctor` acusa um template ejetado que referencia um campo removido do contrato.
7. O `doctor` acusa um formulário que referencia um comando inexistente.
8. No modo live, uma mensagem gera no máximo uma renderização por combinação de predicados (gate G4).
9. No modo API, o SDK TypeScript gerado reflete o contrato e representa dinheiro com `amount` em string.
10. Campos pessoais são mascarados em páginas de erro e em logs da camada de UI.

## Questões em aberto

- **Como o gerador versiona os templates ejetados** e como detecta que a ejeção partiu de um contrato que mudou.
  Uma hipótese é gravar, no arquivo ejetado, o digest do trecho do contrato de que ele partiu.
- **O que o `vetra doctor` consegue verificar em ERB dinâmico**, e se vale uma sintaxe restrita de template que
  torne mais coisas verificáveis.
- Sintaxe e semântica exatas de `page`, `command_form`, `crud ui:` e `expose ui:`, que o exemplo do blog usa
  mas nenhuma especificação fixa; o schema 0.1 da IR não representa páginas.
- Autenticação, limite de taxa e filtragem de logs: o que cada módulo entrega por padrão.
- Como os módulos são versionados e distribuídos em relação ao núcleo.
- Acessibilidade e internacionalização dos templates gerados.

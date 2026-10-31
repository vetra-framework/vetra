# ADR-018: Camada de UI em módulos fora do núcleo, com ejeção em três níveis

- Status: aceito
- Data: 2026-10-30
- Depende de: ADR-007 (comando e adaptadores), ADR-016 (ciclo de vida da operação)
- Dependem deste ADR (na data do aceite): nenhum. Os ADRs 017, 019, 020 e 021 o citam, mas valem sem ele.
- Relacionados: ADR-001 (IR e digest), ADR-004 (análise estática), ADR-010 (sessão do modo hospedado), ADR-013
  (mascaramento), ADR-017 (formatação de dinheiro), ADR-019 (sinais efêmeros), ADR-020 (entrega live), ADR-021
  (campos de transição)

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
três níveis, e a ejeção substitui a apresentação, nunca a autorização. Todo arquivo de tela carrega o digest do
contrato de que partiu, e o `vetra doctor` o compara com o contrato atual.**

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

- O template é renderizado num contexto que recebe `input` (a entrada da consulta), `result` (o que ela
  devolveu) e os auxiliares de apresentação (formatação e `can?`). Não recebe repositórios, comandos nem
  capacidades: a tela mostra o que a consulta devolveu, já filtrado pela política. Isso é uma convenção do
  contexto de renderização, **não uma barreira**: o ERB é Ruby (veja o §7).
- Um formulário que dispara um comando é montado **a partir do contrato dele** (`command_form`): valida a
  entrada, aplica o limite de taxa do papel, reexibe a página com os erros em caso de falha e redireciona com
  uma mensagem em caso de sucesso. O comando é o mesmo das outras superfícies (ADR-007).
- **O formulário e o botão são servidos pela exposição `http` do comando** (ADR-007, §1). `command_form` e
  `expose ui:` num comando sem `expose http:` são erro de compilação: nada é exposto por padrão, nem à tela. As
  regras de rota do ADR-007, §4 (método, colisão, idempotência) valem para eles.
- Os predicados de visibilidade nos templates (`can?`) servem à **apresentação**; a decisão real continua no
  servidor (ADR-016, etapa 3 e etapa 6). Como o `can?` é avaliado fica em aberto.
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
ator não pode, **desde que o código da tela use o runtime do Vetra**; o limite está no §7. É um dos critérios de
aceitação do tempo real (gate G4, critério 10 do ADR-020): a tela ejetada usa os mesmos comandos e as mesmas
regras de autorização.

**No nível 3, um comando só roda por um método que muda estado.** O contexto de uma página para uma requisição
`GET` oferece consultas e não oferece comandos; um comando é chamado a partir de um formulário ou de uma ação,
por `POST`, `PUT`, `PATCH` ou `DELETE`. É a regra do ADR-007, §4 (um comando nunca é exposto por `GET`) estendida
ao código da página, que de outra forma a contornaria chamando o comando de dentro da renderização.

### 5. Versionamento da tela ejetada e `vetra doctor`

Uma tela ejetada pode ficar para trás quando o contrato muda (um campo removido, um comando renomeado, um campo
obrigatório novo). O gerador e o `vetra doctor` tratam isso assim.

**A linha de base fica no arquivo.** Todo arquivo que o gerador entrega ao desenvolvedor (slots, template com
props, página) nasce com um cabeçalho, num comentário de ERB ou de Ruby, com: o formato (`vetra-ui/1`), o alvo (a
consulta ou o comando a que se liga), o nível e o **digest da projeção do contrato** de que partiu.

- A projeção cobre, para cada operação a que o arquivo se liga: o identificador; os campos do contrato de entrada
  e de saída (nome, tipo, `required` e valores de enum); a classificação `privacy`; e as proteções `set_by:` e
  `guarded:` (ADR-021). **Nada mais do grafo entra**, então uma mudança sem relação com a tela não a acusa.
- O digest segue a convenção do ADR-001: `"sha256:"` mais o SHA-256, em hexadecimal minúsculo, do JCS (RFC 8785)
  da projeção. A linha de base **não vai para a IR**: ela viaja com o arquivo quando ele é movido ou renomeado, e
  a IR continua sendo função só das declarações.

**O `vetra doctor` compara o arquivo com o contrato atual e dá duas respostas.**

- **Erro, o que ele prova de forma literal:** um formulário que referencia um comando inexistente, um campo que
  não existe mais na entrada ou na saída, um campo pessoal exibido sem a classificação esperada, e o nome de um
  slot que o template gerado não tem mais.
- **Aviso, quando o digest difere e nada se prova quebrado:** o contrato mudou desde a ejeção. É o caso que a
  verificação literal não enxerga, porque é uma **ausência**: um campo obrigatório novo que o formulário não envia,
  um tipo alterado, um valor novo de enum, um campo que passou a ser pessoal. O aviso mostra a diferença da
  projeção (campos acrescentados, removidos e alterados).
- `vetra ui:resync ARQUIVO` regrava o digest depois que o desenvolvedor revisou, sem alterar o corpo. Um arquivo
  sem cabeçalho é reportado como sem linha de base (aviso).
- A CI da aplicação roda a mesma verificação: os erros a reprovam, os avisos aparecem no relatório.

O limite é declarado: um template ERB é código, e só o que é referenciado de forma literal é verificável. O
`doctor` compila o ERB para Ruby e o analisa com o Prism; um nome de campo montado dinamicamente escapa. O digest
cobre parte desse furo (o contrato mudou, mesmo que a referência seja dinâmica), mas não diz o que a tela faz com
a mudança.

### 6. Admin gerado e seus limites

`crud ui: :admin` gera as telas administrativas das entidades, e `expose ui:` coloca ações (como "Publicar") nas
telas, mostradas só quando a condição vale. O admin gerado é **genérico**: personalizar o visual exige ejetar, e
nesse ponto a vantagem em linhas diminui. Os campos `set_by:` e os valores `guarded:` aparecem como somente
leitura, e as ações como botões `expose ui:` (ADR-021, regra 3).

### 7. Segurança da camada de apresentação

1. **A análise do ADR-004, §5 cobre o código de UI.** Os templates, compilados para Ruby, e as páginas do nível 3
   passam pela mesma análise estática do `call`: o uso direto de constantes que fazem efeito (`Net::HTTP`, `File`,
   `Socket` e as demais) é erro de boot. O limite é o do ADR-004: a análise é um filtro, não uma prova; código que
   monta nomes em tempo de execução passa; uma página que abre conexão própria com o banco escapa (o contexto
   assinado impede forjar o tenant, mas não impede I/O); e o `Ruby::Box` não é um sandbox (ADR-006). **A garantia
   de que a tela não ultrapassa a autorização vale para o código que usa o runtime do Vetra, nos três níveis.**
2. **CSRF.** Uma requisição que **muda estado** e se autentica por uma credencial que o navegador envia sozinho
   (cookie de sessão) só é aceita com uma prova de origem, verificada pelo adaptador na etapa 1 (ADR-016; ADR-007,
   §2): um token por sessão no formulário, comparado em tempo constante. A regra vale para a **credencial**, não
   para o formato do corpo: um corpo JSON com cookie também a exige. Uma requisição por credencial explícita (token
   de portador, no modo API) não a exige. Um cookie `SameSite` é defesa adicional, não substitui o token. No modo
   hospedado, a sessão é a do Rails (ADR-010) e o mecanismo concreto fica em aberto.
3. **Escape por padrão.** O motor de template escapa a saída HTML por padrão; a saída crua exige uma marca
   explícita, que o `doctor` lista. O ERB da biblioteca padrão não escapa (`<%= "<b>&" %>` sai cru; veja a
   verificação preliminar), então o motor precisa ser outro ou configurado para isso. O texto que vem do agente
   (ADR-011) ou do usuário é entrada não confiável.

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
- **Guardar a linha de base na IR ou num manifesto à parte:** ela se perde quando o arquivo é movido ou
  renomeado, e cada revisão de uma tela viraria uma mudança do grafo.
- **Digest do grafo inteiro, ou do contrato inteiro da entidade:** qualquer mudança acusaria toda tela, e o aviso
  deixaria de ser lido. A projeção cobre só as operações a que o arquivo se liga.
- **Reprovar o build a qualquer diferença de digest:** um campo opcional novo obrigaria a revisar toda tela
  ligada ao comando. Só o que o `doctor` prova quebrado é erro; a diferença é aviso.
- **Mesclar com o template gerado de partida (três vias):** exige guardar o conteúdo gerado, e não só o digest, e
  uma geração estável entre versões do módulo. Fica para uma evidência de uso.
- **O nível 3 chamar comandos em qualquer método:** reabriria, por código, a regra de que um comando não sai por
  `GET`, e um prefetch ou uma imagem com `src` malicioso executariam o comando.
- **Confiar no contexto de renderização como barreira:** ele limita o que a convenção entrega, mas o ERB é Ruby.
  Afirmar isolamento seria prometer o que só o ADR-004, com seus limites, oferece.
- **Escape opt-in (`h`, `sanitize`):** esquecer uma chamada é uma falha de XSS, e a saída crua deve ser a exceção
  visível.
- **Contar só com o cookie `SameSite` contra CSRF:** não cobre requisições do mesmo site e depende do navegador.

## Consequências

- Reaproveita um cliente maduro. O Vetra constrói o lado servidor: páginas, formulários por contrato, admin e
  a renderização do live.
- Uma tela ejetada continua sob comandos e políticas, mas pode divergir do contrato; o `doctor` reduz esse
  risco sem eliminá-lo. O digest no cabeçalho pega a ausência (um campo obrigatório novo), que a verificação
  literal não pega, ao custo de um passo de revisão (`ui:resync`) a cada mudança de contrato que atinge a tela.
- A camada de apresentação não fica menor que a do Rails; o ganho está no que é gerado e no vínculo com o
  contrato.
- Em contrapartida, o Vetra precisa igualar o que o Rails já faz bem nessa borda (gerador de autenticação, limite
  de taxa nativo, filtragem de e-mail nos logs por padrão, proteção contra CSRF e escape de saída), ou a
  comparação perde.
- Quatro módulos a manter e a versionar com o núcleo.
- A UI não está na IR 0.1; representá-la (páginas, rotas de página, ações `expose ui:`) exige uma nova MENOR com
  `vetra.ui` em `requires` (ADR-001). O protótipo recusa `ui :server`, `page`, `crud ui:` e `expose ui:`.
- O `vetra doctor` e `vetra ui:resync` não existem; a CLI do protótipo só tem os comandos `graph:*`.

## Garantias e seus níveis

| Garantia | Nível | Mecanismo |
|---|---|---|
| O núcleo funciona sem os módulos de UI | Estrutural | O núcleo não depende de extensões |
| Uma tela, ejetada ou não, não ultrapassa a autorização | Transacional e verificável por testes, para código que usa o runtime | Comandos e consultas sob políticas e RLS (ADR-016, ADR-005); análise do ADR-004, §5. Uma página com conexão própria escapa |
| Esconder um controle não protege uma operação | Verificável por testes | A operação é recusada no servidor mesmo por requisição direta |
| Uma página não executa comando numa requisição `GET` | Verificável por testes | O contexto de `GET` oferece só consultas (§4) |
| Uma requisição com cookie que muda estado exige a prova anti-CSRF | Verificável por testes | Verificação na etapa 1 do adaptador (§7) |
| A saída HTML é escapada por padrão | Verificável por testes | Motor com escape ativo; a saída crua é marcada e listada pelo `doctor` |
| Uma tela ejetada reflete o contrato atual | **Limitada** | `vetra doctor`: erro para a referência literal que falha, aviso para o digest que difere; ERB dinâmico escapa |
| Valores monetários e dados pessoais seguem o contrato | Verificável por testes | Formatação na borda (ADR-017) e mascaramento (ADR-013) |

## Testes de aceitação

1. O núcleo, a API e a suíte do compilador funcionam sem nenhum módulo de UI instalado.
2. Uma `page` liga rota, consulta e template; o template só enxerga `input`, `result` e os auxiliares de
   apresentação.
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
11. Todo arquivo entregue pelo gerador tem o cabeçalho de linha de base. O `doctor` avisa quando um campo
    obrigatório novo entra no comando e o formulário não o envia, e não avisa quando muda um contrato sem relação
    com a tela.
12. `vetra ui:resync` regrava o digest sem alterar o corpo do arquivo; um arquivo sem cabeçalho é reportado.
13. Uma página do nível 3 não consegue chamar um comando numa requisição `GET`.
14. Uma requisição que muda estado, com cookie de sessão e sem a prova anti-CSRF, é recusada na etapa 1, com
    corpo de formulário ou JSON; uma com token de portador não exige a prova.
15. Um valor com marcação HTML num campo do `result` sai escapado; a saída crua só sai com a marca explícita, e o
    `doctor` a lista.
16. O código de UI que usa uma constante de efeito (`Net::HTTP`, `File`...) é recusado no boot; `command_form`
    ou `expose ui:` num comando sem `expose http:` não compila.

## Verificação preliminar

Conferido à mão, **sem sonda versionada**: o ERB da biblioteca padrão (ERB 4.0.3, no Ruby 3.3.6 deste ambiente; o
projeto usa o 4.0.9) **não escapa** a saída: `ERB.new("<%= %q(<b>&) %>").result` devolveu `<b>&`, e só
`ERB::Util.html_escape` devolveu `&lt;b&gt;&amp;`. É a base do §7, item 3.

Não existem os módulos de UI, o DSL (`ui :server`, `page`, `crud ui:` e `expose ui:` falham no protótipo), a
representação na IR, o `vetra doctor` nem os cabeçalhos de linha de base.

## Questões em aberto

- **O que o `vetra doctor` consegue verificar em ERB dinâmico**, e se vale uma sintaxe restrita de template que
  torne mais coisas verificáveis. O §5 fixa só o que é literal e o digest.
- **Como o `can?` é avaliado.** O §3 diz que ele é só apresentação, mas não diz com quê. Uma política pode precisar
  de dados fora da linha do `result`; avaliar por linha dentro do template abre uma consulta por linha (N+1) numa
  transação já encerrada. Uma alternativa é a consulta devolver os booleanos que a tela usa.
- Sintaxe e semântica exatas de `page`, `command_form`, `crud ui:` e `expose ui:`, que o exemplo do blog usa
  mas nenhuma especificação fixa, e a representação na IR (nova MENOR): o nó de página, a rota de página e como o
  adaptador HTTP separa um formulário de uma chamada de API na mesma rota.
- O mecanismo concreto do token anti-CSRF (por sessão, duplo cookie, cabeçalho de origem), no modo independente e
  no hospedado (sessão do Rails, ADR-010), e qual motor de template escapa por padrão.
- Autenticação, limite de taxa e filtragem de logs: o que cada módulo entrega por padrão.
- Como os módulos são versionados e distribuídos em relação ao núcleo, e o que acontece com os slots quando um
  módulo remove um ponto. O merge de três vias com o template gerado de partida.
- Acessibilidade e internacionalização dos templates gerados.

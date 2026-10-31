# Vinculação validada das implementações

`graph:link` carrega o artefato versionado e associa suas implementações Ruby aos blocos do pacote
correspondente. É o terceiro incremento do compilador da [fase 0](fase-0.md), após geração/validação da IR
e [diff arquitetural](graph-diff.md). Os contratos seguem o [ADR-001](adr/001-grafo-da-aplicacao-e-ir.md).

## Executar

Na raiz do repositório:

```sh
bundle exec bin/vetra graph:link --root examples/blog
bundle exec bin/vetra graph:link --root examples/mini_crm
```

Cada exemplo retorna dois blocos Ruby vinculados e quatro **descritores de primitivas sem executor**.
O comando lê somente o `.vetra/graph.json` da aplicação informada; não aceita arquivo alternativo,
`--sources`, `--format` ou `--fail-on-breaking`. As verificações de fontes são obrigatórias.

Saída 0 indica vínculo consistente, 1 indica falha de artefato/fontes/registro e 2 indica uso incorreto.
Avisos do grafo continuam em stderr. O comando não executa operações, abre conexões ou aceita tráfego.

## Ordem do carregamento

1. Exigir um `.vetra/graph.json` regular, dentro da aplicação, sem redirecionamento por links simbólicos.
2. Validar JSON, versão/recursos, schema, invariantes e digest. Exigir os bytes canônicos seguidos de LF,
   a mesma versão do Vetra e a mesma versão do Ruby registradas em `producer`.
3. Conferir o conjunto de arquivos e hashes contra o manifesto **antes de avaliar declarações do projeto**.
   Uma alteração, inclusão ou remoção de arquivo impede a vinculação.
4. Criar um registro novo, avaliar as declarações confiáveis uma vez e selar o registro. Essa etapa
   recria as closures Ruby no processo; o corpo das operações `call` não é executado.
5. Normalizar esse registro em memória **para auditoria** e exigir igualdade com a IR aprovada.
   Divergência é erro; o resultado da auditoria não substitui o artefato.
6. Conferir referências, origem lexical do bloco, arquivo/digest, assinatura, análise e argumentos de
   capacidades. Referência ausente, extra, duplicada ou associada a outro bloco impede a publicação.
7. Conferir novamente os fontes e os bytes do artefato. Só então retornar uma unidade `LinkedGraph`
   completa, com dados congelados e closures privadas.

O registro e a normalização usados no build e nessa auditoria são os mesmos. Este protótipo paga o custo
de uma normalização completa ao vincular; não há cache executável nem promessa de tempo de boot. Em um
processo novo é necessário carregar código confiável para obter os blocos Ruby; isso não autoriza gerar
um modelo alternativo quando o artefato estiver ausente, incompatível ou divergente.

`graph:link` não grava, repara nem regenera o grafo. A reconstrução continua explícita em `graph:build`,
no desenvolvimento/pipeline, seguida de revisão. `.vetra/cache/` não tem autoridade sobre o carregamento;
sua ausência ou corrupção não altera a IR usada na vinculação.

## API Ruby e ordem dos argumentos

```ruby
require "vetra"

graph = Vetra::Graph::Compiler.new(root: "examples/blog").link
graph.implementation_ids
# => ["blog.find_post#call", "blog.publish_post#call"]

binding = graph.binding_for("command", "blog.publish_post")
binding["parameters"]
# => ["input", "posts", "clock"]
binding["arguments"].map { |argument| argument["capability"]["id"] }
# => ["blog.posts", "blog.clock"]
```

A IR ordena o **conjunto** `uses` (`clock`, `posts` no exemplo), enquanto o bloco declara uma ordem de
parâmetros. O vínculo preserva a ordem original e registra a posição de cada capacidade, a partir de 1;
a posição 0 é da entrada/evento. Os parâmetros precisam ser nomeados e seguir a ordem declarada de `uses`.
Desestruturação, argumentos variáveis e assinaturas incompatíveis são recusados neste subconjunto.

Queries e handlers que declaram um repositório recebem referência ao repositório de leitura: o parâmetro
`posts` de `blog.find_post` é associado a `blog.posts_read`. A resolução é compartilhada entre compilador
e vinculador, para manter o conjunto da IR e a ordem dos argumentos consistentes.

`graph.bindings` e `binding_for` retornam somente metadados congelados: operação, referência, origem,
parâmetros e capacidades para Ruby; nome e `executor: "pending"` para primitivas. `graph.document`,
`graph.warnings` e `graph.builtin_bindings` também são visões de dados. Não há API de execução nem getter
de `Proc` na unidade vinculada. Os registros/vinculadores internos não são APIs de execução da aplicação.

Blocos só são aceitos quando sua origem pertence à declaração exata de comando, query ou handler.
Trocar dois `call` no mesmo arquivo não é suficiente para passar: o vínculo verifica o escopo lexical,
além de caminho e hash. A referência é uma chave exata do registro; não é avaliada nem convertida em
constante/método a partir do conteúdo da IR.

## Limites

O carregador avalia **código confiável do pacote**, não apenas JSON. O construtor do DSL continua sem ser
um sandbox: inicializadores Ruby arbitrários podem realizar I/O e não são revertidos se a vinculação
falhar. As validações iniciais impedem carregar declarações quando o artefato ou os fontes já divergem;
não transformam código comprometido no mesmo processo em código seguro.

Usar pacote imutável e dependências correspondentes ao lockfile. Os hashes não autenticam a origem dos
pacotes nem congelam o sistema de arquivos após o retorno. A verificação final detecta divergências
persistentes durante o carregamento; não substitui os controles do pipeline/deploy.

Só os dados da IR e dos descritores são compartilháveis entre Ractors. Congelar um `Proc` não congela
os objetos capturados pela closure; a unidade que mantém implementações não deve ser tratada como IR
serializável ou compartilhável. `call` permanece reservado ao futuro motor de operações.

`test/ractor_test.rb` passa o `Result` compilado dos quatro exemplos a Ractors e confirma a mesma identidade
no retorno, recalcula o digest no receptor e tenta alterar listas, strings e objetos aninhados. Também
compartilha os leitores de dados da unidade vinculada (`document`, `bindings`, `warnings`, `implementation_ids`
e `builtin_bindings`), sem transportar as closures privadas. Os objetos já são compartilháveis ao sair do
compilador; os testes não usam `make_shareable` para corrigi-los antes da passagem.

Um processo separado remove a constante `Ractor` antes de carregar o Vetra e executa build, check,
validação com fontes, link e diff nos quatro exemplos. Isso verifica a independência do núcleo da API
pública opcional, sem prometer um Ruby compilado sem o mecanismo interno de Ractors ou um executor de
operações concorrentes. O critério 11 do ADR-001 cobre os dados do compilador, e está registrado como
coberto na [matriz da fase 0](fase-0-criterios.md).

As primitivas CRUD são **reconhecidas**, mas não têm executor neste incremento. Um vínculo bem-sucedido
não torna a aplicação pronta para servir tráfego. Autorização, transações, RLS, efeitos e despacho das
oito etapas do ADR-016 ainda precisam ser implementados e testados antes de executar comandos.

Uma nova vinculação cria outra unidade. Se falhar, nenhuma unidade parcial é retornada; unidades
anteriores não são alteradas. Isso não implementa recarga automática de módulos Ruby, nem troca de
versões com tráfego em andamento; o servidor deverá definir seu próprio ciclo de publicação.

## Verificação

A suíte cobre ordem de parâmetros, leitura restrita, comandos e handlers, origens trocadas inclusive no
mesmo arquivo, referências faltantes/extras/duplicadas, callbacks sem origem Ruby, registro não selado,
IR adulterada, versões divergentes, fontes alterados antes/durante o carregamento, corrupção/ausência
de cache e restauração do contexto do DSL após falha. Os exemplos compiláveis são vinculados também na CI.

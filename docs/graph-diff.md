# Diff arquitetural da IR

`graph:diff` compara dois grafos do [ADR-001](adr/001-grafo-da-aplicacao-e-ir.md). O comando valida versão,
recursos suportados, schema, invariantes implementados e digest dos dois documentos antes de emitir um
relatório. JSON inválido, referência quebrada, formato futuro ou recurso desconhecido impede a comparação.

## Executar

Na raiz do repositório, comparar o grafo versionado do blog com seu arquivo atual:

```sh
bundle exec bin/vetra graph:diff git:HEAD examples/blog/.vetra/graph.json --root examples/blog
```

Cada entrada pode ser um arquivo JSON ou `git:REF`. Para revisões Git, `--root` indica a aplicação;
o comando lê `.vetra/graph.json` dessa aplicação na revisão. Branches, tags e hashes de commit são aceitos.
A revisão precisa conter o artefato nesse caminho; não há fallback para outra aplicação ou revisão.
Referências Git são resolvidas sem shell, sem checkout e sem alterar arquivos, índice ou branch.

Para acompanhar uma alteração local, guardar o grafo anterior antes de editar o DSL:

```sh
cp examples/blog/.vetra/graph.json /tmp/blog-before.json
# Editar as declarações Ruby e então reconstruir:
bundle exec bin/vetra graph:build --root examples/blog
bundle exec bin/vetra graph:diff /tmp/blog-before.json examples/blog/.vetra/graph.json
```

O comando não reavalia o DSL nem executa `call`, lê banco ou verifica os fontes históricos. A validação é
sobre os dados da IR. `graph:check` continua necessário para conferir que o grafo atual corresponde ao
código; `graph:validate --sources` verifica o manifesto do arquivo atual contra os fontes disponíveis.
`--sources` não é uma opção de `graph:diff`.

## Classificação

| Impacto | Interpretação |
|---|---|
| `breaking` | Quebra potencial de contrato/identidade ou restrição incompatível; classificação conservadora |
| `review` | Mudança cujo efeito precisa ser revisado; não foi demonstrada compatibilidade |
| `additive` | Adição ou ampliação estrutural conhecida; não equivale a aprovação de segurança |
| `metadata` | Origem, manifesto, produtor, anotações ou histórico de identidade; separado do modelo |

Campos são comparados pelo nome; nós, por `(kind, id)`. `previous_ids` e `previous_names` **no documento
posterior** permitem reconhecer renomeações. Sem eles, uma remoção e uma adição permanecem distintas.
Se um rename corresponder a mais de uma identidade anterior, a comparação falha: fusão não é renomeação.
Não há inferência por semelhança nem geração/aplicação de DDL.

Referências tipadas são ajustadas pela correspondência explícita dos nós, evitando relatar apenas a troca
do ID referenciado como mudança de comportamento. Seletores de campos e APIs que mudaram de nome continuam
visíveis. Uma entidade renomeada não renomeia implicitamente todos os seus artefatos: os IDs dos comandos,
contratos e rotas gerados também podem mudar e afetar consumidores.

O diff ignora a ordem de nós, campos, entradas do manifesto e conjuntos declarados, como capacidades e
ações. Preserva a ordem de enums, componentes de índices/FKs, caminhos e literais. Não tenta provar
equivalência entre árvores de predicados diferentes; até uma reordenação dos termos pode exigir revisão.

Contratos consideram seus consumidores nos dois grafos:

- Na **entrada**, adicionar campo obrigatório, remover campo aceito, restringir nulabilidade/valores ou
  apertar limites de tamanho pode quebrar clientes. Uma chave opcional nova é aditiva.
- Na **saída**, perder campo/garantia de presença ou ampliar nulabilidade/valores de enum pode quebrar
  consumidores. Um campo de saída novo é aditivo.
- Em **payloads de eventos persistidos**, novos campos obrigatórios e mudanças de tipo, nulabilidade ou
  obrigatoriedade exigem tratamento de compatibilidade com o histórico. A versão do evento não dispensa revisão.
- Se um contrato servir a entrada e saída, vale a direção mais restritiva. Se não houver consumidor
  conhecido, o impacto fica em revisão quando não houver uma quebra estrutural evidente.

Papéis, políticas, autorização, isolamento e superfícies recebem destaque; seu
`permission_impact` é `indeterminate`. O relatório mostra antes/depois, sem afirmar que uma alteração
isolada comprovou ganho ou perda efetiva de acesso. A lista `calls` de um handler também é permissão: ela
define quais comandos o handler pode executar (ADR-014, §8), então acrescentar ou remover um comando dela, ou
declarar um handler com `calls`, aparece como `permissions`. Privacidade, capacidades e transições também são
marcadas para revisão. Índices, armazenamento e restrições merecem revisão de migração própria.

Mudar somente o hash de um arquivo é mudança de build, não prova de equivalência de implementação:
o diff não distingue comentário, helper alterado ou lógica Ruby diferente apenas pelo digest. Essas
mudanças aparecem em metadados e a saída textual explicita esse limite quando fontes/build mudam.
Mudanças do descritor de implementação/análise aparecem no modelo. Nenhum resultado atesta autenticidade
do pacote, pureza do Ruby ou prontidão para produção.

## JSON e automação

```sh
bundle exec bin/vetra graph:diff git:HEAD examples/blog/.vetra/graph.json \
  --root examples/blog --format json --fail-on-breaking
```

`--format json` escreve somente o relatório em stdout, em JSON canônico seguido de LF. Avisos de validação
ficam em stderr e também em `warnings`, com o lado (`before`/`after`), origem e caminho da validação.
Falhas escrevem diagnóstico em stderr e não produzem relatório parcial em stdout.

O relatório tem `format_version: "1"`, independente da versão da IR:

| Campo | Conteúdo |
|---|---|
| `before`, `after` | Aplicação, versão da IR e digest de cada documento |
| `summary` | Total e contagens por impacto; `requires_review` conta sinalizações de revisão, incluindo quebras |
| `changes` | Alterações ordenadas, com identidade, caminho semântico, categoria, impacto, motivo e antes/depois |
| `warnings` | Avisos de validação dos dois lados; não são alterações de modelo |

Cada alteração informa `change` (`added`, `removed`, `modified`, `renamed`), `kind`, `id`, `path`,
`categories`, `impact`, `description`, `before`, `after`, `before_present`, `after_present` e
`requires_review`. `permission_impact`, quando presente, é `indeterminate` neste incremento.
O `kind` sintético `application` identifica mudanças do envelope/configuração.

Os caminhos de alterações são semânticos: `/fields/title/type` seleciona o campo pelo nome, não por posição
no array da IR. Ausência e literal `null` são diferentes; os indicadores de presença removem a ambiguidade.
Os snapshots JSON preservam os dados comparados, com conjuntos normalizados e referências anteriores
ajustadas às renomeações explícitas. O digest original de cada documento permanece no cabeçalho.

Automação deve reconhecer a versão do relatório e os impactos consumidos. Uma mudança incompatível no
significado/formato do relatório exige nova `format_version`; um relatório desconhecido não deve ser
interpretado como autorização para prosseguir.

| Código de saída | Significado |
|---|---|
| 0 | Relatório produzido, inclusive quando houver diferenças |
| 1 | Erro de entrada, Git, integridade ou validação |
| 2 | Uso incorreto da CLI |
| 3 | Relatório produzido e quebra potencial encontrada com `--fail-on-breaking` |

`--fail-on-breaking` reage somente ao impacto `breaking`; não aprova mudanças de permissão ou outros itens
em revisão. Relatórios com mudanças apenas de metadados também não garantem equivalência do código.

# Fase 0: protótipo do compilador

O protótipo implementa o caminho **DSL Ruby → registro congelado → IR 0.1 → validação** e o diff arquitetural
do [ADR-001](adr/001-grafo-da-aplicacao-e-ir.md). É experimental. Os ADRs continuam propostos e a fase 0
ainda não cumpriu todos os critérios de aceitação.

## Executar

Usar Ruby 4.0.9, fixado em `.ruby-version`, e Bundler. Na raiz do repositório:

```sh
bundle install
bundle exec rake test
bundle exec bin/vetra graph:build --root examples/blog
bundle exec bin/vetra graph:check --root examples/blog
bundle exec bin/vetra graph:validate --root examples/blog --sources
bundle exec bin/vetra graph:build --root examples/mini_crm
bundle exec bin/vetra graph:check --root examples/mini_crm
bundle exec bin/vetra graph:validate --root examples/mini_crm --sources
bundle exec bin/vetra graph:diff git:HEAD examples/blog/.vetra/graph.json --root examples/blog
```

Os dois diretórios em `examples/` contêm declarações Ruby reais, lockfiles e `.vetra/graph.json` gerado
e versionado. São recortes sem autenticação, UI ou persistência: o blog demonstra escopo do autor e
publicação; o CRM demonstra tenant, dinheiro, transição e um handler declarado. Revendas e usuários
persistidos do PDF ficam para incrementos posteriores.

| Comando | Comportamento |
|---|---|
| `graph:build --root APP` | Reconstrói e valida tudo; grava `.vetra/graph.json` por substituição atômica |
| `graph:check --root APP` | Reconstrói e compara bytes, sem editar o artefato; divergência ou ausência falha |
| `graph:validate ARQUIVO` | Valida versão, recursos, schema, invariantes implementados e digest, sem avaliar o DSL |
| `graph:validate --root APP --sources` | Também confere arquivos e hashes; usa o grafo padrão quando não recebe arquivo |
| `graph:diff ANTERIOR POSTERIOR` | Compara arquivos/revisões Git validados; aceita texto ou JSON e sinaliza quebras potenciais |

Saída 0 significa sucesso, 1 indica erro de compilação/validação/arquivo e 2 indica uso incorreto da CLI.
Avisos vão para stderr e não mudam o código de sucesso. `graph:validate` sem `--sources` também aceita as
[fixtures documentais](ir/README.md), cujos hashes de arquivos são placeholders.
No diff, `--fail-on-breaking` adiciona a saída 3 quando houver quebra potencial; o
[guia de comparação](graph-diff.md) explica categorias, renomeações, limites e formato JSON.

## DSL implementado

- `Vetra.app`, com `tenant`, `currency` e `locale`.
- `domain` e `depends_on`; ausência de fronteira explícita gera aviso.
- `entity`, campos primitivos, `enum`, `money`, `decimal`, `slug`, defaults, privacidade, índices e
  `belongs_to`, incluindo chaves compostas para `same_tenant`.
- `crud`: gera criação, leitura por ID, atualização e exclusão como nós de comandos/consulta, contratos,
  repositórios e rotas HTTP. Ainda não existe execução dessas primitivas.
- `roles`, `role`, `visitor`, `authenticated` e `can`; `manage` expande para as quatro ações CRUD.
  `where` aceita igualdade literal, `:current_actor` e relações declaradas. `scope` suporta
  `author`, `owner` e `seller` comparados com `actor.id`; o escopo por vínculos de revenda não está implementado.
- `command` e `query`, com `input`, `returns :entidade`, `authorize`, `uses`, `call`, `unsafe_effect` e
  `expose http:`. `returns` é explícito porque não se infere retorno de Ruby arbitrário.
- `event`, com projeção de campos, visibilidade e exigência de consumidor; `emits` pode inferir o evento
  interno e seu payload quando ele não foi declarado separadamente.
- `handler`, com `on`, `uses`, `calls`, `idempotent_by :event_id` e `call`; `effect` registra capacidades
  externas. `clock`, `uuid` e `random` geram metadados de capacidades determinísticas quando usados.

Cada `call` recebe a entrada/evento seguido dos parâmetros das capacidades na ordem de `uses`, com os
nomes declarados. Os parâmetros são conferidos e o bloco é registrado separadamente da IR; **nenhum
`call` é executado**. IDs e referências da IR são qualificados pelo domínio. O normalizador pode reordenar
o conjunto `uses` na IR, mas a vinculação original dos parâmetros fica com o bloco no registro do build.

Declarações/opções não implementadas falham; não viram anotações nem desaparecem. Entre elas estão UI,
MCP, workflows, consultas live, relações muitos-para-muitos no DSL, metadados de dependências por gem,
SQL explícito e políticas baseadas em atributos materializados do ator além de `id`. O schema 0.1 possui
algumas dessas representações; conhecer sua forma não significa que este consumidor saiba compilá-las.

O construtor não é um sandbox. As declarações são código de desenvolvimento confiável e devem ser
determinísticas; chamadas explícitas a constantes Ruby podem escapar da API. A análise Prism do corpo de
`call` cobre efeitos diretos conhecidos, construções dinâmicas conhecidas e gravações literais pelas
capacidades nomeadas. Não resolve fluxo de dados, aliases, helpers arbitrários, gems ou todos os efeitos
transitivos. `analysis.status: complete` só significa que esse analisador limitado não encontrou uma
construção dinâmica conhecida. Não constitui prova de pureza ou segurança.

## Integridade e limites

O manifesto inclui `app/`, `lib/`, configuração não secreta em `config/`, `Gemfile`, `Gemfile.lock` e
`.ruby-version`. Segredos convencionais (`secrets`, `credentials`, `.env`, `.enc`, `.key`, `.pem`) ficam
fora. Links de arquivo não podem escapar da raiz; diretórios simbólicos são recusados neste incremento.
Nomes secretos fora dessas convenções não são identificáveis automaticamente: não colocar segredos nas
declarações. Hashes cobrem bytes dos arquivos; seus conteúdos não são embutidos no grafo.

A IR usa JCS restrito aos tipos do ADR: strings Unicode preservadas, chaves ordenadas por UTF-16 e
inteiros seguros; números de ponto flutuante são recusados. O digest exclui apenas `digest` na raiz.
Normalização mantém arrays posicionais e a ordem dos enums. O schema local é verificado por
[json_schemer](https://github.com/davishmcclurg/json_schemer), sem resolver referências pela rede.

O compilador verifica referências, namespaces, fronteiras/ciclos entre domínios, origens e hashes de
implementação, campos/defaults, donos de transição, dependências declarativas de políticas, capacidades,
payloads, consumidores obrigatórios, rotas e renomeações explícitas. Não aplica políticas SQL, não instala
triggers e não chama serviços. `transitions enforce: :db` é apenas metadado até existir o gerador SQL.
Nem toda relação semântica possível no schema tem uma implementação; recursos fora do subconjunto
suportado devem ser recusados, não tratados como seguros.

O arquivo versionado sempre é recompilado nos comandos de build/check. `.vetra/cache/` é ignorado; o
cache de compilação e o carregamento de produção ainda não existem. `graph:validate --sources` verifica
integridade, mas não substitui um boot com vinculação de implementações ou autenticação do pacote.

## Cobertura e continuação

Os testes exercitam os exemplos com/sem tenant, reprodução entre checkouts, Unicode/JCS, JSON com chaves
repetidas, imutabilidade/compartilhamento da IR, alterações e remoções de fontes, contratos CRUD,
defaults/valores protegidos, efeitos diretos, limites de capacidades, permissões, eventos e erros da CLI.
O diff cobre direção de contratos, renomeações, ordem posicional, metadados, impacto indeterminado de
permissões e leitura de revisões/tags em repositórios temporários, sem executar o DSL ou alterar o checkout.
A [CI](../.github/workflows/ci.yml) executa os testes e confere os grafos dos exemplos no Ruby fixado.

Os próximos incrementos da fase 0 são a vinculação completa de implementações no carregamento validado e
a ampliação do subconjunto declarativo. A suíte deverá acompanhar cada expansão.
Depois, o motor de comandos e o Vetra Data precisam de seus ADRs, PostgreSQL real e testes transacionais;
as garantias de RLS, entrega de eventos e live continuam pendentes dessas implementações.

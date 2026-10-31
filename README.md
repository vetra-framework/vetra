<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="logo/vetra-logo-dark.svg">
    <img src="logo/vetra-logo.svg" alt="Vetra" width="360">
  </picture>
</p>

<p align="center">
  Framework web em Ruby 4, exclusivo para PostgreSQL, que trata a aplicação como um modelo verificável.
</p>

> **Status: protótipo da fase 0.** Há um compilador experimental do DSL Ruby para a IR 0.1, validação e
> testes. O runtime web, a persistência e os demais componentes continuam em design; os PDFs incluem
> sintaxe futura que o protótipo ainda não suporta. Não há medições de produção.

## A ideia

O Vetra trata a aplicação como um grafo verificável (o **Grafo da Aplicação**), em vez de um conjunto de
classes ligadas por metaprogramação em runtime. A aposta não é ser um Rails mais organizado, e sim tornar
trivial o que hoje é caro nele:

- telas em tempo real sem código de broadcast (consultas reativas);
- processos de negócio que duram dias (workflows duráveis);
- isolamento multiempresa com RLS, verificado por testes adversariais;
- ferramentas de conformidade com a LGPD;
- operações que agentes de IA executam com identidade delegada e permissões limitadas.

A adoção começa dentro de aplicações Rails existentes, um domínio por vez. O Vetra só se torna independente
depois de provar vantagem medida em um módulo comercial real.

## Fundação

Quatro componentes, validados antes de qualquer outro:

1. **Application Graph**: a aplicação compilada em uma representação intermediária versionada.
2. **Motor de comandos**: uma operação, várias superfícies (HTTP, CLI, job, webhook).
3. **Motor de autorização**: papéis e políticas declarativas com escopo.
4. **Vetra Data**: Sequel sobre PostgreSQL, com RLS e contexto assinado.

Consultas reativas são o principal diferencial e entram assim que essa base estiver correta. Ruby::Box,
Ractors, workflows duráveis e MCP são extensões opcionais: o núcleo funciona integralmente sem elas.

## Documentação

| Documento | Conteúdo |
|---|---|
| [Protótipo da fase 0](docs/fase-0.md) | Como executar, DSL implementado, testes e limites atuais |
| [Diff arquitetural](docs/graph-diff.md) | Comparação de grafos/versões Git, contratos, permissões e relatório JSON |
| [Vinculação de implementações](docs/graph-link.md) | Carregamento validado, parâmetros/capacidades e limites do registro Ruby |
| [Proposta técnica](docs/proposta-tecnica.pdf) | Tese, os nove pilares, arquitetura, ADRs, roadmap, riscos e métricas |
| [Exemplo 1: Mini CRM](docs/exemplos/01-mini-crm.pdf) | Multiempresa com RLS, comando e evento, comparado ao Rails 8.1 |
| [Exemplo 2: Blog](docs/exemplos/02-blog.pdf) | O caso simples, sem multiempresa, com UI no servidor |
| [Exemplo 3: Chat](docs/exemplos/03-chat.pdf) | Consultas reativas e revogação de acesso em tempo real |
| [Revisões](docs/revisoes.pdf) | Histórico das rodadas de revisão e erros reconhecidos |
| [Pendências (rodada 7)](docs/pendencias-rodada-7.pdf) | Decisões em aberto, pontos que dependem de medição e próximo passo |

As decisões detalhadas estão no [índice de ADRs](docs/adr/README.md): dez aceitas (001, 002, 003, 004, 005, 006, 008,
015, 016 e 020) e as demais ainda propostas. O
[ADR-016](docs/adr/016-ciclo-de-vida-da-operacao.md) define o ciclo de vida comum às operações; o
[ADR-001](docs/adr/001-grafo-da-aplicacao-e-ir.md) define o grafo e a compatibilidade da
[IR 0.1, com schema e exemplos](docs/ir/README.md), antes do protótipo da fase 0. Os PDFs preservam o
histórico da proposta; os ADRs desenvolvem as decisões posteriores.

## Executar o protótipo

Com Ruby 4.0.9 e Bundler, na raiz do repositório:

```sh
bundle install
bundle exec rake test
bundle exec bin/vetra graph:build --root examples/blog
bundle exec bin/vetra graph:check --root examples/blog
bundle exec bin/vetra graph:validate --root examples/blog --sources
bundle exec bin/vetra graph:diff git:HEAD examples/blog/.vetra/graph.json --root examples/blog
bundle exec bin/vetra graph:link --root examples/blog
```

Há também um exemplo multiempresa em `examples/mini_crm` e outros com revendas e papéis por vínculo
(`examples/mini_crm_revendas`) e com salas e membros muitos-para-muitos (`examples/chat`). Os comandos geram, verificam e vinculam o grafo;
as operações de negócio ainda não são executadas. As primitivas CRUD continuam sem executor.
Veja o [escopo atual](docs/fase-0.md).

## Estrutura do repositório

```
.
├── bin/vetra              # CLI do compilador
├── lib/vetra/             # DSL, normalização e validação
├── test/                  # testes do compilador e da CLI
├── script/                # sondas dos ADRs, fora da suíte (script/sonda_adr003.rb)
├── examples/              # blog, mini CRM, mini CRM com revendas e chat compiláveis
├── docs/
│   ├── proposta-tecnica.pdf
│   ├── revisoes.pdf
│   ├── pendencias-rodada-7.pdf
│   ├── exemplos/          # mini CRM, blog e chat
│   ├── adr/               # registro de decisões arquiteturais
│   └── ir/                # schema versionado e exemplos da representação intermediária
├── logo/                  # SVG, PNG e favicon
└── LICENSE
```

## Licença

[MIT](LICENSE). A governança do projeto ainda está em aberto (veja as questões em aberto na proposta).

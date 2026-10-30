<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="logo/vetra-logo-dark.svg">
    <img src="logo/vetra-logo.svg" alt="Vetra" width="360">
  </picture>
</p>

<p align="center">
  Framework web em Ruby 4, exclusivo para PostgreSQL, que trata a aplicação como um modelo verificável.
</p>

> **Status: em design.** Este repositório contém a proposta técnica e os exemplos de sintaxe.
> Nada foi implementado nem medido ainda; a sintaxe mostrada nos documentos é proposta e não existe.

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
| [Proposta técnica](docs/proposta-tecnica.pdf) | Tese, os nove pilares, arquitetura, ADRs, roadmap, riscos e métricas |
| [Exemplo 1: Mini CRM](docs/exemplos/01-mini-crm.pdf) | Multiempresa com RLS, comando e evento, comparado ao Rails 8.1 |
| [Exemplo 2: Blog](docs/exemplos/02-blog.pdf) | O caso simples, sem multiempresa, com UI no servidor |
| [Exemplo 3: Chat](docs/exemplos/03-chat.pdf) | Consultas reativas e revogação de acesso em tempo real |
| [Revisões](docs/revisoes.pdf) | Histórico das rodadas de revisão e erros reconhecidos |
| [Pendências (rodada 7)](docs/pendencias-rodada-7.pdf) | Decisões em aberto, pontos que dependem de medição e próximo passo |

As decisões detalhadas estão no [índice de ADRs](docs/adr/README.md), ainda com status proposto. O
[ADR-016](docs/adr/016-ciclo-de-vida-da-operacao.md) define o ciclo de vida comum às operações; o
[ADR-001](docs/adr/001-grafo-da-aplicacao-e-ir.md) define o grafo e a compatibilidade da
[IR 0.1, com schema e exemplos](docs/ir/README.md), antes do protótipo da fase 0. Os PDFs preservam o
histórico da proposta; os ADRs desenvolvem as decisões posteriores.

## Estrutura do repositório

```
.
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

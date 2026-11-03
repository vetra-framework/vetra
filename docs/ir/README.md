# Representação intermediária do Grafo da Aplicação

Contrato definido pelo [ADR-001](../adr/001-grafo-da-aplicacao-e-ir.md), aceito. Estes arquivos especificam
dados. O [protótipo da fase 0](../fase-0.md) já compila um subconjunto do DSL e implementa
`graph:build`, `graph:check` e `graph:validate`; o runtime continua pendente.

| Arquivo | Conteúdo |
|---|---|
| [v0.1.schema.json](v0.1.schema.json) | JSON Schema Draft 2020-12, fechado e autocontido, com 12 tipos de nó |
| [v0.2.schema.json](v0.2.schema.json) | Geração de `created_at` e requisito `vetra.timestamps`; leitura preservada |
| [v0.3.schema.json](v0.3.schema.json) | Coleções, contratos compostos de consultas e live; leitura preservada |
| [v0.4.schema.json](v0.4.schema.json) | Comandos de vínculo e requisito `vetra.relation_commands`; leitura preservada |
| [v0.5.schema.json](v0.5.schema.json) | `app.rounding` opcional e requisito `vetra.money_rounding` quando presente; leitura preservada |
| [v0.6.schema.json](v0.6.schema.json) | Build atual, com `policy.rate_limit` opcional e requisito `vetra.rate_limit` quando presente; fechado e autocontido |
| [mini-crm.v0.1.json](exemplos/mini-crm.v0.1.json) | Tenant, dinheiro, privacidade, transição, evento interno e handler com capacidade externa |
| [blog.v0.1.json](exemplos/blog.v0.1.json) | Sem tenant, escopo do autor, relógio, `set_by`, `guarded` e evento público sem consumidor |

Os exemplos têm envelope completo e referências resolvíveis, mas são **recortes didáticos**, não a
compilação dos PDFs: omitem CRUD completo, revendas, autenticação, UI e demais entidades. O CRM usa um
papel com acesso dentro do tenant; o escopo por revenda do exemplo da proposta não está reproduzido aqui, mas
`examples/mini_crm_revendas/.vetra/graph.json` o compila hoje na IR 0.6, preservando a representação do escopo
da 0.1 (veja o [escopo por vínculo](../fase-0.md#escopo-por-vínculo)). O significado de `through`, `local_fields`, `target_fields` e `include_on_create` em relações
muitos-para-muitos, que o schema não define, está em [muitos-para-muitos](../fase-0.md#relações-muitos-para-muitos).
O blog demonstra publicação com um evento explícito adicional. Não há fontes Ruby executáveis anexas.

Os digests de arquivos em `inputs` e `implementation` são placeholders de 64 zeros; `source.line: 1` e
as versões de produtor/dependências são ilustrativos. **O digest do documento é real**: SHA-256 sobre
JCS do envelope sem `digest`. Os arquivos usam indentação para leitura; o futuro `.vetra/graph.json`
versionado usará JCS seguido de LF. Não usar estas fixtures como pacote de produção.

## Forma, semântica e execução

O schema verifica a forma: propriedades obrigatórias, tipos, referências tipadas, alternativas de nós e
campos desconhecidos. As regras semânticas do ADR são outra etapa: ID único, referências existentes,
namespace, tenant, classificação de capacidades, compatibilidade de defaults/payloads, dependências de
autorização e vínculo aos fontes. Um documento que passa no schema ainda pode falhar nessas regras.

`requires` é uma lista de requisitos semânticos, não de plugins a carregar. As fixtures documentais exigem apenas
`vetra.core`; os builds atuais exigem também `vetra.timestamps` e, quando necessário, `vetra.structured_outputs`.
Uma consulta com `live` exige `vetra.live`: desde a IR 0.3, o consumidor compila e valida o modo e as dependências de dados
e autorização, conforme o [ADR-029](../adr/029-declaracoes-live-e-dependencias.md). Os consumidores 0.1 e 0.2
continuam recusando esse recurso. A execução das assinaturas e a entrega em tempo real permanecem pendentes.
Comandos gerados de vínculo exigem `vetra.relation_commands`, disponível desde a IR 0.4. Usam o descritor
`builtin` existente com nome `many_to_many.add.<relação>` ou `many_to_many.remove.<relação>`. O dono vem de
`authorize.entity`; a relação resolve alvo, junção, chaves e vínculos protegidos por `include_on_create`.
O [ADR-032](../adr/032-comandos-gerados-de-vinculo.md) define contratos, recusas e coexistência com
comandos explícitos, sem executor e sem mudança estrutural nos nós. A evolução semântica exige nova MENOR e
requisito, conforme o [ADR-001 §4](../adr/001-grafo-da-aplicacao-e-ir.md#4-compatibilidade-e-evolução).
Os schemas publicados 0.1 a 0.4 permanecem inalterados. Um documento 0.3 com o requisito ou com a
primitiva de vínculo é recusado. O link preserva artefatos anteriores sem geração retroativa.

Desde a IR 0.5, `app.rounding` aceita `half_up` ou `half_even`. O campo é opcional: omissão significa
`half_up`, preservando o significado dos grafos anteriores. Se presente, exige `vetra.money_rounding`;
o requisito sem campo também conserva o padrão. Desde a IR 0.5, o build emite ambos somente quando a aplicação
declara `rounding:`, inclusive `half_up` e mesmo sem campos `money`. Sem a declaração, campo e requisito
ficam ausentes. O modo governa somente conversão e divisão que excedam a escala de destino; soma, subtração e
literais não são arredondados. O [ADR-033](../adr/033-arredondamento-monetario-e-ir-0-5.md)
define o contrato, sem executor. Documentos 0.1 a 0.4 com campo ou requisito novos são recusados.
O diff compara o modo efetivo e classifica sua troca como quebra potencial de valores com revisão.

Desde a IR 0.6, uma política pode declarar
`rate_limit: { "limit": 5, "window_seconds": 60, "key": "actor_tenant" }`, exigindo
`vetra.rate_limit`. Os números são inteiros positivos seguros da IR; a chave é fechada e não há campos
extras. O build emite o requisito somente quando há política limitada. O limite é por política,
ator e tenant, compartilhado entre ações e superfícies, sem alterar os predicados ou conceder acesso.
Ele qualifica a concessão declarada: se alguma política aplicável autoriza a operação sem limite,
a admissão não verifica nem consome cotas dessas políticas. Quando todas as que autorizam têm limite,
todas precisam permitir a admissão, que conta em todas; alternar entre elas não multiplica cotas.
O [ADR-034](../adr/034-limite-de-taxa-por-permissao-e-ir-0-6.md) define janela móvel e a
identidade anônima confiável necessária ao visitante do blog. IR externa sem requisito é recusada;
0.1 a 0.5 recusam campo e requisito. Afrouxar ou remover é quebra potencial de segurança; apertar exige
revisão. Contadores e execução continuam pendentes.

Páginas, workflows e MCP não estão no formato 0.1; sua inclusão exige evolução explícita.
`annotations` aceita metadados com chaves qualificadas e nunca pode alterar execução ou segurança.

Desde a IR 0.2, `generate` também aceita `{ "kind": "timestamp", "on": "create" }`. Essa regra exige
`vetra.timestamps`, só vale no `created_at` obrigatório e não nulo de entidade, e não pode ser combinada com
outras regras de atribuição. O requisito exige esse campo em todas as entidades. Contratos de registro e
payloads carregam o valor, sem copiar a geração; entradas CRUD não podem permitir sua escrita. O
[ADR-027](../adr/027-created-at-implicito-e-ir-0-2.md) registra o contrato e seus limites.


Desde 0.3, um contrato raiz pode ter `collection: true`: `fields` descreve cada objeto da lista, e não
um envelope contendo a lista. Um campo de objeto pode usar `type: { name: "record" | "collection",
contract: { kind: "contract", id: "dominio.entidade.record" } }`. Isso exige `vetra.structured_outputs`.
A referência aponta a um contrato de objeto; ciclos e listas de listas são recusados. Esses formatos são
permitidos apenas nas saídas de consultas, inclusive seus contratos referenciados; entradas, entidades,
comandos e eventos mantêm o formato plano. A classificação pessoal de um campo composto não pode rebaixar
a do contrato referenciado. O [ADR-028](../adr/028-contratos-compostos-e-colecoes-de-consultas.md) registra
os detalhes, incluindo o diff de mudanças nos campos aninhados.

Build e check usam 0.6. Validação, diff e link aceitam 0.1, 0.2, 0.3, 0.4, 0.5 e 0.6, cada uma com o schema e as regras
exatas. O link audita declarações na versão do artefato sem converter ou regravar o documento. Os schemas
0.1/0.2/0.3/0.4/0.5 e as fixtures documentais abaixo permanecem inalterados. Todos os schemas são distribuídos
localmente na gem pelo glob `docs/ir/v*.schema.json`. A atualização exige um build e revisão explícitos;
a mudança de `ir_version` aparece no diff como revisão, sem quebra.

Consumidores executáveis aceitam somente versões e recursos explicitamente suportados, validando com o
schema exato distribuído localmente. Uma MENOR futura não é ignorada. As mesmas regras valem antes de
1.0; detalhes e matriz de compatibilidade estão no ADR-001.

## Verificação documental

O validador Ruby confere estas fixtures sem tentar ler seus fontes ilustrativos:

```sh
bundle exec bin/vetra graph:validate docs/ir/exemplos/blog.v0.1.json
bundle exec bin/vetra graph:validate docs/ir/exemplos/mini-crm.v0.1.json
```

Com Python e os pacotes `jsonschema` e `rfc8785` disponíveis como ferramentas de documentação, executar
na raiz do repositório:

```sh
python3 - <<'PY'
import hashlib
import json
from pathlib import Path
import rfc8785
from jsonschema import Draft202012Validator

root = Path("docs/ir")
schema = json.loads((root / "v0.1.schema.json").read_text())
Draft202012Validator.check_schema(schema)
validator = Draft202012Validator(schema)
for path in sorted((root / "exemplos").glob("*.json")):
    document = json.loads(path.read_text())
    validator.validate(document)
    expected = document.pop("digest")
    actual = "sha256:" + hashlib.sha256(rfc8785.dumps(document)).hexdigest()
    assert actual == expected, f"Digest divergente: {path}"
    print(f"{path}: schema e digest válidos")
PY
```

Isso valida o schema e os digests documentais; não verifica arquivos de origem inexistentes nem executa
a validação semântica do futuro compilador. Python não é uma dependência do framework Ruby.

A suíte Ruby cobre recusa de versões futuras, propriedades desconhecidas, referências quebradas, defaults
protegidos e fonte alterada, entre outros casos. Isso ainda é cobertura parcial dos critérios do ADR;
o [escopo da fase 0](../fase-0.md) registra as limitações. As garantias de RLS, transação e live continuam
dependendo das implementações e dos testes de seus ADRs.

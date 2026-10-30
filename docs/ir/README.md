# Representação intermediária do Grafo da Aplicação

Contrato **proposto** pelo [ADR-001](../adr/001-grafo-da-aplicacao-e-ir.md), anterior à fase 0. Estes
arquivos especificam dados; o compilador, o runtime e os comandos `vetra graph:*` ainda não existem.

| Arquivo | Conteúdo |
|---|---|
| [v0.1.schema.json](v0.1.schema.json) | JSON Schema Draft 2020-12, fechado e autocontido, com 12 tipos de nó |
| [mini-crm.v0.1.json](exemplos/mini-crm.v0.1.json) | Tenant, dinheiro, privacidade, transição, evento interno e handler com capacidade externa |
| [blog.v0.1.json](exemplos/blog.v0.1.json) | Sem tenant, escopo do autor, relógio, `set_by`, `guarded` e evento público sem consumidor |

Os exemplos têm envelope completo e referências resolvíveis, mas são **recortes didáticos**, não a
compilação dos PDFs: omitem CRUD completo, revendas, autenticação, UI e demais entidades. O CRM usa um
papel com acesso dentro do tenant; o escopo por revenda do exemplo da proposta não está reproduzido.
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

`requires` é uma lista de requisitos semânticos, não de plugins a carregar. Os exemplos exigem apenas
`vetra.core`. Uma consulta com `live` também exige `vetra.live`, cuja implementação pertence à fase de
tempo real. Páginas, workflows e MCP não estão no formato 0.1; sua inclusão exige evolução explícita.
`annotations` aceita metadados com chaves qualificadas e nunca pode alterar execução ou segurança.

Consumidores executáveis aceitam somente versões e recursos explicitamente suportados, validando com o
schema exato distribuído localmente. Uma MENOR futura não é ignorada. As mesmas regras valem antes de
1.0; detalhes e matriz de compatibilidade estão no ADR-001.

## Verificação documental

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

A suíte da fase 0 deverá acrescentar os casos de aceitação do ADR, incluindo recusa de versões futuras,
propriedades desconhecidas, referências quebradas, defaults protegidos, fonte alterada e perda de cache.
As garantias de RLS, transação e live continuam dependendo das implementações e dos testes de seus ADRs.

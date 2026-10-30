# ADR-001: Grafo da Aplicação compilado em IR versionada

- Status: proposto
- Data: 2026-10-30
- Relacionados: ADR-004 (capacidades), ADR-005 (RLS), ADR-016 (ciclo de vida), ADR-020 (entrega live) e
  ADR-021 (campos de transição)
- Contrato de dados: [IR 0.1](../ir/v0.1.schema.json), com [exemplos e limites](../ir/README.md)

## Contexto

A proposta depende de um modelo inspecionável para verificar referências, derivar contratos e políticas,
explicar capacidades e comparar mudanças de arquitetura. Objetos Ruby vivos não oferecem um contrato
estável para essas ferramentas. A pendência da rodada 7 exige definir o esquema da representação
intermediária (IR) e sua compatibilidade antes da fase 0.

Os ADRs já escritos precisam representar capacidades, escopos de autorização, dependências de consultas,
eventos e comandos donos de campos de transição. O esquema também precisa distinguir dados declarativos
de código Ruby que a análise estática não consegue provar.

Este ADR especifica o formato inicial e os critérios para implementar o compilador. **Não implementa o
compilador, o runtime nem os comandos `vetra` citados abaixo.**

## Decisão

**O DSL alimenta um registro congelado, normalizado em uma IR JSON versionada. A IR validada é o contrato
de entrada dos compiladores e geradores. Código executável fica separado, vinculado ao mesmo build.**

### 1. Pipeline e fronteira do Ruby

```text
DSL Ruby → registro → normalização → IR → validação estrutural e semântica
                                             ├→ compilação para o runtime
                                             └→ contratos, RLS, tipos, documentação e diff
código Ruby do build ─→ registro de implementações ─→ vinculação ao runtime
```

1. O carregador avalia cada declaração uma vez por build. O construtor registra dados e referências a
   implementações; não executa `call`, não consulta dados da aplicação nem deveria realizar I/O externo.
2. A normalização resolve nomes locais, expande convenções e CRUD, materializa padrões e produz nós
   explícitos, inclusive contratos, políticas, capacidades de repositório e rotas geradas.
3. O registro é congelado; declarações tardias são recusadas. Uma recarga em desenvolvimento produz outro
   registro e outra IR, substituídos junto ao código correspondente, sem alterar parcialmente o grafo ativo.
4. A IR passa pelo JSON Schema e pela validação semântica. Só então alimenta geradores e o runtime.
5. Blocos Ruby são carregados do pacote da aplicação e vinculados por identificador exato num registro
   privado. Referência ausente/ambígua impede o boot. Não há `eval`, desserialização de objetos ou resolução
   de constantes arbitrárias a partir de uma IR recebida.

O construtor é uma API restrita, **não um sandbox**. Ruby arbitrário nas declarações e gems pode realizar
I/O. As garantias estruturais cobrem o modelo declarado; análise e exceções seguem o ADR-004. Geradores
de dados não precisam executar os blocos da aplicação; o runtime precisa deles.

### 2. Esquema inicial: IR 0.1

O arquivo normativo é [v0.1.schema.json](../ir/v0.1.schema.json), em
[JSON Schema Draft 2020-12](https://json-schema.org/draft/2020-12/json-schema-core). O esquema é fechado:
campos e tipos de nó desconhecidos são inválidos. Há exemplos completos em [docs/ir](../ir/README.md).

| Campo obrigatório do envelope | Significado |
|---|---|
| `ir_version` | Versão do formato; inicialmente `"0.1"` |
| `requires` | Recursos semânticos exigidos do consumidor: `vetra.core`; live exige também `vetra.live` |
| `producer` | Nome/versão do compilador e versão do Ruby usados no build |
| `app` | Nome, tenant ou `null`, moeda e idioma padrão; sem credenciais |
| `inputs` | Manifesto de caminhos relativos e SHA-256 dos arquivos de entrada |
| `nodes` | Lista de nós discriminados por `kind` |
| `digest` | SHA-256 do documento canônico, calculado sem o próprio campo |

`requires` não ativa extensões automaticamente. Um consumidor anuncia as versões e os recursos que
implementa. Conhecer o JSON Schema não significa implementar `vetra.live`.

| `kind` | Dados específicos obrigatórios |
|---|---|
| `domain` | `depends_on`: lista fechada de domínios, ou `null` quando não há restrição declarada |
| `entity` | Armazenamento, tenant ou `null`, campos, relações, histórico e proteção de transições |
| `contract` | Campos de entrada/saída normalizados, com tipos e nulabilidade |
| `command` | Contratos, autorização, capacidades, eventos emitidos e implementação |
| `query` | Contratos, autorização, capacidades e implementação; metadados live quando houver |
| `role` | Identidade do papel e se permite ator anônimo |
| `policy` | Papel, entidade, ações, campos permitidos, predicado e entidades lidas pela autorização |
| `capability` | Tipo, adaptador registrado, repetição segura, simulação e alvo/opções aplicáveis |
| `event` | Contrato de payload, versão do evento, visibilidade e exigência de consumidor |
| `handler` | Eventos consumidos, capacidades, comandos que pode chamar, deduplicação e implementação |
| `route` | Superfície, destino, configuração do adaptador e exigência de idempotência |
| `dependency` | Nome/versão da gem e classificação de confiança do ADR-004 |

**Identidade e referências.** A chave é `(kind, id)`. Domínios usam `crm`; os demais nós, nomes qualificados
como `crm.lead`, `crm.win_lead` e `crm.lead.won`, dentro do namespace de seu domínio. Mover um arquivo não
renomeia um nó. Ligações são sempre `{ "kind": "command", "id": "crm.win_lead" }`; arestas e índices reversos
são derivados dessas referências. Seletores locais (nomes de campos e caminhos) são validados no contexto.
Cada nó tem `source.path` relativo à raiz e `source.line` a partir de 1. Nós gerados também apontam
`generated_from` ao nó que os originou, conservando a localização da declaração.

**Renomeação.** `previous_ids` registra identidades anteriores do mesmo `kind`, resolvidas do `was:` do DSL;
campos usam `previous_names`. Não são aliases de runtime. Colisões e ambiguidades são erros. O diff usa
isso para propor renomeação, sem aplicar DDL. Sem essa declaração, uma remoção e uma adição continuam sendo
duas mudanças; não se infere renomeação por semelhança.

**Campos e contratos.** A normalização explicita presença obrigatória (`required`), nulabilidade
(`nullable`) e privacidade: exigir uma chave e aceitar `null` são decisões independentes. Ausência de `default` significa
sem padrão; `{"kind":"literal","value":null}` é um padrão explícito. Decimais exatos são strings; dinheiro
literal é `{ "amount": "1234.56", "currency": "BRL" }`. `Float` é recusado. `set_by` e `guarded[].commands`
usam referências a comandos e alimentam a proteção do ADR-021 e os contratos CRUD. Contratos do CRUD são
inferidos; retornos de Ruby arbitrário não inferíveis exigem contrato declarado.

Grupos de enum, normalizadores conhecidos, derivação de slug e índices declarados também são dados
explícitos. O schema não aceita funções arbitrárias nesses lugares. Relações muitos-para-muitos apontam
à entidade de junção normalizada; `include_on_create` registra vínculos iniciais como o dono da sala.

**Autorização.** Escopos declarativos viram uma árvore de predicados fechados: `eq`, `in`, `and`, `or`,
`not`, `exists`, `true` e `false`. Não se grava SQL ou Ruby como política. Caminhos por relações e
`policy.reads` identificam tabelas que afetam autorização (ADRs 005 e 020). A validação semântica confere
que `reads` cobre o predicado e os vínculos do ator. Um predicado não compilável nunca vira `true`:
usa o caminho seguro previsto no ADR correspondente ou é recusado; o isolamento de tenant continua no banco.

**Implementações.** `implementation` distingue primitivas internas nomeadas de blocos Ruby com `ref`,
caminho, digest do arquivo e análise (`complete`/`incomplete`, constantes e construções não resolvidas).
`unsafe_effect` exige motivo e continua visível. `complete` descreve o analisador, não prova ausência de
efeitos. O DSL `effect` vira capacidade externa; `crud` vira nós explícitos sem que o desenvolvedor os escreva.

**Dados permitidos.** Apenas objetos, listas, strings, booleanos, `null` e inteiros seguros de ±(2^53−1).
Decimais, timestamps e IDs de 64 bits usam strings quando presentes como literais. Não há `Proc`, AST
executável, conexão, credencial, token ou valor de segredo. `annotations`, opcional e com chaves
qualificadas, aceita somente metadados ignoráveis; nenhuma regra de execução ou segurança depende deles.

Páginas, templates ejetados, workflows e MCP terão representação quando seus ADRs/contratos estiverem
definidos; não entram como objetos livres em 0.1. Isso não bloqueia a fase 0. Live já registra modo e
dependências, sem fixar plano de execução ou prometer delta para Ruby arbitrário: sem análise suficiente,
vale a reconsulta conservadora do ADR-020.

Uma declaração sem representação no formato alvo é erro de compilação para esse alvo; nunca é descartada
ou escondida em `annotations`. O formato inicial não promete suportar toda a sintaxe futura dos exemplos.

### 3. Determinismo, manifesto e digest

Mesmas entradas e versões do compilador/Ruby devem produzir o mesmo documento em qualquer checkout.

1. Ordenar `inputs` por `path` e `nodes` por `(kind, id)`, em ordem lexicográfica ASCII. Conjuntos de
   referências são ordenados por `(kind, id)`; `requires`, ações, IDs/nomes anteriores e achados do
   analisador, por texto. Campos, relações e índices são ordenados por `name`; guardas, por `value`; emissões,
   pelo ID do evento. Identidades declaradas duplicadas são erro, não são removidas silenciosamente.
   Arrays posicionais (caminhos, componentes de FK, normalizadores), `enum.values`, valores dos grupos de
   enum e termos de predicados preservam a ordem.
2. Aplicar [JCS, RFC 8785](https://www.rfc-editor.org/info/rfc8785/) ao documento sem `digest` na raiz:
   `digest = "sha256:" + hex_minúsculo(SHA256(JCS(documento_sem_digest)))`. Digest não é assinatura.
3. Gravar `.vetra/graph.json` com JCS do documento completo, seguido de um LF; esse LF não participa do hash.
   Os exemplos documentais podem usar indentação; `graph:check` exige bytes canônicos no artefato versionado.
4. Excluir hora de build, caminho absoluto, máquina e `object_id`. Origens, manifesto e versões participam
   do hash: um comentário pode mudar o build sem mudar o modelo. O diff separa metadados de semântica.

O manifesto cobre declarações e **todo código executável da aplicação vinculado ao build**, inclusive
helpers em `lib/`, configurações não secretas que afetam o modelo, templates usados, `Gemfile.lock` e
`.ruby-version`. A descoberta usa raízes explícitas (`app/`, `lib/` e configuração declarada), detecta
adições/remoções e exclui `.vetra/`, saídas geradas, logs e segredos. Não basta cobrir só arquivos do DSL.
Cada origem/implementação precisa estar no manifesto; o digest da implementação coincide com o do arquivo.
Resolver links simbólicos não pode permitir que uma entrada escape das raízes declaradas.
Gems são cobertas pelo lockfile e pelo pacote imutável de dependências do deploy; o hash não atesta a
procedência desse pacote.

Configuração que muda o grafo é entrada explícita do build, não pode variar depois dele. Credenciais e
opções operacionais independentes do modelo são fornecidas ao runtime separadamente, sem expor seus valores.

### 4. Compatibilidade e evolução

`ir_version` usa `MAIOR.MENOR`, independente das versões do Vetra e da aplicação. **A política vale também
para `0.x`; a versão zero não autoriza quebras silenciosas.**

| Mudança | Regra |
|---|---|
| Correção editorial sem mudar documentos válidos ou interpretação | Mantém a versão |
| Campo opcional ou tipo de nó novo, preservando documentos anteriores | Nova MENOR e novo schema |
| Recurso semântico novo que exige implementação do consumidor | Nova MENOR e requisito em `requires` |
| Remoção, campo obrigatório novo, mudança de tipo, padrão, significado ou canonicalização | Nova MAIOR |
| Mudança no app (entidade, permissão, rota) | Novo grafo/digest; não muda por si o formato |

O leitor anuncia uma **lista explícita de versões suportadas** e recursos implementados. Não basta
aceitar a MAIOR. Cada documento usa seu schema exato, distribuído localmente, sem busca pela rede no boot.

| Documento recebido | Consumidor executável: runtime, RLS, contratos, migrações |
|---|---|
| Versão suportada, recursos conhecidos e documento válido | Aceita após validação semântica/vinculação |
| MENOR futura na mesma MAIOR | Recusa até suportar explicitamente a versão |
| MAIOR desconhecida | Recusa; não interpreta nem reconstrói automaticamente |
| Versão antiga ainda suportada | Usa seu schema/semântica; adaptador explícito se necessário |
| Campo, nó, operador ou requisito desconhecido | Recusa; não ignora dados semânticos |
| Apenas `annotations` desconhecidas | Pode ignorar, sem mudar comportamento |

Uma ferramenta visual pode mostrar JSON futuro como bruto, avisando que não o validou; não pode gerar
políticas ou classificar seu diff como seguro. Um produtor pode emitir formato anterior por alvo explícito
(`target_ir`) somente se **todo o modelo** for representável: descartar uma restrição é erro.

Conversões são offline, explícitas, versionadas e verificadas, preservando o original. O resultado recebe
validação e novo digest. Não são fallback de produção. Campos obsoletos permanecem por pelo menos uma
MENOR, com aviso e instrução de migração, antes de sair na próxima MAIOR. Schemas publicados são imutáveis,
salvo correções editoriais sem efeito, e suas fixtures permanecem disponíveis.

Ao publicar uma MAIOR, a linha estável anterior recebe correções críticas por pelo menos 90 dias; o novo
consumidor mantém leitura da MAIOR anterior nesse período. Na fase 0 há apenas 0.1; conversores só serão
necessários na primeira evolução. Essa política não garante compatibilidade das APIs do app, migrações ou
eventos persistidos: remover um campo pode ser válido no formato e quebrar clientes. Eventos têm versão
própria; expand/contract e coexistência de builds no deploy precisam de controles próprios.

### 5. Validação: forma e significado

O Schema verifica tipos, obrigatoriedade, alternativas e propriedades desconhecidas. Não prova integridade
do grafo ou segurança do código. A etapa semântica é obrigatória:

| Verificação | Resultado |
|---|---|
| ID repetido, referência ausente, `kind` errado, origem fora do manifesto ou caminho fora da raiz | Erro |
| Uso de domínio fora de `depends_on`; ciclo entre domínios com fronteira declarada | Erro |
| Domínio sem restrição declarada (`depends_on: null`) | Aviso e listagem no `doctor` |
| Campo/caminho inexistente em relação, autorização ou payload; default incompatível | Erro |
| Campo pessoal sem classificação exigida; decimal inexato/`Float` monetário | Erro |
| Tenant/`same_tenant` inconsistente, ou omissão de isolamento | Erro |
| Política com dependências de autorização omitidas de `reads` | Erro |
| Dono de transição ausente, default protegido ou escrita literal não autorizada | Erro (ADR-021) |
| Comando usa capacidade externa; query recebe capacidade de escrita/efeito externo | Erro (ADR-004) |
| Handler grava diretamente por repositório em vez de chamar comando | Erro (ADR-016) |
| Efeito conhecido direto, sem `unsafe_effect` motivado | Erro; com exceção, fica fora da garantia |
| Análise incompleta ou gem não classificada | Aviso e restrições de repetição/sombra do ADR-004 |
| Evento interno obrigatório sem handler; payload emitido incompatível | Erro |
| Evento público sem consumidor interno | Permitido |
| Rotas ambíguas, destino incompatível, webhook sem idempotência obrigatória | Erro |
| Live sem `vetra.live` em `requires` ou dependência inexistente | Erro |
| Entidade sem política concedendo acesso | Aviso; nunca concessão implícita |

Cada erro inclui código estável, caminho no JSON, arquivo/linha, motivo e correção sugerida. A IR não pode
pedir a desativação dos mecanismos obrigatórios do ADR-005 ou das etapas do ADR-016.

### 6. Artefato versionado, cache e produção

Conforme a proposta, `.vetra/graph.json` vai para o Git; `.vetra/cache/` é descartável e fica fora dele.
A chave de cache inclui digest da IR, compilador/gerador e versão, Ruby, opções e alvo de compilação.

- **Desenvolvimento:** `graph:build` reconstrói o artefato. Recarga invalida também dependentes por arestas
  reversas. Reconstrução completa é aceitável na fase 0; recarga incremental fica para depois de medir.
- **CI:** `graph:check` reconstrói do código, compara o arquivo versionado, valida e verifica saídas
  determinísticas configuradas. Divergência falha o check; não atualiza o Git silenciosamente.
- **Release:** empacota a IR validada, fontes/implementações e dependências correspondentes.
- **Produção:** confere versão/recursos, schema, semântica, digest, conjunto de entradas e hashes antes de
  vincular implementações e aceitar tráfego. IR ausente, inválida, incompatível ou fontes divergentes
  **impedem iniciar**. O pipeline precisa construir/publicar outro pacote.
- **Cache descartável perdido/corrompido:** recompila a partir da IR já validada e código correspondente.
  Isso não reavalia o DSL para substituir um grafo incompatível. Nenhuma variável dispensa as verificações
  ou reconstrói outro modelo silenciosamente em produção.

O digest detecta divergência, não torna confiável um artefato externo. A IR completa é interna ao build e
à revisão; contém nomes de tabelas, campos e políticas. MCP só recebe a projeção autorizada do ADR-011.
Compartilhamento opcional entre Ractors exige cópia profundamente congelada e testes; não é requisito do núcleo.

### 7. Derivações e diff arquitetural

Contratos/OpenAPI, tipos TypeScript/RBS, SQL de políticas, testes gerados, documentação e `vetra explain`
consomem a IR sem reler o DSL ou executar `call`. Saídas registram digest da IR, gerador/versão e opções
em cabeçalho ou manifesto lateral para formatos sem comentários.

Planos de migração também dependem da IR anterior e do estado conhecido do banco; `db/schema.sql` retrata
o banco após migrações. Não se promete derivar o banco real só do modelo desejado nem aplicar DDL no boot.

`graph:diff` valida os formatos e compara identidades: adições, remoções, renomeações, contratos,
superfícies, capacidades e transições. Toda mudança em papel, política, privacidade ou isolamento aparece
destacada. Se não puder provar ampliação/redução de acesso, reporta **impacto de permissão indeterminado**,
com antes/depois, sem classificar como adição segura. Mudanças só de origem/build aparecem separadas.

## Alternativas rejeitadas

- **Objetos Ruby vivos como contrato:** acopla consumidores ao runtime e não resolve formato ou determinismo.
- **JSON/YAML escrito à mão como fonte:** duplica declarações e exige outra forma de vincular lógica.
- **Serializar `Proc`, bytecode ou `Marshal`:** dependência do Ruby e execução de dados recebidos; o código
  executável pertence ao pacote da aplicação.
- **Ignorar nós/campos de MENOR futura:** pode eliminar restrições de acesso ou transições.
- **Recompilar o DSL automaticamente em produção:** aceitaria um modelo diferente do artefato revisado no CI.
- **Definir agora todas as extensões e recarga incremental:** antecipa outras fases sem evidência.

## Consequências

- A pendência de esquema/compatibilidade tem um contrato concreto para a fase 0, ainda proposto.
- O compilador precisa de normalização, registro de implementações e validação semântica além do Schema.
- Leitores antigos recusam formatos futuros até atualização explícita. Compatibilidade custa manutenção.
- A IR expande convenções em dados sem acrescentar conceitos ao CRUD da camada 1.
- Boot, tamanho da IR e eficácia do cache continuam sem medição; cache binário/incremental não bloqueiam a fase 0.

## Garantias e seus níveis

| Garantia | Nível | Mecanismo e limite |
|---|---|---|
| Formato/referências declaradas consistentes | Estrutural | Schema exato e validação semântica |
| Restrição desconhecida não é ignorada para executar | Estrutural | Versões/recursos explícitos e esquema fechado |
| Reproduzibilidade e correspondência aos fontes | Verificável por testes | Normalização, JCS, manifesto e checks |
| Saídas correspondem à IR/gerador | Verificável por testes | Regeneração e proveniência |
| Ruby arbitrário obedece ao declarado | Fora da garantia estrutural | Análise parcial e limite do ADR-004 |
| Autenticidade do pacote de release | Operacional | Pipeline/armazenamento; digest não é assinatura |

## Testes de aceitação para a fase 0

1. Schema válido no Draft 2020-12 e exemplos com/sem tenant aceitos. Campos, nós e operadores desconhecidos,
   `kind` errado, decimal numérico e propriedade obrigatória ausente falham estruturalmente.
2. Cada regra semântica tem caso que a dispara e diagnóstico com código, JSON e origem.
3. Mesmos fontes/versões em checkouts distintos e descoberta embaralhada geram bytes idênticos. Incluir
   vetores Unicode para JCS, ordem de enums, nulabilidade e arrays posicionais.
4. Hash sem `digest` reproduz o valor; política, código, helper, lockfile, configuração e entradas
   adicionadas/removidas invalidam o build.
5. Versão suportada aceita; MENOR futura, MAIOR desconhecida e recurso não implementado recusam. Anotação
   ignorável não muda comportamento. Testar leitura anterior/conversão quando existir a primeira evolução;
   conversão que perca restrições falha e preserva original.
6. Produção recusa IR ausente/adulterada/incompatível e fontes divergentes. Perda do cache descartável
   só recompila a mesma IR, sem gerar outro modelo para aceitar tráfego.
7. Contratos CRUD, políticas e transições normalizados equivalem aos três exemplos da proposta, inclusive
   defaults protegidos e relações entre tenants.
8. Mesma IR/gerador/opções geram saídas idênticas; `graph:check` detecta edição manual e saída desatualizada.
9. Diff distingue remoção, renomeação, capacidade nova, permissão alterada e mudança só de origem;
   predicados sem comparação decidível recebem impacto indeterminado.
10. Registro congelado recusa declaração tardia; implementação ausente/duplicada falha na vinculação;
    recarga troca registro, código e IR como uma unidade válida.
11. Com Ractors ativos, a cópia de dados é profundamente congelada/compartilhável; o núcleo também passa
    com a extensão desligada.

São critérios para implementar, **não resultados já obtidos**. Validar schemas/fixtures documentais não
comprova o compilador, o RLS ou o runtime ainda inexistentes.

## Questões em aberto que não bloqueiam a fase 0

- Medir boot, tamanho e custo do hash antes de escolher cache binário ou metas de desempenho.
- Definir recompilação incremental com revalidação dos dependentes após existir compilador completo.
- Especificar UI/ejeção, workflows e projeção MCP em suas fases, evoluindo explicitamente o formato.

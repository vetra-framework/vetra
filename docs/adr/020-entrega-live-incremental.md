# ADR-020: Entrega live incremental

- Status: proposto
- Data: 2026-10-30
- Depende de: ADR-005 (RLS e contexto assinado), ADR-008 (ordem e continuidade dos eventos), ADR-016 (ciclo
  de vida da operação), ADR-001 (classificação `privacy` da IR)
- Dependem deste ADR (na data do aceite): 019 (sinais efêmeros)
- Relacionados: ADR-013 (privacidade), ADR-018 (camada de UI)

## Contexto

Consultas reativas são o principal diferencial do Vetra: uma consulta `live` vira uma assinatura, e a tela
acompanha o resultado sem código de broadcast. O problema difícil é fazer isso **respeitando a permissão de
cada assinante, inclusive depois que ela muda**, sem reconsultar o banco por tela.

A primeira versão da proposta reconsultava a consulta para cada assinante a cada mudança: numa sala com
1.000 telas abertas, uma mensagem gerava 1.000 consultas. No outro extremo, um broadcast que renderiza uma
vez para todos é barato, mas não reavalia a permissão de quem já assinou (o `turbo_stream_from` padrão
continua entregando a quem guardou o nome do stream, que não expira).

O Exemplo 3 (chat) mostrou o caso mais difícil: o usuário removido da sala precisa parar de receber
mensagens, mesmo com a tela aberta, e o botão "Excluir" depende do autor, o que quebra a renderização única.

## Decisão

### 1. Assinatura

- Uma **assinatura** é a tupla (consulta, parâmetros, ator, tenant, idioma, template) ligada a **uma conexão
  autenticada**. Ela é autorizada ao assinar, pelo mesmo caminho de leitura do ADR-016 e com o contexto
  assinado do ADR-005.
- **Não existe nome de stream reutilizável.** Não há segredo que, uma vez copiado, continue valendo.
- Cada assinatura guarda a **revisão de autorização** do tenant no momento em que foi autorizada.
- A conexão é WebSocket, com SSE como fallback. Um limite por conexão (assinaturas simultâneas) e um limite de
  fila protegem o processo; um cliente lento é desconectado e ressincroniza.

### 2. Revisão de autorização

- Existe uma linha por tenant em `vetra.authz_revisions (tenant_id, revision)`.
- **Toda tabela que define permissão** (vínculos, papéis, escopos, membros) tem um trigger de instrução,
  gerado a partir do grafo, que incrementa a revisão do tenant **na mesma transação** da mudança. Como é
  trigger, até SQL direto gera a revisão.
- Uma tabela é "de permissão" quando a entidade é referenciada em um `where:` de papel (por exemplo,
  `room_memberships`, usada em `where: { members: :current_actor }`).
- A revisão é **por tenant**: simples e correta. Uma mudança de permissão invalida todas as assinaturas do
  tenant, o que é aceitável porque mudanças de permissão são raras. A granularidade por recurso (sala,
  revenda) só será adotada se a medição mostrar invalidações em massa excessivas (ver questões em aberto).

### 3. Modos de entrega

| Modo | Padrão em | Como confere a permissão | Garantia de revogação |
|---|---|---|---|
| `strict` | Aplicações multiempresa com dados pessoais | Antes de **cada lote**, lê a revisão do tenant (uma linha). Se mudou, revalida as assinaturas do tenant antes de entregar | Nenhum lote **iniciado depois** do commit da revogação entrega dados ao usuário revogado |
| `balanced` | Opção explícita para painéis de baixa sensibilidade | Permissões em memória; invalidação por evento e revalidação periódica | A revogação vale em até um intervalo de revalidação |

- No `strict`, a revisão é lida com uma instrução nova no início do lote, então vê qualquer revogação já
  confirmada.
- No `balanced`, o intervalo de revalidação inicial é de **5 segundos**; a revisão alterada gera invalidação
  imediata por evento, e o intervalo cobre a perda dessa invalidação.
- **Falha fechada.** Se o processo não consegue confirmar a revisão (banco inalcançável, timeout de 2 s no
  `strict`; três intervalos sem confirmação no `balanced`), ele **suspende a entrega de dados protegidos** até
  reconciliar. A tela mostra um estado "reconectando", sem dados novos.
- **Janela residual, aceita.** Um lote já iniciado antes do commit da revogação pode terminar (milissegundos).
  Ordem estrita entre revogação e entrega em vários processos exigiria um protocolo de coordenação e fica
  fora do escopo; a janela é documentada.
- Dados **já entregues não podem ser recolhidos**. O trecho live é limpo na tela, mas o usuário pode tê-los
  copiado. É o mesmo limite do Rails.

### 4. Agrupamento em dois níveis

**Chave estática (por assinatura, calculada ao assinar):**

```
(tenant, escopo efetivo, campos visíveis, filtros e parâmetros, idioma, template)
```

Assinaturas de tenants diferentes **nunca** compartilham grupo. Dentro do grupo, todos podem receber o mesmo
HTML para o mesmo dado.

**Partição por evento (por mudança):** o template pode usar predicados de permissão (`can?(:delete, message)`).
Para a linha alterada, o motor avalia esses predicados **em memória**, para cada assinante, e agrupa pelo
resultado. O trecho é renderizado **uma vez por combinação de resultados**.

- No chat: uma mensagem nova gera **duas** renderizações (a do autor, com o botão "Excluir", e a dos demais),
  qualquer que seja o número de telas abertas.
- Os predicados usados nos templates são compilados a partir do `where:` dos papéis em avaliadores em memória
  sobre (linha, atributos do ator). Um predicado que precisaria de consulta ao banco não é compilável: o
  `vetra explain` aponta, e esse trecho cai na estratégia de reconsulta (abaixo).

### 5. Três estratégias de atualização

O motor escolhe, por consulta:

| Estratégia | Quando | O que faz |
|---|---|---|
| **Delta direto** | Consulta sobre uma única entidade, com filtro, ordenação e limite; sem agregação | `append`, `replace` ou `remove` do trecho, a partir da linha alterada |
| **Reconsulta parcial** | A consulta tem dependências carregadas (`with(:author)`, `with(:members)`) | Recarrega só as linhas e dependências afetadas e renderiza o trecho |
| **Reconsulta completa** | Agregações, `join`s que mudam o conjunto, mudança de filtro, ordenação ou visibilidade, perda de sincronia | Executa a consulta inteira para o grupo e substitui o trecho |

- A linha alterada entra ou sai do conjunto avaliando o filtro da consulta contra `OLD` e `NEW` (o evento de
  mudança carrega os dois, só dos campos não pessoais; §10); a posição vem da ordenação. Um filtro ou uma
  ordenação sobre campo pessoal ou sensível não pode ser avaliado sobre o evento, e a consulta usa a reconsulta
  parcial ou completa.
- Janelas com limite (`last(100)`) são mantidas pelo motor: ao anexar uma linha além do limite, remove-se a
  mais antiga do trecho.
- Quais formas de consulta aceitam delta direto é uma **medição**; a regra acima é o ponto de partida
  conservador.

### 6. Consistência no cliente

- O cliente **começa a escutar antes de ler o estado inicial**: a assinatura é registrada com o checkpoint
  atual (ADR-008), e só então o estado inicial é lido e enviado junto com esse checkpoint. Eventos que
  ocorreram entre o registro e a leitura chegam em duplicata e são descartados pela versão da linha `_v`.
- Na **reconexão**, o cliente envia o último checkpoint recebido. O servidor envia o diff, se provar
  continuidade (ADR-008), ou o estado completo.
- Após reconexão, a assinatura é **reautorizada** do zero, não presumida.

### 7. Revogação

Quando a revalidação mostra que o usuário perdeu acesso:

1. Só a **assinatura** afetada é encerrada; a conexão e as demais assinaturas continuam.
2. O trecho live é **substituído** pela mensagem declarada em `on_revoke`; as mensagens que estavam na tela
   somem junto.
3. A operação é auditada (ator, assinatura, revisão).

### 8. Permissões vindas de fora do banco (SSO)

Uma mudança no provedor de identidade não dispara trigger. Duas regras:

- Grupos e papéis do provedor são **materializados** em tabelas do banco por um comando (por exemplo,
  `sync_identity_memberships`), chamado no login e por webhook do provedor. Como o comando grava em tabela de
  permissão, o trigger gera a revisão.
- Para o que não for materializável, existe `authz.touch!(tenant)`, que incrementa a revisão manualmente, e
  uma **idade máxima da assinatura** (padrão proposto: 15 minutos), após a qual ela precisa ser reautenticada.

### 9. Sinais efêmeros

Presença e "digitando" não passam por este caminho nem entram no histórico. Seguem o ADR-019, com a mesma
autorização das consultas live.

### 10. Evento de mudança de linha

O evento de mudança que o ADR-008 (§3) cita é produzido por um **trigger de linha gerado** em cada entidade que
entra em consulta `live`, na mesma transação da mudança e com o `xid8` dela. Como é trigger, até um `UPDATE`
direto em SQL atualiza as telas (teste 8 do ADR-008).

- O evento carrega a entidade, o identificador, o tenant, o tipo (inserção, alteração ou remoção), a versão
  `_v` e `OLD` e `NEW` **somente dos campos que o grafo não classifica como pessoais nem sensíveis** (`privacy`
  da IR, ADR-001). Campo pessoal ou sensível nunca entra no evento. Assim a outbox não passa a guardar dado
  pessoal fora da proteção por titular que o histórico e a auditoria têm (ADR-016, etapa 7).
- Para renderizar o trecho, os campos pessoais são **relidos** pelo caminho de leitura do ADR-016, uma vez por
  grupo (§4) e com o contexto assinado de um assinante do grupo. Todos os assinantes de um grupo têm o mesmo
  escopo e os mesmos campos visíveis, pela chave estática.
- O trigger é gerado a partir do grafo: a lista de campos do evento sai da classificação `privacy` de cada
  campo, e uma mudança nessa classificação já passa pela revisão do diff arquitetural.

## Alternativas rejeitadas

- **Reconsulta por assinante:** 1.000 consultas por mensagem numa sala com 1.000 telas.
- **Broadcast com uma renderização única e permissões só em cache com revalidação periódica** como padrão:
  entrega dados a quem perdeu acesso até a próxima revalidação. Fica como o modo `balanced`, explícito.
- **Nome de stream assinado e reutilizável:** é um segredo que não expira.
- **Agrupar sem a chave estática**, só por resultado dos predicados: arriscaria misturar tenants ou escopos.
- **Revisão por recurso desde o início:** mais fina, mas bem mais complexa; vale só se a medição pedir.
- **Coordenação entre processos para ordem estrita de revogação:** custo alto para eliminar uma janela de
  milissegundos.
- **Ractor no caminho do filtro:** o `can?` em memória é rápido e o custo de copiar objetos entre Ractors
  superaria o ganho.
- **Evento de mudança com `OLD` e `NEW` completos:** copia campos pessoais e sensíveis para a outbox, fora da
  proteção por titular do histórico e da auditoria, e a eliminação de um titular teria de alcançá-la.
- **Evento gerado só pelo motor, a partir das escritas do comando:** um `UPDATE` direto em SQL não atualizaria as
  telas, o que contradiz o teste 8 do ADR-008.

## Consequências

- Custo por mensagem enviada: um teste de escopo em memória por assinatura, uma leitura de revisão por lote e
  uma renderização por combinação de predicados. Fica próximo ao do broadcast, com permissão conferida antes
  de cada lote.
- Se muitos usuários tiverem permissões individuais, o número de grupos cresce e o custo de manter os grupos
  também. A matriz de carga do gate G4 precisa medir isso, com todos no mesmo grupo e com permissões
  individuais.
- A revisão por tenant invalida todas as assinaturas do tenant a cada mudança de permissão. Em tenants com
  muita rotação de permissões, isso gera revalidações em massa.
- Triggers em tabelas de permissão e uma tabela de revisões entram no esquema gerado.
- Um trigger de linha por entidade live grava um evento por linha alterada, inclusive em escritas em lote
  (preenchimentos de migração, importações), o que aumenta o volume da outbox (ADR-008).
- Os campos pessoais de um trecho são relidos a cada mudança, uma vez por grupo, em vez de viajarem no evento.
- O lado servidor do trecho live é novo, enquanto Hotwire e Action Cable têm anos de produção. O ADR-018
  reduz o risco usando o Turbo como cliente, mas o servidor precisa passar pelo gate G4 antes de produção.

## Garantias e seus níveis

| Garantia | Nível | Mecanismo |
|---|---|---|
| Revogação no `strict`: nenhum lote iniciado depois do commit entrega | Transacional e verificável por testes | Revisão por trigger lida antes de cada lote |
| Revogação no `balanced`: efetiva em até um intervalo | Operacional | Invalidação por evento e revalidação periódica |
| Tenants nunca compartilham grupo de renderização | Estrutural | Tenant na chave estática do grupo |
| No máximo uma renderização por combinação de predicados | Verificável por testes | Partição por evento |
| Reconexão recompõe o estado autorizado | Verificável por testes | Checkpoint, versão `_v` e ressincronização (ADR-008) |
| O evento de mudança não carrega campo pessoal nem sensível | Estrutural | Trigger gerado a partir da classificação `privacy` do grafo |
| Um `UPDATE` direto em SQL atualiza as assinaturas afetadas | Verificável por testes | Trigger de linha gerado (§10) |
| Dados já entregues não são recolhidos | **Fora da garantia** | Limite documentado |

## Critérios de aceitação (gate G4)

1. Usuário removido da conversa deixa de receber entregas após a revogação, conforme o modo.
2. Falha ou atraso no barramento não permite uso indefinido de permissões antigas.
3. Usuários de empresas diferentes nunca compartilham grupo de renderização.
4. Nova mensagem não exige reexecutar a consulta completa de todos os assinantes.
5. Nova mensagem num chat gera no máximo uma renderização por combinação de predicados (autor e demais).
6. Mudança de filtro, visibilidade ou ordenação produz atualização correta.
7. Reconexão após eventos perdidos recompõe o estado autorizado.
8. O indicador de digitação expira após queda inesperada da conexão (ADR-019).
9. A presença continua correta quando um de vários dispositivos desconecta (ADR-019).
10. Uma tela ejetada continua usando os mesmos comandos e regras de autorização (ADR-018).
11. Execução correta com vários processos e falhas simuladas, usando PostgreSQL real e os papéis de produção.
12. (Deste ADR, além do gate G4.) Um `UPDATE` direto em SQL atualiza as assinaturas afetadas, e o evento de
    mudança gravado na outbox não contém campo pessoal nem sensível.

## Questões em aberto

- Quando passar da revisão por tenant para a revisão por recurso: critério proposto, mais de 10 invalidações
  por minuto por tenant em produção de referência (medir antes de decidir).
- Intervalo do modo `balanced` (5 s), idade máxima da assinatura (15 min) e prazo de confirmação da revisão no
  `strict` (2 s): todos são hipóteses.
- Formas de consulta que aceitam delta direto e quais caem em reconsulta parcial ou completa.
- Volume em que o `NOTIFY` passa a atrasar commits (ADR-008 e matriz de carga).
- Limite de assinaturas por conexão e de fila por cliente.
- Como o trigger de instrução da revisão (§2) obtém o tenant: do contexto assinado ou de uma tabela de transição.
  As escritas sem contexto de tenant, como o preenchimento do `vetra_migrator`, precisam da segunda.
- Custo de reler os campos pessoais por grupo (§10) e volume de eventos de escritas em lote; medir na matriz de
  carga do gate G4.

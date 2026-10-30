# ADR-020: Entrega live incremental

- Status: proposto
- Data: 2026-10-30
- Depende de: ADR-005 (RLS e contexto assinado), ADR-008 (ordem e continuidade dos eventos), ADR-016 (ciclo
  de vida da operação)
- Relacionados: ADR-018 (camada de UI), ADR-019 (sinais efêmeros)

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
  mudança carrega os dois); a posição vem da ordenação.
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

## Questões em aberto

- Quando passar da revisão por tenant para a revisão por recurso: critério proposto, mais de 10 invalidações
  por minuto por tenant em produção de referência (medir antes de decidir).
- Intervalo do modo `balanced` e idade máxima da assinatura (5 s e 15 min são hipóteses).
- Formas de consulta que aceitam delta direto e quais caem em reconsulta parcial ou completa.
- Volume em que o `NOTIFY` passa a atrasar commits (ADR-008 e matriz de carga).
- Limite de assinaturas por conexão e de fila por cliente.

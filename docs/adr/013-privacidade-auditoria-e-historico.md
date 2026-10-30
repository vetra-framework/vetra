# ADR-013: Privacy, Audit e History separados, com criptografia por envelope

- Status: proposto
- Data: 2026-10-30
- Depende de: ADR-016 (ciclo de vida da operação), ADR-005 (RLS e contexto assinado)
- Relacionados: ADR-001 (classificação de dados na IR), ADR-017 (formato canônico de valores)

## Contexto

Uma aplicação comercial guarda dados pessoais e, ao mesmo tempo, precisa de um histórico confiável: quem
alterou o quê, e como o registro estava numa data. As duas exigências colidem quando o titular pede a
eliminação dos seus dados. Um histórico imutável que contém o dado pessoal em claro não pode ser eliminado sem
quebrar a auditoria, e apagar linhas do histórico quebra a integridade referencial.

A proposta separa a responsabilidade em três módulos e resolve a colisão por **criptografia por envelope**: o
dado pessoal no histórico e na auditoria é cifrado com uma chave por titular, e eliminar é destruir a chave.

**Escopo jurídico.** O Vetra oferece **ferramentas de conformidade, não conformidade automática**. Base legal,
finalidade e as exceções de conservação (art. 16 da LGPD) continuam decisões do controlador. O pedido de
eliminação do titular (art. 18, VI) é atendido pelas ferramentas abaixo. As referências aos artigos são as da
proposta e pedem revisão jurídica antes de qualquer afirmação de conformidade.

## Decisão

### 1. Três módulos, três responsabilidades

| Módulo | Responsabilidade |
|---|---|
| **Vetra Privacy** | Classificação de dados pessoais, mascaramento em logs e erros, retenção, exportação e eliminação a pedido do titular |
| **Vetra Audit** | Ator, operação, alteração e rastreabilidade |
| **Vetra History** | Versões, consultas "como estava em uma data" e reconstrução de estado |

Eles escrevem na mesma transação do comando (etapa 7 do ADR-016): ou os dados e os três registros existem
juntos, ou nenhum existe.

### 2. Classificação

- Um campo é pessoal por declaração: `personal: true`, com classificação `personal` (padrão) ou `sensitive`.
  A IR 0.1 já representa isso (`privacy`), e o protótipo valida que o payload de um evento não altere a
  privacidade do campo que projeta.
- A classificação alimenta o mascaramento, a criptografia do histórico e da auditoria, a exportação e a
  eliminação. Mudar a privacidade de um campo aparece como mudança de revisão no diff arquitetural (já
  implementado).

### 3. Mascaramento

- Campos pessoais são mascarados em **logs, traces, mensagens de erro e telas de depuração**, pela
  classificação e não por uma lista de nomes mantida à mão. Uma resposta de erro cita o campo, nunca o valor.
- Um dado pessoal enviado a uma integração externa é registrado no Audit: o que foi enviado e a quem.

### 4. History

- O histórico é configurado **por entidade**. A IR 0.1 aceita `none` e `full` (`full` é o padrão do
  protótipo). A proposta também prevê "por campos"; isso ainda não existe no schema e entra quando houver a
  necessidade (veja as questões em aberto).
- O histórico guarda a versão anterior com o ator, a operação e o instante, e responde "como estava em uma
  data". Tem compactação e retenção configuráveis, porque o volume cresce com cada escrita.
- O histórico é gravado pelo framework, a partir da declaração; o `call` não o escreve.

### 5. Audit

- A auditoria é **somente de inclusão**: o papel `vetra_app` tem `INSERT` e não tem `UPDATE` nem `DELETE` nas
  suas tabelas (ADR-005).
- Cada registro traz o ator, o tenant, o identificador da operação (`op_id` do contexto assinado), o comando e a
  alteração, com os valores pessoais cifrados como no histórico.
- A eliminação de um titular é ela mesma um evento de auditoria, **sem o dado pessoal**.

### 6. Criptografia por envelope

- Os dados pessoais **no histórico e na auditoria** são cifrados com uma **chave de dados (DEK) por titular**.
- Cada DEK é guardada cifrada por uma **chave mestra (KEK)** mantida fora do banco, em KMS ou HSM.
- As DEKs ficam num **armazenamento de chaves separado** do banco principal, com retenção de backup própria e
  curta.
- **Eliminar é destruir a DEK.** Os dados cifrados ficam ilegíveis sem remover linhas, e a integridade
  referencial e a trilha de auditoria permanecem.
- Leituras **não chamam o KMS por linha**: as DEKs decifradas ficam em cache de memória por pouco tempo.
- Se a DEK de um titular não está disponível, a leitura do dado pessoal cifrado **falha fechada**: devolve o
  campo como ilegível, nunca em claro.

### 7. Eliminação e exportação

- A eliminação de um titular (a pedido, ou por fim de retenção) faz, em ordem: verificar se há retenção
  obrigatória declarada pelo controlador; sobrescrever ou anonimizar os campos pessoais das tabelas de estado
  atual; destruir a DEK; registrar o evento no Audit.
- A exportação reúne os dados do titular em formato estruturado, lendo o estado atual e o histórico enquanto a
  DEK existe.
- **Pseudonimização sozinha não basta:** um dado reidentificável continua sendo pessoal. Só o dado
  efetivamente anonimizado sai do escopo (arts. 12 e 13, §4º, conforme a proposta).

### 8. O limite dos backups

Um backup do armazenamento de chaves feito **antes** da eliminação ainda contém a DEK, e a KEK continua
existindo. Portanto a eliminação só vale para esses backups **quando a retenção deles expira**, ou após a
**rotação da KEK com o descarte da anterior**. Esse prazo precisa ser documentado por quem opera o sistema. O
mesmo vale para o que está fora do banco: backups, arquivos exportados e integrações têm política própria.

## Alternativas rejeitadas

- **Histórico em claro** (a alternativa da proposta): impede a eliminação sem destruir a trilha.
- **Chaves de dados no mesmo banco e no mesmo backup dos dados:** restaurar um backup devolveria a legibilidade
  de dados já eliminados.
- **Apagar linhas do histórico e da auditoria:** quebra a integridade referencial e a rastreabilidade.
- **Uma só chave para todo o histórico:** eliminar um titular exigiria recifrar tudo.
- **Chamar o KMS a cada linha lida:** inviável em latência e custo; por isso o cache curto na memória.
- **Pseudonimização como substituto da eliminação:** não elimina o dado pessoal reidentificável.
- **Prometer conformidade automática:** a decisão jurídica é do controlador.

## Consequências

- Eliminação viável sem quebrar a auditoria. Nos backups antigos de chaves, só vale após a retenção deles.
- Uma dependência operacional nova: KMS ou HSM, e um armazenamento de chaves separado, com disponibilidade e
  rotação a gerir.
- Leitura de histórico e de auditoria com dado pessoal depende da DEK em cache ou do KMS; uma indisponibilidade
  do KMS degrada essas leituras, não as de estado atual.
- Mais escrita por operação: o histórico e a auditoria entram em toda transação, e o custo precisa ser medido
  na fase 1.
- O mascaramento por classificação exige que todo dado pessoal seja classificado; um campo pessoal não
  declarado vaza.

## Garantias e seus níveis

| Garantia | Nível | Mecanismo |
|---|---|---|
| Dado, histórico e auditoria existem juntos ou não existem | Transacional | Mesma transação (ADR-016) |
| A privacidade de um campo não muda sem revisão | Estrutural | Diff arquitetural e validação do payload dos eventos (implementados no protótipo) |
| Dado pessoal não aparece em log, trace nem erro | Verificável por testes | Mascaramento por classificação |
| Eliminar o titular torna o histórico e a auditoria ilegíveis | Operacional | Destruição da DEK; depende do armazenamento de chaves e do KMS |
| Eliminação alcança os backups | **Limitada** | Só após a retenção dos backups de chaves ou a rotação da KEK |
| Auditoria não é alterável pela aplicação | Transacional | Privilégios do papel `vetra_app` |
| Conformidade com a LGPD | **Fora da garantia** | Decisão do controlador; o Vetra fornece ferramentas |

## Testes de aceitação

1. Um campo `personal: true` não aparece em claro em log, trace nem mensagem de erro, em nenhum adaptador.
2. Mudar a privacidade de um campo é sinalizado pelo `graph:diff` como mudança que exige revisão.
3. Após a eliminação de um titular, o histórico e a auditoria dele existem e estão ilegíveis, e as chaves
   estrangeiras continuam íntegras.
4. A eliminação registra um evento de auditoria sem dado pessoal.
5. O papel `vetra_app` não consegue `UPDATE` nem `DELETE` na auditoria.
6. Leituras repetidas de histórico não chamam o KMS a cada linha.
7. Com o KMS indisponível, a leitura de dado pessoal cifrado falha fechada.
8. Restaurar um backup do banco principal **sem** o backup do armazenamento de chaves não devolve dados
   eliminados.
9. A exportação de um titular contém o estado atual e o histórico legível, enquanto a DEK existe.
10. Uma retenção obrigatória declarada adia a eliminação e é registrada.

## Questões em aberto

- Onde fica o armazenamento de chaves (KMS, banco separado), qual a retenção dos backups dele e como se faz a
  rotação da KEK.
- Como se identifica o **titular** de um campo pessoal (a própria linha, uma entidade relacionada, ou uma
  declaração explícita), já que a DEK é por titular.
- Se o histórico "por campos" entra no schema, e se o padrão `full` é o certo para entidades sem necessidade de
  trilha.
- Formato do histórico (instantâneo completo ou diferença) e política de compactação e retenção.
- Integridade da auditoria além dos privilégios: encadeamento por hash ou assinatura.
- Algoritmo de cifra e formato do envelope (uma cifra autenticada, por exemplo AES-256-GCM, é a hipótese) e
  como os registros referenciam a versão da chave.
- Como o controlador declara retenção obrigatória por exceção legal, e como isso interage com a eliminação
  pedida pelo titular.
- Classificações além de `personal` e `sensitive`, e regras por domínio que exijam classificação.

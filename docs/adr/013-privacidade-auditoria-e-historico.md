# ADR-013: Privacy, Audit e History separados, com criptografia por envelope

- Status: proposto
- Data: 2026-10-30
- Depende de: ADR-016 (ciclo de vida da operação), ADR-005 (RLS e contexto assinado)
- Relacionados: ADR-001 (classificação de dados na IR), ADR-014 (outbox), ADR-017 (formato canônico de valores),
  ADR-020 (entrega live)

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
- **Todo campo pessoal tem um titular declarado.** O titular é a pessoa a quem o dado se refere, e a chave de
  dados (§6) é por titular. A declaração é por entidade: `subject :self` quando a própria linha é o titular
  (uma entidade `customer`), ou `subject :relacao` quando o titular é a entidade apontada por um `belongs_to`
  (o `customer` de um `order`). Um campo pode sobrescrevê-la (`personal: true, subject: :relacao`) quando a linha
  traz dado de mais de uma pessoa. O titular nunca é inferido, e **um campo pessoal sem titular é erro de
  compilação**. Ele é identificado por (tenant, entidade do titular, identificador da linha). A sintaxe é
  proposta; nada disso existe ainda, e a IR 0.1 não tem onde registrá-lo (`privacy` é fechado), então exige uma
  nova MENOR (ADR-001).

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

- A auditoria é **somente de inclusão**. As tabelas de auditoria são do Vetra, e não "da aplicação" no sentido da
  tabela de papéis do ADR-005 (que lista `UPDATE` e `DELETE` só para as tabelas da aplicação). A elas o papel
  `vetra_app` recebe `SELECT`, sob RLS, e `INSERT`, e nunca `UPDATE` nem `DELETE`. Este ADR fixa essa concessão
  como extensão da tabela do ADR-005.
- Cada registro traz o ator, o tenant, o identificador da operação (`op_id` do contexto assinado), o comando e a
  alteração, com os valores pessoais cifrados como no histórico.
- A eliminação de um titular é ela mesma um evento de auditoria, **sem o dado pessoal**.

### 6. Criptografia por envelope

- Os dados pessoais **no histórico e na auditoria** são cifrados com uma **chave de dados (DEK) por titular**.
  Quando há retenção obrigatória (§7), os dados sob a regra usam uma **DEK própria da regra**, separada da DEK
  geral do titular. Assim a eliminação do restante pode destruir a DEK geral sem tornar ilegível o que a lei
  manda guardar.
- Os campos pessoais do payload de um **evento da outbox** são cifrados do mesmo modo. A eliminação torna
  ilegíveis os eventos pendentes do titular, e o handler que os lê recebe o campo como ilegível, nunca em claro.
  Os eventos de mudança de linha do live não carregam campo pessoal (ADR-020, §10).
- Cada DEK é guardada cifrada por uma **chave mestra (KEK)** mantida fora do banco, em KMS ou HSM.
- As DEKs ficam num **armazenamento de chaves separado** do banco principal, com retenção de backup própria e
  curta.
- **Eliminar é destruir a DEK.** Os dados cifrados ficam ilegíveis sem remover linhas, e a integridade
  referencial e a trilha de auditoria permanecem.
- Leituras **não chamam o KMS por linha**: as DEKs decifradas ficam em cache de memória por pouco tempo.
- Se a DEK de um titular não está disponível, a leitura do dado pessoal cifrado **falha fechada**: devolve o
  campo como ilegível, nunca em claro.

### 7. Eliminação e exportação

- A eliminação de um titular (a pedido, ou por fim de retenção) faz, em ordem: identificar as regras de
  retenção que se aplicam aos dados dele; sobrescrever ou anonimizar os campos pessoais do estado atual que **não**
  estão sob retenção; destruir a DEK geral do titular; registrar o evento no Audit, com as regras que adiaram
  parte do pedido e a data em que vencem.
- **Retenção obrigatória.** O controlador a declara na entidade, com o motivo legal, o prazo e o campo de onde o
  prazo conta (por exemplo, `retention :fiscal, years: 5, from: :issued_at, reason: "..."`; sintaxe proposta).
  O motivo é texto do controlador, e o Vetra não o avalia. Uma regra **adia a eliminação do que ela cobre, não do
  restante**: os dados sob retenção ficam legíveis, sob a DEK da regra (§6), e quando o prazo vence a eliminação do
  que restava ocorre sozinha, pela mesma sequência, e é registrada no Audit.
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
- **Titular inferido** (pelo nome do campo, da entidade ou da relação): um erro vaza dado ou destrói o de outra
  pessoa. O titular é declarado, como as renomeações (ADR-015).
- **O ator da operação como titular:** um administrador que edita o dado de um cliente cifraria com a chave do
  administrador.
- **Uma DEK por linha ou por campo:** multiplica as chaves e não corresponde ao pedido do titular, que é por
  pessoa.
- **Retenção que adia a eliminação do titular inteiro:** mantém dado além do que a lei manda guardar.
- **Retenção sem DEK própria:** destruir a DEK geral tornaria ilegível o que a lei manda guardar, e não
  destruí-la manteria legível o que o titular pediu para eliminar.
- **Dado pessoal em claro no payload dos eventos:** a outbox o guardaria até a retenção dela (ADR-014), fora da
  proteção por titular do histórico e da auditoria.

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
- Cada entidade com campo pessoal declara o titular, e esquecer é erro de compilação, não vazamento. Isso exige
  uma nova MENOR da IR.
- Uma regra de retenção multiplica as DEKs: um titular passa a ter uma DEK geral e uma por regra que o alcança.
- Os eventos com campo pessoal passam a pagar a cifra e a decifra, e o handler depende da DEK em cache.

## Garantias e seus níveis

| Garantia | Nível | Mecanismo |
|---|---|---|
| Dado, histórico e auditoria existem juntos ou não existem | Transacional | Mesma transação (ADR-016) |
| A privacidade de um campo não muda sem revisão | Estrutural | Diff arquitetural e validação do payload dos eventos (implementados no protótipo) |
| Dado pessoal não aparece em log, trace nem erro | Verificável por testes | Mascaramento por classificação |
| Eliminar o titular torna o histórico e a auditoria ilegíveis | Operacional | Destruição da DEK; depende do armazenamento de chaves e do KMS |
| Eliminação alcança os backups | **Limitada** | Só após a retenção dos backups de chaves ou a rotação da KEK |
| Auditoria não é alterável pela aplicação | Transacional | Privilégios do papel `vetra_app` (§5) |
| Todo campo pessoal tem um titular declarado | Estrutural | Verificação na compilação (ainda não implementada; exige nova MENOR da IR) |
| Dado sob retenção sobrevive à eliminação do restante e é eliminado ao vencer | Verificável por testes | DEK própria da regra e a sequência do §7 |
| Eventos da outbox não trazem dado pessoal em claro | Verificável por testes | Cifra por DEK dos campos pessoais do payload (§6) |
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
11. Um campo pessoal sem titular declarado falha na compilação.
12. Um pedido de eliminação de um titular com dados sob retenção elimina o restante agora, mantém legível o que
    está sob a regra, registra no Audit a regra e a data, e elimina o que restava quando o prazo vence.
13. O payload de um evento da outbox não contém campo pessoal em claro; depois da eliminação, o handler recebe o
    campo ilegível.

## Questões em aberto

- Onde fica o armazenamento de chaves (KMS, banco separado), qual a retenção dos backups dele e como se faz a
  rotação da KEK.
- A sintaxe da declaração do titular e da regra de retenção, e como a IR a registra (nova MENOR). Também o caso
  de uma pessoa que aparece como titular em mais de uma entidade.
- Se o histórico "por campos" entra no schema, e se o padrão `full` é o certo para entidades sem necessidade de
  trilha.
- Formato do histórico (instantâneo completo ou diferença) e política de compactação e retenção.
- Integridade da auditoria além dos privilégios: encadeamento por hash ou assinatura.
- Algoritmo de cifra e formato do envelope (uma cifra autenticada, por exemplo AES-256-GCM, é a hipótese) e
  como os registros referenciam a versão da chave.
- Retenção: de onde o prazo conta quando o campo de origem muda, e o texto devolvido ao titular quando o pedido
  é adiado em parte.
- Classificações além de `personal` e `sensitive`, e regras por domínio que exijam classificação.

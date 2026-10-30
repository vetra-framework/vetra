# Lista de revisão para aceitar os ADRs

Os 21 ADRs estão escritos e todos têm status **proposto**. Esta lista organiza a revisão: em que ordem ler, o
que conferir em cada ADR e o que o revisor precisa aceitar de forma explícita. Ela não aceita nada por si; a
decisão é de quem revisa.

Aceitar um ADR é aceitar a **decisão**, não a implementação: fora o compilador da fase 0, nenhum componente
existe ainda. Como um ADR aceito não é editado (uma mudança gera outro ADR que o substitui), o momento de
corrigir texto, números e referências é **antes** do aceite.

A classificação "pode mudar a decisão" abaixo é uma **proposta** de quem escreveu os ADRs, baseada no critério da
seção seguinte. O revisor pode discordar e reclassificar.

## Critérios para cada ADR

- [ ] **Decisão verificável.** Dá para dizer, de cada afirmação central, se foi cumprida ou não.
- [ ] **Dependências.** Os ADRs de que ele depende já foram aceitos, ou são aceitos junto. Aceitar um antes do
  outro pressupõe a decisão que ainda não foi tomada.
- [ ] **Evidência.** Cada afirmação sobre o PostgreSQL ou sobre uma biblioteca tem uma sonda em `script/` que
  passou, ou está marcada como hipótese.
- [ ] **Limites aceitos.** Cada garantia declara o nível (estrutural, transacional, verificável por testes,
  operacional, experimental ou fora da garantia), e o revisor aceita o que ficou de fora.
- [ ] **Questões em aberto classificadas.** Uma questão **pode mudar a decisão** se a resposta altera o que o
  ADR decide; nesse caso se resolve antes do aceite. Se só ajusta um parâmetro ou um detalhe de implementação,
  ela é **adiável**. Os números marcados como hipótese (por exemplo "10 tentativas") são valores iniciais, não
  decisões.
- [ ] **Testes de aceitação.** O ADR lista testes que dá para executar e diz com que ambiente (PostgreSQL real,
  os mesmos papéis de produção).
- [ ] **Texto coerente.** Nenhuma frase contradiz outro ADR ou repete como pendência o que outro já decidiu.

## Ordem de revisão

A ordem segue as dependências ("Depende de" no cabeçalho de cada ADR). Os ADRs de uma rodada não dependem uns
dos outros, então podem ser revisados em qualquer ordem entre si.

| Rodada | ADRs | Depende de |
|---|---|---|
| 1 | 016, 001, 002 | nada |
| 2 | 003, 004, 005, 006, 007, 008, 015, 017 | só da rodada 1 |
| 3 | 010, 011, 012, 013, 014, 018, 020, 021 | rodadas 1 e 2 |
| 4 | 009, 019 | 009 depende do 014 (rodada 3); 019, do 020 (rodada 3) |

O índice sugere começar pelos que a fundação usa: 016, 001, 004, 005, 007 e 003. Todos estão nas rodadas 1 e 2.

## Visão geral

A coluna "Evidência" lista as sondas que conferem o que o ADR afirma sobre o PostgreSQL ou sobre bibliotecas.
Onde está "nenhuma", o ADR é uma decisão de projeto e o que o sustenta são os testes de aceitação, ainda sem
implementação.

| ADR | Rodada | Depende de | Evidência | Testes de aceitação | Questões em aberto |
|---|---|---|---|---|---|
| 016 Ciclo de vida da operação | 1 | | nenhuma | 11 | 5 (deixadas a outros) |
| 001 Grafo da Aplicação e IR | 1 | | compilador da fase 0 | 11 (fase 0) | 3 |
| 002 Somente PostgreSQL | 1 | | `sonda_adr002` | 5 | 3 |
| 003 Sequel e repositórios | 2 | 002 | `sonda_adr003`, `sonda_pooler` | 11 | 6 |
| 004 Capacidades e Effect Boundary | 2 | 016 | nenhuma | 8 | 4 |
| 005 RLS e contexto assinado | 2 | 016, 002 | `sonda_adr002`, `sonda_pooler` | 13 | 5 (deixadas a outros) |
| 006 Isolamento de domínios | 2 | 001 | `sonda_adr006` | 7 | 5 |
| 007 Comando e adaptadores | 2 | 016 | nenhuma | 8 | 4 |
| 008 Ordem e continuidade dos eventos | 2 | 016, 002 | `sonda_adr002`, `sonda_pooler` | 9 | 3 |
| 015 Migrações expand/contract | 2 | 002, 001 | `sonda_adr015`, `sonda_adr002` | 12 | 6 |
| 017 Tipo `money` | 2 | 001 | nenhuma | 10 | 5 |
| 010 Adoção hospedada e modo serviço | 3 | 002, 003 | nenhuma | 8 | 6 |
| 011 MCP com identidade delegada | 3 | 007, 016, 005 | nenhuma | 12 | 7 |
| 012 Canário em modo sombra | 3 | 004, 016 | nenhuma | 10 | 6 |
| 013 Privacidade, auditoria e histórico | 3 | 016, 005 | nenhuma | 10 | 8 |
| 014 Outbox | 3 | 016, 008, 002 | `sonda_adr002` | 10 | 6 |
| 018 Camada de UI | 3 | 007, 016 | nenhuma | 10 | 6 |
| 020 Entrega live incremental | 3 | 005, 008, 016 | nenhuma | 11 (gate G4) | 5 |
| 021 Campos de transição | 3 | 016, 004 | nenhuma | 8 | 2 |
| 009 Workflows | 4 | 016, 004, 014 | `sonda_adr009` | 10 | 6 |
| 019 Sinais efêmeros | 4 | 020, 008, 005 | `sonda_adr019` | 11 | 6 |

## Por ADR

Em cada ADR, "limites" são as garantias que o próprio texto classifica abaixo de "verificável por testes" ou
"estrutural". "Pode mudar a decisão" é a proposta descrita no início.

### Rodada 1

**ADR-016 · Ciclo de vida da operação**
- [ ] Limites: "evento entregue pelo menos uma vez, em ordem de commit" é operacional (depende do relay estar
  rodando); "efeito externo exatamente uma vez" é operacional (só com chave de idempotência aceita pelo
  provedor); a repetição segura após deadlock depende de o `call` respeitar o Effect Boundary (ADR-004).
- [ ] Pode mudar a decisão: nenhuma. As cinco questões são deixadas a outros ADRs (005, 008, 011), à medição da
  fase 1 (custo do HMAC) e à retenção da chave de idempotência (24 horas é hipótese).

**ADR-001 · Grafo da Aplicação compilado em IR versionada**
- [ ] Limites: "Ruby arbitrário obedece ao declarado" está fora da garantia estrutural; a autenticidade do
  pacote de release é operacional.
- [ ] O protótipo da fase 0 cobre só um subconjunto dos critérios (execução das operações, primitivas CRUD e
  garantias transacionais seguem pendentes). Aceitar a IR como contrato é aceitar que o formato evolui de forma
  explícita para UI, workflows e MCP.
- [ ] Pode mudar a decisão: nenhuma. As três questões estão no próprio ADR como "não bloqueiam a fase 0".

**ADR-002 · Somente PostgreSQL**
- [ ] Evidência: `sonda_adr002` (23 itens). O 17.11 e o 18.6 cumprem os 23; o 16.15 reprova nos dois itens que
  justificam o mínimo 17 e passa nos outros 21. O PostgreSQL 19 não foi encontrado no espelho usado e entra na
  matriz quando existir.
- [ ] Limites: "o ambiente cumpre os requisitos" é operacional; derivados do PostgreSQL ficam fora da garantia
  até passarem na conformidade.
- [ ] Aceitar o mínimo 17: exclui instalações antigas, e o modo serviço (ADR-010) é a saída.
- [ ] Pode mudar a decisão: nenhuma. As três questões são listas de referência e conveniências de ambiente.

### Rodada 2

**ADR-003 · Sequel com camada fina de repositórios**
- [ ] Evidência: `sonda_adr003` (19 itens, no 16.15, 17.11 e 18.6) e `sonda_pooler` (8 itens, PgBouncer 1.26.1).
- [ ] Limites: "o `call` só alcança dados pelo repositório declarado" é estrutural com o limite do ADR-004;
  "substituir o Sequel sem tocar a aplicação" é experimental. O comportamento atrás de pooler foi medido só no
  PgBouncer 1.26.1; a regra de não usar statements nomeados fica como padrão portátil.
- [ ] Pode mudar a decisão: nenhuma. Duas questões viram limites declarados (outros poolers; `pg` com o Falcon em si).
  O índice pede resolver as questões deste ADR antes da persistência.

**ADR-004 · Capacidades e Effect Boundary**
- [ ] Limites: "gem com conexão própria respeita o Effect Boundary" está fora da garantia.
- [ ] Pode mudar a decisão: **leitura externa em comandos**. Hoje um comando que precisa de um dado externo
  (cotação, CEP) não pode chamá-lo; a saída é um handler que preenche o dado depois, ou um workflow. O ADR
  propõe avaliar um tipo de capacidade "leitura externa pré-transação" e decidir com um caso real. Confirmar que
  a saída atual é aceitável para o aceite.
- [ ] Adiável: granularidade da classificação de dependências, formato final do `effect` e a interação com o
  modo sombra (ADR-012).

**ADR-005 · RLS obrigatório com contexto assinado**
- [ ] Evidência: `sonda_adr002` (RLS com `FORCE`, combinação e troca de políticas, `security_invoker`) e
  `sonda_pooler` (o contexto por `set_config` local não vaza; um `SET` de sessão vaza).
- [ ] Limites: nenhum mecanismo do banco protege contra código comprometido no mesmo processo; a
  confidencialidade da chave do HMAC é operacional.
- [ ] Pode mudar a decisão: nenhuma. O modelo de escopos com vínculos múltiplos já tem declaração no compilador
  (`memberships`), mas o custo em política não foi medido. A frase sobre a versão mínima do PostgreSQL foi
  corrigida (a pendência já estava resolvida no ADR-002).
- [ ] Observação: o ADR-011 pede estender o contexto assinado. Aceitar este ADR é aceitar que o formato cresce.

**ADR-006 · Isolamento de domínios em três níveis, com `Ruby::Box` opcional**
- [ ] Evidência: `sonda_adr006` (13 itens; exige `RUBY_BOX=1`). A gem `pg` pré-compilada falha dentro da box
  (perde a libpq empacotada); compilada contra a libpq do sistema funciona.
- [ ] Limites: o isolamento de monkey patch é experimental; "falha de um domínio não derruba os outros" é
  operacional; o isolamento de segurança entre domínios está fora da garantia da box.
- [ ] Pode mudar a decisão: nenhuma. O `Ruby::Box` é opcional e o nível arquitetural é o padrão.

**ADR-007 · Comando como unidade única de operação e adaptadores de superfície**
- [ ] Limites: nenhum; as quatro garantias são verificáveis por testes ou estruturais.
- [ ] Pode mudar a decisão: **se uma exposição pode restringir o contrato** (aceitar menos campos que o comando)
  sem criar um comando novo. A identidade única do comando é o centro da decisão.
- [ ] Adiável: formato da tarefa de terminal, devolução do resultado de um job, streaming.

**ADR-008 · Notificação como invalidação, ordem por `xid8` e continuidade**
- [ ] Evidência: `sonda_adr002` (tipo `xid8`; uma escrita aberta prende o `xmin`, uma leitura não) e
  `sonda_pooler` (atrás de um pooler em modo de transação o `LISTEN` entrega ao cliente que segura o backend).
- [ ] Limites: "entrega em tempo hábil" é operacional.
- [ ] Pode mudar a decisão: nenhuma. Volume do `NOTIFY`, intervalo de leitura e retenção (1 s e 10 minutos são
  hipóteses) e partição da outbox dependem da matriz de carga.

**ADR-015 · Migrações expand/contract com análise de locks**
- [ ] Evidência: `sonda_adr015` (22 itens, no 16.15, 17.11 e 18.6; roda na CI no 17 e no 18) e `sonda_adr002`
  (troca de política atômica). As verificações de varredura contam `pg_stat_user_tables.seq_scan` em vez de
  comparar tempos.
- [ ] Limites: passos escritos à mão ficam fora da garantia.
- [ ] Pode mudar a decisão: nenhuma. Como o `db:plan` conhece o esquema atual (introspecção ou `db/schema.sql`) é
  escolha de projeto a fechar antes da persistência.

**ADR-017 · Tipo `money` nativo**
- [ ] Limites: nenhum; as seis garantias são verificáveis por testes ou estruturais.
- [ ] Pode mudar a decisão: **como o `scale` do campo e o expoente da moeda convivem** (o valor de uma transação
  deve ter no máximo as casas da moeda; um preço unitário pode ter mais). Define o modelo do tipo.
- [ ] Adiável: taxas de conversão, arredondamento por tenant, biblioteca de formatação, moedas sem ISO 4217.

### Rodada 3

**ADR-010 · Adoção hospedada em Rails ou modo serviço**
- [ ] Limites: isolamento de tenant nas tabelas do Vetra no modo hospedado é transacional, condicionado;
  "nenhuma tabela com dois donos com escrita" e a consistência entre Rails e serviço são operacionais; o domínio
  Vetra não acessar models Rails fora das pontes é estrutural, com os limites do ADR-004.
- [ ] Pode mudar a decisão: **o modo hospedado aceita escrita em tabelas do Rails, ou só leitura nas pontes?**
  A posição inicial é só leitura; a decisão final depende de um caso real. Também: como a autenticação do Rails
  vira o ator do contexto assinado (ADR-005).
- [ ] Adiável: menor versão do Rails, critérios de saída por domínio, convivência com migrações do Rails,
  gerador e deploy do modo independente.

**ADR-011 · MCP opt-in com identidade delegada**
- [ ] Limites: "argumentos hostis não ultrapassam o contrato" é verificável por testes, mas não é prova; "dado
  entregue ao agente não é repassado" está fora da garantia.
- [ ] Pode mudar a decisão: **quem classifica os comandos como sensíveis** (o ADR fixa só o mínimo) e **o
  formato da delegação**, que estende o contexto assinado do ADR-005.
- [ ] Adiável: autenticação do agente e transporte, canal de aprovação humana, validade e limite de taxa,
  leituras como ferramentas e exfiltração, conjunto de testes adversariais.

**ADR-012 · Canário em modo sombra com capacidades simuladas**
- [ ] Limites: "a sombra não produz efeito externo" é estrutural com o limite do ADR-004; código fora do Effect
  Boundary está fora da garantia; "a cópia do tráfego não afeta a produção" é operacional.
- [ ] Pode mudar a decisão: **como o repositório simulado representa leituras depois de escritas dentro da mesma
  operação.** Define a fidelidade da comparação.
- [ ] Adiável: formato do simulador, tolerâncias, orçamento e amostragem, `vacuum`, ordem entre requisições
  espelhadas.

**ADR-013 · Privacidade, auditoria e histórico, com criptografia por envelope**
- [ ] Limites: eliminar o titular torna o histórico e a auditoria ilegíveis (operacional); a eliminação alcança
  os backups só de forma limitada; conformidade com a LGPD está fora da garantia.
- [ ] Pode mudar a decisão: **como se identifica o titular de um campo pessoal** (a chave de dados é por
  titular) e **como o controlador declara retenção obrigatória por exceção legal** e como isso convive com a
  eliminação pedida.
- [ ] Adiável: armazenamento de chaves, histórico por campos, formato e compactação, integridade da auditoria,
  algoritmo e formato do envelope, classificações além de `personal` e `sensitive`.

**ADR-014 · Outbox com entrega pelo menos uma vez**
- [ ] Evidência: `sonda_adr002` (um `FOR UPDATE` atribui `xid`). A referência à sonda foi acrescentada ao texto.
- [ ] Limites: "cada evento chega pelo menos uma vez a cada handler" e "o efeito externo ocorre uma vez só" são
  operacionais.
- [ ] Pode mudar a decisão: **qual é o ator de um handler.** A hipótese é um ator de sistema limitado ao tenant do
  evento; operar como o ator original exige capacidade explícita. Também: fan-out materializado por entrega ou
  cursor por handler (o ADR diz que a medição de volume pode reabrir a escolha).
- [ ] Adiável: tentativas máximas, espera e lease (hipóteses), partição, compatibilidade de versões de evento,
  publicação de eventos públicos. O índice pede resolver as questões deste ADR antes da persistência.

**ADR-018 · Camada de UI em módulos fora do núcleo, com ejeção em três níveis**
- [ ] Limites: "uma tela ejetada reflete o contrato atual" é limitada.
- [ ] Pode mudar a decisão: **como o gerador versiona os templates ejetados e detecta que o contrato mudou.** A
  garantia "limitada" acima depende disso.
- [ ] Adiável: o que o `vetra doctor` verifica em ERB dinâmico; sintaxe de `page`, `command_form`, `crud ui:` e
  `expose ui:` (o exemplo do blog as usa, mas o schema 0.1 da IR não representa páginas); autenticação e logs;
  versionamento dos módulos; acessibilidade e internacionalização.

**ADR-020 · Entrega live incremental**
- [ ] Limites: a revogação no modo `balanced` vale em até um intervalo (operacional); dados já entregues não são
  recolhidos (fora da garantia).
- [ ] Os 11 critérios do gate G4 dependem de implementação; o 8 e o 9 vêm do ADR-019 e o 10, do ADR-018.
- [ ] Pode mudar a decisão: nenhuma. As cinco questões são valores e hipóteses (por exemplo, passar para revisão
  por recurso com mais de 10 invalidações por minuto por tenant).

**ADR-021 · Campos de transição**
- [ ] Limites: a proteção contra SQL fora do repositório só existe com `enforce: :db` (trigger com o comando
  vindo do contexto assinado).
- [ ] Pode mudar a decisão: nenhuma. As duas questões (máquina de estados declarativa; `guarded:` para tipos
  além de enum) ampliam o recurso.

### Rodada 4

**ADR-009 · Workflows duráveis por histórico de eventos e replay determinístico**
- [ ] Evidência: `sonda_adr009` (14 itens, só biblioteca padrão). O bloqueio por `TracePoint` precisa de `:call`
  e `:c_call`, custa cerca de 4 vezes e é uma lista de negação com furos (escaparam, entre outros, `Time.new`,
  `Date.today`, `SecureRandom`, `Kernel#system` e `TCPSocket`).
- [ ] Limites: "os efeitos de um passo não se repetem após queda" é operacional; "o código não usa relógio,
  acaso, I/O ou threads" é estrutural, mas limitado; o bloqueio por `TracePoint` é rede de segurança de
  desenvolvimento, não garantia.
- [ ] Pode mudar a decisão: **a viabilidade e o custo do escalonador de fibras determinístico completo**, que a
  sonda não cobre, e **quem é o ator de um workflow** e como o tenant e o contexto assinado se aplicam a cada
  passo (ADR-004 e ADR-005).
- [ ] Adiável: limite de tamanho do histórico, manutenção de versões antigas, sintaxe do DSL (o schema 0.1 não
  representa workflows), precisão dos temporizadores.

**ADR-019 · Sinais efêmeros autorizados pelo mesmo motor**
- [ ] Evidência: `sonda_adr019` (5 itens, no 16.15, 17.11 e 18.6): limite do payload do `NOTIFY` (7.999 bytes
  passam, 8.000 falham) e volume de WAL de tabelas `UNLOGGED`.
- [ ] Limites: a presença **não sobrevive a um crash do banco** (garantia não oferecida; a tabela `UNLOGGED` volta
  vazia e se recompõe pelos heartbeats); "entrega em tempo hábil" é operacional.
- [ ] Pode mudar a decisão: **se o estado de presença é dado pessoal** para fins de privacidade (ADR-013). A
  resposta depende da decisão do ADR-013.
- [ ] Adiável: valores de limitação de taxa e heartbeat (hipóteses), `autovacuum` da tabela de presença,
  comportamento num failover, limiar para adotar o Redis.

## O que já foi corrigido por esta revisão

- ADR-005: a "versão mínima do PostgreSQL" era listada como pendência, mas o ADR-002 já a fixou em 17. A frase
  agora remete ao ADR-002.
- ADR-014: a medição do `FOR UPDATE` passou a citar a sonda que a confere.

## Depois do aceite

- Mudar de decisão gera um ADR novo que substitui o anterior.
- O índice (`README.md`) passa a registrar o novo status de cada ADR.
- Antes de implementar a persistência, as questões em aberto dos ADRs 003, 005, 014 e 015 precisam estar
  resolvidas (índice, "Próximo passo", item 4).

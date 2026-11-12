# ADR-051: Contadores duráveis de limite de taxa

- Status: proposto
- Data: 2026-11-12
- Depende de: ADR-034 (semântica e IR 0.6), ADR-036 e ADR-005 (contexto assinado), ADR-040 e ADR-043 (papéis e manutenção), ADR-044 a ADR-047 (executor), ADR-049 (visitante), ADR-050 (HTTP)

## Contexto

A IR já declara limites, mas o avaliador recusa qualquer autorização que dependa deles. O visitante do blog não consegue comentar. A reserva não pode acompanhar o rollback da operação nem ser repetida a cada acesso, estado final ou tentativa interna. Blog e chat mantêm identidade global apenas em Ruby: `current_actor()` no banco exige um contexto de tenant. Passar um UUID não verificado à função permitiria ao login da aplicação escolher outra cota.

## Decisão

### Armazenamento, janela e identidade

Uma aplicação cujo grafo exige `vetra.rate_limit` recebe `vetra.rate_limit`, de dono `vetra_owner`, com identidade bigint, namespace, ID da política, tenant UUID opcional, ator UUID e `admitted_at timestamptz(6)`. Cada linha é uma admissão numa política. Índices cobrem o contador e a purga por instante/ID. Não há baldes fixos, média aproximada ou relógio Ruby para a janela.

O contador é `(namespace da aplicação, ID da política, tenant ou NULL, ator)`. `NULL` é o marcador de ausência, sem inventar um tenant sentinela. O ator vem exclusivamente do contexto confiável. O UUID anônimo v8, derivado e verificado pelo emissor do ADR-049, representa o visitante; o UUID do principal autenticado representa o usuário. Não se aceita visitante sem ator nem ID de ator na entrada da operação. A borda é responsável por não atribuir o mesmo UUID a identidades diferentes. Rotas, registros, comandos e chaves de idempotência não entram na chave do contador.

### Envelope e privilégios

A aplicação não recebe nenhum privilégio sobre a tabela: nem `SELECT`, `INSERT`, `UPDATE`, `DELETE`, `TRUNCATE` ou acesso à sequência. Só executa `vetra.reserve_rate_limit(text)`, uma função `SECURITY DEFINER`, `VOLATILE`, não estrita, de dono `vetra_owner`, com `search_path = pg_catalog, pg_temp` e objetos qualificados. Tabela com ENABLE/FORCE RLS; uma política própria permite ao dono executar o corpo fechado, e políticas de SELECT/DELETE permitem a purga ao `vetra_relay`. Não há política para `vetra_app`.

A borda emite um envelope **`r1.kid.payload.mac`**, usando `ContextIssuer` e as chaves do ADR-036, provisionadas também no blog. HMAC-SHA256 vincula namespace, tenant (inclusive NULL), ator, operação, ID do pedido e a lista completa de políticas com limite/janela. O descritor vem da decisão sobre a IR, nunca dos argumentos do cliente. A função verifica o mesmo protocolo de assinatura, validade, chave ativa/verify_only, codificação canônica e comparação do MAC usado pelo contexto, com domínio `r1` separado de `v1`. O envelope não contém o instante de admissão. O teto do protocolo é 8 KiB: uma lista que não caiba falha fechada.

Isso evita ampliar o contrato das rotinas `current_tenant()`/`current_actor()` dos planos existentes. Nenhum parâmetro de ator, limite ou janela é aceito fora da assinatura. Uma injeção de SQL com o login `vetra_app` não pode forjar outro principal, reduzir o limite ou ler contadores alheios; reapresentar um envelope autêntico só consome mais da mesma cota. A assinatura não torna confiável um resolvedor defeituoso nem protege contra execução arbitrária no processo que guarda o segredo. O token é omitido dos logs SQL do Sequel como o contexto `v1`; logs de parâmetros do servidor são configuração operacional.

### Reserva conjunta, concorrência e durabilidade

Depois de permitir a autorização, a etapa 3 recebe a lista das políticas limitadas que sustentam a concessão. Se as concessões sem limite já cobrem todos os campos solicitados, a lista é vazia: nenhuma consulta, conexão ou consumo do contador. Se forem necessárias concessões limitadas, todas as limitadas aplicáveis entram juntas, sem alternância de políticas. Negação de autorização nunca reserva. Coleções sem registro mantêm a admissão por papéis do ADR-044; o acesso às linhas continua filtrado pela guarda.

`Data::RateLimit`, injetado em `Edge(rate_limit:)`, usa **pool próprio de `vetra_app`**, separado da unidade da operação. O Runner recusa a implementação de referência se ela usa o mesmo objeto de pool da unidade. A reserva também recusa uma transação já aberta nessa conexão. Abre transação curta em READ COMMITTED, com `statement_timeout = 2000 ms` e `lock_timeout = 1000 ms`. O `pool_timeout` e os timeouts de conexão/rede são responsabilidade da configuração do pool e do hospedeiro (ADR-050).

A função adquire travas consultivas transacionais de 64 bits por contador, derivadas da chave completa. Ordena as **chaves de trava**, não só IDs de políticas, inclusive diante de colisões do hash; colisões serializam contadores independentes, sem ampliar a cota. Depois de adquirir todas, lê `clock_timestamp()` uma vez, conta as admissões posteriores a `instante - janela` e só insere se **todas** comportam mais uma. Função VOLATILE em READ COMMITTED renova o snapshot das leituras depois da espera pelas travas: o próximo reservante vê as admissões confirmadas pelo anterior. Outros isolamentos são recusados. Uma política cheia não consome nenhuma das outras. Exceção no corpo desfaz suas alterações e devolve NULL; timeout/cancelamento também recusa.

Retorno: **0** significa reserva; inteiro positivo é a espera em segundos; NULL ou erro é indisponibilidade. A espera usa o maior tempo necessário entre as políticas cheias, arredondado para cima, mínimo 1. Se o limite diminuiu, procura a admissão cuja expiração realmente torna a contagem menor que o novo limite. É uma estimativa sem garantia de vaga: outros pedidos podem consumir a cota antes do cliente.

A borda só considera admitido depois do COMMIT da reserva. A unidade da operação abre depois. Falha de negócio, FK, timeout, cancelamento ou rollback posterior não devolvem cota. Em falha do COMMIT da reserva, o resultado pode ser incerto e contar, mas o Runner **não executa** a operação. Durabilidade física pressupõe a configuração de durabilidade do PostgreSQL.

### Repetições, guardas e saídas

Serialização e deadlock repetem as etapas da operação, com nova autorização, mas a admissão já confirmada vale **uma vez por chamada do Runner**, mesmo se a janela terminar durante as tentativas. O conjunto reservado é o da primeira decisão; as tentativas internas não ampliam a reserva. Uma nova chamada do cliente, inclusive com a **mesma chave de idempotência**, passa pela reserva antes da etapa 4: um replay consome cota, como o ADR-034 exige. Entrada/chave inválida ou autorização negada antes disso não é admissão.

`Authorization#decide`, `AccessGuard` e a reautorização final não consultam contador. O handler de sistema usa a concessão `calls` e devolve lista vazia de limites. O avaliador informa políticas e descritores; só o Runner faz a reserva.

Taxa excedida produz `Outcome(status: :rate_limited, retry_after: segundos, retryable: true)`, diagnóstico `data_rate_limit_exceeded`. HTTP devolve 429 e o `Retry-After` do Outcome. Colaborador ausente, pool inválido/indisponível, resposta inválida, falha de assinatura/configuração, contenção e falhas de banco viram `data_rate_limit_unavailable`, recusa retentável da etapa 3: **503**, inclusive em rota de registro; nunca 403/404 e nunca admissão. Ausência de ator confiável é `data_authorization_context` e não chama contador.

### Builds, relógio e purga

O digest do grafo não faz parte da chave: reconstrução, edição de corpo e mudanças de fontes conservam a cota quando namespace e ID permanecem iguais. **Reordenar declarações pode mudar os IDs das políticas; não se mantém a continuidade nesse caso**, nem se migram admissões entre IDs. Renomear namespace/papel também não preserva cota. Implantação que precise dessa continuidade deve esperar a maior janela antes de trocar os IDs, ou fornecer migração operacional revisada; não se inventa identidade estável nova na IR 0.6. Mudanças de descritor com o mesmo ID usam as admissões ainda retidas; aumentar a janela não recupera admissões que a purga anterior já apagou. Builds simultâneos com descritores diferentes não prometem uma cota única com a semântica dos dois: a implantação deve coordenar a transição e a retenção.

O relógio autoritativo é o do PostgreSQL primário; processos Ruby só datam a validade da assinatura (tolerância do ADR-036). Deriva Ruby/banco além dessa tolerância recusa. Retrocesso do relógio do banco conserva admissões futuras na contagem, de forma conservadora; avanço pode antecipar vencimentos. NTP sem saltos, monitoramento e continuidade do relógio em failover são requisitos operacionais. Não se promete janela de tempo monotônico entre servidores.

Retenção = **maior janela declarada no grafo implantado**. `vetra rate_limit:purge --root ... [--batch 1000]`, com DATABASE_URL de `vetra_relay`, apaga admissões vencidas em lotes de até 10.000. Corte único do relógio do banco, transportado com fuso; o laço termina mesmo que novas linhas vençam durante a execução. O papel de manutenção só lê/apaga; não reserva, insere ou altera. Agendamento e coordenação da retenção ao trocar builds são do operador. Sem purga há crescimento, sem redução da segurança da janela.

### Plano e guardas

A seção nasce inteira num passo transacional incremental, depois da idempotência e antes da segurança/revisão. Só o blog ganha plano/modelo `0005_expand`; exemplos sem requisito não mudam. Nenhum `graph.json` muda e a IR segue 0.6. Como no ADR-043, a seção é reconhecida por texto/hash exatos; alteração/remoção posterior é recusada até haver tradução específica. O retrato deve ser gerado por replay real com `db:plan --snapshot`, e `--check` confere cadeia, convergência e dump.

A guarda da rotina confere schema/dono, assinatura, retorno, linguagem, volatilidade, atributos, configuração e hash exato do corpo; o fecho das guardas de autorização reconhece somente essa definição quando o grafo exige o recurso. Nome e schema sozinhos não concedem confiança.

## Alternativas rejeitadas

- Memória local/Redis: memória não compartilha a cota entre processos; Redis exigiria nova infraestrutura e não reutilizaria os papéis e o provisionamento do banco.
- Baldes fixos/token bucket: não satisfazem a janela móvel exata do ADR-034.
- Reserva na unidade da operação ou por linha: rollback devolveria cota; guardas e tentativas multiplicariam o consumo.
- `INSERT` direto com RLS por tenant: não prova o ator global, permite forjar carimbo/descritor e não resolve a reserva conjunta sozinha.
- UUID solto em função definidora: o login poderia escolher outra identidade. Um envelope assinado mantém a autoridade na borda existente.
- Tabela adicional só de travas ou trava global: a primeira pede ciclo de vida próprio; a segunda serializa atores e tenants independentes.
- Digest do build na chave: todo deploy zeraria a cota, mesmo sem mudança de política.

## Garantia e validação

Os testes com Sequel.mock cobrem decisões, dispensa, falha fechada, espera HTTP, assinatura, pools separados, repetição interna sem recobrança, replay com recobrança, visitantes, tenants, políticas/janelas distintas, plano e purga. São testes da integração, não prova de SQL ou concorrência.

`script/sonda_rate_limit.rb` aplica planos como `vetra_migrator`, reserva com logins reais de `vetra_app`, purga como `vetra_relay`, e confere janela móvel, 32 conexões simultâneas, atomicidade conjunta, falha posterior, isolamento, privilégios, adulteração, guarda e timeout. Sua execução e a geração/conferência do retrato no PostgreSQL 17 e 18 ficam para a auditoria do Claude; ainda não há evidência operacional desta entrega. O aceite do ADR pertence ao mantenedor.

O custo é uma transação adicional por admissão limitada, verificação HMAC e chave, uma trava e contagem indexada por política, mais uma linha por política admitida. A contenção do mesmo contador é serial; purga, tamanho do pool e latência precisam de medição em produção. Não altera o orçamento dos ADRs 022/023 nem anuncia conformidade integral das oito etapas.

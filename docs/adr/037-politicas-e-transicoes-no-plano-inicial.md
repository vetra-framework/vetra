# ADR-037: Políticas e transições no plano inicial

- Status: aceito
- Aceite: 2026-11-05, pelo Claude por delegação do mantenedor, após a auditoria da C7 (devolvida na rodada 1, aprovada na rodada 2), com a sonda de RLS e integridade em 103/103 no PostgreSQL 18.6.
- Data: 2026-11-05
- Depende de: ADR-005 (§2, §5 e §6), ADR-021, ADR-023 (§2), ADR-030/031 e ADR-035/036

## Contexto

A IR normaliza `scope:` e `where:` no mesmo predicado. Não conserva uma atribuição autenticada dos
papéis Ruby ao ator, exceto quando o próprio predicado consulta vínculos. O plano precisa oferecer
acessos úteis dentro do tenant, proteger o escopo SQL e compor a revisão sem abrir outra transação.

## Decisão

### Políticas e aplicação

`Vetra::SQL::Security` consome a IR validada preservada no resultado de `Schema`. Toda tabela com
`scope: tenant` ou `tenant_root` recebe ENABLE/FORCE RLS e uma restritiva `FOR ALL TO vetra_app`, com
USING/WITH CHECK pela coluna de tenant ou pelo `id` da raiz. Tenant e ator usam as subconsultas não
correlacionadas do ADR-036, sem cache de sessão.

Entidades sem predicados de escopo recebem a permissiva `true` de leitura/escrita prevista no ADR-005.
Isso inclui a raiz, usuários e vínculos do CRM. O RBAC de tais operações, inclusive quem administra
vínculos, pertence à aplicação; DML concedido ao papel SQL não é a autorização completa dos papéis Ruby.
Um cliente com SQL arbitrário pode alterar vínculos dentro do tenant nessas tabelas. O isolamento entre
tenants continua obrigatório; proteção de administração contra esse cliente exige políticas adicionais
e um contrato de identidade/papéis, sem inferir do nome de um papel um vínculo inexistente.

Nas entidades com escopo, as permissivas são por ação CRUD: OR dos predicados das concessões daquela
ação. Ausência de concessão nega a ação; não se acrescenta `true` para preencher ações ausentes. UPDATE
confere OLD e NEW por USING/WITH CHECK; INSERT só tem WITH CHECK. Políticas de campos, comandos,
limites de taxa e a escolha dos papéis continuam na aplicação. Não se traduz o nome de uma ação de
negócio para uma operação SQL nem se confia em uma claim de papel que a IR não define.

O subconjunto SQL inclui `true`, `and`, `or`, `not`, igualdade, `in` literal, campo escalar local,
`actor.id`, literais escalares e EXISTS por `belongs_to`/`has_many`. A ida por FK seguida da inversa
equivalente é reduzida ao vínculo: tenant e ator vêm do contexto e só a unidade é correlacionada.
O índice do vínculo precisa começar por tenant e campo do ator; conta também um índice físico criado
para a FK. Ciclos entre políticas são recusados antes de gerar SQL com recursão de RLS.

Percursos de campo que podem produzir coleções, `money` composto, `many_to_many` sem uma regra de
quantificação neste consumidor, dependências globais e outros operandos não têm tradução definida
neste plano. A concessão correspondente fica na aplicação e o espelho registra política e ação;
usa-se `true` para essa concessão, sempre sob a restritiva. Não se descarta só uma parte do predicado,
pois isso poderia alterar o significado de negação/OR. Esses casos precisam de extensão explícita do
tradutor e testes antes de se anunciar garantia de escopo no banco.

`db/policies/0001_seguranca.sql` é um espelho determinístico dos passos de segurança, com as limitações
em comentários. Somente `db/plans/` é aplicado. `db:plan`, `--snapshot` e `--check` conferem o plano e
o espelho byte a byte contra a IR, inclusive arquivo ausente ou extra, antes de acessar o banco.
Não se aplica o espelho separadamente nem se aceita edição manual como fonte de verdade.

Blog e chat continuam globais: não recebem tenant, RLS de tenant/escopo ou revisão inventados.
Seu RBAC permanece na aplicação; visitante/contexto global precisa de contrato posterior.

### Revisão e transições

`Authorization::Result.statements` expõe as mesmas instruções do SQL standalone sem BEGIN/COMMIT,
SETs da sessão e cabeçalho. O plano as compõe depois de RLS, privilégios e triggers de transição.
As guardas de privilégios e rotinas continuam depois de todos os REVOKEs. Os triggers de revisão
mantêm as tabelas de transição e ENABLE ALWAYS dos ADRs 030/031. A carga inicial lê a raiz vazia;
isso é DML de infraestrutura, sem dados ou segredos embutidos no plano.

Cada entidade `transitions enforce: db` recebe um BEFORE INSERT OR UPDATE por linha, ENABLE ALWAYS,
com dono `vetra_owner`, SECURITY INVOKER e `search_path = pg_catalog, pg_temp`. Somente
`current_user = vetra_migrator` dispensa contexto. Para os demais, o trigger captura o token e chama
`current_tenant()`, que valida o token inteiro, inclusive `cmd`, antes de extrair a claim do token
capturado. Não executa callbacks nem SQL da aplicação entre captura, validação e extração. Não confia
em outra GUC e não cria novo definer ou exceção na guarda C2. EXECUTE é revogado de PUBLIC e da aplicação;
o PostgreSQL verifica a permissão de função ao criar o trigger.

`set_by` compara INSERT ao default literal físico (ou NULL), e UPDATE a OLD com IS DISTINCT FROM,
inclusive nas duas colunas de `money`. Default de contexto com `set_by` é recusado: não se inventa
o valor que o repositório produziria. `guarded` confere a entrada e a saída de cada valor protegido;
uma troca entre valores com donos diferentes exige pertencer às duas listas. Preservar o valor não
é transição e permite editar outros campos. Contexto inválido ou comando indevido falha com
SQLSTATE `42501` e `transition_violation`, sem incluir token, dados ou identidade na mensagem.

## Alternativas rejeitadas

- Tenant permissivo: OR com escopo abriria a fronteira entre tenants.
- Só restritivas: não concede nem os acessos legítimos que a sonda precisa comprovar.
- Permissiva `true` adicional numa entidade com escopo: anularia o escopo gerado.
- Assumir um papel Ruby pelo nome: a IR não declara como provar essa atribuição.
- Dois SQLs editáveis ou aplicar `db/policies/` junto ao plano: divergência e criação duplicada.
- Copiar o standalone com BEGIN/COMMIT: quebra a transação única e a atomicidade do executor.
- Helper SECURITY DEFINER novo para extrair `cmd`: desnecessário; ampliaria a superfície de confiança.
- Comparar só NEW em `guarded`: permitiria sair de valor protegido pelo CRUD genérico.

## Consequências e garantia

A geração continua determinística e sem banco, com IR 0.6. Cada comando tem classificação explícita
de lock/custo e fase expand; custos `tabela_vazia` pressupõem banco vazio. A verificação do token em
transições custa uma validação por linha, além das validações por instrução do RLS. Medições do
ADR-023 com concorrência e pooler seguem pendentes.

Testes sem banco cobrem SQL, diagnósticos, ordem das guardas e divergência do espelho. A sonda
`script/sonda_rls_integridade.rb` aplica os planos dos dois CRMs e uma fixture compilada de `set_by`
como migrador, com chaves aleatórias em memória, e testa vetra_app com tokens válidos/recusados.
A garantia transacional exige sua execução no PostgreSQL 17/18. Migrações incrementais, executor
persistente, emissão de eventos e autenticação do runtime ficam para K8 ou tarefas posteriores.

Referências: [CREATE POLICY](https://www.postgresql.org/docs/17/sql-createpolicy.html),
[CREATE TRIGGER](https://www.postgresql.org/docs/17/sql-createtrigger.html) e
[segurança de rotinas](https://www.postgresql.org/docs/17/sql-createfunction.html).

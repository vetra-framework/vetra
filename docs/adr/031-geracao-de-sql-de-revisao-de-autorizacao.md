# ADR-031: Geração de SQL de revisão de autorização

- Status: aceito
- Aceite: integração direta na main, após testes do gerador e aplicação em PostgreSQL descartável. Confirmado em 2026-11-03 pelo Claude, por delegação do mantenedor, após a auditoria K2 e das correções K5 (`fb41921`) e C2 (`4588b78`).
- Data: 2026-11-03
- Depende de: ADR-001 (IR), ADR-015/025 (planos revisáveis), ADR-020/030 (revisão de autorização)

## Contexto

A sonda do ADR-020 já verifica os triggers do ADR-030, mas eles são escritos à mão. O próximo incremento
gera o SQL a partir das referências de políticas e do armazenamento da IR, sem iniciar um executor de
migrações ou entregar dados live.

## Decisão

- `vetra db:authz:sql --root APP` escreve SQL em stdout. Sempre lê o artefato canônico, confere produtor,
  fontes e digest, sem avaliar o DSL. Não conecta ao banco nem aplica ou grava SQL no projeto.
- A API `Vetra::SQL::Authorization` também aceita uma IR e a valida antes de gerar. O resultado é congelado
  e determinístico. O formato da IR continua 0.3; as versões anteriores continuam sendo lidas.
- A seleção é conservadora: união de `policy.reads`, incluindo as junções, mais a entidade raiz do tenant
  para acompanhar seu ciclo de vida. O relatório no cabeçalho identifica grafo, tabelas e coluna do tenant.
- Esta etapa exige tenant explícito. Na raiz, a coluna é `id`; nas demais entidades, é o campo declarado
  em `entity.tenant`. Dependências globais não recebem um tenant inventado: a geração falha.
- A tabela nova `<sql-schema>.authz_revisions` usa `tenant_id text` e `revision bigint`. O identificador
  físico é convertido para texto; isso aceita UUID, texto ou inteiro, mas os tipos das colunas de vínculo
  precisam coincidir com o da raiz no banco. A tabela de revisão não tem FK para a raiz: remover e recriar
  um tenant mantém seu contador, em vez de reutilizar uma revisão antiga.
- O SQL é um bootstrap para um schema de infraestrutura novo. Exige que as tabelas da aplicação e os
  papéis já existam. Colisão de schema, tabelas particionadas/herdadas, colunas incompatíveis ou papéis
  inadequados falham dentro da transação, sem substituir objetos existentes.
- O proprietário das funções deve ser `NOLOGIN NOSUPERUSER NOBYPASSRLS NOCREATEROLE`; a aplicação deve ser distinta,
  sem superusuário, `BYPASSRLS`, `CREATEROLE` ou vínculo ao proprietário. Ela não pode ser proprietária das
  tabelas protegidas nem de seus schemas. O SQL revoga `TRUNCATE` e `TRIGGER` do papel da aplicação e de
  `PUBLIC`; se esses poderes persistirem por herança, a instalação falha. Os privilégios DML existentes
  são preservados. Não são criados papéis ou políticas RLS.
  O SQL também recusa privilégios herdados de escrita nas revisões, execução das funções e criação no
  schema novo, inclusive quando vierem de `ALTER DEFAULT PRIVILEGES`.
- A instalação usa uma transação, `lock_timeout` de 3 s e locks `SHARE ROW EXCLUSIVE` nas tabelas
  selecionadas, em ordem estável. Permite leituras comuns e bloqueia escritas durante a instalação.
  O preenchimento inicial lê os IDs da raiz e cria revisões zero; essa varredura precisa ser revisada.
- Cada tabela recebe três funções/triggers, com nomes derivados de aplicação e identidade da entidade.
  `INSERT` lê os tenants novos, `DELETE` os antigos e `UPDATE` a união; cada conjunto é distinto e ordenado.
  O incremento transacional por UPSERT e o `NOTIFY` com somente o tenant seguem o ADR-030.
- Funções usam `SECURITY DEFINER`, `search_path` fixo e objetos persistidos qualificados. A aplicação
  recebe somente leitura na tabela de revisões e uso do schema novo; não recebe escrita nem execução
  direta das funções.

## Limites

Este comando não é `db:plan` nem `db:migrate`. Não compara com `db/schema.sql`, não planeja alterações de
instalações existentes, não possui repetição automática de passos e não substitui a introspecção completa
do ADR-025. O SQL gerado deve compor um plano revisado; sua aplicação de produção continua pendente.

Sem tenant, tabelas globais, partições, herança e múltiplas aplicações no mesmo schema de infraestrutura
ficam fora deste bootstrap. A geração de RLS, eventos de linha, `_v`, o runtime strict/balanced, o contexto
assinado e o transporte continuam pendentes. Alterações de políticas no grafo ainda precisam de revisão
e de uma estratégia de atualização; não há upgrade automático deste SQL.

## Garantia

Testes do compilador cobrem seleção, mapeamento, recusas e determinismo. Uma sonda aplica o SQL realmente
gerado em PostgreSQL descartável e verifica triggers, privilégios, concorrência e recusas com rollback.
As 17 verificações passaram localmente no PostgreSQL 18.6; a CI usa 17 e 18. O [guia](../db-authz-sql.md)
registra execução, resultados e limites. O compilador passa a `0.1.0-alpha.5`, sem alterar a IR.

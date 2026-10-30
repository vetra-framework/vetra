# ADR-021: Campos de transição

- Status: proposto
- Data: 2026-10-30
- Depende de: ADR-016 (ciclo de vida da operação), ADR-004 (capacidades e Effect Boundary)
- Relacionados: ADR-005 (RLS e contexto assinado), ADR-018 (camada de UI)

## Contexto

Um CRUD gerado a partir da entidade expõe, por padrão, todos os campos para criação e edição. Isso abre um
buraco que a rodada 7 da proposta reconheceu como erro: no mini CRM, o `update` gerado aceitaria
`status: "won"`, e no blog um autor publicaria pelo formulário de edição sem gravar `published_at`. Em ambos
os casos o **comando** que carrega a regra e emite o evento (`win_lead`, `publish_post`) seria contornado:
sem validação "só rascunhos", sem data, sem `crm.lead.won`, sem e-mail.

No Rails dos exemplos o problema não existia, porque os parâmetros permitidos (`lead_params`) já não
incluíam o `status`. No Vetra, a brevidade vem de gerar o CRUD, então a proteção precisa ser parte do
modelo, não disciplina do desenvolvedor.

## Decisão

Campos e valores que representam uma **transição de negócio** só podem ser alterados pelos comandos que os
declaram.

### Declaração

```ruby
enum :status, %w[new contacted won lost], default: "new",
     guarded: { "won" => :win_lead }          # o valor "won" só entra pelo comando win_lead

timestamp :published_at, set_by: :publish_post # o campo só é gravado por publish_post
boolean   :approved, default: false, set_by: :approve_comment
```

- `set_by:` protege um **campo** inteiro. Aceita um comando ou uma lista (`set_by: %i[publish_post unpublish_post]`).
- `guarded:` protege **valores** de um enum, cada um com o comando (ou lista) que pode levar o registro até ele.
- O valor padrão (`default:`) pode ser gravado na criação; um valor protegido nunca pode ser o padrão
  (erro de boot).

### Regras

1. **Contrato de entrada.** O contrato derivado do CRUD gerado **omite** os campos `set_by:` e **recusa** os
   valores `guarded:`. Uma entrada que traga um campo protegido é recusada na etapa 2 do ADR-016, com um erro
   que diz qual comando usar.
2. **Valores protegidos são terminais para o caminho genérico.** O CRUD genérico só aceita mudar o `status`
   quando o valor atual **e** o novo valor são não protegidos. Sair de `won` também exige um comando.
3. **Telas administrativas geradas** (`crud ui: :admin`) não exibem campos protegidos como editáveis; mostram
   como somente leitura. Os comandos aparecem como botões (`expose ui: { button: ... }`), só quando a
   condição vale.
4. **Comandos genéricos.** Um comando declarado pelo desenvolvedor que **não** esteja na lista `set_by:` ou
   `guarded:` e que tente gravar o campo é recusado:
   - **no boot**, quando a análise estática vê a gravação literal (`update!(lead, status: "won")`);
   - **na etapa 6 do ADR-016**, para o que a análise não alcança: o repositório compara as colunas alteradas
     com as declarações e, se o comando corrente não está autorizado, desfaz a operação com
     `transition_violation`. O erro nomeia o campo, o valor e o comando esperado.
5. **O evento não pode ser pulado.** Como só o comando grava a transição, o evento que ele declara em `emits`
   sai sempre que a transição ocorre. É a garantia que o CRUD irrestrito quebraria.
6. **Registro.** O histórico e a auditoria gravam qual comando fez a transição.

### Reforço no banco (opcional)

Por padrão, a verificação está na aplicação (regras 1 a 4). Uma entidade pode pedir reforço no banco:

```ruby
entity :lead do
  ...
  transitions enforce: :db
end
```

Nesse caso, o gerador cria um trigger `BEFORE UPDATE` que compara `OLD` e `NEW` e valida o comando corrente
contra a lista permitida. O nome do comando vem do contexto assinado (a claim `cmd` do ADR-005), então
SQL injetado não consegue se passar por outro comando. O custo é uma validação do token por linha alterada, e por isso
é opcional: fica para entidades onde a regra de negócio é crítica (financeiro, estoque).

### Exceções controladas

- **Seeds e migrações de dados** rodam como `vetra_migrator` (ADR-005) e podem gravar campos protegidos. O
  histórico registra o ator como `system:migration`.
- **Importações em massa** devem usar um comando próprio que declara os campos em `set_by:`. Não há um "modo
  administrador" que desligue a proteção.

## Alternativas rejeitadas

- **CRUD genérico com todos os campos.** Permite contornar a regra e o evento. É o erro que este ADR corrige.
- **Confiar que o desenvolvedor marque os campos como somente leitura** (`readonly`, `attr_readonly`): é
  disciplina; o framework não sabe qual comando é o dono da transição, e a mesma lacuna reaparece em cada
  entidade.
- **Máquina de estados completa** (`from: -> to:` declarados por transição). É mais expressiva, mas aumenta
  o conceito da camada 1 e o orçamento de conceitos não comporta. Pode ser reavaliada se os módulos reais
  precisarem de transições encadeadas.
- **Verificação só no banco.** Aplicação e banco precisariam concordar sobre o que é a transição, e o erro
  chegaria tarde e em linguagem de SQL. A aplicação é a camada principal; o banco é reforço opcional.

## Consequências

- Um pouco mais de declaração na entidade (`set_by:` e `guarded:`), em troca de uma classe de falha fechada
  por padrão.
- O CRUD gerado fica menor em campos editáveis; a personalização do formulário passa a depender do comando.
- O grafo passa a ter uma relação "campo → comando dono", que alimenta `vetra explain`, o OpenAPI (campos
  protegidos não aparecem como graváveis) e os testes gerados.
- A análise estática de gravações literais tem o mesmo limite do ADR-004: não cobre código dinâmico. A
  verificação na etapa 6 cobre o que ela não vê.

## Garantias e seus níveis

| Garantia | Nível | Mecanismo |
|---|---|---|
| O contrato gerado não aceita campos nem valores protegidos | Estrutural | Contrato derivado do grafo |
| Um comando não autorizado não grava o campo protegido | Verificável por testes | Verificação na etapa 6, mais análise estática no boot |
| O mesmo, contra SQL fora do repositório | Transacional, com `enforce: :db` | Trigger com o comando vindo do contexto assinado |
| A transição sempre emite o evento do comando | Estrutural | Só o comando grava; `emits` é declarado nele |

## Testes de aceitação

1. `POST` e `PATCH` genéricos com `status: "won"` são recusados com 422 e a mensagem indica `win_lead`.
2. `PATCH` genérico de `published_at` é recusado.
3. Sair de um valor protegido pelo caminho genérico é recusado.
4. Um comando que grava um campo protegido sem estar na lista falha no boot (gravação literal) ou na etapa 6
   (gravação dinâmica).
5. O comando dono grava o campo e emite o evento; o histórico registra o comando.
6. As telas administrativas geradas não exibem campos protegidos como editáveis e mostram os botões dos
   comandos só quando a condição vale.
7. Com `enforce: :db`, um `UPDATE` direto fora do comando dono falha no trigger.
8. Um valor protegido como `default:` é erro de boot.

## Questões em aberto

- Máquina de estados declarativa, caso transições encadeadas apareçam nos módulos reais.
- Se `guarded:` deve valer também para outros tipos além de enum (por exemplo, faixas de valor).

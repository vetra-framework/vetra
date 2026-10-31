# ADR-006: Isolamento de domínios em três níveis, com Ruby::Box opcional

- Status: proposto
- Data: 2026-10-30
- Depende de: ADR-001 (Grafo da Aplicação e IR)
- Relacionados: ADR-004 (capacidades e Effect Boundary), ADR-005 (RLS), ADR-010 (adoção e modo serviço), ADR-014
  (outbox)

## Contexto

Em monólitos grandes, a fronteira entre domínios é uma convenção. Ela se rompe de duas formas: um domínio
passa a depender de outro sem que ninguém decida isso, e uma definição global de um domínio (um monkey patch,
uma constante) afeta todos os outros.

O Ruby 4.0 traz o `Ruby::Box`, um recurso **experimental** que separa definições entre "caixas" no mesmo
processo. Ele é tentador como fundação do isolamento, mas é experimental, tem limites conhecidos com extensões
nativas e não é o que a segurança do Vetra pode usar como base. O princípio 8 da proposta é explícito: recursos
experimentais nunca definem a confiabilidade do núcleo, e o Vetra funciona integralmente sem eles.

## Decisão

**O isolamento tem três níveis independentes. O arquitetural é o padrão e a base. O de runtime
(`Ruby::Box`) e o operacional (processo separado) são opcionais.**

| Nível | Mecanismo | Finalidade | Padrão? |
|---|---|---|---|
| **Arquitetural** | Grafo e verificação de dependências | Impedir acoplamentos indevidos | Sim |
| **Runtime** | `Ruby::Box` por domínio | Separar definições e monkey patches; recarga por domínio | Não (opcional, experimental) |
| **Operacional** | Domínio em processo separado | Isolar falhas, memória e recursos, sem adotar microsserviços | Não (opcional) |

### 1. Nível arquitetural (núcleo)

- Cada domínio declara de quais outros depende (`depends_on`). O compilador recusa uma referência a outro
  domínio que não foi declarada, recusa ciclos entre domínios, e exige que o identificador de cada nó pertença
  ao namespace do seu domínio. Um domínio sem `depends_on` gera aviso, porque sua fronteira não pode ser
  verificada. Tudo isso já está implementado no protótipo.
- A garantia vale **para o que foi declarado**. Ruby é dinâmico: uma constante resolvida em tempo de execução
  fora do que a análise alcança escapa (limite do ADR-001 e do ADR-004).

### 2. Nível de runtime: `Ruby::Box`, opcional e experimental

O uso do `Ruby::Box` é uma extensão. Esta decisão fixa o que ela pode e não pode prometer, com base em medições
no Ruby 4.0.9 (`script/sonda_adr006.rb`, 13 de 13 verificações):

**O que a box faz.**

- Um monkey patch em `String` dentro da box A não aparece na principal nem na box B.
- Uma constante definida numa box não existe na principal.
- Extensões nativas comuns carregam dentro de uma box e funcionam: `json`, `bigdecimal`, `prism` e o
  `nokogiri` pré-compilado (1.19.4, com parse de XML).

**O que a box não é (confirmado).**

- **Não é um sandbox de segurança.** Dentro de uma box, o código lê arquivos do sistema, executa comandos,
  abre conexões de rede e vê o mesmo `ENV` do processo.
- **Não isola falhas.** Uma exceção levantada na box sobe ao chamador. Um `exit` dentro da box termina o
  processo inteiro (o `SystemExit` só é contido se o chamador o capturar); `abort` e `exit!` também.

**Limites e peculiaridades medidos.**

- O `Ruby::Box` só existe com `RUBY_BOX=1` no ambiente do processo; sem isso, `Ruby::Box.enabled?` é `false`.
  Cada uso emite o aviso de recurso experimental.
- **O `pg` pré-compilado não carrega numa box.** O Ruby copia a extensão para um arquivo temporário ao
  carregá-la, e a variante pré-compilada do `pg` depende de uma `libpq` empacotada ao lado da extensão
  (`libpq-ruby-pg.so.1`), que fica para trás: `cannot open shared object file`. O `pg` **compilado contra a
  `libpq` do sistema** carrega e consulta o PostgreSQL normalmente. O `nokogiri` pré-compilado não tem esse
  problema. A regra prática é que gem nativa pré-compilada com biblioteca vendorizada precisa ser testada.
- Com o modo box ligado, **`$?` fica `uninitialized`** depois de `system` e de crase no programa principal
  (o valor de retorno de `system` continua correto). Código que lê `$?` precisa usar `Process.wait2` ou
  `Open3`.

**Consequência para o Vetra.** O núcleo não carrega nada dentro de uma box, não exige `RUBY_BOX` e continua
correto sem ele. Quem ligar o recurso assume os limites acima, e o relatório do grafo registra que o domínio
roda em box (nível experimental).

### 3. Nível operacional (opcional)

- Um domínio pode rodar em **processo separado**, o que isola falhas, memória e recursos sem adotar
  microsserviços. Domínios separados se comunicam por API e por eventos da outbox (ADR-014), não por memória
  compartilhada.
- Se dois processos compartilham o banco, cada tabela tem **um único dono** (ADR-010).
- Este é o único nível que isola falhas. O isolamento de segurança continua sendo o das capacidades e do RLS
  (ADR-004, ADR-005), nunca o de uma box.

### 4. Os níveis se somam, não se substituem

Ligar a box não dispensa as dependências declaradas, e separar o processo não dispensa o RLS. Cada nível tem o
seu rótulo de garantia (tabela abaixo) e é descrito como tal na documentação.

## Alternativas rejeitadas

- **`Ruby::Box` como fundação** (a alternativa da proposta): é experimental, só funciona com uma variável de
  ambiente e tem comportamentos como os acima. O núcleo ficaria dependente de um recurso que pode mudar.
- **Só convenção de pastas e revisão:** é o estado do problema. Sem verificação, a fronteira se rompe em
  silêncio.
- **Microsserviços desde o início:** paga o custo operacional antes de provar a necessidade.
- **Tratar a box como barreira de segurança:** as medições mostram que ela não impede arquivo, comando nem rede.
- **Engines ou gems por domínio:** separam o código, mas não verificam dependências nem isolam definições em
  tempo de execução.

## Consequências

- O núcleo independe de qualquer recurso experimental do Ruby.
- Quem quiser separar monkey patches e recarregar um domínio pode ligar a box, ao custo de testar suas gems
  nativas (principalmente as pré-compiladas com bibliotecas vendorizadas).
- A segurança nunca é atribuída à box: isso evita uma falsa sensação de isolamento.
- Separar um domínio em processo próprio exige que ele se comunique só por API e eventos, e exige o dono único
  das tabelas.

## Garantias e seus níveis

| Garantia | Nível | Mecanismo |
|---|---|---|
| Dependência não declarada entre domínios é erro | Estrutural | Validação do grafo, só para o que foi declarado |
| Monkey patch de um domínio não afeta os outros | **Experimental** | `Ruby::Box`, só com `RUBY_BOX=1` |
| Falha de um domínio não derruba os outros | Operacional | Processo separado |
| Isolamento de segurança entre domínios | **Fora da garantia da box** | Capacidades e RLS (ADR-004, ADR-005) |

## Testes de aceitação

1. Uma referência a outro domínio sem `depends_on` falha na compilação; um ciclo entre domínios também.
2. O núcleo e toda a suíte passam sem `RUBY_BOX` e sem `Ruby::Box`.
3. Com a box ligada, um monkey patch num domínio não aparece em outro.
4. Uma gem nativa de produção (`pg`, `nokogiri` e as demais da aplicação) carrega e funciona dentro de uma box,
   ou o domínio é marcado como incompatível com a box.
5. O código do Vetra não depende de `$?` no programa principal.
6. A documentação e o relatório descrevem a box como experimental e não como sandbox.
7. Dois domínios em processos separados trocam eventos pela outbox e não compartilham tabela com escrita.

## Questões em aberto

- Comportamento com as demais gems nativas da aplicação (a lista depende de cada projeto); `pg` e `nokogiri`
  estão medidos.
- Se o `pg` pré-compilado passa a funcionar numa versão futura do Ruby ou da gem, ou se a recomendação de
  compilar contra a `libpq` do sistema permanece.
- Custo de memória e de carga de uma box por domínio em uma aplicação real.
- Como a recarga por domínio interage com o carregamento validado do `graph:link` (que hoje avalia declarações
  uma vez e sela o registro).
- Quando, se algum dia, o `Ruby::Box` deixar de ser experimental, se o nível de runtime sobe de rótulo.

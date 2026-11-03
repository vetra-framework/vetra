#!/usr/bin/env bash
# Simula o gate de compatibilidade da CI sem precisar do GitHub. Extrai os passos "graph:check", "graph:validate",
# "Diff arquitetural" e "graph:link" do próprio .github/workflows/ci.yml, clona o estado commitado do repositório
# numa pasta temporária e roda os passos em cenários de PR e push, conferindo o resultado esperado de cada um.
# Não faz parte da suíte do compilador e não altera a sua árvore de trabalho.
#
#   script/simular_gate_ci.sh
#
# Rode com o Ruby do projeto (.ruby-version): os artefatos registram a versão do Ruby que os gerou, e outro Ruby
# faz o graph:check falhar. Precisa de rede para o bundle install do clone.
set -uo pipefail

repo=$(git rev-parse --show-toplevel)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

LANG=C.UTF-8 LC_ALL=C.UTF-8 ruby -ryaml -e '
  steps = YAML.load_file(File.join(ARGV[0], ".github/workflows/ci.yml")).dig("jobs", "test", "steps")
  { "check" => "graph:check em todos os exemplos", "validate" => "graph:validate em todos os exemplos",
    "diff" => "Diff arquitetural contra a base do evento", "link" => "graph:link em todos os exemplos" }.each do |file, name|
    step = steps.find { |entry| entry["name"] == name } or abort("passo não encontrado no YAML: #{name}")
    File.write(File.join(ARGV[1], "#{file}.sh"), step["run"])
  end' "$repo" "$work" || exit 2

git clone -q "$repo" "$work/ci" || exit 2
# Inclui a implementação local para testar antes de criar o commit do PR.
git -C "$repo" diff --binary HEAD > "$work/local.patch" || exit 2
if [ -s "$work/local.patch" ]; then
  git -C "$work/ci" apply --index "$work/local.patch" || exit 2
fi
for file in script/check_graph_compatibility.rb .github/graph-compatibility.json; do
  if [ -f "$repo/$file" ]; then
    mkdir -p "$work/ci/$(dirname "$file")"
    cp -p "$repo/$file" "$work/ci/$file" || exit 2
    git -C "$work/ci" add "$file" || exit 2
  fi
done
cd "$work/ci" || exit 2
git config user.name simulacao && git config user.email simulacao@example.com
if ! git diff --cached --quiet; then git commit -qm "Snapshot local para simulação" || exit 2; fi
git checkout -q -b pr
git update-ref refs/remotes/origin/main HEAD # a base do PR é o estado clonado
git config user.name simulacao && git config user.email simulacao@example.com
bundle install --quiet || exit 2

failures=0
reset() { git reset -q --hard origin/main && git clean -fdq; }
step() {
  ref="${2-main}"
  if [ -n "$ref" ]; then
    sha=$(git rev-parse --verify "origin/$ref" 2>/dev/null) || sha="$ref"
  else
    sha=
  fi
  BASE_SHA="$sha" EVENT_NAME="${event_name-pull_request}" bash -e "$work/$1.sh" > "$work/saida.txt" 2>&1
}
expect() { # expect "descrição" esperado(zero|falha) passo [base [trecho que a saída deve conter]]
  step "$3" "${4-main}"; code=$?; problem=
  case $2 in
    zero) [ $code -eq 0 ] || problem="esperava saída 0, saiu $code" ;;
    falha) [ $code -ne 0 ] || problem="esperava falha, saiu 0" ;;
  esac
  # Uma falha só vale se for pelo motivo esperado: a mensagem de erro precisa aparecer na saída.
  [ -z "$problem" ] && [ -n "${5-}" ] && ! grep -qF -- "$5" "$work/saida.txt" && problem="a saída não contém \"$5\""
  if [ -z "$problem" ]; then
    printf '  PASS  %s (saída %s)\n' "$1" "$code"
  else
    printf '  FAIL  %s: %s\n' "$1" "$problem"; sed 's/^/        /' "$work/saida.txt" | tail -8
    failures=$((failures + 1))
  fi
}
compared() { grep -c '^graph:diff ' "$work/saida.txt"; }

echo "base: $(git rev-parse --short origin/main); exemplos: $(ls examples | tr '\n' ' ')"

reset
expect "sem mudanças: nada quebra" zero diff
printf '        grafos comparados: %s de %s\n' "$(compared)" "$(ls -d examples/*/ | wc -l | tr -d ' ')"

reset
sed -i '/expose http:/d' examples/mini_crm_revendas/app/domains/crm/win_lead.rb
bundle exec bin/vetra graph:build --root examples/mini_crm_revendas > /dev/null 2>&1
git commit -qam "remove rota"
expect "rota removida de um exemplo existente faz o gate falhar" falha diff

reset
git rm -q examples/chat/.vetra/graph.json && git commit -qm "remove artefato"
expect "artefato removido faz o gate falhar" falha diff

reset
git rm -rqf examples/chat && git commit -qm "remove exemplo"
expect "exemplo apagado faz o gate falhar" falha diff

reset
cp -r examples/blog examples/novo && git add -A && git commit -qm "exemplo novo"
expect "exemplo novo, sem versão na base, não derruba a comparação" zero diff
for passo in check validate link; do
  expect "exemplo novo passa pelo passo normal graph:$passo" zero "$passo"
  printf '        exemplos processados: %s\n' "$(grep -c ': OK' "$work/saida.txt")"
done

reset
echo "# comentário" >> examples/blog/app/domains/blog/domain.rb
bundle exec bin/vetra graph:build --root examples/blog > /dev/null 2>&1
git commit -qam "mudança inofensiva"
expect "mudança só de metadados não derruba o gate" zero diff

# Falha ao ler a base não pode virar "nenhum grafo para comparar".
reset
expect "base inexistente faz o gate falhar" falha diff nao-existe "SHA de base válido"
expect "referência da base vazia faz o gate falhar" falha diff "" "SHA de base válido"

mkdir "$work/fakebin" # um git que resolve a referência, mas falha ao listar a árvore
printf '#!/bin/sh\nfor arg do\n  [ "$arg" = ls-tree ] && { echo "fatal: falha simulada" >&2; exit 128; }\ndone\nexec %s "$@"\n' "$(command -v git)" > "$work/fakebin/git"
chmod +x "$work/fakebin/git"
path_original=$PATH PATH="$work/fakebin:$PATH"
expect "falha do git ao listar a base faz o gate falhar" falha diff main "Falha ao ler a base (git ls-tree)"
PATH=$path_original

git update-ref refs/remotes/origin/sem-grafos "$(git commit-tree "$(git mktree < /dev/null)" -m "sem grafos")"
expect "base legítima, sem nenhum grafo, não derruba o gate" zero diff sem-grafos "nada a comparar"

reset
event_name=push
expect "push normal compara com o SHA anterior" zero diff
expect "primeiro push sem commit anterior passa pelos checks normais" zero diff 0000000000000000000000000000000000000000 "Primeiro push"
expect "push sem SHA de base falha" falha diff "" "SHA de base válido"
sed -i '/expose http:/d' examples/mini_crm_revendas/app/domains/crm/win_lead.rb
bundle exec bin/vetra graph:build --root examples/mini_crm_revendas > /dev/null 2>&1
git commit -qam "remove rota no push"
expect "push com quebra não declarada falha" falha diff main "Quebra sem declaração"

echo
if [ $failures -eq 0 ]; then echo "Resultado: o gate se comporta como esperado."; else echo "Resultado: $failures cenário(s) com falha."; fi
exit $failures

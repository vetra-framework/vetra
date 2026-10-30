#!/usr/bin/env bash
# Simula o gate de compatibilidade da CI sem precisar do GitHub. Extrai os passos "graph:check", "graph:validate",
# "Diff arquitetural" e "graph:link" do próprio .github/workflows/ci.yml, clona o estado commitado do repositório
# numa pasta temporária e roda os passos em seis cenários, conferindo o resultado esperado de cada um.
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
    "diff" => "Diff arquitetural contra a base do PR", "link" => "graph:link em todos os exemplos" }.each do |file, name|
    step = steps.find { |entry| entry["name"] == name } or abort("passo não encontrado no YAML: #{name}")
    File.write(File.join(ARGV[1], "#{file}.sh"), step["run"])
  end' "$repo" "$work" || exit 2

git clone -q "$repo" "$work/ci" && cd "$work/ci" || exit 2
git checkout -q -b pr
git update-ref refs/remotes/origin/main HEAD # a base do PR é o estado clonado
git config user.name simulacao && git config user.email simulacao@example.com
bundle install --quiet || exit 2

failures=0
reset() { git reset -q --hard origin/main && git clean -fdq; }
step() { BASE_REF=main bash -e "$work/$1.sh" > "$work/saida.txt" 2>&1; }
expect() { # expect "descrição" esperado(zero|falha) passo
  step "$3"; code=$?
  if { [ "$2" = zero ] && [ $code -eq 0 ]; } || { [ "$2" = falha ] && [ $code -ne 0 ]; }; then
    printf '  PASS  %s (saída %s)\n' "$1" "$code"
  else
    printf '  FAIL  %s: esperava %s, saiu %s\n' "$1" "$2" "$code"; sed 's/^/        /' "$work/saida.txt" | tail -8
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

echo
if [ $failures -eq 0 ]; then echo "Resultado: o gate se comporta como esperado."; else echo "Resultado: $failures cenário(s) com falha."; fi
exit $failures

#!/usr/bin/env bash
set -u

# test_coverage_objective_skills.sh — regressão dos literais introduzidos pela
# US-04 ("Objetivo de cobertura 100% por ciclo"): react-feynman emite a seção
# 'Objetivo do ciclo' + o 'Contrato de cobertura por fatia'; prd adiciona um
# 'AC de cobertura' por user story; a estrutura é extensível (Objetivo #2) sem
# redesenho. Mudança puramente de DOCUMENTAÇÃO (texto de skill) — sem este teste,
# uma regressão que apagasse a seção inteira passaria silenciosa.
#
# NÃO confundir com test_us04_skill_integration.sh (feature disjunta:
# auto-grill-me + domain-docs). Aquele suite mede outra coisa; este guarda
# EXATAMENTE os literais deste patch.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RF="$REPO_ROOT/skills/react-feynman/SKILL.md"
PRD="$REPO_ROOT/skills/prd/SKILL.md"

PASS=0; FAIL=0; FAILED=""
_fail() { FAIL=$((FAIL+1)); FAILED="${FAILED}
  ✗ $1"; }
_pass() { PASS=$((PASS+1)); }
assert_present() {
  if grep -qF -- "$2" "$1"; then _pass
  else _fail "$3 :: '$2' AUSENTE de $(basename "$(dirname "$1")")/$(basename "$1")"; fi
}

for f in "$RF" "$PRD"; do
  [[ -f "$f" ]] || { echo "FAIL: $f inexistente" >&2; exit 1; }
done

# ─── AC1 — react-feynman instrui a emitir a seção 'Objetivo do ciclo' ────────────
assert_present "$RF" "### Objetivo do ciclo" "AC1 react-feynman emite a seção 'Objetivo do ciclo' no template de plano"
assert_present "$RF" "Objetivo #1" "AC1 a seção numera o Objetivo #1 (cobertura)"

# ─── AC2 — template inclui 'Contrato de cobertura por fatia' (unidades + testes) ──
assert_present "$RF" "Contrato de cobertura por fatia" "AC2 template inclui o contrato de cobertura por fatia"
assert_present "$RF" "unidades/branches introduzidos" "AC2 o contrato lista unidades/branches introduzidos"
assert_present "$RF" "Unidade/branch introduzido" "AC2 o contrato pareia unidade→teste em tabela"
assert_present "$RF" "Teste que o exercita" "AC2 o contrato exige o teste que exercita cada unidade"

# ─── AC3 — prd instrui a adicionar um AC de cobertura por US ─────────────────────
assert_present "$PRD" "AC de cobertura" "AC3 prd adiciona um AC de cobertura por user story"
assert_present "$PRD" "cobertura de patch 100%" "AC3 o AC de cobertura exige patch 100%"

# ─── AC4 — 'Objetivo do ciclo' é descrita como extensível (Objetivo #2) sem redesenho ─
assert_present "$RF" "Objetivo #2" "AC4 react-feynman cita Objetivo #2 futuro"
assert_present "$RF" "sem redesenho" "AC4 react-feynman: novo objetivo entra sem redesenho"
assert_present "$PRD" "Objetivo #2" "AC4 prd também é extensível p/ Objetivo #2"
assert_present "$PRD" "sem redesenho" "AC4 prd: AC transversal análogo sem redesenho"

# ─── AC5 — frontmatter description (trigger phrases) intacto em ambas as skills ───
# A descrição do frontmatter é o que dispara auto-invocação; uma regressão que a
# apagasse quebraria o trigger. Asserção positiva sobre o literal de cada uma.
assert_present "$RF" "executar ciclo completo de planejamento+revisão." "AC5 react-feynman: trigger phrase do frontmatter intacta"
assert_present "$PRD" "precisa ser convertido para execução no loop Ralph." "AC5 prd: trigger phrase do frontmatter intacta"

# ─── Summary ──
TOTAL=$((PASS + FAIL))
echo ""
echo "─── Resultado: $PASS/$TOTAL pass ──────────────────"
if [ "$FAIL" -gt 0 ]; then
  printf '%s\n' "$FAILED"
  exit 1
fi
exit 0

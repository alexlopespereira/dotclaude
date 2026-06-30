#!/usr/bin/env bash
set -u

# test_us05_coverage_review_dod_docs.sh — regressão de PROTOCOLO de US-05:
# dimensão COVERAGE no Codex (CODE_REVIEW.md) + critério cross-cutting de
# cobertura na DoD (DOD.md + docs/definition_of_done.md) + docs (README/WORKFLOW).
#
# Por que existe: a mudança é DOCS-ONLY (texto de rubrica/DoD/README). Sem teste,
# uma regressão que (a) apague a dimensão COVERAGE da rubrica, (b) remova a regra
# grep-verificável do pragma, (c) afrouxe o veredicto binário, (d) apague o
# critério cross-cutting de cobertura de qualquer um dos dois DoDs, ou (e) suma
# com /coverage-init / 'Objetivo do ciclo' do README/WORKFLOW passaria silenciosa.
# Guarda os LITERAIS introduzidos por ESTE patch (mutation-proof) — espelha o
# aprendizado de US-04 (teste não pode medir feature disjunta).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CR="$REPO_ROOT/skills/ralph-adversarial/CODE_REVIEW.md"
DOD_LEAN="$REPO_ROOT/skills/auto-grill-me/references/DOD.md"
DOD_CANON="$REPO_ROOT/docs/definition_of_done.md"
README="$REPO_ROOT/README.md"
WORKFLOW="$REPO_ROOT/WORKFLOW.md"

PASS=0; FAIL=0; FAILED=""
_fail() { FAIL=$((FAIL+1)); FAILED="${FAILED}
  ✗ $1"; }
_pass() { PASS=$((PASS+1)); }
assert_present() {
  if grep -qF -- "$2" "$1"; then _pass
  else _fail "$3 :: '$2' AUSENTE de $(basename "$1")"; fi
}
assert_file() {
  if [ -f "$1" ]; then _pass
  else _fail "$2 :: alvo de ref cruzada inexistente: $1"; fi
}

for f in "$CR" "$DOD_LEAN" "$DOD_CANON" "$README" "$WORKFLOW"; do
  [ -f "$f" ] || { echo "FAIL: $f inexistente" >&2; exit 1; }
done

# ─── AC1 — CODE_REVIEW.md ganha dimensão COVERAGE + regra grep-verificável do pragma
assert_present "$CR" "**COVERAGE**" \
  "AC1 dimensão COVERAGE existe na rubrica"
assert_present "$CR" "pragma novo (no cover) sem justificativa adjacente = finding P1" \
  "AC1 regra do pragma com literal exato"

# ─── AC2 — Codex lê o bloco COVERAGE_DIFF do --report como evidência; veredicto binário
assert_present "$CR" "COVERAGE_DIFF" \
  "AC2 rubrica cita o bloco COVERAGE_DIFF do --report"
assert_present "$CR" "veredicto segue binário" \
  "AC2 veredicto binário (sem bloqueio numérico in-loop)"
assert_present "$CR" "sem bloqueio numérico in-loop" \
  "AC2 explicita ausência de gate numérico no loop"

# ─── AC3 — critério cross-cutting de cobertura nos DOIS DoDs (literais idênticos)
assert_present "$DOD_CANON" "Cobertura por ciclo" \
  "AC3 critério cross-cutting no DoD canônico"
assert_present "$DOD_CANON" "categoria instrumentável" \
  "AC3 aplicabilidade às categorias instrumentáveis (canônico)"
assert_present "$DOD_CANON" "coverage-gate.sh --gate" \
  "AC3 referencia o gate (canônico)"
assert_present "$DOD_LEAN" "Cobertura por ciclo" \
  "AC3 critério cross-cutting no DoD lean"
assert_present "$DOD_LEAN" "categoria instrumentável" \
  "AC3 aplicabilidade às categorias instrumentáveis (lean)"
assert_present "$DOD_LEAN" "coverage-gate.sh --gate" \
  "AC3 referencia o gate (lean)"

# ─── AC4 — toda ref cruzada nova validada por existência do alvo (test -f)
# Nota: o "Objetivo do ciclo #1" é citado como proveniência (data/ciclo), no
# padrão das demais "Origem:" do DoD — não como ref a arquivo. Por isso não há
# assert ao plano-fonte: planos vivem em .claude/plans/ (gitignored, efêmeros).
assert_file "$REPO_ROOT/commands/coverage-init.md"                       "AC4 /coverage-init"
assert_file "$REPO_ROOT/skills/ralph-adversarial/lib/coverage-gate.sh"   "AC4 coverage-gate.sh"
assert_file "$REPO_ROOT/skills/react-feynman/SKILL.md"                   "AC4 skill do Objetivo do ciclo"

# ─── AC6 — README e WORKFLOW listam /coverage-init e o 'Objetivo do ciclo'
assert_present "$README"   "/coverage-init"     "AC6 README lista /coverage-init"
assert_present "$README"   "Objetivo do ciclo"  "AC6 README cita o Objetivo do ciclo"
assert_present "$WORKFLOW" "/coverage-init"     "AC6 WORKFLOW lista /coverage-init"
assert_present "$WORKFLOW" "Objetivo do ciclo"  "AC6 WORKFLOW cita o Objetivo do ciclo"

echo "── test_us05: $PASS passaram, $FAIL falharam ──"
if [ "$FAIL" -gt 0 ]; then printf '%s\n' "$FAILED" >&2; exit 1; fi
exit 0

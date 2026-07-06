#!/usr/bin/env bash
set -u

# test_context_budget_principles.sh — trava a política de screenshot da skill
# browser-inspect (regras 5/6 de §Extração dirigida) E o delta do P16 em
# CLAUDE.global.md (higiene de sessão: evaluate>screenshot, janela como unidade
# de sessão, retomada pós-pausa). Ciclo context-budget-gate, US-02; plano-fonte
# .claude/plans/2026-07-06T14-00-17Z-context-budget-gate.md.
#
# Por que existe: medição 2026-07-06 — 45 Reads de PNG = 8,5M chars de contexto;
# 15,5M de 30,3M tokens de cache-write vieram de reescritas frias. O texto será
# editado por sessões futuras; este teste ancora as cláusulas (presença) no
# idiom da suíte (contadores PASS/FAIL, exit != 0 em falha, run-all.sh).
# Mutation-proof (AC5): remover qualquer cláusula AC1-AC3 faz um assert falhar.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
GLOBAL_MD="$REPO_ROOT/CLAUDE.global.md"
SKILL_MD="$REPO_ROOT/skills/browser-inspect/SKILL.md"

PASS=0; FAIL=0; FAILED=""
_fail() { FAIL=$((FAIL+1)); FAILED="${FAILED}
  ✗ $1"; }
_pass() { PASS=$((PASS+1)); }
# assert_present <file> <fixed-string> <label> — grep -F casa → pass.
assert_present() {
  if grep -qF -- "$2" "$1"; then _pass
  else _fail "$3 :: '$2' AUSENTE de $(basename "$1")"; fi
}

# ─── Pré-condição: fontes-da-verdade existem ─────────────────────────────────
[[ -f "$GLOBAL_MD" ]] || { echo "FAIL: $GLOBAL_MD inexistente" >&2; exit 1; }
[[ -f "$SKILL_MD"  ]] || { echo "FAIL: $SKILL_MD inexistente"  >&2; exit 1; }

# ─── AC1: browser-inspect regra 5 — verificação textual, não screenshot ──────
assert_present "$SKILL_MD" 'Verificação de passo é textual, não visual' \
  "AC1 regra 5 título 'verificação textual, não visual'"
assert_present "$SKILL_MD" 'use `browser_evaluate` dirigido — nunca `browser_take_screenshot`' \
  "AC1 regra 5 'evaluate dirigido, nunca screenshot'"
assert_present "$SKILL_MD" 'Screenshot **só** quando a decisão seguinte depende de **ver** o layout' \
  "AC1 regra 5 'screenshot só quando decisão depende de ver o layout'"

# ─── AC2: browser-inspect regra 6 — screenshot p/ humano != agente ───────────
assert_present "$SKILL_MD" 'Screenshot para humano ≠ para agente' \
  "AC2 regra 6 título 'screenshot humano != agente'"
assert_present "$SKILL_MD" '**não** faça `Read` do PNG de volta' \
  "AC2 regra 6 'não Read do PNG de volta'"
assert_present "$SKILL_MD" '`Read` de PNG no máximo **1-2 por fase**' \
  "AC2 regra 6 'Read de PNG no máximo 1-2 por fase'"
assert_present "$SKILL_MD" '**nunca** re-`Read` do mesmo arquivo' \
  "AC2 regra 6 'nunca re-Read do mesmo arquivo'"
assert_present "$SKILL_MD" '(2026-07-06): 45 `Read`s de PNG numa sessão = 8,5M chars' \
  "AC2 regra 6 origem medida '2026-07-06, 8,5M chars'"

# ─── AC3(a): P16 — evaluate > screenshot / Read de PNG só p/ decisão visual ──
assert_present "$GLOBAL_MD" 'Verificação por `evaluate` dirigido, não screenshot' \
  "AC3a P16 'evaluate dirigido, não screenshot'"
assert_present "$GLOBAL_MD" '`Read` de PNG só p/ decisão visual' \
  "AC3a P16 'Read de PNG só p/ decisão visual'"

# ─── AC3(b): P16 — janela como unidade de sessão -> /handoff-continue ────────
assert_present "$GLOBAL_MD" 'Janela é a unidade de sessão' \
  "AC3b P16 'janela é a unidade de sessão'"
assert_present "$GLOBAL_MD" 'cruzou o gate → `/handoff-continue`' \
  "AC3b P16 'cruzou o gate -> /handoff-continue'"

# ─── AC3(c): P16 — retomada pós-pausa longa prefere sessão nova ─────────────
assert_present "$GLOBAL_MD" 'retomada pós-pausa longa prefere sessão nova' \
  "AC3c P16 'retomada pós-pausa prefere sessão nova'"

# ─── AC3: número rastreável no P16 (15,5M / 30,3M cache-write) ───────────────
assert_present "$GLOBAL_MD" '15,5M de 30,3M tokens de cache-write' \
  "AC3 P16 número rastreável '15,5M/30,3M cache-write'"

# ─── AC4: delta mínimo — a linha do P16 não cresce além do budget documentado ─
# Baseline medido antes desta US: 49 palavras. Budget do delta: ≤ 50 palavras
# (≈ ~60 tokens PT, DoD b3-Tarefa3 "delta enxuto"). Cap = 49 + 50 = 99.
P16_BASELINE_WORDS=49
P16_DELTA_BUDGET=50
P16_CAP=$((P16_BASELINE_WORDS + P16_DELTA_BUDGET))
P16_WORDS=$(grep -E '^16\. ' "$GLOBAL_MD" | wc -w | tr -d ' ')
if [ "$P16_WORDS" -le "$P16_CAP" ]; then _pass
else _fail "AC4 delta mínimo :: P16 tem $P16_WORDS palavras (> cap $P16_CAP = baseline $P16_BASELINE_WORDS + budget $P16_DELTA_BUDGET)"; fi

# ─── Sumário ─────────────────────────────────────────────────────────────────
echo "test_context_budget_principles: PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then
  echo "Falhas:$FAILED" >&2
  exit 1
fi
exit 0

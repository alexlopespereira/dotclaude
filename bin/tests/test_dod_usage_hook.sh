#!/usr/bin/env bash
set -u

# test_dod_usage_hook.sh — testes para hooks/dod-usage-log.sh.
#
# O hook emite eventos `use` de telemetria DETERMINISTICAMENTE, parseando
# marcadores <!-- dod-use: id --> / <!-- test-spec-use: id --> nos planos
# persistidos (+ TEST-PATTERNS.md). Substitui a emissão prompt-driven quebrada.
#
# Estratégia: DOTCLAUDE_REPO aponta para o repo REAL (libs + DOD.md/TEST-PATTERNS
# canônicos → shas reais); USAGE_LOG_HOME e CLAUDE_PROJECT_DIR são sandbox (não
# poluem ~/.claude nem o repo). Asserções fortes: contagem exata de eventos +
# valor do campo sha via jq (não "≥1").

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/../.." && pwd)"
HOOK="$REPO/hooks/dod-usage-log.sh"
DOD_CANON="$REPO/skills/auto-grill-me/references/DOD.md"
TS_CANON="$REPO/skills/testing/references/TEST-PATTERNS.md"

PASS=0; FAIL=0; FAILED=""
_fail() { FAIL=$((FAIL+1)); FAILED="${FAILED}
  ✗ $1"; }
_pass() { PASS=$((PASS+1)); }
assert_eq() { [ "$1" = "$2" ] && _pass || _fail "$3 :: expected '$2' got '$1'"; }

[ -f "$HOOK" ]      || { echo "FAIL: $HOOK inexistente" >&2; exit 1; }
[ -f "$DOD_CANON" ] || { echo "FAIL: $DOD_CANON inexistente" >&2; exit 1; }
[ -f "$TS_CANON" ]  || { echo "FAIL: $TS_CANON inexistente" >&2; exit 1; }

TMP="$(mktemp -d -t dod-usage-hook.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
HOME_DIR="$TMP/home"
PROJ="$TMP/proj"
PLANS="$PROJ/.claude/plans"
mkdir -p "$HOME_DIR" "$PLANS"

run_hook() {
  local p="${1:-}"; [ -n "$p" ] || p='{}'
  printf '%s' "$p" | \
    DOTCLAUDE_REPO="$REPO" USAGE_LOG_HOME="$HOME_DIR" CLAUDE_PROJECT_DIR="$PROJ" \
    bash "$HOOK"
}
# count <prefix> <id> → nº de eventos use daquele id no log da prefix
count() {
  cat "$HOME_DIR"/telemetry/"$1"-usage.*.jsonl 2>/dev/null \
    | jq -r --arg id "$2" 'select(.dod_id==$id and .kind=="use") | .dod_id' 2>/dev/null \
    | wc -l | tr -d ' '
}
# sha_of <file> <id> → sha atual dos bullets (via a própria lib)
sha_of() {
  ( source "$REPO/bin/lib/usage-fold.sh"; dod_bullets_sha "$1" ) \
    | awk -F'\t' -v i="$2" '$1==i{print $2; exit}'
}
# got_sha <prefix> <id> → sha do 1º evento use emitido
got_sha() {
  cat "$HOME_DIR"/telemetry/"$1"-usage.*.jsonl 2>/dev/null \
    | jq -r --arg id "$2" 'select(.dod_id==$id and .kind=="use") | .sha' 2>/dev/null | head -1
}
ledger() { cat "$HOME_DIR"/cache/telemetry/processed-plans.* 2>/dev/null; }

mk() { printf '%s\n' "$2" > "$PLANS/$1"; }   # mk <file> <conteúdo>

# ─── 1. Pré-seed lazy: plano pré-existente NÃO conta; sentinela gravada ──────
mk "pre.md" "# pré-existente
- artefato X
<!-- dod-use: tarefa-1 -->"
run_hook '{}'; RC=$?
assert_eq "$RC" "0" "1 pré-seed exit 0"
assert_eq "$(count dod tarefa-1)" "0" "1 pré-seed NÃO emite (plano pré-existente)"
if ledger | grep -qxF "# preseeded:$PLANS"; then _pass; else _fail "1 sentinela do escopo planos gravada"; fi

# ─── 2. Plano NOVO emite 1 evento com o sha correto ─────────────────────────
mk "new1.md" "# novo
<!-- dod-use: tarefa-1 -->"
run_hook '{}'
assert_eq "$(count dod tarefa-1)" "1" "2 plano novo → 1 evento dod"
assert_eq "$(got_sha dod tarefa-1)" "$(sha_of "$DOD_CANON" tarefa-1)" "2 sha emitido == sha atual do DOD.md"

# ─── 3. Idempotência: re-rodar sem mudança NÃO re-emite ─────────────────────
run_hook '{}'
assert_eq "$(count dod tarefa-1)" "1" "3 idempotência (2ª execução não duplica)"

# ─── 4. Multiplicidade: tarefa-N por ocorrência; cat-N-base 1× ──────────────
mk "new2.md" "# multi
<!-- dod-use: tarefa-5 -->
texto
<!-- dod-use: tarefa-5 -->
<!-- dod-use: cat-1-base -->"
run_hook '{}'
assert_eq "$(count dod tarefa-5)" "2" "4 tarefa-5 contada 2× (multiplicidade preservada)"
assert_eq "$(count dod cat-1-base)" "1" "4 cat-1-base contada 1×"

# ─── 5. Twin test-spec: marcador no plano → evento test-spec ────────────────
mk "new3.md" "# specs
<!-- test-spec-use: tarefa-1 -->"
run_hook '{}'
assert_eq "$(count test-spec tarefa-1)" "1" "5 test-spec-use no plano → 1 evento test-spec"
assert_eq "$(got_sha test-spec tarefa-1)" "$(sha_of "$TS_CANON" tarefa-1)" "5 sha test-spec == sha do TEST-PATTERNS.md"

# ─── 6. ID inexistente no DOD.md → 0 eventos, exit 0 ────────────────────────
mk "new4.md" "# id ruim
<!-- dod-use: tarefa-99999 -->"
run_hook '{}'; RC=$?
assert_eq "$RC" "0" "6 id inexistente → exit 0"
assert_eq "$(count dod tarefa-99999)" "0" "6 id inexistente → 0 eventos"

# ─── 7. stop_hook_active=true → no-op (re-entrância) ────────────────────────
mk "new5.md" "# guard
<!-- dod-use: tarefa-7 -->"
run_hook '{"stop_hook_active":true}'; RC=$?
assert_eq "$RC" "0" "7 stop_hook_active exit 0"
assert_eq "$(count dod tarefa-7)" "0" "7 stop_hook_active → não emite"
# e depois, sem o guard, emite normalmente
run_hook '{}'
assert_eq "$(count dod tarefa-7)" "1" "7b sem guard → emite o plano pendente"

# ─── 8. Plano sem marcador → exit 0, nada quebra ────────────────────────────
mk "new6.md" "# sem marcador
só prosa, nenhum DoD"
run_hook '{}'; RC=$?
assert_eq "$RC" "0" "8 plano sem marcador → exit 0"

# ─── 9. Independência de cwd (roda de /tmp, paths via env) ──────────────────
mk "new7.md" "# cwd
<!-- dod-use: tarefa-8 -->"
( cd /tmp && printf '{}' | DOTCLAUDE_REPO="$REPO" USAGE_LOG_HOME="$HOME_DIR" \
    CLAUDE_PROJECT_DIR="$PROJ" bash "$HOOK" )
assert_eq "$(count dod tarefa-8)" "1" "9 emite correto mesmo rodando de outro cwd"

# ─── 10. Sem checkout dotclaude (DOTCLAUDE_REPO inválido) → no-op exit 0 ─────
printf '{}' | DOTCLAUDE_REPO="$TMP/inexistente" USAGE_LOG_HOME="$HOME_DIR" \
  CLAUDE_PROJECT_DIR="$PROJ" bash "$HOOK"; RC=$?
assert_eq "$RC" "0" "10 sem checkout → no-op exit 0"

# ─── Summary ────────────────────────────────────────────────────────────────
TOTAL=$((PASS + FAIL))
echo ""
echo "─── Resultado: $PASS/$TOTAL pass ──────────────────"
if [ "$FAIL" -gt 0 ]; then
  printf '%s\n' "$FAILED"
  exit 1
fi
exit 0

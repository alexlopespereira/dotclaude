#!/usr/bin/env bash
# tests/lib/test_smoke.sh — US-11 F10 coverage for smoke.sh
#
# AC8 (rev3 R15): cleanup_smoke defesa em profundidade
#   AC8a SMOKE='/'                          → exit 8 + mensagem; / não tocado
#   AC8b SMOKE=''                           → return 0 silencioso
#   AC8c SMOKE='/tmp/something-else'        → exit 8 (não bate whitelist)
# AC9 (rev3 R15): trap em INT/TERM dispara cleanup_smoke
#   smoke em background → SIGTERM → sandbox limpo após exit
#   (SIGINT não é exercido em background bash — vide AGENTS.md "Backgrounded
#    bash + SIGINT trap is broken by design"; TERM compartilha mesmo handler)
# Smoke e2e (AC1, AC4, AC5, AC7, AC10): rodar smoke.sh contra os mocks
#   → ≥2 DISPATCH; prd.json final all passes:true; SMOKE removido após exit;
#     pool real do usuário não tocado; SMOKE_VIOLATIONS=0 com mocks.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TESTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SKILL_DIR="$(cd "$TESTS_DIR/.." && pwd)"
SMOKE_SCRIPT="$SKILL_DIR/smoke.sh"

PASS=0
FAIL=0
FAILED=""

_fail() { FAIL=$((FAIL + 1)); FAILED="${FAILED}
  ✗ $1"; }
_pass() { PASS=$((PASS + 1)); }

assert_eq() {
    local actual="$1" expected="$2" msg="$3"
    if [ "$actual" = "$expected" ]; then _pass
    else _fail "$msg :: expected='$expected' actual='$actual'"; fi
}
assert_rc() {
    local rc="$1" expected="$2" msg="$3"
    if [ "$rc" = "$expected" ]; then _pass
    else _fail "$msg :: expected rc=$expected got rc=$rc"; fi
}
assert_contains() {
    local haystack="$1" needle="$2" msg="$3"
    case "$haystack" in
        *"$needle"*) _pass ;;
        *) _fail "$msg :: '$needle' not found" ;;
    esac
}
assert_ge() {
    local actual="$1" expected="$2" msg="$3"
    if [ "$actual" -ge "$expected" ] 2>/dev/null; then _pass
    else _fail "$msg :: expected actual($actual) >= $expected"; fi
}
assert_le() {
    local actual="$1" expected="$2" msg="$3"
    if [ "$actual" -le "$expected" ] 2>/dev/null; then _pass
    else _fail "$msg :: expected actual($actual) <= $expected"; fi
}
assert_file_absent() {
    local path="$1" msg="$2"
    if [ ! -e "$path" ]; then _pass
    else _fail "$msg :: $path still exists"; fi
}

# ─── AC8a: SMOKE='/' → exit 8, / não é tocado ──────────────────────────────
# cleanup_smoke é invocado em subshell para que `exit 8` não mate o test
# runner. Também asserto que `/etc` (proxy para "raiz não tocada") segue
# acessível após a chamada.

OUT=$(
    bash -c '
        set -u
        # Source smoke.sh sem rodar run_smoke (guarda BASH_SOURCE != $0).
        # Cf. smoke.sh tail: if [ "${BASH_SOURCE[0]}" = "${0}" ]; then run_smoke
        export RALPH_SMOKE_SOURCE_ONLY=1
        # shellcheck disable=SC1090
        . "'"$SMOKE_SCRIPT"'"
        SMOKE="/"
        cleanup_smoke
        echo "REACHED_AFTER_CLEANUP"
    ' 2>&1
)
RC=$?
assert_rc "$RC" 8 "AC8a SMOKE='/' returns exit 8"
assert_contains "$OUT" "ERROR: cleanup_smoke refusing to delete '/'" \
    "AC8a error message names the rejected path"
case "$OUT" in
    *"REACHED_AFTER_CLEANUP"*) _fail "AC8a cleanup must NOT continue past exit 8" ;;
    *) _pass ;;
esac
# Sanity: /etc still exists (smoke didn't actually rm /).
[ -d /etc ] && _pass || _fail "AC8a / appears to have been touched (catastrophic)"

# ─── AC8b: SMOKE='' → return 0 silencioso ──────────────────────────────────

OUT=$(
    bash -c '
        set -u
        # shellcheck disable=SC1090
        . "'"$SMOKE_SCRIPT"'"
        SMOKE=""
        cleanup_smoke
        echo "OK_EMPTY"
    ' 2>&1
)
RC=$?
assert_rc "$RC" 0 "AC8b SMOKE='' returns rc=0 (silent skip)"
assert_contains "$OUT" "OK_EMPTY" "AC8b execution continues past cleanup"
case "$OUT" in
    *ERROR*) _fail "AC8b emitted ERROR for empty SMOKE — should be silent" ;;
    *) _pass ;;
esac

# ─── AC8c: SMOKE='/tmp/something-else' → exit 8 (não bate whitelist) ───────

OUT=$(
    bash -c '
        set -u
        # shellcheck disable=SC1090
        . "'"$SMOKE_SCRIPT"'"
        SMOKE="/tmp/something-else"
        cleanup_smoke
        echo "REACHED_AFTER_CLEANUP"
    ' 2>&1
)
RC=$?
assert_rc "$RC" 8 "AC8c non-whitelist path returns exit 8"
assert_contains "$OUT" "ERROR: cleanup_smoke refusing to delete '/tmp/something-else'" \
    "AC8c error message names the rejected path"
case "$OUT" in
    *"REACHED_AFTER_CLEANUP"*) _fail "AC8c cleanup must NOT continue past exit 8" ;;
    *) _pass ;;
esac

# ─── AC8 positive: whitelist-match path is accepted and rm'd ───────────────
# Provisiona um diretório dummy sob /tmp/ralph-smoke.<rand> e prova que
# cleanup_smoke o remove sem erro. Garante que a regex aceita o caso real.

DUMMY=$(mktemp -d "/tmp/ralph-smoke.XXXXXXXX")
touch "$DUMMY/sentinel"
[ -e "$DUMMY/sentinel" ] && _pass || _fail "AC8-pos sentinel setup"

OUT=$(
    bash -c '
        set -u
        # shellcheck disable=SC1090
        . "'"$SMOKE_SCRIPT"'"
        SMOKE="'"$DUMMY"'"
        cleanup_smoke
        echo "OK_REMOVED"
    ' 2>&1
)
RC=$?
assert_rc "$RC" 0 "AC8-pos whitelist-prefixed path returns rc=0"
assert_contains "$OUT" "OK_REMOVED" "AC8-pos execution continues past cleanup"
assert_file_absent "$DUMMY" "AC8-pos sandbox actually removed"

# ─── AC9: trap em SIGTERM dispara cleanup; sandbox removido pós-exit ───────
# Smoke em background com state file. Esperamos ele provisionar (state file
# existe), enviamos TERM, esperamos exit, asserto que SMOKE removido.
#
# Nota AGENTS.md: bash em background herda SIGINT=SIG_IGN do parent; o
# trap interno NÃO sobrescreve. Em produção o usuário roda em foreground
# onde Ctrl-C entrega SIGINT normalmente. Em testes mandamos SIGTERM, que
# é roteado pelo MESMO handler body (ver smoke.sh — INT/TERM ambos fazem
# `cleanup_smoke; exit ...`).

STATE_FILE=$(mktemp -t ralph-smoke-state.XXXXXX)
LOG=$(mktemp -t ralph-smoke-log.XXXXXX)
# Para que o smoke PROVISIONE mas tenha tempo de receber TERM antes do
# orquestrador terminar, usamos delay nos mocks (FAKE_DELAY=10s por story).
# RALPH_HANG_TIMEOUT=60s mantém o orquestrador vivo pelo intervalo do TERM.
(
    export RALPH_SMOKE_STATE_FILE="$STATE_FILE"
    export FAKE_DELAY=10
    export RALPH_HANG_TIMEOUT=60
    export RALPH_REVIEW_TIMEOUT=60
    export RALPH_POLL_INTERVAL=1
    # `exec` replaces the subshell with bash so $! is the smoke PID directly
    # — without it, $! is the wrapping subshell and SIGTERM kills only the
    # wrapper, leaving the orphaned smoke + sandbox behind.
    exec bash "$SMOKE_SCRIPT"
) >"$LOG" 2>&1 &
SMOKE_PID=$!

# Espera até 30s pelo state file (provisionamento do bare + 3 clones leva 1-2s)
i=0
while [ $i -lt 60 ] && [ ! -s "$STATE_FILE" ]; do
    sleep 0.5
    i=$((i + 1))
done
SMOKE_PATH=$(cat "$STATE_FILE" 2>/dev/null)
case "$SMOKE_PATH" in
    /tmp/ralph-smoke.*|/private/var/folders/*|/var/folders/*) _pass ;;
    *) _fail "AC9 setup: SMOKE path absent or unexpected: '$SMOKE_PATH'" ;;
esac
[ -d "$SMOKE_PATH" ] && _pass || _fail "AC9 setup: sandbox dir absent before signal: $SMOKE_PATH"

# Manda SIGTERM (handler é o mesmo que INT — testa via TERM por causa do
# bash-background SIG_IGN). Aguarda processo morrer e checa cleanup.
kill -TERM "$SMOKE_PID" 2>/dev/null || true
wait "$SMOKE_PID" 2>/dev/null
SMOKE_RC=$?

# Exit code 143 = 128+15 (SIGTERM). Se o trap correu corretamente.
assert_eq "$SMOKE_RC" "143" "AC9 smoke exits 143 after SIGTERM (trap handler)"
assert_file_absent "$SMOKE_PATH" "AC9 sandbox removed after signal+cleanup"

rm -f "$STATE_FILE" "$LOG"

# ─── AC1+AC4+AC5+AC7+AC10 (e2e smoke contra mocks): smoke completa em <60s ─
# Smoke completo: provisiona, roda --parallel=2, espera todas as 3 stories
# mergearem, valida log + prd.json + ausência de strays + sandbox cleanup.
# Mocks têm FAKE_DELAY=0 default; cada review é serial (3 reviews ≈ instant).

STATE_FILE=$(mktemp -t ralph-smoke-state.XXXXXX)
LOG=$(mktemp -t ralph-smoke-log.XXXXXX)

# Capturamos o conteúdo do prd.json + DISPATCH count ANTES do cleanup
# rodar — usamos um trap-pre-cleanup hook via env: smoke roda, antes do
# trap final consumimos o estado por inspecionar o log que já foi escrito
# pelos componentes do orquestrador (que escreve para stderr). O LOG do
# smoke contém os events do log_event (escrito a stderr e capturado aqui).
# Para preservar prd.json final e workers/log paths, copiamos o conteúdo
# para um path FORA do sandbox antes do cleanup — usando RALPH_SMOKE_PRESERVE
# (hook leve em smoke.sh não existe; em vez disso, lemos o LOG_OUTPUT que
# captura tudo que o orquestrador escreve em stderr, que inclui SMOKE_VIOLATIONS).

START=$(date +%s)
(
    export RALPH_SMOKE_STATE_FILE="$STATE_FILE"
    export FAKE_DELAY=0
    export RALPH_HANG_TIMEOUT=60
    export RALPH_REVIEW_TIMEOUT=30
    export RALPH_POLL_INTERVAL=1
    export RALPH_SMOKE_MAX_ITER=3
    bash "$SMOKE_SCRIPT"
) >"$LOG" 2>&1
SMOKE_RC=$?
ELAPSED=$(( $(date +%s) - START ))

# AC6 sanity (smoke <30min): sob mocks deve ser <60s.
assert_le "$ELAPSED" 60 "AC6 smoke completed under 60s wall-clock (mocks)"

# AC7: sandbox removido após exit normal.
SMOKE_PATH=$(cat "$STATE_FILE" 2>/dev/null)
assert_file_absent "$SMOKE_PATH" "AC7 sandbox removed after smoke exit"

# rc=0 esperado quando todas as 3 stories mergearam.
assert_rc "$SMOKE_RC" 0 "AC e2e smoke returns rc=0 with mocks"

# AC1: ≥2 DISPATCH events no log (provando paralelismo) — pool=3 com cap=2,
# então a primeira tick despacha 2 simultâneo.
N_DISPATCH=$(grep -c '| DISPATCH |' "$LOG" 2>/dev/null || echo 0)
N_DISPATCH=$(echo "$N_DISPATCH" | head -1 | tr -d ' ')
assert_ge "$N_DISPATCH" 2 "AC1 ≥2 DISPATCH events in smoke log"

# AC10: SMOKE_VIOLATIONS line presente; com mocks delta-commit, strays=0.
N_VIOLATIONS_LINE=$(grep -c '| SMOKE_VIOLATIONS |' "$LOG" 2>/dev/null || echo 0)
N_VIOLATIONS_LINE=$(echo "$N_VIOLATIONS_LINE" | head -1 | tr -d ' ')
assert_ge "$N_VIOLATIONS_LINE" 1 "AC10 SMOKE_VIOLATIONS event emitted to log"
assert_contains "$(cat "$LOG")" "delta_strays=0" \
    "AC10 strays=0 with contract-compliant mocks (delta-commit)"

# AC3: refs efêmeras ralph/<story> deletadas após cada merge. smoke.sh emite
# stray_refs=N no SMOKE_VIOLATIONS event lendo `git for-each-ref refs/ralph/*`
# do orch slot. Mocks delta-commit + finalize_review com origin presente
# devem zerar refs (cada `update-ref -d` corre no caminho de sucesso).
assert_contains "$(cat "$LOG")" "stray_refs=0" \
    "AC3 ralph refs deleted after merge (no survivors in orch slot)"

# AC5: prd.json final 100% passes:true. smoke.sh emite passes=N/N no
# SMOKE_VIOLATIONS — assertion direta substitui o proxy rc=0 (que poderia
# passar mesmo se RALPH_SMOKE_MAX_ITER esgotasse com 2/3 stories completas).
assert_contains "$(cat "$LOG")" "passes=3/3" \
    "AC5 all 3 stories passes:true in final prd.json"

rm -f "$STATE_FILE" "$LOG"

# ─── Final report ──────────────────────────────────────────────────────────

echo ""
echo "─────────────────────────────────────────"
echo "test_smoke.sh: PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then
    printf '%s\n' "$FAILED"
    exit 1
fi
echo "  ✓ all assertions green"
exit 0

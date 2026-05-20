#!/bin/bash
# Behavioral fixture para US-02 AC5 + AC6 — addresses REQUEST_CHANGES finding
# (review-US-02-iter2-claude-sonnet.txt, P1 AC_COMPLIANCE).
#
# Exercita os code paths reais (não apenas o regex coberto por
# test_stream_timeout_detect.sh):
#   A) RALPH_API_TIMEOUT_RETRY=0 (dry-run): API_TIMEOUT_CANDIDATE → FALHA_COMMIT
#      fall-through + set_retry_count incrementado (AC5)
#   B) RALPH_API_TIMEOUT_RETRY=1, 1ª tentativa: API_TIMEOUT emitido,
#      set_retry_count INALTERADO, API_TIMEOUT_FILE incrementado (AC6 invariante)
#   C) RALPH_API_TIMEOUT_RETRY=1, budget esgotado: API_BUDGET_EXHAUSTED +
#      passes=ESCALATED_API_TIMEOUT (AC6 boundary)
#
# Estratégia: as funções helper e o bloco condicional são replicados aqui
# (linhas 431-463 e 578-606 de ralph-adversarial.sh). Sentinel greps detectam
# remoção de tags/contadores; manter sincronizado intencionalmente.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RALPH_SH="$SCRIPT_DIR/../ralph-adversarial.sh"

[ -f "$RALPH_SH" ] || { echo "FAIL: ralph-adversarial.sh não encontrado em $RALPH_SH"; exit 1; }

# Sentinels de drift — se qualquer dessas strings sumir, o script-alvo perdeu
# o comportamento que esta suíte assume. Aborta antes de rodar a lógica replicada.
for pattern in \
    'API_TIMEOUT_CANDIDATE' \
    'API_BUDGET_EXHAUSTED' \
    'ESCALATED_API_TIMEOUT' \
    'set_api_timeout_count' \
    'set_retry_count preserved'
do
    grep -q "$pattern" "$RALPH_SH" \
        || { echo "FAIL (drift): pattern '$pattern' ausente em ralph-adversarial.sh — atualizar test ou recuperar comportamento"; exit 1; }
done

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
cd "$TMP"

RETRY_FILE="$TMP/retry"
API_TIMEOUT_FILE="$TMP/api-timeout"
: > "$RETRY_FILE"
: > "$API_TIMEOUT_FILE"
: > progress.txt
cat > prd.json <<'EOF'
{ "userStories": [ { "id": "US-X", "passes": false } ] }
EOF

# Replica de ralph-adversarial.sh:431-463 — helpers de contador
get_retry_count() {
    local story_id="$1" count
    count=$(grep "^${story_id}:" "$RETRY_FILE" 2>/dev/null | tail -1 | cut -d: -f2 || true)
    echo "${count:-0}"
}
set_retry_count() {
    local story_id="$1" count="$2"
    grep -v "^${story_id}:" "$RETRY_FILE" > "${RETRY_FILE}.tmp" 2>/dev/null || true
    echo "${story_id}:${count}" >> "${RETRY_FILE}.tmp"
    mv "${RETRY_FILE}.tmp" "$RETRY_FILE"
}
get_api_timeout_count() {
    local story_id="$1" count
    count=$(grep "^${story_id}:" "$API_TIMEOUT_FILE" 2>/dev/null | tail -1 | cut -d: -f2 || true)
    echo "${count:-0}"
}
set_api_timeout_count() {
    local story_id="$1" count="$2"
    grep -v "^${story_id}:" "$API_TIMEOUT_FILE" > "${API_TIMEOUT_FILE}.tmp" 2>/dev/null || true
    echo "${story_id}:${count}" >> "${API_TIMEOUT_FILE}.tmp"
    mv "${API_TIMEOUT_FILE}.tmp" "$API_TIMEOUT_FILE"
}

# Replica de ralph-adversarial.sh:578-606 — bloco condicional FALHA_COMMIT /
# API_TIMEOUT. Mantém apenas o que muda comportamento observável.
run_block() {
    local STORY_ID="$1"
    local API_TIMEOUT_DETECTED="$2"
    local CURRENT_RETRIES; CURRENT_RETRIES=$(get_retry_count "$STORY_ID")
    local LAST_MSG="random commit without story id"
    local PRIMARY_AGENT="claude"

    if [[ "$LAST_MSG" != *"$STORY_ID"* ]]; then
        if [ "$API_TIMEOUT_DETECTED" = true ]; then
            if [ "$RALPH_API_TIMEOUT_RETRY" = "1" ]; then
                local CURRENT_API_TIMEOUTS NEXT_API_TIMEOUTS
                CURRENT_API_TIMEOUTS=$(get_api_timeout_count "$STORY_ID")
                if [ "$CURRENT_API_TIMEOUTS" -ge "$MAX_API_TIMEOUT_RETRIES" ]; then
                    echo "$(date -Iseconds) | API_BUDGET_EXHAUSTED | $STORY_ID | budget $MAX_API_TIMEOUT_RETRIES esgotado" >> progress.txt
                    jq --arg id "$STORY_ID" '(.userStories[] | select(.id == $id)).passes = "ESCALATED_API_TIMEOUT"' prd.json > prd.tmp && mv prd.tmp prd.json
                    return 0
                fi
                NEXT_API_TIMEOUTS=$((CURRENT_API_TIMEOUTS + 1))
                echo "$(date -Iseconds) | API_TIMEOUT | $STORY_ID | retry $NEXT_API_TIMEOUTS/$MAX_API_TIMEOUT_RETRIES (set_retry_count preserved)" >> progress.txt
                set_api_timeout_count "$STORY_ID" "$NEXT_API_TIMEOUTS"
                return 0
            else
                echo "$(date -Iseconds) | API_TIMEOUT_CANDIDATE | $STORY_ID | dry-run: regex match (RALPH_API_TIMEOUT_RETRY=0)" >> progress.txt
            fi
        fi
        echo "$(date -Iseconds) | FALHA_COMMIT | $STORY_ID | $PRIMARY_AGENT não produziu commit válido" >> progress.txt
        set_retry_count "$STORY_ID" "$((CURRENT_RETRIES + 1))"
    fi
}

FAIL=0
assert_grep() {
    local label="$1" needle="$2" file="$3"
    if ! grep -q "$needle" "$file" 2>/dev/null; then
        echo "FAIL ($label): esperado encontrar '$needle' em $file"
        FAIL=1
    fi
}
assert_no_grep() {
    local label="$1" needle="$2" file="$3"
    if grep -q "$needle" "$file" 2>/dev/null; then
        echo "FAIL ($label): NÃO esperava encontrar '$needle' em $file"
        FAIL=1
    fi
}
assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" != "$actual" ]; then
        echo "FAIL ($label): esperado='$expected' atual='$actual'"
        FAIL=1
    fi
}

# ─── Cenário A: dry-run default (AC5) ───────────────────────
: > progress.txt
: > "$RETRY_FILE"
: > "$API_TIMEOUT_FILE"
RALPH_API_TIMEOUT_RETRY=0
MAX_API_TIMEOUT_RETRIES=3
run_block "US-X" true

assert_grep    "A1" "API_TIMEOUT_CANDIDATE | US-X" progress.txt
assert_grep    "A2" "FALHA_COMMIT | US-X"          progress.txt
RETRY_VAL=$(grep "^US-X:" "$RETRY_FILE" 2>/dev/null | cut -d: -f2 || echo "0")
assert_eq      "A3 (set_retry_count incrementado em dry-run)" "1" "$RETRY_VAL"

# ─── Cenário B: active retry, 1ª tentativa (AC6 invariante) ─
: > progress.txt
: > "$RETRY_FILE"
: > "$API_TIMEOUT_FILE"
RALPH_API_TIMEOUT_RETRY=1
MAX_API_TIMEOUT_RETRIES=3
run_block "US-X" true

assert_grep    "B1" "API_TIMEOUT | US-X"           progress.txt
assert_grep    "B2 (nota set_retry_count preserved)" "set_retry_count preserved" progress.txt
assert_no_grep "B3 (FALHA_COMMIT não deve vazar em active retry)" "FALHA_COMMIT" progress.txt
assert_no_grep "B4 (API_TIMEOUT_CANDIDATE é exclusivo do dry-run)" "API_TIMEOUT_CANDIDATE" progress.txt
RETRY_VAL=$(grep "^US-X:" "$RETRY_FILE" 2>/dev/null | cut -d: -f2 || echo "")
assert_eq      "B5 (set_retry_count INALTERADO)" "" "$RETRY_VAL"
TIMEOUT_VAL=$(grep "^US-X:" "$API_TIMEOUT_FILE" 2>/dev/null | cut -d: -f2 || echo "")
assert_eq      "B6 (API_TIMEOUT_FILE incrementado para 1)" "1" "$TIMEOUT_VAL"

# ─── Cenário C: active retry, budget esgotado (AC6 boundary) ─
: > progress.txt
: > "$RETRY_FILE"
echo "US-X:3" > "$API_TIMEOUT_FILE"
cat > prd.json <<'EOF'
{ "userStories": [ { "id": "US-X", "passes": false } ] }
EOF
RALPH_API_TIMEOUT_RETRY=1
MAX_API_TIMEOUT_RETRIES=3
run_block "US-X" true

assert_grep    "C1" "API_BUDGET_EXHAUSTED | US-X"  progress.txt
assert_no_grep "C2 (sem API_TIMEOUT em iteração de esgotamento)" "API_TIMEOUT | US-X" progress.txt
PASSES_VAL=$(jq -r '.userStories[0].passes' prd.json)
assert_eq      "C3 (passes=ESCALATED_API_TIMEOUT)" "ESCALATED_API_TIMEOUT" "$PASSES_VAL"

# ─── Sanity: API_TIMEOUT_DETECTED=false não dispara nada ────
: > progress.txt
: > "$RETRY_FILE"
: > "$API_TIMEOUT_FILE"
RALPH_API_TIMEOUT_RETRY=0
MAX_API_TIMEOUT_RETRIES=3
run_block "US-X" false

assert_no_grep "D1 (sem detecção, nenhuma tag API_*)" "API_TIMEOUT" progress.txt
assert_grep    "D2 (apenas FALHA_COMMIT no path normal)" "FALHA_COMMIT | US-X" progress.txt

if [ "$FAIL" -ne 0 ]; then
    echo "stream-timeout behavior test: FAIL"
    exit 1
fi

echo "PASS: stream-timeout behavior — A (dry-run), B (active 1st retry), C (budget exhausted), D (no-detect baseline)"
exit 0

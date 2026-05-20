#!/bin/bash
# Test fixture: dual-output progress.txt + progress.jsonl (US-03).
# Cobre os 3 cenários da AC6:
#  (a) finding único → 1 linha JSON com array de 1 evidence
#  (b) 5 findings → 1 linha JSON com array de 5 evidences
#  (c) zero findings → linha com array vazio
#
# Também valida o schema completo (AC3): ts ISO-8601, event/story_id strings,
# evidences array, verdict string|null.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARSE_SH="$SCRIPT_DIR/../parse-verdict.sh"

command -v jq >/dev/null 2>&1 || { echo "FAIL: jq não instalado"; exit 1; }
[ -f "$PARSE_SH" ] || { echo "FAIL: parse-verdict.sh não encontrado em $PARSE_SH"; exit 1; }

# Sanity: o emit_progress_event precisa existir e mencionar progress.jsonl.
grep -qE 'progress\.jsonl' "$PARSE_SH" \
    || { echo "FAIL: parse-verdict.sh não menciona progress.jsonl"; exit 1; }
grep -qE '^emit_progress_event\(\)' "$PARSE_SH" \
    || { echo "FAIL: parse-verdict.sh não define emit_progress_event()"; exit 1; }

# Sanity de integração: ralph-adversarial.sh precisa CHAMAR emit_progress_event
# nos pontos REVIEW_* (REVIEW_BLOCK, REVIEW_REQUEST_CHANGES, REVIEW_UNKNOWN).
# Sem isso, progress.jsonl nunca é escrito durante operação normal — o que
# foi exatamente o gap apontado pelo reviewer da iteração anterior.
ORCH_SH="$SCRIPT_DIR/../ralph-adversarial.sh"
[ -f "$ORCH_SH" ] || { echo "FAIL: ralph-adversarial.sh não encontrado em $ORCH_SH"; exit 1; }
grep -qE 'emit_progress_event[[:space:]]+"REVIEW_' "$ORCH_SH" \
    || { echo "FAIL: ralph-adversarial.sh não chama emit_progress_event nos pontos REVIEW_*"; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
cd "$TMP"

# shellcheck disable=SC1090
source "$PARSE_SH"

FAIL=0

# Valida que linha JSONL é válida e bate o schema (AC3).
# Args: <jsonl_line> <expected_event> <expected_story_id> <expected_evidences_count> <expected_verdict_or_null>
assert_schema() {
    local label="$1" line="$2" exp_event="$3" exp_story="$4" exp_count="$5" exp_verdict="$6"
    if ! echo "$line" | jq -e . >/dev/null 2>&1; then
        echo "FAIL ($label): linha não é JSON válido: $line"
        FAIL=1; return
    fi
    # ts ISO-8601 (date -Iseconds): YYYY-MM-DDThh:mm:ss[+-]hh:mm
    if ! echo "$line" | jq -re '.ts' | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}([+-][0-9]{2}:?[0-9]{2}|Z)$'; then
        echo "FAIL ($label): ts não é ISO-8601: $(echo "$line" | jq -r .ts)"
        FAIL=1
    fi
    local got_event got_story got_count got_verdict_type got_verdict
    got_event=$(echo "$line" | jq -r .event)
    got_story=$(echo "$line" | jq -r .story_id)
    got_count=$(echo "$line" | jq -r '.evidences | length')
    got_verdict_type=$(echo "$line" | jq -r '.verdict | type')
    got_verdict=$(echo "$line" | jq -r '.verdict')
    [ "$got_event" = "$exp_event" ] || { echo "FAIL ($label): event=$got_event != $exp_event"; FAIL=1; }
    [ "$got_story" = "$exp_story" ] || { echo "FAIL ($label): story_id=$got_story != $exp_story"; FAIL=1; }
    [ "$got_count" = "$exp_count" ] || { echo "FAIL ($label): evidences count=$got_count != $exp_count"; FAIL=1; }
    # AC4: evidences é array.
    if ! echo "$line" | jq -e '.evidences | type == "array"' >/dev/null; then
        echo "FAIL ($label): evidences não é array"
        FAIL=1
    fi
    if [ "$exp_verdict" = "null" ]; then
        [ "$got_verdict_type" = "null" ] || { echo "FAIL ($label): verdict type=$got_verdict_type != null"; FAIL=1; }
    else
        [ "$got_verdict_type" = "string" ] && [ "$got_verdict" = "$exp_verdict" ] \
            || { echo "FAIL ($label): verdict=$got_verdict != $exp_verdict"; FAIL=1; }
    fi
}

# --- Cenário (a): 1 evidence ---
: > progress.txt
: > progress.jsonl
emit_progress_event "REVIEW_BLOCK" "US-A" "BLOCK" "single evidence string"
LINE_COUNT=$(wc -l < progress.jsonl | tr -d ' ')
if [ "$LINE_COUNT" != "1" ]; then
    echo "FAIL (a): esperava 1 linha em progress.jsonl, obteve $LINE_COUNT"
    FAIL=1
fi
LINE=$(head -1 progress.jsonl)
assert_schema "(a) single evidence" "$LINE" "REVIEW_BLOCK" "US-A" "1" "BLOCK"
# progress.txt mantém formato concat humano-legível.
if ! grep -qE '\| REVIEW_BLOCK \| US-A \| single evidence string$' progress.txt; then
    echo "FAIL (a): progress.txt não tem formato concat esperado"
    FAIL=1
fi

# --- Cenário (b): 5 evidences ---
: > progress.txt
: > progress.jsonl
EVS=$(printf 'ev1\nev2\nev3\nev4\nev5')
emit_progress_event "REVIEW_REQUEST_CHANGES" "US-B" "REQUEST_CHANGES" "$EVS"
LINE=$(head -1 progress.jsonl)
assert_schema "(b) 5 evidences" "$LINE" "REVIEW_REQUEST_CHANGES" "US-B" "5" "REQUEST_CHANGES"
# Valida ordem do array
if ! echo "$LINE" | jq -e '.evidences == ["ev1","ev2","ev3","ev4","ev5"]' >/dev/null; then
    echo "FAIL (b): ordem das evidences não preservada — got $(echo "$LINE" | jq -c .evidences)"
    FAIL=1
fi
# progress.txt: pipe-concat
if ! grep -qE '\| REVIEW_REQUEST_CHANGES \| US-B \| ev1\|ev2\|ev3\|ev4\|ev5$' progress.txt; then
    echo "FAIL (b): progress.txt concat com '|' não bate"
    FAIL=1
fi

# --- Cenário (c): zero evidences ---
: > progress.txt
: > progress.jsonl
emit_progress_event "MERGE" "US-C" "MERGE" ""
LINE=$(head -1 progress.jsonl)
assert_schema "(c) zero evidences" "$LINE" "MERGE" "US-C" "0" "MERGE"
if ! echo "$LINE" | jq -e '.evidences == []' >/dev/null; then
    echo "FAIL (c): evidences vazio não é array []"
    FAIL=1
fi

# --- Cenário extra: verdict vazio → null ---
: > progress.txt
: > progress.jsonl
emit_progress_event "ESCALAÇÃO" "US-D" "" "story falhou 3 vezes"
LINE=$(head -1 progress.jsonl)
assert_schema "(d) verdict null" "$LINE" "ESCALAÇÃO" "US-D" "1" "null"

if [ "$FAIL" -ne 0 ]; then
    echo "progress.jsonl dual-output test: FAIL"
    exit 1
fi

echo "PASS: dual-output emit_progress_event — (a) 1 evidence, (b) 5 evidences, (c) zero evidences, (d) verdict null, schema válido"
exit 0

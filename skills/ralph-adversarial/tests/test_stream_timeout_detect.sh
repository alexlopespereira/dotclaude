#!/bin/bash
# Test fixture: stream-timeout regex detection em ralph-adversarial.sh
# Cobre US-02 AC7:
#  (a) "API Error: Stream idle timeout"        → match
#  (b) "partial response received" sozinho      → NO match
#  (c) '"verdict": "partial"' (ac_trace tag)    → NO match
#  (d) "429" sozinho                            → NO match
#
# Estratégia: roda o mesmo regex usado em ralph-adversarial.sh sobre fixtures
# sintéticas e verifica o match. Não inicia o loop Ralph nem precisa de
# binários (claude/codex) — só valida o regex.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RALPH_SH="$SCRIPT_DIR/../ralph-adversarial.sh"

[ -f "$RALPH_SH" ] || { echo "FAIL: ralph-adversarial.sh não encontrado em $RALPH_SH"; exit 1; }

# Sanity: o script-alvo precisa conter a regex de detecção e as env vars.
# Se alguém remover/renomear, o teste falha aqui antes de validar comportamento.
grep -E 'API Error.*Stream idle timeout' "$RALPH_SH" >/dev/null \
    || { echo "FAIL: ralph-adversarial.sh não contém regex 'API Error.*Stream idle timeout'"; exit 1; }
grep -E 'RALPH_API_TIMEOUT_RETRY' "$RALPH_SH" >/dev/null \
    || { echo "FAIL: ralph-adversarial.sh não menciona RALPH_API_TIMEOUT_RETRY"; exit 1; }
grep -E 'MAX_API_TIMEOUT_RETRIES' "$RALPH_SH" >/dev/null \
    || { echo "FAIL: ralph-adversarial.sh não menciona MAX_API_TIMEOUT_RETRIES"; exit 1; }

# Mesmo regex usado em ralph-adversarial.sh. Se divergir, o sanity grep
# acima ainda passa mas este filtro pode dar comportamento diferente —
# mantenha sincronizado intencionalmente.
REGEX='API Error:[[:space:]]*Stream idle timeout'

check_match() {
    local label="$1" expected="$2" input="$3"
    local actual
    if echo "$input" | grep -qiE "$REGEX"; then
        actual=match
    else
        actual=nomatch
    fi
    if [ "$actual" != "$expected" ]; then
        echo "FAIL ($label): expected=$expected actual=$actual input=$input"
        return 1
    fi
    return 0
}

FAIL=0

# (a) API Error completa → match
check_match "a" match    'API Error: Stream idle timeout'                       || FAIL=1
# (b) "partial response received" isolada → NO match (false-positive evitado)
check_match "b" nomatch  'partial response received from upstream'              || FAIL=1
# (c) ac_trace tag '"verdict": "partial"' → NO match (false-positive evitado)
check_match "c" nomatch  '"verdict": "partial", "ac_trace": [...]'              || FAIL=1
# (d) "429" sozinho (HTTP code) → NO match (false-positive evitado)
check_match "d" nomatch  'HTTP 429 Too Many Requests'                            || FAIL=1

# Bonus: variações que devem casar (case-insensitive + espaços extras)
check_match "case-mixed"   match 'api error: stream idle timeout'               || FAIL=1
check_match "extra-spaces" match 'API Error:   Stream idle timeout (after 60s)' || FAIL=1
# Linha contextual no log real
check_match "log-context"  match 'claude: API Error: Stream idle timeout — exit 1' || FAIL=1

if [ "$FAIL" -ne 0 ]; then
    echo "stream-timeout detect test: FAIL"
    exit 1
fi

echo "PASS: stream-timeout detect — (a) API Error match, (b) partial response no match, (c) verdict tag no match, (d) 429 no match"
exit 0

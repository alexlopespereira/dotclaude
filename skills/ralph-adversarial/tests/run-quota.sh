#!/bin/bash
# Test runner for detect-quota.sh::is_codex_quota_error.
# Uses inline samples (positives and negatives) instead of fixture files.
# Exit status = number of failing tests.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DETECTOR="$SCRIPT_DIR/../detect-quota.sh"

# shellcheck source=../detect-quota.sh
source "$DETECTOR"

pass=0
fail=0
failures=()

assert_quota() {
    local name="$1" sample="$2"
    if is_codex_quota_error "$sample"; then
        printf "  PASS  %-45s → quota detected\n" "$name"
        pass=$((pass + 1))
    else
        printf "  FAIL  %-45s expected quota, got none\n" "$name"
        fail=$((fail + 1))
        failures+=("$name")
    fi
}

assert_no_quota() {
    local name="$1" sample="$2"
    if is_codex_quota_error "$sample"; then
        printf "  FAIL  %-45s false-positive quota\n" "$name"
        fail=$((fail + 1))
        failures+=("$name")
    else
        printf "  PASS  %-45s → no quota\n" "$name"
        pass=$((pass + 1))
    fi
}

# ── Positives ──────────────────────────────────────────────
assert_quota "openai-exceeded-quota" \
    "Error: 429 You exceeded your current quota, please check your plan and billing details."
assert_quota "insufficient_quota-json" \
    'error: {"type":"insufficient_quota","message":"..."}'
assert_quota "stream-429-too-many" \
    "stream error: unexpected status 429 Too Many Requests"
assert_quota "rate-limited-word" \
    "Request was rate-limited. Retry later."
assert_quota "rate-limit-hyphen" \
    "hit rate-limit on provider"
assert_quota "rate_limit_underscore" \
    "openai.RateLimitError: rate_limit_exceeded"
assert_quota "monthly-limit" \
    "You have reached your monthly limit for this plan."
assert_quota "daily-limit" \
    "daily limit reached for org-xxx"
assert_quota "usage-limit" \
    "usage limit exceeded on account"
assert_quota "quota-exhausted" \
    "OpenAI quota exhausted for this key."
assert_quota "quota-reached" \
    "Your quota has been reached."

# ── Positives: auth morta (Codex inutilizável por auth) ────
assert_quota "codex-token-expired" \
    '{"error":{"type":"token_expired"}}'
assert_quota "refresh-token-reused" \
    "The refresh token was already used"
assert_quota "refresh-token-reused-short" \
    "refresh token already used"
assert_quota "status-401-unauthorized" \
    'request https://chatgpt.com/backend-api/codex/responses failed with status 401 Unauthorized: {"detail":"Unauthorized"}'

# ── Negatives ──────────────────────────────────────────────
assert_no_quota "merge-verdict" \
    "## Verdict: MERGE — everything looks good."
assert_no_quota "block-verdict-bug" \
    "Finding P0 in src/auth.ts:42 — TypeError: undefined is not a function"
assert_no_quota "year-1429" \
    "The year 1429 marked an important event."
assert_no_quota "empty-diff" \
    "No changes to review."
assert_no_quota "codex-exec-failed-generic" \
    '{"verdict":"BLOCK","error":"codex_exec_failed"}'

# ── Negatives: quase-auth que NÃO deve disparar fallback ───
assert_no_quota "id-1401-unauthorized" \
    "1401 Unauthorized"
assert_no_quota "review-prose-token-expired" \
    "the session token expired handling is missing"
assert_no_quota "review-line-401" \
    "Finding P1: src/api.ts:401 returns Unauthorized without body"

echo
echo "---"
echo "Pass: $pass  Fail: $fail"
if [ "$fail" -gt 0 ]; then
    echo "Failures:"
    for f in "${failures[@]}"; do echo "  - $f"; done
fi
exit "$fail"

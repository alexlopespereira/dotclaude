#!/usr/bin/env bash
# tests/lib/test_validate_prd.sh — TDD coverage for validate-prd.sh +
# extract-deps-from-plan.sh (US-02 AC1-AC6).
#
# Inline assertion harness (no bats). Each block is annotated with the AC it
# exercises so commit ac_trace can reference test:line.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/../../lib" && pwd)"
FIXTURE_DIR="$(cd "$SCRIPT_DIR/../fixtures" && pwd)"

VALIDATOR="$LIB_DIR/validate-prd.sh"
EXTRACTOR="$LIB_DIR/extract-deps-from-plan.sh"

# shellcheck source=../../lib/dispatch.sh
. "$LIB_DIR/dispatch.sh"

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
        *) _fail "$msg :: '$needle' not found in '$haystack'" ;;
    esac
}
assert_not_contains() {
    local haystack="$1" needle="$2" msg="$3"
    case "$haystack" in
        *"$needle"*) _fail "$msg :: '$needle' unexpectedly found in '$haystack'" ;;
        *) _pass ;;
    esac
}

# ─── AC1: extract-deps-from-plan.sh recognises "depende de US-XX" ─────────
# The /prd-convert skill's markdown instructs Claude to feed each fatia's
# prose through this extractor and use the output as `dependsOn`.

# Single mention.
out=$(echo "Esta fatia depende de US-01." | "$EXTRACTOR")
assert_eq "$out" "US-01" "AC1 single 'depende de' → US-01"

# Multiple ids (comma + 'e' connector), plural verb.
out=$(echo "Depende das US-01, US-02 e US-03." | "$EXTRACTOR")
expected=$(printf 'US-01\nUS-02\nUS-03\n')
assert_eq "$out" "$expected" "AC1 'depende das ...' captures comma+e list"

# Case-insensitive on the verb.
out=$(echo "DEPENDE DOS US-07." | "$EXTRACTOR")
assert_eq "$out" "US-07" "AC1 uppercase verb still matched"

# No mention → empty output.
out=$(echo "Esta fatia é independente." | "$EXTRACTOR")
assert_eq "$out" "" "AC1 no mention → empty output"

# Empty input → empty output, rc=0.
out=$(printf '' | "$EXTRACTOR")
rc=$?
assert_rc "$rc" 0 "AC1 empty input → rc=0"
assert_eq "$out" "" "AC1 empty input → empty output"

# Full plan fixture: dedup across mentions, sort stable.
out=$("$EXTRACTOR" < "$FIXTURE_DIR/plan-with-deps.md")
expected=$(printf 'US-01\nUS-03\n')
assert_eq "$out" "$expected" "AC1 plan-with-deps.md → US-01, US-03 unique"

# ─── AC2: validator rejects cycle with clear message ─────────────────────
# Consumes the schema-valid cycle.json fixture authored by US-03 F3 AC4.
out=$("$VALIDATOR" "$FIXTURE_DIR/cycle.json" 2>&1)
rc=$?
assert_rc "$rc" 1 "AC2 cycle → rc=1"
assert_contains "$out" "ciclo detectado" "AC2 cycle msg contains 'ciclo detectado'"
assert_contains "$out" "US-01" "AC2 cycle msg names US-01"
assert_contains "$out" "US-02" "AC2 cycle msg names US-02"

# ─── AC3: dependsOn absent stays absent (Fase 1 compat) ──────────────────
# A prd.json with no dependsOn anywhere must validate cleanly. Schema permits
# the field to be missing (treated as []).
TMP_NODEP=$(mktemp_safe file ac3-nodep)
cat > "$TMP_NODEP" <<'JSON'
{
  "projectName": "fase1-compat",
  "userStories": [
    {
      "id": "US-A",
      "title": "Pre-Fase2 story",
      "acceptanceCriteria": ["AC1: dummy"],
      "priority": 1,
      "passes": false
    }
  ]
}
JSON
"$VALIDATOR" "$TMP_NODEP" >/dev/null 2>&1
assert_rc "$?" 0 "AC3 no dependsOn anywhere → rc=0 (Fase 1 compat)"
# And the file must be byte-for-byte unchanged.
TMP_BAK=$(mktemp_safe file ac3-bak)
cp "$TMP_NODEP" "$TMP_BAK"
"$VALIDATOR" "$TMP_NODEP" >/dev/null 2>&1
if cmp -s "$TMP_NODEP" "$TMP_BAK"; then _pass
else _fail "AC3 validator must not touch prd.json without --auto-recover"; fi
rm -f "$TMP_NODEP" "$TMP_BAK"

# ─── AC4: warn-only ESCALATED-vs-dep-OK (default mode) ───────────────────
TMP_PRD=$(mktemp_safe file ac4-warn)
cp "$FIXTURE_DIR/escalated-but-dep-ok.json" "$TMP_PRD"
TMP_BAK=$(mktemp_safe file ac4-bak)
cp "$TMP_PRD" "$TMP_BAK"

err=$("$VALIDATOR" "$TMP_PRD" 2>&1 >/dev/null)
rc=$?
assert_rc "$rc" 0 "AC4 warn-only → rc=0 (warning is not an error)"
assert_contains "$err" "WARN: US-B passes:ESCALATED com blocked_by:US-A; US-A está OK." \
    "AC4 exact warn message"

# prd.json must be byte-for-byte unchanged in warn-only mode.
if cmp -s "$TMP_PRD" "$TMP_BAK"; then _pass
else _fail "AC4 prd.json must be unchanged in warn-only mode (cmp failed)"; fi

# ─── AC5: --auto-recover applies revert ──────────────────────────────────
err=$("$VALIDATOR" --auto-recover "$TMP_PRD" 2>&1 >/dev/null)
rc=$?
assert_rc "$rc" 0 "AC5 --auto-recover → rc=0"
assert_contains "$err" "RECOVERED: US-B reverted to passes:false" \
    "AC5 RECOVERED message"
# B.passes is now boolean false.
b_passes=$(jq -r '.userStories[] | select(.id == "US-B") | .passes' "$TMP_PRD")
assert_eq "$b_passes" "false" "AC5 US-B passes reverted to false"
# escalation_reason removed.
b_reason=$(jq -r '.userStories[] | select(.id == "US-B") | has("escalation_reason")' "$TMP_PRD")
assert_eq "$b_reason" "false" "AC5 US-B escalation_reason removed"
# A untouched (was passes:true).
a_passes=$(jq -r '.userStories[] | select(.id == "US-A") | .passes' "$TMP_PRD")
assert_eq "$a_passes" "true" "AC5 US-A passes unchanged"

# Re-running the validator after recovery is a no-op (no inconsistencies left).
err2=$("$VALIDATOR" "$TMP_PRD" 2>&1 >/dev/null)
rc=$?
assert_rc "$rc" 0 "AC5 idempotent: re-run after recovery → rc=0"
assert_eq "$err2" "" "AC5 idempotent: re-run emits no WARN"
rm -f "$TMP_PRD" "$TMP_BAK"

# ─── AC6: dep still failing → no warning even with --auto-recover ────────
TMP_PRD=$(mktemp_safe file ac6-stillfail)
cp "$FIXTURE_DIR/escalated-and-dep-still-failed.json" "$TMP_PRD"
TMP_BAK=$(mktemp_safe file ac6-bak)
cp "$TMP_PRD" "$TMP_BAK"

# Default mode: no warning (dep is still passes:false).
err=$("$VALIDATOR" "$TMP_PRD" 2>&1 >/dev/null)
rc=$?
assert_rc "$rc" 0 "AC6 default → rc=0"
assert_not_contains "$err" "WARN" "AC6 default → no WARN (dep still failed)"
assert_not_contains "$err" "RECOVERED" "AC6 default → no RECOVERED"

# --auto-recover mode: still no warning, still no recovery, file untouched.
err=$("$VALIDATOR" --auto-recover "$TMP_PRD" 2>&1 >/dev/null)
rc=$?
assert_rc "$rc" 0 "AC6 --auto-recover → rc=0"
assert_not_contains "$err" "WARN" "AC6 --auto-recover → no WARN (dep still failed)"
assert_not_contains "$err" "RECOVERED" "AC6 --auto-recover → no RECOVERED"
if cmp -s "$TMP_PRD" "$TMP_BAK"; then _pass
else _fail "AC6 prd.json must be unchanged when dep still failed"; fi

# Confirm B is still ESCALATED.
b_passes=$(jq -r '.userStories[] | select(.id == "US-B") | .passes' "$TMP_PRD")
assert_eq "$b_passes" "ESCALATED" "AC6 US-B remains ESCALATED"
rm -f "$TMP_PRD" "$TMP_BAK"

# ─── Bonus: schema rejection (negative) ──────────────────────────────────
# A prd.json with a non-string dependsOn entry must fail schema check.
TMP_BADSCHEMA=$(mktemp_safe file bad-schema)
cat > "$TMP_BADSCHEMA" <<'JSON'
{
  "userStories": [
    {
      "id": "US-A",
      "title": "Bad",
      "acceptanceCriteria": ["AC1"],
      "priority": 1,
      "passes": false,
      "dependsOn": [123]
    }
  ]
}
JSON
out=$("$VALIDATOR" "$TMP_BADSCHEMA" 2>&1)
rc=$?
assert_rc "$rc" 1 "Schema: non-string dep entry → rc=1"
assert_contains "$out" "schema check" "Schema: error message names schema check"
rm -f "$TMP_BADSCHEMA"

# Bonus: unresolved dep id rejected.
TMP_UNRES=$(mktemp_safe file unresolved)
cat > "$TMP_UNRES" <<'JSON'
{
  "userStories": [
    {
      "id": "US-A",
      "title": "A",
      "acceptanceCriteria": ["AC1"],
      "priority": 1,
      "passes": false,
      "dependsOn": ["US-DOES-NOT-EXIST"]
    }
  ]
}
JSON
out=$("$VALIDATOR" "$TMP_UNRES" 2>&1)
rc=$?
assert_rc "$rc" 1 "Unresolved dep id → rc=1"
assert_contains "$out" "unresolved" "Unresolved dep error names 'unresolved'"
rm -f "$TMP_UNRES"

# Usage error on unknown flag.
out=$("$VALIDATOR" --bogus /tmp/whatever 2>&1)
rc=$?
assert_rc "$rc" 2 "Unknown flag → rc=2"

# ─── Report ──────────────────────────────────────────────────────────────
echo ""
echo "─────────────────────────────────────────────"
echo "PASS=$PASS  FAIL=$FAIL"
if [ $FAIL -gt 0 ]; then
    printf '%s\n' "$FAILED"
    exit 1
fi
exit 0

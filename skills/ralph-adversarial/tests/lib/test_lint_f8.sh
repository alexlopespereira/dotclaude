#!/usr/bin/env bash
# tests/lib/test_lint_f8.sh — US-09 / AC F8g mutation tests for the lint.
#
# AC F8g: lint multi-checks roda em CI, todos retornam 0 linhas em código
# limpo. Teste de mutação adiciona violação para cada check (uppercase
# HEAD_BEFORE_MERGE em outra função; head_before_merge fora da whitelist
# de funções; git reflog --since=x -- HEAD; mktemp -t prefix; mktemp
# template.XXXX) e assert que lint detecta cada um.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TESTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SKILL_DIR="$(cd "$TESTS_DIR/.." && pwd)"
LIB_DIR="$SKILL_DIR/lib"
LINT="$SCRIPT_DIR/lint-f8.sh"

# shellcheck source=../../lib/dispatch.sh
source "$LIB_DIR/dispatch.sh"

PASS=0
FAIL=0
FAILED=""

_pass() { PASS=$((PASS + 1)); }
_fail() { FAIL=$((FAIL + 1)); FAILED="${FAILED}
  ✗ $1"; }

assert_rc() {
    local rc="$1" want="$2" msg="$3"
    if [ "$rc" = "$want" ]; then _pass
    else _fail "$msg :: expected rc=$want got rc=$rc"; fi
}
assert_contains() {
    local hay="$1" needle="$2" msg="$3"
    case "$hay" in
        *"$needle"*) _pass ;;
        *) _fail "$msg :: '$needle' not found in '$hay'" ;;
    esac
}

# Run the lint over a custom set of target files (LINT_F8_TARGETS env).
run_lint_against() {
    LINT_F8_TARGETS="$*" bash "$LINT" 2>&1
}

# ─── Baseline: clean code → lint exits 0 ──────────────────────────────────

out=$(bash "$LINT" 2>&1); rc=$?
assert_rc "$rc" 0 "baseline: lint passes on clean code"

# ─── Mutation 1: uppercase HEAD_BEFORE_MERGE in another function ──────────

WORK=$(mktemp_safe dir lint-mut)
cp "$SKILL_DIR/ralph-adversarial.sh" "$WORK/ralph-adversarial.sh"
cp "$LIB_DIR/dispatch.sh"            "$WORK/dispatch.sh"

# Inject uppercase reference into ralph-adversarial.sh in a new helper —
# different function from merge_and_push_story.
cat >> "$WORK/ralph-adversarial.sh" <<'EOF'

bad_helper_check1() {
    local HEAD_BEFORE_MERGE
    HEAD_BEFORE_MERGE=$(git rev-parse HEAD)
    echo "$HEAD_BEFORE_MERGE"
}
EOF

out=$(run_lint_against "$WORK/ralph-adversarial.sh $WORK/dispatch.sh"); rc=$?
assert_rc "$rc" 1 "mut1 uppercase HEAD_BEFORE_MERGE → lint rc=1"
assert_contains "$out" "check1_uppercase_HEAD_BEFORE_MERGE" "mut1 lint flags check1"

rm -rf "$WORK"

# ─── Mutation 2: head_before_merge outside whitelist ──────────────────────

WORK=$(mktemp_safe dir lint-mut)
cp "$SKILL_DIR/ralph-adversarial.sh" "$WORK/ralph-adversarial.sh"
cp "$LIB_DIR/dispatch.sh"            "$WORK/dispatch.sh"

# (a) Reference in ralph-adversarial.sh (any reference outside dispatch.sh
#     trips check2_outside_dispatch).
cat >> "$WORK/ralph-adversarial.sh" <<'EOF'

stray_helper_check2() {
    local head_before_merge
    head_before_merge=$(git rev-parse HEAD)
    echo "$head_before_merge"
}
EOF

out=$(run_lint_against "$WORK/ralph-adversarial.sh $WORK/dispatch.sh"); rc=$?
assert_rc "$rc" 1 "mut2a head_before_merge in ralph-adversarial.sh → lint rc=1"
assert_contains "$out" "check2_head_before_merge_outside_dispatch" "mut2a flags outside-dispatch"

rm -rf "$WORK"

# (b) Reference in dispatch.sh but in a *different* function.
WORK=$(mktemp_safe dir lint-mut)
cp "$SKILL_DIR/ralph-adversarial.sh" "$WORK/ralph-adversarial.sh"
cp "$LIB_DIR/dispatch.sh"            "$WORK/dispatch.sh"

cat >> "$WORK/dispatch.sh" <<'EOF'

stray_dispatch_helper() {
    local head_before_merge
    head_before_merge=42
    echo "$head_before_merge"
}
EOF

out=$(run_lint_against "$WORK/ralph-adversarial.sh $WORK/dispatch.sh"); rc=$?
assert_rc "$rc" 1 "mut2b head_before_merge in dispatch.sh wrong fn → lint rc=1"
assert_contains "$out" "check2_head_before_merge_outside_whitelist" "mut2b flags wrong-fn"

rm -rf "$WORK"

# ─── Mutation 3: git reflog --since=x -- HEAD ─────────────────────────────

WORK=$(mktemp_safe dir lint-mut)
cp "$SKILL_DIR/ralph-adversarial.sh" "$WORK/ralph-adversarial.sh"
cp "$LIB_DIR/dispatch.sh"            "$WORK/dispatch.sh"

cat >> "$WORK/dispatch.sh" <<'EOF'

bad_reflog_check3() {
    git reflog --since=1.hour -- HEAD
}
EOF

out=$(run_lint_against "$WORK/ralph-adversarial.sh $WORK/dispatch.sh"); rc=$?
assert_rc "$rc" 1 "mut3 git reflog --since=x HEAD → lint rc=1"
assert_contains "$out" "check3_reflog_since_head" "mut3 flags check3"

rm -rf "$WORK"

# ─── Mutation 4: mktemp -t prefix ─────────────────────────────────────────

WORK=$(mktemp_safe dir lint-mut)
cp "$SKILL_DIR/ralph-adversarial.sh" "$WORK/ralph-adversarial.sh"
cp "$LIB_DIR/dispatch.sh"            "$WORK/dispatch.sh"

cat >> "$WORK/dispatch.sh" <<'EOF'

bad_mktemp_check4() {
    local f
    f=$(mktemp -t fakeprefix.XXXXXXXX)
    echo "$f"
}
EOF

out=$(run_lint_against "$WORK/ralph-adversarial.sh $WORK/dispatch.sh"); rc=$?
assert_rc "$rc" 1 "mut4 mktemp -t prefix → lint rc=1"
assert_contains "$out" "check4_mktemp_dash_t" "mut4 flags check4"

rm -rf "$WORK"

# ─── Mutation 5: mktemp template with fewer than 8 X's ────────────────────

WORK=$(mktemp_safe dir lint-mut)
cp "$SKILL_DIR/ralph-adversarial.sh" "$WORK/ralph-adversarial.sh"
cp "$LIB_DIR/dispatch.sh"            "$WORK/dispatch.sh"

cat >> "$WORK/dispatch.sh" <<'EOF'

bad_mktemp_check5() {
    local f
    f=$(mktemp /tmp/short-template.XXXX)
    echo "$f"
}
EOF

out=$(run_lint_against "$WORK/ralph-adversarial.sh $WORK/dispatch.sh"); rc=$?
assert_rc "$rc" 1 "mut5 mktemp template <8 X's → lint rc=1"
assert_contains "$out" "check5_mktemp_template_short" "mut5 flags check5"

rm -rf "$WORK"

# ─── Sanity: each mutation triggers exactly its own check (no cross-fire) ─
# Re-run each mutation in isolation and assert the lint output mentions only
# the expected check id (not the others). This guards against regex drift
# where one mutation accidentally satisfies multiple checks.

assert_isolated_check() {
    local mut_label="$1" expected_check="$2" mut_text="$3"
    local W
    W=$(mktemp_safe dir lint-iso)
    cp "$SKILL_DIR/ralph-adversarial.sh" "$W/ralph-adversarial.sh"
    cp "$LIB_DIR/dispatch.sh"            "$W/dispatch.sh"
    printf '%s\n' "$mut_text" >> "$W/dispatch.sh"
    local raw
    raw=$(run_lint_against "$W/ralph-adversarial.sh $W/dispatch.sh")
    case "$raw" in
        *"$expected_check"*) _pass ;;
        *) _fail "iso $mut_label: '$expected_check' missing in lint output" ;;
    esac
    # Make sure no OTHER check_id leaked. We grep for "checkN_" prefixes
    # other than the expected.
    local other check_ids
    check_ids="check1_ check2_ check3_ check4_ check5_"
    for other in $check_ids; do
        case "$expected_check" in
            ${other}*) continue ;;
        esac
        if printf '%s' "$raw" | grep -q "$other"; then
            _fail "iso $mut_label: cross-fire — $other unexpectedly flagged"
            rm -rf "$W"
            return
        fi
    done
    _pass
    rm -rf "$W"
}

# Note: mutation 2b is the "in dispatch.sh wrong fn" case; mut1 (uppercase)
# uses HEAD_BEFORE_MERGE in dispatch.sh in a different function, which would
# also trip check1; we keep it scoped to ralph-adversarial.sh in mut1 so
# only check1 fires there. For the isolation suite we add to dispatch.sh
# instead and accept that uppercase fires both check1 (uppercase rule) and
# may also touch check2 if matched by lowercase regex — but check1 matches
# the uppercase form only (\\bHEAD_BEFORE_MERGE\\b), and check2 matches
# lowercase only (\\bhead_before_merge\\b). So they are disjoint by case.

assert_isolated_check "mut3" "check3_reflog_since_head" '
iso_helper3() {
    git reflog --since=2.hours -- HEAD
}'

assert_isolated_check "mut4" "check4_mktemp_dash_t" '
iso_helper4() {
    local f
    f=$(mktemp -t somepfx.XXXXXXXX)
    echo "$f"
}'

assert_isolated_check "mut5" "check5_mktemp_template_short" '
iso_helper5() {
    local f
    f=$(mktemp /tmp/iso5.XXXXX)
    echo "$f"
}'

# ─── Report ───────────────────────────────────────────────────────────────

echo ""
echo "─────────────────────────────────────────────"
echo "PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then
    printf '%s\n' "$FAILED"
    exit 1
fi
exit 0

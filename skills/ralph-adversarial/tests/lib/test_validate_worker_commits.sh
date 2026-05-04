#!/usr/bin/env bash
# tests/lib/test_validate_worker_commits.sh — TDD coverage for the
# US-04 3-layer post-validation in lib/dispatch.sh.
#
# Each block annotated with the AC it exercises so commit ac_trace can
# point at file:line. Inline assertion harness; never `set -e` so all
# failures report.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TESTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SKILL_DIR="$(cd "$TESTS_DIR/.." && pwd)"
LIB_DIR="$SKILL_DIR/lib"
MOCKS_DIR="$TESTS_DIR/mocks"
IMPL_PROMPT="$SKILL_DIR/IMPL_PROMPT.md"

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
        *"$needle"*) _fail "$msg :: '$needle' unexpectedly found" ;;
        *) _pass ;;
    esac
}

# Helper: bootstrap a throwaway git repo with N empty base commits.
mk_repo() {
    local n_base="${1:-1}"
    local d
    d=$(mktemp_safe dir vwc-repo)
    (
        cd "$d"
        git init --quiet
        git config user.email "test@test.local"
        git config user.name  "test-runner"
        # Some macOS git installs default core.logAllRefUpdates=true at
        # the repo level, but defend explicitly so reflog is always on.
        git config core.logAllRefUpdates true
        local i=0
        while [ "$i" -lt "$n_base" ]; do
            git commit --allow-empty -m "base-$i" --quiet
            i=$((i + 1))
        done
    )
    echo "$d"
}

# Wide reflog window the tests use unless they specifically narrow it.
WIDE_LO=0
WIDE_HI=99999999999

# ─── AC1: FAKE_OUTCOME=commit (touches progress.txt) → Layer B rejects ────

REPO=$(mk_repo 1)
(
    cd "$REPO"
    HEAD_BEFORE=$(git rev-parse HEAD)
    FAKE_OUTCOME=commit FAKE_STORY_ID=US-AC1 \
        "$MOCKS_DIR/fake-claude.sh" '{"id":"US-AC1"}' >/dev/null 2>&1
    HEAD_AFTER=$(git rev-parse HEAD)
    echo "AC1_HEAD_BEFORE=$HEAD_BEFORE"
    echo "AC1_HEAD_AFTER=$HEAD_AFTER"
) > "$REPO/_out.txt" 2>&1
out=$(cat "$REPO/_out.txt")
hb=$(printf '%s\n' "$out" | sed -n 's/^AC1_HEAD_BEFORE=//p')
ha=$(printf '%s\n' "$out" | sed -n 's/^AC1_HEAD_AFTER=//p')
err=$(validate_worker_commits "$REPO" "$hb" "$ha" "$WIDE_LO" "$WIDE_HI" 2>&1)
rc=$?
assert_rc "$rc" 1 "AC1 commit-touches-progress → rc=1"
assert_contains "$err" "FORBIDDEN_DELTA" "AC1 Layer B emits FORBIDDEN_DELTA"
assert_contains "$err" "progress.txt"    "AC1 reason names progress.txt"
rm -rf "$REPO"

# ─── AC2: multi-commit-violation → Layer B iterates per commit, rejects ──

REPO=$(mk_repo 1)
(
    cd "$REPO"
    HEAD_BEFORE=$(git rev-parse HEAD)
    FAKE_OUTCOME=multi-commit-violation FAKE_STORY_ID=US-AC2 \
        "$MOCKS_DIR/fake-claude.sh" '{"id":"US-AC2"}' >/dev/null 2>&1
    HEAD_AFTER=$(git rev-parse HEAD)
    new_count=$(git rev-list --count "${HEAD_BEFORE}..HEAD")
    echo "AC2_HEAD_BEFORE=$HEAD_BEFORE"
    echo "AC2_HEAD_AFTER=$HEAD_AFTER"
    echo "AC2_NEW_COUNT=$new_count"
) > "$REPO/_out.txt" 2>&1
out=$(cat "$REPO/_out.txt")
assert_contains "$out" "AC2_NEW_COUNT=2" "AC2 mock produces 2 commits"
hb=$(printf '%s\n' "$out" | sed -n 's/^AC2_HEAD_BEFORE=//p')
ha=$(printf '%s\n' "$out" | sed -n 's/^AC2_HEAD_AFTER=//p')
err=$(validate_worker_commits "$REPO" "$hb" "$ha" "$WIDE_LO" "$WIDE_HI" 2>&1)
rc=$?
assert_rc "$rc" 1 "AC2 multi-commit → rc=1"
assert_contains "$err" "FORBIDDEN_DELTA" "AC2 Layer B detects per-commit"
assert_contains "$err" "progress.txt" "AC2 reason names progress.txt (commit-1)"
rm -rf "$REPO"

# ─── AC3: amend-violation → Layer A' detects 'commit (amend):' ────────────

REPO=$(mk_repo 1)
(
    cd "$REPO"
    HEAD_BEFORE=$(git rev-parse HEAD)
    FAKE_OUTCOME=amend-violation FAKE_STORY_ID=US-AC3 \
        "$MOCKS_DIR/fake-claude.sh" '{"id":"US-AC3"}' >/dev/null 2>&1
    HEAD_AFTER=$(git rev-parse HEAD)
    # Empirical guards (per AC3): post-amend rev-list does NOT contain
    # progress.txt; aggregate diff also does not. Only the reflog remembers.
    rev_list_files=$(git rev-list "${HEAD_BEFORE}..HEAD" \
        | xargs -I{} git show --name-only --pretty=format: {} | sort -u)
    diff_files=$(git diff --name-only "${HEAD_BEFORE}..HEAD" | sort -u | tr '\n' ' ')
    has_amend_in_reflog=$(git reflog show HEAD | grep -c 'commit (amend)')
    echo "AC3_HEAD_BEFORE=$HEAD_BEFORE"
    echo "AC3_HEAD_AFTER=$HEAD_AFTER"
    echo "AC3_REVLIST_HAS_PROGRESS=$(printf '%s\n' "$rev_list_files" | grep -c '^progress.txt$')"
    echo "AC3_DIFF=$diff_files"
    echo "AC3_AMEND_REFLOG=$has_amend_in_reflog"
) > "$REPO/_out.txt" 2>&1
out=$(cat "$REPO/_out.txt")
assert_contains "$out" "AC3_REVLIST_HAS_PROGRESS=0" \
    "AC3 empirical: rev-list post-amend does NOT contain progress.txt"
assert_contains "$out" "AC3_DIFF=work.txt" \
    "AC3 empirical: aggregate diff shows only work.txt"
assert_contains "$out" "AC3_AMEND_REFLOG=1" \
    "AC3 empirical: reflog has 'commit (amend)' entry"
hb=$(printf '%s\n' "$out" | sed -n 's/^AC3_HEAD_BEFORE=//p')
ha=$(printf '%s\n' "$out" | sed -n 's/^AC3_HEAD_AFTER=//p')
err=$(validate_worker_commits "$REPO" "$hb" "$ha" "$WIDE_LO" "$WIDE_HI" 2>&1)
rc=$?
assert_rc "$rc" 1 "AC3 amend-violation → rc=1"
assert_contains "$err" "HISTORY_REWRITE_DETECTED" \
    "AC3 Layer A' rejects with HISTORY_REWRITE_DETECTED"
assert_contains "$err" "amend" "AC3 reason mentions amend"
rm -rf "$REPO"

# ─── AC4: legit `git revert HEAD` — Layer A' silent, Layer B catches ──────
# Two-commit setup so the revert is a "regular" extra commit.

REPO=$(mk_repo 1)
(
    cd "$REPO"
    HEAD_BEFORE=$(git rev-parse HEAD)
    # commit-1: violation (touches progress.txt)
    printf 'violation by US-AC4\n' >> progress.txt
    git add progress.txt
    git commit -m "[US-AC4] commit-1 violation" --quiet
    # commit-2: legitimate revert of commit-1 (creates a NEW commit, not an
    # amend or reset). This also touches progress.txt to undo it; that is
    # expected — Layer B must still hit on commit-1 first.
    git revert HEAD --no-edit --quiet
    HEAD_AFTER=$(git rev-parse HEAD)
    new_count=$(git rev-list --count "${HEAD_BEFORE}..HEAD")
    has_amend=$(git reflog show HEAD | grep -c 'commit (amend)')
    has_reset=$(git reflog show HEAD | grep -c 'reset:')
    echo "AC4_HEAD_BEFORE=$HEAD_BEFORE"
    echo "AC4_HEAD_AFTER=$HEAD_AFTER"
    echo "AC4_NEW_COUNT=$new_count"
    echo "AC4_AMEND=$has_amend"
    echo "AC4_RESET=$has_reset"
) > "$REPO/_out.txt" 2>&1
out=$(cat "$REPO/_out.txt")
assert_contains "$out" "AC4_NEW_COUNT=2" "AC4 setup: 2 commits (violation + revert)"
assert_contains "$out" "AC4_AMEND=0"     "AC4 reflog has NO amend entry"
assert_contains "$out" "AC4_RESET=0"     "AC4 reflog has NO reset entry"
hb=$(printf '%s\n' "$out" | sed -n 's/^AC4_HEAD_BEFORE=//p')
ha=$(printf '%s\n' "$out" | sed -n 's/^AC4_HEAD_AFTER=//p')
err=$(validate_worker_commits "$REPO" "$hb" "$ha" "$WIDE_LO" "$WIDE_HI" 2>&1)
rc=$?
assert_rc "$rc" 1 "AC4 revert-on-violation → rc=1 (Layer B)"
assert_contains "$err" "FORBIDDEN_DELTA" "AC4 reject via Layer B (not A')"
assert_not_contains "$err" "HISTORY_REWRITE_DETECTED" \
    "AC4 Layer A' must NOT trip on a legit revert"
rm -rf "$REPO"

# ─── AC5: contract-respecting commit (only progress-<id>.txt) → passes ────

REPO=$(mk_repo 1)
(
    cd "$REPO"
    HEAD_BEFORE=$(git rev-parse HEAD)
    printf 'learning by US-AC5\n' >> progress-US-AC5.txt
    git add progress-US-AC5.txt
    git commit -m "[US-AC5] delta-only commit" --quiet
    HEAD_AFTER=$(git rev-parse HEAD)
    echo "AC5_HEAD_BEFORE=$HEAD_BEFORE"
    echo "AC5_HEAD_AFTER=$HEAD_AFTER"
) > "$REPO/_out.txt" 2>&1
out=$(cat "$REPO/_out.txt")
hb=$(printf '%s\n' "$out" | sed -n 's/^AC5_HEAD_BEFORE=//p')
ha=$(printf '%s\n' "$out" | sed -n 's/^AC5_HEAD_AFTER=//p')
err=$(validate_worker_commits "$REPO" "$hb" "$ha" "$WIDE_LO" "$WIDE_HI" 2>&1)
rc=$?
assert_rc "$rc" 0 "AC5 contract-respecting commit → rc=0"
assert_eq "$err" "" "AC5 no error message on stderr"
rm -rf "$REPO"

# Also verify per-id deltas with the agents-delta-<id>.md sibling pass.
REPO=$(mk_repo 1)
(
    cd "$REPO"
    HEAD_BEFORE=$(git rev-parse HEAD)
    printf 'gotcha\n' >> progress-US-AC5b.txt
    printf 'pattern\n' >> agents-delta-US-AC5b.md
    git add progress-US-AC5b.txt agents-delta-US-AC5b.md
    git commit -m "[US-AC5b] both deltas" --quiet
    HEAD_AFTER=$(git rev-parse HEAD)
    echo "AC5b_HB=$HEAD_BEFORE"
    echo "AC5b_HA=$HEAD_AFTER"
) > "$REPO/_out.txt" 2>&1
out=$(cat "$REPO/_out.txt")
hb=$(printf '%s\n' "$out" | sed -n 's/^AC5b_HB=//p')
ha=$(printf '%s\n' "$out" | sed -n 's/^AC5b_HA=//p')
validate_worker_commits "$REPO" "$hb" "$ha" "$WIDE_LO" "$WIDE_HI" >/dev/null 2>&1
assert_rc "$?" 0 "AC5b progress-<id>.txt + agents-delta-<id>.md → rc=0"
rm -rf "$REPO"

# ─── AC6: validate_worker_commits $ORCH ... → reject ──────────────────────

REPO=$(mk_repo 1)
HEAD=$(git -C "$REPO" rev-parse HEAD)
err=$(ORCH="$REPO" validate_worker_commits "$REPO" "$HEAD" "$HEAD" "$WIDE_LO" "$WIDE_HI" 2>&1)
rc=$?
assert_rc "$rc" 1 "AC6 slot==\$ORCH → rc=1"
assert_contains "$err" "slot inválido" "AC6 message: slot inválido"
assert_contains "$err" "orquestrador" "AC6 message: orquestrador"
# Sanity: same slot, with ORCH unset/different, must NOT trip the orch guard
# (head_before == head_after, no commits → returns 0).
err_ok=$(ORCH="" validate_worker_commits "$REPO" "$HEAD" "$HEAD" "$WIDE_LO" "$WIDE_HI" 2>&1)
rc_ok=$?
assert_rc "$rc_ok" 0 "AC6 ORCH unset → no guard trip on same slot"
assert_eq "$err_ok" "" "AC6 ORCH unset → no error"
rm -rf "$REPO"

# ─── AC7: IMPL_PROMPT.md has 3 clauses + tracked in git ────────────────────

[ -f "$IMPL_PROMPT" ] && _pass || _fail "AC7 IMPL_PROMPT.md exists"
content=$(cat "$IMPL_PROMPT")
assert_contains "$content" "Delta files"   "AC7 clause 1: Delta files"
assert_contains "$content" "No push"       "AC7 clause 2: No push"
assert_contains "$content" "No history rewrite" "AC7 clause 3: No history rewrite"
# File must be tracked by git (will show in `git log -- IMPL_PROMPT.md`
# after this commit lands; pre-commit, the file is at least tracked).
( cd "$SKILL_DIR" && git ls-files --error-unmatch IMPL_PROMPT.md >/dev/null 2>&1 )
assert_rc "$?" 0 "AC7 IMPL_PROMPT.md is tracked by git"

# ─── AC8: git-reset-violation → Layer A' detects 'reset:' ────────────────

REPO=$(mk_repo 2)
(
    cd "$REPO"
    HEAD_BEFORE=$(git rev-parse HEAD)
    FAKE_OUTCOME=git-reset-violation FAKE_STORY_ID=US-AC8 \
        "$MOCKS_DIR/fake-claude.sh" '{"id":"US-AC8"}' >/dev/null 2>&1
    HEAD_AFTER=$(git rev-parse HEAD)
    echo "AC8_HB=$HEAD_BEFORE"
    echo "AC8_HA=$HEAD_AFTER"
) > "$REPO/_out.txt" 2>&1
out=$(cat "$REPO/_out.txt")
hb=$(printf '%s\n' "$out" | sed -n 's/^AC8_HB=//p')
ha=$(printf '%s\n' "$out" | sed -n 's/^AC8_HA=//p')
err=$(validate_worker_commits "$REPO" "$hb" "$ha" "$WIDE_LO" "$WIDE_HI" 2>&1)
rc=$?
assert_rc "$rc" 1 "AC8 git-reset-violation → rc=1"
assert_contains "$err" "HISTORY_REWRITE_DETECTED" \
    "AC8 Layer A' rejects with HISTORY_REWRITE_DETECTED"
assert_contains "$err" "reset" "AC8 reason mentions reset"
rm -rf "$REPO"

# ─── AC9: orch_rebase WITHOUT with_validated_slot → INVARIANT VIOLATION ──

# Phase=uninit (no .slot-phase file at all).
SLOT=$(mktemp_safe dir slot-noinit)
out=$( ( orch_rebase "$SLOT" ) 2>&1 )
rc=$?
assert_rc "$rc" 1 "AC9 orch_rebase uninit → rc=1 (via die/exit 1)"
assert_contains "$out" "INVARIANT VIOLATION" "AC9 message: INVARIANT VIOLATION"
assert_contains "$out" "Layer A not done"    "AC9 message: Layer A not done"
# Sanity: explicit .slot-phase=uninit content also fails.
set_slot_phase "$SLOT" "uninit"
out=$( ( orch_rebase "$SLOT" ) 2>&1 )
rc=$?
assert_rc "$rc" 1 "AC9 explicit phase=uninit → rc=1"
assert_contains "$out" "INVARIANT VIOLATION" "AC9 explicit phase=uninit emits INVARIANT"
# Positive control: routed through with_validated_slot, orch_rebase succeeds.
SLOT2=$(mktemp_safe dir slot-good)
layer_a_validate() { return 0; }
with_validated_slot "$SLOT2" orch_rebase "$SLOT2" >/dev/null 2>&1
assert_rc "$?" 0 "AC9 positive: orch_rebase via wrapper → rc=0"
phase=$(get_slot_phase "$SLOT2")
assert_eq "$phase" "completed" "AC9 positive: phase=completed"
rm -rf "$SLOT" "$SLOT2"

# ─── AC10: commit-then-reset (zero-net) → A' rejects HISTORY_REWRITE ──────

REPO=$(mk_repo 1)
(
    cd "$REPO"
    HEAD_BEFORE=$(git rev-parse HEAD)
    FAKE_OUTCOME=commit-then-reset FAKE_STORY_ID=US-AC10 \
        "$MOCKS_DIR/fake-claude.sh" '{"id":"US-AC10"}' >/dev/null 2>&1
    HEAD_AFTER=$(git rev-parse HEAD)
    echo "AC10_HB=$HEAD_BEFORE"
    echo "AC10_HA=$HEAD_AFTER"
) > "$REPO/_out.txt" 2>&1
out=$(cat "$REPO/_out.txt")
hb=$(printf '%s\n' "$out" | sed -n 's/^AC10_HB=//p')
ha=$(printf '%s\n' "$out" | sed -n 's/^AC10_HA=//p')
# Pre-condition: SHAs equal (zero-net) — Layer A would short-circuit alone.
assert_eq "$hb" "$ha" "AC10 setup: HEAD_BEFORE == HEAD_AFTER (zero-net)"
err=$(validate_worker_commits "$REPO" "$hb" "$ha" "$WIDE_LO" "$WIDE_HI" 2>&1)
rc=$?
assert_rc "$rc" 1 "AC10 commit-then-reset → rc=1 (via Layer A')"
assert_contains "$err" "HISTORY_REWRITE_DETECTED" \
    "AC10 Layer A' rejects (covers Layer A SHA-blind case)"
rm -rf "$REPO"

# ─── AC11: die-vs-return semantics inside `$(...)` ────────────────────────
# Anti-pattern: `return 1` from a function inside a command-substitution
# subshell does NOT terminate the subshell. Following commands still run.
# Canonical: `die "..."` (which calls `exit 1`) DOES terminate the subshell.

# Sub-case A: anti-pattern — execution continues past the failing function.
buggy_validate_returns() { return 1; }
buggy_out=$( buggy_validate_returns; echo "AFTER_BUGGY" )
assert_contains "$buggy_out" "AFTER_BUGGY" \
    "AC11 anti-pattern: return 1 in subshell does NOT abort (BUG documented)"

# Sub-case B: canonical — die/exit 1 aborts the subshell immediately.
canonical_validate_dies() { die "validate failed"; }
canonical_out=$( canonical_validate_dies 2>/dev/null; echo "AFTER_CANON" )
assert_not_contains "$canonical_out" "AFTER_CANON" \
    "AC11 canonical: die/exit 1 aborts subshell (CORRECT)"

# Sub-case C: lib/dispatch.sh ships a die() helper for this convention.
type die >/dev/null 2>&1
assert_rc "$?" 0 "AC11 lib provides die() helper"

# ─── Report ───────────────────────────────────────────────────────────────

echo ""
echo "─────────────────────────────────────────────"
echo "PASS=$PASS  FAIL=$FAIL"
if [ $FAIL -gt 0 ]; then
    printf '%s\n' "$FAILED"
    exit 1
fi
exit 0

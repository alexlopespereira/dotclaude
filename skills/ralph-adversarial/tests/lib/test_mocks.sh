#!/usr/bin/env bash
# tests/lib/test_mocks.sh — TDD coverage for the fake-claude/fake-codex
# mocks (US-03 F3). Each block annotated with the AC it exercises so the
# commit ac_trace can reference test:line.
#
# Inline assertion harness (no bats); never set -e so all failures report.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TESTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SKILL_DIR="$(cd "$TESTS_DIR/.." && pwd)"
LIB_DIR="$SKILL_DIR/lib"
MOCKS_DIR="$TESTS_DIR/mocks"
FIXTURE_DIR="$TESTS_DIR/fixtures"
RALPH_SCRIPT="$SKILL_DIR/ralph-adversarial.sh"

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

# Helper: bootstrap a throwaway git repo with N empty base commits so
# `git checkout -B <branch>` and `git reset HEAD~1` resolve. Returns the
# path on stdout. Caller is responsible for `rm -rf`.
mk_repo() {
    local n_base="${1:-1}"
    local d
    d=$(mktemp_safe dir mock-repo)
    (
        cd "$d"
        git init --quiet
        git config user.email "test@test.local"
        git config user.name  "test-runner"
        local i=0
        while [ "$i" -lt "$n_base" ]; do
            git commit --allow-empty -m "base-$i" --quiet
            i=$((i + 1))
        done
    )
    echo "$d"
}

# ─── AC4: cycle.json fixture exists ────────────────────────────────────────
# Schema must be valid prd.json (for US-02 AC2 to consume it).

CYCLE_FIXTURE="$FIXTURE_DIR/cycle.json"
[ -f "$CYCLE_FIXTURE" ] && _pass || _fail "AC4 cycle.json fixture exists"
ids=$(jq -r '.userStories[].id' "$CYCLE_FIXTURE" 2>/dev/null | sort | tr '\n' ' ')
assert_eq "$ids" "US-01 US-02 " "AC4 cycle.json contains US-01 + US-02"
# Verify it really is a cycle (validator helper).
detect_dependsOn_cycle "$CYCLE_FIXTURE" 2>/dev/null
assert_rc "$?" 1 "AC4 cycle.json triggers detect_dependsOn_cycle"

# ─── AC2: multi-commit-violation produces 2 commits, only 1st touches progress.txt ──

REPO=$(mk_repo 1)
(
    cd "$REPO"
    BASE=$(git rev-parse HEAD)
    FAKE_OUTCOME=multi-commit-violation FAKE_STORY_ID=US-MC \
        "$MOCKS_DIR/fake-claude.sh" '{"id":"US-MC"}' >/dev/null 2>&1
    rc=$?
    [ "$rc" -eq 0 ] || { echo "MC_RC_FAIL=$rc"; exit 1; }
    # Exactly 2 commits added beyond BASE.
    new_count=$(git rev-list --count "${BASE}..HEAD")
    echo "MC_NEW_COUNT=$new_count"
    # Files touched in HEAD~1 (commit-1) and HEAD (commit-2).
    head1_files=$(git show --name-only --pretty=format: HEAD~1 | tr '\n' ' ')
    head_files=$(git show --name-only --pretty=format: HEAD | tr '\n' ' ')
    echo "MC_HEAD1_FILES=$head1_files"
    echo "MC_HEAD_FILES=$head_files"
) > "$REPO/_out.txt" 2>&1
out=$(cat "$REPO/_out.txt")
assert_contains "$out" "MC_NEW_COUNT=2" "AC2 multi-commit produces 2 commits"
assert_contains "$out" "MC_HEAD1_FILES=progress.txt work.txt " \
    "AC2 commit-1 touches progress.txt + work.txt"
assert_contains "$out" "MC_HEAD_FILES=work.txt " \
    "AC2 commit-2 touches only work.txt"
assert_not_contains "$out" "MC_HEAD_FILES=progress.txt" \
    "AC2 commit-2 must NOT touch progress.txt"
rm -rf "$REPO"

# ─── AC3a: conflict-trivial produces a commit on a unique line ────────────

REPO=$(mk_repo 1)
(
    cd "$REPO"
    BASE=$(git rev-parse HEAD)
    # Pre-seed shared file so trivial == append, not create.
    printf 'placeholder line\n' > work.txt
    git add work.txt
    git commit -m "seed work.txt" --quiet
    BASE2=$(git rev-parse HEAD)
    FAKE_OUTCOME=conflict-trivial FAKE_STORY_ID=US-T1 \
        "$MOCKS_DIR/fake-claude.sh" '{"id":"US-T1"}' >/dev/null 2>&1
    new_count=$(git rev-list --count "${BASE2}..HEAD")
    echo "TRIV_NEW_COUNT=$new_count"
    # work.txt should now have placeholder + 1 appended line.
    line_count=$(wc -l < work.txt | tr -d ' ')
    echo "TRIV_LINES=$line_count"
    msg=$(git log -1 --format=%s)
    echo "TRIV_MSG=$msg"
) > "$REPO/_out.txt" 2>&1
out=$(cat "$REPO/_out.txt")
assert_contains "$out" "TRIV_NEW_COUNT=1" "AC3 trivial produces 1 commit"
assert_contains "$out" "TRIV_LINES=2" "AC3 trivial appends a line"
assert_contains "$out" "TRIV_MSG=[US-T1] conflict-trivial" \
    "AC3 trivial commit message tagged"
rm -rf "$REPO"

# ─── AC3b: conflict-overlap rewrites the same line deterministically ──────

REPO=$(mk_repo 1)
(
    cd "$REPO"
    # Seed with 3 lines so we can target line 2.
    printf 'one\ntwo\nthree\n' > work.txt
    git add work.txt
    git commit -m "seed 3 lines" --quiet
    BASE=$(git rev-parse HEAD)
    FAKE_OUTCOME=conflict-overlap FAKE_LINE=2 FAKE_STORY_ID=US-O1 \
        "$MOCKS_DIR/fake-claude.sh" '{"id":"US-O1"}' >/dev/null 2>&1
    line2_after=$(sed -n '2p' work.txt)
    new_count=$(git rev-list --count "${BASE}..HEAD")
    echo "OVL_NEW_COUNT=$new_count"
    echo "OVL_LINE2=$line2_after"
    # Lines 1 and 3 must be untouched.
    line1=$(sed -n '1p' work.txt)
    line3=$(sed -n '3p' work.txt)
    echo "OVL_LINE1=$line1"
    echo "OVL_LINE3=$line3"
) > "$REPO/_out.txt" 2>&1
out=$(cat "$REPO/_out.txt")
assert_contains "$out" "OVL_NEW_COUNT=1" "AC3 overlap produces 1 commit"
assert_contains "$out" "OVL_LINE2=overlap from US-O1" \
    "AC3 overlap rewrites the targeted line"
assert_contains "$out" "OVL_LINE1=one" "AC3 overlap leaves line 1 intact"
assert_contains "$out" "OVL_LINE3=three" "AC3 overlap leaves line 3 intact"
rm -rf "$REPO"

# Determinism: two runs with the same FAKE_STORY_ID produce identical output
# (so two workers would collide on the same row → real merge conflict).
REPO=$(mk_repo 1)
(
    cd "$REPO"
    printf 'a\nb\nc\n' > work.txt
    git add work.txt
    git commit -m "seed" --quiet
    FAKE_OUTCOME=conflict-overlap FAKE_LINE=2 FAKE_STORY_ID=US-X \
        "$MOCKS_DIR/fake-claude.sh" '{"id":"US-X"}' >/dev/null 2>&1
    snapshot1=$(sed -n '2p' work.txt)
    git reset --hard HEAD~1 --quiet
    FAKE_OUTCOME=conflict-overlap FAKE_LINE=2 FAKE_STORY_ID=US-X \
        "$MOCKS_DIR/fake-claude.sh" '{"id":"US-X"}' >/dev/null 2>&1
    snapshot2=$(sed -n '2p' work.txt)
    echo "OVL_DET_S1=$snapshot1"
    echo "OVL_DET_S2=$snapshot2"
) > "$REPO/_out.txt" 2>&1
out=$(cat "$REPO/_out.txt")
s1=$(printf '%s\n' "$out" | sed -n 's/^OVL_DET_S1=//p')
s2=$(printf '%s\n' "$out" | sed -n 's/^OVL_DET_S2=//p')
assert_eq "$s1" "$s2" "AC3 overlap is deterministic for same story id"
rm -rf "$REPO"

# ─── AC5: amend-violation hides progress.txt from rev-list, leaves it in reflog ──

REPO=$(mk_repo 1)
(
    cd "$REPO"
    BASE=$(git rev-parse HEAD)
    FAKE_OUTCOME=amend-violation FAKE_STORY_ID=US-AM \
        "$MOCKS_DIR/fake-claude.sh" '{"id":"US-AM"}' >/dev/null 2>&1
    new_count=$(git rev-list --count "${BASE}..HEAD")
    echo "AM_NEW_COUNT=$new_count"
    # Reflog must contain exactly one 'commit (amend):' entry.
    amend_lines=$(git reflog show HEAD | grep -c 'commit (amend)')
    echo "AM_AMEND_COUNT=$amend_lines"
    # Reflog must also contain the original 'commit:' entry.
    commit_lines=$(git reflog show HEAD | grep -cE 'commit:[[:space:]]\[US-AM\]')
    echo "AM_COMMIT_COUNT=$commit_lines"
    # rev-list HEAD..BASE walks the *current* DAG only; progress.txt must
    # be invisible in HEAD's tree (it was rm'd in the amend).
    has_progress=$(git ls-tree -r HEAD --name-only | grep -c '^progress.txt$')
    echo "AM_HAS_PROGRESS=$has_progress"
    # work.txt survives.
    has_work=$(git ls-tree -r HEAD --name-only | grep -c '^work.txt$')
    echo "AM_HAS_WORK=$has_work"
    # Files in HEAD's diff vs BASE: only work.txt — progress.txt is gone.
    diff_files=$(git diff --name-only "${BASE}..HEAD" | sort | tr '\n' ' ')
    echo "AM_DIFF=$diff_files"
) > "$REPO/_out.txt" 2>&1
out=$(cat "$REPO/_out.txt")
assert_contains "$out" "AM_NEW_COUNT=1" "AC5 amend leaves rev-list with 1 new SHA"
assert_contains "$out" "AM_AMEND_COUNT=1" "AC5 reflog has 'commit (amend):' entry"
assert_contains "$out" "AM_COMMIT_COUNT=1" "AC5 reflog still has original 'commit:' entry"
assert_contains "$out" "AM_HAS_PROGRESS=0" "AC5 HEAD tree no longer contains progress.txt"
assert_contains "$out" "AM_HAS_WORK=1"     "AC5 HEAD tree retains work.txt"
assert_contains "$out" "AM_DIFF=work.txt"  "AC5 diff vs BASE shows only work.txt"
rm -rf "$REPO"

# ─── AC6: hang-with-mcp spawns 2 sleep children under the bash -c parent ──

# Cleanup helper kills any sleep PIDs the test may have leaked.
_ac6_cleanup() {
    local mock_pid="$1" bash_pid="$2"
    [ -n "$bash_pid" ] && pgrep -P "$bash_pid" 2>/dev/null | while read -r s; do
        kill -KILL "$s" 2>/dev/null || true
    done
    [ -n "$bash_pid" ]  && kill -KILL "$bash_pid"  2>/dev/null || true
    [ -n "$mock_pid" ]  && kill -KILL "$mock_pid"  2>/dev/null || true
    wait 2>/dev/null || true
}

FAKE_OUTCOME=hang-with-mcp "$MOCKS_DIR/fake-codex.sh" >/dev/null 2>&1 &
mock_pid=$!
# Give the script time to fork bash -c and the two sleeps.
sleep 0.5
bash_pid=$(pgrep -P "$mock_pid" 2>/dev/null | head -1)
if [ -z "$bash_pid" ]; then
    _fail "AC6 fake-codex hang-with-mcp: no bash -c child of mock_pid=$mock_pid"
else
    _pass
    n_sleeps=$(pgrep -P "$bash_pid" 2>/dev/null | wc -l | tr -d ' ')
    assert_eq "$n_sleeps" "2" "AC6 hang-with-mcp spawns exactly 2 sleep children"
fi
_ac6_cleanup "$mock_pid" "$bash_pid"

# ─── AC7: commit-then-reset leaves HEAD unchanged (zero-net) ──────────────

REPO=$(mk_repo 1)
(
    cd "$REPO"
    HEAD_BEFORE=$(git rev-parse HEAD)
    FAKE_OUTCOME=commit-then-reset FAKE_STORY_ID=US-ZR \
        "$MOCKS_DIR/fake-claude.sh" '{"id":"US-ZR"}' >/dev/null 2>&1
    HEAD_AFTER=$(git rev-parse HEAD)
    echo "ZR_BEFORE=$HEAD_BEFORE"
    echo "ZR_AFTER=$HEAD_AFTER"
    # Reflog must show both 'commit:' (the transient) and 'reset:' entries.
    has_commit=$(git reflog show HEAD | grep -cE 'commit:[[:space:]]\[US-ZR\]')
    has_reset=$(git reflog show HEAD | grep -c 'reset:')
    echo "ZR_REFLOG_COMMIT=$has_commit"
    echo "ZR_REFLOG_RESET=$has_reset"
) > "$REPO/_out.txt" 2>&1
out=$(cat "$REPO/_out.txt")
zr_before=$(printf '%s\n' "$out" | sed -n 's/^ZR_BEFORE=//p')
zr_after=$(printf '%s\n' "$out"  | sed -n 's/^ZR_AFTER=//p')
assert_eq "$zr_before" "$zr_after" "AC7 HEAD_BEFORE == HEAD_AFTER (zero-net)"
assert_contains "$out" "ZR_REFLOG_COMMIT=1" "AC7 reflog records the transient commit"
assert_contains "$out" "ZR_REFLOG_RESET=1"  "AC7 reflog records the reset"
rm -rf "$REPO"

# ─── AC8: git-reset-violation produces 'reset:' reflog entry ──────────────

# Need ≥ 2 commits so HEAD~1 resolves.
REPO=$(mk_repo 2)
(
    cd "$REPO"
    HEAD_BEFORE=$(git rev-parse HEAD)
    PARENT=$(git rev-parse HEAD~1)
    FAKE_OUTCOME=git-reset-violation FAKE_STORY_ID=US-GR \
        "$MOCKS_DIR/fake-claude.sh" '{"id":"US-GR"}' >/dev/null 2>&1
    rc=$?
    HEAD_AFTER=$(git rev-parse HEAD)
    echo "GR_RC=$rc"
    echo "GR_HEAD_AFTER=$HEAD_AFTER"
    echo "GR_PARENT=$PARENT"
    # HEAD must have moved back to PARENT.
    if [ "$HEAD_AFTER" = "$PARENT" ]; then
        echo "GR_MOVED=yes"
    else
        echo "GR_MOVED=no (was $HEAD_BEFORE → $HEAD_AFTER, expected $PARENT)"
    fi
    has_reset=$(git reflog show HEAD | grep -c 'reset:')
    echo "GR_REFLOG_RESET=$has_reset"
) > "$REPO/_out.txt" 2>&1
out=$(cat "$REPO/_out.txt")
assert_contains "$out" "GR_RC=0"           "AC8 git-reset-violation rc=0"
assert_contains "$out" "GR_MOVED=yes"      "AC8 HEAD moved to HEAD~1"
assert_contains "$out" "GR_REFLOG_RESET=1" "AC8 reflog gains 'reset:' entry"
rm -rf "$REPO"

# ─── Negative: unknown FAKE_OUTCOME exits 2 ───────────────────────────────

err=$(FAKE_OUTCOME=garbage "$MOCKS_DIR/fake-claude.sh" 'prompt' 2>&1)
rc=$?
assert_rc "$rc" 2 "Negative: unknown FAKE_OUTCOME → rc=2"
assert_contains "$err" "unknown FAKE_OUTCOME" "Negative: error message names the bad value"

# ─── fake-codex MERGE / BLOCK / REQUEST_CHANGES verdicts ──────────────────

for v in MERGE BLOCK REQUEST_CHANGES; do
    out=$(FAKE_VERDICT=$v "$MOCKS_DIR/fake-codex.sh" 'review prompt')
    assert_contains "$out" "## Verdict: $v" "fake-codex emits '## Verdict: $v'"
done

# ─── AC1: full serial run with both mocks completes < 10s ─────────────────
# (Last block — long-running git operations.)

REPO=$(mk_repo 1)
cat > "$REPO/prd.json" <<JSON
{
  "projectName": "mock-ac1",
  "branchName": "test-mock-ac1",
  "userStories": [
    {
      "id": "US-MOCK",
      "title": "AC1 e2e mock test",
      "acceptanceCriteria": ["AC1: mock works end-to-end"],
      "priority": 1,
      "passes": false
    }
  ]
}
JSON

start=$(date +%s)
(
    cd "$REPO"
    export RALPH_AGENT_BIN="$MOCKS_DIR/fake-claude.sh"
    export RALPH_REVIEWER_BIN="$MOCKS_DIR/fake-codex.sh"
    export FAKE_OUTCOME=commit
    export FAKE_VERDICT=MERGE
    export RALPH_HANG_TIMEOUT=15
    bash "$RALPH_SCRIPT" 2
) > "$REPO/_run.log" 2>&1
rc=$?
elapsed=$(( $(date +%s) - start ))

assert_rc "$rc" 0 "AC1 e2e exit 0"
passes=$(jq -r '.userStories[0].passes' "$REPO/prd.json" 2>/dev/null)
assert_eq "$passes" "true" "AC1 e2e marks story passes:true"
if [ "$elapsed" -lt 10 ]; then
    _pass
else
    _fail "AC1 e2e elapsed < 10s (was ${elapsed}s) — log: $REPO/_run.log"
fi
rm -rf "$REPO"

# ─── Report ───────────────────────────────────────────────────────────────

echo ""
echo "─────────────────────────────────────────────"
echo "PASS=$PASS  FAIL=$FAIL"
if [ $FAIL -gt 0 ]; then
    printf '%s\n' "$FAILED"
    exit 1
fi
exit 0

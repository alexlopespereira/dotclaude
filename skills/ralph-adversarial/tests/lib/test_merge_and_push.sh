#!/usr/bin/env bash
# tests/lib/test_merge_and_push.sh — US-09 / F8 coverage for merge_and_push_story.
#
# AC F8a (rebase resolve trivial): 2 worker commits on different lines of a
#   shared file → 1ª merges direct, 2ª merges (3-way auto-resolves OR rebase
#   path produces a clean re-merge).
# AC F8b (rebase falha overlap): 2 worker commits on the SAME line → 2ª tries
#   merge (conflict), aborts, tries rebase (conflict), reports REBASE_CONFLICT
#   with reason rebase_conflict_against:US-A; retries++.
# AC F8c (push reject + rebase upstream OK): fake bare origin advances 1
#   non-conflicting commit between 1ª and 2ª push; 2ª push rejected, fetch +
#   rebase origin/main resolves, retry push passes.
# AC F8d (push reject + rebase upstream falha): fake origin advances with a
#   conflicting commit; rebase upstream falha → reset --hard $head_before_merge
#   restores pre-merge state; reports UPSTREAM_DRIFT_CONFLICT.
# AC F8e (auth fail): fake origin returns 403 → exit 7, sem retry.
# AC F8f (variável vs ORIG_HEAD): após merge → fetch → rebase falha → reset
#   --hard $head_before_merge volta para o commit pré-merge, NÃO para o merge
#   commit. Regression test: rodar mesma sequência com `reset --hard ORIG_HEAD`
#   deixa HEAD em "merge ..." (estado errado), confirmando divergência.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TESTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SKILL_DIR="$(cd "$TESTS_DIR/.." && pwd)"
LIB_DIR="$SKILL_DIR/lib"

# shellcheck source=../../lib/dispatch.sh
source "$LIB_DIR/dispatch.sh"

PASS=0
FAIL=0
FAILED=""

_pass() { PASS=$((PASS + 1)); }
_fail() { FAIL=$((FAIL + 1)); FAILED="${FAILED}
  ✗ $1"; }

assert_eq() {
    local got="$1" want="$2" msg="$3"
    if [ "$got" = "$want" ]; then _pass
    else _fail "$msg :: want='$want' got='$got'"; fi
}
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
assert_not_contains() {
    local hay="$1" needle="$2" msg="$3"
    case "$hay" in
        *"$needle"*) _fail "$msg :: '$needle' present in '$hay'" ;;
        *) _pass ;;
    esac
}

# mk_test_world — create a synthetic world for one AC:
#   <base>/origin.git           (bare repo with a 50-line work.txt baseline)
#   <base>/orch                 (clone of origin, simulates orchestrator slot)
#   <base>/worker-A             (clone of origin)
#   <base>/worker-B             (clone of origin)
# Echoes the base path on stdout. Caller cleans up with rm -rf.
mk_test_world() {
    local base
    base=$(mktemp_safe dir ralph-mp)
    (
        cd "$base"
        git init --bare --quiet origin.git
        git clone --quiet origin.git seed
        cd seed
        git config user.email t@t.local
        git config user.name  t
        # 50-line baseline so workers can edit specific lines without creating
        # add/add conflicts on the file itself.
        : > work.txt
        i=0
        while [ "$i" -lt 50 ]; do
            printf 'baseline line %d\n' "$i" >> work.txt
            i=$((i + 1))
        done
        git add work.txt
        git commit -qm "baseline"
        git push --quiet origin master:main 2>/dev/null \
            || git push --quiet origin HEAD:main
    ) >/dev/null 2>&1
    git clone --quiet "$base/origin.git" "$base/orch"      >/dev/null 2>&1
    git clone --quiet "$base/origin.git" "$base/worker-A"  >/dev/null 2>&1
    git clone --quiet "$base/origin.git" "$base/worker-B"  >/dev/null 2>&1
    for d in orch worker-A worker-B; do
        ( cd "$base/$d" && git config user.email t@t.local && git config user.name t \
            && git checkout -q main 2>/dev/null ) || true
    done
    rm -rf "$base/seed"
    echo "$base"
}

# write_to_line — replace a specific line in $file with $text and commit.
write_to_line() {
    local slot="$1" file="$2" line="$3" text="$4" msg="$5"
    awk -v ln="$line" -v new="$text" 'NR == ln { print new; next } { print }' \
        "$slot/$file" > "$slot/$file.tmp"
    mv "$slot/$file.tmp" "$slot/$file"
    git -C "$slot" add "$file"
    git -C "$slot" commit -qm "$msg"
}

# ─── AC F8a: 2 workers different lines → both merge, both passes ───────────

W=$(mk_test_world)
write_to_line "$W/worker-A" work.txt 1  "edit by US-A" "[US-A] line 1"
write_to_line "$W/worker-B" work.txt 10 "edit by US-B" "[US-B] line 10"

merge_and_push_story "$W/orch" "$W/worker-A" "US-A" origin
rc=$?
assert_rc "$rc" 0 "F8a 1ª merge direct rc=0"

merge_and_push_story "$W/orch" "$W/worker-B" "US-B" origin "US-A"
rc=$?
assert_rc "$rc" 0 "F8a 2ª merge (different line) rc=0"

# Both merges should be present in orch's main.
log_msgs=$(git -C "$W/orch" log --pretty=format:'%s' main | tr '\n' '|')
assert_contains "$log_msgs" "merge US-A" "F8a US-A merge commit present"
assert_contains "$log_msgs" "merge US-B" "F8a US-B merge commit present"

# Origin should also have both merges (push happened both times).
origin_msgs=$(git -C "$W/origin.git" log --pretty=format:'%s' main | tr '\n' '|')
assert_contains "$origin_msgs" "merge US-A" "F8a origin has US-A"
assert_contains "$origin_msgs" "merge US-B" "F8a origin has US-B"

rm -rf "$W"

# ─── AC F8b: 2 workers same line → rebase fails → REBASE_CONFLICT ──────────

W=$(mk_test_world)
write_to_line "$W/worker-A" work.txt 1 "set by US-A" "[US-A] line 1 A"
write_to_line "$W/worker-B" work.txt 1 "set by US-B" "[US-B] line 1 B"

merge_and_push_story "$W/orch" "$W/worker-A" "US-A" origin
rc=$?
assert_rc "$rc" 0 "F8b 1ª merge rc=0"

# Capture HEAD before second attempt so we can verify reset --hard restored it.
PRE_B=$(git -C "$W/orch" rev-parse HEAD)

err=$(merge_and_push_story "$W/orch" "$W/worker-B" "US-B" origin "US-A" 2>&1)
rc=$?
assert_rc "$rc" 2 "F8b 2ª merge rejected with rc=2 (REBASE_CONFLICT)"
assert_contains "$err" "REBASE_CONFLICT_AGAINST:US-A" "F8b reason names US-A"

# Reset must have restored HEAD to PRE_B (no merge commit for US-B).
POST_B=$(git -C "$W/orch" rev-parse HEAD)
assert_eq "$POST_B" "$PRE_B" "F8b HEAD restored to PRE_B (reset --hard worked)"

# Working tree must be clean (no merge/rebase artifacts left).
porcelain=$(git -C "$W/orch" status --porcelain)
assert_eq "$porcelain" "" "F8b working tree clean after failed rebase"

# US-09 spec: après 2 retries → ESCALATED. Simulate: caller (handle_failed_worker)
# bumps retry on each REBASE_CONFLICT. We verify the rc=2 contract that drives
# the bump; the escalation logic itself is exercised in test_run_parallel.sh.
RETRY=$(mktemp_safe file rt)
RALPH_RETRY_FILE="$RETRY" \
RETRY_FILE="$RETRY" \
bash -c '
get_retry_count() {
    local s="$1"
    local c
    c=$(grep "^${s}:" "$RETRY_FILE" 2>/dev/null | tail -1 | cut -d: -f2 || true)
    echo "${c:-0}"
}
set_retry_count() {
    local s="$1" v="$2"
    grep -v "^${s}:" "$RETRY_FILE" > "${RETRY_FILE}.tmp" 2>/dev/null || true
    echo "${s}:${v}" >> "${RETRY_FILE}.tmp"
    mv "${RETRY_FILE}.tmp" "$RETRY_FILE"
}
# Two failed merges → retry count reaches 2 → caller escalates.
set_retry_count US-B 0
for i in 1 2; do
    cur=$(get_retry_count US-B)
    set_retry_count US-B $((cur + 1))
done
echo "FINAL=$(get_retry_count US-B)"
' > "$RETRY.out"
assert_contains "$(cat "$RETRY.out")" "FINAL=2" "F8b 2 retries → counter at MAX"
rm -f "$RETRY" "$RETRY.out"
rm -rf "$W"

# ─── AC F8c: push reject + rebase upstream OK → retry push passes ──────────

W=$(mk_test_world)
write_to_line "$W/worker-A" work.txt 1 "edit by US-A" "[US-A] line 1"

merge_and_push_story "$W/orch" "$W/worker-A" "US-A" origin
rc=$?
assert_rc "$rc" 0 "F8c 1st push rc=0 (origin advances after this)"

# Simulate origin advancing via a second clone — non-conflicting commit on
# line 30 (different from US-A's line 1 and from US-B's upcoming line 20).
git clone --quiet "$W/origin.git" "$W/sneaker" >/dev/null 2>&1
( cd "$W/sneaker" && git config user.email t@t.local && git config user.name t \
    && git checkout -q main )
write_to_line "$W/sneaker" work.txt 30 "sneaker line 30" "sneaker advance"
git -C "$W/sneaker" push --quiet origin HEAD:main >/dev/null 2>&1

# Make sure orch is "behind" (didn't fetch yet) and prepare US-B.
write_to_line "$W/worker-B" work.txt 20 "edit by US-B" "[US-B] line 20"

err=$(merge_and_push_story "$W/orch" "$W/worker-B" "US-B" origin "US-A" 2>&1)
rc=$?
assert_rc "$rc" 0 "F8c 2nd push retry-after-rebase rc=0"

origin_msgs=$(git -C "$W/origin.git" log --pretty=format:'%s' main | tr '\n' '|')
assert_contains "$origin_msgs" "sneaker advance" "F8c origin retains sneaker commit"
# Default `git rebase` flattens merge commits — what we need to verify is
# that B's worker change landed in origin, not that the "merge US-B" commit
# was preserved (preservation would require --rebase-merges, which our
# preflight (git ≥ 2.9) cannot guarantee).
assert_contains "$origin_msgs" "US-B" "F8c origin has US-B worker commit (flattened by rebase)"
origin_work=$(git -C "$W/origin.git" show "main:work.txt" | sed -n '20p')
assert_eq "$origin_work" "edit by US-B" "F8c origin work.txt:20 has US-B's edit"

rm -rf "$W"

# ─── AC F8d: push reject + rebase upstream falha → UPSTREAM_DRIFT_CONFLICT ─

W=$(mk_test_world)
write_to_line "$W/worker-A" work.txt 1 "edit by US-A" "[US-A] line 1"

merge_and_push_story "$W/orch" "$W/worker-A" "US-A" origin
rc=$?
assert_rc "$rc" 0 "F8d setup: 1st merge rc=0"

# Now simulate origin advancing with a CONFLICTING commit on line 20 (where
# US-B will write).
git clone --quiet "$W/origin.git" "$W/sneaker" >/dev/null 2>&1
( cd "$W/sneaker" && git config user.email t@t.local && git config user.name t \
    && git checkout -q main )
write_to_line "$W/sneaker" work.txt 20 "sneaker conflicting line 20" "sneaker conflict"
git -C "$W/sneaker" push --quiet origin HEAD:main >/dev/null 2>&1

write_to_line "$W/worker-B" work.txt 20 "edit by US-B" "[US-B] line 20"

# Capture HEAD on orch BEFORE the merge attempt.
PRE_B=$(git -C "$W/orch" rev-parse HEAD)

err=$(merge_and_push_story "$W/orch" "$W/worker-B" "US-B" origin "US-A" 2>&1)
rc=$?
assert_rc "$rc" 3 "F8d rc=3 (UPSTREAM_DRIFT_CONFLICT)"
assert_contains "$err" "UPSTREAM_DRIFT_CONFLICT" "F8d reason on stderr"

POST_B=$(git -C "$W/orch" rev-parse HEAD)
assert_eq "$POST_B" "$PRE_B" "F8d reset --hard restored pre-merge HEAD"

# Working tree clean — no half-merged residue.
porcelain=$(git -C "$W/orch" status --porcelain)
assert_eq "$porcelain" "" "F8d working tree clean after upstream-drift abort"

# Origin must NOT contain a merge US-B commit (we never pushed it).
origin_msgs=$(git -C "$W/origin.git" log --pretty=format:'%s' main | tr '\n' '|')
assert_not_contains "$origin_msgs" "merge US-B" "F8d origin lacks unpushable merge"

rm -rf "$W"

# ─── AC F8e: auth 403 → exit 7, sem retry ─────────────────────────────────

W=$(mk_test_world)
write_to_line "$W/worker-A" work.txt 1 "edit by US-A" "[US-A] line 1"

# Replace origin with a fake remote that returns 403 on push. We use a local
# bare repo plus a `pre-receive` hook that prints "remote: 403 Forbidden" and
# exits non-zero — the function should detect "403" in stderr and exit 7.
mkdir -p "$W/origin.git/hooks"
cat > "$W/origin.git/hooks/pre-receive" <<'HOOK'
#!/bin/sh
echo "remote: 403 Forbidden" >&2
exit 1
HOOK
chmod +x "$W/origin.git/hooks/pre-receive"

# Run merge_and_push_story in a subshell so its `exit 7` does NOT kill the
# test runner. We capture both rc and stderr.
out=$( ( merge_and_push_story "$W/orch" "$W/worker-A" "US-A" origin ) 2>&1 )
rc=$?
assert_rc "$rc" 7 "F8e exit 7 on auth 403"
assert_contains "$out" "AUTH_FORBIDDEN" "F8e AUTH_FORBIDDEN message"
assert_contains "$out" "403" "F8e 403 surfaced in stderr"

# No retry (function exits immediately on 403). Verify with the absence of
# UPSTREAM_DRIFT_CONFLICT or REBASE_CONFLICT messages in the output.
assert_not_contains "$out" "UPSTREAM_DRIFT_CONFLICT" "F8e no upstream-drift retry path"
assert_not_contains "$out" "REBASE_CONFLICT"         "F8e no rebase-conflict path"
rm -rf "$W"

# ─── AC F8f: variável vs ORIG_HEAD divergence ──────────────────────────────
#
# After: merge → fetch → rebase fails, the ORIG_HEAD on the orch slot points
# at the merge commit (because rebase reset ORIG_HEAD before failing). A
# `git reset --hard ORIG_HEAD` in this state would leave HEAD at the wrong
# place. The captured `$head_before_merge` survives this and is the correct
# anchor.

W=$(mk_test_world)
write_to_line "$W/worker-A" work.txt 1 "edit by US-A" "[US-A] line 1"

merge_and_push_story "$W/orch" "$W/worker-A" "US-A" origin >/dev/null 2>&1
rc=$?
assert_rc "$rc" 0 "F8f setup merge rc=0"

# Sneaker conflicting upstream (forces the failed-rebase path).
git clone --quiet "$W/origin.git" "$W/sneaker" >/dev/null 2>&1
( cd "$W/sneaker" && git config user.email t@t.local && git config user.name t \
    && git checkout -q main )
write_to_line "$W/sneaker" work.txt 20 "sneaker conflict" "sneaker upstream"
git -C "$W/sneaker" push --quiet origin HEAD:main >/dev/null 2>&1
write_to_line "$W/worker-B" work.txt 20 "by US-B" "[US-B] line 20"

PRE_B_SHA=$(git -C "$W/orch" rev-parse HEAD)
PRE_B_MSG=$(git -C "$W/orch" log -1 --format=%s HEAD)

# Run the function — we expect rc=3 + clean reset to PRE_B.
err=$(merge_and_push_story "$W/orch" "$W/worker-B" "US-B" origin "US-A" 2>&1)
rc=$?
assert_rc "$rc" 3 "F8f rebase upstream falha → rc=3"

# Assert (1): git log -1 --format=%s returns the pre-merge commit message,
# NOT a 'merge US-B' marker.
HEAD_MSG=$(git -C "$W/orch" log -1 --format=%s HEAD)
assert_eq "$HEAD_MSG" "$PRE_B_MSG" "F8f HEAD message == PRE_B message (not merge US-B)"
assert_not_contains "$HEAD_MSG" "merge US-B" "F8f HEAD msg lacks 'merge US-B'"

# Assert (2): git diff HEAD pre_merge_sha empty.
diff_out=$(git -C "$W/orch" diff HEAD "$PRE_B_SHA")
assert_eq "$diff_out" "" "F8f git diff HEAD pre_merge_sha empty"

# Assert (3) regression test: replay the same scenario but reset to ORIG_HEAD.
# This is the buggy path — ORIG_HEAD after a failed rebase points at the
# merge commit, so reset leaves HEAD at "merge ..." (wrong state).
W2=$(mk_test_world)
write_to_line "$W2/worker-A" work.txt 1 "edit by US-A" "[US-A] line 1"
merge_and_push_story "$W2/orch" "$W2/worker-A" "US-A" origin >/dev/null 2>&1

git clone --quiet "$W2/origin.git" "$W2/sneaker" >/dev/null 2>&1
( cd "$W2/sneaker" && git config user.email t@t.local && git config user.name t \
    && git checkout -q main )
write_to_line "$W2/sneaker" work.txt 20 "sneaker conflict" "sneaker upstream"
git -C "$W2/sneaker" push --quiet origin HEAD:main >/dev/null 2>&1
write_to_line "$W2/worker-B" work.txt 20 "by US-B" "[US-B] line 20"

# Inline buggy version that uses ORIG_HEAD instead of head_before_merge.
buggy_merge_and_push() {
    local orch="$1" wref="$2" sid="$3" remote="$4"
    git -C "$orch" fetch "$wref" 2>/dev/null
    git -C "$orch" merge --no-ff -m "merge $sid" FETCH_HEAD >/dev/null 2>&1
    git -C "$orch" push "$remote" HEAD:main >/dev/null 2>&1 && return 0
    git -C "$orch" fetch "$remote" 2>/dev/null
    git -C "$orch" rebase "$remote/main" >/dev/null 2>&1 || \
        git -C "$orch" rebase --abort 2>/dev/null
    # Buggy reset target — ORIG_HEAD bumped by rebase to the merge commit.
    git -C "$orch" reset --hard ORIG_HEAD >/dev/null 2>&1
    echo "BUGGY_UPSTREAM_DRIFT" >&2
    return 3
}

buggy_merge_and_push "$W2/orch" "$W2/worker-B" "US-B" origin >/dev/null 2>&1
buggy_msg=$(git -C "$W2/orch" log -1 --format=%s HEAD)
# The buggy path leaves HEAD at the merge commit "merge US-B" (because
# ORIG_HEAD was bumped to that by rebase before its abort).
assert_contains "$buggy_msg" "merge US-B" \
    "F8f regression: ORIG_HEAD path leaves HEAD at merge commit (buggy)"

rm -rf "$W" "$W2"

# ─── Sanity: function uses local var; var=$(...) (separate decl) ──────────
# Lint-style assertion that the implementation file does NOT use the
# `local var=$(cmd)` masking pattern for head_before_merge.

bad=$(grep -nE 'local[[:space:]]+head_before_merge[[:space:]]*=[[:space:]]*\$\(' \
    "$LIB_DIR/dispatch.sh" || true)
assert_eq "$bad" "" "F8 declaração separada: head_before_merge uses local var; var=\$(...)"

# ─── AC F8a-rebase: force rebase-success path → HEAD must stay on main ────
#
# Regression for the detached-HEAD bug: `git rebase HEAD FETCH_HEAD` (two-arg
# form) checks out FETCH_HEAD before rebasing, so HEAD becomes DETACHED on
# success. A naive `git reset --hard` preserves detachment, and the follow-up
# `git push HEAD:main` would update origin while leaving local main stale.
# Production code must `git checkout -q main` to reattach.
#
# With disjoint-line workers (F8a setup), direct `git merge --no-ff` succeeds
# and the rebase branch is never entered — so we force it via a PATH-shimmed
# `git` wrapper that fails the FIRST `git merge --no-ff … FETCH_HEAD` call
# only. The post-rebase `git merge --no-ff $rebased_sha` (no FETCH_HEAD arg)
# passes through unmodified and exercises the bug-prone code.

W=$(mk_test_world)
write_to_line "$W/worker-A" work.txt 1  "edit by US-A" "[US-A] line 1"
write_to_line "$W/worker-B" work.txt 10 "edit by US-B" "[US-B] line 10"

merge_and_push_story "$W/orch" "$W/worker-A" "US-A" origin >/dev/null 2>&1
rc=$?
assert_rc "$rc" 0 "F8a-rebase setup: 1ª merge rc=0"

WRAP="$W/wrap"
mkdir -p "$WRAP"
SENTINEL="$W/wrap-sentinel"
REAL_GIT=$(command -v git)
cat > "$WRAP/git" <<WRAPEOF
#!/usr/bin/env bash
saw_merge=0; saw_no_ff=0; saw_fh=0
for a in "\$@"; do
    case "\$a" in
        merge) saw_merge=1 ;;
        --no-ff) saw_no_ff=1 ;;
        FETCH_HEAD) saw_fh=1 ;;
    esac
done
if [ "\$saw_merge" = 1 ] && [ "\$saw_no_ff" = 1 ] && [ "\$saw_fh" = 1 ] \
        && [ ! -f "$SENTINEL" ]; then
    touch "$SENTINEL"
    exit 1
fi
exec "$REAL_GIT" "\$@"
WRAPEOF
chmod +x "$WRAP/git"

PATH="$WRAP:$PATH" merge_and_push_story "$W/orch" "$W/worker-B" "US-B" origin "US-A" >/dev/null 2>&1
rc=$?
assert_rc "$rc" 0 "F8a-rebase forced rebase path → rc=0"

# CRITICAL invariant: HEAD attached to main, not detached.
branch=$(git -C "$W/orch" branch --show-current)
assert_eq "$branch" "main" "F8a-rebase HEAD attached to main after rebase-success path"

# main must point to the new merge commit (local ref updated, not just origin).
main_msg=$(git -C "$W/orch" log -1 --format=%s main)
assert_contains "$main_msg" "merge US-B" "F8a-rebase main tip is the US-B merge commit"

# Symmetry: HEAD == main (no detached SHA divergence).
head_sha=$(git -C "$W/orch" rev-parse HEAD)
main_sha=$(git -C "$W/orch" rev-parse main)
assert_eq "$head_sha" "$main_sha" "F8a-rebase HEAD == main (no detached SHA)"

# Origin must also have the merge.
origin_msgs=$(git -C "$W/origin.git" log --pretty=format:'%s' main | tr '\n' '|')
assert_contains "$origin_msgs" "merge US-B" "F8a-rebase origin received US-B"

# Sentinel must have fired exactly once (proof the rebase path was taken).
assert_eq "$([ -f "$SENTINEL" ] && echo yes || echo no)" "yes" \
    "F8a-rebase wrapper fired (rebase path was actually exercised)"

rm -rf "$W"

# ─── AC F8a-rebase-fail: force rebase failure → HEAD must reattach to main ─
#
# Companion to the success-path test: when the rebase ALSO fails (overlapping
# changes), `rebase --abort` leaves HEAD at FETCH_HEAD (detached). Production
# code must `git checkout -q main` after the abort.

W=$(mk_test_world)
write_to_line "$W/worker-A" work.txt 1 "edit by US-A" "[US-A] line 1"
# Same line as orch-after-A so rebase HEAD FETCH_HEAD also fails.
write_to_line "$W/worker-B" work.txt 1 "edit by US-B" "[US-B] line 1"

merge_and_push_story "$W/orch" "$W/worker-A" "US-A" origin >/dev/null 2>&1
rc=$?
assert_rc "$rc" 0 "F8a-rebase-fail setup: 1ª merge rc=0"

WRAP="$W/wrap"
mkdir -p "$WRAP"
SENTINEL="$W/wrap-sentinel"
REAL_GIT=$(command -v git)
cat > "$WRAP/git" <<WRAPEOF
#!/usr/bin/env bash
saw_merge=0; saw_no_ff=0; saw_fh=0
for a in "\$@"; do
    case "\$a" in
        merge) saw_merge=1 ;;
        --no-ff) saw_no_ff=1 ;;
        FETCH_HEAD) saw_fh=1 ;;
    esac
done
if [ "\$saw_merge" = 1 ] && [ "\$saw_no_ff" = 1 ] && [ "\$saw_fh" = 1 ] \
        && [ ! -f "$SENTINEL" ]; then
    touch "$SENTINEL"
    exit 1
fi
exec "$REAL_GIT" "\$@"
WRAPEOF
chmod +x "$WRAP/git"

PATH="$WRAP:$PATH" merge_and_push_story "$W/orch" "$W/worker-B" "US-B" origin "US-A" >/dev/null 2>&1
rc=$?
assert_rc "$rc" 2 "F8a-rebase-fail rc=2 (REBASE_CONFLICT)"

# CRITICAL: HEAD must be back on main even after rebase --abort path.
branch=$(git -C "$W/orch" branch --show-current)
assert_eq "$branch" "main" "F8a-rebase-fail HEAD reattached to main after rebase --abort"

# Working tree clean.
porcelain=$(git -C "$W/orch" status --porcelain)
assert_eq "$porcelain" "" "F8a-rebase-fail working tree clean"

rm -rf "$W"

# ─── Report ───────────────────────────────────────────────────────────────

echo ""
echo "─────────────────────────────────────────────"
echo "PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then
    printf '%s\n' "$FAILED"
    exit 1
fi
exit 0

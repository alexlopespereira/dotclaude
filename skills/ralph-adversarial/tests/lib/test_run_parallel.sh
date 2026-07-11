#!/usr/bin/env bash
# tests/lib/test_run_parallel.sh — US-06 coverage for run_parallel real
# dispatcher (workers.txt + log_event + trap + slate cleanup).
#
# AC1: 6 stories (3 commit, 1 noop, 1 hang, 1 conflict-trivial) → 4 workers
#      dispatched in parallel, workers.txt consistent.
# AC2: hang detected within 2s of RALPH_HANG_TIMEOUT=10.
# AC3: trap on signal kills all PGs; pgrep -f fake-claude empty.
# AC4: signal recovery — mock-hang active → kill orchestrator → no orphans.
# AC5: slate_cleanup_for_retry exits 0 when delta files absent.
# AC6: slate_cleanup_for_retry removes delta files when present.
#
# Signal note: a backgrounded non-interactive bash inherits SIGINT=SIG_IGN
# from its parent and `trap '...' INT` inside the script CANNOT override
# that — bash documents this explicitly. In production users invoke the
# orchestrator in the foreground where Ctrl-C delivers SIGINT normally;
# in tests we send SIGTERM, which routes through the same handler body
# (see ralph-adversarial.sh trap setup). AC3/AC4 verify the cleanup, not
# the specific signal number.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TESTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SKILL_DIR="$(cd "$TESTS_DIR/.." && pwd)"
LIB_DIR="$SKILL_DIR/lib"
RALPH_SCRIPT="$SKILL_DIR/ralph-adversarial.sh"
MOCKS_DIR="$TESTS_DIR/mocks"

# shellcheck source=../../lib/dispatch.sh
source "$LIB_DIR/dispatch.sh"

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
assert_file_present() {
    local path="$1" msg="$2"
    if [ -e "$path" ]; then _pass
    else _fail "$msg :: $path missing"; fi
}

# count_lines — robust line counter (grep -c exits 1 on no match, which
# combined with `|| echo 0` produces a two-line "0\n0" string that breaks
# `[ -ge ]` integer comparisons; piping to wc -l always yields a single
# integer regardless of grep's exit code).
count_lines() {
    local pattern="$1" file="$2"
    [ -f "$file" ] || { echo 0; return 0; }
    grep -- "$pattern" "$file" 2>/dev/null | wc -l | tr -d ' '
}

# mk_pool — N-slot synthetic pool under TMPDIR. Slots are git repos on
# main with one base commit and reflog enabled.
mk_pool() {
    local repo="$1"
    local n_slots="${2:-5}"
    local base
    base=$(mktemp -d -t ralph-prl.XXXXXX)
    mkdir -p "$base/checkouts"
    local i
    for i in $(seq 1 "$n_slots"); do
        local slot="$base/checkouts/${repo}-${i}"
        mkdir -p "$slot"
        (
            cd "$slot"
            git init --quiet -b main 2>/dev/null || git init --quiet
            git config user.email "t@t.local"
            git config user.name  "t"
            git config core.logAllRefUpdates true
            git commit --allow-empty -m "base" --quiet
        )
    done
    cat > "$base/checkouts/.${repo}.pool" <<EOF
repo_name=$repo
slots=$n_slots
EOF
    echo "$base"
}

seed_pending_prd() {
    local slot="$1"; shift
    local stories_json="$*"
    cat > "$slot/prd.json" <<JSON
{
  "projectName": "us06-test",
  "branchName": "feat/us06-test",
  "userStories": [$stories_json]
}
JSON
}

story_block() {
    local id="$1" prio="$2"
    cat <<JSON
    {"id":"$id","title":"story $id","priority":$prio,"passes":false,"acceptanceCriteria":[]}
JSON
}

# ─── AC5: slate_cleanup_for_retry — noop case (no delta files) ─────────────

BASE=$(mk_pool ac5 2)
SLOT="$BASE/checkouts/ac5-1"
slate_cleanup_for_retry "$SLOT" "US-FAKE"
rc=$?
assert_rc "$rc" 0 "AC5 slate_cleanup --ignore-unmatch with no delta files → exit 0"
porcelain=$(git -C "$SLOT" status --porcelain)
assert_eq "$porcelain" "" "AC5 slate_cleanup leaves clean working tree"
rm -rf "$BASE"

# ─── AC6: slate_cleanup_for_retry — delta files removed ────────────────────

BASE=$(mk_pool ac6 2)
SLOT="$BASE/checkouts/ac6-1"
(
    cd "$SLOT"
    printf 'old delta\n' > "progress-US-X.txt"
    printf 'old md\n'    > "agents-delta-US-X.md"
    git add "progress-US-X.txt" "agents-delta-US-X.md"
    git commit -m "[US-X] previous bad attempt" --quiet
)
assert_file_present "$SLOT/progress-US-X.txt"     "AC6 setup: delta txt exists"
assert_file_present "$SLOT/agents-delta-US-X.md"  "AC6 setup: delta md  exists"

slate_cleanup_for_retry "$SLOT" "US-X"
rc=$?
assert_rc "$rc" 0 "AC6 slate_cleanup with deltas present → exit 0"
assert_file_absent  "$SLOT/progress-US-X.txt"    "AC6 progress-US-X.txt removed from working tree"
assert_file_absent  "$SLOT/agents-delta-US-X.md" "AC6 agents-delta-US-X.md removed from working tree"
rm -rf "$BASE"

# ─── AC1: 6 stories, 4 workers in parallel, workers.txt consistent ─────────
# Pool=5 → orchestrator on slot1, workers slot2..slot5 (cap=4).
# Stories: US-A,B,C → commit (delay 5s — long enough that all 4 workers
#   are concurrently visible in workers.txt at the snapshot point);
# US-D → noop; US-E → hang; US-F → conflict-trivial (delay 5s).

BASE=$(mk_pool ac1 5)
ORCH="$BASE/checkouts/ac1-1"
seed_pending_prd "$ORCH" "$(story_block US-A 1),
$(story_block US-B 2),
$(story_block US-C 3),
$(story_block US-D 4),
$(story_block US-E 5),
$(story_block US-F 6)"

OUTCOME_MAP=$(mktemp -t ralph-outmap.XXXXXX)
cat > "$OUTCOME_MAP" <<EOF
US-A:commit
US-B:commit
US-C:commit
US-D:noop
US-E:hang
US-F:conflict-trivial
EOF
DELAY_MAP=$(mktemp -t ralph-delaymap.XXXXXX)
cat > "$DELAY_MAP" <<EOF
US-A:5
US-B:5
US-C:5
US-F:5
EOF
WORKERS_FILE=$(mktemp -t ralph-wfile.XXXXXX)
LOGFILE=$(mktemp -t ralph-orchlog.XXXXXX)

(
    cd "$ORCH"
    export RALPH_ALLOW_TEST_CWD=1 \
           RALPH_AGENT_BIN="$MOCKS_DIR/fake-claude.sh" \
           RALPH_REVIEWER_BIN="$MOCKS_DIR/fake-codex.sh" \
           RALPH_WORKERS_FILE="$WORKERS_FILE" \
           RALPH_HANG_TIMEOUT=10 \
           RALPH_POLL_INTERVAL=1 \
           FAKE_OUTCOME_MAP="$OUTCOME_MAP" \
           FAKE_DELAY_MAP="$DELAY_MAP"
    exec bash "$RALPH_SCRIPT" --parallel 50
) >"$LOGFILE" 2>&1 &
ORCH_PID=$!

# Poll for peak concurrency (up to ~10s) instead of a fixed-time snapshot:
# on slow runners the 4th worker may register after t=3s, and a single
# snapshot flakes. The 5s story delays + the hang worker keep the peak
# window open well past dispatch, so a deadline poll is race-free.
WSNAP=$(mktemp -t ralph-wsnap.XXXXXX)
PEAK=0
VALID=0
i=0
while [ $i -lt 50 ]; do
    cp "$WORKERS_FILE" "$WSNAP" 2>/dev/null || : > "$WSNAP"
    n=$(awk 'END{print NR}' "$WSNAP")
    if [ "$n" -gt "$PEAK" ]; then
        PEAK=$n
        VALID=$(read_workers_file "$WSNAP" | wc -l | tr -d ' ')
    fi
    [ "$PEAK" -ge 4 ] && break
    sleep 0.2
    i=$((i + 1))
done
rm -f "$WSNAP"
assert_eq "$PEAK" "4" "AC1 4 workers active concurrently in workers.txt"

assert_eq "$VALID" "$PEAK" "AC1 every workers.txt row is well-formed"

# Now wait for the slow stories to commit and review (they delay 5s each),
# then take the orchestrator down. We wait up to 25s for ≥3 REVIEW_MERGE
# events (US-A, US-B, US-C must all merge) before signalling.
i=0
while [ $i -lt 50 ]; do
    n_merge=$(count_lines '| REVIEW_MERGE |' "$LOGFILE")
    if [ "${n_merge:-0}" -ge 3 ]; then break; fi
    sleep 0.5
    i=$((i + 1))
done
kill -TERM "$ORCH_PID" 2>/dev/null || true
wait "$ORCH_PID" 2>/dev/null || true

n_dispatch=$(count_lines '| DISPATCH |' "$LOGFILE")
assert_ge "$n_dispatch" 4 "AC1 ≥4 DISPATCH events in log"

n_merge=$(count_lines '| REVIEW_MERGE |' "$LOGFILE")
assert_ge "$n_merge" 3 "AC1 ≥3 REVIEW_MERGE events (US-A,B,C)"

rm -f "$OUTCOME_MAP" "$DELAY_MAP" "$WORKERS_FILE" "$LOGFILE"
rm -rf "$BASE"

# ─── AC2: hang detected within 2s of RALPH_HANG_TIMEOUT=10 ─────────────────
# A single hang story; assert HANG event lands within 13s wall-clock from
# orchestrator start (10s timeout + 1s poll + small bookkeeping).

BASE=$(mk_pool ac2 2)
ORCH="$BASE/checkouts/ac2-1"
seed_pending_prd "$ORCH" "$(story_block US-HANG 1)"

OUTCOME_MAP=$(mktemp -t ralph-outmap.XXXXXX)
echo "US-HANG:hang" > "$OUTCOME_MAP"
LOGFILE=$(mktemp -t ralph-orchlog.XXXXXX)

START=$(date +%s)
(
    cd "$ORCH"
    export RALPH_ALLOW_TEST_CWD=1 \
           RALPH_AGENT_BIN="$MOCKS_DIR/fake-claude.sh" \
           RALPH_REVIEWER_BIN="$MOCKS_DIR/fake-codex.sh" \
           RALPH_HANG_TIMEOUT=10 \
           RALPH_POLL_INTERVAL=1 \
           FAKE_OUTCOME_MAP="$OUTCOME_MAP"
    exec bash "$RALPH_SCRIPT" --parallel 5
) >"$LOGFILE" 2>&1 &
ORCH_PID=$!

DETECTED=""
i=0
while [ $i -lt 30 ]; do
    if grep -q '| HANG |' "$LOGFILE" 2>/dev/null; then
        DETECTED=$(date +%s)
        break
    fi
    sleep 0.5
    i=$((i + 1))
done

kill -TERM "$ORCH_PID" 2>/dev/null || true
wait "$ORCH_PID" 2>/dev/null || true

assert_contains "$(cat "$LOGFILE")" "| HANG |" "AC2 HANG event present"
if [ -n "$DETECTED" ]; then
    ELAPSED=$((DETECTED - START))
    assert_le "$ELAPSED" 13 "AC2 hang detected within 13s (10 timeout + 2s slack + poll/bookkeeping)"
    assert_ge "$ELAPSED" 9  "AC2 hang detected after timeout (≥ 9s — close to 10s timeout)"
else
    _fail "AC2 hang never detected within 15s window"
fi
rm -f "$OUTCOME_MAP" "$LOGFILE"
rm -rf "$BASE"

# ─── AC3 + AC4: signal trap kills all PGs, no orphans ──────────────────────
# Pool=3 → 2 workers; both running mock=hang. Send SIGTERM (the trap
# handles SIGINT and SIGTERM identically; backgrounded bash sets SIGINT
# to SIG_IGN before the script's trap can override it — see file header).

BASE=$(mk_pool ac34 3)
ORCH="$BASE/checkouts/ac34-1"
seed_pending_prd "$ORCH" \
    "$(story_block US-H1 1),
$(story_block US-H2 2)"

OUTCOME_MAP=$(mktemp -t ralph-outmap.XXXXXX)
cat > "$OUTCOME_MAP" <<EOF
US-H1:hang
US-H2:hang
EOF
LOGFILE=$(mktemp -t ralph-orchlog.XXXXXX)

(
    cd "$ORCH"
    export RALPH_ALLOW_TEST_CWD=1 \
           RALPH_AGENT_BIN="$MOCKS_DIR/fake-claude.sh" \
           RALPH_REVIEWER_BIN="$MOCKS_DIR/fake-codex.sh" \
           RALPH_HANG_TIMEOUT=300 \
           RALPH_POLL_INTERVAL=1 \
           FAKE_OUTCOME_MAP="$OUTCOME_MAP"
    exec bash "$RALPH_SCRIPT" --parallel 5
) >"$LOGFILE" 2>&1 &
ORCH_PID=$!

# Wait for both workers to dispatch.
i=0
while [ $i -lt 20 ]; do
    n_dispatch=$(count_lines '| DISPATCH |' "$LOGFILE")
    if [ "${n_dispatch:-0}" -ge 2 ]; then break; fi
    sleep 0.5
    i=$((i + 1))
done

PRE_HITS=$(pgrep -f "fake-claude.sh" | wc -l | tr -d ' ')
assert_ge "$PRE_HITS" 2 "AC4 setup: 2 fake-claude workers alive before signal"

kill -TERM "$ORCH_PID" 2>/dev/null || true
wait "$ORCH_PID" 2>/dev/null || true

# Trap path: kill_agent_pg sends TERM then (after 2s) KILL. Allow 6s
# total grace; 2 workers serially × ~3s each.
sleep 6

POST_HITS=$(pgrep -f "fake-claude.sh" | wc -l | tr -d ' ')
assert_eq "$POST_HITS" "0" "AC3 trap killed all fake-claude PGs"

ORPH_HITS=$(pgrep -f "sleep 999" | wc -l | tr -d ' ')
assert_eq "$ORPH_HITS" "0" "AC4 no orphaned sleep 999 children remain"

assert_contains "$(cat "$LOGFILE")" "| CLEANUP_KILL |" \
    "AC3 trap logged CLEANUP_KILL for at least one worker"
assert_contains "$(cat "$LOGFILE")" "| TRAP_TERM |" \
    "AC3 trap entry logged on signal receipt"

rm -f "$OUTCOME_MAP" "$LOGFILE"
rm -rf "$BASE"

# ─── Sanity: slate cleanup is wired to dispatch_one (e2e regression) ───────
# Pre-seed a stale delta in the worker slot; run with one noop story;
# orchestrator's dispatch_one must call slate_cleanup_for_retry before
# launching the mock, so the file disappears.

BASE=$(mk_pool slatewire 2)
ORCH="$BASE/checkouts/slatewire-1"
WORKER="$BASE/checkouts/slatewire-2"
seed_pending_prd "$ORCH" "$(story_block US-S 1)"

(
    cd "$WORKER"
    printf 'stale\n' > "progress-US-S.txt"
    git add "progress-US-S.txt"
    git commit -m "[US-S] stale delta from prior run" --quiet
)
assert_file_present "$WORKER/progress-US-S.txt" "wire setup: stale delta exists"

OUTCOME_MAP=$(mktemp -t ralph-outmap.XXXXXX)
echo "US-S:noop" > "$OUTCOME_MAP"
LOGFILE=$(mktemp -t ralph-orchlog.XXXXXX)

(
    cd "$ORCH"
    export RALPH_ALLOW_TEST_CWD=1 \
           RALPH_AGENT_BIN="$MOCKS_DIR/fake-claude.sh" \
           RALPH_REVIEWER_BIN="$MOCKS_DIR/fake-codex.sh" \
           RALPH_HANG_TIMEOUT=10 \
           RALPH_POLL_INTERVAL=1 \
           FAKE_OUTCOME_MAP="$OUTCOME_MAP"
    exec bash "$RALPH_SCRIPT" --parallel 3
) >"$LOGFILE" 2>&1 &
ORCH_PID=$!

# noop completes ~immediately; wait for the orchestrator to finish on its
# own (escalates US-S after 2 retries of FALHA_COMMIT). 15s budget.
i=0
while [ $i -lt 30 ]; do
    if ! kill -0 "$ORCH_PID" 2>/dev/null; then break; fi
    sleep 0.5
    i=$((i + 1))
done
kill -TERM "$ORCH_PID" 2>/dev/null || true
wait "$ORCH_PID" 2>/dev/null || true

assert_file_absent "$WORKER/progress-US-S.txt" \
    "wire e2e: dispatch_one ran slate_cleanup_for_retry on the worker slot"

rm -f "$OUTCOME_MAP" "$LOGFILE"
rm -rf "$BASE"

# ─── Report ───────────────────────────────────────────────────────────────

echo ""
echo "─────────────────────────────────────────────"
echo "PASS=$PASS  FAIL=$FAIL"
if [ $FAIL -gt 0 ]; then
    printf '%s\n' "$FAILED"
    exit 1
fi
exit 0

#!/usr/bin/env bash
# tests/lib/test_review_queue.sh — US-07 coverage for the review queue +
# Codex review drainer with hang detection.
#
# AC1: alternating MERGE/BLOCK/REQUEST_CHANGES across 3 stories → prd.json
#      reflects each verdict.
# AC2: at every moment of the run, at most 1 PID is recorded in
#      review-state.txt (serialization invariant). Verified by walking the
#      log: in-flight counter (DISPATCH +1, finalize -1) never > 1.
# AC3: when a worker commits, workers.txt drops the row before the review
#      finishes. review-state.txt then carries the slot id.
# AC4: review hang trigger — fake-codex with FAKE_DELAY=999, RALPH_REVIEW_TIMEOUT=10
#      kills the PG, logs REVIEW_HANG, finalizes BLOCK; next queued review
#      runs.
# AC5: hang-with-mcp — pgrep -P REVIEW_PID returns ≥1 child before timeout;
#      after kill_agent_pg, both pgrep -P and pgrep -f 'sleep 999' empty.
# AC6: depends_on blocks dependent dispatch until predecessor MERGEs.
# AC7: simultaneous worker hang in US-X + review MERGE in US-Y — both
#      updates land correctly in final prd.json (still valid JSON).
# AC8: dirty-worktree post-validation — fake-codex stray file flips verdict
#      to BLOCK with REVIEW_DIRTY_WORKTREE event.

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
assert_not_contains() {
    local haystack="$1" needle="$2" msg="$3"
    case "$haystack" in
        *"$needle"*) _fail "$msg :: unexpected '$needle' present" ;;
        *) _pass ;;
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
assert_file_present() {
    local path="$1" msg="$2"
    if [ -e "$path" ]; then _pass
    else _fail "$msg :: $path missing"; fi
}

count_lines() {
    local pattern="$1" file="$2"
    [ -f "$file" ] || { echo 0; return 0; }
    grep -- "$pattern" "$file" 2>/dev/null | wc -l | tr -d ' '
}

# Walk log; count DISPATCH/finalize transitions and return max in-flight.
# DISPATCH +1; MERGE/BLOCK/REQUEST_CHANGES/UNKNOWN -1. HANG/DIRTY_WORKTREE
# are informational and ignored (each is followed by a real finalize line).
max_review_in_flight() {
    local logfile="$1"
    awk '
        /\| REVIEW_DISPATCH \|/        { f++ }
        /\| REVIEW_MERGE \|/           { f-- }
        /\| REVIEW_BLOCK \|/           { f-- }
        /\| REVIEW_REQUEST_CHANGES \|/ { f-- }
        /\| REVIEW_UNKNOWN \|/         { f-- }
        { if (f > m) m = f }
        END { print (m == "" ? 0 : m) }
    ' "$logfile" 2>/dev/null
}

mk_pool() {
    local repo="$1"
    local n_slots="${2:-5}"
    local base
    base=$(mktemp -d -t ralph-rev.XXXXXX)
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
  "projectName": "us07-test",
  "branchName": "feat/us07-test",
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

story_block_dep() {
    local id="$1" prio="$2" dep="$3"
    cat <<JSON
    {"id":"$id","title":"story $id","priority":$prio,"passes":false,"dependsOn":["$dep"],"acceptanceCriteria":[]}
JSON
}

# ─── AC1 (alternating verdicts) + AC2 (serialization) ──────────────────────
# 3 independent stories; verdict map alternates MERGE/BLOCK/REQUEST_CHANGES.
# Pool=4 → 3 workers. All commit fast. Reviews drain serially.

BASE=$(mk_pool ac12 4)
ORCH="$BASE/checkouts/ac12-1"
seed_pending_prd "$ORCH" \
    "$(story_block US-A 1),
$(story_block US-B 2),
$(story_block US-C 3)"

VERDICT_MAP=$(mktemp -t ralph-vmap.XXXXXX)
cat > "$VERDICT_MAP" <<EOF
US-A:MERGE
US-B:BLOCK
US-C:REQUEST_CHANGES
EOF
DELAY_MAP=$(mktemp -t ralph-dmap.XXXXXX)
cat > "$DELAY_MAP" <<EOF
US-A:1
US-B:1
US-C:1
EOF
LOGFILE=$(mktemp -t ralph-orchlog.XXXXXX)

(
    cd "$ORCH"
    export RALPH_ALLOW_TEST_CWD=1 \
           RALPH_AGENT_BIN="$MOCKS_DIR/fake-claude.sh" \
           RALPH_REVIEWER_BIN="$MOCKS_DIR/fake-codex.sh" \
           RALPH_HANG_TIMEOUT=30 \
           RALPH_REVIEW_TIMEOUT=30 \
           RALPH_POLL_INTERVAL=1 \
           FAKE_VERDICT_MAP="$VERDICT_MAP" \
           FAKE_DELAY_MAP="$DELAY_MAP"
    exec bash "$RALPH_SCRIPT" --parallel 50
) >"$LOGFILE" 2>&1 &
ORCH_PID=$!

# Each story: commit (~0s) + review (1s). 3 stories serial review = ~3s. Plus
# BLOCK/REQUEST_CHANGES retries (each = commit + 1s review × 2 more) ≈ 6s
# more. Total ~10s. Wait up to 25s for ESCALATED for B and C.
i=0
while [ $i -lt 60 ]; do
    pending=$(jq -r '[.userStories[] | select(.passes == false)] | length' "$ORCH/prd.json" 2>/dev/null || echo 99)
    if [ "${pending:-99}" -eq 0 ]; then break; fi
    if ! kill -0 "$ORCH_PID" 2>/dev/null; then break; fi
    sleep 0.5
    i=$((i + 1))
done
kill -TERM "$ORCH_PID" 2>/dev/null || true
wait "$ORCH_PID" 2>/dev/null || true

# AC1 — final verdicts on prd.json.
A_PASSES=$(jq -r '.userStories[] | select(.id=="US-A") | .passes' "$ORCH/prd.json")
B_PASSES=$(jq -r '.userStories[] | select(.id=="US-B") | .passes' "$ORCH/prd.json")
C_PASSES=$(jq -r '.userStories[] | select(.id=="US-C") | .passes' "$ORCH/prd.json")
assert_eq "$A_PASSES" "true"      "AC1 US-A merged → passes:true"
assert_eq "$B_PASSES" "ESCALATED" "AC1 US-B BLOCK retries exhaust → ESCALATED"
assert_eq "$C_PASSES" "ESCALATED" "AC1 US-C REQUEST_CHANGES exhaust → ESCALATED"

LOG=$(cat "$LOGFILE")
assert_contains "$LOG" "| REVIEW_MERGE | US-A |"           "AC1 log REVIEW_MERGE US-A"
assert_contains "$LOG" "| REVIEW_BLOCK | US-B |"           "AC1 log REVIEW_BLOCK US-B"
assert_contains "$LOG" "| REVIEW_REQUEST_CHANGES | US-C |" "AC1 log REVIEW_REQUEST_CHANGES US-C"

# AC2 — serialization invariant: max in-flight reviews ≤ 1.
MAX_IN_FLIGHT=$(max_review_in_flight "$LOGFILE")
assert_le "$MAX_IN_FLIGHT" 1 "AC2 review queue serialized (max in-flight=$MAX_IN_FLIGHT)"

rm -f "$VERDICT_MAP" "$DELAY_MAP" "$LOGFILE"
rm -rf "$BASE"

# ─── AC3 (slot freed before review terminates) ─────────────────────────────
# 1 story; impl 0s + review 4s. After commit, snapshot workers.txt and
# review-state.txt: workers.txt empty (slot freed), review-state.txt has
# the slot id.

BASE=$(mk_pool ac3 2)
ORCH="$BASE/checkouts/ac3-1"
seed_pending_prd "$ORCH" "$(story_block US-A 1)"

DELAY_MAP=$(mktemp -t ralph-dmap.XXXXXX)
echo "US-A:4" > "$DELAY_MAP"
WORKERS_FILE=$(mktemp -t ralph-wfile.XXXXXX)
REVIEW_QUEUE=$(mktemp -t ralph-rqfile.XXXXXX)
REVIEW_STATE=$(mktemp -t ralph-rsfile.XXXXXX)
LOGFILE=$(mktemp -t ralph-orchlog.XXXXXX)

(
    cd "$ORCH"
    export RALPH_ALLOW_TEST_CWD=1 \
           RALPH_AGENT_BIN="$MOCKS_DIR/fake-claude.sh" \
           RALPH_REVIEWER_BIN="$MOCKS_DIR/fake-codex.sh" \
           RALPH_WORKERS_FILE="$WORKERS_FILE" \
           RALPH_REVIEW_QUEUE_FILE="$REVIEW_QUEUE" \
           RALPH_REVIEW_STATE_FILE="$REVIEW_STATE" \
           RALPH_HANG_TIMEOUT=30 \
           RALPH_REVIEW_TIMEOUT=30 \
           RALPH_POLL_INTERVAL=1 \
           FAKE_DELAY_MAP="$DELAY_MAP"
    exec bash "$RALPH_SCRIPT" --parallel 5
) >"$LOGFILE" 2>&1 &
ORCH_PID=$!

# Wait until review starts (state file non-empty) — generous 12s budget.
i=0
while [ $i -lt 24 ]; do
    if [ -s "$REVIEW_STATE" ]; then break; fi
    sleep 0.5
    i=$((i + 1))
done

# Snapshot: workers.txt should NOT contain US-A; review-state should.
WORKERS_SNAP=$(cat "$WORKERS_FILE" 2>/dev/null || echo "")
REVIEW_SNAP=$(cat "$REVIEW_STATE" 2>/dev/null || echo "")
assert_not_contains "$WORKERS_SNAP" "US-A" "AC3 workers.txt does not list US-A after commit"
assert_contains    "$REVIEW_SNAP" "US-A"  "AC3 review-state.txt carries US-A while review runs"
assert_contains    "$REVIEW_SNAP" "ac3-2" "AC3 review-state.txt records the worker slot basename"

# Wait for orchestrator to settle.
i=0
while [ $i -lt 30 ]; do
    pending=$(jq -r '[.userStories[] | select(.passes == false)] | length' "$ORCH/prd.json" 2>/dev/null || echo 99)
    if [ "${pending:-99}" -eq 0 ]; then break; fi
    if ! kill -0 "$ORCH_PID" 2>/dev/null; then break; fi
    sleep 0.5
    i=$((i + 1))
done
kill -TERM "$ORCH_PID" 2>/dev/null || true
wait "$ORCH_PID" 2>/dev/null || true

rm -f "$DELAY_MAP" "$WORKERS_FILE" "$REVIEW_QUEUE" "$REVIEW_STATE" "$LOGFILE"
rm -rf "$BASE"

# ─── AC4 (review hang → BLOCK; next review dispatched) ────────────────────
# 2 stories. US-X review hangs (FAKE_DELAY=999). US-Y review normal MERGE.
# RALPH_REVIEW_TIMEOUT=10 → US-X gets killed and BLOCK'd; US-Y proceeds.

BASE=$(mk_pool ac4 3)
ORCH="$BASE/checkouts/ac4-1"
seed_pending_prd "$ORCH" \
    "$(story_block US-X 1),
$(story_block US-Y 2)"

DELAY_MAP=$(mktemp -t ralph-dmap.XXXXXX)
echo "US-X:999" > "$DELAY_MAP"
LOGFILE=$(mktemp -t ralph-orchlog.XXXXXX)

(
    cd "$ORCH"
    export RALPH_ALLOW_TEST_CWD=1 \
           RALPH_AGENT_BIN="$MOCKS_DIR/fake-claude.sh" \
           RALPH_REVIEWER_BIN="$MOCKS_DIR/fake-codex.sh" \
           RALPH_HANG_TIMEOUT=30 \
           RALPH_REVIEW_TIMEOUT=10 \
           RALPH_POLL_INTERVAL=1 \
           FAKE_REVIEW_DELAY_MAP="$DELAY_MAP"
    exec bash "$RALPH_SCRIPT" --parallel 50
) >"$LOGFILE" 2>&1 &
ORCH_PID=$!

# Budget: US-X hang 1 (10s) → BLOCK retry, US-Y review (~0s) → MERGE,
# US-X re-impl + hang 2 (10s) → ESCALATED. ~25s.
i=0
while [ $i -lt 80 ]; do
    pending=$(jq -r '[.userStories[] | select(.passes == false)] | length' "$ORCH/prd.json" 2>/dev/null || echo 99)
    if [ "${pending:-99}" -eq 0 ]; then break; fi
    if ! kill -0 "$ORCH_PID" 2>/dev/null; then break; fi
    sleep 0.5
    i=$((i + 1))
done
kill -TERM "$ORCH_PID" 2>/dev/null || true
wait "$ORCH_PID" 2>/dev/null || true

LOG=$(cat "$LOGFILE")
assert_contains "$LOG" "| REVIEW_HANG | US-X |"  "AC4 REVIEW_HANG event for US-X"
assert_contains "$LOG" "| REVIEW_BLOCK | US-X |" "AC4 hang finalizes BLOCK for US-X"
assert_contains "$LOG" "| REVIEW_MERGE | US-Y |" "AC4 next queued review (US-Y) merged after hang"

X_PASSES=$(jq -r '.userStories[] | select(.id=="US-X") | .passes' "$ORCH/prd.json")
Y_PASSES=$(jq -r '.userStories[] | select(.id=="US-Y") | .passes' "$ORCH/prd.json")
assert_eq "$X_PASSES" "ESCALATED" "AC4 US-X final state ESCALATED after repeated hangs"
assert_eq "$Y_PASSES" "true"      "AC4 US-Y merged despite earlier hang on US-X"

rm -f "$DELAY_MAP" "$LOGFILE"
rm -rf "$BASE"

# ─── AC5 (hang-with-mcp PG kill propagates to grandchildren) ───────────────
# fake-codex spawns 2 sleep 999 children inside its PG; orchestrator must
# kill the entire group on timeout.

# Drain any sleep 999 leftover from prior tests (AC4 used FAKE_REVIEW_DELAY=999
# which makes fake-codex itself sleep 999 — kill_agent_pg should have cleaned
# them, but pgrep -f 'sleep 999' is system-wide and the AC explicitly checks
# that signature, so make sure we start from zero.
pkill -f 'sleep 999' 2>/dev/null || true
sleep 1

BASE=$(mk_pool ac5 2)
ORCH="$BASE/checkouts/ac5-1"
seed_pending_prd "$ORCH" "$(story_block US-PG 1)"

REVIEW_STATE=$(mktemp -t ralph-rsfile.XXXXXX)
LOGFILE=$(mktemp -t ralph-orchlog.XXXXXX)

(
    cd "$ORCH"
    export RALPH_ALLOW_TEST_CWD=1 \
           RALPH_AGENT_BIN="$MOCKS_DIR/fake-claude.sh" \
           RALPH_REVIEWER_BIN="$MOCKS_DIR/fake-codex.sh" \
           RALPH_REVIEW_STATE_FILE="$REVIEW_STATE" \
           RALPH_HANG_TIMEOUT=30 \
           RALPH_REVIEW_TIMEOUT=5 \
           RALPH_POLL_INTERVAL=1 \
           FAKE_REVIEW_OUTCOME=hang-with-mcp
    exec bash "$RALPH_SCRIPT" --parallel 5
) >"$LOGFILE" 2>&1 &
ORCH_PID=$!

# Wait for review to start.
i=0
while [ $i -lt 30 ]; do
    if [ -s "$REVIEW_STATE" ]; then break; fi
    sleep 0.2
    i=$((i + 1))
done
REVIEW_PID=$(awk -F: 'NR==1 {print $1}' "$REVIEW_STATE" 2>/dev/null)
[ -n "$REVIEW_PID" ] || REVIEW_PID=0

# Pre-timeout: PID alive AND has at least one child.
sleep 1
PRE_ALIVE=$(kill -0 "$REVIEW_PID" 2>/dev/null && echo yes || echo no)
PRE_CHILDREN=$(pgrep -P "$REVIEW_PID" 2>/dev/null | wc -l | tr -d ' ')
PRE_SLEEPS=$(pgrep -f 'sleep 999' 2>/dev/null | wc -l | tr -d ' ')
assert_eq "$PRE_ALIVE" "yes" "AC5 review PID alive before timeout"
assert_ge "$PRE_CHILDREN" 1  "AC5 review PID has ≥1 child (bash-c parent of sleeps)"
assert_ge "$PRE_SLEEPS" 2    "AC5 ≥2 'sleep 999' children alive before timeout"

# Wait until iter 1 REVIEW_PID dies (orchestrator's timeout kill landed).
# Then stop the orchestrator BEFORE it launches iter 2 — otherwise iter 2's
# fresh sleeps would contaminate the post-kill assertion. RALPH_REVIEW_TIMEOUT=5
# fires the kill ~5s after launch; we poll at 0.5s.
i=0
while [ $i -lt 30 ]; do
    if ! kill -0 "$REVIEW_PID" 2>/dev/null; then break; fi
    sleep 0.5
    i=$((i + 1))
done
kill -TERM "$ORCH_PID" 2>/dev/null || true
wait "$ORCH_PID" 2>/dev/null || true
# parallel_cleanup runs in the trap; give the kernel a moment to reap.
sleep 1

POST_CHILDREN=$(pgrep -P "$REVIEW_PID" 2>/dev/null | wc -l | tr -d ' ')
POST_SLEEPS=$(pgrep -f 'sleep 999' 2>/dev/null | wc -l | tr -d ' ')
assert_eq "$POST_CHILDREN" "0" "AC5 PG kill cleared review PID children"
assert_eq "$POST_SLEEPS"   "0" "AC5 PG kill cleared 'sleep 999' grandchildren"

assert_contains "$(cat "$LOGFILE")" "| REVIEW_HANG | US-PG |" "AC5 REVIEW_HANG logged for hang-with-mcp"

# Belt & suspenders: pkill any leftover sleep 999 (e.g. from a flaky reap).
pkill -f 'sleep 999' 2>/dev/null || true

rm -f "$REVIEW_STATE" "$LOGFILE"
rm -rf "$BASE"

# ─── AC6 (depends_on blocks dependent until predecessor merges) ────────────
# US-A no deps; US-B depends on US-A. Both fast commits; review delay 2s.
# Orchestrator must NOT dispatch US-B until US-A's review finalizes MERGE.

BASE=$(mk_pool ac6 3)
ORCH="$BASE/checkouts/ac6-1"
seed_pending_prd "$ORCH" \
    "$(story_block     US-A 1),
$(story_block_dep US-B 2 US-A)"

DELAY_MAP=$(mktemp -t ralph-dmap.XXXXXX)
cat > "$DELAY_MAP" <<EOF
US-A:2
US-B:0
EOF
LOGFILE=$(mktemp -t ralph-orchlog.XXXXXX)

(
    cd "$ORCH"
    export RALPH_ALLOW_TEST_CWD=1 \
           RALPH_AGENT_BIN="$MOCKS_DIR/fake-claude.sh" \
           RALPH_REVIEWER_BIN="$MOCKS_DIR/fake-codex.sh" \
           RALPH_HANG_TIMEOUT=30 \
           RALPH_REVIEW_TIMEOUT=30 \
           RALPH_POLL_INTERVAL=1 \
           FAKE_DELAY_MAP="$DELAY_MAP"
    exec bash "$RALPH_SCRIPT" --parallel 20
) >"$LOGFILE" 2>&1 &
ORCH_PID=$!

i=0
while [ $i -lt 40 ]; do
    pending=$(jq -r '[.userStories[] | select(.passes == false)] | length' "$ORCH/prd.json" 2>/dev/null || echo 99)
    if [ "${pending:-99}" -eq 0 ]; then break; fi
    if ! kill -0 "$ORCH_PID" 2>/dev/null; then break; fi
    sleep 0.5
    i=$((i + 1))
done
kill -TERM "$ORCH_PID" 2>/dev/null || true
wait "$ORCH_PID" 2>/dev/null || true

# Both must end as passes:true.
A_PASSES=$(jq -r '.userStories[] | select(.id=="US-A") | .passes' "$ORCH/prd.json")
B_PASSES=$(jq -r '.userStories[] | select(.id=="US-B") | .passes' "$ORCH/prd.json")
assert_eq "$A_PASSES" "true" "AC6 US-A merged"
assert_eq "$B_PASSES" "true" "AC6 US-B merged after dep cleared"

# Ordering: REVIEW_MERGE for US-A must appear BEFORE first DISPATCH for US-B.
A_MERGE_LINE=$(grep -n '| REVIEW_MERGE | US-A |' "$LOGFILE" | head -1 | cut -d: -f1)
B_DISP_LINE=$(grep -n  '| DISPATCH | US-B |'    "$LOGFILE" | head -1 | cut -d: -f1)
[ -n "$A_MERGE_LINE" ] || A_MERGE_LINE=0
[ -n "$B_DISP_LINE"  ] || B_DISP_LINE=0
if [ "$A_MERGE_LINE" -gt 0 ] && [ "$B_DISP_LINE" -gt 0 ] && [ "$A_MERGE_LINE" -lt "$B_DISP_LINE" ]; then
    _pass
else
    _fail "AC6 dispatch order: US-A REVIEW_MERGE (line=$A_MERGE_LINE) must precede US-B DISPATCH (line=$B_DISP_LINE)"
fi

rm -f "$DELAY_MAP" "$LOGFILE"
rm -rf "$BASE"

# ─── AC7 (concurrent worker hang + review merge → both prd.json updates) ───
# US-X: fake-claude hangs (worker timeout). US-Y: commits + review MERGE.
# RALPH_HANG_TIMEOUT=3 → fast escalation. Final prd.json must remain valid
# JSON and reflect both updates.

BASE=$(mk_pool ac7 3)
ORCH="$BASE/checkouts/ac7-1"
seed_pending_prd "$ORCH" \
    "$(story_block US-X 1),
$(story_block US-Y 2)"

OUTCOME_MAP=$(mktemp -t ralph-omap.XXXXXX)
cat > "$OUTCOME_MAP" <<EOF
US-X:hang
US-Y:commit
EOF
LOGFILE=$(mktemp -t ralph-orchlog.XXXXXX)

(
    cd "$ORCH"
    export RALPH_ALLOW_TEST_CWD=1 \
           RALPH_AGENT_BIN="$MOCKS_DIR/fake-claude.sh" \
           RALPH_REVIEWER_BIN="$MOCKS_DIR/fake-codex.sh" \
           RALPH_HANG_TIMEOUT=3 \
           RALPH_REVIEW_TIMEOUT=15 \
           RALPH_POLL_INTERVAL=1 \
           FAKE_OUTCOME_MAP="$OUTCOME_MAP"
    exec bash "$RALPH_SCRIPT" --parallel 50
) >"$LOGFILE" 2>&1 &
ORCH_PID=$!

i=0
while [ $i -lt 60 ]; do
    pending=$(jq -r '[.userStories[] | select(.passes == false)] | length' "$ORCH/prd.json" 2>/dev/null || echo 99)
    if [ "${pending:-99}" -eq 0 ]; then break; fi
    if ! kill -0 "$ORCH_PID" 2>/dev/null; then break; fi
    sleep 0.5
    i=$((i + 1))
done
kill -TERM "$ORCH_PID" 2>/dev/null || true
wait "$ORCH_PID" 2>/dev/null || true
pkill -f 'sleep 999' 2>/dev/null || true

# JSON validity post-run.
if jq -e . "$ORCH/prd.json" >/dev/null 2>&1; then _pass
else _fail "AC7 prd.json invalid JSON post-run (race-safe write violated)"; fi

X_PASSES=$(jq -r '.userStories[] | select(.id=="US-X") | .passes' "$ORCH/prd.json")
Y_PASSES=$(jq -r '.userStories[] | select(.id=="US-Y") | .passes' "$ORCH/prd.json")
assert_eq "$X_PASSES" "ESCALATED" "AC7 US-X (worker hang) final ESCALATED"
assert_eq "$Y_PASSES" "true"      "AC7 US-Y (merge) final true"
assert_contains "$(cat "$LOGFILE")" "| HANG | US-X |"        "AC7 worker HANG event for US-X"
assert_contains "$(cat "$LOGFILE")" "| REVIEW_MERGE | US-Y |" "AC7 review MERGE event for US-Y"

rm -f "$OUTCOME_MAP" "$LOGFILE"
rm -rf "$BASE"

# ─── AC8 (Plano B: dirty review WT is isolated, not blocking) ──────────────
# Plan B isolates the reviewer in a dedicated git worktree at
# $POOL_BASE/.ralph-review-<story>. Codex/mock writes there are not visible
# to worker slots, so the legacy REVIEW_DIRTY_WORKTREE BLOCK override is
# dropped. fake-codex with FAKE_REVIEW_OUTCOME=dirty-worktree still drops a
# stray file in cwd, but that cwd is now the disposable review WT — verdict
# is whatever the mock emitted (MERGE), and the WT is removed in
# finalize_review regardless.

BASE=$(mk_pool ac8 2)
ORCH="$BASE/checkouts/ac8-1"
seed_pending_prd "$ORCH" "$(story_block US-DW 1)"

LOGFILE=$(mktemp -t ralph-orchlog.XXXXXX)

(
    cd "$ORCH"
    export RALPH_ALLOW_TEST_CWD=1 \
           RALPH_AGENT_BIN="$MOCKS_DIR/fake-claude.sh" \
           RALPH_REVIEWER_BIN="$MOCKS_DIR/fake-codex.sh" \
           RALPH_HANG_TIMEOUT=20 \
           RALPH_REVIEW_TIMEOUT=20 \
           RALPH_POLL_INTERVAL=1 \
           FAKE_REVIEW_OUTCOME=dirty-worktree
    exec bash "$RALPH_SCRIPT" --parallel 10
) >"$LOGFILE" 2>&1 &
ORCH_PID=$!

i=0
while [ $i -lt 40 ]; do
    pending=$(jq -r '[.userStories[] | select(.passes == false)] | length' "$ORCH/prd.json" 2>/dev/null || echo 99)
    if [ "${pending:-99}" -eq 0 ]; then break; fi
    if ! kill -0 "$ORCH_PID" 2>/dev/null; then break; fi
    sleep 0.5
    i=$((i + 1))
done
kill -TERM "$ORCH_PID" 2>/dev/null || true
wait "$ORCH_PID" 2>/dev/null || true

LOG=$(cat "$LOGFILE")
# Plano B: REVIEW_DIRTY_WORKTREE event must NOT appear (isolation works).
if echo "$LOG" | grep -q "| REVIEW_DIRTY_WORKTREE | US-DW |"; then
    FAIL=$((FAIL + 1))
    FAILED="${FAILED}\nAC8: unexpected REVIEW_DIRTY_WORKTREE — Plano B isolation broken"
else
    PASS=$((PASS + 1))
fi
assert_contains "$LOG" "| REVIEW_MERGE | US-DW |" "AC8 mock dirty-WT verdict still MERGE (isolated)"

DW_PASSES=$(jq -r '.userStories[] | select(.id=="US-DW") | .passes' "$ORCH/prd.json")
assert_eq "$DW_PASSES" "true" "AC8 US-DW passes:true (mock MERGE despite dirty review WT)"

# Review WT must be cleaned up after finalize_review.
if [ -d "$BASE/checkouts/.ralph-review-US-DW" ]; then
    FAIL=$((FAIL + 1))
    FAILED="${FAILED}\nAC8: review worktree .ralph-review-US-DW not cleaned up"
else
    PASS=$((PASS + 1))
fi

rm -f "$LOGFILE"
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

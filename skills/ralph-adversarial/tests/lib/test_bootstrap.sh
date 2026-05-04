#!/usr/bin/env bash
# tests/lib/test_bootstrap.sh — E2E coverage for ralph-adversarial.sh
# --parallel bootstrap (US-05). Spawns the real script with mocked agents
# and a synthetic pool layout under /tmp so the recursion guard does not
# fire and prereq checks (jq, claude/codex) are bypassed via mocks.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TESTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SKILL_DIR="$(cd "$TESTS_DIR/.." && pwd)"
RALPH_SCRIPT="$SKILL_DIR/ralph-adversarial.sh"
MOCKS_DIR="$TESTS_DIR/mocks"

PASS=0
FAIL=0
FAILED=""

_fail() { FAIL=$((FAIL + 1)); FAILED="${FAILED}
  ✗ $1"; }
_pass() { PASS=$((PASS + 1)); }

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

# Helper: build a realistic pool layout under a freshly-mktemp'd base.
# Returns the base via stdout; pool slots are git-initialized with one
# base commit, on main, working tree clean. Optional last arg = number
# of slots (default 2). Pool dir name uses the repo arg.
mk_pool() {
    local repo="$1"
    local n_slots="${2:-2}"
    local base
    base=$(mktemp -d -t ralph-pool.XXXXXX)
    # parse_pool_from_pwd requires the path to end in /checkouts/<repo>-<N>.
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
    # Pool metadata file matching the format checkout-init.sh writes.
    cat > "$base/checkouts/.${repo}.pool" <<EOF
repo_name=$repo
slots=$n_slots
EOF
    echo "$base"
}

# Helper: drop a minimal "all stories already done" prd.json into a slot
# so the script's serial loop exits immediately with "TODAS COMPLETAS".
seed_done_prd() {
    local slot="$1"
    cat > "$slot/prd.json" <<'JSON'
{
  "projectName": "bootstrap-test",
  "branchName": "feat/bootstrap-test",
  "userStories": [
    {"id":"US-A","title":"a","priority":1,"passes":true,"acceptanceCriteria":[]}
  ]
}
JSON
}

# Wrapper: run ralph-adversarial.sh in $cwd with mocks wired so the prereq
# checks for claude/codex are skipped (RALPH_AGENT_BIN/RALPH_REVIEWER_BIN
# turn NEEDS_* false). Returns combined stdout+stderr; rc captured by caller.
run_ralph() {
    local cwd="$1"; shift
    (
        cd "$cwd"
        RALPH_ALLOW_TEST_CWD=1 \
        RALPH_AGENT_BIN="$MOCKS_DIR/fake-claude.sh" \
        RALPH_REVIEWER_BIN="$MOCKS_DIR/fake-codex.sh" \
            bash "$RALPH_SCRIPT" "$@"
    ) 2>&1
}

# ─── AC1: --parallel from non-pool cwd → graceful fail with usage ─────────

SAFE_DIR=$(mktemp -d -t ralph-no-pool.XXXXXX)
out=$(run_ralph "$SAFE_DIR" --parallel)
rc=$?
assert_rc "$rc" 1 "AC1 outside pool → exit 1"
assert_contains "$out" "Uso:"          "AC1 prints usage line"
assert_contains "$out" "--parallel"    "AC1 message names the flag"
assert_contains "$out" "checkouts"     "AC1 message names expected pool layout"
# Critically, must NOT proceed to "modo paralelo detectado".
assert_not_contains "$out" "modo paralelo detectado" \
    "AC1 outside pool → never prints parallel-detected line"
rm -rf "$SAFE_DIR"

# ─── AC4: pool=1 slot → abort with clear "≥ 2 slots" message ──────────────

BASE=$(mk_pool soloapp 1)
SLOT="$BASE/checkouts/soloapp-1"
out=$(run_ralph "$SLOT" --parallel)
rc=$?
assert_rc "$rc" 1 "AC4 pool=1 → exit 1"
assert_contains "$out" "≥ 2 slots"   "AC4 message mentions slots minimum"
assert_contains "$out" "checkout-init" "AC4 message points to /checkout-init"
assert_not_contains "$out" "modo paralelo detectado" \
    "AC4 pool=1 → never reaches parallel-detected line"
rm -rf "$BASE"

# ─── AC2 + AC5: pool=2 → identifies slots, prints orchestrator + workers ──

BASE=$(mk_pool myapp 2)
ORCH="$BASE/checkouts/myapp-1"
seed_done_prd "$ORCH"
out=$(run_ralph "$ORCH" --parallel 1)
rc=$?
assert_rc "$rc" 0 "AC2 pool=2 + all-done prd → serial loop completes (rc=0)"
assert_contains "$out" "modo paralelo detectado"  "AC2 prints detection line"
assert_contains "$out" "orquestrador=myapp-1"     "AC5 names orchestrator"
assert_contains "$out" "workers=[myapp-2]"        "AC5 names worker list"
# US-06: run_parallel is now real — when all stories already pass, it logs
# ALL_DONE via log_event (no longer falls back to run_serial's banner).
assert_contains "$out" "ALL_DONE" \
    "AC2 control: parallel loop reached ALL_DONE (all stories pre-settled)"
rm -rf "$BASE"

# ─── AC2/AC5 with pool=3: orchestrator on slot 2, workers are 1 and 3 ─────

BASE=$(mk_pool tri 3)
ORCH="$BASE/checkouts/tri-2"
seed_done_prd "$ORCH"
out=$(run_ralph "$ORCH" --parallel 1)
rc=$?
assert_rc "$rc" 0 "AC2 pool=3 from slot 2 → rc=0"
assert_contains "$out" "orquestrador=tri-2"        "AC5 pool=3 orchestrator slot 2"
assert_contains "$out" "workers=[tri-1, tri-3]"    "AC5 pool=3 workers exclude orchestrator"
rm -rf "$BASE"

# ─── AC6: core.logAllRefUpdates=false on a slot → preflight aborts ────────

BASE=$(mk_pool reflogtest 2)
git -C "$BASE/checkouts/reflogtest-2" config core.logAllRefUpdates false
ORCH="$BASE/checkouts/reflogtest-1"
seed_done_prd "$ORCH"
out=$(run_ralph "$ORCH" --parallel)
rc=$?
assert_rc "$rc" 1 "AC6 reflog=false on a slot → exit 1"
assert_contains "$out" "core.logAllRefUpdates" "AC6 message names the setting"
assert_contains "$out" "Camada A'"              "AC6 message references Camada A'"
assert_not_contains "$out" "modo paralelo detectado" \
    "AC6 preflight failure happens BEFORE parallel-detected line"
rm -rf "$BASE"

# ─── Sanity: no --parallel → script still runs serial unchanged ───────────

BASE=$(mk_pool noparallel 2)
ORCH="$BASE/checkouts/noparallel-1"
seed_done_prd "$ORCH"
out=$(run_ralph "$ORCH" 1)
rc=$?
assert_rc "$rc" 0 "no-flag invocation → rc=0 (serial path unchanged)"
assert_not_contains "$out" "modo paralelo detectado" \
    "no-flag invocation → never prints parallel-detected line"
assert_contains "$out" "TODAS AS STORIES COMPLETAS" \
    "no-flag invocation → serial loop ran"
rm -rf "$BASE"

# ─── Sanity: --parallel=N parses N and still bootstraps ───────────────────

BASE=$(mk_pool eqval 2)
ORCH="$BASE/checkouts/eqval-1"
seed_done_prd "$ORCH"
out=$(run_ralph "$ORCH" --parallel=3 1)
rc=$?
assert_rc "$rc" 0 "--parallel=N parses N (rc=0)"
assert_contains "$out" "modo paralelo detectado" \
    "--parallel=N still triggers parallel bootstrap"
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

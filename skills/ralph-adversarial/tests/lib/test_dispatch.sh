#!/usr/bin/env bash
# tests/lib/test_dispatch.sh — TDD coverage for lib/dispatch.sh (US-01).
#
# Runs without `bats`: a tiny inline harness keeps PASS/FAIL counts and exits 1
# if any assertion fails. Each top-level block is annotated with the AC it
# exercises (matches commit ac_trace).

# We do NOT set -e: we want to keep going past failures and report all of them.
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/../../lib" && pwd)"
FIXTURE_DIR="$(cd "$SCRIPT_DIR/../fixtures" && pwd)"

# shellcheck source=../../lib/dispatch.sh
source "$LIB_DIR/dispatch.sh"

PASS=0
FAIL=0
FAILED=""

_fail() {
    FAIL=$((FAIL + 1))
    FAILED="${FAILED}
  ✗ $1"
}
_pass() {
    PASS=$((PASS + 1))
}

assert_eq() {
    local actual="$1" expected="$2" msg="$3"
    if [ "$actual" = "$expected" ]; then
        _pass
    else
        _fail "$msg :: expected='$expected' actual='$actual'"
    fi
}

assert_rc() {
    local rc="$1" expected="$2" msg="$3"
    if [ "$rc" = "$expected" ]; then
        _pass
    else
        _fail "$msg :: expected rc=$expected got rc=$rc"
    fi
}

assert_contains() {
    local haystack="$1" needle="$2" msg="$3"
    case "$haystack" in
        *"$needle"*) _pass ;;
        *) _fail "$msg :: '$needle' not found in '$haystack'" ;;
    esac
}

# ─── AC1: is_dispatchable ──────────────────────────────────────────────────

# Independent story (no dependsOn) with passes:false → dispatchable.
is_dispatchable "US-A" "$FIXTURE_DIR/dispatchable-independent.json"
assert_rc "$?" 0 "AC1 independent → dispatchable"

# Story whose dep is ESCALATED → not dispatchable.
is_dispatchable "US-B" "$FIXTURE_DIR/dispatchable-deps_escalated.json"
assert_rc "$?" 1 "AC1 dep ESCALATED → not dispatchable"

# Story whose dep is still passes:false (in review queue) → not dispatchable.
is_dispatchable "US-B" "$FIXTURE_DIR/dispatchable-in_review_queue.json"
assert_rc "$?" 1 "AC1 dep in review → not dispatchable"

# Dep that has passes:true → dispatchable.
TMP_PRD=$(mktemp_safe file ac1-deptrue)
cat > "$TMP_PRD" <<'JSON'
{
  "userStories": [
    {"id":"US-A","priority":1,"passes":true},
    {"id":"US-B","priority":2,"passes":false,"dependsOn":["US-A"]}
  ]
}
JSON
is_dispatchable "US-B" "$TMP_PRD"
assert_rc "$?" 0 "AC1 dep passes:true → dispatchable"
rm -f "$TMP_PRD"

# Story already passes:true → not dispatchable (no work to do).
is_dispatchable "US-C" "$FIXTURE_DIR/dispatchable-multiple_pending.json"
assert_rc "$?" 1 "AC1 self passes:true → not dispatchable"

# ─── AC2: compute_cap ──────────────────────────────────────────────────────

# pool=2 → orchestrator takes 1 → slots_avail=1 → cap=min(4,1,many)=1
assert_eq "$(compute_cap 4 1 99)" "1" "AC2 pool=2 → cap=1"
# pool=3 → slots_avail=2
assert_eq "$(compute_cap 4 2 99)" "2" "AC2 pool=3 → cap=2"
# pool=5 → slots_avail=4 (default RALPH_PARALLEL_N=4)
assert_eq "$(compute_cap 4 4 99)" "4" "AC2 pool=5 default N=4 → cap=4"
# dispatchable count is the binding constraint
assert_eq "$(compute_cap 4 4 2)" "2" "AC2 dispatchable=2 binds → cap=2"
# pool=1 → slots_avail=0 → cap=0 + warning to stderr
out_err=$(compute_cap 4 0 99 2>&1 >/dev/null)
out_val=$(compute_cap 4 0 99 2>/dev/null)
assert_eq "$out_val" "0" "AC2 pool=1 → cap=0"
assert_contains "$out_err" "WARN" "AC2 pool=1 → emits WARN"

# ─── AC3: detect_dependsOn_cycle ───────────────────────────────────────────

# Acyclic fixtures → return 0.
detect_dependsOn_cycle "$FIXTURE_DIR/dispatchable-independent.json" 2>/dev/null
assert_rc "$?" 0 "AC3 acyclic single → no cycle"

detect_dependsOn_cycle "$FIXTURE_DIR/dispatchable-in_review_queue.json" 2>/dev/null
assert_rc "$?" 0 "AC3 linear A←B → no cycle"

# Cycle fixture → return 1 with message containing 'ciclo detectado'.
err=$(detect_dependsOn_cycle "$FIXTURE_DIR/dispatchable-cycle.json" 2>&1 >/dev/null)
rc=$?
assert_rc "$rc" 1 "AC3 cycle.json rejected"
assert_contains "$err" "ciclo detectado" "AC3 cycle message contains 'ciclo detectado'"
assert_contains "$err" "US-01" "AC3 cycle message names US-01"
assert_contains "$err" "US-02" "AC3 cycle message names US-02"

# ─── AC4: parse_pool_from_pwd ──────────────────────────────────────────────

out=$(parse_pool_from_pwd "/Users/x/Projects/checkouts/myrepo-3" 2>&1)
rc=$?
assert_rc "$rc" 0 "AC4 valid pool path → rc=0"
assert_eq "$out" "myrepo 3" "AC4 valid pool path → 'myrepo 3'"

out=$(parse_pool_from_pwd "/Users/x/Projects/myrepo" 2>&1)
rc=$?
assert_rc "$rc" 1 "AC4 non-pool path → rc=1"
assert_contains "$out" "ERROR" "AC4 non-pool path emits ERROR"

# Repo with hyphen in name; trailing digits separated by hyphen.
out=$(parse_pool_from_pwd "/x/checkouts/foo-bar-baz-12" 2>&1)
rc=$?
assert_rc "$rc" 0 "AC4 hyphenated repo → rc=0"
assert_eq "$out" "foo-bar-baz 12" "AC4 hyphenated repo → 'foo-bar-baz 12'"

# ─── AC5: read_workers_file ────────────────────────────────────────────────

WF=$(mktemp_safe file workers)
cat > "$WF" <<'EOF'
1:1234:US-01:1700000000
malformed-line
2:abc:US-02:1700000001
3:5678:US-03:notnumeric
4:9999:US-04:1700000099

EOF
out=$(read_workers_file "$WF")
# Expect lines 1 and 4 only.
assert_contains "$out" "1:1234:US-01:1700000000" "AC5 valid worker line kept"
assert_contains "$out" "4:9999:US-04:1700000099" "AC5 second valid worker line kept"
case "$out" in
    *malformed-line*) _fail "AC5 malformed line should be skipped" ;;
    *) _pass ;;
esac
case "$out" in
    *"2:abc:"*) _fail "AC5 non-numeric pid should be skipped" ;;
    *) _pass ;;
esac
case "$out" in
    *notnumeric*) _fail "AC5 non-numeric started_at should be skipped" ;;
    *) _pass ;;
esac
rm -f "$WF"

# Missing file → no output, rc=0.
out=$(read_workers_file "/nonexistent/path/workers.txt")
rc=$?
assert_rc "$rc" 0 "AC5 missing file → rc=0"
assert_eq "$out" "" "AC5 missing file → empty output"

# ─── AC6: next_dispatchable ────────────────────────────────────────────────

out=$(next_dispatchable "$FIXTURE_DIR/dispatchable-multiple_pending.json")
assert_eq "$out" "US-A" "AC6 highest-priority pending wins (priority=1)"

out=$(next_dispatchable "$FIXTURE_DIR/dispatchable-in_review_queue.json")
assert_eq "$out" "US-A" "AC6 pending A returned (B blocked)"

out=$(next_dispatchable "$FIXTURE_DIR/dispatchable-empty.json")
assert_eq "$out" "" "AC6 empty PRD → empty output"

# All passes:true → empty.
TMP_PRD=$(mktemp_safe file ac6-alldone)
cat > "$TMP_PRD" <<'JSON'
{"userStories":[{"id":"US-A","priority":1,"passes":true}]}
JSON
out=$(next_dispatchable "$TMP_PRD")
assert_eq "$out" "" "AC6 all done → empty output"
rm -f "$TMP_PRD"

# ─── AC7: mktemp_safe (rev5b R28) ──────────────────────────────────────────

# Default file: returns a path with 8 random chars in place of XXXXXXXX.
unset TMPDIR
F=$(mktemp_safe file ac7-default)
assert_rc "$?" 0 "AC7 file default → rc=0"
[ -f "$F" ] && _pass || _fail "AC7 file default → file exists"
# Suffix is exactly 8 chars (no extra X's, no -t prefix).
suffix=${F##*/ac7-default.}
if [ ${#suffix} -eq 8 ]; then
    _pass
else
    _fail "AC7 file default → suffix length 8 (got ${#suffix} from '$suffix')"
fi
rm -f "$F"

# dir mode returns an existing directory.
D=$(mktemp_safe dir ac7-dir)
assert_rc "$?" 0 "AC7 dir mode → rc=0"
[ -d "$D" ] && _pass || _fail "AC7 dir mode → directory exists"
rmdir "$D" 2>/dev/null || rm -rf "$D"

# TMPDIR=/tmp/ → trailing slash stripped (no // in path).
TMPDIR=/tmp/ F=$(mktemp_safe file ac7-trailing)
case "$F" in
    *//*) _fail "AC7 TMPDIR trailing slash → got // in '$F'" ;;
    /tmp/ac7-trailing.*) _pass ;;
    *) _fail "AC7 TMPDIR trailing slash → unexpected path '$F'" ;;
esac
rm -f "$F"

# (a) TMPDIR=/path/inexistente → fallback /tmp + WARN to stderr.
err=$(TMPDIR=/path/that/does/not/exist mktemp_safe file ac7-fallback 2>&1 >/dev/null)
F=$(TMPDIR=/path/that/does/not/exist mktemp_safe file ac7-fallback 2>/dev/null)
assert_contains "$err" "WARN" "AC7 (a) bad TMPDIR → WARN emitted"
case "$F" in
    /tmp/ac7-fallback.*) _pass ;;
    *) _fail "AC7 (a) bad TMPDIR → fallback to /tmp (got '$F')" ;;
esac
rm -f "$F"

# (b) TMPDIR=/dev/null → fallback /tmp.
F=$(TMPDIR=/dev/null mktemp_safe file ac7-devnull 2>/dev/null)
case "$F" in
    /tmp/ac7-devnull.*) _pass ;;
    *) _fail "AC7 (b) TMPDIR=/dev/null → fallback to /tmp (got '$F')" ;;
esac
rm -f "$F"

# (c) Both TMPDIR and the fallback unwritable → return 1 with
# 'no writable tmpdir found' on stderr. We use a chmod-555 sandbox for both
# locations via the MKTEMP_SAFE_FALLBACK env var (the fallback path is
# injectable precisely so this branch can be exercised without chmod-ing the
# real /tmp). This calls mktemp_safe directly — no shim, no tautology.
SANDBOX=$(mktemp -d "/tmp/ac7-readonly.XXXXXXXX")
chmod 555 "$SANDBOX"

# First sub-case: bad TMPDIR but writable fallback → WARN + success on /tmp.
err=$(TMPDIR="$SANDBOX" mktemp_safe file ac7-rofallback 2>&1 >/dev/null)
F=$(TMPDIR="$SANDBOX" mktemp_safe file ac7-rofallback 2>/dev/null)
assert_contains "$err" "WARN" "AC7 (c) read-only TMPDIR → WARN emitted"
case "$F" in
    /tmp/ac7-rofallback.*) _pass ;;
    *) _fail "AC7 (c) read-only TMPDIR → fallback to /tmp (got '$F')" ;;
esac
rm -f "$F"

# Both-dead sub-case: TMPDIR and the injected fallback both point at the
# read-only sandbox. mktemp_safe must return 1 and emit the ERROR message.
ro_err=$(TMPDIR="$SANDBOX" MKTEMP_SAFE_FALLBACK="$SANDBOX" \
    mktemp_safe file ac7-bothdead 2>&1 >/dev/null)
ro_rc=$?
assert_rc "$ro_rc" 1 "AC7 (c) both unwritable → rc=1"
assert_contains "$ro_err" "no writable tmpdir found" "AC7 (c) both unwritable → ERROR message"

chmod 755 "$SANDBOX"
rm -rf "$SANDBOX"

# Negative: bad type → ERROR + rc=1.
err=$(mktemp_safe garbage label 2>&1 >/dev/null)
rc=$?
assert_rc "$rc" 1 "AC7 bad type → rc=1"
assert_contains "$err" "ERROR" "AC7 bad type → ERROR message"

# Lint guard: dispatch.sh must NOT use `mktemp -t` and must use 8 X's.
grep -nE 'mktemp[[:space:]]+-t' "$LIB_DIR/dispatch.sh" >/dev/null
if [ $? -eq 0 ]; then
    _fail "AC7 lint: dispatch.sh uses 'mktemp -t' (forbidden by rev5b R28)"
else
    _pass
fi
grep -nE '\.X{8}([^X]|$)' "$LIB_DIR/dispatch.sh" >/dev/null
assert_rc "$?" 0 "AC7 lint: dispatch.sh template has exactly 8 X's"

# ─── AC8: with_validated_slot ──────────────────────────────────────────────

# Happy path: validate succeeds → callback runs → phase=completed.
SLOT=$(mktemp_safe dir slot-happy)
# Stub callback echoes 'hello' to a sentinel file.
SENTINEL="$SLOT/sentinel.txt"
cb_happy() { echo "hello" > "$SENTINEL"; }
layer_a_validate() { return 0; }
with_validated_slot "$SLOT" cb_happy
rc=$?
assert_rc "$rc" 0 "AC8 happy → rc=0"
[ -f "$SENTINEL" ] && _pass || _fail "AC8 happy → callback ran (sentinel exists)"
phase=$(get_slot_phase "$SLOT")
assert_eq "$phase" "completed" "AC8 happy → phase=completed"
# Phase file is exactly 1 line.
lines=$(wc -l < "$SLOT/.slot-phase" | tr -d ' ')
assert_eq "$lines" "1" "AC8 happy → .slot-phase has 1 line"
rm -rf "$SLOT"

# Failure path: validate dies → callback NOT called, phase=layer_a_failed, rc=1.
SLOT=$(mktemp_safe dir slot-fail)
SENTINEL="$SLOT/sentinel.txt"
cb_should_not_run() { echo "should not run" > "$SENTINEL"; }
layer_a_validate() { echo "validate dying" >&2; exit 1; }
( with_validated_slot "$SLOT" cb_should_not_run ) 2>/dev/null
rc=$?
# Restore stub for subsequent tests.
layer_a_validate() { return 0; }
assert_rc "$rc" 1 "AC8 fail → rc=1"
[ ! -f "$SENTINEL" ] && _pass || _fail "AC8 fail → callback NOT called (no sentinel)"
phase=$(get_slot_phase "$SLOT")
assert_eq "$phase" "layer_a_failed" "AC8 fail → phase=layer_a_failed"
rm -rf "$SLOT"

# set -e propagation: with_validated_slot returning 1 should abort under set -e.
SLOT=$(mktemp_safe dir slot-sete)
layer_a_validate() { exit 1; }
out=$(set -e; with_validated_slot "$SLOT" true; echo "REACHED" 2>&1) 2>/dev/null
layer_a_validate() { return 0; }
case "$out" in
    *REACHED*) _fail "AC8 set -e → should NOT reach post-call line" ;;
    *) _pass ;;
esac
rm -rf "$SLOT"

# ─── AC9: set_slot_phase atomic + race ─────────────────────────────────────

SLOT=$(mktemp_safe dir slot-race)
# Tmpfile naming: must use $$.
set_slot_phase "$SLOT" "phaseA"
# After the call, no leftover .tmp.* files (mv removed them).
leftovers=$(ls "$SLOT"/.slot-phase.tmp.* 2>/dev/null | wc -l | tr -d ' ')
assert_eq "$leftovers" "0" "AC9 no leftover .tmp files"
phase=$(get_slot_phase "$SLOT")
assert_eq "$phase" "phaseA" "AC9 single write readable"

# Race: spawn N=20 set_slot_phase processes in parallel with different phase
# strings; final .slot-phase must be one of them, never corrupted/partial.
# Use `bash -c` to fork real processes so each writer has its own $$ (bash 3.2
# subshells inherit the parent's $$, which would defeat the suffix uniqueness).
SLOT2=$(mktemp_safe dir slot-race2)
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    bash -c "source '$LIB_DIR/dispatch.sh'; set_slot_phase '$SLOT2' 'phase_${i}'" &
done
wait
# Final phase: one valid line, content matches phase_<digits>.
final=$(get_slot_phase "$SLOT2")
case "$final" in
    phase_[0-9]*) _pass ;;
    *) _fail "AC9 race → final corrupted: '$final'" ;;
esac
# .slot-phase exists and is exactly 1 line.
lines=$(wc -l < "$SLOT2/.slot-phase" | tr -d ' ')
assert_eq "$lines" "1" "AC9 race → final .slot-phase is 1 line"
# No leftover .tmp.* (each process cleaned its own via mv).
leftovers=$(ls "$SLOT2"/.slot-phase.tmp.* 2>/dev/null | wc -l | tr -d ' ')
assert_eq "$leftovers" "0" "AC9 race → no leftover .tmp.* files"

# Lint guard: implementation does NOT use `declare -A` (bash 3.2 compat).
grep -nE '\bdeclare\b[[:space:]]+-A' "$LIB_DIR/dispatch.sh" >/dev/null
if [ $? -eq 0 ]; then
    _fail "AC9 lint: dispatch.sh uses 'declare -A' (bash 3.2 incompatible)"
else
    _pass
fi
rm -rf "$SLOT" "$SLOT2"

# ─── AC10: PRECONDITION (file-based, no bash 4 hard requirement) ───────────

# dispatch.sh sources cleanly under bash 3.2 (this very test runs under it).
# We confirm there's no `declare -A` / `mapfile` / `readarray` USE (skip
# comments, which legitimately mention the words in the bash-3.2 rationale).
grep -vE '^[[:space:]]*#' "$LIB_DIR/dispatch.sh" \
    | grep -nE '(mapfile|readarray)' >/dev/null
if [ $? -eq 0 ]; then
    _fail "AC10 lint: dispatch.sh uses mapfile/readarray (bash 4+)"
else
    _pass
fi

# assert_layer_a_done: invariant violation in 'uninit' phase.
SLOT=$(mktemp_safe dir slot-assert)
out=$( ( assert_layer_a_done "$SLOT" ) 2>&1 )
rc=$?
assert_rc "$rc" 1 "assert_layer_a_done uninit → exit 1"
assert_contains "$out" "INVARIANT VIOLATION" "assert_layer_a_done uninit → INVARIANT VIOLATION"
# Now mark completed and confirm it passes.
set_slot_phase "$SLOT" "completed"
( assert_layer_a_done "$SLOT" ) 2>/dev/null
assert_rc "$?" 0 "assert_layer_a_done completed → ok"
rm -rf "$SLOT"

# ─── US-05 AC7: version_ge ─────────────────────────────────────────────────

version_ge "2.9.0"  "2.9.0"  && _pass || _fail "version_ge 2.9.0 == 2.9.0"
version_ge "2.39.5" "2.9.0"  && _pass || _fail "version_ge 2.39.5 >= 2.9.0"
version_ge "2.10.0" "2.9.0"  && _pass || _fail "version_ge 2.10.0 >= 2.9.0  (numeric, not lexical)"
version_ge "2.5.0"  "2.9.0"  && _fail "version_ge 2.5.0 should NOT be >= 2.9.0" || _pass
version_ge "1.99.0" "2.0.0"  && _fail "version_ge 1.99 < 2.0 (major dominates)" || _pass
version_ge "3.0.0"  "2.9.0"  && _pass || _fail "version_ge 3.0.0 >= 2.9.0"
# Prerelease/build suffix on patch: stripped, treated as numeric only.
version_ge "2.39.5-rc1" "2.9.0" && _pass || _fail "version_ge with prerelease suffix"
# git --version output third field is exactly the dotted form.
version_ge "$(echo 'git version 2.39.5 (Apple Git-154)' | awk '{print $3}')" "2.9" \
    && _pass || _fail "version_ge real git --version parse"
# Two-component version (no patch).
version_ge "2.9"   "2.9.0" && _pass || _fail "version_ge 2.9 (no patch) == 2.9.0"
version_ge "2.8"   "2.9"   && _fail "version_ge 2.8 < 2.9" || _pass

# ─── US-05 AC6: preflight_slot reflog gating ───────────────────────────────

# Stub git_* helpers; restore real versions afterwards. Pattern matches the
# one used by layer_a_validate elsewhere in this file.
git_reflog_setting_for_slot() { echo "false"; }
git_version_for_slot()        { echo "2.39.5"; }
out=$( ( preflight_slot /fake/slot ) 2>&1 )
rc=$?
assert_rc "$rc" 1 "AC6 reflog=false → preflight rc=1"
assert_contains "$out" "core.logAllRefUpdates"  "AC6 message names the setting"
assert_contains "$out" "Camada A'"              "AC6 message references Camada A'"

git_reflog_setting_for_slot() { echo "true"; }
preflight_slot /fake/slot
assert_rc "$?" 0 "AC6 reflog=true + git=2.39 → preflight ok"

# Empty config (default) must NOT trip the reflog gate (git's default is true).
git_reflog_setting_for_slot() { echo ""; }
preflight_slot /fake/slot
assert_rc "$?" 0 "AC6 reflog setting empty (default) → preflight ok"

# ─── US-05 AC7: preflight_slot git version gating ──────────────────────────

git_reflog_setting_for_slot() { echo "true"; }
git_version_for_slot()        { echo "2.5.0"; }
out=$( ( preflight_slot /fake/slot ) 2>&1 )
rc=$?
assert_rc "$rc" 1 "AC7 git 2.5 → preflight rc=1"
assert_contains "$out" "2.9" "AC7 message names 2.9 requirement"

# Empty version string should also fail with a clear message.
git_version_for_slot() { echo ""; }
out=$( ( preflight_slot /fake/slot ) 2>&1 )
rc=$?
assert_rc "$rc" 1 "AC7 empty version → preflight rc=1"
assert_contains "$out" "git --version" "AC7 message names git --version source"

# Restore the real implementations for subsequent tests.
git_reflog_setting_for_slot() { git -C "$1" config --get core.logAllRefUpdates 2>/dev/null; }
git_version_for_slot()        { git -C "$1" --version 2>/dev/null | awk '{print $3}'; }

# ─── US-05: count_pool_slots ───────────────────────────────────────────────

POOL_DIR=$(mktemp_safe dir pool-count)
mkdir -p "$POOL_DIR/myrepo-1" "$POOL_DIR/myrepo-2" "$POOL_DIR/myrepo-3"
cat > "$POOL_DIR/.myrepo.pool" <<'EOF'
repo_name=myrepo
slots=3
EOF
assert_eq "$(count_pool_slots "$POOL_DIR" myrepo)" "3" "count from .pool file"

# Pool file absent → fall back to ls.
rm "$POOL_DIR/.myrepo.pool"
assert_eq "$(count_pool_slots "$POOL_DIR" myrepo)" "3" "count by ls fallback"

# Malformed slots= line → ls fallback (not a partial integer parse).
cat > "$POOL_DIR/.myrepo.pool" <<'EOF'
slots=oops
EOF
assert_eq "$(count_pool_slots "$POOL_DIR" myrepo)" "3" "count: malformed slots= → ls fallback"
rm "$POOL_DIR/.myrepo.pool"

# Single slot → 1 (AC4 prerequisite).
mkdir -p "$POOL_DIR/lonely-1"
assert_eq "$(count_pool_slots "$POOL_DIR" lonely)" "1" "count single slot → 1"

# Repo absent entirely → 0.
assert_eq "$(count_pool_slots "$POOL_DIR" nope)"   "0" "count missing repo → 0"
assert_eq "$(count_pool_slots "/nonexistent" any)" "0" "count missing pool dir → 0"
rm -rf "$POOL_DIR"

# ─── US-04: touchesFiles disjunction gate ──────────────────────────────────

# Pure helper: literal prefix normalization (SKILL.md algorithm step 1 —
# substring up to the first glob metacharacter *, ?, [).
assert_eq "$(touches_literal_prefix 'bin/*.sh')"       "bin/"           "US-04 prefix: * meta → bin/"
assert_eq "$(touches_literal_prefix 'bin/tests/x.sh')" "bin/tests/x.sh" "US-04 prefix: no meta → whole glob"
assert_eq "$(touches_literal_prefix 'bin/foo.sh')"     "bin/foo.sh"     "US-04 prefix: dot is NOT a meta"
assert_eq "$(touches_literal_prefix 'src/?.c')"        "src/"           "US-04 prefix: ? meta → src/"
assert_eq "$(touches_literal_prefix 'a[bc]d')"         "a"              "US-04 prefix: [ meta → a"

# Pure helper: prefixes_intersect (SKILL.md step 2 — one is a string-prefix
# of the other).
prefixes_intersect "bin/" "bin/tests/x.sh" && _pass || _fail "US-04 'bin/' is prefix of 'bin/tests/x.sh' → intersect"
prefixes_intersect "bin/foo.sh" "bin/"     && _pass || _fail "US-04 'bin/' is prefix of 'bin/foo.sh' → intersect"
prefixes_intersect "bin/a.sh" "docs/b.md"  && _fail "US-04 disjoint prefixes must NOT intersect" || _pass
prefixes_intersect "bin/a.sh" "bin/b.sh"   && _fail "US-04 sibling files (neither a prefix) must NOT intersect" || _pass

# AC4: glob case — ['bin/*.sh'] vs ['bin/tests/x.sh'] intersect because the
# literal prefix 'bin/' is a prefix of 'bin/tests/x.sh' (conservative).
TMP_PRD=$(mktemp_safe file ac4-glob)
cat > "$TMP_PRD" <<'JSON'
{
  "userStories": [
    {"id":"US-A","priority":1,"passes":false,"touchesFiles":["bin/*.sh"]},
    {"id":"US-B","priority":2,"passes":false,"touchesFiles":["bin/tests/x.sh"]}
  ]
}
JSON
stories_touch_intersect "US-A" "US-B" "$TMP_PRD" && _pass || _fail "AC4 bin/*.sh ∩ bin/tests/x.sh → intersect"
assert_eq "$(next_dispatchable_excluding "$TMP_PRD" "US-A")" "" "AC4 US-A in-flight → US-B serialized (empty)"
rm -f "$TMP_PRD"

# AC1: intersecting touchesFiles (['bin/foo.sh'] vs ['bin/']) → the second is
# NOT co-dispatched while the first is in-flight.
TMP_PRD=$(mktemp_safe file ac1-intersect)
cat > "$TMP_PRD" <<'JSON'
{
  "userStories": [
    {"id":"US-A","priority":1,"passes":false,"touchesFiles":["bin/foo.sh"]},
    {"id":"US-B","priority":2,"passes":false,"touchesFiles":["bin/"]}
  ]
}
JSON
assert_eq "$(next_dispatchable_excluding "$TMP_PRD" "")"     "US-A" "AC1 nothing in-flight → US-A first"
assert_eq "$(next_dispatchable_excluding "$TMP_PRD" "US-A")" ""     "AC1 US-A in-flight → US-B blocked (intersect)"
rm -f "$TMP_PRD"

# AC2: disjoint touchesFiles (['bin/a.sh'] vs ['docs/b.md']) → co-dispatch in
# the same tick (US-A in-flight, US-B still selected).
TMP_PRD=$(mktemp_safe file ac2-disjoint)
cat > "$TMP_PRD" <<'JSON'
{
  "userStories": [
    {"id":"US-A","priority":1,"passes":false,"touchesFiles":["bin/a.sh"]},
    {"id":"US-B","priority":2,"passes":false,"touchesFiles":["docs/b.md"]}
  ]
}
JSON
stories_touch_intersect "US-A" "US-B" "$TMP_PRD" && _fail "AC2 disjoint must NOT intersect" || _pass
assert_eq "$(next_dispatchable_excluding "$TMP_PRD" "US-A")" "US-B" "AC2 US-A in-flight → US-B co-dispatched"
rm -f "$TMP_PRD"

# AC3: a story without the touchesFiles field is dispatchable with no extra
# restriction — pre-US-04 behavior preserved.
# (a) candidate lacks touchesFiles, in-flight declares one → candidate ok.
TMP_PRD=$(mktemp_safe file ac3-cand-absent)
cat > "$TMP_PRD" <<'JSON'
{
  "userStories": [
    {"id":"US-A","priority":1,"passes":false,"touchesFiles":["bin/"]},
    {"id":"US-B","priority":2,"passes":false}
  ]
}
JSON
stories_touch_intersect "US-A" "US-B" "$TMP_PRD" && _fail "AC3 absent field → no intersect" || _pass
assert_eq "$(next_dispatchable_excluding "$TMP_PRD" "US-A")" "US-B" "AC3 US-B (no touchesFiles) co-dispatched despite US-A bin/"
rm -f "$TMP_PRD"

# (b) candidate declares touchesFiles, in-flight does NOT → candidate ok.
TMP_PRD=$(mktemp_safe file ac3-inflight-absent)
cat > "$TMP_PRD" <<'JSON'
{
  "userStories": [
    {"id":"US-A","priority":1,"passes":false},
    {"id":"US-B","priority":2,"passes":false,"touchesFiles":["bin/foo.sh"]}
  ]
}
JSON
assert_eq "$(next_dispatchable_excluding "$TMP_PRD" "US-A")" "US-B" "AC3 in-flight without touchesFiles → US-B unrestricted"
rm -f "$TMP_PRD"

# (c) an empty touchesFiles array behaves like an absent field.
TMP_PRD=$(mktemp_safe file ac3-empty)
cat > "$TMP_PRD" <<'JSON'
{
  "userStories": [
    {"id":"US-A","priority":1,"passes":false,"touchesFiles":[]},
    {"id":"US-B","priority":2,"passes":false,"touchesFiles":["bin/foo.sh"]}
  ]
}
JSON
stories_touch_intersect "US-A" "US-B" "$TMP_PRD" && _fail "AC3 empty array → no intersect" || _pass
assert_eq "$(next_dispatchable_excluding "$TMP_PRD" "US-A")" "US-B" "AC3 empty touchesFiles array → unrestricted"
rm -f "$TMP_PRD"

# Regression: the dependsOn gate still composes with the new touchesFiles
# gate. US-B has disjoint files but depends on the still-unfinished US-A →
# remains blocked by deps (proves the new gate did not replace the old one).
TMP_PRD=$(mktemp_safe file us04-compose)
cat > "$TMP_PRD" <<'JSON'
{
  "userStories": [
    {"id":"US-A","priority":1,"passes":false,"touchesFiles":["bin/a.sh"]},
    {"id":"US-B","priority":2,"passes":false,"touchesFiles":["docs/b.md"],"dependsOn":["US-A"]}
  ]
}
JSON
assert_eq "$(next_dispatchable_excluding "$TMP_PRD" "US-A")" "" "US-04 deps gate still blocks disjoint dependent"
rm -f "$TMP_PRD"

# ─── Report ────────────────────────────────────────────────────────────────

echo ""
echo "─────────────────────────────────────────────"
echo "PASS=$PASS  FAIL=$FAIL"
if [ $FAIL -gt 0 ]; then
    printf '%s\n' "$FAILED"
    exit 1
fi
exit 0

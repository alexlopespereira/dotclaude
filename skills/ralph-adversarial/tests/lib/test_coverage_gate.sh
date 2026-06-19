#!/usr/bin/env bash
# tests/lib/test_coverage_gate.sh — TDD coverage for coverage-gate.sh (US-01).
#
# Inline assertion harness (no bats), capture-proof: every assert-of-absence is
# paired with an assert-of-presence proving the relevant stub actually ran.
#
# All external deps (git, diff-cover, coverage, c8, bashcov, kcov) are replaced
# by a single dispatcher stub that logs argv to $STUB_CALL_LOG and simulates
# output. The script reaches them ONLY through the seam env vars
# COVERAGE_GATE_<DEP>, so the call-log is proof the seam routed correctly.
#
# Harness state (call-logs, project dirs) lives OUTSIDE the repo (mktemp -d in
# TMPDIR) — never inside the repo under test (AGENTS.md: framework pre-flight
# aborts on stray untracked files).

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/../../lib" && pwd)"
SCRIPT="$LIB_DIR/coverage-gate.sh"

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
assert_rc_zero() {
    local rc="$1" msg="$2"
    if [ "$rc" -eq 0 ]; then _pass
    else _fail "$msg :: expected rc=0 got rc=$rc"; fi
}
assert_rc_nonzero() {
    local rc="$1" msg="$2"
    if [ "$rc" -ne 0 ]; then _pass
    else _fail "$msg :: expected rc!=0 got rc=0"; fi
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
        *) _fail "$msg :: '$needle' not found in <<<$haystack>>>" ;;
    esac
}
assert_not_contains() {
    local haystack="$1" needle="$2" msg="$3"
    case "$haystack" in
        *"$needle"*) _fail "$msg :: '$needle' unexpectedly found in <<<$haystack>>>" ;;
        *) _pass ;;
    esac
}

# ─── Stub toolchain ───────────────────────────────────────────────────────
STUBROOT="$(mktemp -d "${TMPDIR:-/tmp}/covgate-stubs.XXXXXXXX")"
cat > "$STUBROOT/_dispatch" <<'STUB'
#!/usr/bin/env bash
# Generic tool stub. Dispatches on basename, logs argv, simulates output.
set -u
name=$(basename "$0")
printf '%s %s\n' "$name" "$*" >> "${STUB_CALL_LOG:?STUB_CALL_LOG unset}"
case "$name" in
  git)
    case "${1:-}" in
      fetch) exit "${STUB_GIT_FETCH_RC:-0}" ;;
      diff)  printf '%s\n' "${STUB_GIT_DIFF:-}"; exit 0 ;;
      *)     exit 0 ;;
    esac
    ;;
  diff-cover)
    printf 'Coverage: %s%%\n' "${STUB_DIFFCOVER_PCT:-100}"
    exit "${STUB_DIFFCOVER_RC:-0}"
    ;;
  coverage)
    # `coverage run` is the test runner; its rc must surface to --gate.
    if [ "${1:-}" = "run" ]; then exit "${STUB_COVERAGE_RUN_RC:-0}"; fi
    if [ "${1:-}" = "lcov" ]; then
      out=""
      while [ $# -gt 0 ]; do
        case "$1" in
          -o) out="${2:-}"; shift ;;
          -o*) out="${1#-o}" ;;
        esac
        shift
      done
      [ -n "$out" ] && printf '%s' "${STUB_LCOV:-}" > "$out"
    fi
    exit 0
    ;;
  c8)
    dir=""
    prev=""
    for a in "$@"; do
      case "$a" in --report-dir=*) dir="${a#--report-dir=}" ;; esac
      [ "$prev" = "--report-dir" ] && dir="$a"
      prev="$a"
    done
    [ -n "$dir" ] && { mkdir -p "$dir"; printf '%s' "${STUB_LCOV:-}" > "$dir/lcov.info"; }
    # c8 wraps the test command; its rc must surface to --gate.
    exit "${STUB_C8_RC:-0}"
    ;;
  bashcov)
    mkdir -p coverage
    printf '%s' "${STUB_LCOV:-}" > coverage/lcov.info
    exit "${STUB_BASHCOV_RC:-0}"
    ;;
  kcov)
    # Invocation: kcov --output-interface=lcov <reportdir> <testcmd...>
    dir=""
    for a in "$@"; do
      case "$a" in
        --*) : ;;
        *) [ -z "$dir" ] && dir="$a" ;;
      esac
    done
    [ -n "$dir" ] && { mkdir -p "$dir"; printf '%s' "${STUB_LCOV:-}" > "$dir/lcov.info"; }
    exit "${STUB_KCOV_RC:-0}"
    ;;
esac
exit 0
STUB
chmod +x "$STUBROOT/_dispatch"
for tool in git diff-cover coverage c8 bashcov kcov; do
    cp "$STUBROOT/_dispatch" "$STUBROOT/$tool"
    chmod +x "$STUBROOT/$tool"
done

# Seam wiring (all six deps point at stubs).
export COVERAGE_GATE_GIT="$STUBROOT/git"
export COVERAGE_GATE_DIFF_COVER="$STUBROOT/diff-cover"
export COVERAGE_GATE_COVERAGE="$STUBROOT/coverage"
export COVERAGE_GATE_C8="$STUBROOT/c8"
export COVERAGE_GATE_BASHCOV="$STUBROOT/bashcov"
export COVERAGE_GATE_KCOV="$STUBROOT/kcov"

# LCOV fixtures.
LCOV_BRANCH='SF:foo.py
DA:1,1
DA:2,1
LF:2
LH:2
BRF:4
BRH:3
end_of_record'
LCOV_LINEONLY='SF:foo.sh
DA:1,1
DA:2,1
DA:3,0
LF:3
LH:2
end_of_record'

# Per-test scratch.
new_log() { STUB_CALL_LOG="$(mktemp "${TMPDIR:-/tmp}/covgate-log.XXXXXXXX")"; export STUB_CALL_LOG; }
new_proj() { mktemp -d "${TMPDIR:-/tmp}/covgate-proj.XXXXXXXX"; }

cleanup() { rm -rf "$STUBROOT"; }
trap cleanup EXIT

# ─── AC1: script exists, shebang, set -u, executable ──────────────────────
if [ -f "$SCRIPT" ]; then _pass; else _fail "AC1 script exists at $SCRIPT"; fi
assert_eq "$(head -1 "$SCRIPT" 2>/dev/null)" "#!/usr/bin/env bash" "AC1 shebang"
if grep -q '^set -u' "$SCRIPT" 2>/dev/null; then _pass; else _fail "AC1 set -u present"; fi
if [ -x "$SCRIPT" ]; then _pass; else _fail "AC1 script is executable (0755)"; fi

# ─── cat-9-base b3: arg/usage validation (no side effects) ────────────────
out=$("$SCRIPT" 2>&1); rc=$?
assert_rc "$rc" 2 "b3 no mode → rc=2"
assert_contains "$out" "Usage" "b3 no mode → usage on stderr"

out=$("$SCRIPT" --report 2>&1); rc=$?
assert_rc "$rc" 2 "b3 --report without --lang → rc=2"

out=$("$SCRIPT" --bogus 2>&1); rc=$?
assert_rc "$rc" 2 "b3 unknown flag → rc=2"

out=$("$SCRIPT" --report --gate --lang python 2>&1); rc=$?
assert_rc "$rc" 2 "b3 both modes → rc=2"

# ─── cat-9-base b4: numeric form/range validation before arithmetic ───────
out=$("$SCRIPT" --gate --lang python --epsilon abc 2>&1); rc=$?
assert_rc "$rc" 2 "b4 non-numeric epsilon → rc=2"

out=$("$SCRIPT" --gate --lang python --epsilon 99999 2>&1); rc=$?
assert_rc "$rc" 2 "b4 out-of-range epsilon → rc=2 (no overflow path)"

# ─── AC2 + AC7: --report exit0 + seam call-log (python, branch present) ────
new_log
proj=$(new_proj)
STUB_DIFFCOVER_PCT=87 STUB_DIFFCOVER_RC=0 STUB_LCOV="$LCOV_BRANCH" \
  bash -c 'cd "$1" && "$2" --report --lang python --report-dir "$1/rd" \
    --test-cmd pytest --progress-file "$1/progress.txt"' _ "$proj" "$SCRIPT"
rc=$?
assert_rc_zero "$rc" "AC2 --report exit 0 (coverage 87% < 100%, advisory)"
prog=$(cat "$proj/progress.txt" 2>/dev/null)
assert_contains "$prog" "COVERAGE_DIFF=87%" "AC2 COVERAGE_DIFF=87% written to progress.txt"
log=$(cat "$STUB_CALL_LOG")
# Capture-proof: positive asserts that the seam routed to each stub.
assert_contains "$log" "git fetch" "AC7 git seam invoked (fetch)"
assert_contains "$log" "coverage" "AC7 coverage seam invoked"
assert_contains "$log" "diff-cover" "AC7 diff-cover seam invoked"
# AC9: branch% derived from lcov data (75%), NOT hardcoded.
assert_contains "$prog" "COVERAGE_BRANCH=75.00%" "AC9 branch% computed from BRF/BRH (75%)"
rm -rf "$proj"

# ─── AC2 advisory: coverage way below 100 still exit 0 ────────────────────
new_log
proj=$(new_proj)
STUB_DIFFCOVER_PCT=40 STUB_DIFFCOVER_RC=0 STUB_LCOV="$LCOV_BRANCH" \
  bash -c 'cd "$1" && "$2" --report --lang python --report-dir "$1/rd" \
    --progress-file "$1/progress.txt"' _ "$proj" "$SCRIPT"
rc=$?
assert_rc_zero "$rc" "AC2 advisory: 40% still exit 0"
assert_contains "$(cat "$proj/progress.txt")" "COVERAGE_DIFF=40%" "AC2 40% written"
rm -rf "$proj"

# ─── AC6: git fetch fails → COVERAGE_REPORT_SKIPPED, exit 0, no diff-cover ─
new_log
proj=$(new_proj)
STUB_GIT_FETCH_RC=1 STUB_DIFFCOVER_PCT=99 STUB_LCOV="$LCOV_BRANCH" \
  bash -c 'cd "$1" && "$2" --report --lang python --report-dir "$1/rd" \
    --progress-file "$1/progress.txt"' _ "$proj" "$SCRIPT"
rc=$?
assert_rc_zero "$rc" "AC6 fetch-fail → exit 0"
assert_contains "$(cat "$proj/progress.txt")" "COVERAGE_REPORT_SKIPPED" "AC6 skip marker written"
log=$(cat "$STUB_CALL_LOG")
# Capture-proof pair: git fetch DID run (positive) but diff-cover did NOT (negative).
assert_contains "$log" "git fetch" "AC6 capture-proof: git fetch ran"
assert_not_contains "$log" "diff-cover" "AC6 diff-cover NOT called against stale base"
rm -rf "$proj"

# ─── AC5/AC9: bash via bashcov → branch=n/a (line-only) ───────────────────
new_log
proj=$(new_proj)
STUB_DIFFCOVER_PCT=100 STUB_DIFFCOVER_RC=0 STUB_LCOV="$LCOV_LINEONLY" \
  bash -c 'cd "$1" && "$2" --report --lang bash --test-cmd "bin/tests/run-all.sh" \
    --progress-file "$1/progress.txt"' _ "$proj" "$SCRIPT"
rc=$?
assert_rc_zero "$rc" "AC5 bash --report exit 0"
prog=$(cat "$proj/progress.txt")
assert_contains "$prog" "COVERAGE_BRANCH=n/a" "AC5 bash branch=n/a (NOT 0%)"
assert_not_contains "$prog" "COVERAGE_BRANCH=0" "AC5 bash branch is not reported as 0%"
log=$(cat "$STUB_CALL_LOG")
assert_contains "$log" "bashcov" "AC5 capture-proof: bashcov stub ran"
rm -rf "$proj"

# ─── AC7: kcov seam (bash fallback / explicit --bash-tool kcov) ───────────
new_log
proj=$(new_proj)
STUB_DIFFCOVER_PCT=100 STUB_DIFFCOVER_RC=0 STUB_LCOV="$LCOV_LINEONLY" \
  bash -c 'cd "$1" && "$2" --report --lang bash --bash-tool kcov \
    --report-dir "$1/rd" --test-cmd "bin/tests/run-all.sh" \
    --progress-file "$1/progress.txt"' _ "$proj" "$SCRIPT"
rc=$?
assert_rc_zero "$rc" "AC7 bash --bash-tool kcov exit 0"
log=$(cat "$STUB_CALL_LOG")
assert_contains "$log" "kcov" "AC7 capture-proof: kcov seam invoked"
assert_not_contains "$log" "bashcov" "AC7 bashcov NOT called when kcov selected"
rm -rf "$proj"

# ─── AC3: --gate diff-cover --fail-under=100 fails → exit != 0 ────────────
new_log
proj=$(new_proj)
echo '{"total": 50}' > "$proj/.coverage-baseline.json"
STUB_DIFFCOVER_PCT=80 STUB_DIFFCOVER_RC=1 STUB_LCOV="$LCOV_BRANCH" \
  bash -c 'cd "$1" && "$2" --gate --lang python --report-dir "$1/rd" \
    --baseline "$1/.coverage-baseline.json"' _ "$proj" "$SCRIPT"
rc=$?
assert_rc_nonzero "$rc" "AC3 --gate patch<100% → exit != 0"
log=$(cat "$STUB_CALL_LOG")
assert_contains "$log" "diff-cover" "AC3 capture-proof: diff-cover ran with --fail-under"
assert_contains "$log" "fail-under=100" "AC3 diff-cover called with --fail-under=100"
rm -rf "$proj"

# ─── --gate happy path: diff-cover passes + ratchet ok → exit 0 ──────────
new_log
proj=$(new_proj)
echo '{"total": 50}' > "$proj/.coverage-baseline.json"
STUB_DIFFCOVER_PCT=100 STUB_DIFFCOVER_RC=0 STUB_LCOV="$LCOV_BRANCH" STUB_GIT_DIFF="" \
  bash -c 'cd "$1" && "$2" --gate --lang python --report-dir "$1/rd" \
    --baseline "$1/.coverage-baseline.json"' _ "$proj" "$SCRIPT"
rc=$?
assert_rc_zero "$rc" "--gate patch 100% + ratchet ok → exit 0"
rm -rf "$proj"

# ─── AC4: ratchet — current total < baseline-epsilon → exit != 0 ─────────
new_log
proj=$(new_proj)
# line-only lcov → line% = 2/3 = 66.67; baseline 90 → below ratchet.
echo '{"total": 90}' > "$proj/.coverage-baseline.json"
baseline_before=$(cat "$proj/.coverage-baseline.json")
STUB_DIFFCOVER_PCT=100 STUB_DIFFCOVER_RC=0 STUB_LCOV="$LCOV_LINEONLY" STUB_GIT_DIFF="" \
  bash -c 'cd "$1" && "$2" --gate --lang python --report-dir "$1/rd" \
    --baseline "$1/.coverage-baseline.json" --epsilon 0.5' _ "$proj" "$SCRIPT"
rc=$?
assert_rc_nonzero "$rc" "AC4 ratchet violated (66.67 < 90-0.5) → exit != 0"
# AC4: baseline NEVER auto-committed/mutated by the script.
assert_eq "$(cat "$proj/.coverage-baseline.json")" "$baseline_before" "AC4 baseline file byte-unchanged"
log=$(cat "$STUB_CALL_LOG")
assert_not_contains "$log" "git add" "AC4 no git add of baseline"
assert_not_contains "$log" "git commit" "AC4 no git commit of baseline"
rm -rf "$proj"

# ─── ratchet pass: current total >= baseline-epsilon → exit 0 ────────────
new_log
proj=$(new_proj)
echo '{"total": 60}' > "$proj/.coverage-baseline.json"
STUB_DIFFCOVER_PCT=100 STUB_DIFFCOVER_RC=0 STUB_LCOV="$LCOV_LINEONLY" STUB_GIT_DIFF="" \
  bash -c 'cd "$1" && "$2" --gate --lang python --report-dir "$1/rd" \
    --baseline "$1/.coverage-baseline.json" --epsilon 0.5' _ "$proj" "$SCRIPT"
rc=$?
assert_rc_zero "$rc" "ratchet ok (66.67 >= 60-0.5) → exit 0"
rm -rf "$proj"

# ─── cat-9-base b7: --report idempotent (block replaced, not appended) ────
new_log
proj=$(new_proj)
for _i in 1 2; do
  STUB_DIFFCOVER_PCT=87 STUB_DIFFCOVER_RC=0 STUB_LCOV="$LCOV_BRANCH" \
    bash -c 'cd "$1" && "$2" --report --lang python --report-dir "$1/rd" \
      --progress-file "$1/progress.txt"' _ "$proj" "$SCRIPT"
done
markers=$(grep -c 'coverage-gate:begin' "$proj/progress.txt")
assert_eq "$markers" "1" "b7 idempotent: exactly one coverage block after 2 runs"
rm -rf "$proj"

# ─── pragma gate: new unjustified pragma fails; justified passes ──────────
new_log
proj=$(new_proj)
echo '{"total": 50}' > "$proj/.coverage-baseline.json"
STUB_DIFFCOVER_PCT=100 STUB_DIFFCOVER_RC=0 STUB_LCOV="$LCOV_BRANCH" \
STUB_GIT_DIFF='+    raise RuntimeError  # pragma: no cover' \
  bash -c 'cd "$1" && "$2" --gate --lang python --report-dir "$1/rd" \
    --baseline "$1/.coverage-baseline.json"' _ "$proj" "$SCRIPT"
rc=$?
assert_rc_nonzero "$rc" "pragma: new unjustified '# pragma: no cover' → exit != 0"

new_log
STUB_DIFFCOVER_PCT=100 STUB_DIFFCOVER_RC=0 STUB_LCOV="$LCOV_BRANCH" \
STUB_GIT_DIFF='+    raise RuntimeError  # pragma: no cover -- defensive, unreachable by construction' \
  bash -c 'cd "$1" && "$2" --gate --lang python --report-dir "$1/rd" \
    --baseline "$1/.coverage-baseline.json"' _ "$proj" "$SCRIPT"
rc=$?
assert_rc_zero "$rc" "pragma: justified pragma (text after marker) → exit 0"
rm -rf "$proj"

# ─── AC7: js via c8 seam → call-log proves c8 invoked (lcovonly) ──────────
new_log
proj=$(new_proj)
STUB_DIFFCOVER_PCT=92 STUB_DIFFCOVER_RC=0 STUB_LCOV="$LCOV_BRANCH" \
  bash -c 'cd "$1" && "$2" --report --lang js --report-dir "$1/rd" \
    --test-cmd "npm test" --progress-file "$1/progress.txt"' _ "$proj" "$SCRIPT"
rc=$?
assert_rc_zero "$rc" "AC7 --lang js --report exit 0"
assert_contains "$(cat "$proj/progress.txt")" "COVERAGE_DIFF=92%" "AC7 js diff-coverage written"
log=$(cat "$STUB_CALL_LOG")
assert_contains "$log" "c8" "AC7 capture-proof: c8 seam invoked for js"
assert_contains "$log" "reporter=lcovonly" "AC7 c8 invoked with --reporter=lcovonly"
rm -rf "$proj"

# ─── AC7: liquid also routes through the c8 seam (same branch) ────────────
new_log
proj=$(new_proj)
STUB_DIFFCOVER_PCT=100 STUB_DIFFCOVER_RC=0 STUB_LCOV="$LCOV_BRANCH" \
  bash -c 'cd "$1" && "$2" --report --lang liquid --report-dir "$1/rd" \
    --test-cmd "npm test" --progress-file "$1/progress.txt"' _ "$proj" "$SCRIPT"
rc=$?
assert_rc_zero "$rc" "AC7 --lang liquid --report exit 0"
log=$(cat "$STUB_CALL_LOG")
assert_contains "$log" "c8" "AC7 capture-proof: c8 seam invoked for liquid"
rm -rf "$proj"

# ─── AC3 (review fix): failing runner fails the gate even if lcov is valid ─
# A pytest/c8/bashcov that exits !=0 must NOT be swallowed by `|| true`; a
# stale/partial-but-valid lcov that satisfies diff-cover/ratchet must still
# fail --gate because the suite did not pass.
new_log
proj=$(new_proj)
echo '{"total": 50}' > "$proj/.coverage-baseline.json"
STUB_DIFFCOVER_PCT=100 STUB_DIFFCOVER_RC=0 STUB_LCOV="$LCOV_BRANCH" STUB_GIT_DIFF="" \
STUB_COVERAGE_RUN_RC=1 \
  bash -c 'cd "$1" && "$2" --gate --lang python --report-dir "$1/rd" \
    --baseline "$1/.coverage-baseline.json"' _ "$proj" "$SCRIPT"
rc=$?
assert_rc_nonzero "$rc" "AC3 gate: failing python runner (rc=1) → exit != 0 despite diff-cover/ratchet ok"
rm -rf "$proj"

# ─── AC3 (review fix): failing bashcov runner fails the gate ──────────────
new_log
proj=$(new_proj)
echo '{"total": 50}' > "$proj/.coverage-baseline.json"
STUB_DIFFCOVER_PCT=100 STUB_DIFFCOVER_RC=0 STUB_LCOV="$LCOV_LINEONLY" STUB_GIT_DIFF="" \
STUB_BASHCOV_RC=1 \
  bash -c 'cd "$1" && "$2" --gate --lang bash --report-dir "$1/rd" \
    --test-cmd "bin/tests/run-all.sh" --baseline "$1/.coverage-baseline.json"' _ "$proj" "$SCRIPT"
rc=$?
assert_rc_nonzero "$rc" "AC3 gate: failing bashcov runner (rc=1) → exit != 0"
rm -rf "$proj"

# ─── AC2 (review fix): failing runner stays advisory in --report (exit 0) ──
new_log
proj=$(new_proj)
STUB_DIFFCOVER_PCT=100 STUB_DIFFCOVER_RC=0 STUB_LCOV="$LCOV_BRANCH" \
STUB_COVERAGE_RUN_RC=1 \
  bash -c 'cd "$1" && "$2" --report --lang python --report-dir "$1/rd" \
    --progress-file "$1/progress.txt"' _ "$proj" "$SCRIPT"
rc=$?
assert_rc_zero "$rc" "AC2 advisory: failing runner still exit 0 in --report (never blocks loop)"
rm -rf "$proj"

# ─── Wiring (P0-1): o loop Ralph chama coverage-gate.sh --report ────────────
# Sem call site, a metade in-loop advisory do R2 é dead code (era o órfão).
LOOP="$LIB_DIR/../ralph-adversarial.sh"
if grep -q 'lib/coverage-gate.sh' "$LOOP"; then assert_rc_zero 0 "P0-1 wiring: loop referencia lib/coverage-gate.sh"; else assert_rc_zero 1 "P0-1 wiring: loop NAO referencia o gate (orphan)"; fi
if grep -Eq '\-\-report --lang' "$LOOP"; then assert_rc_zero 0 "P0-1 wiring: loop invoca --report --lang (advisory)"; else assert_rc_zero 1 "P0-1 wiring: loop NAO invoca --report (orphan)"; fi

# ─── Report ────────────────────────────────────────────────────────────────
echo ""
echo "─────────────────────────────────────────────"
echo "PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then
    printf '%s\n' "$FAILED"
    exit 1
fi
exit 0

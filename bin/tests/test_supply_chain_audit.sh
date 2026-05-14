#!/usr/bin/env bash
# bin/tests/test_supply_chain_audit.sh — testes do audit log JSONL.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB="$SCRIPT_DIR/../lib/supply-chain"
# shellcheck source=../lib/supply-chain/audit.sh
. "$LIB/audit.sh"

PASS=0; FAIL=0; FAILED=""
_pass(){ PASS=$((PASS+1)); }
_fail(){ FAIL=$((FAIL+1)); FAILED="${FAILED}
  ✗ $1"; }
assert_eq() { [ "$2" = "$1" ] && _pass || _fail "$3 :: expected='$1' actual='$2'"; }
assert_file_exists() { [ -f "$1" ] && _pass || _fail "$2 :: missing '$1'"; }

WORKSPACE=$(mktemp -d)
trap 'rm -rf "$WORKSPACE"' EXIT
export SC_AUDIT_LOG="$WORKSPACE/audit.jsonl"

echo "=== sc_audit_log tests ==="

# T01: append simple → file exists, 1 line, schema OK
sc_audit_log "allow" "echo ok" ""
assert_file_exists "$SC_AUDIT_LOG" "T01a file created"
lines=$(wc -l < "$SC_AUDIT_LOG"); assert_eq "1" "$(echo "$lines" | tr -d ' ')" "T01b 1 line"

valid=$(jq -e '. as $obj | $obj.ts and $obj.cwd and $obj.decision and $obj.command' "$SC_AUDIT_LOG" >/dev/null && echo "ok" || echo "fail")
assert_eq "ok" "$valid" "T01c schema valid"

# T02: reason="" → JSON null (jq without -r prints null literal as "null")
got_reason=$(jq '.reason' "$SC_AUDIT_LOG")
assert_eq "null" "$got_reason" "T02 empty reason → null"

# T03: reason populated stored as string
: > "$SC_AUDIT_LOG"
sc_audit_log "bypass" "npm install foo" "CVE patch"
got=$(jq -r '.reason' "$SC_AUDIT_LOG")
assert_eq "CVE patch" "$got" "T03 reason captured as string"

# T04: decision field exact
got=$(jq -r '.decision' "$SC_AUDIT_LOG")
assert_eq "bypass" "$got" "T04 decision"

# T05: command field captured
got=$(jq -r '.command' "$SC_AUDIT_LOG")
assert_eq "npm install foo" "$got" "T05 command"

# T06: cwd captured
got=$(jq -r '.cwd' "$SC_AUDIT_LOG")
assert_eq "$PWD" "$got" "T06 cwd"

# T07: timestamp is ISO-8601 with Z suffix
got=$(jq -r '.ts' "$SC_AUDIT_LOG")
case "$got" in
  20[0-9][0-9]-[0-1][0-9]-[0-3][0-9]T[0-2][0-9]:[0-5][0-9]:[0-5][0-9]Z) _pass ;;
  *) _fail "T07 ts format: '$got'" ;;
esac

# T08: multiple appends → N lines, each JSON
: > "$SC_AUDIT_LOG"
for i in 1 2 3 4 5; do
  sc_audit_log "allow" "cmd-$i" ""
done
n=$(wc -l < "$SC_AUDIT_LOG" | tr -d ' ')
assert_eq "5" "$n" "T08 5 appends"

# All lines valid JSON?
while IFS= read -r line; do
  echo "$line" | jq -e . >/dev/null 2>&1 || _fail "T08b invalid JSON line: $line"
done < "$SC_AUDIT_LOG"
# If we got here without _fail, count one pass for the loop
_pass

# T09: concurrent append — 30 background processes, all 30 lines must end up
: > "$SC_AUDIT_LOG"
for i in $(seq 1 30); do
  ( sc_audit_log "allow" "concurrent-$i" "" ) &
done
wait
n=$(wc -l < "$SC_AUDIT_LOG" | tr -d ' ')
assert_eq "30" "$n" "T09 concurrent 30 appends preserved"

# All lines valid JSON?
bad=0
while IFS= read -r line; do
  echo "$line" | jq -e . >/dev/null 2>&1 || bad=$((bad+1))
done < "$SC_AUDIT_LOG"
assert_eq "0" "$bad" "T09b all concurrent lines valid JSON"

# T10: rotation — force tiny threshold and verify shift behavior
SC_AUDIT_MAX_BYTES=200
export SC_AUDIT_MAX_BYTES
: > "$SC_AUDIT_LOG"

# Generate enough lines to cross 200 bytes
for i in $(seq 1 10); do
  sc_audit_log "allow" "rotation-trigger-$i" ""
done

# After rotation, audit.jsonl should exist (fresh or near-fresh) AND audit-1.jsonl should have old content
assert_file_exists "$SC_AUDIT_LOG" "T10a active still present"
assert_file_exists "${WORKSPACE}/audit-1.jsonl" "T10b historic-1 created"

# T11: rotation chain — force enough rotations to fill historic-5
SC_AUDIT_MAX_BYTES=100
export SC_AUDIT_MAX_BYTES
: > "$SC_AUDIT_LOG"
rm -f "${WORKSPACE}"/audit-*.jsonl

for round in 1 2 3 4 5 6 7; do
  for i in $(seq 1 5); do
    sc_audit_log "allow" "round-${round}-msg-${i}" ""
  done
done

# Should have audit-1 through audit-5, no audit-6
assert_file_exists "${WORKSPACE}/audit-1.jsonl" "T11a -1 present"
assert_file_exists "${WORKSPACE}/audit-5.jsonl" "T11b -5 present"
[ ! -f "${WORKSPACE}/audit-6.jsonl" ] && _pass || _fail "T11c -6 must NOT exist (only 5 historics)"

# T12: manual rotation
unset SC_AUDIT_MAX_BYTES
: > "$SC_AUDIT_LOG"
rm -f "${WORKSPACE}"/audit-*.jsonl
sc_audit_log "allow" "before-manual-rotate" ""
sc_audit_rotate
[ -s "$SC_AUDIT_LOG" ] && _fail "T12a active should be empty after manual rotate" || _pass
got=$(jq -r '.command' "${WORKSPACE}/audit-1.jsonl")
assert_eq "before-manual-rotate" "$got" "T12b historic-1 has pre-rotate line"

# T13: reason with quotes/special chars (JSON escape via jq)
: > "$SC_AUDIT_LOG"
sc_audit_log "bypass" 'npm install "tricky"' 'reason with "quotes" and \backslash'
# Must be valid JSON
echo -n ""
got=$(jq -r '.reason' "$SC_AUDIT_LOG" 2>/dev/null || echo "PARSE_FAIL")
assert_eq 'reason with "quotes" and \backslash' "$got" "T13 reason with special chars"

# T14: command with newlines (rare but possible)
: > "$SC_AUDIT_LOG"
sc_audit_log "allow" "echo line1
line2" ""
n=$(wc -l < "$SC_AUDIT_LOG" | tr -d ' ')
# JSON itself stays on one line; jq escapes embedded \n
assert_eq "1" "$n" "T14 newline in command stays on one JSONL line"

# T15: missing args (no-op safe — should not crash)
: > "$SC_AUDIT_LOG"
sc_audit_log "" "" "" 2>/dev/null
n=$(wc -l < "$SC_AUDIT_LOG" | tr -d ' ')
assert_eq "1" "$n" "T15 even empty-arg call writes one line"

echo ""
echo "PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then
  echo "Failed tests:$FAILED"
  exit 1
fi
exit 0

#!/usr/bin/env bash
# test_vm_common.sh — fonte única do mapping VM→IP (P2 batch item 4).
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=/dev/null
source "$REPO_ROOT/bin/lib/vm-common.sh"

PASS=0; FAIL=0; FAILED=""
_pass() { PASS=$((PASS+1)); }
_fail() { FAIL=$((FAIL+1)); FAILED="${FAILED}
  ✗ $1"; }

[ "$(vm_ip 1)" = "192.0.2.11" ] && _pass || _fail "vm_ip 1 → .4"
[ "$(vm_ip 2)" = "192.0.2.12" ] && _pass || _fail "vm_ip 2 → .2"
vm_ip 3 >/dev/null 2>&1 && _fail "vm_ip 3 deveria falhar" || _pass
vm_ip   >/dev/null 2>&1 && _fail "vm_ip vazio deveria falhar" || _pass
[ "$VM_COMMON_USER" = "dev" ] && _pass || _fail "VM_COMMON_USER"
# consumidores realmente usam a lib (anti-regressão da dedup):
grep -q "vm-common.sh" "$REPO_ROOT/bin/vm-oauth.sh"     && _pass || _fail "vm-oauth não usa a lib"
grep -q "vm-common.sh" "$REPO_ROOT/bin/vm-provision.sh" && _pass || _fail "vm-provision não usa a lib"
# e não restam case-mappings duplicados (atribuição `N) ip=`/`IP=`) fora da
# lib — menção a IP em comentário/usage é doc, não mapping, e é tolerada:
DUP=$(grep -rlnE '\)[[:space:]]*(IP|ip)="192\.168' "$REPO_ROOT/bin" --include="*.sh" | grep -v "lib/vm-common.sh" | grep -v "tests/" || true)
[ -z "$DUP" ] && _pass || _fail "case-mapping de IP fora da lib: $DUP"

echo "test_vm_common.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -gt 0 ] && { echo "FALHAS:$FAILED" >&2; exit 1; }
exit 0

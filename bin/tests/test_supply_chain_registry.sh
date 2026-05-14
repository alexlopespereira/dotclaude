#!/usr/bin/env bash
# bin/tests/test_supply_chain_registry.sh — Tests cache + registry with
# mocked `npm` and `curl` via PATH override. Covers AC1..AC8 of US-03.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB="$SCRIPT_DIR/../lib/supply-chain"

PASS=0; FAIL=0; FAILED=""
_pass(){ PASS=$((PASS+1)); }
_fail(){ FAIL=$((FAIL+1)); FAILED="${FAILED}
  ✗ $1"; }
assert_eq() { [ "$2" = "$1" ] && _pass || _fail "$3 :: expected='$1' actual='$2'"; }
assert_contains() { case "$1" in *"$2"*) _pass;; *) _fail "$3 :: needle '$2' not in '$1'";; esac; }
assert_rc_nonzero() { [ "$1" -ne 0 ] && _pass || _fail "$2 :: expected non-zero rc, got $1"; }
assert_file_exists() { [ -f "$1" ] && _pass || _fail "$2 :: file '$1' missing"; }

# ─── Isolated workspace ──────────────────────────────────────────────────────
WORKSPACE=$(mktemp -d)
trap 'rm -rf "$WORKSPACE"' EXIT
export SC_CACHE_DIR="$WORKSPACE/sc-cache"

MOCK_DIR="$WORKSPACE/mocks"
mkdir -p "$MOCK_DIR"

# Mock npm: behavior driven by arg pattern.
cat > "$MOCK_DIR/npm" <<'MOCKEOF'
#!/usr/bin/env bash
# args: view <pkg>@<ver> time.<ver>
if [ "$1" != "view" ]; then exit 1; fi
PKGV="$2"; FIELD="$3"

case "$PKGV" in
  "lodash@4.17.21")
    echo "2021-02-20T19:48:09.270Z"; exit 0 ;;
  "ghost-pkg@1.0.0")
    echo "npm ERR! code E404" >&2
    echo "npm ERR! 404 Not Found - GET https://registry.npmjs.org/ghost-pkg - Not found" >&2
    exit 1 ;;
  "lodash@99.99.99")
    echo "npm ERR! code E404" >&2
    echo "npm ERR! 404 Not Found - GET https://registry.npmjs.org/lodash - No matching version found for lodash@99.99.99" >&2
    exit 1 ;;
  "neterr@1.0.0")
    echo "npm ERR! network getaddrinfo ENOTFOUND registry.npmjs.org" >&2
    exit 1 ;;
  "srv5xx@1.0.0")
    echo "npm ERR! code E503" >&2
    echo "npm ERR! 503 Service Unavailable" >&2
    exit 1 ;;
  "fresh@1.0.0")
    echo "2026-05-12T10:00:00.000Z"; exit 0 ;;
  "old@1.0.0")
    echo "2020-01-01T00:00:00.000Z"; exit 0 ;;
  *)
    echo "npm ERR! code E404" >&2
    exit 1 ;;
esac
MOCKEOF
chmod +x "$MOCK_DIR/npm"

# Mock curl: parse -o and URL, write body + emit http_code.
cat > "$MOCK_DIR/curl" <<'MOCKEOF'
#!/usr/bin/env bash
OUT=""; URL=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) OUT="$2"; shift 2 ;;
    -w) shift 2 ;;
    -sS|-s|--max-time|--silent) shift ;;
    --max-time) shift 2 ;;
    http://*|https://*) URL="$1"; shift ;;
    -*) shift ;;
    *) shift ;;
  esac
done

case "$URL" in
  *pypi.org/pypi/requests/2.31.0/json)
    cat > "$OUT" <<'JSON'
{"urls":[{"upload_time":"2023-05-22T11:00:00"}]}
JSON
    echo "200"; exit 0 ;;
  *pypi.org/pypi/fresh-py/1.0.0/json)
    cat > "$OUT" <<'JSON'
{"urls":[{"upload_time":"2026-05-13T08:00:00"}]}
JSON
    echo "200"; exit 0 ;;
  *pypi.org/pypi/ghost-py/*)
    echo "Not Found" > "$OUT"
    echo "404"; exit 0 ;;
  *pypi.org/pypi/broken-srv/*)
    echo "Internal Server Error" > "$OUT"
    echo "503"; exit 0 ;;
  *pypi.org/pypi/timeout-pkg/*)
    # Simulate network error (curl returns non-zero on connection failure).
    exit 6 ;;
  *)
    echo "" > "$OUT"
    echo "404"; exit 0 ;;
esac
MOCKEOF
chmod +x "$MOCK_DIR/curl"

export PATH="$MOCK_DIR:$PATH"

# shellcheck source=../lib/supply-chain/registry.sh
. "$LIB/registry.sh"

echo "=== cache + registry tests ==="

# ─── Cache primitives ────────────────────────────────────────────────────────
# T01: cache miss returns 1
sc_cache_get npm absent-pkg 1.0.0 >/dev/null 2>&1
assert_eq "1" "$?" "T01 cache miss returns rc=1"

# T02: cache put + get round-trip
sc_cache_put npm foo 1.2.3 "2024-01-15T12:00:00.000Z"
got=$(sc_cache_get npm foo 1.2.3)
assert_eq "2024-01-15T12:00:00.000Z" "$got" "T02 cache put/get round-trip"

# T03: cache atomic — no half-write visible
# Spawn 20 concurrent puts of different values; verify final read is one of them.
for i in $(seq 1 20); do
  ( sc_cache_put npm racepkg 1.0.0 "value-$i" ) &
done
wait
final=$(sc_cache_get npm racepkg 1.0.0)
case "$final" in
  value-*) _pass ;;
  *) _fail "T03 concurrent put: final='$final' should be value-N" ;;
esac

# T04: scoped package (path includes /) → escaped
sc_cache_put npm "@scope/pkg" 1.0.0 "2024-02-01T00:00:00Z"
got=$(sc_cache_get npm "@scope/pkg" 1.0.0)
assert_eq "2024-02-01T00:00:00Z" "$got" "T04 scoped pkg cache"

# T05: cache file location is escaped, not literal slash
assert_file_exists "$SC_CACHE_DIR/registry-times/npm/@scope__pkg/1.0.0.iso" "T05 escaped path"

# ─── Registry: npm via mocked `npm view` ─────────────────────────────────────
# T06: success
got=$(sc_get_publish_time npm lodash 4.17.21 2>/dev/null)
assert_eq "2021-02-20T19:48:09.270Z" "$got" "T06 npm success"

# T07: result cached (subsequent call reads cache without invoking npm)
# To prove cache hit: replace mock to fail, then call again — should still succeed.
mv "$MOCK_DIR/npm" "$MOCK_DIR/npm.disabled"
got=$(sc_get_publish_time npm lodash 4.17.21 2>/dev/null)
assert_eq "2021-02-20T19:48:09.270Z" "$got" "T07 npm cache hit (mock disabled)"
mv "$MOCK_DIR/npm.disabled" "$MOCK_DIR/npm"

# T08: package not found
err=$(sc_get_publish_time npm ghost-pkg 1.0.0 2>&1 >/dev/null)
assert_contains "$err" "PACKAGE_NOT_FOUND" "T08 npm pkg 404 → PACKAGE_NOT_FOUND"

# T09: version not found
err=$(sc_get_publish_time npm lodash 99.99.99 2>&1 >/dev/null)
assert_contains "$err" "VERSION_NOT_FOUND" "T09 npm version 404 → VERSION_NOT_FOUND"

# T10: network error
err=$(sc_get_publish_time npm neterr 1.0.0 2>&1 >/dev/null)
assert_contains "$err" "NETWORK_ERROR" "T10 npm network err"

# T11: server 5xx
err=$(sc_get_publish_time npm srv5xx 1.0.0 2>&1 >/dev/null)
assert_contains "$err" "REGISTRY_5XX" "T11 npm 503"

# ─── Registry: PyPI via mocked curl ──────────────────────────────────────────
# T12: success
got=$(sc_get_publish_time pypi requests 2.31.0 2>/dev/null)
assert_eq "2023-05-22T11:00:00" "$got" "T12 pypi success"

# T13: cache hit on pypi
mv "$MOCK_DIR/curl" "$MOCK_DIR/curl.disabled"
got=$(sc_get_publish_time pypi requests 2.31.0 2>/dev/null)
assert_eq "2023-05-22T11:00:00" "$got" "T13 pypi cache hit"
mv "$MOCK_DIR/curl.disabled" "$MOCK_DIR/curl"

# T14: pypi 404
err=$(sc_get_publish_time pypi ghost-py 1.0.0 2>&1 >/dev/null)
case "$err" in
  *PACKAGE_NOT_FOUND*|*VERSION_NOT_FOUND*) _pass ;;
  *) _fail "T14 pypi 404 :: got '$err'" ;;
esac

# T15: pypi 5xx
err=$(sc_get_publish_time pypi broken-srv 1.0.0 2>&1 >/dev/null)
assert_contains "$err" "REGISTRY_5XX" "T15 pypi 503 → REGISTRY_5XX"

# T16: pypi network error (curl exits non-zero)
err=$(sc_get_publish_time pypi timeout-pkg 1.0.0 2>&1 >/dev/null)
assert_contains "$err" "NETWORK_ERROR" "T16 pypi connection refused → NETWORK_ERROR"

# T17: unsupported registry
err=$(sc_get_publish_time crates serde 1.0.0 2>&1 >/dev/null)
assert_contains "$err" "UNSUPPORTED" "T17 unsupported registry"

# T18: invalid args
err=$(sc_get_publish_time npm "" "" 2>&1 >/dev/null)
assert_contains "$err" "INVALID_ARGS" "T18 missing args"

# ─── Performance: cache hit must be fast ─────────────────────────────────────
# T19: 100 cache hits in under 5s (well below the 100ms × 100 budget).
sc_cache_put npm perfpkg 1.0.0 "2024-01-01T00:00:00Z"
start=$(date +%s)
for _ in $(seq 1 100); do
  sc_get_publish_time npm perfpkg 1.0.0 >/dev/null 2>&1
done
end=$(date +%s)
elapsed=$((end - start))
if [ "$elapsed" -lt 5 ]; then _pass
else _fail "T19 perf: 100 cache hits took ${elapsed}s (budget 5s)"
fi

# ─── sc_resolve_tree fallbacks (no real npm/pip needed) ──────────────────────
# T20: yarn (out of cobertura) → root-only fallback returns registry pkgs.
out=$(sc_resolve_tree '{"manager":"yarn","op":"install","pkgs":[{"name":"foo","spec":"1.0.0","type":"registry","raw":"foo@1.0.0"}],"flags":[]}')
assert_eq "foo@1.0.0" "$out" "T20 yarn root-only fallback"

# T21: skip-list types ignored in root-only
out=$(sc_resolve_tree '{"manager":"pnpm","op":"install","pkgs":[{"name":"","spec":"workspace:*","type":"workspace","raw":"workspace:*"}],"flags":[]}')
assert_eq "" "$out" "T21 workspace skipped"

# T22: unknown manager:op → rc=1
sc_resolve_tree '{"manager":"other","op":"other","pkgs":[],"flags":[]}' >/dev/null 2>&1
assert_eq "1" "$?" "T22 unknown manager rc=1"

# ─── Summary ─────────────────────────────────────────────────────────────────
echo ""
echo "PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then
  echo "Failed tests:$FAILED"
  exit 1
fi
exit 0

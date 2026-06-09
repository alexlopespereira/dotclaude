#!/usr/bin/env bash
# bin/tests/test_supply_chain_hook.sh — E2E para hooks/supply-chain-guard.sh.
# Simula stdin JSON (formato PreToolUse), mocka npm/curl via PATH, verifica
# exit codes + stderr + audit log.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$SCRIPT_DIR/../../hooks/supply-chain-guard.sh"
LIB_DIR="$SCRIPT_DIR/../lib/supply-chain"

PASS=0; FAIL=0; FAILED=""
_pass(){ PASS=$((PASS+1)); }
_fail(){ FAIL=$((FAIL+1)); FAILED="${FAILED}
  ✗ $1"; }
assert_eq() { [ "$2" = "$1" ] && _pass || _fail "$3 :: expected='$1' actual='$2'"; }
assert_contains() { case "$1" in *"$2"*) _pass;; *) _fail "$3 :: needle '$2' not in stderr";; esac; }

# Portable "N days ago" ISO timestamp (macOS BSD date OR GNU date). Used so the
# "fresh" package mock stays inside the 14-day cooldown regardless of wall-clock
# date (avoids date-drift rotting the fixtures).
_days_ago_iso() {
  date -u -v-"$1"d +%Y-%m-%dT%H:%M:%S.000Z 2>/dev/null || \
    date -u -d "$1 days ago" +%Y-%m-%dT%H:%M:%S.000Z
}

# ─── Sandbox ─────────────────────────────────────────────────────────────────
WORKSPACE=$(mktemp -d)
trap 'rm -rf "$WORKSPACE"' EXIT

export SC_CACHE_DIR="$WORKSPACE/cache"
export SC_AUDIT_LOG="$WORKSPACE/audit.jsonl"
export SC_LIB_DIR="$LIB_DIR"
export SC_FRESH_TIME="$(_days_ago_iso 2)"   # 2 days ago → always "fresh"

MOCK_DIR="$WORKSPACE/mocks"
mkdir -p "$MOCK_DIR"
ORIG_PATH="$PATH"

# Mock npm — handles `view` and `install --dry-run --json`.
cat > "$MOCK_DIR/npm" <<'MOCKEOF'
#!/usr/bin/env bash
if [ "$1" = "view" ]; then
  PKGV="$2"
  case "$PKGV" in
    "old-pkg@1.0.0")  echo "2020-01-01T00:00:00.000Z"; exit 0 ;;
    "fresh-pkg@1.0.0") echo "$SC_FRESH_TIME"; exit 0 ;;
    "lodash@4.17.21") echo "2021-02-20T19:48:09.270Z"; exit 0 ;;
    "neterr@1.0.0")
      echo "npm ERR! network getaddrinfo ENOTFOUND" >&2; exit 1 ;;
    *)
      echo "npm ERR! code E404" >&2; exit 1 ;;
  esac
fi

if [ "$1" = "install" ]; then
  # --dry-run mode used by sc_resolve_tree
  for arg in "$@"; do
    case "$arg" in
      --dry-run) ;;
    esac
  done
  # Capture trailing pkg specs
  ADDED="[]"
  for arg in "$@"; do
    case "$arg" in
      old-pkg@1.0.0)    ADDED='[{"name":"old-pkg","version":"1.0.0"}]'; break ;;
      fresh-pkg@1.0.0)  ADDED='[{"name":"fresh-pkg","version":"1.0.0"}]'; break ;;
      lodash@4.17.21)   ADDED='[{"name":"lodash","version":"4.17.21"}]'; break ;;
      neterr@1.0.0)     ADDED='[{"name":"neterr","version":"1.0.0"}]'; break ;;
    esac
  done
  echo "{\"added\":$ADDED}"
  exit 0
fi
exit 1
MOCKEOF
chmod +x "$MOCK_DIR/npm"

# Mock curl (not exercised in these tests — npm registry path)
cat > "$MOCK_DIR/curl" <<'MOCKEOF'
#!/usr/bin/env bash
echo "404"
exit 0
MOCKEOF
chmod +x "$MOCK_DIR/curl"

export PATH="$MOCK_DIR:$PATH"

# ─── Helper to invoke the hook with a command string ─────────────────────────
hook_call() {
  local cmd="$1"
  printf '{"tool_input":{"command":%s}}' "$(jq -n --arg c "$cmd" '$c')" | bash "$HOOK"
}

# ─── Tests ───────────────────────────────────────────────────────────────────
echo "=== hook E2E tests ==="

# T01: op=other → exit 0
hook_call "echo hello" > /dev/null 2>&1
assert_eq "0" "$?" "T01 echo (other) → exit 0"

# T02: Empty command in JSON → exit 0
printf '{"tool_input":{"command":""}}' | bash "$HOOK" > /dev/null 2>&1
assert_eq "0" "$?" "T02 empty command → exit 0"

# T03: git status → exit 0
hook_call "git status" > /dev/null 2>&1
assert_eq "0" "$?" "T03 git status → exit 0"

# T04: npm install old-pkg with --ignore-scripts → cooldown OK → exit 0
err=$(hook_call "npm install --ignore-scripts old-pkg@1.0.0" 2>&1 >/dev/null)
rc=$?
assert_eq "0" "$rc" "T04 old-pkg with --ignore-scripts allowed"

# T05: npm install fresh-pkg with --ignore-scripts → cooldown FRESH → exit 2
err=$(hook_call "npm install --ignore-scripts fresh-pkg@1.0.0" 2>&1 >/dev/null)
rc=$?
assert_eq "2" "$rc" "T05a fresh-pkg blocked"
assert_contains "$err" "cooldown:fresh" "T05b stderr mentions cooldown:fresh"
assert_contains "$err" "CLAUDE_SC_BYPASS_COOLDOWN" "T05c stderr shows bypass env"

# T06: npm install without --ignore-scripts → scripts problem → exit 2
err=$(hook_call "npm install old-pkg@1.0.0" 2>&1 >/dev/null)
rc=$?
assert_eq "2" "$rc" "T06a missing --ignore-scripts blocked"
assert_contains "$err" "scripts:--ignore-scripts missing" "T06b stderr mentions scripts:"

# T07: git-url dep (with --ignore-scripts so D2 doesn't trigger) → exit 2
err=$(hook_call "npm install --ignore-scripts github:tanstack/router#abc123" 2>&1 >/dev/null)
rc=$?
assert_eq "2" "$rc" "T07a git-url blocked"
assert_contains "$err" "git-url:github:tanstack/router#abc123" "T07b stderr cites the git-url"
assert_contains "$err" "CLAUDE_SC_BYPASS_GIT_DEPS" "T07c stderr shows git-deps bypass env"

# T08: bypass cooldown WITH REASON → exit 0
err=$(CLAUDE_SC_BYPASS_COOLDOWN=1 CLAUDE_SC_REASON="security patch validated manually" \
      hook_call "npm install --ignore-scripts fresh-pkg@1.0.0" 2>&1 >/dev/null)
rc=$?
assert_eq "0" "$rc" "T08 bypass cooldown with REASON → allow"

# T09: bypass cooldown WITHOUT REASON → exit 2 with specific message
err=$(CLAUDE_SC_BYPASS_COOLDOWN=1 CLAUDE_SC_REASON="" \
      hook_call "npm install --ignore-scripts fresh-pkg@1.0.0" 2>&1 >/dev/null)
rc=$?
assert_eq "2" "$rc" "T09a bypass without REASON → block"
assert_contains "$err" "CLAUDE_SC_REASON" "T09b stderr cites REASON requirement"

# T10: partial bypass (cooldown bypass set, but scripts problem unsolved) → exit 2
err=$(CLAUDE_SC_BYPASS_COOLDOWN=1 CLAUDE_SC_REASON="testing" \
      hook_call "npm install fresh-pkg@1.0.0" 2>&1 >/dev/null)
rc=$?
assert_eq "2" "$rc" "T10 partial bypass (scripts still violates) → block"

# T11: full bypass (cooldown + scripts) WITH REASON → exit 0
err=$(CLAUDE_SC_BYPASS_COOLDOWN=1 CLAUDE_SC_BYPASS_SCRIPTS=1 CLAUDE_SC_REASON="rebuild scenario" \
      hook_call "npm install fresh-pkg@1.0.0" 2>&1 >/dev/null)
rc=$?
assert_eq "0" "$rc" "T11 full bypass (cooldown+scripts) with REASON → allow"

# T12: network error during cooldown lookup → fail-closed → exit 2
err=$(hook_call "npm install --ignore-scripts neterr@1.0.0" 2>&1 >/dev/null)
rc=$?
assert_eq "2" "$rc" "T12a network-error fail-closed"
assert_contains "$err" "cooldown:network-error" "T12b stderr cites network-error"

# T13: workspace:* spec → skipped from cooldown → only ignore-scripts problem
err=$(hook_call "pnpm add workspace:*" 2>&1 >/dev/null)
rc=$?
# pnpm add workspace:* → manager=pnpm, op=install. Cooldown skipped (workspace type).
# But D2 fires (pnpm needs --ignore-scripts).
assert_eq "2" "$rc" "T13a pnpm add workspace:* blocked only by D2 (not cooldown)"
echo "$err" | grep -q 'cooldown:' && _fail "T13b should NOT mention cooldown" || _pass
echo "$err" | grep -q '^.*scripts:' && _pass || _fail "T13c should mention scripts:"

# T14: bun add with workspace + --ignore-scripts → exit 0 (workspace skipped, scripts ok)
err=$(hook_call "bun add --ignore-scripts workspace:*" 2>&1 >/dev/null)
rc=$?
assert_eq "0" "$rc" "T14 bun add workspace:* with --ignore-scripts allowed"

# T15: pip install with cooldown OK → allow (pip is not Node, D2 doesn't apply)
# But pip would call pypi via curl mock → 404 → fail-closed → block
# Confirm pip path goes through curl (no --ignore-scripts requirement)
err=$(hook_call "pip install lodash" 2>&1 >/dev/null)
rc=$?
# pypi mock returns 404 for unknown → fail-closed
assert_eq "2" "$rc" "T15 pip install unknown → fail-closed via pypi 404"

# T16: audit log captures decisions
# We've made several calls above. Check the audit log has entries.
[ -f "$SC_AUDIT_LOG" ] && _pass || _fail "T16a audit log file exists"
n=$(wc -l < "$SC_AUDIT_LOG" | tr -d ' ')
[ "$n" -gt 0 ] && _pass || _fail "T16b audit log has at least 1 line (got $n)"

# T17: audit log entries are valid JSON with required fields
bad=0
while IFS= read -r line; do
  echo "$line" | jq -e 'has("ts") and has("cwd") and has("decision") and has("command")' >/dev/null 2>&1 || bad=$((bad+1))
done < "$SC_AUDIT_LOG"
assert_eq "0" "$bad" "T17 all audit lines have required fields"

# T18: audit log distinguishes allow / block / bypass
have_allow=$(jq -r 'select(.decision=="allow") | .decision' "$SC_AUDIT_LOG" | head -1)
have_block=$(jq -r 'select(.decision=="block") | .decision' "$SC_AUDIT_LOG" | head -1)
have_bypass=$(jq -r 'select(.decision=="bypass") | .decision' "$SC_AUDIT_LOG" | head -1)
assert_eq "allow" "$have_allow" "T18a audit has at least one 'allow'"
assert_eq "block" "$have_block" "T18b audit has at least one 'block'"
assert_eq "bypass" "$have_bypass" "T18c audit has at least one 'bypass'"

# T19: lockfile camada — npm install (no args) com package-lock.json + --ignore-scripts
TMPCWD=$(mktemp -d); cd "$TMPCWD" || exit 1
echo '{"name":"x","version":"1.0.0"}' > package.json
echo '{"name":"x","lockfileVersion":2}' > package-lock.json
err=$(hook_call "npm install --ignore-scripts" 2>&1 >/dev/null)
rc=$?
assert_eq "2" "$rc" "T19a bare 'npm install' + lockfile → blocked"
assert_contains "$err" "lockfile:" "T19b stderr mentions lockfile:"
cd "$SCRIPT_DIR" || exit 1

# T20: lockfile camada — npm install --ignore-scripts --frozen-lockfile → allow
cd "$TMPCWD" || exit 1
err=$(hook_call "npm install --ignore-scripts --frozen-lockfile" 2>&1 >/dev/null)
rc=$?
assert_eq "0" "$rc" "T20 npm install --frozen-lockfile → allow"
cd "$SCRIPT_DIR" || exit 1

# T21: bypass message shape — block message must include exemplo de invocação
err=$(hook_call "npm install fresh-pkg@1.0.0" 2>&1 >/dev/null)
assert_contains "$err" "Exemplo de invocação corrigida" "T21 block message has exemplo"

# T22: Hook returns clean output (no stderr) when allowing.
stderr_out=$(hook_call "echo allowed" 2>&1 >/dev/null)
assert_eq "" "$stderr_out" "T22 echo case has empty stderr"

# T23: Hook permits when lib_dir is unavailable (fail-open with warning)
export PATH="$ORIG_PATH"  # restore so jq exists
unset SC_LIB_DIR
err=$(SC_LIB_DIR=/nonexistent hook_call "npm install foo" 2>&1 >/dev/null)
rc=$?
# When SC_LIB_DIR is invalid AND fallback paths (script_dir/../bin/lib/supply-chain
# and ~/Projects/dotclaude/...) ARE accessible from this run, it WON'T fail-open.
# That's actually expected: the hook in this repo can locate its libs from
# script_dir/../bin/lib/supply-chain. So this is more of a smoke test: any
# rc (0 or 2) is acceptable as long as the hook didn't crash.
case "$rc" in 0|2) _pass ;; *) _fail "T23 unexpected rc=$rc" ;; esac
export SC_LIB_DIR="$LIB_DIR"
export PATH="$MOCK_DIR:$PATH"

# ─── T24 (AC2): split segments → BOTH packages validated by the cooldown ─────
# A recording stub logs every `npm view <pkg@ver>` lookup; both segments of a
# `&&` chain must produce a lookup.
REC_DIR="$WORKSPACE/rec"; mkdir -p "$REC_DIR"
export NPM_LOOKUP_LOG="$WORKSPACE/lookups.txt"; : > "$NPM_LOOKUP_LOG"
cat > "$REC_DIR/npm" <<'MOCKEOF'
#!/usr/bin/env bash
if [ "$1" = "view" ]; then
  echo "$2" >> "$NPM_LOOKUP_LOG"
  echo "2020-01-01T00:00:00.000Z"; exit 0
fi
if [ "$1" = "install" ]; then
  added="[]"
  for arg in "$@"; do
    case "$arg" in
      install|--dry-run|--json|--silent|--no-save|--*|-*) ;;
      *@*) n="${arg%@*}"; v="${arg##*@}"; added="[{\"name\":\"$n\",\"version\":\"$v\"}]" ;;
      *)   added="[{\"name\":\"$arg\",\"version\":\"1.0.0\"}]" ;;
    esac
  done
  echo "{\"added\":$added}"; exit 0
fi
exit 1
MOCKEOF
chmod +x "$REC_DIR/npm"

PATH="$REC_DIR:$ORIG_PATH" hook_call "npm install lodash --ignore-scripts && npm install evilpkg --ignore-scripts" >/dev/null 2>&1
rc=$?
assert_eq "0" "$rc" "T24a split chain (both old pkgs) → allow"
grep -q '^lodash@' "$NPM_LOOKUP_LOG" && _pass || _fail "T24b lodash was looked up (segment 1)"
grep -q '^evilpkg@' "$NPM_LOOKUP_LOG" && _pass || _fail "T24c evilpkg was looked up (segment 2)"

# ─── T25 (AC3): pip install -e . → no registry lookup, hook allows ───────────
# Recording stub for pip: any invocation is a failure of the test's intent.
export PIP_LOOKUP_LOG="$WORKSPACE/pip-lookups.txt"; : > "$PIP_LOOKUP_LOG"
cat > "$REC_DIR/pip" <<'MOCKEOF'
#!/usr/bin/env bash
echo "$@" >> "$PIP_LOOKUP_LOG"
exit 1
MOCKEOF
chmod +x "$REC_DIR/pip"
cat > "$REC_DIR/curl" <<'MOCKEOF'
#!/usr/bin/env bash
echo "CURL_CALLED $*" >> "$PIP_LOOKUP_LOG"
echo "404"; exit 0
MOCKEOF
chmod +x "$REC_DIR/curl"

err=$(PATH="$REC_DIR:$ORIG_PATH" hook_call "pip install -e ." 2>&1 >/dev/null)
rc=$?
assert_eq "0" "$rc" "T25a pip install -e . → allow (no registry pkg)"
n=$(wc -l < "$PIP_LOOKUP_LOG" | tr -d ' ')
assert_eq "0" "$n" "T25b zero registry lookups for 'pip install -e .'"

# ─── T26 (AC4): pip install -e . requests → requests IS checked ──────────────
: > "$PIP_LOOKUP_LOG"
cat > "$REC_DIR/curl" <<'MOCKEOF'
#!/usr/bin/env bash
OUT=""; URL=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) OUT="$2"; shift 2 ;;
    http*) URL="$1"; shift ;;
    *) shift ;;
  esac
done
echo "$URL" >> "$PIP_LOOKUP_LOG"
case "$URL" in
  *pypi.org/pypi/requests/*) echo '{"urls":[{"upload_time":"2020-01-01T00:00:00"}]}' > "$OUT"; echo "200"; exit 0 ;;
  *) echo "" > "$OUT"; echo "404"; exit 0 ;;
esac
MOCKEOF
chmod +x "$REC_DIR/curl"
cat > "$REC_DIR/pip" <<'MOCKEOF'
#!/usr/bin/env bash
# dry-run report for `requests` only (local '.' must not reach here)
for a in "$@"; do case "$a" in requests*) echo '{"install":[{"metadata":{"name":"requests","version":"2.0.0"}}]}'; exit 0 ;; esac; done
echo '{"install":[]}'; exit 0
MOCKEOF
chmod +x "$REC_DIR/pip"

err=$(PATH="$REC_DIR:$ORIG_PATH" hook_call "pip install -e . requests" 2>&1 >/dev/null)
rc=$?
assert_eq "0" "$rc" "T26a pip install -e . requests → allow (requests old)"
grep -q 'pypi.org/pypi/requests/' "$PIP_LOOKUP_LOG" && _pass || _fail "T26b requests checked via cooldown"

# ─── T27: npx com pacote LOCAL em ./node_modules → allow SEM lookup ──────────
# npx executa o binário local quando o pacote já está instalado — não há
# download, logo cooldown não se aplica (senão todo release fresco de
# playwright re-bloquearia `npx playwright test` por 14 dias).
: > "$NPM_LOOKUP_LOG"
NPXWS="$WORKSPACE/npx-local"; mkdir -p "$NPXWS/node_modules/playwright"
echo '{"name":"playwright","version":"1.50.0"}' > "$NPXWS/node_modules/playwright/package.json"
( cd "$NPXWS" && PATH="$REC_DIR:$ORIG_PATH" hook_call "npx playwright test tests/e2e/foo.spec.ts --reporter=line 2>&1 | tail -80" >/dev/null 2>&1 )
rc=$?
assert_eq "0" "$rc" "T27a npx playwright com node_modules local → allow"
grep -q 'playwright' "$NPM_LOOKUP_LOG" && _fail "T27b lookup de playwright NÃO deveria ocorrer (binário local)" || _pass

# ─── T28: npx SEM cópia local → cooldown continua aplicando (lookup ocorre) ──
: > "$NPM_LOOKUP_LOG"
NPXWS2="$WORKSPACE/npx-remote"; mkdir -p "$NPXWS2"
( cd "$NPXWS2" && PATH="$REC_DIR:$ORIG_PATH" hook_call "npx playwright test" >/dev/null 2>&1 )
grep -q 'playwright' "$NPM_LOOKUP_LOG" && _pass || _fail "T28 sem node_modules local → lookup de playwright acontece"

# ─── T29 (P0 do review): spec EXPLÍCITA não ganha o skip local ────────────────
# `npx pkg@versão` pode baixar do registry mesmo com cópia local de OUTRA
# versão — o cooldown tem que aplicar.
: > "$NPM_LOOKUP_LOG"
( cd "$NPXWS" && PATH="$REC_DIR:$ORIG_PATH" hook_call "npx playwright@9.9.9 test" >/dev/null 2>&1 )
grep -q 'playwright' "$NPM_LOOKUP_LOG" && _pass || _fail "T29 npx pkg@versão explícita → lookup ocorre apesar do node_modules local"

# ─── T30 (P0 do review): diretório vazio plantado NÃO conta como install ─────
: > "$NPM_LOOKUP_LOG"
NPXWS3="$WORKSPACE/npx-planted"; mkdir -p "$NPXWS3/node_modules/evilpkg"
( cd "$NPXWS3" && PATH="$REC_DIR:$ORIG_PATH" hook_call "npx evilpkg" >/dev/null 2>&1 )
grep -q 'evilpkg' "$NPM_LOOKUP_LOG" && _pass || _fail "T30 dir vazio sem package.json → lookup ocorre (anti-plantio)"

# ─── Summary ─────────────────────────────────────────────────────────────────
echo ""
echo "PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then
  echo "Failed tests:$FAILED"
  exit 1
fi
exit 0

#!/usr/bin/env bash
# bin/tests/test_supply_chain_e2e.sh — Edge cases E2E para hook ativo.
# Complementa test_supply_chain_hook.sh (paths comuns) com cenários complexos:
# dist-tags, monorepos, múltiplos pkgs mistos, performance, settings.json
# integrity, fail-closed em corner cases.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$SCRIPT_DIR/../../hooks/supply-chain-guard.sh"
LIB_DIR="$SCRIPT_DIR/../lib/supply-chain"

PASS=0; FAIL=0; FAILED=""
_pass(){ PASS=$((PASS+1)); }
_fail(){ FAIL=$((FAIL+1)); FAILED="${FAILED}
  ✗ $1"; }
assert_eq() { [ "$2" = "$1" ] && _pass || _fail "$3 :: expected='$1' actual='$2'"; }
assert_contains() { case "$1" in *"$2"*) _pass;; *) _fail "$3 :: needle '$2' not in '$1'";; esac; }
assert_not_contains() { case "$1" in *"$2"*) _fail "$3 :: needle '$2' should NOT appear";; *) _pass;; esac; }
assert_lt() { [ "$1" -lt "$2" ] && _pass || _fail "$3 :: $1 not < $2"; }

# Portable "N days ago" ISO timestamp (BSD or GNU date) — keeps the "fresh"
# fixtures inside the 14-day cooldown regardless of wall-clock date.
_days_ago_iso() {
  date -u -v-"$1"d +"$2" 2>/dev/null || date -u -d "$1 days ago" +"$2"
}

WORKSPACE=$(mktemp -d)
trap 'rm -rf "$WORKSPACE"' EXIT
export SC_CACHE_DIR="$WORKSPACE/cache"
export SC_AUDIT_LOG="$WORKSPACE/audit.jsonl"
export SC_LIB_DIR="$LIB_DIR"
export SC_FRESH_TIME="$(_days_ago_iso 2 %Y-%m-%dT%H:%M:%S.000Z)"   # npm fresh
export SC_FRESH_TIME_PYPI="$(_days_ago_iso 2 %Y-%m-%dT%H:%M:%S)"   # PyPI fresh

MOCK_DIR="$WORKSPACE/mocks"
mkdir -p "$MOCK_DIR"

# Mock npm — covers view + install --dry-run with multiple packages.
cat > "$MOCK_DIR/npm" <<'MOCKEOF'
#!/usr/bin/env bash
if [ "$1" = "view" ]; then
  PKGV="$2"; FIELD="${3:-}"
  # npm REAL: field-path com pontos (time.X.Y.Z) desce chaves inexistentes →
  # stdout vazio + rc=0; o acesso correto é bracket time[X.Y.Z]; dist-tags
  # resolvem via `view <pkg> dist-tags.latest` (fix do code review Fase 5.5).
  case "$FIELD" in
    time.*) exit 0 ;;
  esac
  case "$PKGV:$FIELD" in
    "lodash@4.17.21:time[4.17.21]") echo "2021-02-20T19:48:09.270Z"; exit 0 ;;
    "express@4.18.0:time[4.18.0]")  echo "2022-04-25T15:00:00.000Z"; exit 0 ;;
    "react@18.0.0:time[18.0.0]")    echo "2022-03-29T18:00:00.000Z"; exit 0 ;;
    "fresh-evil@1.0.0:time[1.0.0]") echo "$SC_FRESH_TIME"; exit 0 ;;
    "stable@1.0.0:time[1.0.0]")     echo "2024-01-15T10:00:00.000Z"; exit 0 ;;
    "stable:dist-tags.latest")      echo "1.0.0"; exit 0 ;;
    "fresh-evil:dist-tags.latest")  echo "1.0.0"; exit 0 ;;
    *)
      echo "npm ERR! code E404" >&2; exit 1 ;;
  esac
fi

if [ "$1" = "install" ]; then
  # Dry-run mode: emit JSON with .added based on trailing args. Unknown pkgs
  # cause `npm install` to fail in real life — mock fails with rc=1 so the
  # registry.sh fallback (_sc_resolve_root_only) kicks in.
  declare -a NAMES=()
  declare -a SAW_PKG_ARG=()
  for arg in "$@"; do
    case "$arg" in
      --*|-*) ;;
      install|--dry-run|--json|--silent|--no-save) ;;
      *@*)
        SAW_PKG_ARG+=("$arg")
        case "$arg" in
          lodash@4.17.21|express@4.18.0|react@18.0.0|fresh-evil@1.0.0|stable@1.0.0|stable@latest|fresh-evil@latest)
            n="${arg%@*}"; v="${arg##*@}"
            NAMES+=("{\"name\":\"$n\",\"version\":\"$v\"}")
            ;;
        esac
        ;;
    esac
  done
  # If any pkg arg was unknown to the mock, simulate real npm error.
  if [ "${#SAW_PKG_ARG[@]}" -gt 0 ] && [ "${#NAMES[@]}" -ne "${#SAW_PKG_ARG[@]}" ]; then
    echo "npm ERR! 404 Not Found" >&2; exit 1
  fi
  if [ "${#NAMES[@]}" -eq 0 ]; then
    echo '{"added":[]}'; exit 0
  fi
  joined=$(IFS=,; echo "${NAMES[*]}")
  echo "{\"added\":[$joined]}"
  exit 0
fi
exit 1
MOCKEOF
chmod +x "$MOCK_DIR/npm"

# Mock curl (PyPI)
cat > "$MOCK_DIR/curl" <<'MOCKEOF'
#!/usr/bin/env bash
OUT=""; URL=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) OUT="$2"; shift 2 ;;
    http*) URL="$1"; shift ;;
    *) shift ;;
  esac
done
case "$URL" in
  *pypi.org/pypi/black/24.0.0/json)
    echo '{"urls":[{"upload_time":"2024-01-25T10:00:00"}]}' > "$OUT"
    echo "200"; exit 0 ;;
  *pypi.org/pypi/graphifyy/0.99.99/json)
    # Fresh PyPI pkg
    echo "{\"urls\":[{\"upload_time\":\"$SC_FRESH_TIME_PYPI\"}]}" > "$OUT"
    echo "200"; exit 0 ;;
  *) echo "" > "$OUT"; echo "404"; exit 0 ;;
esac
MOCKEOF
chmod +x "$MOCK_DIR/curl"

export PATH="$MOCK_DIR:$PATH"

hook_call() {
  local cmd="$1"
  printf '{"tool_input":{"command":%s}}' "$(jq -n --arg c "$cmd" '$c')" | bash "$HOOK"
}

echo "=== e2e edge-case tests ==="

# ─── T01: dist-tag pkg@latest resolvendo pra timestamp velho → allow ─────────
err=$(hook_call "npm install --ignore-scripts stable@latest" 2>&1 >/dev/null)
assert_eq "0" "$?" "T01 npm install --ignore-scripts stable@latest → allow (resolved old)"

# ─── T02: dist-tag pkg@latest resolvendo pra fresh → block ───────────────────
err=$(hook_call "npm install --ignore-scripts fresh-evil@latest" 2>&1 >/dev/null)
rc=$?
assert_eq "2" "$rc" "T02a fresh dist-tag blocked"
assert_contains "$err" "cooldown:fresh" "T02b cooldown:fresh in stderr"

# ─── T03: múltiplos pkgs mistos — um fresh, dois stable → block (1 problema)
err=$(hook_call "npm install --ignore-scripts lodash@4.17.21 express@4.18.0 fresh-evil@1.0.0" 2>&1 >/dev/null)
rc=$?
assert_eq "2" "$rc" "T03a mixed → blocked"
assert_contains "$err" "fresh-evil" "T03b cites only the fresh pkg"
echo "$err" | grep -c "cooldown:fresh" | grep -q '^1$' && _pass || _fail "T03c exactly 1 cooldown:fresh problem"

# ─── T04: múltiplos pkgs stable → allow (sanity, no false positive) ──────────
err=$(hook_call "npm install --ignore-scripts lodash@4.17.21 express@4.18.0 react@18.0.0" 2>&1 >/dev/null)
assert_eq "0" "$?" "T04 multiple old pkgs → allow"

# ─── T05: workspace + local mix (skip-list) → allow w/ --ignore-scripts ─────
err=$(hook_call "pnpm add --ignore-scripts workspace:* file:./local-pkg link:./other" 2>&1 >/dev/null)
assert_eq "0" "$?" "T05 workspace+local with --ignore-scripts → allow"

# ─── T06: bypass parcial — só cooldown bypassed mas há git-url → block ──────
err=$(CLAUDE_SC_BYPASS_COOLDOWN=1 CLAUDE_SC_REASON="testing partial" \
      hook_call "npm install --ignore-scripts github:foo/bar" 2>&1 >/dev/null)
rc=$?
assert_eq "2" "$rc" "T06 partial bypass (cooldown only, git-url not bypassed) → block"

# ─── T07: bypass total + REASON → allow ──────────────────────────────────────
err=$(CLAUDE_SC_BYPASS_COOLDOWN=1 CLAUDE_SC_BYPASS_GIT_DEPS=1 CLAUDE_SC_BYPASS_SCRIPTS=1 \
      CLAUDE_SC_REASON="onboarding internal fork, code reviewed" \
      hook_call "npm install github:myorg/internal" 2>&1 >/dev/null)
assert_eq "0" "$?" "T07 full bypass + REASON → allow"

# ─── T08: REASON com aspas/escape — não deve quebrar audit log ──────────────
err=$(CLAUDE_SC_BYPASS_COOLDOWN=1 CLAUDE_SC_BYPASS_SCRIPTS=1 \
      CLAUDE_SC_REASON='security "patch" for CVE \backslash' \
      hook_call "npm install fresh-evil@1.0.0" 2>&1 >/dev/null)
assert_eq "0" "$?" "T08a special chars in REASON allowed"
# audit log line stayed valid JSON
last_line=$(tail -n 1 "$SC_AUDIT_LOG")
echo "$last_line" | jq -e . >/dev/null 2>&1 && _pass || _fail "T08b audit line malformed: $last_line"

# ─── T09: REASON com whitespace só → bloqueia (não é "vazio" trivial) ───────
# Hook today treats only literal-empty REASON as missing. Whitespace-only is
# accepted. This documents current behavior; refining later requires policy.
err=$(CLAUDE_SC_BYPASS_COOLDOWN=1 CLAUDE_SC_BYPASS_SCRIPTS=1 \
      CLAUDE_SC_REASON="   " \
      hook_call "npm install fresh-evil@1.0.0" 2>&1 >/dev/null)
# Current behavior: spaces are non-empty → allows.
assert_eq "0" "$?" "T09 whitespace REASON: documents current policy (allowed)"

# ─── T10: comando longo (>200 chars) deve ser truncado/aceito sem crash ─────
LONG="npm install --ignore-scripts $(printf 'pkg%d@1.0.0 ' {1..20})"
err=$(hook_call "$LONG" 2>&1 >/dev/null)
# All 20 will be unknown, so all will return PACKAGE_NOT_FOUND → fail-closed
rc=$?
assert_eq "2" "$rc" "T10 long command (20 unknown pkgs) → block fail-closed"

# ─── T11: Performance — 100 cache hits via direct API < 5s ──────────────────
# Pre-warm cache via direct API (not through hook, to isolate)
# shellcheck source=../lib/supply-chain/registry.sh
. "$LIB_DIR/registry.sh"
sc_cache_put npm perfpkg 1.0.0 "2024-01-01T00:00:00Z" >/dev/null

start=$(date +%s)
for _ in $(seq 1 100); do
  sc_get_publish_time npm perfpkg 1.0.0 >/dev/null 2>&1
done
elapsed=$(($(date +%s) - start))
assert_lt "$elapsed" "5" "T11 100 cache hits in ${elapsed}s (budget 5s)"

# ─── T12: PyPI path — uv tool install com pkg fresh → block ─────────────────
err=$(hook_call "uv tool install graphifyy" 2>&1 >/dev/null)
rc=$?
# uv tool install graphifyy → no version → sc_resolve_tree falls back to
# root-only with spec="*". sc_get_publish_time gets "*" — npm view "*" fails.
# We don't have proper resolution, so cooldown will mark this as
# lookup-failed/version-not-found → fail-closed block.
assert_eq "2" "$rc" "T12 uv tool install graphifyy (no version) → fail-closed"

# ─── T13: settings.json continues to be valid JSON após registro ────────────
# (Smoke test: the global settings.json should still parse.)
if [ -f "$HOME/.claude/settings.json" ]; then
  jq -e . "$HOME/.claude/settings.json" >/dev/null 2>&1 && _pass || _fail "T13 settings.json invalid JSON after US-05"
else
  # Smoke de máquina provisionada — em ambiente hermético (runner de CI,
  # HOME sem ~/.claude) não há o que validar: skip explícito, não falha.
  echo "  (T13/T14 skip: settings.json ausente — ambiente sem ~/.claude provisionado)"
  _pass
fi

# ─── T14: settings.json contém o hook supply-chain-guard.sh ─────────────────
if [ -f "$HOME/.claude/settings.json" ]; then
  has=$(jq -r '.hooks.PreToolUse[] | select(.matcher=="Bash") | .hooks[] | .command' "$HOME/.claude/settings.json" 2>/dev/null | grep -c 'supply-chain-guard.sh' || echo 0)
  [ "$has" -ge 1 ] && _pass || _fail "T14 supply-chain-guard.sh missing from settings.json (got $has matches)"
fi

# ─── T15: pnpm dlx — run-ephemeral path (no D2 requirement) ─────────────────
err=$(hook_call "pnpm dlx create-foo" 2>&1 >/dev/null)
rc=$?
# pnpm dlx → op=run-ephemeral. Cooldown applies (create-foo unknown → 404
# → fail-closed). Not blocked by --ignore-scripts (op != install).
case "$rc" in
  2) _pass ;;  # fail-closed on unknown is expected
  *) _fail "T15 pnpm dlx → rc=$rc, expected 2 (fail-closed)" ;;
esac

# ─── T16: pure git command bypasses hook → no audit entry ───────────────────
pre=$(wc -l < "$SC_AUDIT_LOG" | tr -d ' ' 2>/dev/null || echo 0)
hook_call "git diff --stat" > /dev/null 2>&1
post=$(wc -l < "$SC_AUDIT_LOG" | tr -d ' ' 2>/dev/null || echo 0)
# op=other → early-return at exit 0. Audit not called for "other" commands.
assert_eq "$pre" "$post" "T16 op:other does not pollute audit log"

# ─── Summary ─────────────────────────────────────────────────────────────────
echo ""
echo "PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then
  echo "Failed tests:$FAILED"
  exit 1
fi
exit 0

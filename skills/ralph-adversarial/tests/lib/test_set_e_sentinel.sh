#!/usr/bin/env bash
# tests/lib/test_set_e_sentinel.sh — US-08 / F8h sentinel.
#
# Confirma que aplicar `set -euo pipefail` APENAS dentro do corpo de
# `run_parallel()` preserva o caminho serial (Fase 1) intocado. F8 (US-09) só
# pode aplicar a alteração permanentemente depois desta sentinela ficar verde.
#
# AC3: baseline (script intocado) + serial flow exits 0 com "TODAS AS STORIES
#      COMPLETAS" — confirma que o catálogo (tests/fase1-exit-codes.md) não
#      altera nada.
# AC4: patched (set -euo pipefail injetado como 1ª linha de run_parallel) +
#      serial flow exits 0. Como run_serial nunca entra em run_parallel, set -e
#      jamais ativa; a sentinela protege contra regressões futuras (e.g., F8
#      injetando a diretiva no lugar errado).
#
# Esta sentinela NÃO valida que o caminho parallel continua verde sob set -e:
# essa validação é responsabilidade de US-09 / F8 quando ele aplicar a
# diretiva e refatorar as capturas (b)/(c) do catálogo.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TESTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SKILL_DIR="$(cd "$TESTS_DIR/.." && pwd)"
RALPH_SCRIPT="$SKILL_DIR/ralph-adversarial.sh"
MOCKS_DIR="$TESTS_DIR/mocks"
CATALOG="$TESTS_DIR/fase1-exit-codes.md"

PASS=0
FAIL=0
FAILED=""

_pass() { PASS=$((PASS + 1)); }
_fail() { FAIL=$((FAIL + 1)); FAILED="${FAILED}
  ✗ $1"; }

assert_rc() {
    local rc="$1" expected="$2" msg="$3"
    if [ "$rc" = "$expected" ]; then _pass
    else _fail "$msg :: expected rc=$expected got rc=$rc"; fi
}
assert_contains() {
    local haystack="$1" needle="$2" msg="$3"
    case "$haystack" in
        *"$needle"*) _pass ;;
        *) _fail "$msg :: needle not found" ;;
    esac
}
assert_eq() {
    local got="$1" want="$2" msg="$3"
    if [ "$got" = "$want" ]; then _pass
    else _fail "$msg :: want='$want' got='$got'"; fi
}

# ─── AC5: catálogo existe e cita rev5b R25 + Decisão #13 ──────────────────

if [ -f "$CATALOG" ]; then _pass
else _fail "AC5 catalog file exists at $CATALOG"; fi

cat_text=$(cat "$CATALOG" 2>/dev/null || true)
assert_contains "$cat_text" "Decisão #13"  "AC5 catalog references Decisão #13"
assert_contains "$cat_text" "rev5b R25"    "AC5 catalog references rev5b R25"
assert_contains "$cat_text" "run_parallel" "AC5 catalog explains parallel-only scope"
assert_contains "$cat_text" "run_serial"   "AC5 catalog scope = run_serial path"
# Catalog must enumerate at least one (a), one (b), one (c) classification.
assert_contains "$cat_text" "(a)" "AC2 catalog has class-(a) entries"
assert_contains "$cat_text" "(b)" "AC2 catalog has class-(b) entries"
assert_contains "$cat_text" "(c)" "AC2 catalog has class-(c) entries"

# ─── AC1 spot-checks: each named non-zero-tolerant pattern listed ─────────

assert_contains "$cat_text" "kill -0"      "AC1 catalog mentions kill -0"
assert_contains "$cat_text" "while"        "AC1 catalog mentions while-condition pattern"
assert_contains "$cat_text" 'grep'         "AC1 catalog mentions grep usage"
# git diff --quiet is documented as absent (US-09 introduces it); the catalog
# explicitly states this so the audit does not look like an oversight.
assert_contains "$cat_text" "git diff --quiet" "AC1 catalog documents git diff --quiet status"

# ─── Helpers for the runtime sentinel checks ─────────────────────────────

mk_serial_workspace() {
    local dir
    dir=$(mktemp -d -t ralph-sentinel.XXXXXX)
    (
        cd "$dir"
        git init -q
        git config user.email t@t.local
        git config user.name  t
        cat > prd.json <<'JSON'
{
  "projectName": "sentinel",
  "branchName": "feat/sentinel",
  "userStories": [
    { "id": "S-1", "title": "x", "priority": 1, "passes": true, "acceptanceCriteria": [] }
  ]
}
JSON
        git add prd.json && git commit -qm init
    )
    echo "$dir"
}

run_serial_against() {
    local script="$1" cwd="$2"
    (
        cd "$cwd"
        RALPH_AGENT_BIN="$MOCKS_DIR/fake-claude.sh" \
        RALPH_REVIEWER_BIN="$MOCKS_DIR/fake-codex.sh" \
            bash "$script" 1
    ) 2>&1
}

# ─── AC3: baseline — run_serial exits 0 with current (no-set-e) script ────

ws=$(mk_serial_workspace)
out=$(run_serial_against "$RALPH_SCRIPT" "$ws")
rc=$?
assert_rc "$rc" 0 "AC3 baseline serial path rc=0"
assert_contains "$out" "TODAS AS STORIES COMPLETAS" \
    "AC3 baseline emits TODAS COMPLETAS marker"
rm -rf "$ws"

# ─── AC4: patched — inject `set -euo pipefail` as 1st line of run_parallel ─

# The patched copy MUST live next to the original because the script computes
# SCRIPT_DIR from BASH_SOURCE[0] and then `source "$SCRIPT_DIR/lib/dispatch.sh"`
# (and the parse-verdict / detect-quota / IMPL_PROMPT.md / CODE_REVIEW.md
# files). A copy in /tmp would fail those sources. We use a unique suffix per
# invocation and trap-cleanup it on exit.
patched="$SKILL_DIR/.ralph-adversarial.sentinel.$$.sh"
cleanup_patched() { rm -f "$patched"; }
trap cleanup_patched EXIT
# awk: print every line; whenever we see `run_parallel() {`, inject the
# directive on the next line UNLESS it already follows (idempotent). This
# matters because US-09 made the directive permanent; without idempotence
# the patched copy would have two consecutive `set -euo pipefail` lines.
# Anchored to start-of-line + literal `() {` to avoid matching call sites.
awk '
{
    if (skip_check) {
        skip_check = 0
        if ($0 == "    set -euo pipefail") { print; next }
        # Otherwise inject the directive ahead of this line.
        print "    set -euo pipefail"
    }
    print
}
/^run_parallel\(\) \{$/ { skip_check = 1 }
' "$RALPH_SCRIPT" > "$patched"

# Sanity 1: directive landed exactly once in the patched file.
n_inj=$(grep -c '^    set -euo pipefail$' "$patched" || true)
assert_eq "$n_inj" "1" "AC4 patch sanity: set -euo pipefail injected once"

# Sanity 2: directive does NOT appear at the top of the file (global scope).
top_n=$(head -n 10 "$patched" | grep -c '^set -euo pipefail$' || true)
assert_eq "$top_n" "0" "AC4 patch sanity: directive not promoted to global"

# Sanity 3: bash -n parses the patched script (no syntax breakage).
bash -n "$patched"
assert_rc "$?" 0 "AC4 patch sanity: bash -n parses patched script"

# Sanity 4: the injected line is INSIDE run_parallel — between
# `run_parallel() {` and the next top-level `}`.
inside_check=$(awk '
/^run_parallel\(\) \{$/    { in_fn=1; next }
in_fn && /^\}$/             { in_fn=0; next }
in_fn && /^    set -euo pipefail$/ { found=1 }
END { print (found ? "yes" : "no") }
' "$patched")
assert_eq "$inside_check" "yes" "AC4 patch sanity: directive lives inside run_parallel body"

# Run serial path against the patched script.
ws=$(mk_serial_workspace)
out=$(run_serial_against "$patched" "$ws")
rc=$?
assert_rc "$rc" 0 "AC4 patched serial path rc=0 (set -e in run_parallel did not bleed)"
assert_contains "$out" "TODAS AS STORIES COMPLETAS" \
    "AC4 patched serial output unchanged"
# Crucially: parallel-mode messages must NOT appear (proves run_parallel was
# never entered, hence set -e never activated).
case "$out" in
    *"modo paralelo detectado"*) _fail "AC4 patched: serial path unexpectedly entered run_parallel" ;;
    *) _pass ;;
esac
rm -rf "$ws"
cleanup_patched
trap - EXIT

# ─── Report ───────────────────────────────────────────────────────────────

echo ""
echo "─────────────────────────────────────────────"
echo "PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then
    printf '%s\n' "$FAILED"
    exit 1
fi
exit 0

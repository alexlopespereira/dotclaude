#!/usr/bin/env bash
# bin/tests/test_force_merge.sh — Cobre force-merge.sh (US-02..US-06).
#
# Estratégia: mock de `gh` via PATH shadow. Cada teste escreve um `gh` em
# $MOCK_DIR que dispatch baseado em $* contra responses hardcoded. Mock
# também loga calls em $MOCK_LOG (uma chamada por linha) para assertions
# de "qual subcomando foi invocado".

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT="$BIN_DIR/force-merge.sh"

PASS=0; FAIL=0; FAILED=""

_fail() { FAIL=$((FAIL+1)); FAILED="${FAILED}
  ✗ $1"; }
_pass() { PASS=$((PASS+1)); }

assert_rc()       { [ "$1" = "$2" ] && _pass || _fail "$3 :: expected rc=$2 got rc=$1"; }
assert_contains() { case "$1" in *"$2"*) _pass ;; *) _fail "$3 :: needle '$2' not found in output";; esac; }
assert_not_contains() { case "$1" in *"$2"*) _fail "$3 :: needle '$2' found but should NOT be";; *) _pass;; esac; }

setup_mock() {
  MOCK_DIR=$(mktemp -d)
  MOCK_LOG="$MOCK_DIR/mock.log"
  : > "$MOCK_LOG"
  # Mock for sync.sh: stub that says "fora do pool" so tests don't depend on real sync state.
  cat > "$MOCK_DIR/sync.sh" <<'STUB'
#!/usr/bin/env bash
echo "ERRO: cwd não está em /Users/dev/Projects/checkouts/<repo>-N/."
exit 1
STUB
  chmod +x "$MOCK_DIR/sync.sh"
}

teardown_mock() {
  [ -n "${MOCK_DIR:-}" ] && rm -rf "$MOCK_DIR"
  unset MOCK_DIR MOCK_LOG
}

# Run force-merge.sh with PATH shadowed by mock + a fake sync.sh in same dir.
# We copy force-merge.sh into MOCK_DIR so SCRIPT_DIR resolves to MOCK_DIR
# (where the stub sync.sh lives), letting us test the sync-skip path.
run_script() {
  cp "$SCRIPT" "$MOCK_DIR/force-merge.sh"
  chmod +x "$MOCK_DIR/force-merge.sh"
  PATH="$MOCK_DIR:$PATH" MOCK_LOG="$MOCK_LOG" bash "$MOCK_DIR/force-merge.sh" "$@" 2>&1
}

# ─── Build canned `gh` mock based on env vars set by each test ────────────
# Note: parameter defaults that contain '}' must use intermediate vars,
# because bash does NOT brace-balance inside ${VAR:-default} — adjacent }}
# would be parsed as one close + one literal.
write_gh_mock() {
  cat > "$MOCK_DIR/gh" <<'MOCK_EOF'
#!/usr/bin/env bash
echo "$*" >> "$MOCK_LOG"
DEF_PR_VIEW='{"state":"OPEN","isDraft":false,"baseRefName":"main","title":"test PR"}'
DEF_PR_LIST='[]'
DEF_PR_CHECKS='[]'
DEF_API_PROT='{"message":"Branch not protected","status":"404"}'
case "$1" in
  pr)
    case "$2" in
      list)
        if [[ "$*" == *"--author @me"* ]]; then
          echo "${MOCK_PR_LIST_ME:-$DEF_PR_LIST}"
          exit 0
        fi
        if [[ "$*" == *"--head "* ]]; then
          if [[ "$*" == *"--jq"* ]]; then
            echo "${MOCK_PR_BY_BRANCH_NUM:-}"
          else
            echo "${MOCK_PR_BY_BRANCH:-$DEF_PR_LIST}"
          fi
          exit 0
        fi
        echo "[]"
        exit 0
        ;;
      view)
        echo "${MOCK_PR_VIEW:-$DEF_PR_VIEW}"
        exit 0
        ;;
      merge)
        echo "✓ Merged PR (mock)"
        exit "${MOCK_MERGE_RC:-0}"
        ;;
      checks)
        if [[ "$*" == *"--watch"* ]]; then
          exit "${MOCK_CHECKS_WATCH_RC:-0}"
        fi
        echo "${MOCK_PR_CHECKS:-$DEF_PR_CHECKS}"
        exit 0
        ;;
    esac
    ;;
  api)
    if [[ "$*" == *"branches"* ]] && [[ "$*" == *"protection"* ]]; then
      if [ "${MOCK_PROTECTED:-false}" = "true" ]; then
        echo "{}"
        exit 0
      else
        echo "$DEF_API_PROT" >&2
        exit 1
      fi
    fi
    echo "{}"
    exit 0
    ;;
  repo)
    if [ "$2" = "view" ]; then
      echo "${MOCK_REPO_NWO:-dev/test-repo}"
      exit 0
    fi
    ;;
esac
exit 0
MOCK_EOF
  chmod +x "$MOCK_DIR/gh"
}

# ═══════════════════════════════════════════════════════════════════════════
# Test (a): auto-detect com 1 PR aberto não-draft → mergeia, exit 0
# ═══════════════════════════════════════════════════════════════════════════
setup_mock
export MOCK_PR_LIST_ME='[{"number":42,"title":"feat: foo","headRefName":"feat/foo","isDraft":false}]'
export MOCK_PR_VIEW='{"state":"OPEN","isDraft":false,"baseRefName":"main","title":"feat: foo"}'
export MOCK_PROTECTED=false
write_gh_mock
OUT=$(run_script --no-sync); RC=$?
assert_rc "$RC" 0 "(a) auto-detect 1 PR returns rc=0"
assert_contains "$OUT" "PR #42" "(a) output mentions detected PR #42"
assert_contains "$OUT" "mergeado" "(a) output confirms merge"
unset MOCK_PR_LIST_ME MOCK_PR_VIEW MOCK_PROTECTED
teardown_mock

# ═══════════════════════════════════════════════════════════════════════════
# Test (b): auto-detect com 0 PRs → exit 1
# ═══════════════════════════════════════════════════════════════════════════
setup_mock
export MOCK_PR_LIST_ME='[]'
write_gh_mock
OUT=$(run_script --no-sync); RC=$?
assert_rc "$RC" 1 "(b) auto-detect 0 PRs returns rc=1"
assert_contains "$OUT" "nenhum PR aberto" "(b) error message clear"
unset MOCK_PR_LIST_ME
teardown_mock

# ═══════════════════════════════════════════════════════════════════════════
# Test (c): auto-detect com >1 PRs → exit 1 com lista
# ═══════════════════════════════════════════════════════════════════════════
setup_mock
export MOCK_PR_LIST_ME='[
  {"number":42,"title":"feat: foo","headRefName":"feat/foo","isDraft":false},
  {"number":43,"title":"fix: bar","headRefName":"fix/bar","isDraft":false}
]'
write_gh_mock
OUT=$(run_script --no-sync); RC=$?
assert_rc "$RC" 1 "(c) >1 PRs returns rc=1"
assert_contains "$OUT" "ambíguo" "(c) error mentions ambiguity"
assert_contains "$OUT" "#42" "(c) lists PR #42"
assert_contains "$OUT" "#43" "(c) lists PR #43"
unset MOCK_PR_LIST_ME
teardown_mock

# ═══════════════════════════════════════════════════════════════════════════
# Test (d): arg numérico → usa direto
# ═══════════════════════════════════════════════════════════════════════════
setup_mock
export MOCK_PR_VIEW='{"state":"OPEN","isDraft":false,"baseRefName":"main","title":"feat: explicit"}'
export MOCK_PROTECTED=false
write_gh_mock
OUT=$(run_script 99 --no-sync); RC=$?
assert_rc "$RC" 0 "(d) numeric arg returns rc=0"
assert_contains "$OUT" "PR #99" "(d) uses explicit PR number"
assert_not_contains "$OUT" "Auto-detectado" "(d) skips auto-detect when arg given"
unset MOCK_PR_VIEW MOCK_PROTECTED
teardown_mock

# ═══════════════════════════════════════════════════════════════════════════
# Test (e): arg branch name → resolve via gh pr list --head
# ═══════════════════════════════════════════════════════════════════════════
setup_mock
export MOCK_PR_BY_BRANCH_NUM=77
export MOCK_PR_VIEW='{"state":"OPEN","isDraft":false,"baseRefName":"main","title":"feat: by branch"}'
export MOCK_PROTECTED=false
write_gh_mock
OUT=$(run_script feat/some-branch --no-sync); RC=$?
assert_rc "$RC" 0 "(e) branch arg returns rc=0"
assert_contains "$OUT" "feat/some-branch" "(e) mentions branch name"
assert_contains "$OUT" "PR #77" "(e) resolves to PR #77"
unset MOCK_PR_BY_BRANCH_NUM MOCK_PR_VIEW MOCK_PROTECTED
teardown_mock

# ═══════════════════════════════════════════════════════════════════════════
# Test (f): PR já MERGED → idempotente, rc=0
# ═══════════════════════════════════════════════════════════════════════════
setup_mock
export MOCK_PR_VIEW='{"state":"MERGED","isDraft":false,"baseRefName":"main","title":"already done"}'
write_gh_mock
OUT=$(run_script 50 --no-sync); RC=$?
assert_rc "$RC" 0 "(f) MERGED PR returns rc=0 (idempotent)"
assert_contains "$OUT" "já está MERGED" "(f) message says already merged"
unset MOCK_PR_VIEW
teardown_mock

# ═══════════════════════════════════════════════════════════════════════════
# Test (g): PR CLOSED sem merge → rc=1
# ═══════════════════════════════════════════════════════════════════════════
setup_mock
export MOCK_PR_VIEW='{"state":"CLOSED","isDraft":false,"baseRefName":"main","title":"abandoned"}'
write_gh_mock
OUT=$(run_script 51 --no-sync); RC=$?
assert_rc "$RC" 1 "(g) CLOSED PR returns rc=1"
assert_contains "$OUT" "CLOSED" "(g) message mentions closed"
unset MOCK_PR_VIEW
teardown_mock

# ═══════════════════════════════════════════════════════════════════════════
# Test (h): PR DRAFT → rc=1
# ═══════════════════════════════════════════════════════════════════════════
setup_mock
export MOCK_PR_VIEW='{"state":"OPEN","isDraft":true,"baseRefName":"main","title":"WIP"}'
write_gh_mock
OUT=$(run_script 52 --no-sync); RC=$?
assert_rc "$RC" 1 "(h) draft PR returns rc=1"
assert_contains "$OUT" "draft" "(h) message mentions draft"
assert_contains "$OUT" "gh pr ready" "(h) suggests gh pr ready"
unset MOCK_PR_VIEW
teardown_mock

# ═══════════════════════════════════════════════════════════════════════════
# Test (i): auto-detect com PR draft entre os abertos → ignora-o (filter isDraft=false)
# ═══════════════════════════════════════════════════════════════════════════
setup_mock
export MOCK_PR_LIST_ME='[{"number":60,"title":"WIP","headRefName":"wip/x","isDraft":true}]'
write_gh_mock
OUT=$(run_script --no-sync); RC=$?
assert_rc "$RC" 1 "(i) only-draft PRs returns rc=1 (filtered out)"
assert_contains "$OUT" "nenhum PR aberto não-draft" "(i) message excludes drafts"
unset MOCK_PR_LIST_ME
teardown_mock

# ═══════════════════════════════════════════════════════════════════════════
# Test (j): branch protegida sem FORCE_MERGE_CONFIRMED → rc=3 (gate)
# ═══════════════════════════════════════════════════════════════════════════
setup_mock
export MOCK_PR_VIEW='{"state":"OPEN","isDraft":false,"baseRefName":"main","title":"feat: prot"}'
export MOCK_PROTECTED=true
write_gh_mock
OUT=$(run_script 70 --no-sync); RC=$?
assert_rc "$RC" 3 "(j) protected branch sem confirm returns rc=3"
assert_contains "$OUT" "confirmação humana" "(j) gate explains confirmation needed"
unset MOCK_PR_VIEW MOCK_PROTECTED
teardown_mock

# ═══════════════════════════════════════════════════════════════════════════
# Test (k): branch protegida com FORCE_MERGE_CONFIRMED=1 → mergeia
# ═══════════════════════════════════════════════════════════════════════════
setup_mock
export MOCK_PR_VIEW='{"state":"OPEN","isDraft":false,"baseRefName":"main","title":"feat: prot"}'
export MOCK_PROTECTED=true
write_gh_mock
OUT=$(FORCE_MERGE_CONFIRMED=1 run_script 71 --no-sync); RC=$?
assert_rc "$RC" 0 "(k) protected + FORCE_MERGE_CONFIRMED=1 returns rc=0"
assert_contains "$OUT" "mergeado" "(k) merge happens after confirm"
unset MOCK_PR_VIEW MOCK_PROTECTED
teardown_mock

# ═══════════════════════════════════════════════════════════════════════════
# Test (l): --no-sync pula auto-sync (assert via não invocar sync.sh stub)
# ═══════════════════════════════════════════════════════════════════════════
setup_mock
export MOCK_PR_VIEW='{"state":"OPEN","isDraft":false,"baseRefName":"main","title":"feat: nosync"}'
export MOCK_PROTECTED=false
write_gh_mock
OUT=$(run_script 80 --no-sync); RC=$?
assert_rc "$RC" 0 "(l) --no-sync rc=0"
assert_not_contains "$OUT" "Disparando auto-sync" "(l) --no-sync skips sync banner"
assert_not_contains "$OUT" "fora do pool" "(l) --no-sync also skips fora-do-pool warning"
unset MOCK_PR_VIEW MOCK_PROTECTED
teardown_mock

# ═══════════════════════════════════════════════════════════════════════════
# Test (m): default (sem --no-sync) chama sync; stub diz "fora do pool" e silencia
# ═══════════════════════════════════════════════════════════════════════════
setup_mock
export MOCK_PR_VIEW='{"state":"OPEN","isDraft":false,"baseRefName":"main","title":"feat: sync"}'
export MOCK_PROTECTED=false
write_gh_mock
OUT=$(run_script 81); RC=$?
assert_rc "$RC" 0 "(m) auto-sync default rc=0"
assert_contains "$OUT" "Disparando auto-sync" "(m) auto-sync banner shown"
assert_contains "$OUT" "fora do pool" "(m) sync stub returns fora-do-pool, captured by run_sync_or_skip"
unset MOCK_PR_VIEW MOCK_PROTECTED
teardown_mock

# ═══════════════════════════════════════════════════════════════════════════
# Test (n): combinação ilegal --wait --admin → rc=2
# ═══════════════════════════════════════════════════════════════════════════
setup_mock
write_gh_mock
OUT=$(run_script --wait --admin --no-sync 2>&1); RC=$?
assert_rc "$RC" 2 "(n) --wait --admin combo returns rc=2"
assert_contains "$OUT" "mutuamente exclusivas" "(n) error names the conflict"
teardown_mock

# ═══════════════════════════════════════════════════════════════════════════
# Test (o): flag desconhecida → rc=2
# ═══════════════════════════════════════════════════════════════════════════
setup_mock
write_gh_mock
OUT=$(run_script --bogus-flag --no-sync 2>&1); RC=$?
assert_rc "$RC" 2 "(o) unknown flag returns rc=2"
assert_contains "$OUT" "flag desconhecida" "(o) error names the bad flag"
teardown_mock

# ═══════════════════════════════════════════════════════════════════════════
# Test (p): --admin sem CONFIRMED → rc=3 (sempre exige confirm)
# ═══════════════════════════════════════════════════════════════════════════
setup_mock
export MOCK_PR_VIEW='{"state":"OPEN","isDraft":false,"baseRefName":"main","title":"feat: x"}'
export MOCK_PROTECTED=false
write_gh_mock
OUT=$(run_script 90 --admin --no-sync); RC=$?
assert_rc "$RC" 3 "(p) --admin sem CONFIRMED returns rc=3"
assert_contains "$OUT" "ADMIN" "(p) gate names ADMIN mode"
unset MOCK_PR_VIEW MOCK_PROTECTED
teardown_mock

# ═══════════════════════════════════════════════════════════════════════════
# Test (q): --admin + FORCE_MERGE_NESTED=1 (composto) AINDA exige CONFIRMED
# ═══════════════════════════════════════════════════════════════════════════
setup_mock
export MOCK_PR_VIEW='{"state":"OPEN","isDraft":false,"baseRefName":"main","title":"feat: y"}'
export MOCK_PROTECTED=false
write_gh_mock
OUT=$(FORCE_MERGE_NESTED=1 run_script 91 --admin --no-sync); RC=$?
assert_rc "$RC" 3 "(q) --admin + NESTED ainda exige confirm (sempre)"
unset MOCK_PR_VIEW MOCK_PROTECTED
teardown_mock

# ═══════════════════════════════════════════════════════════════════════════
# Test (r): --admin + CONFIRMED=1 mergeia, mock log mostra --admin nas args
# ═══════════════════════════════════════════════════════════════════════════
setup_mock
export MOCK_PR_VIEW='{"state":"OPEN","isDraft":false,"baseRefName":"main","title":"feat: z"}'
export MOCK_PROTECTED=true
write_gh_mock
OUT=$(FORCE_MERGE_CONFIRMED=1 run_script 92 --admin --no-sync); RC=$?
assert_rc "$RC" 0 "(r) --admin + CONFIRMED rc=0"
assert_contains "$OUT" "Modo: --admin" "(r) output anuncia admin mode"
# Verify mock log contains "--admin" in pr merge args
LOG=$(cat "$MOCK_LOG" 2>/dev/null || echo "")
assert_contains "$LOG" "pr merge 92 --admin" "(r) mock log shows gh pr merge with --admin"
unset MOCK_PR_VIEW MOCK_PROTECTED
teardown_mock

# ═══════════════════════════════════════════════════════════════════════════
# Test (s): --wait + FORCE_MERGE_NESTED=1 PULA confirmação (composto pode)
# ═══════════════════════════════════════════════════════════════════════════
setup_mock
export MOCK_PR_VIEW='{"state":"OPEN","isDraft":false,"baseRefName":"main","title":"feat: w"}'
export MOCK_PROTECTED=false
export MOCK_PR_CHECKS='[]'  # sem checks → cai pro soft direto
write_gh_mock
OUT=$(FORCE_MERGE_NESTED=1 run_script 93 --wait --no-sync); RC=$?
assert_rc "$RC" 0 "(s) --wait + NESTED pula confirm, mergeia rc=0"
assert_contains "$OUT" "PR sem checks" "(s) detect-first dispara fallback soft"
unset MOCK_PR_VIEW MOCK_PROTECTED MOCK_PR_CHECKS
teardown_mock

# ═══════════════════════════════════════════════════════════════════════════
# Test (t): --wait sem NESTED, sem CONFIRMED → rc=3
# ═══════════════════════════════════════════════════════════════════════════
setup_mock
export MOCK_PR_VIEW='{"state":"OPEN","isDraft":false,"baseRefName":"main","title":"feat: w2"}'
export MOCK_PROTECTED=false
write_gh_mock
OUT=$(run_script 94 --wait --no-sync); RC=$?
assert_rc "$RC" 3 "(t) --wait sem NESTED, sem CONFIRMED returns rc=3"
assert_contains "$OUT" "WAIT" "(t) gate names WAIT mode"
unset MOCK_PR_VIEW MOCK_PROTECTED
teardown_mock

# ═══════════════════════════════════════════════════════════════════════════
# Test (u): --wait com checks PASSING → watch+merge OK
# ═══════════════════════════════════════════════════════════════════════════
setup_mock
export MOCK_PR_VIEW='{"state":"OPEN","isDraft":false,"baseRefName":"main","title":"feat: ci-ok"}'
export MOCK_PROTECTED=false
export MOCK_PR_CHECKS='[{"state":"SUCCESS","name":"ci"}]'
export MOCK_CHECKS_WATCH_RC=0
write_gh_mock
OUT=$(FORCE_MERGE_CONFIRMED=1 run_script 95 --wait --no-sync); RC=$?
assert_rc "$RC" 0 "(u) --wait + checks passing rc=0"
assert_contains "$OUT" "Aguardando 1 check" "(u) detect-first announces 1 check"
assert_contains "$OUT" "checks passaram" "(u) success message"
assert_contains "$OUT" "mergeado" "(u) merge happens after checks"
unset MOCK_PR_VIEW MOCK_PROTECTED MOCK_PR_CHECKS MOCK_CHECKS_WATCH_RC
teardown_mock

# ═══════════════════════════════════════════════════════════════════════════
# Test (v): --wait com checks FAILING → watch returns rc≠0, abort rc=1
# ═══════════════════════════════════════════════════════════════════════════
setup_mock
export MOCK_PR_VIEW='{"state":"OPEN","isDraft":false,"baseRefName":"main","title":"feat: ci-fail"}'
export MOCK_PROTECTED=false
export MOCK_PR_CHECKS='[{"state":"FAILURE","name":"unit-tests"}]'
export MOCK_CHECKS_WATCH_RC=1
write_gh_mock
OUT=$(FORCE_MERGE_CONFIRMED=1 run_script 96 --wait --no-sync); RC=$?
assert_rc "$RC" 1 "(v) --wait + checks failing rc=1"
assert_contains "$OUT" "check falhou" "(v) error mentions failure"
# Check that merge was NOT invoked
LOG=$(cat "$MOCK_LOG" 2>/dev/null || echo "")
assert_not_contains "$LOG" "pr merge 96" "(v) merge NOT invoked when checks fail"
unset MOCK_PR_VIEW MOCK_PROTECTED MOCK_PR_CHECKS MOCK_CHECKS_WATCH_RC
teardown_mock

# ═══════════════════════════════════════════════════════════════════════════
# Test (w): detect-first chama `pr checks --json state` ANTES de `--watch`
# (Finding #6 da revisão adversária — não confiar em exit code do --watch)
# ═══════════════════════════════════════════════════════════════════════════
setup_mock
export MOCK_PR_VIEW='{"state":"OPEN","isDraft":false,"baseRefName":"main","title":"feat: order"}'
export MOCK_PROTECTED=false
export MOCK_PR_CHECKS='[{"state":"PENDING","name":"ci"}]'
export MOCK_CHECKS_WATCH_RC=0
write_gh_mock
OUT=$(FORCE_MERGE_CONFIRMED=1 run_script 97 --wait --no-sync); RC=$?
assert_rc "$RC" 0 "(w) ordering OK rc=0"
LOG=$(cat "$MOCK_LOG" 2>/dev/null || echo "")
# Verifica ordem: --json state aparece ANTES de --watch
JSON_LINE=$(grep -n -- "--json state" "$MOCK_LOG" | head -1 | cut -d: -f1)
WATCH_LINE=$(grep -n -- "--watch" "$MOCK_LOG" | head -1 | cut -d: -f1)
if [ -n "$JSON_LINE" ] && [ -n "$WATCH_LINE" ] && [ "$JSON_LINE" -lt "$WATCH_LINE" ]; then
  _pass
else
  _fail "(w) detect-first must call --json state BEFORE --watch (json=$JSON_LINE watch=$WATCH_LINE)"
fi
unset MOCK_PR_VIEW MOCK_PROTECTED MOCK_PR_CHECKS MOCK_CHECKS_WATCH_RC
teardown_mock

# ─── Final report ──────────────────────────────────────────────────────────
echo ""
echo "─────────────────────────────────────────"
echo "test_force_merge.sh: PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf '%s\n' "$FAILED"
  exit 1
fi
echo "  ✓ all assertions green"
exit 0

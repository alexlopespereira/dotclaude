#!/usr/bin/env bash
# bin/tests/test_ship_ci_watch.sh — Cobre a espera de CI do bin/ship.sh
# (US-03 do ciclo quick-wins-item3): o loop de polling com `sleep 5` foi
# substituído por `gh pr checks <pr> --watch` com teto via perl alarm.
#
# Estratégia: monta um repo git real (na frente de origin/main, tree limpo),
# copia ship.sh para um MOCK_DIR (assim SCRIPT_DIR resolve os helpers
# commit-push-pr/force-merge/sync para stubs do MOCK_DIR), e shadowa `gh` no
# PATH com um stub que loga argv e devolve RCs configuráveis. git/jq/perl são
# reais; nenhuma chamada de rede (origin é um bare local).

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SHIP="$BIN_DIR/ship.sh"

PASS=0; FAIL=0; FAILED=""
_fail() { FAIL=$((FAIL+1)); FAILED="${FAILED}
  ✗ $1"; }
_pass() { PASS=$((PASS+1)); }
assert_rc()           { [ "$1" = "$2" ] && _pass || _fail "$3 :: expected rc=$2 got rc=$1"; }
assert_rc_nonzero()   { [ "$1" != "0" ] && _pass || _fail "$2 :: expected rc!=0 got rc=0"; }
assert_contains()     { case "$1" in *"$2"*) _pass ;; *) _fail "$3 :: needle '$2' not found";; esac; }
assert_not_contains() { case "$1" in *"$2"*) _fail "$3 :: needle '$2' found but should NOT be";; *) _pass;; esac; }

# ─── Setup: repo git real 1 commit à frente de origin/main, tree limpo ──────
setup_repo() {
  REPO=$(mktemp -d); ORIGIN=$(mktemp -d)
  ( cd "$ORIGIN" && git init -q --bare ) >/dev/null 2>&1
  (
    cd "$REPO"
    git init -q -b main
    git config user.email t@t.com; git config user.name t
    git config commit.gpgsign false
    echo a > a.txt; git add a.txt; git commit -qm init
    git remote add origin "$ORIGIN"
    git push -q origin main
    echo b >> a.txt; git commit -qam more       # 1 ahead, tree limpo
  ) >/dev/null 2>&1
}

# ─── Setup: MOCK_DIR com ship.sh + stubs (gh, helpers) ─────────────────────
setup_mock() {
  MOCK_DIR=$(mktemp -d); CALL_LOG="$MOCK_DIR/calls.log"; : > "$CALL_LOG"
  cp "$SHIP" "$MOCK_DIR/ship.sh"; chmod +x "$MOCK_DIR/ship.sh"

  for h in commit-push-pr.sh sync.sh; do
    printf '#!/usr/bin/env bash\necho "%s $*" >> "$CALL_LOG"\nexit 0\n' "$h" > "$MOCK_DIR/$h"
    chmod +x "$MOCK_DIR/$h"
  done
  # force-merge stub loga FORCEMERGE para provar (ou refutar) que o merge ocorreu.
  printf '#!/usr/bin/env bash\necho "FORCEMERGE $*" >> "$CALL_LOG"\nexit 0\n' > "$MOCK_DIR/force-merge.sh"
  chmod +x "$MOCK_DIR/force-merge.sh"

  cat > "$MOCK_DIR/gh" <<'GH'
#!/usr/bin/env bash
echo "gh $*" >> "$CALL_LOG"
DEF_CHECKS='[{"state":"PENDING"}]'
case "$1" in
  pr)
    case "$2" in
      list)  echo "${SHIP_PR_NUM:-77}" ;;
      view)
        if [[ "$*" == *"--json state"* ]]; then echo "${SHIP_PR_STATE:-OPEN}"
        elif [[ "$*" == *"--json url"* ]]; then echo "https://example/pr/77"
        else echo "{}"; fi ;;
      checks)
        if [[ "$*" == *"--watch"* ]]; then exit "${SHIP_WATCH_RC:-0}"
        elif [[ "$*" == *"--json state"* ]]; then echo "${SHIP_CHECKS:-$DEF_CHECKS}"
        else echo "[]"; fi ;;
    esac ;;
  repo) echo "dev/test-repo" ;;
  api)  exit 1 ;;            # protection 404 → branch não-protegida
esac
exit 0
GH
  chmod +x "$MOCK_DIR/gh"
}

run_ship() {
  ( cd "$REPO" && PATH="$MOCK_DIR:$PATH" CALL_LOG="$CALL_LOG" "$@" bash "$MOCK_DIR/ship.sh" "feat: x" --skip-deploy 2>&1 )
}

# ═══════════════════════════════════════════════════════════════════════════
# AC1: caminho de CI usa `gh pr checks <pr> --watch` (call-log) e NÃO há
#      polling com sleep no trecho de checks (grep no source).
# ═══════════════════════════════════════════════════════════════════════════
setup_repo; setup_mock
OUT=$(SHIP_WATCH_RC=0 run_ship); RC=$?
assert_rc "$RC" 0 "AC1 CI verde → ship rc=0"
assert_contains "$(cat "$CALL_LOG")" "pr checks 77 --watch" "AC1 invoca gh pr checks --watch"
assert_contains "$(cat "$CALL_LOG")" "FORCEMERGE" "AC1 com CI verde prossegue pro merge"
# Source: idioma perl-alarm presente; loop de polling antigo removido.
assert_contains "$(cat "$SHIP")" 'perl -e' "AC1 ship usa perl alarm como teto"
assert_contains "$(cat "$SHIP")" 'gh pr checks "$PR_NUM" --watch' "AC1 ship tem o --watch no source"
assert_not_contains "$(cat "$SHIP")" 'for i in 1 2 3 4 5 6; do' "AC1 loop de polling antigo removido"
rm -rf "$REPO" "$ORIGIN" "$MOCK_DIR"

# ═══════════════════════════════════════════════════════════════════════════
# AC2: gh pr checks --watch falha (exit 8) → ship aborta SEM mergear.
# ═══════════════════════════════════════════════════════════════════════════
setup_repo; setup_mock
OUT=$(SHIP_WATCH_RC=8 run_ship); RC=$?
assert_rc_nonzero "$RC" "AC2 CI vermelho → ship rc!=0"
assert_contains "$(cat "$CALL_LOG")" "pr checks 77 --watch" "AC2 chegou a observar o CI"
assert_not_contains "$(cat "$CALL_LOG")" "FORCEMERGE" "AC2 NÃO mergeia com CI vermelho"
rm -rf "$REPO" "$ORIGIN" "$MOCK_DIR"

# ═══════════════════════════════════════════════════════════════════════════
# AC1b: PR sem checks → segue direto (sem watch, sem travar), prossegue merge.
# ═══════════════════════════════════════════════════════════════════════════
setup_repo; setup_mock
OUT=$(SHIP_CHECKS='[]' run_ship); RC=$?
assert_rc "$RC" 0 "AC1b sem checks → ship rc=0"
assert_not_contains "$(cat "$CALL_LOG")" "--watch" "AC1b não chama --watch quando não há checks"
assert_contains "$(cat "$CALL_LOG")" "FORCEMERGE" "AC1b prossegue pro merge sem checks"
rm -rf "$REPO" "$ORIGIN" "$MOCK_DIR"

# ─── Report ────────────────────────────────────────────────────────────────
echo ""
echo "─────────────────────────────────────────"
echo "test_ship_ci_watch.sh: PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then printf '%s\n' "$FAILED"; exit 1; fi
echo "  ✓ all assertions green"
exit 0

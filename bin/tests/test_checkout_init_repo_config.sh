#!/usr/bin/env bash
# bin/tests/test_checkout_init_repo_config.sh — Cobre o bloco de repo config
# adicionado em US-07 ao checkout-init.sh: habilita allow_auto_merge +
# delete_branch_on_merge no remote, com fallback gracioso.
#
# Estratégia: extrai o bloco de config e roda em isolamento com mocks de gh
# e git remote. Mais barato e determinístico do que rodar checkout-init.sh
# inteiro (que cloneria N slots de verdade).

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
INIT_SCRIPT="$BIN_DIR/checkout-init.sh"

PASS=0; FAIL=0; FAILED=""
_fail() { FAIL=$((FAIL+1)); FAILED="${FAILED}
  ✗ $1"; }
_pass() { PASS=$((PASS+1)); }
assert_rc()       { [ "$1" = "$2" ] && _pass || _fail "$3 :: rc=$2 esperado, got $1"; }
assert_contains() { case "$1" in *"$2"*) _pass ;; *) _fail "$3 :: needle '$2' não em output";; esac; }
assert_not_contains() { case "$1" in *"$2"*) _fail "$3 :: needle '$2' presente, deveria não estar";; *) _pass;; esac; }

setup_workspace() {
  WORKSPACE=$(mktemp -d)
  MOCK_DIR="$WORKSPACE/mocks"
  mkdir -p "$MOCK_DIR"
  CHECKOUT_BASE="$WORKSPACE/checkouts"
  REPO_NAME="testrepo"
  SLOT_PATH="$CHECKOUT_BASE/${REPO_NAME}-1"
  mkdir -p "$SLOT_PATH"
  # Init a fake git repo with a remote URL we control via mock
  git -C "$SLOT_PATH" init -q
  git -C "$SLOT_PATH" remote add origin "git@github.com:dev/testrepo.git"
}

teardown_workspace() {
  [ -n "${WORKSPACE:-}" ] && rm -rf "$WORKSPACE"
  unset WORKSPACE MOCK_DIR CHECKOUT_BASE REPO_NAME SLOT_PATH
}

write_gh_mock() {
  cat > "$MOCK_DIR/gh" <<'MOCK_EOF'
#!/usr/bin/env bash
# Mock gh: lê env vars MOCK_IS_ADMIN, MOCK_PATCH_RC.
case "$1" in
  api)
    if [[ "$*" == *"--jq"* ]] && [[ "$*" == *"permissions.admin"* ]]; then
      echo "${MOCK_IS_ADMIN:-false}"
      exit 0
    fi
    if [ "$2" = "-X" ] && [ "${3:-}" = "PATCH" ]; then
      if [ "${MOCK_PATCH_RC:-0}" = "0" ]; then
        echo "{}"
        exit 0
      else
        echo "patch failed" >&2
        exit 1
      fi
    fi
    ;;
esac
exit 0
MOCK_EOF
  chmod +x "$MOCK_DIR/gh"
}

# Run only the config block from checkout-init.sh in isolation.
# Inject CHECKOUT_BASE + REPO_NAME via env, source the block.
run_config_block() {
  # Extract the block: from the comment about "Configurar repo no GitHub"
  # up to (but not including) "# Instalar dependências".
  awk '
    /^# Configurar repo no GitHub/{p=1}
    /^# Instalar dependências/{p=0}
    p
  ' "$INIT_SCRIPT" > "$WORKSPACE/config-block.sh"

  PATH="$MOCK_DIR:$PATH" \
    CHECKOUT_BASE="$CHECKOUT_BASE" \
    REPO_NAME="$REPO_NAME" \
    bash "$WORKSPACE/config-block.sh" 2>&1
}

# ═══════════════════════════════════════════════════════════════════════════
# Test 1: usuário é admin → PATCH chamado, mensagem de sucesso
# ═══════════════════════════════════════════════════════════════════════════
setup_workspace
export MOCK_IS_ADMIN=true
export MOCK_PATCH_RC=0
write_gh_mock
OUT=$(run_config_block); RC=$?
assert_rc "$RC" 0 "(1) admin path rc=0"
assert_contains "$OUT" "habilitados em dev/testrepo" "(1) success message names repo"
unset MOCK_IS_ADMIN MOCK_PATCH_RC
teardown_workspace

# ═══════════════════════════════════════════════════════════════════════════
# Test 2: usuário NÃO é admin → log warning, continua (rc=0)
# ═══════════════════════════════════════════════════════════════════════════
setup_workspace
export MOCK_IS_ADMIN=false
write_gh_mock
OUT=$(run_config_block); RC=$?
assert_rc "$RC" 0 "(2) non-admin rc=0 (graceful)"
assert_contains "$OUT" "Sem permissão admin" "(2) warning explica falta de permissão"
assert_contains "$OUT" "dev/testrepo" "(2) warning nomeia o repo"
assert_not_contains "$OUT" "habilitados em" "(2) NÃO emite mensagem de sucesso"
unset MOCK_IS_ADMIN
teardown_workspace

# ═══════════════════════════════════════════════════════════════════════════
# Test 3: PATCH falha (ex: rede) → log warning, continua (rc=0)
# ═══════════════════════════════════════════════════════════════════════════
setup_workspace
export MOCK_IS_ADMIN=true
export MOCK_PATCH_RC=1
write_gh_mock
OUT=$(run_config_block); RC=$?
assert_rc "$RC" 0 "(3) PATCH-fail rc=0 (graceful)"
assert_contains "$OUT" "PATCH falhou" "(3) warning explica falha do PATCH"
unset MOCK_IS_ADMIN MOCK_PATCH_RC
teardown_workspace

# ═══════════════════════════════════════════════════════════════════════════
# Test 4: gh CLI ausente → log warning, continua (rc=0)
# Estratégia: shadow `gh` com um stub que exit 127 (command-not-found-style)
# E faz `command -v gh` retornar falso. O jeito mais simples é criar um
# diretório de mocks com um shim "gh" que NÃO é executável (assim
# `command -v` o ignora) — mas isso depende do PATH não ter outro gh real
# antes. Solução robusta: tornar o teste chamar o bloco isolando PATH para
# excluir o real gh, mantendo /usr/bin e /bin.
setup_workspace
# Construir PATH sem o diretório do gh real
GH_REAL=$(command -v gh)
GH_DIR=$(dirname "$GH_REAL")
# Filtrar GH_DIR do PATH atual
NEW_PATH=$(echo "$PATH" | tr ':' '\n' | grep -v -F -x "$GH_DIR" | tr '\n' ':' | sed 's/:$//')
# Confirma que gh ficou inacessível neste PATH
if PATH="$NEW_PATH" command -v gh >/dev/null 2>&1; then
  _fail "(4) setup: gh ainda no PATH após filtrar — múltiplas instalações?"
else
  _pass
fi
OUT=$(
  PATH="$NEW_PATH" \
    CHECKOUT_BASE="$CHECKOUT_BASE" \
    REPO_NAME="$REPO_NAME" \
    bash "$WORKSPACE/config-block.sh" 2>&1
)
RC=$?
# Precisamos gerar config-block.sh primeiro
awk '
  /^# Configurar repo no GitHub/{p=1}
  /^# Instalar dependências/{p=0}
  p
' "$INIT_SCRIPT" > "$WORKSPACE/config-block.sh"
# Rerun com o block agora gerado
OUT=$(
  PATH="$NEW_PATH" \
    CHECKOUT_BASE="$CHECKOUT_BASE" \
    REPO_NAME="$REPO_NAME" \
    bash "$WORKSPACE/config-block.sh" 2>&1
)
RC=$?
assert_rc "$RC" 0 "(4) gh ausente rc=0 (graceful)"
assert_contains "$OUT" "gh CLI ausente" "(4) warning explica gh ausente"
teardown_workspace

# ─── Final report ──────────────────────────────────────────────────────────
echo ""
echo "─────────────────────────────────────────"
echo "test_checkout_init_repo_config.sh: PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf '%s\n' "$FAILED"
  exit 1
fi
echo "  ✓ all assertions green"
exit 0

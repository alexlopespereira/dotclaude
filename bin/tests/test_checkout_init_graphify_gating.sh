#!/usr/bin/env bash
# bin/tests/test_checkout_init_graphify_gating.sh — Cobre o bloco Graphify
# do checkout-init.sh após Errata 2026-05-08 do ADR 0001:
#
#   - /graphify-init é dono da config versionada (CLAUDE.md + .claude/settings.json).
#   - /checkout-init cuida apenas dos hooks per-clone (.git/hooks/).
#   - Gating: só instala hooks se o repo é Graphified em main
#     (graphify-out/graph.json presente no slot 1 recém-clonado).
#
# Estratégia: extrai o bloco Graphify e roda em isolamento com graphify CLI
# mockada via PATH. O mock loga cada invocação; asserts checam que
# `hook install` é chamado N vezes e `claude install` NUNCA.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
INIT_SCRIPT="$BIN_DIR/checkout-init.sh"

PASS=0; FAIL=0; FAILED=""
_fail() { FAIL=$((FAIL+1)); FAILED="${FAILED}
  ✗ $1"; }
_pass() { PASS=$((PASS+1)); }
assert_rc()           { [ "$1" = "$2" ] && _pass || _fail "$3 :: rc=$2 esperado, got $1"; }
assert_contains()     { case "$1" in *"$2"*) _pass ;; *) _fail "$3 :: needle '$2' não em output";; esac; }
assert_not_contains() { case "$1" in *"$2"*) _fail "$3 :: needle '$2' presente, deveria não estar";; *) _pass;; esac; }
assert_eq()           { [ "$1" = "$2" ] && _pass || _fail "$3 :: '$2' esperado, got '$1'"; }

setup_workspace() {
  WORKSPACE=$(mktemp -d)
  MOCK_DIR="$WORKSPACE/mocks"
  mkdir -p "$MOCK_DIR"
  CHECKOUT_BASE="$WORKSPACE/checkouts"
  REPO_NAME="testrepo"
  SLOTS=5
  GRAPHIFY_LOG="$WORKSPACE/graphify.log"
  : > "$GRAPHIFY_LOG"
  for i in $(seq 1 "$SLOTS"); do
    mkdir -p "$CHECKOUT_BASE/${REPO_NAME}-${i}"
  done
}

teardown_workspace() {
  [ -n "${WORKSPACE:-}" ] && rm -rf "$WORKSPACE"
  unset WORKSPACE MOCK_DIR CHECKOUT_BASE REPO_NAME SLOTS GRAPHIFY_LOG
}

mark_repo_graphified() {
  # Sinaliza repo Graphified colocando graphify-out/graph.json no slot 1
  # (gate do checkout-init.sh após Errata 2026-05-08).
  mkdir -p "$CHECKOUT_BASE/${REPO_NAME}-1/graphify-out"
  echo '{}' > "$CHECKOUT_BASE/${REPO_NAME}-1/graphify-out/graph.json"
}

write_graphify_mock() {
  cat > "$MOCK_DIR/graphify" <<MOCK_EOF
#!/usr/bin/env bash
# Mock graphify CLI: loga subcomando+args, retorna 0.
echo "\$@" >> "$GRAPHIFY_LOG"
exit 0
MOCK_EOF
  chmod +x "$MOCK_DIR/graphify"
}

# Extrai o bloco Graphify do checkout-init.sh em arquivo temporário.
# Sentinelas: comentário "# Instalar Graphify hooks por slot" → "# Metadata".
extract_graphify_block() {
  awk '
    /^# Instalar Graphify hooks por slot/{p=1}
    /^# Metadata/{p=0}
    p
  ' "$INIT_SCRIPT" > "$WORKSPACE/graphify-block.sh"
}

run_graphify_block() {
  local no_graphify="${1:-false}"
  local with_cli="${2:-true}"
  extract_graphify_block

  local path_to_use="$PATH"
  if [ "$with_cli" = "true" ]; then
    path_to_use="$MOCK_DIR:$PATH"
  else
    # Remover dir do graphify real do PATH (e mock também não está)
    local real_dir
    real_dir=$(dirname "$(command -v graphify 2>/dev/null || echo /nonexistent/x)")
    path_to_use=$(echo "$PATH" | tr ':' '\n' | grep -v -F -x "$real_dir" | grep -v -F -x "$MOCK_DIR" | tr '\n' ':' | sed 's/:$//')
  fi

  PATH="$path_to_use" \
    CHECKOUT_BASE="$CHECKOUT_BASE" \
    REPO_NAME="$REPO_NAME" \
    SLOTS="$SLOTS" \
    NO_GRAPHIFY="$no_graphify" \
    bash "$WORKSPACE/graphify-block.sh" 2>&1
}

count_log_lines() {
  local pattern="$1"
  awk -v p="$pattern" '$0 ~ p {n++} END {print n+0}' "$GRAPHIFY_LOG" 2>/dev/null
}

# ═══════════════════════════════════════════════════════════════════════════
# Test 1: repo Graphified + CLI presente
#   → hook install chamado N=5 vezes
#   → claude install NUNCA chamado (Errata: deve sair do checkout-init)
#   → output anuncia hooks instalados nos N slots
# ═══════════════════════════════════════════════════════════════════════════
setup_workspace
mark_repo_graphified
write_graphify_mock
OUT=$(run_graphify_block "false" "true"); RC=$?
assert_rc "$RC" 0 "(1) Graphified+CLI rc=0"
HOOK_COUNT=$(count_log_lines "^hook install$")
CLAUDE_COUNT=$(count_log_lines "^claude install$")
assert_eq "$HOOK_COUNT" "5" "(1) hook install chamado 5x"
assert_eq "$CLAUDE_COUNT" "0" "(1) claude install NUNCA chamado"
assert_contains "$OUT" "Graphify hooks no slot 1" "(1) anuncia slot 1"
assert_contains "$OUT" "Graphify hooks no slot 5" "(1) anuncia slot 5"
assert_contains "$OUT" "instalados em 5 slot(s)" "(1) summary com count"
teardown_workspace

# ═══════════════════════════════════════════════════════════════════════════
# Test 2: repo NÃO-Graphified (sem graphify-out/graph.json no slot 1)
#   → bloco skippado integralmente (gating não passa)
#   → output não menciona Graphify
#   → mock NÃO invocado
# ═══════════════════════════════════════════════════════════════════════════
setup_workspace
write_graphify_mock
OUT=$(run_graphify_block "false" "true"); RC=$?
assert_rc "$RC" 0 "(2) não-Graphified rc=0"
assert_not_contains "$OUT" "Graphify" "(2) output sem menção a Graphify"
HOOK_COUNT=$(count_log_lines "^hook install$")
CLAUDE_COUNT=$(count_log_lines "^claude install$")
assert_eq "$HOOK_COUNT" "0" "(2) hook install não chamado"
assert_eq "$CLAUDE_COUNT" "0" "(2) claude install não chamado"
teardown_workspace

# ═══════════════════════════════════════════════════════════════════════════
# Test 3: repo Graphified mas --no-graphify (NO_GRAPHIFY=true)
#   → flag wins; bloco skippado mesmo com gating positivo
#   → output sem menção a Graphify
#   → mock NÃO invocado
# ═══════════════════════════════════════════════════════════════════════════
setup_workspace
mark_repo_graphified
write_graphify_mock
OUT=$(run_graphify_block "true" "true"); RC=$?
assert_rc "$RC" 0 "(3) --no-graphify rc=0"
assert_not_contains "$OUT" "Graphify hooks no slot" "(3) sem invocação per-slot"
HOOK_COUNT=$(count_log_lines "^hook install$")
assert_eq "$HOOK_COUNT" "0" "(3) flag wins — hook install pulado"
teardown_workspace

# ═══════════════════════════════════════════════════════════════════════════
# Test 4: repo Graphified + CLI graphify ausente do PATH
#   → warning não-fatal; rc=0
#   → instrução de install na 2ª linha
# ═══════════════════════════════════════════════════════════════════════════
setup_workspace
mark_repo_graphified
# Não escreve mock — CLI estará ausente
OUT=$(run_graphify_block "false" "false"); RC=$?
assert_rc "$RC" 0 "(4) CLI ausente rc=0 (graceful)"
assert_contains "$OUT" "graphify CLI ausente" "(4) warning explica CLI ausente"
assert_contains "$OUT" "uv tool install graphifyy" "(4) instrução de install"
teardown_workspace

# ─── Final report ──────────────────────────────────────────────────────────
echo ""
echo "─────────────────────────────────────────"
echo "test_checkout_init_graphify_gating.sh: PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf '%s\n' "$FAILED"
  exit 1
fi
echo "  ✓ all assertions green"
exit 0

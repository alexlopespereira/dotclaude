#!/usr/bin/env bash
# bin/tests/test_graphify_drift.sh — Unit tests para os helpers em
# bin/lib/graphify_version.sh (drift detection da CLI graphify vs.
# artefatos committados em graphify-out/.graphify_version).
#
# Estratégia: sourcear o lib, mockar `uv` e `pip` via PATH, e validar
# _graphify_installed_version() e _graphify_drift_check() em cenários.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_FILE="$(cd "$SCRIPT_DIR/.." && pwd)/lib/graphify_version.sh"

PASS=0; FAIL=0; FAILED=""
_fail() { FAIL=$((FAIL+1)); FAILED="${FAILED}
  ✗ $1"; }
_pass() { PASS=$((PASS+1)); }
assert_eq()           { [ "$1" = "$2" ] && _pass || _fail "$3 :: esperado '$2', got '$1'"; }
assert_contains()     { case "$1" in *"$2"*) _pass ;; *) _fail "$3 :: needle '$2' não em output";; esac; }
assert_not_contains() { case "$1" in *"$2"*) _fail "$3 :: needle '$2' presente, deveria não estar";; *) _pass;; esac; }
assert_empty()        { [ -z "$1" ] && _pass || _fail "$2 :: output não-vazio: '$1'"; }

setup() {
  WORKSPACE=$(mktemp -d)
  MOCK_DIR="$WORKSPACE/mocks"
  SLOT_DIR="$WORKSPACE/slot"
  mkdir -p "$MOCK_DIR" "$SLOT_DIR/graphify-out"
  # Stubs default FALHOS de uv e pip (exit 1, stdout vazio) — mock_uv/mock_pip
  # sobrescrevem por cenário. MOCK_DIR vem primeiro no PATH, então nenhum
  # cenário cai no uv/pip REAIS do host. Não filtrar dirs do PATH pra "sumir"
  # com binários: sob usrmerge (Ubuntu) pip mora em /usr/bin junto de
  # awk/sed — remover o dir quebraria os próprios helpers da lib.
  printf '#!/usr/bin/env bash\nexit 1\n' > "$MOCK_DIR/uv"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$MOCK_DIR/pip"
  chmod +x "$MOCK_DIR/uv" "$MOCK_DIR/pip"
  TEST_PATH="$MOCK_DIR:$PATH"
}

teardown() {
  [ -n "${WORKSPACE:-}" ] && rm -rf "$WORKSPACE"
  unset WORKSPACE MOCK_DIR SLOT_DIR TEST_PATH
}

mock_uv() {
  # $1 = output literal pro `uv tool list`
  local out="$1"
  cat > "$MOCK_DIR/uv" <<MOCK_EOF
#!/usr/bin/env bash
if [ "\$1" = "tool" ] && [ "\$2" = "list" ]; then
  cat <<DATA
$out
DATA
  exit 0
fi
exit 0
MOCK_EOF
  chmod +x "$MOCK_DIR/uv"
}

mock_pip() {
  # $1 = versão simulada (string vazia = pacote não encontrado)
  local ver="$1"
  cat > "$MOCK_DIR/pip" <<MOCK_EOF
#!/usr/bin/env bash
if [ "\$1" = "show" ] && [ "\$2" = "graphifyy" ]; then
  if [ -n "$ver" ]; then
    echo "Name: graphifyy"
    echo "Version: $ver"
  fi
  exit 0
fi
exit 0
MOCK_EOF
  chmod +x "$MOCK_DIR/pip"
}

# Source o lib (helpers ficam disponíveis na shell de teste)
# shellcheck source=../lib/graphify_version.sh
. "$LIB_FILE"

# ═══════════════════════════════════════════════════════════════════════════
# T1: _graphify_installed_version lê de `uv tool list`
# ═══════════════════════════════════════════════════════════════════════════
setup
mock_uv "graphifyy v0.7.10
- graphify"
OUT=$(PATH="$TEST_PATH" _graphify_installed_version)
assert_eq "$OUT" "0.7.10" "(T1) uv tool list → '0.7.10'"
teardown

# ═══════════════════════════════════════════════════════════════════════════
# T2: fallback para `pip show graphifyy` quando uv indisponível
# 'uv indisponível' cobre ausente-E-falhando — observavelmente idênticos:
# toda leitura da lib é `cmd 2>/dev/null | pipeline`, então uv ausente e uv
# que falha (stub default do setup: exit 1, stdout vazio) produzem ambos
# v="" e caem no fallback pip.
# ═══════════════════════════════════════════════════════════════════════════
setup
mock_pip "0.6.5"
OUT=$(PATH="$TEST_PATH" _graphify_installed_version)
assert_eq "$OUT" "0.6.5" "(T2) pip show → '0.6.5'"
teardown

# ═══════════════════════════════════════════════════════════════════════════
# T3: retorna string vazia quando nem uv nem pip acham graphifyy
# ═══════════════════════════════════════════════════════════════════════════
setup
mock_uv ""              # uv presente mas tool list não lista graphifyy
mock_pip ""             # pip presente mas pacote não encontrado
OUT=$(PATH="$TEST_PATH" _graphify_installed_version)
assert_eq "$OUT" "" "(T3) nada encontrado → string vazia"
teardown

# ═══════════════════════════════════════════════════════════════════════════
# T4: _graphify_drift_check silente quando .graphify_version ausente
# ═══════════════════════════════════════════════════════════════════════════
setup
mock_uv "graphifyy v0.7.10
- graphify"
# Não criar SLOT_DIR/graphify-out/.graphify_version
OUT=$(PATH="$TEST_PATH" _graphify_drift_check "$SLOT_DIR")
assert_empty "$OUT" "(T4) sem .graphify_version → silente"
teardown

# ═══════════════════════════════════════════════════════════════════════════
# T5: silente quando versões batem
# ═══════════════════════════════════════════════════════════════════════════
setup
mock_uv "graphifyy v0.7.10
- graphify"
echo "0.7.10" > "$SLOT_DIR/graphify-out/.graphify_version"
OUT=$(PATH="$TEST_PATH" _graphify_drift_check "$SLOT_DIR")
assert_empty "$OUT" "(T5) versões iguais → silente"
teardown

# ═══════════════════════════════════════════════════════════════════════════
# T6: warning quando versões diferem — contém ambas + dica de refresh
# ═══════════════════════════════════════════════════════════════════════════
setup
mock_uv "graphifyy v0.7.10
- graphify"
echo "0.7.8" > "$SLOT_DIR/graphify-out/.graphify_version"
OUT=$(PATH="$TEST_PATH" _graphify_drift_check "$SLOT_DIR")
assert_contains "$OUT" "graphify CLI drift" "(T6) prefixo do warning"
assert_contains "$OUT" "committed=0.7.8" "(T6) versão committada no warning"
assert_contains "$OUT" "local=0.7.10" "(T6) versão local no warning"
assert_contains "$OUT" "/commit-push-pr" "(T6) dica de refresh"
teardown

# ═══════════════════════════════════════════════════════════════════════════
# T7: silente quando .graphify_version está vazio (proteção contra corrupção)
# ═══════════════════════════════════════════════════════════════════════════
setup
mock_uv "graphifyy v0.7.10
- graphify"
: > "$SLOT_DIR/graphify-out/.graphify_version"   # arquivo vazio
OUT=$(PATH="$TEST_PATH" _graphify_drift_check "$SLOT_DIR")
assert_empty "$OUT" "(T7) committed vazio → silente"
teardown

# ═══════════════════════════════════════════════════════════════════════════
# T8: silente quando versão local indetectável (uv/pip somem)
# ═══════════════════════════════════════════════════════════════════════════
setup
# Sem mock_uv/mock_pip — valem os stubs default falhos do setup()
echo "0.7.8" > "$SLOT_DIR/graphify-out/.graphify_version"
OUT=$(PATH="$TEST_PATH" _graphify_drift_check "$SLOT_DIR")
assert_empty "$OUT" "(T8) local indetectável → silente (não falso-positivo)"
teardown

# ─── Final report ──────────────────────────────────────────────────────────
echo ""
echo "─────────────────────────────────────────"
echo "test_graphify_drift.sh: PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf '%s\n' "$FAILED"
  exit 1
fi
echo "  ✓ all assertions green"
exit 0

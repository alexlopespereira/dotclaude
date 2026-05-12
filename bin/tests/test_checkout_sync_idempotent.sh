#!/usr/bin/env bash
# bin/tests/test_checkout_sync_idempotent.sh — Integração: valida que
# /sync (checkout-sync-all.sh) é idempotente após L1 do ADR 0001
# Errata 2026-05-12:
#
#   - L1: `git checkout -- graphify-out/` antes do dirty-check descarta
#     o regen do /sync anterior. Sem isso, sync N+1 pula o slot porque
#     o próprio sync N deixou graphify-out/ dirty.
#   - L2: warning quando graphify CLI local difere de
#     graphify-out/.graphify_version.
#
# Estratégia: cria repo bare + slot clonado em tmpdir, sobrescreve HOME
# pra apontar `$HOME/Projects/checkouts` ao tmpdir, mocka `graphify` e
# `uv` via PATH, e roda o script real. Cobre fluxo end-to-end.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SYNC_SCRIPT="$BIN_DIR/checkout-sync-all.sh"

PASS=0; FAIL=0; FAILED=""
_fail() { FAIL=$((FAIL+1)); FAILED="${FAILED}
  ✗ $1"; }
_pass() { PASS=$((PASS+1)); }
assert_rc()           { [ "$1" = "$2" ] && _pass || _fail "$3 :: rc=$2 esperado, got $1"; }
assert_contains()     { case "$1" in *"$2"*) _pass ;; *) _fail "$3 :: needle '$2' não em output";; esac; }
assert_not_contains() { case "$1" in *"$2"*) _fail "$3 :: needle '$2' presente, deveria não estar";; *) _pass;; esac; }
assert_eq()           { [ "$1" = "$2" ] && _pass || _fail "$3 :: esperado '$2', got '$1'"; }

setup() {
  WORKSPACE=$(mktemp -d)
  FAKE_HOME="$WORKSPACE/home"
  mkdir -p "$FAKE_HOME/Projects/checkouts"

  MOCK_DIR="$WORKSPACE/mocks"
  mkdir -p "$MOCK_DIR"

  REPO_NAME="syncrepo"
  ORIGIN_DIR="$WORKSPACE/origin.git"
  SOURCE_DIR="$WORKSPACE/source"
  SLOT_DIR="$FAKE_HOME/Projects/checkouts/${REPO_NAME}-1"

  # 1. Cria source repo com graphify-out/ committado
  mkdir -p "$SOURCE_DIR/graphify-out"
  cd "$SOURCE_DIR"
  git init -q -b main .
  git config user.email "test@test"
  git config user.name "test"
  echo "main code" > main.py
  echo '{"nodes":["seed"],"edges":[]}' > graphify-out/graph.json
  echo "# Graph Report" > graphify-out/GRAPH_REPORT.md
  echo "<html>seed</html>" > graphify-out/graph.html
  echo "$SOURCE_DIR" > graphify-out/.graphify_root
  echo "0.7.10" > graphify-out/.graphify_version
  git add . >/dev/null
  git commit -q -m "initial with graphify-out"
  cd "$WORKSPACE"

  # 2. Bare remote
  git clone --bare -q "$SOURCE_DIR" "$ORIGIN_DIR" 2>/dev/null
  # Define HEAD do bare repo apontando pra main (clone --bare herda o HEAD do source)

  # 3. Clona pro slot
  git clone --quiet "$ORIGIN_DIR" "$SLOT_DIR" 2>/dev/null
  git -C "$SLOT_DIR" config user.email "test@test"
  git -C "$SLOT_DIR" config user.name "test"

  # 4. Mock graphify: simula regen rewriting graphify-out/graph.json
  # (cada chamada incrementa um contador no log e altera o JSON)
  GRAPHIFY_LOG="$WORKSPACE/graphify.log"
  : > "$GRAPHIFY_LOG"
  cat > "$MOCK_DIR/graphify" <<MOCK_EOF
#!/usr/bin/env bash
echo "\$@" >> "$GRAPHIFY_LOG"
if [ "\$1" = "update" ]; then
  # Simula regen: reescreve graph.json com timestamp pra forçar diff
  echo "{\"nodes\":[\"regenerated\"],\"edges\":[],\"t\":\$(date +%s%N)}" > graphify-out/graph.json
fi
exit 0
MOCK_EOF
  chmod +x "$MOCK_DIR/graphify"

  # 5. Mock uv (versão local = committed para evitar drift no setup padrão)
  cat > "$MOCK_DIR/uv" <<'MOCK_EOF'
#!/usr/bin/env bash
if [ "$1" = "tool" ] && [ "$2" = "list" ]; then
  echo "graphifyy v0.7.10"
  echo "- graphify"
fi
exit 0
MOCK_EOF
  chmod +x "$MOCK_DIR/uv"

  # PATH limpo: nossos mocks + tools básicos (git/bash/coreutils)
  TEST_PATH="$MOCK_DIR:$PATH"
}

teardown() {
  [ -n "${WORKSPACE:-}" ] && rm -rf "$WORKSPACE"
  unset WORKSPACE FAKE_HOME MOCK_DIR REPO_NAME ORIGIN_DIR SOURCE_DIR SLOT_DIR GRAPHIFY_LOG TEST_PATH
}

run_sync() {
  HOME="$FAKE_HOME" PATH="$TEST_PATH" bash "$SYNC_SCRIPT" "$REPO_NAME" 2>&1
}

# ═══════════════════════════════════════════════════════════════════════════
# T1: slot clean → sync ok, graphify update invocado
# ═══════════════════════════════════════════════════════════════════════════
setup
OUT=$(run_sync); RC=$?
assert_rc "$RC" 0 "(T1) sync slot clean rc=0"
assert_contains "$OUT" "✓ atualizado" "(T1) slot atualizado"
assert_contains "$OUT" "atualizando graphify-out/" "(T1) regen rodou"
UPDATE_COUNT=$(grep -c "^update \." "$GRAPHIFY_LOG" || true)
assert_eq "$UPDATE_COUNT" "1" "(T1) graphify update . chamado 1x"
teardown

# ═══════════════════════════════════════════════════════════════════════════
# T2 (L1 core): slot com graphify-out/ dirty → NÃO pula (regression test
# do bug: antes do fix, sync 2 sempre pulava porque sync 1 deixou dirty)
# ═══════════════════════════════════════════════════════════════════════════
setup
# Simula estado pós-sync anterior: graphify-out/graph.json dirty
echo '{"nodes":["leftover"]}' > "$SLOT_DIR/graphify-out/graph.json"
assert_contains "$(git -C "$SLOT_DIR" status --porcelain)" "graphify-out/graph.json" "(T2 setup) dirty confirmado"

OUT=$(run_sync); RC=$?
assert_rc "$RC" 0 "(T2) L1: rc=0 mesmo com graphify-out dirty"
assert_contains "$OUT" "✓ atualizado" "(T2) L1: slot atualizado, não pulado"
assert_not_contains "$OUT" "slot dirty — pulando" "(T2) L1: NÃO pulou por dirty graphify-out"
teardown

# ═══════════════════════════════════════════════════════════════════════════
# T3 (L1 boundary): dirty FORA de graphify-out/ ainda bloqueia
# (proteção pra trabalho de usuário em código real)
# ═══════════════════════════════════════════════════════════════════════════
setup
echo "user work in progress" > "$SLOT_DIR/main.py"
OUT=$(run_sync); RC=$?
assert_rc "$RC" 0 "(T3) script termina rc=0"
assert_contains "$OUT" "slot dirty — pulando" "(T3) dirty em main.py bloqueia"
assert_contains "$OUT" "0 atualizados" "(T3) zero slots processados"
teardown

# ═══════════════════════════════════════════════════════════════════════════
# T4 (idempotência): rodar sync duas vezes seguidas → ambos processam
# (sem L1, segundo sync pularia)
# ═══════════════════════════════════════════════════════════════════════════
setup
OUT1=$(run_sync); RC1=$?
OUT2=$(run_sync); RC2=$?
assert_rc "$RC1" 0 "(T4) sync #1 rc=0"
assert_rc "$RC2" 0 "(T4) sync #2 rc=0"
assert_contains "$OUT1" "✓ atualizado" "(T4) sync #1 atualizou"
assert_contains "$OUT2" "✓ atualizado" "(T4) sync #2 atualizou (idempotente)"
assert_not_contains "$OUT2" "slot dirty — pulando" "(T4) sync #2 NÃO pulou"
teardown

# ═══════════════════════════════════════════════════════════════════════════
# T5 (L2 integração): drift entre .graphify_version e CLI local → warning
# ═══════════════════════════════════════════════════════════════════════════
setup
# Slot tem .graphify_version=0.7.10 (do setup), mock uv também retorna 0.7.10.
# Forçar drift: reescreve a versão committada localmente pra 0.7.8.
echo "0.7.8" > "$SLOT_DIR/graphify-out/.graphify_version"
git -C "$SLOT_DIR" add graphify-out/.graphify_version >/dev/null 2>&1 || true
git -C "$SLOT_DIR" commit -q -m "downgrade marker" 2>/dev/null || true

OUT=$(run_sync); RC=$?
assert_rc "$RC" 0 "(T5) sync rc=0 mesmo com drift"
assert_contains "$OUT" "graphify CLI drift" "(T5) warning de drift presente"
assert_contains "$OUT" "committed=0.7.8" "(T5) versão committada no warning"
assert_contains "$OUT" "local=0.7.10" "(T5) versão local no warning"
teardown

# ═══════════════════════════════════════════════════════════════════════════
# T6 (L2 boundary): versões iguais → sem warning, sync normal
# ═══════════════════════════════════════════════════════════════════════════
setup
OUT=$(run_sync); RC=$?
assert_rc "$RC" 0 "(T6) sync rc=0"
assert_not_contains "$OUT" "graphify CLI drift" "(T6) versões iguais → sem warning"
teardown

# ─── Final report ──────────────────────────────────────────────────────────
echo ""
echo "─────────────────────────────────────────"
echo "test_checkout_sync_idempotent.sh: PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf '%s\n' "$FAILED"
  exit 1
fi
echo "  ✓ all assertions green"
exit 0

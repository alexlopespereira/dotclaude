#!/usr/bin/env bash
# bin/tests/test_sync_pool.sh — Cobre o fallback de inferência de pool do
# bin/checkout-sync.sh (US-03 do ciclo quick-wins-item3; renomeado de bin/sync.sh em US-05).
#
# Estratégia: bin/checkout-sync.sh resolve o checkout base e o script checkout-sync-all
# via seams de env (SYNC_CHECKOUT_BASE, SYNC_CHECKOUT_SYNC_ALL). Cada teste
# injeta um stub de checkout-sync-all que loga argv em $CALL_LOG, monta um repo
# git real fora do base (git é read-only aqui: só rev-parse) e roda checkout-sync.sh do
# cwd certo. `git` é real; nenhuma chamada de rede.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SYNC="$BIN_DIR/checkout-sync.sh"

PASS=0; FAIL=0; FAILED=""
_fail() { FAIL=$((FAIL+1)); FAILED="${FAILED}
  ✗ $1"; }
_pass() { PASS=$((PASS+1)); }
assert_rc()           { [ "$1" = "$2" ] && _pass || _fail "$3 :: expected rc=$2 got rc=$1"; }
assert_rc_nonzero()   { [ "$1" != "0" ] && _pass || _fail "$2 :: expected rc!=0 got rc=0"; }
assert_contains()     { case "$1" in *"$2"*) _pass ;; *) _fail "$3 :: needle '$2' not found in: $1";; esac; }
assert_not_contains() { case "$1" in *"$2"*) _fail "$3 :: needle '$2' found but should NOT be";; *) _pass;; esac; }

# Stub de checkout-sync-all que apenas loga argv.
make_stub() {
  STUB="$1"
  cat > "$STUB" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$CALL_LOG"
exit 0
EOF
  chmod +x "$STUB"
}

# Cria um repo git real em <base_dir>/<name> e retorna o caminho via stdout.
make_git_repo() {
  local parent="$1" name="$2" dir
  dir="$parent/$name"
  mkdir -p "$dir"
  ( cd "$dir" && git init -q && git config user.email t@t.com && git config user.name t ) >/dev/null 2>&1
  echo "$dir"
}

run_sync() {
  # $1 = cwd, resto = args de checkout-sync.sh
  local cwd="$1"; shift
  ( cd "$cwd" && SYNC_CHECKOUT_BASE="$BASE" SYNC_CHECKOUT_SYNC_ALL="$STUB" \
      CALL_LOG="$CALL_LOG" bash "$SYNC" "$@" 2>&1 )
}

# ═══════════════════════════════════════════════════════════════════════════
# AC3: cwd em repo git fora do base, com pool correspondente → infere + chama
# ═══════════════════════════════════════════════════════════════════════════
TMP=$(mktemp -d); BASE="$TMP/checkouts"; CALL_LOG="$TMP/calls.log"; STUB="$TMP/sync-all-stub.sh"
mkdir -p "$BASE/myrepo-1"            # pool existe
: > "$CALL_LOG"; make_stub "$STUB"
WORK=$(mktemp -d); GITREPO=$(make_git_repo "$WORK" "myrepo")
OUT=$(run_sync "$GITREPO"); RC=$?
assert_rc "$RC" 0 "AC3 infere e roda → rc=0"
assert_contains "$OUT" "myrepo" "AC3 loga a inferência citando o repo"
assert_contains "$(cat "$CALL_LOG")" "myrepo" "AC3 chama checkout-sync-all com o repo certo"
rm -rf "$TMP" "$WORK"

# ═══════════════════════════════════════════════════════════════════════════
# AC3 (variação): basename com sufixo -N é stripado antes de casar o pool
# ═══════════════════════════════════════════════════════════════════════════
TMP=$(mktemp -d); BASE="$TMP/checkouts"; CALL_LOG="$TMP/calls.log"; STUB="$TMP/sync-all-stub.sh"
mkdir -p "$BASE/storefront-1"
: > "$CALL_LOG"; make_stub "$STUB"
WORK=$(mktemp -d); GITREPO=$(make_git_repo "$WORK" "storefront-3")   # clone com sufixo
OUT=$(run_sync "$GITREPO"); RC=$?
assert_rc "$RC" 0 "AC3v sufixo -3 stripado → rc=0"
assert_contains "$(cat "$CALL_LOG")" "storefront" "AC3v chama com 'storefront' (sem -3)"
assert_not_contains "$(cat "$CALL_LOG")" "storefront-3" "AC3v não passa o sufixo"
rm -rf "$TMP" "$WORK"

# ═══════════════════════════════════════════════════════════════════════════
# AC4a: cwd em repo git fora do base SEM pool correspondente → erro claro
# ═══════════════════════════════════════════════════════════════════════════
TMP=$(mktemp -d); BASE="$TMP/checkouts"; CALL_LOG="$TMP/calls.log"; STUB="$TMP/sync-all-stub.sh"
mkdir -p "$BASE"                    # base existe mas sem o pool do repo
: > "$CALL_LOG"; make_stub "$STUB"
WORK=$(mktemp -d); GITREPO=$(make_git_repo "$WORK" "sempool")
OUT=$(run_sync "$GITREPO"); RC=$?
assert_rc_nonzero "$RC" "AC4a sem pool → rc!=0"
assert_contains "$OUT" "sempool" "AC4a erro cita o repo inferido"
assert_contains "$OUT" "$BASE" "AC4a erro cita o caminho do pool"
[ -s "$CALL_LOG" ] && _fail "AC4a NÃO deve chamar checkout-sync-all sem pool" || _pass
rm -rf "$TMP" "$WORK"

# ═══════════════════════════════════════════════════════════════════════════
# AC4b: cwd fora de git → mantém o erro atual ("cwd não está em ...")
# (esse texto é grepado por force-merge.sh:97 para pular o sync graciosamente)
# ═══════════════════════════════════════════════════════════════════════════
TMP=$(mktemp -d); BASE="$TMP/checkouts"; CALL_LOG="$TMP/calls.log"; STUB="$TMP/sync-all-stub.sh"
mkdir -p "$BASE"; : > "$CALL_LOG"; make_stub "$STUB"
NONGIT=$(mktemp -d)                 # mktemp -d no macOS não está sob repo git
OUT=$(run_sync "$NONGIT"); RC=$?
assert_rc_nonzero "$RC" "AC4b fora de git → rc!=0"
assert_contains "$OUT" "cwd não está em" "AC4b mantém o erro canônico (compat force-merge)"
[ -s "$CALL_LOG" ] && _fail "AC4b NÃO deve chamar checkout-sync-all fora de git" || _pass
rm -rf "$TMP" "$NONGIT"

# ═══════════════════════════════════════════════════════════════════════════
# AC4c: cwd DENTRO do pool → comportamento idêntico ao de hoje (caminho feliz)
# ═══════════════════════════════════════════════════════════════════════════
TMP=$(mktemp -d); BASE="$TMP/checkouts"; CALL_LOG="$TMP/calls.log"; STUB="$TMP/sync-all-stub.sh"
mkdir -p "$BASE/myrepo-2"; : > "$CALL_LOG"; make_stub "$STUB"
OUT=$(run_sync "$BASE/myrepo-2"); RC=$?
assert_rc "$RC" 0 "AC4c dentro do pool → rc=0"
assert_contains "$(cat "$CALL_LOG")" "myrepo" "AC4c chama com o repo derivado do path"
rm -rf "$TMP"

# ═══════════════════════════════════════════════════════════════════════════
# Bônus: repo explícito como arg passa direto (caminho feliz inalterado)
# ═══════════════════════════════════════════════════════════════════════════
TMP=$(mktemp -d); BASE="$TMP/checkouts"; CALL_LOG="$TMP/calls.log"; STUB="$TMP/sync-all-stub.sh"
mkdir -p "$BASE"; : > "$CALL_LOG"; make_stub "$STUB"
NONGIT=$(mktemp -d)
OUT=$(run_sync "$NONGIT" explicito); RC=$?
assert_rc "$RC" 0 "Bônus repo explícito fora do pool → rc=0"
assert_contains "$(cat "$CALL_LOG")" "explicito" "Bônus passa o repo explícito sem inferir"
rm -rf "$TMP" "$NONGIT"

# ─── Report ────────────────────────────────────────────────────────────────
echo ""
echo "─────────────────────────────────────────"
echo "test_sync_pool.sh: PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then printf '%s\n' "$FAILED"; exit 1; fi
echo "  ✓ all assertions green"
exit 0

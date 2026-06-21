#!/usr/bin/env bash
set -u

# test_claude_yolo.sh — atalho YOLO + symlink no install (US-01).
#
# Cobre os acceptance criteria automatizáveis da story:
#   AC1 — bin/claude-yolo: argv repassado ao binário resolvido é EXATAMENTE
#         `--dangerously-skip-permissions <args extras>` na ordem. Com CY_CLAUDE
#         aponta pro stub; sem CY_CLAUDE e sem `claude` no PATH restrito, resolve
#         o fallback $HOME/.local/bin/claude (cat-9 b8).
#   AC2 — sync.sh install (sandbox via SYNC_CLAUDE_HOME + SYNC_LOCAL_BIN): cria
#         symlink claude-yolo → $CLAUDE_DIR/bin/claude-yolo; 2ª execução não erra
#         (ln -sf idempotente).
#   AC3 — commands/commit-push-pr-push.md existe, frontmatter com 'alias' +
#         allowed-tools não-wildcard + argument-hint; corpo invoca
#         bin/commit-push-pr.sh com $ARGUMENTS.
#   AC4 — CLAUDE.md (raiz) tem o bullet ❌ ssh interativo no Princípio 9 citando
#         a origem (análise de logs 2026-06-09).
#   AC5 — bash -n limpo + chmod +x no bin/claude-yolo.
#
# Estratégia: stubs com call-log (argv uma linha por arg). Sem claude/ssh reais.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
YOLO="$REPO_ROOT/bin/claude-yolo"
SYNC="$REPO_ROOT/sync.sh"
CMD_MD="$REPO_ROOT/commands/commit-push-pr-push.md"
CLAUDE_MD="$REPO_ROOT/CLAUDE.global.md"   # conteúdo dos Princípios (fonte global)

PASS=0; FAIL=0; FAILED=""
_fail() { FAIL=$((FAIL+1)); FAILED="${FAILED}
  ✗ $1"; }
_pass() { PASS=$((PASS+1)); }

assert_rc()   { [ "$1" = "$2" ] && _pass || _fail "$3 :: expected rc=$2 got rc=$1"; }
assert_grep() { grep -qiF -- "$2" "$1" && _pass || _fail "$3 :: texto '$2' ausente em $1"; }
# assert_argv_exact <logfile> <label> <arg...> — argv capturado (uma linha por
# arg, na ordem) deve ser EXATAMENTE a sequência passada. Fecha o falso-positivo
# de "mesmos tokens reordenados".
assert_argv_exact() {
  local log="$1" label="$2"; shift 2
  printf '%s\n' "$@" > "$TMP/expected-argv.txt"
  if diff -q "$TMP/expected-argv.txt" "$log" >/dev/null 2>&1; then _pass; else _fail "$label :: argv != esperado:
--- esperado
$(cat "$TMP/expected-argv.txt")
--- obtido
$(cat "$log" 2>/dev/null)"; fi
}

[[ -f "$YOLO" ]] || { echo "FAIL: $YOLO inexistente" >&2; exit 1; }
[[ -f "$SYNC" ]] || { echo "FAIL: $SYNC inexistente" >&2; exit 1; }

TMP="$(mktemp -d -t claude-yolo.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

YOLO_LOG="$TMP/argv.log"
STUB="$TMP/claude-stub.sh"
cat > "$STUB" <<'EOF'
#!/bin/bash
: > "$YOLO_LOG"
for a in "$@"; do printf '%s\n' "$a" >> "$YOLO_LOG"; done
exit 0
EOF
chmod +x "$STUB"

# ── AC1a: CY_CLAUDE → argv exato (flag prefixada + extras na ordem) ───────────
rm -f "$YOLO_LOG"
CY_CLAUDE="$STUB" YOLO_LOG="$YOLO_LOG" bash "$YOLO" --model opus -p "hi" >/dev/null 2>&1
assert_rc "$?" 0 "AC1a claude-yolo rc=0 com CY_CLAUDE"
assert_argv_exact "$YOLO_LOG" "AC1a argv exato (flag + extras na ordem)" \
  "--dangerously-skip-permissions" "--model" "opus" "-p" "hi"

# ── AC1b: sem extras → só a flag ──────────────────────────────────────────────
rm -f "$YOLO_LOG"
CY_CLAUDE="$STUB" YOLO_LOG="$YOLO_LOG" bash "$YOLO" >/dev/null 2>&1
assert_argv_exact "$YOLO_LOG" "AC1b argv sem extras = só a flag" \
  "--dangerously-skip-permissions"

# ── AC1c: fallback $HOME/.local/bin/claude (sem CY_CLAUDE, sem claude no PATH) ─
FAKE_HOME="$TMP/home"
mkdir -p "$FAKE_HOME/.local/bin"
cp "$STUB" "$FAKE_HOME/.local/bin/claude"
chmod +x "$FAKE_HOME/.local/bin/claude"
rm -f "$YOLO_LOG"
# PATH restrito a /usr/bin:/bin → `command -v claude` não acha; fallback do home.
env -i HOME="$FAKE_HOME" PATH="/usr/bin:/bin" YOLO_LOG="$YOLO_LOG" \
  bash "$YOLO" --foo bar >/dev/null 2>&1
assert_rc "$?" 0 "AC1c fallback rc=0"
assert_argv_exact "$YOLO_LOG" "AC1c fallback resolve \$HOME/.local/bin/claude" \
  "--dangerously-skip-permissions" "--foo" "bar"

# ── AC2: symlink no install (sandbox) ─────────────────────────────────────────
# Repo temp mínimo: só sync.sh + bin/claude-yolo (DIRS/FILES ausentes são
# pulados pelo install). SYNC_CLAUDE_HOME = ~/.claude sandbox; SYNC_LOCAL_BIN =
# destino do symlink sandbox.
REPO2="$TMP/repo"
mkdir -p "$REPO2/bin"
cp "$SYNC" "$REPO2/sync.sh"
cp "$YOLO" "$REPO2/bin/claude-yolo"
chmod +x "$REPO2/sync.sh" "$REPO2/bin/claude-yolo"

CHOME="$TMP/claude-home"
LBIN="$TMP/localbin"
mkdir -p "$CHOME"

SYNC_CLAUDE_HOME="$CHOME" SYNC_LOCAL_BIN="$LBIN" bash "$REPO2/sync.sh" install >/dev/null 2>&1
assert_rc "$?" 0 "AC2a 1ª install rc=0"
LINK="$LBIN/claude-yolo"
if [ -L "$LINK" ]; then _pass; else _fail "AC2b symlink $LINK não criado"; fi
TARGET="$(readlink "$LINK" 2>/dev/null || true)"
[ "$TARGET" = "$CHOME/bin/claude-yolo" ] && _pass || _fail "AC2c symlink aponta errado: '$TARGET' (esperado '$CHOME/bin/claude-yolo')"

# 2ª execução: idempotente, sem erro
SYNC_CLAUDE_HOME="$CHOME" SYNC_LOCAL_BIN="$LBIN" bash "$REPO2/sync.sh" install >/dev/null 2>&1
assert_rc "$?" 0 "AC2d 2ª install rc=0 (idempotente)"
[ -L "$LINK" ] && _pass || _fail "AC2e symlink ainda existe após 2ª install"

# ── AC3: commands/commit-push-pr-push.md ──────────────────────────────────────
if [ -f "$CMD_MD" ]; then _pass; else _fail "AC3a $CMD_MD inexistente"; fi
if [ -f "$CMD_MD" ]; then
  assert_grep "$CMD_MD" "alias"                "AC3b description marca 'alias'"
  assert_grep "$CMD_MD" "argument-hint"        "AC3c tem argument-hint"
  assert_grep "$CMD_MD" "bin/commit-push-pr.sh" "AC3d corpo invoca bin/commit-push-pr.sh"
  assert_grep "$CMD_MD" "ARGUMENTS"            "AC3e corpo cita \$ARGUMENTS"
  # allowed-tools NÃO-wildcard: deve ser idêntico ao do commit-push-pr.md.
  AT_REF="$(grep -m1 '^allowed-tools:' "$REPO_ROOT/commands/commit-push-pr.md")"
  AT_NEW="$(grep -m1 '^allowed-tools:' "$CMD_MD")"
  [ -n "$AT_NEW" ] && [ "$AT_NEW" = "$AT_REF" ] && _pass || _fail "AC3f allowed-tools != commit-push-pr.md:
  ref: $AT_REF
  new: $AT_NEW"
  case "$AT_NEW" in *'(*)'*) _fail "AC3g allowed-tools não pode ser wildcard '(*)'";; *) _pass;; esac
fi

# ── AC4: bullet ssh interativo no Princípio 9 da CLAUDE.md ─────────────────────
assert_grep "$CLAUDE_MD" "ssh -t" "AC4a CLAUDE.md cita ssh -t interativo"
assert_grep "$CLAUDE_MD" "2026-06-09" "AC4b CLAUDE.md cita a origem (logs 2026-06-09)"

# ── AC5: bash -n + executável ─────────────────────────────────────────────────
if bash -n "$YOLO" 2>/dev/null; then _pass; else _fail "AC5a bash -n falhou em $YOLO"; fi
[ -x "$YOLO" ] && _pass || _fail "AC5b $YOLO não é executável (chmod +x)"

# ── Resultado ─────────────────────────────────────────────────────────────────
echo "test_claude_yolo.sh: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  echo "FALHAS:$FAILED" >&2
  exit 1
fi

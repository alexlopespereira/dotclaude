#!/usr/bin/env bash
# test_block_dangerous_git.sh — fail-closed hardening do hook PreToolUse de
# secret-scan (US-02). TDD: escrito ANTES do hardening (red-green no mesmo
# commit, documentado na mensagem do commit).
#
# Contrato PreToolUse (ressalva R3): exit 1 NÃO bloqueia — só exit 2. Um erro
# interno (dep ausente, parse falho) precisa virar exit 2, nunca exit 1/0.
#
# Cobre:
#   AC2 — jq ausente (seam BDG_JQ → path inexistente) → exit 2 + stderr cita 'jq'.
#   AC3 — secret Stripe sk_live_ no staged diff → exit 2; commit limpo → exit 0;
#         arquivo .env staged → exit 2.
#   AC4 — hook tem set -u e trap ERR que converte erro interno em exit 2.
#   AC5 — hooks Stop/SessionStart NÃO têm trap bloqueante (grep prova ausência).
#
# Estratégia: invoca o hook real com payload via stdin (formato PreToolUse) e,
# para os cenários de secret/.env/limpo, roda dentro de um repo git temporário
# cujo índice (staged diff) o hook inspeciona.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HOOK="$REPO_ROOT/hooks/block-dangerous-git.sh"

PASS=0; FAIL=0; FAILED=""
_pass() { PASS=$((PASS+1)); }
_fail() { FAIL=$((FAIL+1)); FAILED="${FAILED}
  ✗ $1"; }
assert_rc() { [ "$1" = "$2" ] && _pass || _fail "$3 :: expected rc=$2 got rc=$1"; }
assert_contains() { case "$1" in *"$2"*) _pass;; *) _fail "$3 :: '$2' ausente em: $1";; esac; }

[ -f "$HOOK" ] || { echo "FAIL: $HOOK inexistente" >&2; exit 1; }

payload() { printf '{"tool_name":"Bash","tool_input":{"command":"%s"}}' "$1"; }

mk_repo() { # cria repo git temp isolado e ecoa o caminho
  local d; d=$(mktemp -d)
  git -C "$d" init -q
  git -C "$d" config user.email t@t.t
  git -C "$d" config user.name t
  printf '%s' "$d"
}

# Fixture montada por concatenação para o literal NÃO casar o regex de secret
# no diff DESTE arquivo (senão o próprio hook bloquearia o commit do teste).
# Em runtime vira a string contígua que o hook-sob-teste deve detectar.
SECRET="token=sk_""live_0123456789abcdefABCDEF"

# AC2 — jq ausente → exit 2 + stderr aciona 'jq'
err=$(payload "git commit -m x" | BDG_JQ=/nonexistent/jq bash "$HOOK" 2>&1 1>/dev/null); rc=$?
assert_rc "$rc" "2" "AC2 jq ausente bloqueia (fail-closed)"
assert_contains "$err" "jq" "AC2 stderr cita a dependência jq"

# AC3 — secret Stripe staged → exit 2
repo=$(mk_repo)
printf '%s\n' "$SECRET" > "$repo/config.txt"
git -C "$repo" add config.txt
( cd "$repo" && payload "git commit -m add" | bash "$HOOK" 2>/dev/null ); rc=$?
assert_rc "$rc" "2" "AC3 secret Stripe staged bloqueia"
rm -rf "$repo"

# AC3 — commit limpo → exit 0
repo=$(mk_repo)
printf 'hello world\n' > "$repo/readme.txt"
git -C "$repo" add readme.txt
( cd "$repo" && payload "git commit -m clean" | bash "$HOOK" 2>/dev/null ); rc=$?
assert_rc "$rc" "0" "AC3 commit limpo libera (exit 0)"
rm -rf "$repo"

# AC3 — arquivo .env staged → exit 2
repo=$(mk_repo)
printf 'X=1\n' > "$repo/.env"
git -C "$repo" add -f .env
( cd "$repo" && payload "git commit -m env" | bash "$HOOK" 2>/dev/null ); rc=$?
assert_rc "$rc" "2" "AC3 arquivo .env staged bloqueia"
rm -rf "$repo"

# comando não-git (mesmo com secret staged) não é interceptado → exit 0
repo=$(mk_repo)
printf '%s\n' "$SECRET" > "$repo/c.txt"
git -C "$repo" add c.txt
( cd "$repo" && payload "ls -la" | bash "$HOOK" 2>/dev/null ); rc=$?
assert_rc "$rc" "0" "comando não-git não intercepta"
rm -rf "$repo"

# P0 code-review (Fase 5.5): trap ERR não herda em command substitution
# (sem set -E) e `|| true` mascarava falha de git diff → scan pulado + exit 0.
# Fail-closed exige rc explícito: git diff falhou DENTRO de repo → exit 2.
# Seam BDG_GIT (mesmo pattern do BDG_JQ): stub finge rev-parse ok / diff falha.
stub=$(mktemp -d)
cat > "$stub/git" <<'EOF'
#!/bin/bash
case "$1" in
  rev-parse) exit 0;;
  diff) echo "fatal: index.lock exists" >&2; exit 128;;
  *) exit 0;;
esac
EOF
chmod +x "$stub/git"
d=$(mktemp -d)
err=$(cd "$d" && payload "git commit -m x" | BDG_GIT="$stub/git" bash "$HOOK" 2>&1 1>/dev/null); rc=$?
assert_rc "$rc" "2" "P0 git diff falha dentro de repo → exit 2 (fail-closed)"
assert_contains "$err" "diff" "P0 stderr explica a falha do diff"
rm -rf "$stub" "$d"

# cwd fora de repo git → exit 0 (allow documentado: nada a escanear; o próprio
# git falhará o comando do usuário com 'not a git repository')
d=$(mktemp -d)
( cd "$d" && payload "git commit -m x" | bash "$HOOK" 2>/dev/null ); rc=$?
assert_rc "$rc" "0" "cwd não-git libera (git falhará o comando sozinho)"
rm -rf "$d"

# AC4 — set -u e trap ERR→exit 2 no source do hook
src=$(cat "$HOOK")
assert_contains "$src" "set -u" "AC4 set -u presente no hook"
case "$src" in *trap*ERR*) _pass;; *) _fail "AC4 trap ERR ausente no hook";; esac
case "$src" in *"exit 2"*) _pass;; *) _fail "AC4 hook bloqueia com exit 2";; esac

# AC5 — hooks Stop/SessionStart NÃO têm trap bloqueante (exit 2 dentro de trap)
for h in sync-telemetry-log session-start-sync dod-usage-log adr-materialize-warn stop-notify handoff-resume; do
  f="$REPO_ROOT/hooks/$h.sh"
  if [ ! -f "$f" ]; then _fail "AC5 $h.sh inexistente"; continue; fi
  if grep -nE "trap .*exit[[:space:]]+2" "$f" >/dev/null 2>&1; then
    _fail "AC5 $h.sh tem trap bloqueante (exit 2) — deve ser best-effort"
  else
    _pass
  fi
done

echo "test_block_dangerous_git.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -gt 0 ] && { echo "FALHAS:$FAILED" >&2; exit 1; }
exit 0

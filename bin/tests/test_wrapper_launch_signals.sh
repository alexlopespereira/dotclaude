#!/usr/bin/env bash
set -u

# test_wrapper_launch_signals.sh — testes de sinal/cleanup pro wrapper-launch.sh
# (skills/browser-actions).
#
# Origem: investigação 2026-07-12 do vazamento de processos Playwright. 234 perfis
# efêmeros órfãos em ~/.claude/ e um /var/log/syslog.1 de 9,2G (gvfsd em loop de
# "Too many open files") tinham a mesma causa raiz.
#
# Mecanismo (provado empiricamente antes deste teste existir):
#   1. o wrapper rodava `npx @playwright/mcp` em FOREGROUND;
#   2. bash ADIA a execução de trap enquanto um comando foreground não retorna;
#   3. supervisor manda SIGTERM no PID do wrapper -> bash marca pendente e segue
#      esperando o npx, que NÃO recebeu o sinal (kill dirigido não atinge o grupo);
#   4. supervisor escala pra SIGKILL -> bash morre, trap NUNCA roda;
#   5. perfil efêmero vaza em disco e npx/node/chrome são reparentados ao init,
#      seguem vivos e seguram conexões gvfs até estourar o limite de 1024 FDs.
#
# Invariantes cobertas:
#   T1 — SIGTERM no wrapper encerra o wrapper (não pode ser ignorado).
#   T2 — SIGTERM remove o perfil efêmero (trap roda de fato).
#   T3 — SIGTERM não deixa descendente vivo (npx/node/chrome).
#   T4 — GC de startup remove perfis efêmeros de PID morto (defesa contra SIGKILL,
#        que é inmascarável — sem GC, todo SIGKILL vira lixo permanente).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/../.." && pwd)"
WRAPPER="$REPO/skills/browser-actions/wrapper-launch.sh"

PASS=0; FAIL=0; FAILED=""
_fail() { FAIL=$((FAIL+1)); FAILED="${FAILED}
  ✗ $1"; }
_pass() { PASS=$((PASS+1)); }
assert_eq() { [ "$1" = "$2" ] && _pass || _fail "$3 :: esperado '$2', obtido '$1'"; }

SLOT="sigtest$$"
BASE="$HOME/.claude/chrome-profile-${SLOT}"
TMP="$(mktemp -d)"

cleanup_all() {
  for p in $(ps -eo pid,args | grep "[c]hrome-profile-${SLOT}" | awk '{print $1}'); do
    kill -9 "$p" 2>/dev/null || true
  done
  rm -rf "${BASE}"* "$TMP" 2>/dev/null || true
}
trap cleanup_all EXIT

# Sobe o wrapper no caminho EFÊMERO: ocupa o lock do slot base com um PID vivo,
# forçando a 2ª sessão para chrome-profile-<slot>-pid<PID>. stdin fica aberto
# (fifo) senão o MCP recebe EOF e sai sozinho, mascarando o teste.
start_ephemeral_wrapper() {
  mkdir -p "$BASE/.lock"; echo $$ > "$BASE/.lock/pid"
  mkfifo -m 600 "$TMP/in" 2>/dev/null || true
  sleep 120 > "$TMP/in" &
  KEEPER=$!
  CLAUDE_SLOT_NAME="$SLOT" DISPLAY= setsid bash "$WRAPPER" <"$TMP/in" >"$TMP/out" 2>&1 &
  # $! é o setsid; o wrapper real é o bash que segura o perfil efêmero.
  for _ in $(seq 1 40); do
    W=$(ps -eo pid,args | grep "[w]rapper-launch.sh" | awk '{print $1}' | while read -r p; do
          tr '\0' ' ' < "/proc/$p/environ" 2>/dev/null | grep -q "CLAUDE_SLOT_NAME=$SLOT" && echo "$p"
        done | head -1)
    [ -n "${W:-}" ] && [ -d "${BASE}-pid${W}" ] && break
    sleep 0.5
  done
  echo "${W:-}"
}

W="$(start_ephemeral_wrapper)"
if [ -z "$W" ]; then
  echo "SETUP FALHOU: wrapper efêmero não subiu" >&2
  exit 1
fi
EPH="${BASE}-pid${W}"
DESC_BEFORE=$(pgrep -P "$W" | wc -l)

kill -TERM "$W" 2>/dev/null
for _ in $(seq 1 20); do kill -0 "$W" 2>/dev/null || break; sleep 0.5; done

# T1 — o wrapper morre com SIGTERM (antes: ficava vivo, forçando SIGKILL).
kill -0 "$W" 2>/dev/null && alive=SIM || alive=NAO
assert_eq "$alive" "NAO" "T1 SIGTERM encerra o wrapper"

# T2 — trap rodou e removeu o perfil efêmero.
[ -d "$EPH" ] && leaked=SIM || leaked=NAO
assert_eq "$leaked" "NAO" "T2 SIGTERM remove o perfil efêmero"

# T3 — nenhum descendente (npx/node/chrome) sobrevive ao wrapper.
sleep 1
surv=$(ps -eo args | grep -c "[c]hrome-profile-${SLOT}-pid${W}")
assert_eq "$surv" "0" "T3 SIGTERM não deixa descendente vivo (antes: $DESC_BEFORE filhos viravam órfãos)"

# T4 — GC de startup limpa perfil efêmero de PID morto (cenário SIGKILL).
DEAD_PID=999999
kill -0 "$DEAD_PID" 2>/dev/null && DEAD_PID=999998
STALE="${BASE}-pid${DEAD_PID}"
mkdir -p "$STALE/.lock"; echo "$DEAD_PID" > "$STALE/.lock/pid"
CLAUDE_SLOT_NAME="$SLOT" DISPLAY= WRAPPER_GC_ONLY=1 bash "$WRAPPER" </dev/null >/dev/null 2>&1
[ -d "$STALE" ] && stale=SIM || stale=NAO
assert_eq "$stale" "NAO" "T4 GC de startup remove perfil efêmero de PID morto"

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || { echo "FALHAS:$FAILED"; exit 1; }

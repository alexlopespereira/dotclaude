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
# Hermético e portável (reescrito no ciclo /diagnose 2026-07-12 pós-#115):
#   - `npx` é STUB (fake MCP: spawna um filho pra simular o chrome e dorme).
#     Os invariantes são sobre a mecânica de sinais do WRAPPER, não sobre o MCP
#     real — o stub torna a suíte determinística (sem rede/registry, sem depender
#     de npx instalado; na VM1 via ssh o npx nem está no PATH) e rodável no macOS.
#   - Sem setsid/procfs NO TESTE: o wrapper sobe como job de background e $! é o
#     PID dele. A versão anterior usava `setsid` + varredura de /proc/*/environ,
#     ambos inexistentes no macOS — era o "SETUP FALHOU" de lá.
#   - HOME apontado pra sandbox: perfis/locks isolados do ~/.claude real.
#
# Invariantes cobertas:
#   T1 — SIGTERM no wrapper encerra o wrapper (não pode ser ignorado).
#   T2 — SIGTERM remove o perfil efêmero (trap roda de fato).
#   T3 — SIGTERM não deixa descendente vivo (stub npx + filho dele).
#   T4 — GC de startup remove perfis efêmeros de PID morto (defesa contra SIGKILL,
#        que é inmascarável — sem GC, todo SIGKILL vira lixo permanente).
#   T5 — TERM extra DURANTE o cleanup não aborta a remoção. Regressão do vazamento
#        visto na VM1 (2026-07-12): um TERM que chegava com o cleanup em andamento
#        disparava on_signal, que via CLEANED=1 retornava e dava exit 143 ANTES
#        dos rm — perfil vazava com .lock/pid intacto.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/../.." && pwd)"
WRAPPER="$REPO/skills/browser-actions/wrapper-launch.sh"

PASS=0; FAIL=0; FAILED=""
_fail() { FAIL=$((FAIL+1)); FAILED="${FAILED}
  ✗ $1"; }
_pass() { PASS=$((PASS+1)); }
assert_eq() { [ "$1" = "$2" ] && _pass || _fail "$3 :: esperado '$2', obtido '$1'"; }

SLOT="sigtest$$"
TMP="$(mktemp -d -t wrap-sig.XXXXXX)"
HOME_DIR="$TMP/home"
STUB_DIR="$TMP/bin"
BASE="$HOME_DIR/.claude/chrome-profile-${SLOT}"
PIDS_LOG="$TMP/stub-pids.log"
mkdir -p "$HOME_DIR" "$STUB_DIR"

cleanup_all() {
  if [ -s "$PIDS_LOG" ]; then
    while read -r p; do kill -9 "$p" 2>/dev/null || true; done < "$PIDS_LOG"
  fi
  rm -rf "$TMP" 2>/dev/null || true
}
trap cleanup_all EXIT

# Stub npx = fake MCP. Registra o próprio PID e o de um filho (simula o chrome)
# em PIDS_LOG pro T3 checar sobreviventes, e dorme segurando o argv original
# (sem exec — o --user-data-dir precisa continuar visível no ps). Morre com o
# TERM default, como o MCP real.
cat > "$STUB_DIR/npx" <<'EOF'
#!/bin/bash
echo $$ >> "$PIDS_LOG"
sleep 300 &
echo $! >> "$PIDS_LOG"
wait
EOF
chmod +x "$STUB_DIR/npx"

# start_ephemeral_wrapper — sobe o wrapper no caminho EFÊMERO: ocupa o lock do
# slot base com um PID vivo (o do teste), forçando a sessão pra
# chrome-profile-<slot>-pid<PID>. Ecoa o PID do wrapper; W_EPH fica no dir.
start_ephemeral_wrapper() {
  : > "$PIDS_LOG"
  mkdir -p "$BASE/.lock"; echo $$ > "$BASE/.lock/pid"
  HOME="$HOME_DIR" PATH="$STUB_DIR:$PATH" PIDS_LOG="$PIDS_LOG" \
    CLAUDE_SLOT_NAME="$SLOT" DISPLAY= \
    bash "$WRAPPER" </dev/null >"$TMP/out" 2>&1 &
  local w=$!
  for _ in $(seq 1 40); do
    [ -d "${BASE}-pid${w}" ] && [ -s "$PIDS_LOG" ] && break
    sleep 0.25
  done
  echo "$w"
}

W="$(start_ephemeral_wrapper)"
EPH="${BASE}-pid${W}"
if [ ! -d "$EPH" ] || [ ! -s "$PIDS_LOG" ]; then
  echo "SETUP FALHOU: wrapper efêmero não subiu (out: $(cat "$TMP/out" 2>/dev/null))" >&2
  exit 1
fi
DESC_BEFORE=$(wc -l < "$PIDS_LOG" | tr -d ' ')

kill -TERM "$W" 2>/dev/null
for _ in $(seq 1 20); do kill -0 "$W" 2>/dev/null || break; sleep 0.5; done

# T1 — o wrapper morre com SIGTERM (antes: ficava vivo, forçando SIGKILL).
kill -0 "$W" 2>/dev/null && alive=SIM || alive=NAO
assert_eq "$alive" "NAO" "T1 SIGTERM encerra o wrapper"

# T2 — trap rodou e removeu o perfil efêmero.
[ -d "$EPH" ] && leaked=SIM || leaked=NAO
assert_eq "$leaked" "NAO" "T2 SIGTERM remove o perfil efêmero"

# T3 — nenhum descendente (stub npx nem o filho dele) sobrevive ao wrapper.
sleep 1
surv=0
while read -r p; do kill -0 "$p" 2>/dev/null && surv=$((surv+1)); done < "$PIDS_LOG"
assert_eq "$surv" "0" "T3 SIGTERM não deixa descendente vivo (de $DESC_BEFORE registrados)"

# T4 — GC de startup limpa perfil efêmero de PID morto (cenário SIGKILL).
DEAD_PID=999999
kill -0 "$DEAD_PID" 2>/dev/null && DEAD_PID=999998
STALE="${BASE}-pid${DEAD_PID}"
mkdir -p "$STALE/.lock"; echo "$DEAD_PID" > "$STALE/.lock/pid"
HOME="$HOME_DIR" CLAUDE_SLOT_NAME="$SLOT" DISPLAY= WRAPPER_GC_ONLY=1 \
  bash "$WRAPPER" </dev/null >/dev/null 2>&1
[ -d "$STALE" ] && stale=SIM || stale=NAO
assert_eq "$stale" "NAO" "T4 GC de startup remove perfil efêmero de PID morto"

# T5 — segundo TERM no meio do cleanup não pode abortar a remoção do perfil.
# O stub segura o TERM por 2s (simula MCP/chrome desligando devagar) pra garantir
# que o cleanup do wrapper esteja EM ANDAMENTO quando o 2º TERM chega — a janela
# que vazava na VM1.
cat > "$STUB_DIR/npx" <<'EOF'
#!/bin/bash
echo $$ >> "$PIDS_LOG"
trap 'sleep 2; exit 143' TERM
sleep 300 &
echo $! >> "$PIDS_LOG"
while :; do wait && break; done
EOF
W2="$(start_ephemeral_wrapper)"
EPH2="${BASE}-pid${W2}"
if [ ! -d "$EPH2" ] || [ ! -s "$PIDS_LOG" ]; then
  echo "SETUP T5 FALHOU: wrapper efêmero não subiu (out: $(cat "$TMP/out" 2>/dev/null))" >&2
  exit 1
fi
kill -TERM "$W2" 2>/dev/null
sleep 0.6                       # cleanup já começou (stub segurando o TERM)
kill -TERM "$W2" 2>/dev/null    # o sinal que abortava o cleanup
for _ in $(seq 1 30); do kill -0 "$W2" 2>/dev/null || break; sleep 0.5; done
kill -0 "$W2" 2>/dev/null && alive2=SIM || alive2=NAO
[ -d "$EPH2" ] && leaked2=SIM || leaked2=NAO
assert_eq "$alive2" "NAO" "T5a wrapper encerra mesmo com TERM duplo"
assert_eq "$leaked2" "NAO" "T5b TERM durante o cleanup não aborta a remoção do perfil"
while read -r p; do kill -9 "$p" 2>/dev/null || true; done < "$PIDS_LOG"

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || { echo "FALHAS:$FAILED"; exit 1; }

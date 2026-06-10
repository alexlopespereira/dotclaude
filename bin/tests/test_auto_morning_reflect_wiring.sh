#!/usr/bin/env bash
# test_auto_morning_reflect_wiring.sh — testes para o wiring de US-02 em
# bin/auto-morning.sh (invocação non-blocking de reflect-retro-due.sh).
#
# Cobre os acceptance criteria automatizáveis (AC2 é CAT3-MANUAL, fora daqui):
#   AC1 — auto-morning.sh chama reflect-retro-due.sh APÓS o vm-morning, com
#         `|| true` (non-blocking): um stub de reflect que faz `exit 1` NÃO
#         altera o exit code (0) do auto-morning. Ordem (vm-morning antes de
#         reflect) provada por timestamps no call-log.
#   AC3 — o log da execução do reflect aparece em $AM_LOG quando invocado via
#         auto-morning.sh, com o vm-morning STUBADO (sem abrir abas reais).
#
# Estratégia: seams de env (AM_LOG/AM_VM_MORNING/AM_REFLECT_RETRO/AM_SKIP_WAIT)
# apontam para stubs que logam num call-log compartilhado. Pattern de
# test_reflect_retro_due.sh / test_vm_provision.sh.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
AM="$REPO_ROOT/bin/auto-morning.sh"

PASS=0; FAIL=0; FAILED=""
_pass() { PASS=$((PASS+1)); }
_fail() { FAIL=$((FAIL+1)); FAILED="${FAILED}
  ✗ $1"; }
assert_eq()   { [ "$1" = "$2" ] && _pass || _fail "$3 :: expected '$2' got '$1'"; }
assert_grep() { printf '%s' "$1" | grep -qE -- "$2" && _pass || _fail "$3 :: padrão '$2' ausente em: $1"; }
assert_rc()   { [ "$1" = "$2" ] && _pass || _fail "$3 :: expected rc=$2 got rc=$1"; }
assert_lt()   { { [ -n "$1" ] && [ -n "$2" ] && [ "$1" -lt "$2" ]; } && _pass || _fail "$3 :: esperado $1 < $2"; }

[ -f "$AM" ] || { echo "FAIL: $AM inexistente" >&2; exit 1; }
bash -n "$AM" || { echo "FAIL: bash -n sujo em $AM" >&2; exit 1; }

TMP="$(mktemp -d -t am.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

CALLLOG="$TMP/calls.log"

# vm-morning stub: loga (com índice de chamada) que rodou e o pid relativo.
VM_STUB="$TMP/vm-morning.sh"
cat > "$VM_STUB" <<EOF
#!/usr/bin/env bash
printf '%s VM_MORNING_RAN\n' "\$(date +%s%N)" >> "$CALLLOG"
exit 0
EOF
chmod +x "$VM_STUB"

# reflect stub OK: loga argv e sai 0.
REFLECT_OK="$TMP/reflect-ok.sh"
cat > "$REFLECT_OK" <<EOF
#!/usr/bin/env bash
printf '%s REFLECT_RAN %s\n' "\$(date +%s%N)" "\$*" >> "$CALLLOG"
exit 0
EOF
chmod +x "$REFLECT_OK"

# reflect stub FAIL: loga e sai 1 (prova non-blocking).
REFLECT_FAIL="$TMP/reflect-fail.sh"
cat > "$REFLECT_FAIL" <<EOF
#!/usr/bin/env bash
printf '%s REFLECT_RAN_FAIL %s\n' "\$(date +%s%N)" "\$*" >> "$CALLLOG"
exit 1
EOF
chmod +x "$REFLECT_FAIL"

# backlog-dispatch stub: no-op para isolar o wiring do reflect (US-07 adicionou
# uma 2ª chamada non-blocking ao auto-morning; sem stub ela rodaria o dispatcher
# real contra o ambiente do laptop).
BACKLOG_STUB="$TMP/backlog-dispatch.sh"
cat > "$BACKLOG_STUB" <<EOF
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$BACKLOG_STUB"

run_am() { # reflect_stub ; ecoa nada, só roda o wrapper
  : > "$CALLLOG"
  AM_SKIP_WAIT=1 \
  AM_LOG="$TMP/auto-morning.log" \
  AM_VM_MORNING="$VM_STUB" \
  AM_REFLECT_RETRO="$1" \
  AM_BACKLOG_DISPATCH="$BACKLOG_STUB" \
    bash "$AM"
}

# ── AC1 + AC3: reflect OK roda APÓS vm-morning; exit 0; log no AM_LOG ─────────
run_am "$REFLECT_OK"; rc=$?
LOG_OUT="$(cat "$TMP/auto-morning.log")"

assert_rc "$rc" 0 "AC1: auto-morning exit 0 quando reflect sai 0"
assert_grep "$LOG_OUT" "VM_MORNING|vm-morning|executando" "AC3: vm-morning aparece no log"
assert_grep "$LOG_OUT" "drenando retros vencidas" "AC3: anúncio do reflect aparece no log"
assert_grep "$LOG_OUT" "--max 2" "AC1: reflect chamado com --max 2 (visível no log)"

# Ordem: VM_MORNING_RAN antes de REFLECT_RAN no call-log (timestamps ns).
VM_TS="$(grep 'VM_MORNING_RAN' "$CALLLOG" | head -1 | awk '{print $1}')"
RF_TS="$(grep 'REFLECT_RAN' "$CALLLOG" | head -1 | awk '{print $1}')"
assert_lt "$VM_TS" "$RF_TS" "AC1: vm-morning roda ANTES do reflect (ordem no call-log)"

# ── AC1: reflect com exit 1 NÃO altera o exit code do auto-morning ────────────
run_am "$REFLECT_FAIL"; rc=$?
LOG_OUT="$(cat "$TMP/auto-morning.log")"

assert_rc "$rc" 0 "AC1: reflect exit 1 → auto-morning ainda sai 0 (|| true, non-blocking)"
assert_grep "$LOG_OUT" "REFLECT_RAN_FAIL|drenando retros" "AC1: reflect FAIL foi de fato invocado"
assert_grep "$LOG_OUT" "concluído" "AC1: auto-morning chega ao fim mesmo com reflect falho"

# ── AC1/robustez: reflect ausente/não-executável não derruba o auto-morning ───
run_am "$TMP/nao-existe.sh"; rc=$?
LOG_OUT="$(cat "$TMP/auto-morning.log")"
assert_rc "$rc" 0 "AC1: reflect ausente → auto-morning sai 0"
assert_grep "$LOG_OUT" "ausente/não-executável|pulado" "AC1: reflect ausente é logado e pulado"

# ── resumo ────────────────────────────────────────────────────────────────────
echo "─────────────────────────────────────────"
echo "PASS: $PASS   FAIL: $FAIL"
if [ "$FAIL" -gt 0 ]; then
  echo "Falhas:$FAILED"
  exit 1
fi
echo "OK — auto-morning reflect wiring (US-02 AC1/AC3)"

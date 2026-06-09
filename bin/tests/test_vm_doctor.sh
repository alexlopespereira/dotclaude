#!/usr/bin/env bash
# test_vm_doctor.sh — testes para bin/vm-doctor.sh (US-03).
#
# Cobre os acceptance criteria automatizáveis:
#   AC1 — parser key-based: lê campos em qualquer ordem (fixture real tem NRestarts
#         ANTES de ExecStart) e tolera chaves ausentes (.timer sem NRestarts/WD/ExecStart).
#   AC2 — telegram-bot (WD deletado) e agent-heartbeat (WD existe, ExecStart deletado,
#         failed) são ambos órfãos; o 2º prova ExecStart independente do WD.
#   AC3 — claude-code (saudável) não dispara critério; not-found / WD-vazio são pulados.
#   AC4 — agent-fornece_ai.service static (ausente de list-units) detectado via
#         list-unit-files.
#   AC5 — sem --fix nenhuma mutação ocorre; com --fix a sequência é stop→disable
#         (enabled), stop→mask (static), timer homônimo stop→disable, reset-failed ao fim.
#   AC6 — sudo -n falhando: aviso + degrade report-only + exit 0.
#   AC7 — report inclui journal disk-usage e SUGERE vacuum sem executá-lo.
#   AC8 é [CAT3-MANUAL] — validação nas VMs reais, fora deste harness.
#
# Estratégia: stub de systemctl/journalctl que lê fixtures de um diretório e
# loga toda invocação num call-log. WD/ExecStart "existentes" usam paths reais
# da máquina de teste (macOS); "deletados" usam paths garantidamente inexistentes.

# P_* / IS_ORPHAN / ORPHAN_REASON / CORROB são populados pelo vm-doctor.sh
# sourceado (parse_show/classify_unit) — shellcheck não enxerga a origem.
# shellcheck disable=SC2154
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DOCTOR="$REPO_ROOT/bin/vm-doctor.sh"

PASS=0; FAIL=0; FAILED=""
_pass() { PASS=$((PASS+1)); }
_fail() { FAIL=$((FAIL+1)); FAILED="${FAILED}
  ✗ $1"; }
assert_eq()   { [ "$1" = "$2" ] && _pass || _fail "$3 :: expected '$2' got '$1'"; }
assert_grep() { printf '%s' "$1" | grep -qE -- "$2" && _pass || _fail "$3 :: padrão '$2' ausente em: $1"; }
assert_nogrep(){ printf '%s' "$1" | grep -qE -- "$2" && _fail "$3 :: padrão '$2' NÃO deveria aparecer em: $1" || _pass; }
assert_rc()   { [ "$1" = "$2" ] && _pass || _fail "$3 :: expected rc=$2 got rc=$1"; }

[ -f "$DOCTOR" ] || { echo "FAIL: $DOCTOR inexistente" >&2; exit 1; }

TMP="$(mktemp -d -t vm-doctor.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# Paths reais (existem) vs deletados (não existem) na máquina de teste.
EXIST_DIR="$TMP"                         # diretório real
EXIST_BIN="$TMP/realbin"; : > "$EXIST_BIN"   # arquivo real
GONE_DIR="/nonexistent/vm-doctor/deleted-wd"
GONE_BIN="/nonexistent/vm-doctor/deleted-bin/foo"
GONE_BIN2="/nonexistent/vm-doctor/fornece/ai"

# ── Fixtures de `systemctl show` (user scope) ────────────────────────────────
FX="$TMP/fixtures"; mkdir -p "$FX"

# telegram-bot: WD deletado, NRestarts ANTES de ExecStart (AC1 ordem), enabled,
# activating/auto-restart, NRestarts grande.
cat > "$FX/user.show.telegram-bot.service" <<EOF
Names=telegram-bot.service
LoadState=loaded
ActiveState=activating
SubState=auto-restart
WorkingDirectory=$GONE_DIR
NRestarts=26960
ExecStart={ path=$GONE_BIN ; argv[]=$GONE_BIN bot.py ; ignore_errors=no }
UnitFileState=enabled
EOF

# agent-heartbeat.service: WD EXISTE, ExecStart deletado, failed, enabled.
cat > "$FX/user.show.agent-heartbeat.service" <<EOF
Names=agent-heartbeat.service
LoadState=loaded
ActiveState=failed
SubState=failed
WorkingDirectory=$EXIST_DIR
NRestarts=3
ExecStart={ path=$GONE_BIN ; argv[]=$GONE_BIN --beat ; ignore_errors=no }
UnitFileState=enabled
EOF

# agent-heartbeat.timer: SEM NRestarts/WD/ExecStart (AC1 chaves ausentes), enabled.
cat > "$FX/user.show.agent-heartbeat.timer" <<EOF
Names=agent-heartbeat.timer
LoadState=loaded
ActiveState=active
SubState=waiting
UnitFileState=enabled
EOF

# claude-code.service: saudável (NRestarts=0, paths existem, active/running).
cat > "$FX/user.show.claude-code.service" <<EOF
Names=claude-code.service
LoadState=loaded
ActiveState=active
SubState=running
WorkingDirectory=$EXIST_DIR
NRestarts=0
ExecStart={ path=$EXIST_BIN ; argv[]=$EXIST_BIN ; ignore_errors=no }
UnitFileState=enabled
EOF

# pulseaudio.service: fantasma not-found, WD vazio (AC3 não vira falso positivo).
cat > "$FX/user.show.pulseaudio.service" <<EOF
Names=pulseaudio.service
LoadState=not-found
ActiveState=inactive
SubState=dead
WorkingDirectory=
NRestarts=0
UnitFileState=
EOF

# pipewire.service: LOADED (não not-found) mas com WD vazio e ExecStart vazio —
# prova que o check de path é pulado por WD/ExecStart vazios, INDEPENDENTE do
# early-return de not-found (AC3 — fecha o gap do parecer: pulseaudio sozinha
# não exercita o ramo loaded+WD-vazio).
cat > "$FX/user.show.pipewire.service" <<EOF
Names=pipewire.service
LoadState=loaded
ActiveState=active
SubState=running
WorkingDirectory=
NRestarts=0
ExecStart=
UnitFileState=enabled
EOF

# spaced.service: ExecStart com ESPAÇO no path (existe!) — o parser deve cortar
# no separador ' ; ' do systemd, não no 1º espaço; truncar viraria falso órfão
# e --fix desabilitaria a unit saudável (finding confirmado no review Fase 5.5).
SPACED_BIN="$TMP/real bin"; : > "$SPACED_BIN"
cat > "$FX/user.show.spaced.service" <<EOF
Names=spaced.service
LoadState=loaded
ActiveState=active
SubState=running
WorkingDirectory=$EXIST_DIR
NRestarts=0
ExecStart={ path=$SPACED_BIN ; argv[]=$SPACED_BIN --flag ; ignore_errors=no }
UnitFileState=enabled
EOF

# agent-fornece_ai.service: static, ExecStart deletado, WD vazio — só em unit-files.
cat > "$FX/user.show.agent-fornece_ai.service" <<EOF
Names=agent-fornece_ai.service
LoadState=loaded
ActiveState=inactive
SubState=dead
WorkingDirectory=
NRestarts=0
ExecStart={ path=$GONE_BIN2 ; argv[]=$GONE_BIN2 ; ignore_errors=no }
UnitFileState=static
EOF

# list-units --all: NÃO inclui agent-fornece_ai (static não-carregada).
cat > "$FX/user.list-units" <<'EOF'
telegram-bot.service     loaded activating auto-restart Telegram Bot
agent-heartbeat.service  loaded failed     failed       Agent Heartbeat
agent-heartbeat.timer    loaded active     waiting      Agent Heartbeat Timer
claude-code.service      loaded active     running      Claude Code
pulseaudio.service       not-found inactive dead        pulseaudio.service
EOF

# list-unit-files: inclui a static agent-fornece_ai (AC4).
cat > "$FX/user.list-unit-files" <<'EOF'
telegram-bot.service     enabled enabled
agent-heartbeat.service  enabled enabled
agent-heartbeat.timer    enabled enabled
claude-code.service      enabled enabled
agent-fornece_ai.service static  -
EOF

# ── Stub de systemctl ─────────────────────────────────────────────────────────
STUB="$TMP/systemctl-stub.sh"
cat > "$STUB" <<'STUBEOF'
#!/usr/bin/env bash
echo "$*" >> "$VM_DOCTOR_CALLLOG"
args=("$@")
scope="system"
if [ "${args[0]:-}" = "--user" ]; then scope="user"; args=("${args[@]:1}"); fi
cmd="${args[0]:-}"
case "$cmd" in
  list-units)      cat "$VM_DOCTOR_FIXTURES/$scope.list-units" 2>/dev/null ;;
  list-unit-files) cat "$VM_DOCTOR_FIXTURES/$scope.list-unit-files" 2>/dev/null ;;
  show)
    unit="${args[$(( ${#args[@]} - 1 ))]}"
    cat "$VM_DOCTOR_FIXTURES/$scope.show.$unit" 2>/dev/null ;;
  *) : ;;  # stop/disable/mask/reset-failed/etc: só loga, exit 0
esac
exit 0
STUBEOF
chmod +x "$STUB"

# ── Stub de journalctl ────────────────────────────────────────────────────────
JSTUB="$TMP/journalctl-stub.sh"
cat > "$JSTUB" <<'JSTUBEOF'
#!/usr/bin/env bash
echo "journalctl $*" >> "$VM_DOCTOR_CALLLOG"
case "$*" in
  *--disk-usage*) echo "Archived and active journals take up 1.4G in the file system." ;;
esac
exit 0
JSTUBEOF
chmod +x "$JSTUB"

# Helper: roda o doctor com stubs; sudo SEMPRE falha por default (degrade system),
# então as fixtures são só user-scope. $1 = call-log path; resto = args do doctor.
run_doctor() {
  local calllog="$1"; shift
  : > "$calllog"
  VM_DOCTOR_SYSTEMCTL="$STUB" \
  VM_DOCTOR_JOURNALCTL="$JSTUB" \
  VM_DOCTOR_SUDO="$TMP/false-sudo.sh" \
  VM_DOCTOR_FIXTURES="$FX" \
  VM_DOCTOR_CALLLOG="$calllog" \
    bash "$DOCTOR" "$@"
}

# sudo stub que SEMPRE falha (simula VM sem sudo passwordless). REGISTRA argv no
# call-log ANTES de falhar (parecer iter4): sem isso, uma regressão que esquecesse
# o `continue` do degrade tentaria `sudo systemctl stop ...`, o sudo falharia ANTES
# do stub de systemctl logar, e os asserts de ausência passariam por acidente.
cat > "$TMP/false-sudo.sh" <<'EOF'
#!/usr/bin/env bash
echo "sudo $*" >> "${VM_DOCTOR_CALLLOG:-/dev/null}"
exit 1
EOF
chmod +x "$TMP/false-sudo.sh"

# =============================================================================
echo "=== vm-doctor tests ==="

# ── AC1: parser key-based, ordem arbitrária + chaves ausentes ────────────────
# shellcheck source=../vm-doctor.sh
. "$DOCTOR"

parse_show < "$FX/user.show.telegram-bot.service"
assert_eq "$P_NRestarts" "26960" "AC1a NRestarts lido (antes de ExecStart)"
assert_eq "$P_ExecStartPath" "$GONE_BIN" "AC1b ExecStart path lido (após NRestarts)"
assert_eq "$P_WorkingDirectory" "$GONE_DIR" "AC1c WorkingDirectory lido"
assert_eq "$P_ActiveState" "activating" "AC1d ActiveState lido"

# .timer sem NRestarts/WD/ExecStart — não pode dar erro nem inventar valor.
parse_show < "$FX/user.show.agent-heartbeat.timer"
assert_eq "$P_NRestarts" "" "AC1e NRestarts ausente → vazio"
assert_eq "$P_WorkingDirectory" "" "AC1f WD ausente → vazio"
assert_eq "$P_ExecStartPath" "" "AC1g ExecStart ausente → vazio"
assert_eq "$P_UnitFileState" "enabled" "AC1h UnitFileState lido apesar de chaves faltando"

# ── AC2: telegram-bot e agent-heartbeat são órfãos; heartbeat prova ExecStart ⟂ WD
parse_show < "$FX/user.show.telegram-bot.service"; classify_unit
assert_eq "$IS_ORPHAN" "1" "AC2a telegram-bot órfã (WD deletado)"
assert_grep "$ORPHAN_REASON" "WorkingDirectory inexistente" "AC2b motivo WD"

parse_show < "$FX/user.show.agent-heartbeat.service"; classify_unit
assert_eq "$IS_ORPHAN" "1" "AC2c agent-heartbeat órfã"
assert_grep "$ORPHAN_REASON" "ExecStart inexistente" "AC2d motivo ExecStart"
assert_nogrep "$ORPHAN_REASON" "WorkingDirectory" "AC2e WD existe → NÃO é motivo (ExecStart ⟂ WD)"
assert_grep "$CORROB" "failed" "AC2f failed é corroborante"

# ── AC3: claude-code saudável; not-found e WD-vazio pulados ──────────────────
parse_show < "$FX/user.show.claude-code.service"; classify_unit
assert_eq "$IS_ORPHAN" "0" "AC3a claude-code saudável não é órfã"
assert_eq "$CORROB" "" "AC3b claude-code sem corroborante"

parse_show < "$FX/user.show.pulseaudio.service"; classify_unit
assert_eq "$IS_ORPHAN" "0" "AC3c pulseaudio not-found pulada (sem falso positivo)"

# pipewire: LOADED (passa do early-return de not-found) mas WD/ExecStart vazios →
# os dois checks de path são pulados por -n vazio, sem falso positivo. Isto prova
# o ramo loaded+WD-vazio que pulseaudio (not-found) não exercita.
parse_show < "$FX/user.show.pipewire.service"; classify_unit
assert_eq "$P_LoadState" "loaded" "AC3d pipewire é loaded (não not-found)"
assert_eq "$IS_ORPHAN" "0" "AC3e pipewire loaded+WD-vazio+ExecStart-vazio NÃO é órfã"
assert_eq "$ORPHAN_REASON" "" "AC3f pipewire sem motivo de órfã"

# spaced: path com espaço EXISTE → parser preserva o path inteiro e a unit
# saudável NÃO vira falso órfão (corta em ' ; ', não no 1º espaço).
parse_show < "$FX/user.show.spaced.service"; classify_unit
assert_eq "$P_ExecStartPath" "$SPACED_BIN" "AC3g path com espaço preservado inteiro"
assert_eq "$IS_ORPHAN" "0" "AC3h unit com path-com-espaço existente NÃO é órfã"

# ── AC4: static órfã detectada via list-unit-files (subprocess full-run) ─────
LOG="$TMP/log.ac4"
OUT=$(run_doctor "$LOG")
assert_grep "$OUT" "agent-fornece_ai.service.*ExecStart inexistente" "AC4a static órfã reportada"
# Veio de list-unit-files: o stub foi consultado por show.agent-fornece_ai.
assert_grep "$(cat "$LOG")" "show .*agent-fornece_ai.service" "AC4b show chamado p/ unit de unit-files"

# ── AC5a: sem --fix, NENHUMA mutação no call-log ─────────────────────────────
LOG="$TMP/log.report"
OUT=$(run_doctor "$LOG")
assert_nogrep "$(cat "$LOG")" "(^| )(stop|disable|mask|reset-failed) " "AC5a report-only: zero mutação"
assert_grep "$(cat "$LOG")" "show " "AC5b report-only: show presente"
assert_grep "$(cat "$LOG")" "list-unit" "AC5c report-only: list-* presente"

# ── AC5b: com --fix, sequências corretas + ordem ─────────────────────────────
LOG="$TMP/log.fix"
OUT=$(run_doctor "$LOG" --fix)
MUT=$(grep -nE "(stop|disable|mask|reset-failed)" "$LOG")

# enabled órfã (telegram-bot): stop antes de disable
ln_stop_tb=$(printf '%s\n' "$MUT" | grep -E "stop telegram-bot.service" | head -1 | cut -d: -f1)
ln_dis_tb=$(printf '%s\n' "$MUT" | grep -E "disable telegram-bot.service" | head -1 | cut -d: -f1)
[ -n "$ln_stop_tb" ] && [ -n "$ln_dis_tb" ] && [ "$ln_stop_tb" -lt "$ln_dis_tb" ] \
  && _pass || _fail "AC5d telegram-bot stop→disable em ordem (stop=$ln_stop_tb dis=$ln_dis_tb)"

# enabled órfã com timer homônimo (agent-heartbeat): service stop→disable, timer stop→disable
assert_grep "$(cat "$LOG")" "--user stop agent-heartbeat.service" "AC5e heartbeat service stop"
assert_grep "$(cat "$LOG")" "--user disable agent-heartbeat.service" "AC5f heartbeat service disable"
# Timer homônimo: NÃO basta presença — a ordem deve ser stop→disable (uma regressão
# disable→stop no timer passaria se só checássemos presença; parecer adversário).
ln_stop_tm=$(printf '%s\n' "$MUT" | grep -E "stop agent-heartbeat.timer" | head -1 | cut -d: -f1)
ln_dis_tm=$(printf '%s\n' "$MUT" | grep -E "disable agent-heartbeat.timer" | head -1 | cut -d: -f1)
[ -n "$ln_stop_tm" ] && [ -n "$ln_dis_tm" ] && [ "$ln_stop_tm" -lt "$ln_dis_tm" ] \
  && _pass || _fail "AC5g timer homônimo stop→disable em ordem (stop=$ln_stop_tm dis=$ln_dis_tm)"

# static órfã (agent-fornece_ai): stop→mask (NÃO disable)
ln_stop_fa=$(printf '%s\n' "$MUT" | grep -E "stop agent-fornece_ai.service" | head -1 | cut -d: -f1)
ln_mask_fa=$(printf '%s\n' "$MUT" | grep -E "mask agent-fornece_ai.service" | head -1 | cut -d: -f1)
[ -n "$ln_stop_fa" ] && [ -n "$ln_mask_fa" ] && [ "$ln_stop_fa" -lt "$ln_mask_fa" ] \
  && _pass || _fail "AC5i static stop→mask em ordem (stop=$ln_stop_fa mask=$ln_mask_fa)"
assert_nogrep "$(cat "$LOG")" "disable agent-fornece_ai.service" "AC5j static NÃO recebe disable"

# reset-failed roda ao final (após todas as mutações de unit)
ln_reset=$(printf '%s\n' "$MUT" | grep -E "reset-failed" | head -1 | cut -d: -f1)
ln_last_mut=$(printf '%s\n' "$MUT" | grep -vE "reset-failed" | tail -1 | cut -d: -f1)
[ -n "$ln_reset" ] && [ -n "$ln_last_mut" ] && [ "$ln_reset" -gt "$ln_last_mut" ] \
  && _pass || _fail "AC5k reset-failed ao final (reset=$ln_reset last=$ln_last_mut)"

# ── AC6: sudo -n falha → aviso + degrade + exit 0 ────────────────────────────
LOG="$TMP/log.ac6"
ERR=$(VM_DOCTOR_SYSTEMCTL="$STUB" VM_DOCTOR_JOURNALCTL="$JSTUB" \
      VM_DOCTOR_SUDO="$TMP/false-sudo.sh" VM_DOCTOR_FIXTURES="$FX" \
      VM_DOCTOR_CALLLOG="$LOG" bash "$DOCTOR" 2>&1 >/dev/null)
rc=$?
assert_rc "$rc" "0" "AC6a exit 0 mesmo sem sudo"
assert_grep "$ERR" "sudo -n indispon" "AC6b aviso de degrade impresso"

# AC6c–e: --fix PEDIDO + sudo -n falha + órfã SYSTEM-scope → apply_fix deve degradar
# o ramo system para report-only (mensagem específica + ZERO mutação na unit system),
# sem erro fatal. Fixtures isoladas: só system-scope, user vazio.
FXSYS="$TMP/fixtures-sys"; mkdir -p "$FXSYS"
cat > "$FXSYS/system.list-units" <<'EOF'
etl-crm-blog.service loaded failed failed ETL Salesforce Blog
EOF
cat > "$FXSYS/system.list-unit-files" <<'EOF'
etl-crm-blog.service enabled enabled
EOF
cat > "$FXSYS/system.show.etl-crm-blog.service" <<EOF
Names=etl-crm-blog.service
LoadState=loaded
ActiveState=failed
SubState=failed
WorkingDirectory=$GONE_DIR
NRestarts=120
ExecStart={ path=$GONE_BIN ; argv[]=$GONE_BIN ; ignore_errors=no }
UnitFileState=enabled
EOF

LOG="$TMP/log.ac6sys"
: > "$LOG"
ERR=$(VM_DOCTOR_SYSTEMCTL="$STUB" VM_DOCTOR_JOURNALCTL="$JSTUB" \
      VM_DOCTOR_SUDO="$TMP/false-sudo.sh" VM_DOCTOR_FIXTURES="$FXSYS" \
      VM_DOCTOR_CALLLOG="$LOG" bash "$DOCTOR" --fix 2>&1 >/dev/null)
rc=$?
assert_rc "$rc" "0" "AC6c --fix sem sudo em órfã system: exit 0 (sem erro fatal)"
assert_grep "$ERR" "system sem sudo: etl-crm-blog.service.*report-only" "AC6d degrade report-only da órfã system"
# A órfã system foi ESCANEADA (show chamado) mas NÃO sofreu mutação alguma.
assert_grep "$(cat "$LOG")" "show .*etl-crm-blog.service" "AC6e órfã system foi escaneada"
assert_nogrep "$(cat "$LOG")" "(stop|disable|mask) etl-crm-blog.service" "AC6f órfã system NÃO sofreu mutação"
# reset-failed NÃO roda no scope system degradado (SYSTEM_OK!=1).
assert_nogrep "$(cat "$LOG")" "^reset-failed" "AC6g reset-failed não roda no system degradado"
# Precondição do negativo (rubrica TESTING): o sudo stub REGISTRA argv — a chamada
# `sudo -n true` do preflight aparece no call-log, provando que uma eventual
# mutação via sudo TAMBÉM apareceria. Só então o nogrep de tentativa tem valor.
assert_grep "$(cat "$LOG")" "^sudo -n true" "AC6h precondição: sudo stub registra argv no call-log"
assert_nogrep "$(cat "$LOG")" "^sudo .*(stop|disable|mask|reset-failed)" "AC6i nenhuma mutação sequer TENTADA via sudo (pega regressão sem continue)"

# ── AC7: journal disk-usage no report + SUGERE vacuum sem executar ───────────
LOG="$TMP/log.ac7"
OUT=$(run_doctor "$LOG")
assert_grep "$OUT" "Journal disk usage" "AC7a seção journal presente"
assert_grep "$OUT" "1.4G" "AC7b disk-usage do user reportado"
assert_grep "$OUT" "vacuum-size" "AC7c vacuum SUGERIDO"
assert_nogrep "$(cat "$LOG")" "vacuum" "AC7d vacuum NÃO executado (ausente do call-log)"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then
  echo "Failed tests:$FAILED"
  exit 1
fi
exit 0

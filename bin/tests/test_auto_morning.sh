#!/usr/bin/env bash
# test_auto_morning.sh — testes para o wiring de US-07 em bin/auto-morning.sh
# (invocação non-blocking de backlog-dispatch.sh).
#
# Cobre AC9 (AC10 é CAT3-MANUAL, fora daqui):
#   AC9 — auto-morning.sh chama backlog-dispatch.sh com --max 2 de forma
#         non-blocking (|| true) via seam AM_BACKLOG_DISPATCH:
#         (a) o dispatcher é invocado com --max 2 (visível no call-log);
#         (b) um dispatcher que faz `exit 1` NÃO altera o exit 0 do auto-morning;
#         (c) dispatcher ausente/não-executável é logado e pulado, exit 0;
#         (d) o backlog roda APÓS o reflect (ordem por timestamps no call-log).
#
# Estratégia: seams de env apontam para stubs que logam num call-log. Pattern de
# test_auto_morning_reflect_wiring.sh.
#
# Cobre também US-02 do ciclo r9-secrets-lifecycle (seção ao final): step
# non-blocking de aviso de credenciais vencendo via seam AM_SECRETS_EXPIRY
# (secrets-expiry.sh due --days 14), entre BACKLOG_DISPATCH e INTERRUPCOES.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
AM="$REPO_ROOT/bin/auto-morning.sh"

PASS=0; FAIL=0; FAILED=""
_pass() { PASS=$((PASS+1)); }
_fail() { FAIL=$((FAIL+1)); FAILED="${FAILED}
  ✗ $1"; }
assert_grep() { printf '%s' "$1" | grep -qE -- "$2" && _pass || _fail "$3 :: padrão '$2' ausente em: $1"; }
assert_nogrep(){ printf '%s' "$1" | grep -qE -- "$2" && _fail "$3 :: padrão '$2' NÃO deveria aparecer em: $1" || _pass; }
assert_rc()   { [ "$1" = "$2" ] && _pass || _fail "$3 :: expected rc=$2 got rc=$1"; }
assert_lt()   { { [ -n "$1" ] && [ -n "$2" ] && [ "$1" -lt "$2" ]; } && _pass || _fail "$3 :: esperado $1 < $2"; }

[ -f "$AM" ] || { echo "FAIL: $AM inexistente" >&2; exit 1; }
bash -n "$AM" || { echo "FAIL: bash -n sujo em $AM" >&2; exit 1; }

TMP="$(mktemp -d -t ambl.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

CALLLOG="$TMP/calls.log"

VM_STUB="$TMP/vm-morning.sh"
cat > "$VM_STUB" <<EOF
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$VM_STUB"

# reflect stub: loga com timestamp ns (para provar ordem reflect→backlog).
REFLECT_STUB="$TMP/reflect.sh"
cat > "$REFLECT_STUB" <<EOF
#!/usr/bin/env bash
printf '%s REFLECT_RAN\n' "\$(date +%s%N)" >> "$CALLLOG"
exit 0
EOF
chmod +x "$REFLECT_STUB"

# backlog stub OK: loga argv + timestamp; sai 0.
BACKLOG_OK="$TMP/backlog-ok.sh"
cat > "$BACKLOG_OK" <<EOF
#!/usr/bin/env bash
printf '%s BACKLOG_RAN %s\n' "\$(date +%s%N)" "\$*" >> "$CALLLOG"
exit 0
EOF
chmod +x "$BACKLOG_OK"

# backlog stub FAIL: loga e sai 1 (prova non-blocking).
BACKLOG_FAIL="$TMP/backlog-fail.sh"
cat > "$BACKLOG_FAIL" <<EOF
#!/usr/bin/env bash
printf '%s BACKLOG_RAN_FAIL %s\n' "\$(date +%s%N)" "\$*" >> "$CALLLOG"
exit 1
EOF
chmod +x "$BACKLOG_FAIL"

run_am() { # backlog_stub
  : > "$CALLLOG"
  AM_SKIP_WAIT=1 \
  AM_LOG="$TMP/auto-morning.log" \
  AM_VM_MORNING="$VM_STUB" \
  AM_REFLECT_RETRO="$REFLECT_STUB" \
  AM_BACKLOG_DISPATCH="$1" \
  AM_INTERRUPCOES="$TMP/ir-nao-existe.sh" \
  AM_AUTONOMY_CACHE="$TMP/autonomy-default" \
  AM_SECRETS_EXPIRY="$TMP/se-nao-existe.sh" \
    bash "$AM"
}

# ── AC9a/AC9d: backlog OK roda com --max 2, APÓS o reflect, exit 0 ────────────
run_am "$BACKLOG_OK"; rc=$?
LOG_OUT="$(cat "$TMP/auto-morning.log")"
assert_rc "$rc" 0 "AC9: auto-morning exit 0 quando backlog sai 0"
assert_grep "$LOG_OUT" "drenando backlog" "AC9: anúncio do backlog aparece no log"
assert_grep "$LOG_OUT" "--max 2" "AC9a: backlog chamado com --max 2"
assert_grep "$(cat "$CALLLOG")" "BACKLOG_RAN .*--max 2" "AC9a: call-log confirma --max 2 no argv"
RF_TS="$(grep 'REFLECT_RAN' "$CALLLOG" | head -1 | awk '{print $1}')"
BL_TS="$(grep 'BACKLOG_RAN' "$CALLLOG" | head -1 | awk '{print $1}')"
assert_lt "$RF_TS" "$BL_TS" "AC9d: backlog roda APÓS o reflect (ordem no call-log)"

# ── AC9b: backlog exit 1 NÃO altera o exit code do auto-morning ───────────────
run_am "$BACKLOG_FAIL"; rc=$?
LOG_OUT="$(cat "$TMP/auto-morning.log")"
assert_rc "$rc" 0 "AC9b: backlog exit 1 → auto-morning ainda sai 0 (|| true)"
assert_grep "$(cat "$CALLLOG")" "BACKLOG_RAN_FAIL" "AC9b: backlog FAIL foi de fato invocado"
assert_grep "$LOG_OUT" "concluído" "AC9b: auto-morning chega ao fim mesmo com backlog falho"

# ── AC9c: backlog ausente/não-executável é logado e pulado, exit 0 ────────────
run_am "$TMP/nao-existe.sh"; rc=$?
LOG_OUT="$(cat "$TMP/auto-morning.log")"
assert_rc "$rc" 0 "AC9c: backlog ausente → auto-morning sai 0"
assert_grep "$LOG_OUT" "ausente/não-executável|pulado" "AC9c: backlog ausente é logado e pulado"

# ═══ US-01 (autonomy-4-melhorias): bin/morning.sh — contador de reflexões
# filtrado por kind + linha dedicada de autonomy-promotion vencida/próxima ═══
# Falha #1 da Revisão Adversária: sem filtro, kinds novos (learn,
# autonomy-promotion) inflavam o contador de baselines e sugeriam um
# /reflect --retro inexistente. Seams MORNING_* injetam fixture + stubs.

MORNING="$REPO_ROOT/bin/morning.sh"
[ -f "$MORNING" ] || { echo "FAIL: $MORNING inexistente" >&2; exit 1; }
bash -n "$MORNING" || { echo "FAIL: bash -n sujo em $MORNING" >&2; exit 1; }

POOL="$TMP/checkouts"; mkdir -p "$POOL/demo-1"
NOOP="$TMP/noop.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$NOOP"; chmod +x "$NOOP"
REMFIX="$TMP/reminders.jsonl"
cat > "$REMFIX" <<'EOF'
{"pr":"99","repo":"demo","created_at":"2026-05-18T03-15-16Z","retro_due_at":"2026-05-25T03-15-16Z"}
{"kind":"learn","pr":"84","repo":"dotclaude","created_at":"2026-06-01T00-00-00Z"}
{"kind":"autonomy-promotion","repo":"dotclaude","retro_due_at":"2026-07-08T00-00-00Z","note":"promover autonomy-guard a block nas VMs (echo block > ~/.claude/cache/autonomy/mode) após inspecionar audit"}
{"kind":"autonomy-promotion","repo":"dotclaude","retro_due_at":"2099-01-01T00-00-00Z","note":"promoção futura NÃO exibida"}
EOF

MORNING_OUT="$(MORNING_CHECKOUT_BASE="$POOL" MORNING_SYNC_SCRIPT="$NOOP" \
  MORNING_LAUNCH_SCRIPT="$NOOP" MORNING_REMINDERS="$REMFIX" \
  bash "$MORNING" demo --no-sync 2>&1)"; rc=$?
assert_rc "$rc" 0 "US-01/AC7: morning.sh exit 0 com fixture mista"
assert_grep "$MORNING_OUT" "Reflexões pendentes: 1 baseline" \
  "US-01/AC7: contador mostra 1 (kind==null conta; learn/autonomy-promotion não)"
assert_grep "$MORNING_OUT" "2026-07-08" \
  "US-01/AC7: linha dedicada do lembrete de promoção cita a data 2026-07-08"
assert_grep "$MORNING_OUT" "autonomy-guard" \
  "US-01/AC7: linha dedicada menciona autonomy-guard"
assert_nogrep "$MORNING_OUT" "2099-01-01" \
  "US-01/AC7: promoção com due além de hoje+7d NÃO é exibida"

# ═══ R6: relatório semanal de interrupções no auto-morning (telemetria) ═══
# Roda 1×/semana via stamp por mtime; non-blocking; --since 7 + --out arquivo.

IR_STUB="$TMP/ir-stub.sh"
cat > "$IR_STUB" <<EOF
#!/usr/bin/env bash
printf '%s IR_RAN %s\n' "\$(date +%s%N)" "\$*" >> "$CALLLOG"
exit 0
EOF
chmod +x "$IR_STUB"
IR_FAIL="$TMP/ir-fail.sh"
cat > "$IR_FAIL" <<EOF
#!/usr/bin/env bash
printf '%s IR_RAN_FAIL %s\n' "\$(date +%s%N)" "\$*" >> "$CALLLOG"
exit 1
EOF
chmod +x "$IR_FAIL"

run_am_ir() { # ir_stub autonomy_cache
  AM_SKIP_WAIT=1 AM_LOG="$TMP/auto-morning.log" AM_VM_MORNING="$VM_STUB" \
  AM_REFLECT_RETRO="$REFLECT_STUB" AM_BACKLOG_DISPATCH="$BACKLOG_OK" \
  AM_INTERRUPCOES="$1" AM_AUTONOMY_CACHE="$2" \
  AM_SECRETS_EXPIRY="$TMP/se-nao-existe.sh" bash "$AM"
}

# R6a — sem stamp: relatório roda com --since 7 e --out; stamp criado; exit 0.
ACACHE="$TMP/autonomy"; mkdir -p "$ACACHE"; : > "$CALLLOG"
run_am_ir "$IR_STUB" "$ACACHE"; rc=$?
assert_rc "$rc" 0 "R6a: auto-morning exit 0 com relatório semanal"
assert_grep "$(cat "$CALLLOG")" "IR_RAN .*--since 7" "R6a: relatório invocado com --since 7"
assert_grep "$(cat "$CALLLOG")" "IR_RAN .*--out" "R6a: relatório escreve via --out"
[ -f "$ACACHE/last-weekly-report" ] && _pass || _fail "R6a: stamp last-weekly-report criado"

# R6b — stamp fresco: NÃO re-roda (contagem no call-log não muda).
N1="$(grep -c 'IR_RAN ' "$CALLLOG")"
run_am_ir "$IR_STUB" "$ACACHE"
N2="$(grep -c 'IR_RAN ' "$CALLLOG")"
[ "$N1" = "$N2" ] && _pass || _fail "R6b: stamp fresco deveria pular ($N1 → $N2)"

# R6c — stamp velho (>7d): re-roda.
touch -t 202001010000 "$ACACHE/last-weekly-report"
run_am_ir "$IR_STUB" "$ACACHE"
N3="$(grep -c 'IR_RAN ' "$CALLLOG")"
[ "$N3" -gt "$N2" ] && _pass || _fail "R6c: stamp velho deveria re-rodar ($N2 → $N3)"

# R6d — relatório exit 1: non-blocking (auto-morning exit 0) e stamp NÃO tocado
# (re-tenta na próxima manhã em vez de silenciar a falha por 1 semana).
ACACHE2="$TMP/autonomy2"; mkdir -p "$ACACHE2"; : > "$CALLLOG"
run_am_ir "$IR_FAIL" "$ACACHE2"; rc=$?
assert_rc "$rc" 0 "R6d: relatório falho não derruba o auto-morning"
assert_grep "$(cat "$CALLLOG")" "IR_RAN_FAIL" "R6d: relatório falho foi de fato invocado"
[ ! -f "$ACACHE2/last-weekly-report" ] && _pass || _fail "R6d: falha não grava stamp (re-tenta amanhã)"

# ═══ US-02 (r9-secrets-lifecycle): aviso proativo de credenciais vencendo ═══
# Step non-blocking entre BACKLOG_DISPATCH e INTERRUPCOES, seam AM_SECRETS_EXPIRY:
# roda `secrets-expiry.sh due --days 14` e imprime vencimentos no log da manhã.

# SE_OK: loga argv + timestamp e emite uma linha de vencimento (como o due real).
SE_OK="$TMP/se-ok.sh"
cat > "$SE_OK" <<EOF
#!/usr/bin/env bash
printf '%s SE_RAN %s\n' "\$(date +%s%N)" "\$*" >> "$CALLLOG"
printf 'token-x\tprov\t2026-07-10\t8d\n'
exit 1
EOF
chmod +x "$SE_OK"
# SE_FAIL: loga e sai 3 (inventário corrompido — pior caso do secrets-expiry).
SE_FAIL="$TMP/se-fail.sh"
cat > "$SE_FAIL" <<EOF
#!/usr/bin/env bash
printf '%s SE_RAN_FAIL %s\n' "\$(date +%s%N)" "\$*" >> "$CALLLOG"
exit 3
EOF
chmod +x "$SE_FAIL"

run_am_se() { # se_stub [ir_stub autonomy_cache]
  : > "$CALLLOG"
  AM_SKIP_WAIT=1 AM_LOG="$TMP/auto-morning.log" AM_VM_MORNING="$VM_STUB" \
  AM_REFLECT_RETRO="$REFLECT_STUB" AM_BACKLOG_DISPATCH="$BACKLOG_OK" \
  AM_INTERRUPCOES="${2:-$TMP/ir-nao-existe.sh}" \
  AM_AUTONOMY_CACHE="${3:-$TMP/autonomy-default}" \
  AM_SECRETS_EXPIRY="$1" bash "$AM"
}

# ── AC1: stub roda com 'due' e '--days 14' no argv; exit 1 do due (há vencidas)
# não derruba o auto-morning; vencimentos aparecem no log da manhã ────────────
run_am_se "$SE_OK"; rc=$?
LOG_OUT="$(cat "$TMP/auto-morning.log")"
assert_rc "$rc" 0 "US-02/AC1: due com vencimento (exit 1) → auto-morning ainda sai 0"
assert_grep "$(cat "$CALLLOG")" "SE_RAN due --days 14" "US-02/AC1: call-log confirma 'due --days 14' no argv"
assert_grep "$LOG_OUT" "token-x" "US-02/AC1: vencimento impresso no log da manhã"
assert_grep "$LOG_OUT" "credenciais vencendo" "US-02/AC1: anúncio do step aparece no log"
BL_TS="$(grep 'BACKLOG_RAN' "$CALLLOG" | head -1 | awk '{print $1}')"
SE_TS="$(grep 'SE_RAN' "$CALLLOG" | head -1 | awk '{print $1}')"
assert_lt "$BL_TS" "$SE_TS" "US-02: step de expiry roda APÓS o backlog (ordem no call-log)"

# stub que falha duro (exit 3, inventário corrompido) também é non-blocking,
# mas rc=3 ganha ALERTA próprio (code-review R9: colapsar 1 e 3 deixava o
# pipeline de aviso morto sem sinal acionável); rc=1 (há due) NÃO alerta
run_am_se "$SE_FAIL"; rc=$?
assert_rc "$rc" 0 "US-02/AC1: expiry exit 3 → auto-morning ainda sai 0 (non-blocking)"
assert_grep "$(cat "$CALLLOG")" "SE_RAN_FAIL" "US-02/AC1: stub falho foi de fato invocado"
assert_grep "$(cat "$TMP/auto-morning.log")" "concluído" "US-02/AC1: auto-morning chega ao fim com expiry falho"
assert_grep "$(cat "$TMP/auto-morning.log")" "ALERTA: inventário de secrets corrompido" \
  "US-02/RF: rc=3 imprime ALERTA de corrupção (distinto de 'há vencimento')"
: > "$TMP/auto-morning.log"   # log acumula entre runs — zera pro assert negativo
run_am_se "$SE_OK"
assert_nogrep "$(cat "$TMP/auto-morning.log")" "ALERTA: inventário" \
  "US-02/RF: rc=1 (há due) NÃO gera ALERTA de corrupção"

# ordem vs INTERRUPCOES: expiry roda ANTES do relatório semanal
ACACHE_SE="$TMP/autonomy-se"; mkdir -p "$ACACHE_SE"
run_am_se "$SE_OK" "$IR_STUB" "$ACACHE_SE"
SE_TS="$(grep 'SE_RAN' "$CALLLOG" | head -1 | awk '{print $1}')"
IR_TS="$(grep 'IR_RAN' "$CALLLOG" | head -1 | awk '{print $1}')"
assert_lt "$SE_TS" "$IR_TS" "US-02: step de expiry roda ANTES do relatório de interrupções"

# ── AC2: seam apontando para inexistente → pula com mensagem, exit 0,
# e NENHUMA invocação no call-log (capture-proof, par com o positivo do AC1) ──
run_am_se "$TMP/se-nao-existe.sh"; rc=$?
LOG_OUT="$(cat "$TMP/auto-morning.log")"
assert_rc "$rc" 0 "US-02/AC2: expiry ausente → auto-morning sai 0"
assert_grep "$LOG_OUT" "secrets-expiry.sh ausente/não-executável" "US-02/AC2: mensagem de pulo no log"
assert_nogrep "$(cat "$CALLLOG")" "SE_RAN" "US-02/AC2: call-log sem SE_RAN (step de fato pulado)"

echo "─────────────────────────────────────────"
echo "PASS: $PASS   FAIL: $FAIL"
if [ "$FAIL" -gt 0 ]; then
  echo "Falhas:$FAILED"
  exit 1
fi
echo "OK — auto-morning backlog wiring (US-07 AC9)"

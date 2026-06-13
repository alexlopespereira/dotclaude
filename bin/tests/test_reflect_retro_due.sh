#!/usr/bin/env bash
# test_reflect_retro_due.sh — testes para bin/reflect-retro-due.sh (US-01).
#
# Cobre os acceptance criteria automatizáveis:
#   AC1 — --help documenta seleção/dedup/cap/resolução; arg inválido e --max
#         não-numérico/gigante (>3 dígitos, inclui 999999999999999999) → usage
#         em stderr + exit != 0, ANTES de qualquer aritmética.
#   AC2 — selector: baseline vencida dispara; futura, learn (retro_due_at null) e
#         linha corrompida não-JSON são ignoradas sem erro (call-log do claude stub).
#   AC3 — dedup: (a) retro_done existente não roda; (b) baselines duplicadas → 1
#         execução; (c) 3 retro_attempt → skip permanente.
#   AC4 — cap: 4 vencidas + --max 2 → exatamente 2, oldest-first (ordem no call-log).
#   AC5 — resolução de path (RRD_PROJECTS_DIR fake): slot exato; fallback base-1;
#         nenhum candidato → skip sem marcador novo, execuções seguintes continuam.
#   AC6 — argv exato do claude: -p "/reflect <pr> --retro" + --allowedTools, APÓS
#         cd no path (cwd logado); timeout via RRD_TIMEOUT com 900.
#   AC7 — rc=0 → append retro_done (jq-parseable); rc!=0 → append retro_attempt e
#         processa o PRÓXIMO item, exit 0 (non-blocking).
#   AC8 — idempotência: 2ª execução pós-retro_done → zero retros, exit 0, "nada vencido".
#
# Estratégia: stubs de claude/timeout que logam argv + cwd num call-log
# compartilhado; fixtures de reminders.jsonl controlam o que o selector vê.
# Pattern de test_vm_provision.sh.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RRD="$REPO_ROOT/bin/reflect-retro-due.sh"

PASS=0; FAIL=0; FAILED=""
_pass() { PASS=$((PASS+1)); }
_fail() { FAIL=$((FAIL+1)); FAILED="${FAILED}
  ✗ $1"; }
assert_eq()    { [ "$1" = "$2" ] && _pass || _fail "$3 :: expected '$2' got '$1'"; }
assert_grep()  { printf '%s' "$1" | grep -qE -- "$2" && _pass || _fail "$3 :: padrão '$2' ausente em: $1"; }
assert_nogrep(){ printf '%s' "$1" | grep -qE -- "$2" && _fail "$3 :: padrão '$2' NÃO deveria aparecer em: $1" || _pass; }
assert_rc()    { [ "$1" = "$2" ] && _pass || _fail "$3 :: expected rc=$2 got rc=$1"; }
assert_count() { # texto, padrão, n esperado, msg
  local n; n=$(printf '%s\n' "$1" | grep -cE -- "$2"); [ "$n" = "$3" ] && _pass || _fail "$4 :: esperado $3 ocorrências de '$2', obteve $n"; }
assert_lt()    { { [ -n "$1" ] && [ -n "$2" ] && [ "$1" -lt "$2" ]; } && _pass || _fail "$3 :: esperado $1 < $2"; }

[ -f "$RRD" ] || { echo "FAIL: $RRD inexistente" >&2; exit 1; }
bash -n "$RRD" || { echo "FAIL: bash -n sujo em $RRD" >&2; exit 1; }

TMP="$(mktemp -d -t rrd.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

NOW="2026-06-01T00-00-00Z"   # fixo: vencido = due <= NOW

# ── stubs ────────────────────────────────────────────────────────────────────
# claude stub: loga argv + cwd; falha se o PR estiver em RRD_FAIL_PRS.
CLAUDE_STUB="$TMP/claude.sh"
cat > "$CLAUDE_STUB" <<'EOF'
#!/usr/bin/env bash
{ echo "claude $*"; echo "cwd=$(pwd)"; } >> "$RRD_CALLLOG"
pr=""
for a in "$@"; do
  case "$a" in
    /reflect\ *) pr=$(printf '%s' "$a" | awk '{print $2}') ;;
  esac
done
if [ -n "${RRD_FAIL_PRS:-}" ]; then
  for f in $RRD_FAIL_PRS; do [ "$f" = "$pr" ] && exit 1; done
fi
exit 0
EOF
chmod +x "$CLAUDE_STUB"

# timeout stub: loga "timeout <dur> <cmd...>" e exec o restante (mantém o cwd).
TIMEOUT_STUB="$TMP/timeout.sh"
cat > "$TIMEOUT_STUB" <<'EOF'
#!/usr/bin/env bash
echo "timeout $*" >> "$RRD_CALLLOG"
shift   # remove a duração
exec "$@"
EOF
chmod +x "$TIMEOUT_STUB"

# PROJECTS_DIR fake com os slots usados pelos testes de path.
PROJ="$TMP/projects"
mkdir -p "$PROJ/checkouts/dotclaude-slot" "$PROJ/dotclaude" \
         "$PROJ/checkouts/wikiapp-1" "$PROJ/checkouts/storefront-1"
# (dotclaude resolve via $PROJ/dotclaude; wikiapp-2/3 via base-1 = wikiapp-1)

run() { # call-log ; resto via env do caller
  RRD_NOW="$NOW" RRD_CLAUDE="$CLAUDE_STUB" RRD_TIMEOUT="$TIMEOUT_STUB" \
  RRD_PROJECTS_DIR="$PROJ" "$@"
}

echo "=== reflect-retro-due tests ==="

# =============================================================================
# AC1 — help + validação de --max (forma E comprimento ANTES de aritmética)
# =============================================================================
OUT=$(bash "$RRD" --help); rc=$?
assert_rc "$rc" "0" "AC1a --help exit 0"
assert_grep "$OUT" "[Ss]ele" "AC1b help documenta seleção"
assert_grep "$OUT" "dedup|retro_done" "AC1c help documenta dedup"
assert_grep "$OUT" "--max" "AC1d help documenta cap --max"
assert_grep "$OUT" "checkouts|path|slot" "AC1e help documenta resolução de path"

ERR=$(bash "$RRD" --frobnicate 2>&1 >/dev/null); rc=$?
[ "$rc" != 0 ] && _pass || _fail "AC1f arg inválido → exit != 0 (rc=$rc)"
assert_grep "$ERR" "[Uu]so|[Uu]sage" "AC1g arg inválido → usage em stderr"

ERR=$(bash "$RRD" --max abc 2>&1 >/dev/null); rc=$?
[ "$rc" != 0 ] && _pass || _fail "AC1h --max não-numérico → exit != 0 (rc=$rc)"

ERR=$(bash "$RRD" --max 999999999999999999 2>&1 >/dev/null); rc=$?
[ "$rc" != 0 ] && _pass || _fail "AC1i --max gigante (>3 dígitos) → exit != 0 (rc=$rc)"
assert_grep "$ERR" "[Uu]so|[Uu]sage" "AC1j --max gigante → usage (sem virar caminho feliz)"

# =============================================================================
# AC2 — selector: vencida dispara; futura/learn/corrompida ignoradas
# =============================================================================
REM="$TMP/rem-ac2.jsonl"
{
  echo '{"pr":"20","repo":"dotclaude","retro_due_at":"2026-05-25T03-15-17Z","mode":"baseline"}'
  echo '{"pr":"99","repo":"dotclaude","retro_due_at":"2026-12-01T00-00-00Z"}'
  echo '{"kind":"learn","pr":"4","repo":"dotclaude","created_at":"2026-05-25T21-15-11Z"}'
  echo 'isto NAO eh json {{{'
} > "$REM"
LOG="$TMP/log.ac2"; : > "$LOG"
OUT=$(run env RRD_REMINDERS="$REM" RRD_CALLLOG="$LOG" bash "$RRD" 2>&1); rc=$?
assert_rc "$rc" "0" "AC2a exit 0"
assert_count "$(cat "$LOG")" "^claude " "1" "AC2b apenas a vencida dispara claude (1 execução)"
assert_grep "$(cat "$LOG")" "/reflect 20 --retro" "AC2c a vencida é o PR 20"
assert_nogrep "$(cat "$LOG")" "/reflect 99" "AC2d futura ignorada"
assert_nogrep "$(cat "$LOG")" "/reflect 4 " "AC2e learn ignorado"

# =============================================================================
# AC3 — dedup
# =============================================================================
# (a) retro_done existente → não roda
REM="$TMP/rem-ac3a.jsonl"
{
  echo '{"pr":"20","repo":"dotclaude","retro_due_at":"2026-05-25T03-15-17Z"}'
  echo '{"kind":"retro_done","pr":"20","repo":"dotclaude","created_at":"2026-05-26T00-00-00Z","rc":0}'
} > "$REM"
LOG="$TMP/log.ac3a"; : > "$LOG"
OUT=$(run env RRD_REMINDERS="$REM" RRD_CALLLOG="$LOG" bash "$RRD" 2>&1); rc=$?
assert_rc "$rc" "0" "AC3a-rc exit 0"
assert_nogrep "$(cat "$LOG")" "^claude " "AC3a par com retro_done não roda"
assert_grep "$OUT" "nada vencido" "AC3a' nada a fazer → log nada vencido"

# (b) baselines duplicadas do mesmo par → UMA execução
REM="$TMP/rem-ac3b.jsonl"
{
  echo '{"pr":"20","repo":"dotclaude","retro_due_at":"2026-05-25T03-15-17Z","mode":"baseline"}'
  echo '{"pr":"20","repo":"dotclaude","retro_due_at":"2026-05-25T03-43-28Z"}'
} > "$REM"
LOG="$TMP/log.ac3b"; : > "$LOG"
OUT=$(run env RRD_REMINDERS="$REM" RRD_CALLLOG="$LOG" bash "$RRD" 2>&1); rc=$?
assert_count "$(cat "$LOG")" "^claude " "1" "AC3b duplicatas → 1 execução"

# (c) 3 retro_attempt → skip permanente
REM="$TMP/rem-ac3c.jsonl"
{
  echo '{"pr":"20","repo":"dotclaude","retro_due_at":"2026-05-25T03-15-17Z"}'
  echo '{"kind":"retro_attempt","pr":"20","repo":"dotclaude","created_at":"2026-05-26T00-00-00Z","rc":1}'
  echo '{"kind":"retro_attempt","pr":"20","repo":"dotclaude","created_at":"2026-05-27T00-00-00Z","rc":1}'
  echo '{"kind":"retro_attempt","pr":"20","repo":"dotclaude","created_at":"2026-05-28T00-00-00Z","rc":1}'
} > "$REM"
LOG="$TMP/log.ac3c"; : > "$LOG"
OUT=$(run env RRD_REMINDERS="$REM" RRD_CALLLOG="$LOG" bash "$RRD" 2>&1); rc=$?
assert_nogrep "$(cat "$LOG")" "^claude " "AC3c 3 attempts → não roda"
assert_grep "$OUT" "skip permanente" "AC3c' log 'skip permanente'"

# =============================================================================
# AC4 — cap: 4 vencidas + --max 2 → exatamente 2, oldest-first
# =============================================================================
REM="$TMP/rem-ac4.jsonl"
{
  echo '{"pr":"30","repo":"dotclaude","retro_due_at":"2026-05-28T00-00-00Z"}'
  echo '{"pr":"31","repo":"dotclaude","retro_due_at":"2026-05-25T00-00-00Z"}'
  echo '{"pr":"32","repo":"dotclaude","retro_due_at":"2026-05-27T00-00-00Z"}'
  echo '{"pr":"33","repo":"dotclaude","retro_due_at":"2026-05-26T00-00-00Z"}'
} > "$REM"
LOG="$TMP/log.ac4"; : > "$LOG"
OUT=$(run env RRD_REMINDERS="$REM" RRD_CALLLOG="$LOG" bash "$RRD" --max 2 2>&1); rc=$?
assert_rc "$rc" "0" "AC4a exit 0"
assert_count "$(cat "$LOG")" "^claude " "2" "AC4b --max 2 → exatamente 2 execuções"
# oldest-first: PR 31 (05-25) antes de PR 33 (05-26); 32/30 não rodam
ln31=$(grep -nE "/reflect 31 " "$LOG" | head -1 | cut -d: -f1)
ln33=$(grep -nE "/reflect 33 " "$LOG" | head -1 | cut -d: -f1)
assert_lt "$ln31" "$ln33" "AC4c oldest-first: PR31 antes de PR33"
assert_nogrep "$(cat "$LOG")" "/reflect 32 " "AC4d PR32 fora do cap"
assert_nogrep "$(cat "$LOG")" "/reflect 30 " "AC4e PR30 fora do cap"

# =============================================================================
# AC5 — resolução de path (RRD_PROJECTS_DIR fake)
# =============================================================================
# (a) slot exato presente ($PROJ/dotclaude) ; (b) wikiapp-2 → base-1 (wikiapp-1) ;
# (c) repo inexistente → skip sem marcador, execuções seguintes continuam.
REM="$TMP/rem-ac5.jsonl"
{
  echo '{"pr":"40","repo":"naoexiste-9","retro_due_at":"2026-05-24T00-00-00Z"}'
  echo '{"pr":"41","repo":"wikiapp-2","retro_due_at":"2026-05-25T00-00-00Z"}'
  echo '{"pr":"42","repo":"dotclaude","retro_due_at":"2026-05-26T00-00-00Z"}'
} > "$REM"
LOG="$TMP/log.ac5"; : > "$LOG"
before=$(wc -l < "$REM")
OUT=$(run env RRD_REMINDERS="$REM" RRD_CALLLOG="$LOG" bash "$RRD" --max 5 2>&1); rc=$?
assert_rc "$rc" "0" "AC5a exit 0"
assert_grep "$(cat "$LOG")" "cwd=$PROJ/checkouts/wikiapp-1\$" "AC5b wikiapp-2 resolve p/ base-1 (wikiapp-1)"
assert_grep "$(cat "$LOG")" "cwd=$PROJ/dotclaude\$" "AC5c dotclaude resolve p/ slot/base"
assert_nogrep "$(cat "$LOG")" "/reflect 40 " "AC5d repo inexistente não roda"
assert_grep "$OUT" "naoexiste-9" "AC5e skip do repo inexistente é logado"
# nenhum marcador novo (retro_done/retro_attempt) para o inexistente — só a
# baseline original permanece (re-tentável quando o clone existir).
mark_naoexiste=$(grep -E '"kind":"retro_(done|attempt)"' "$REM" | grep -c '"repo":"naoexiste-9"')
assert_eq "$mark_naoexiste" "0" "AC5f repo inexistente → NENHUM marcador novo (re-tentável)"
assert_count "$(cat "$LOG")" "^claude " "2" "AC5g execuções seguintes continuam (2 resolvidas rodam)"

# =============================================================================
# AC6 — argv exato + timeout + cwd
# =============================================================================
REM="$TMP/rem-ac6.jsonl"
echo '{"pr":"42","repo":"dotclaude","retro_due_at":"2026-05-26T00-00-00Z"}' > "$REM"
LOG="$TMP/log.ac6"; : > "$LOG"
OUT=$(run env RRD_REMINDERS="$REM" RRD_CALLLOG="$LOG" bash "$RRD" 2>&1); rc=$?
assert_grep "$(cat "$LOG")" 'claude -p /reflect 42 --retro' "AC6a -p /reflect <pr> --retro"
assert_grep "$(cat "$LOG")" "claude .*--allowedTools" "AC6b --allowedTools presente"
assert_grep "$(cat "$LOG")" "^timeout 900 " "AC6c timeout via RRD_TIMEOUT com 900"
assert_grep "$(cat "$LOG")" "cwd=$PROJ/dotclaude\$" "AC6d executado APÓS cd no path resolvido"

# =============================================================================
# AC7 — rc=0 → retro_done ; rc!=0 → retro_attempt + processa próximo (non-blocking)
# =============================================================================
REM="$TMP/rem-ac7.jsonl"
{
  echo '{"pr":"50","repo":"dotclaude","retro_due_at":"2026-05-25T00-00-00Z"}'
  echo '{"pr":"51","repo":"dotclaude","retro_due_at":"2026-05-26T00-00-00Z"}'
} > "$REM"
LOG="$TMP/log.ac7"; : > "$LOG"
# PR 50 falha (rc=1), PR 51 sucede
OUT=$(run env RRD_REMINDERS="$REM" RRD_CALLLOG="$LOG" RRD_FAIL_PRS="50" bash "$RRD" --max 5 2>&1); rc=$?
assert_rc "$rc" "0" "AC7a falha não bloqueia → exit 0 (non-blocking)"
assert_count "$(cat "$LOG")" "^claude " "2" "AC7b processa o próximo após falha"
# marcadores corretos e jq-parseable
last_attempt=$(grep '"kind":"retro_attempt"' "$REM" | tail -1)
last_done=$(grep '"kind":"retro_done"' "$REM" | tail -1)
printf '%s' "$last_attempt" | jq -e '.kind=="retro_attempt" and .pr=="50" and .repo=="dotclaude" and .rc==1' >/dev/null 2>&1 \
  && _pass || _fail "AC7c PR50 → retro_attempt rc=1 jq-parseable (got: $last_attempt)"
printf '%s' "$last_done" | jq -e '.kind=="retro_done" and .pr=="51" and .repo=="dotclaude" and .rc==0 and (.created_at|type=="string")' >/dev/null 2>&1 \
  && _pass || _fail "AC7d PR51 → retro_done pr/repo/created_at/rc=0 jq-parseable (got: $last_done)"

# =============================================================================
# AC8 — idempotência: 2ª execução pós-retro_done → zero retros, "nada vencido"
# =============================================================================
REM="$TMP/rem-ac8.jsonl"
echo '{"pr":"60","repo":"dotclaude","retro_due_at":"2026-05-25T00-00-00Z"}' > "$REM"
LOG="$TMP/log.ac8a"; : > "$LOG"
run env RRD_REMINDERS="$REM" RRD_CALLLOG="$LOG" bash "$RRD" >/dev/null 2>&1
assert_count "$(cat "$LOG")" "^claude " "1" "AC8a 1ª execução roda 1 retro"
LOG="$TMP/log.ac8b"; : > "$LOG"
OUT=$(run env RRD_REMINDERS="$REM" RRD_CALLLOG="$LOG" bash "$RRD" 2>&1); rc=$?
assert_rc "$rc" "0" "AC8b 2ª execução exit 0"
assert_count "$(cat "$LOG")" "^claude " "0" "AC8c 2ª execução roda zero retros"
assert_grep "$OUT" "nada vencido" "AC8d 2ª execução loga 'nada vencido'"

# =============================================================================
# Hotfix pós-merge #55 — resolução do binário timeout (macOS não tem GNU timeout)
# =============================================================================
# Execução real no laptop: "timeout: command not found" rc=127 → retro_attempt
# espúrio. Cadeia esperada sem RRD_TIMEOUT: timeout → gtimeout → vazio (roda o
# claude SEM teto, com aviso em stderr). Controlamos via PATH restrito.
NEED=$(mktemp -d "$TMP/needbin.XXXXXX")
for b in bash env date jq mktemp awk grep sed sort wc tr basename dirname cat head tail uniq; do
  p=$(command -v "$b") && ln -s "$p" "$NEED/$b"
done

# (a) nem timeout nem gtimeout no PATH → claude roda direto + aviso, retro_done gravado
REM="$TMP/rem-tofix-a.jsonl"
printf '{"kind":"baseline","pr":"20","repo":"dotclaude","retro_due_at":"2026-05-25T03-15-17Z","created_at":"x"}\n' > "$REM"
LOG="$TMP/log.tofix-a"; : > "$LOG"
OUT=$(env PATH="$NEED" RRD_NOW="$NOW" RRD_CLAUDE="$CLAUDE_STUB" RRD_CALLLOG="$LOG" \
      RRD_REMINDERS="$REM" RRD_PROJECTS_DIR="$PROJ" bash "$RRD" --max 1 2>&1); rc=$?
assert_rc "$rc" "0" "TOFIX-a sem timeout/gtimeout → exit 0"
assert_grep "$(cat "$LOG")" "^claude -p /reflect 20 --retro" "TOFIX-b claude invocado DIRETO (sem prefixo timeout)"
assert_count "$(cat "$LOG")" "^timeout " "0" "TOFIX-c nenhum timeout no call-log"
assert_grep "$OUT" "[Ss]em teto" "TOFIX-d aviso de execução sem teto"
assert_grep "$(tail -1 "$REM")" "retro_done" "TOFIX-e retro_done gravado (não attempt rc=127)"

# (b) só gtimeout no PATH → usado como fallback
GT="$TMP/gtimeout-bin"; mkdir -p "$GT"
cat > "$GT/gtimeout" <<EOF
#!/usr/bin/env bash
echo "gtimeout \$*" >> "\$RRD_CALLLOG"
shift
exec "\$@"
EOF
chmod +x "$GT/gtimeout"
REM="$TMP/rem-tofix-b.jsonl"
printf '{"kind":"baseline","pr":"20","repo":"dotclaude","retro_due_at":"2026-05-25T03-15-17Z","created_at":"x"}\n' > "$REM"
LOG="$TMP/log.tofix-b"; : > "$LOG"
OUT=$(env PATH="$NEED:$GT" RRD_NOW="$NOW" RRD_CLAUDE="$CLAUDE_STUB" RRD_CALLLOG="$LOG" \
      RRD_REMINDERS="$REM" RRD_PROJECTS_DIR="$PROJ" bash "$RRD" --max 1 2>&1); rc=$?
assert_rc "$rc" "0" "TOFIX-f com gtimeout → exit 0"
assert_grep "$(cat "$LOG")" "^gtimeout 900 " "TOFIX-g gtimeout usado com 900"

# =============================================================================
# US-06 — flag --model na etapa /reflect (default: modelo padrão do Claude Code,
# SEM --model no argv; override CLI > env)
# =============================================================================
# AC1 — invocação default NÃO contém `--model` no argv (usa o default do Claude
#       Code); capture-proof: assert positivo de "^claude " prova que o stub
#       rodou co-presente, então a ausência de --model é real, não arquivo vazio.
REM="$TMP/rem-model.jsonl"
echo '{"pr":"70","repo":"dotclaude","retro_due_at":"2026-05-26T00-00-00Z"}' > "$REM"
LOG="$TMP/log.model"; : > "$LOG"
OUT=$(run env RRD_REMINDERS="$REM" RRD_CALLLOG="$LOG" bash "$RRD" 2>&1); rc=$?
assert_rc "$rc" "0" "US06-AC1a exit 0"
assert_count "$(cat "$LOG")" "^claude " "1" "US06-AC1b capture-proof: stub claude rodou (co-presente)"
assert_nogrep "$(cat "$LOG")" "claude .*--model" "US06-AC1c default SEM --model no argv (modelo padrão do Claude Code)"

# AC2 — --model custom respeitado no argv; substitui o default
REM="$TMP/rem-model2.jsonl"
echo '{"pr":"71","repo":"dotclaude","retro_due_at":"2026-05-26T00-00-00Z"}' > "$REM"
LOG="$TMP/log.model2"; : > "$LOG"
OUT=$(run env RRD_REMINDERS="$REM" RRD_CALLLOG="$LOG" bash "$RRD" --model claude-opus-4-8 2>&1); rc=$?
assert_rc "$rc" "0" "US06-AC2a --model custom exit 0"
assert_grep "$(cat "$LOG")" "claude .*--model claude-opus-4-8" "US06-AC2b --model custom respeitado no argv"
assert_count "$(cat "$LOG")" "claude .*--model" "1" "US06-AC2c só o --model custom aparece (default não injeta outro)"

# AC2 — --model sem valor → usage em stderr + exit != 0 (antes de qualquer exec)
ERR=$(bash "$RRD" --model 2>&1 >/dev/null); rc=$?
[ "$rc" != 0 ] && _pass || _fail "US06-AC2d --model sem valor → exit != 0 (rc=$rc)"
assert_grep "$ERR" "[Uu]so|[Uu]sage" "US06-AC2e --model sem valor → usage em stderr"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then
  echo "Failed tests:$FAILED"
  exit 1
fi
exit 0

#!/usr/bin/env bash
set -u

# test_usage_log.sh — testes para bin/lib/usage-log.sh (US-01).
#
# Cobre os 5 acceptance criteria da story "Writer de eventos + machine-id + schema v1":
#   AC1 — log_event <kind> <dod_id> --sha <S> faz append de EXATAMENTE 1 linha
#         JSONL em <home>/telemetry/<prefix>-usage.<machine-id>.jsonl (path
#         absoluto; cria o arquivo se ausente). Default prefix=dod; --prefix override.
#   AC2 — machine-id lido de <home>/.machine-id; gerado via uuidgen se ausente e
#         persistido; idempotente (2a invocação reusa o mesmo id); nunca hostname.
#   AC3 — schema v1: v=1, ts (ISO-8601 UTC), machine, dod_id, kind, sha;
#         eventos baseline carregam count.
#   AC4 — atomicidade: 2 processos concorrentes × 5000 appends → 10000 linhas,
#         0 malformadas (regressão da suposição S1).
#   AC5 — o writer NUNCA reescreve o arquivo (somente >> append).
#
# Estratégia: tudo em tmpdir; USAGE_LOG_HOME aponta para sandbox (não polui ~/.claude).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="$(cd "$SCRIPT_DIR/.." && pwd)/lib/usage-log.sh"

PASS=0; FAIL=0; FAILED=""
_fail() { FAIL=$((FAIL+1)); FAILED="${FAILED}
  ✗ $1"; }
_pass() { PASS=$((PASS+1)); }

assert_eq()       { [ "$1" = "$2" ] && _pass || _fail "$3 :: expected '$2' got '$1'"; }
assert_ne()       { [ "$1" != "$2" ] && _pass || _fail "$3 :: expected NOT '$2' but got it"; }
assert_rc()       { [ "$1" = "$2" ] && _pass || _fail "$3 :: expected rc=$2 got rc=$1"; }
assert_match()    { case "$1" in $2) _pass ;; *) _fail "$3 :: '$1' não casa com '$2'";; esac; }

[[ -f "$TARGET" ]] || { echo "FAIL: $TARGET inexistente" >&2; exit 1; }

TMP="$(mktemp -d -t usage-log.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
HOME_DIR="$TMP/home"

# ─── AC2 — machine-id: gerado, persistido, idempotente, não-hostname ────────
MID1="$(USAGE_LOG_HOME="$HOME_DIR" bash -c "source '$TARGET'; _usage_log_machine_id")"
MID2="$(USAGE_LOG_HOME="$HOME_DIR" bash -c "source '$TARGET'; _usage_log_machine_id")"

# arquivo persistido
if [ -s "$HOME_DIR/.machine-id" ]; then _pass
else _fail "AC2: <home>/.machine-id não foi persistido"; fi
# idempotente: 2a chamada reusa o mesmo id
assert_eq "$MID1" "$MID2" "AC2 idempotente (mesmo id em 2 invocações)"
# formato uuid (8-4-4-4-12 hex)
assert_match "$MID1" "????????-????-????-????-????????????" "AC2 machine-id tem formato uuid"
# nunca hostname
assert_ne "$MID1" "$(hostname)"   "AC2 machine-id != hostname"
assert_ne "$MID1" "$(hostname -s 2>/dev/null || hostname)" "AC2 machine-id != hostname -s"

# ─── AC1 — append de 1 linha; cria arquivo; path absoluto; prefix default/override
LOGFILE="$HOME_DIR/telemetry/dod-usage.$MID1.jsonl"
# arquivo ainda não existe
[ ! -f "$LOGFILE" ] && _pass || _fail "AC1 pré-condição: logfile não deveria existir ainda"

USAGE_LOG_HOME="$HOME_DIR" bash -c "source '$TARGET'; log_event use tarefa-7 --sha abc123"
RC=$?
assert_rc "$RC" 0 "AC1 log_event use exit 0"
# arquivo criado
[ -f "$LOGFILE" ] && _pass || _fail "AC1: logfile não foi criado em $LOGFILE"
# exatamente 1 linha
assert_eq "$(wc -l < "$LOGFILE" | tr -d ' ')" "1" "AC1 exatamente 1 linha após 1 evento"

# 2o evento → exatamente 2 linhas (append, não overwrite)
USAGE_LOG_HOME="$HOME_DIR" bash -c "source '$TARGET'; log_event revision tarefa-7 --sha def456"
assert_eq "$(wc -l < "$LOGFILE" | tr -d ' ')" "2" "AC1 append acumula (2 linhas)"

# prefix override → arquivo distinto test-spec-usage.<mid>.jsonl
USAGE_LOG_HOME="$HOME_DIR" bash -c "source '$TARGET'; log_event use tarefa-9 --sha aaa --prefix test-spec"
SPECLOG="$HOME_DIR/telemetry/test-spec-usage.$MID1.jsonl"
[ -f "$SPECLOG" ] && _pass || _fail "AC1: --prefix test-spec não criou $SPECLOG"

# sha obrigatório → sem --sha falha (rc != 0)
USAGE_LOG_HOME="$HOME_DIR" bash -c "source '$TARGET'; log_event use tarefa-7" 2>/dev/null
assert_ne "$?" "0" "AC1/Adv#2 --sha obrigatório (falha sem sha)"

# Adv P1 (regressão): flag de valor SEM valor (último arg) NÃO deve travar em
# loop infinito — deve falhar rápido com rc!=0. Watchdog mata em 3s se travar
# (RC=137 = SIGKILL → bug presente). Cobre --sha/--prefix/--count/--migrated-from/--ts.
for FLAG in --sha --prefix --count --migrated-from --ts; do
  ( USAGE_LOG_HOME="$HOME_DIR" bash -c "source '$TARGET'; log_event use tarefa-7 --sha abc $FLAG" >/dev/null 2>&1 ) &
  HANGPID=$!
  ( sleep 3; kill -9 "$HANGPID" 2>/dev/null ) & WD=$!
  if wait "$HANGPID" 2>/dev/null; then HRC=0; else HRC=$?; fi
  kill "$WD" 2>/dev/null; wait "$WD" 2>/dev/null
  assert_ne "$HRC" "0"   "Adv P1 $FLAG sem valor falha (rc!=0)"
  assert_ne "$HRC" "137" "Adv P1 $FLAG sem valor NÃO trava (watchdog não disparou)"
done

# kind inválido → falha
USAGE_LOG_HOME="$HOME_DIR" bash -c "source '$TARGET'; log_event bogus tarefa-7 --sha x" 2>/dev/null
assert_ne "$?" "0" "AC3 kind inválido rejeitado"

# ─── AC3 — schema v1 do evento use ──────────────────────────────────────────
L1="$(sed -n '1p' "$LOGFILE")"
echo "$L1" > "$TMP/l1.json"
if jq -e . "$TMP/l1.json" >/dev/null 2>&1; then _pass
else _fail "AC3: linha 1 não é JSON válido :: $L1"; fi
assert_eq "$(jq -r '.v'       "$TMP/l1.json")" "1"        "AC3 v=1"
assert_eq "$(jq -r '.machine' "$TMP/l1.json")" "$MID1"    "AC3 machine == machine-id"
assert_eq "$(jq -r '.dod_id'  "$TMP/l1.json")" "tarefa-7" "AC3 dod_id"
assert_eq "$(jq -r '.kind'    "$TMP/l1.json")" "use"      "AC3 kind=use"
assert_eq "$(jq -r '.sha'     "$TMP/l1.json")" "abc123"   "AC3 sha preservado"
# ts ISO-8601 UTC (termina em Z, formato YYYY-MM-DDThh:mm:ssZ)
TS="$(jq -r '.ts' "$TMP/l1.json")"
assert_match "$TS" "????-??-??T??:??:??Z" "AC3 ts ISO-8601 UTC (sufixo Z)"

# baseline carrega count
USAGE_LOG_HOME="$HOME_DIR" bash -c "source '$TARGET'; log_event baseline tarefa-7 --sha abc123 --count 5"
BL="$(grep '"kind":"baseline"' "$LOGFILE" | head -1)"
echo "$BL" > "$TMP/bl.json"
assert_eq "$(jq -r '.kind'  "$TMP/bl.json")" "baseline" "AC3 baseline kind"
assert_eq "$(jq -r '.count' "$TMP/bl.json")" "5"        "AC3 baseline carrega count"
# baseline sem count → falha
USAGE_LOG_HOME="$HOME_DIR" bash -c "source '$TARGET'; log_event baseline tarefa-7 --sha abc123" 2>/dev/null
assert_ne "$?" "0" "AC3 baseline exige count"

# ─── AC5 — NUNCA reescreve (só append): sentinela sobrevive ─────────────────
SENT="$HOME_DIR/telemetry/dod-usage.$MID1.jsonl"
LINES_BEFORE="$(wc -l < "$SENT" | tr -d ' ')"
FIRST_BEFORE="$(sed -n '1p' "$SENT")"
USAGE_LOG_HOME="$HOME_DIR" bash -c "source '$TARGET'; log_event use tarefa-7 --sha zzz"
LINES_AFTER="$(wc -l < "$SENT" | tr -d ' ')"
FIRST_AFTER="$(sed -n '1p' "$SENT")"
assert_eq "$LINES_AFTER" "$((LINES_BEFORE + 1))" "AC5 append soma exatamente 1 linha"
assert_eq "$FIRST_AFTER" "$FIRST_BEFORE" "AC5 linha 1 (histórico) intacta após novo evento"
# estrutural: writer só usa >> (append), nunca truncating redirect no logfile
if grep -qE '>>[[:space:]]*"\$(log)?file"|>>[[:space:]]*"\$logfile"' "$TARGET"; then _pass
else _fail "AC5 estrutural: nenhum append (>>) ao logfile encontrado em $TARGET"; fi
if grep -qE '[^>]>[[:space:]]*"\$logfile"' "$TARGET"; then
  _fail "AC5 estrutural: redirect truncante (>) ao logfile encontrado em $TARGET"
else _pass; fi

# ─── AC4 — atomicidade: 2 procs × 5000 appends → 10000 linhas, 0 malformadas ─
ATOMIC_MID="$MID1"
ATOMIC_LOG="$HOME_DIR/telemetry/atomictest-usage.$ATOMIC_MID.jsonl"
rm -f "$ATOMIC_LOG"
N=5000
cat > "$TMP/worker.sh" <<EOF
#!/usr/bin/env bash
source "$TARGET"
for ((i=0; i<$N; i++)); do
  log_event use tarefa-atomic --sha deadbeef --prefix atomictest
done
EOF
chmod +x "$TMP/worker.sh"

USAGE_LOG_HOME="$HOME_DIR" "$TMP/worker.sh" &
P1=$!
USAGE_LOG_HOME="$HOME_DIR" "$TMP/worker.sh" &
P2=$!
wait "$P1"; wait "$P2"

NLINES="$(wc -l < "$ATOMIC_LOG" | tr -d ' ')"
assert_eq "$NLINES" "$((N * 2))" "AC4 exatamente $((N*2)) linhas (2×$N appends concorrentes)"
# 0 malformadas: jq slurp deve contar exatamente 10000 objetos válidos
NOBJ="$(jq -s 'length' "$ATOMIC_LOG" 2>/dev/null || echo -1)"
assert_eq "$NOBJ" "$((N * 2))" "AC4 jq slurp: $((N*2)) objetos JSON válidos (0 malformadas)"

# ─── Summary ────────────────────────────────────────────────────────────────
TOTAL=$((PASS + FAIL))
echo ""
echo "─── Resultado: $PASS/$TOTAL pass ──────────────────"
if [ "$FAIL" -gt 0 ]; then
  printf '%s\n' "$FAILED"
  exit 1
fi
exit 0

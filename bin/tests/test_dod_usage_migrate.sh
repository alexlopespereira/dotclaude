#!/usr/bin/env bash
set -u

# test_dod_usage_migrate.sh — testes para bin/dod-usage-migrate.sh (US-03).
#
# Cobre os 6 acceptance criteria da story "Migracao seeder + strip inline +
# remocao do snapshot":
#   AC1 — por DoD: 1 baseline {count} + 1 revision (+ desde_rev eventos use).
#   AC2 — idempotente: rodar 2x não duplica baseline (flag migrated_from).
#   AC3 — reconcilia max() entre o DOD.md do repo, o install em $(_usage_log_home)
#         e --reconcile-extra antes de semear (não perde deriva in-flight).
#   AC4 — pós-seed os headings ficam SEM o sufixo `(usos: N · desde rev: N)`.
#   AC5 — o fold (US-02) pós-migração reproduz EXATAMENTE os contadores inline
#         pré-migração (equivalência por dod_id) — inclusive usos≠desde_rev.
#   AC6 — o snapshot .json é removido.
# + Extensão do writer (usage-log.sh): --migrated-from anexa o campo; --ts
#   sobrescreve o ts; sem os flags o evento fica byte-idêntico ao schema v1.
#
# Estratégia: tudo em tmpdir; USAGE_LOG_HOME aponta p/ sandbox (controla onde o
# log é escrito E onde o install é procurado p/ reconcile); --dod-file/--state-file
# apontam p/ fixtures — NUNCA toca o repo real nem o ~/.claude real.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MIGRATE="$BIN_DIR/dod-usage-migrate.sh"
FOLD="$BIN_DIR/lib/usage-fold.sh"
LOG="$BIN_DIR/lib/usage-log.sh"

PASS=0; FAIL=0; FAILED=""
_fail() { FAIL=$((FAIL+1)); FAILED="${FAILED}
  ✗ $1"; }
_pass() { PASS=$((PASS+1)); }
assert_eq()    { [ "$1" = "$2" ] && _pass || _fail "$3 :: expected '$2' got '$1'"; }
assert_ne()    { [ "$1" != "$2" ] && _pass || _fail "$3 :: expected NOT '$2' but got it"; }

[ -f "$MIGRATE" ] || { echo "FAIL: $MIGRATE inexistente" >&2; exit 1; }

TMP="$(mktemp -d -t dod-migrate-test.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# Fixture DOD.md com a distribuição-chave: usos==desde_rev, usos≠desde_rev,
# zerado, e um título com parênteses internos (caso tarefa-17 do DOD.md real).
make_fixture() {
  local f="$1"
  printf '%s\n' \
    '# Fixture DOD' \
    '' \
    '## Categoria 1 — Test' \
    '' \
    '### DoD-base — Categoria 1 (usos: 3 · desde rev: 3)' \
    '- [ ] [b1] foo base' \
    '- [ ] [b2] bar base' \
    '' \
    '### Tarefa 1 — Exemplo um (usos: 5 · desde rev: 2)' \
    '- [ ] [b1] alpha' \
    '' \
    '### Tarefa 7 — Tema (`www.exemplo.com.br`) (usos: 1 · desde rev: 1)' \
    '- [ ] [b1] beta' \
    '- [ ] [b2] gamma' \
    '' \
    '### Tarefa 2 — Zerado (usos: 0 · desde rev: 0)' \
    '- [ ] [b1] delta' \
    > "$f"
}

# Snapshot .json (last_seen_iso por id; sem contadores — como o real).
make_state() {
  cat > "$1" <<'EOF'
{
  "tarefa-1": { "bullets_sha256": "x", "last_seen_iso": "2026-05-10T00:00:00Z", "slug": "t1", "title_current": "Exemplo um" }
}
EOF
}

# ─── Caso base: REAL RUN num sandbox ─────────────────────────────────────────
H1="$TMP/h1"; mkdir -p "$H1"
FIX1="$TMP/repo1/DOD.md"; mkdir -p "$TMP/repo1"; make_fixture "$FIX1"
STATE1="$TMP/repo1/.state.json"; make_state "$STATE1"

# Contadores inline ANTES da migração (oráculo da equivalência AC5).
INLINE_PRE="$(awk '
  BEGIN{cc=""}
  /^## Categoria [0-9]+ — /{s=$0;sub(/^## Categoria /,"",s);sub(/ .*$/,"",s);cc=s;next}
  /^### DoD-base — Categoria [0-9]+ \(usos: [0-9]+ · desde rev: [0-9]+\)$/{
    match($0,/usos: [0-9]+/);u=substr($0,RSTART+6,RLENGTH-6)
    match($0,/desde rev: [0-9]+/);r=substr($0,RSTART+11,RLENGTH-11)
    printf "cat-%s-base\t%s\t%s\n",cc,u,r;next}
  /^### Tarefa [0-9]+ — .+ \(usos: [0-9]+ · desde rev: [0-9]+\)$/{
    s=$0;sub(/^### Tarefa /,"",s);sub(/ .*$/,"",s)
    match($0,/usos: [0-9]+/);u=substr($0,RSTART+6,RLENGTH-6)
    match($0,/desde rev: [0-9]+/);r=substr($0,RSTART+11,RLENGTH-11)
    printf "tarefa-%s\t%s\t%s\n",s,u,r;next}
' "$FIX1" | LC_ALL=C sort)"

USAGE_LOG_HOME="$H1" bash "$MIGRATE" --prefix dod --dod-file "$FIX1" --state-file "$STATE1" >/dev/null 2>&1
RC=$?
assert_eq "$RC" "0" "migrate real run → exit 0"

LOGFILE1="$(find "$H1/telemetry" -name 'dod-usage.*.jsonl' 2>/dev/null | head -1)"
assert_ne "$LOGFILE1" "" "AC1 log per-machine criado"

# AC1 — por DoD exatamente 1 baseline e 1 revision; #use == desde_rev.
for id in cat-1-base tarefa-1 tarefa-7 tarefa-2; do
  nb="$(jq -s --arg i "$id" '[.[]|select(.dod_id==$i and .kind=="baseline")]|length' "$LOGFILE1")"
  nrev="$(jq -s --arg i "$id" '[.[]|select(.dod_id==$i and .kind=="revision")]|length' "$LOGFILE1")"
  assert_eq "$nb" "1" "AC1 $id → exatamente 1 baseline"
  assert_eq "$nrev" "1" "AC1 $id → exatamente 1 revision"
done
# tarefa-1: desde_rev=2 → 2 eventos use; baseline.count = usos-desde_rev = 3.
nuse_t1="$(jq -s '[.[]|select(.dod_id=="tarefa-1" and .kind=="use")]|length' "$LOGFILE1")"
bc_t1="$(jq -s '[.[]|select(.dod_id=="tarefa-1" and .kind=="baseline")][0].count' "$LOGFILE1")"
assert_eq "$nuse_t1" "2" "AC1 tarefa-1 → 2 eventos use (=desde_rev)"
assert_eq "$bc_t1" "3" "AC1 tarefa-1 → baseline.count = usos-desde_rev = 3"

# AC4 — headings sem sufixo; título com parênteses internos preservado.
assert_eq "$(grep -c ' (usos: ' "$FIX1")" "0" "AC4 nenhum sufixo (usos:...) remanescente"
assert_eq "$(grep -c '^### Tarefa 7 — Tema (`www.exemplo.com.br`)$' "$FIX1")" "1" \
  "AC4 título com parênteses internos preservado (só o sufixo removido)"

# AC6 — snapshot removido.
[ -f "$STATE1" ] && _fail "AC6 snapshot ainda existe" || _pass

# AC5 — equivalência: fold pós-migração == contadores inline pré-migração (id,usos,desde_rev).
FOLD_OUT="$(USAGE_LOG_HOME="$H1" bash "$FOLD" --prefix dod --dod-file "$FIX1" | awk -F'\t' '{print $1"\t"$2"\t"$3}' | LC_ALL=C sort)"
assert_eq "$FOLD_OUT" "$INLINE_PRE" "AC5 fold reproduz EXATAMENTE os contadores inline (por dod_id)"

# AC5 (sub) — last_seen preservado p/ tarefa-1 (do snapshot), não migration-time.
LS_T1="$(USAGE_LOG_HOME="$H1" bash "$FOLD" --prefix dod --dod-file "$FIX1" | awk -F'\t' '$1=="tarefa-1"{print $4}')"
assert_eq "$LS_T1" "2026-05-10T00:00:00Z" "AC5 last_seen de tarefa-1 vem do snapshot (reconcile .json)"

# ─── AC2 — idempotência: 2a run não duplica baseline ─────────────────────────
nb_before="$(grep -c '"kind":"baseline"' "$LOGFILE1")"
USAGE_LOG_HOME="$H1" bash "$MIGRATE" --prefix dod --dod-file "$FIX1" --state-file "$STATE1" >/dev/null 2>&1
nb_after="$(grep -c '"kind":"baseline"' "$LOGFILE1")"
assert_eq "$nb_after" "$nb_before" "AC2 2a run não adiciona baseline (idempotente)"
# Fold continua idêntico após 2a run.
FOLD_OUT2="$(USAGE_LOG_HOME="$H1" bash "$FOLD" --prefix dod --dod-file "$FIX1" | awk -F'\t' '{print $1"\t"$2"\t"$3}' | LC_ALL=C sort)"
assert_eq "$FOLD_OUT2" "$INLINE_PRE" "AC2 fold idêntico após 2a run"

# ─── AC3 — reconcile max() com install acessível (auto-detect via _usage_log_home)
H3="$TMP/h3"; mkdir -p "$H3"
FIX3="$TMP/repo3/DOD.md"; mkdir -p "$TMP/repo3"; make_fixture "$FIX3"
STATE3="$TMP/repo3/.state.json"; make_state "$STATE3"
# Install drift: MESMO rel path do prefix dod sob o USAGE_LOG_HOME, com usos maior.
INST_DIR="$H3/skills/auto-grill-me/references"; mkdir -p "$INST_DIR"
# tarefa-1 com usos=9/desde rev=4 no install (deriva in-flight não sincronizada).
sed 's/Tarefa 1 — Exemplo um (usos: 5 · desde rev: 2)/Tarefa 1 — Exemplo um (usos: 9 · desde rev: 4)/' "$FIX3" > "$INST_DIR/DOD.md"
USAGE_LOG_HOME="$H3" bash "$MIGRATE" --prefix dod --dod-file "$FIX3" --state-file "$STATE3" >/dev/null 2>&1
T1_USOS="$(USAGE_LOG_HOME="$H3" bash "$FOLD" --prefix dod --dod-file "$FIX3" | awk -F'\t' '$1=="tarefa-1"{print $2}')"
T1_REV="$(USAGE_LOG_HOME="$H3" bash "$FOLD" --prefix dod --dod-file "$FIX3" | awk -F'\t' '$1=="tarefa-1"{print $3}')"
assert_eq "$T1_USOS" "9" "AC3 reconcile max usos (install 9 > repo 5) → 9"
assert_eq "$T1_REV" "4" "AC3 reconcile max desde_rev (install 4 > repo 2) → 4"

# AC3 (sub) — --reconcile-extra também entra no max().
H3b="$TMP/h3b"; mkdir -p "$H3b"
FIX3b="$TMP/repo3b/DOD.md"; mkdir -p "$TMP/repo3b"; make_fixture "$FIX3b"
EXTRA="$TMP/repo3b/EXTRA.md"
sed 's/Tarefa 2 — Zerado (usos: 0 · desde rev: 0)/Tarefa 2 — Zerado (usos: 7 · desde rev: 0)/' "$FIX3b" > "$EXTRA"
# --state-file aponta p/ tmp (inexistente) — mantém hermético (nunca toca o repo real).
USAGE_LOG_HOME="$H3b" bash "$MIGRATE" --prefix dod --dod-file "$FIX3b" \
  --state-file "$TMP/repo3b/.state.json" --reconcile-extra "$EXTRA" >/dev/null 2>&1
T2_USOS="$(USAGE_LOG_HOME="$H3b" bash "$FOLD" --prefix dod --dod-file "$FIX3b" | awk -F'\t' '$1=="tarefa-2"{print $2}')"
assert_eq "$T2_USOS" "7" "AC3 --reconcile-extra entra no max (tarefa-2: 0 repo, 7 extra → 7)"

# ─── prefix test-spec (US-06) — strip de TEST-PATTERNS + rm do .test-spec json +
#     EQUIVALÊNCIA (US-06 AC2): o seeder test-spec reusa as MESMAS libs M1/M2 com
#     --prefix test-spec; o fold pós-migração reproduz EXATAMENTE os contadores
#     que estavam inline pré-migração (espelha a equivalência dod AC5). ──────────
H4="$TMP/h4"; mkdir -p "$H4"
TP="$TMP/repo4/TEST-PATTERNS.md"; mkdir -p "$TMP/repo4"; make_fixture "$TP"
TPSTATE="$TMP/repo4/.test-spec-revision-state.json"; make_state "$TPSTATE"

# Oráculo: contadores inline de TEST-PATTERNS ANTES da migração (a migração
# strippa $TP, então captura tem de ser pré-migrate). Mesma awk do oráculo dod.
INLINE_PRE_TS="$(awk '
  BEGIN{cc=""}
  /^## Categoria [0-9]+ — /{s=$0;sub(/^## Categoria /,"",s);sub(/ .*$/,"",s);cc=s;next}
  /^### DoD-base — Categoria [0-9]+ \(usos: [0-9]+ · desde rev: [0-9]+\)$/{
    match($0,/usos: [0-9]+/);u=substr($0,RSTART+6,RLENGTH-6)
    match($0,/desde rev: [0-9]+/);r=substr($0,RSTART+11,RLENGTH-11)
    printf "cat-%s-base\t%s\t%s\n",cc,u,r;next}
  /^### Tarefa [0-9]+ — .+ \(usos: [0-9]+ · desde rev: [0-9]+\)$/{
    s=$0;sub(/^### Tarefa /,"",s);sub(/ .*$/,"",s)
    match($0,/usos: [0-9]+/);u=substr($0,RSTART+6,RLENGTH-6)
    match($0,/desde rev: [0-9]+/);r=substr($0,RSTART+11,RLENGTH-11)
    printf "tarefa-%s\t%s\t%s\n",s,u,r;next}
' "$TP" | LC_ALL=C sort)"

USAGE_LOG_HOME="$H4" bash "$MIGRATE" --prefix test-spec --dod-file "$TP" --state-file "$TPSTATE" >/dev/null 2>&1
assert_eq "$(grep -c ' (usos: ' "$TP")" "0" "AC3 prefix test-spec → TEST-PATTERNS sem sufixo"
[ -f "$TPSTATE" ] && _fail "AC3 .test-spec snapshot ainda existe" || _pass
# Isolamento de prefix no nome do log.
[ -n "$(find "$H4/telemetry" -name 'test-spec-usage.*.jsonl' 2>/dev/null)" ] && _pass \
  || _fail "AC1 prefix test-spec escreve em test-spec-usage.*.jsonl"
[ -z "$(find "$H4/telemetry" -name 'dod-usage.*.jsonl' 2>/dev/null)" ] && _pass \
  || _fail "AC1 prefix test-spec NÃO escreve em dod-usage.*"

# AC2 (US-06) — equivalência: fold test-spec pós-migração == inline pré-migração.
FOLD_TS="$(USAGE_LOG_HOME="$H4" bash "$FOLD" --prefix test-spec --dod-file "$TP" \
  | awk -F'\t' '{print $1"\t"$2"\t"$3}' | LC_ALL=C sort)"
assert_eq "$FOLD_TS" "$INLINE_PRE_TS" "AC2 fold test-spec reproduz EXATAMENTE os contadores inline (por spec_id)"

# ─── Extensão do writer usage-log.sh ─────────────────────────────────────────
# --migrated-from anexa o campo; --ts sobrescreve; sem flags = schema v1 puro.
HW="$TMP/hw"; mkdir -p "$HW"
USAGE_LOG_HOME="$HW" bash "$LOG" use tarefa-1 --sha abc123 --migrated-from inline --ts 2026-01-02T03:04:05Z
LW="$(find "$HW/telemetry" -name 'dod-usage.*.jsonl' | head -1)"
assert_eq "$(jq -r '.migrated_from' "$LW")" "inline" "writer --migrated-from → campo migrated_from"
assert_eq "$(jq -r '.ts' "$LW")" "2026-01-02T03:04:05Z" "writer --ts sobrescreve o timestamp"
assert_eq "$(jq -r '.kind' "$LW")" "use" "writer evento use bem-formado com flags"

HW2="$TMP/hw2"; mkdir -p "$HW2"
USAGE_LOG_HOME="$HW2" bash "$LOG" use tarefa-9 --sha deadbeef
LW2="$(find "$HW2/telemetry" -name 'dod-usage.*.jsonl' | head -1)"
assert_eq "$(jq -r 'has("migrated_from")' "$LW2")" "false" "writer sem --migrated-from → schema v1 puro (sem campo extra)"

# --ts inválido → erro de uso (fail-closed).
HW3="$TMP/hw3"; mkdir -p "$HW3"
USAGE_LOG_HOME="$HW3" bash "$LOG" use t --sha a --ts "naoiso" >/dev/null 2>&1
assert_ne "$?" "0" "writer --ts inválido → exit != 0 (fail-closed)"

# ─── Summary ─────────────────────────────────────────────────────────────────
TOTAL=$((PASS + FAIL))
echo ""
echo "─── Resultado: $PASS/$TOTAL pass ──────────────────"
if [ "$FAIL" -gt 0 ]; then
  printf '%s\n' "$FAILED"
  exit 1
fi
exit 0

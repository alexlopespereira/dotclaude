#!/usr/bin/env bash
# test_parallelism_report.sh — testes para bin/parallelism-report.sh (US-01).
#
# Mede aderência ao Princípio 9 (paralelização de tool_use). O fato central do
# formato de transcript: tool calls PARALELAS da mesma resposta da API
# compartilham message.id mas ocupam LINHAS separadas no jsonl (cada linha tem 1
# bloco tool_use). Contar por linha dá 0% falso — é preciso agrupar por
# message.id. Verificado empiricamente nos transcripts reais antes de escrever.
#
# Cobre os acceptance criteria automatizáveis:
#   AC1 — fixture com 3 mensagens-API com tool_use (1 com 2 tool_use em linhas
#         separadas compartilhando message.id) → relatório acusa 1/3 (33%).
#   AC2 — isSidechain true excluído por default; --include-sidechains inclui.
#   AC3 — tool_use sem message.id → bucket 'unknown' reportado explicitamente.
#   AC4 — --since N filtra por mtime; --project <substring> filtra por diretório.
#   AC5 — args inválidos (flag desconhecida, --since não-num/gigante) → usage
#         em stderr + exit != 0, validação de forma E comprimento antes de
#         aritmética.
#   AC6 — read-only: nenhum arquivo criado/modificado (capture-proof: assert
#         positivo do output co-presente com assert de ausência de writes).
#
# Seam: PR_TRANSCRIPT_DIR aponta a raiz fake dos transcripts.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PR="$REPO_ROOT/bin/parallelism-report.sh"

PASS=0; FAIL=0; FAILED=""
_pass() { PASS=$((PASS+1)); }
_fail() { FAIL=$((FAIL+1)); FAILED="${FAILED}
  ✗ $1"; }
assert_eq()    { [ "$1" = "$2" ] && _pass || _fail "$3 :: expected '$2' got '$1'"; }
assert_grep()  { printf '%s' "$1" | grep -qE -- "$2" && _pass || _fail "$3 :: padrão '$2' ausente em: $1"; }
assert_nogrep(){ printf '%s' "$1" | grep -qE -- "$2" && _fail "$3 :: padrão '$2' NÃO deveria aparecer em: $1" || _pass; }
assert_rc()    { [ "$1" = "$2" ] && _pass || _fail "$3 :: expected rc=$2 got rc=$1"; }

[ -f "$PR" ] || { echo "FAIL: $PR inexistente" >&2; exit 1; }
bash -n "$PR" || { echo "FAIL: bash -n sujo em $PR" >&2; exit 1; }

TMP="$(mktemp -d -t prl.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# ── helpers de fixture ───────────────────────────────────────────────────────
# Linha de tool_use: tu_line <message_id|-> <sidechain true|false> [tool_id]
# id "-" → mensagem SEM message.id (bucket unknown).
tu_line() {
  local mid="$1" side="$2" tid="${3:-tu}"
  if [ "$mid" = "-" ]; then
    printf '{"isSidechain":%s,"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"%s","name":"Bash","input":{}}]}}\n' "$side" "$tid"
  else
    printf '{"isSidechain":%s,"type":"assistant","message":{"id":"%s","role":"assistant","content":[{"type":"tool_use","id":"%s","name":"Bash","input":{}}]}}\n' "$side" "$mid" "$tid"
  fi
}
# Linha de texto (sem tool_use), deve ser ignorada.
text_line() {
  printf '{"isSidechain":false,"type":"assistant","message":{"id":"%s","role":"assistant","content":[{"type":"text","text":"oi"}]}}\n' "$1"
}
# Linha de user/tool_result, ignorada.
user_line() {
  printf '{"isSidechain":false,"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"ok"}]}}\n'
}

agg_field() { # <jsonl_output> <campo> → valor do objeto AGGREGATE
  printf '%s\n' "$1" | jq -rs '.[] | select(.project=="AGGREGATE") | .'"$2"'' 2>/dev/null
}

snapshot_tree() { # <dir> → 1 linha por arquivo: nome + mtime + size
  # Dual GNU-first: GNU `stat -f` interpreta o arg como filesystem e devolve
  # contadores (assert de não-mutação virava vácuo/flake no Linux).
  (cd "$1" && find . -type f -exec sh -c \
    'stat -c "%n %Y %s" "$1" 2>/dev/null || stat -f "%N %m %z" "$1" 2>/dev/null' _ {} \; | sort)
}

echo "=== parallelism-report tests ==="

# =============================================================================
# AC1 — 3 mensagens-API com tool_use, 1 paralela (2 tool_use mesmo id) → 1/3 33%
# =============================================================================
R1="$TMP/ac1"; mkdir -p "$R1/proj-x"
{
  user_line
  tu_line msgA false a1      # mensagem A — paralela: 2 linhas, mesmo id
  tu_line msgA false a2
  text_line msgT             # texto puro, ignorado
  tu_line msgB false b1      # mensagem B — 1 tool_use
  tu_line msgC false c1      # mensagem C — 1 tool_use
} > "$R1/proj-x/s1.jsonl"

OUT=$(PR_TRANSCRIPT_DIR="$R1" bash "$PR" --since 9999 2>&1); rc=$?
assert_rc "$rc" "0" "AC1a exit 0 no caminho feliz"
assert_grep "$OUT" "33%" "AC1b table mostra 33%"

OUTJ=$(PR_TRANSCRIPT_DIR="$R1" bash "$PR" --since 9999 --format jsonl 2>&1)
assert_eq "$(agg_field "$OUTJ" messages)" "3" "AC1c agregado: 3 mensagens com tool_use"
assert_eq "$(agg_field "$OUTJ" parallel)" "1" "AC1d agregado: 1 paralela"
assert_eq "$(agg_field "$OUTJ" unknown)" "0" "AC1e agregado: 0 unknown"

# =============================================================================
# AC2 — isSidechain excluído por default; --include-sidechains inclui
# =============================================================================
R2="$TMP/ac2"; mkdir -p "$R2/proj-y"
{
  tu_line msgM false m1      # main: 1 mensagem não-paralela
  tu_line msgS true s1       # sidechain: paralela (2 linhas mesmo id)
  tu_line msgS true s2
} > "$R2/proj-y/s1.jsonl"

OUTJ=$(PR_TRANSCRIPT_DIR="$R2" bash "$PR" --since 9999 --format jsonl 2>&1)
assert_eq "$(agg_field "$OUTJ" messages)" "1" "AC2a default exclui sidechain (só msgM)"
assert_eq "$(agg_field "$OUTJ" parallel)" "0" "AC2b default: 0 paralelas (sidechain fora)"

OUTJ=$(PR_TRANSCRIPT_DIR="$R2" bash "$PR" --since 9999 --include-sidechains --format jsonl 2>&1)
assert_eq "$(agg_field "$OUTJ" messages)" "2" "AC2c --include-sidechains: msgM + msgS"
assert_eq "$(agg_field "$OUTJ" parallel)" "1" "AC2d --include-sidechains: msgS paralela conta"

# =============================================================================
# AC3 — tool_use sem message.id → bucket 'unknown' reportado explicitamente
# =============================================================================
R3="$TMP/ac3"; mkdir -p "$R3/proj-z"
{
  tu_line msgA false a1
  tu_line - false u1         # sem message.id → unknown
  tu_line - false u2         # sem message.id → unknown
} > "$R3/proj-z/s1.jsonl"

OUT=$(PR_TRANSCRIPT_DIR="$R3" bash "$PR" --since 9999 2>&1)
assert_grep "$OUT" "[Uu]nknown" "AC3a unknown reportado explicitamente no table"
OUTJ=$(PR_TRANSCRIPT_DIR="$R3" bash "$PR" --since 9999 --format jsonl 2>&1)
assert_eq "$(agg_field "$OUTJ" unknown)" "2" "AC3b agregado: 2 tool_use unknown"
assert_eq "$(agg_field "$OUTJ" messages)" "1" "AC3c unknown NÃO entra no denominador de mensagens"

# =============================================================================
# AC4 — --since N (mtime) e --project <substring> (diretório)
# =============================================================================
R4="$TMP/ac4"; mkdir -p "$R4/proj-alpha" "$R4/proj-beta"
tu_line msgPa false pa1 > "$R4/proj-alpha/s.jsonl"   # alpha: recente (mtime=agora)
{ tu_line msgPb false pb1; } > "$R4/proj-beta/s.jsonl"
touch -t 202001010000 "$R4/proj-beta/s.jsonl"        # beta: antigo

# default --since 14: beta (2020) excluído por mtime
OUTJ=$(PR_TRANSCRIPT_DIR="$R4" bash "$PR" --format jsonl 2>&1)
assert_eq "$(agg_field "$OUTJ" messages)" "1" "AC4a --since 14 default exclui beta antigo (mtime)"
assert_nogrep "$OUTJ" "proj-beta" "AC4b beta antigo fora do relatório"

# --since 99999: beta volta
OUTJ=$(PR_TRANSCRIPT_DIR="$R4" bash "$PR" --since 99999 --format jsonl 2>&1)
assert_eq "$(agg_field "$OUTJ" messages)" "2" "AC4c --since grande inclui beta antigo"

# --project alpha: só alpha mesmo com beta recente
touch "$R4/proj-beta/s.jsonl"                        # beta agora recente
OUTJ=$(PR_TRANSCRIPT_DIR="$R4" bash "$PR" --since 9999 --project alpha --format jsonl 2>&1)
assert_grep "$OUTJ" "proj-alpha" "AC4d --project alpha inclui alpha"
assert_nogrep "$OUTJ" "proj-beta" "AC4e --project alpha exclui beta"
assert_eq "$(agg_field "$OUTJ" messages)" "1" "AC4f --project alpha: só 1 mensagem"

# =============================================================================
# AC5 — args inválidos → usage stderr + exit != 0 (forma E comprimento)
# =============================================================================
ERR=$(PR_TRANSCRIPT_DIR="$R1" bash "$PR" --frobnicate 2>&1 >/dev/null); rc=$?
[ "$rc" != 0 ] && _pass || _fail "AC5a flag desconhecida → exit != 0 (rc=$rc)"
assert_grep "$ERR" "[Uu]so|[Uu]sage" "AC5b flag desconhecida → usage em stderr"

ERR=$(PR_TRANSCRIPT_DIR="$R1" bash "$PR" --since abc 2>&1 >/dev/null); rc=$?
[ "$rc" != 0 ] && _pass || _fail "AC5c --since não-numérico → exit != 0 (rc=$rc)"
assert_grep "$ERR" "[Uu]so|[Uu]sage" "AC5d --since não-num → usage"

ERR=$(PR_TRANSCRIPT_DIR="$R1" bash "$PR" --since 999999999999999999999999 2>&1 >/dev/null); rc=$?
[ "$rc" != 0 ] && _pass || _fail "AC5e --since gigante → exit != 0 (rc=$rc, sem virar caminho feliz)"
assert_grep "$ERR" "[Uu]so|[Uu]sage" "AC5f --since gigante → usage"

ERR=$(PR_TRANSCRIPT_DIR="$R1" bash "$PR" --format yaml 2>&1 >/dev/null); rc=$?
[ "$rc" != 0 ] && _pass || _fail "AC5g --format inválido → exit != 0 (rc=$rc)"

ERR=$(PR_TRANSCRIPT_DIR="$R1" bash "$PR" --since 2>&1 >/dev/null); rc=$?
[ "$rc" != 0 ] && _pass || _fail "AC5h --since sem valor → exit != 0 (rc=$rc)"

OUT=$(bash "$PR" --help); rc=$?
assert_rc "$rc" "0" "AC5i --help exit 0"
assert_grep "$OUT" "since|project|format|sidechain" "AC5j help documenta flags"

# =============================================================================
# AC6 — read-only: nenhum arquivo criado/modificado (capture-proof)
# =============================================================================
R6="$TMP/ac6"; mkdir -p "$R6/proj-r"
{ tu_line msgA false a1; tu_line msgA false a2; } > "$R6/proj-r/s.jsonl"
SNAP_BEFORE=$(snapshot_tree "$R6")
OUT=$(PR_TRANSCRIPT_DIR="$R6" bash "$PR" --since 9999 2>&1); rc=$?
SNAP_AFTER=$(snapshot_tree "$R6")
# capture-proof: assert POSITIVO de que o script produziu relatório...
assert_grep "$OUT" "AGGREGATE|TOTAL|proj-r" "AC6a script produziu output (prova que rodou)"
# ...co-presente com assert de AUSÊNCIA de qualquer write (snapshot idêntico).
assert_eq "$SNAP_AFTER" "$SNAP_BEFORE" "AC6b nenhum arquivo criado/modificado (read-only)"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then
  echo "Failed tests:$FAILED"
  exit 1
fi
exit 0

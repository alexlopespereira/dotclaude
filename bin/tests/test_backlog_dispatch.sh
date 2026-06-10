#!/usr/bin/env bash
# test_backlog_dispatch.sh — testes para bin/backlog-dispatch.sh (US-07).
#
# Cobre os acceptance criteria automatizáveis:
#   AC1 — header do script documenta schema/markers/fluxo; --help funciona;
#         stubs claude/git via call-log (TDD escrito antes da implementação).
#   AC2 — human_gate true NUNCA despacha e aparece em seção 'human-gate'
#         (capture-proof: ^claude presente para o item elegível co-presente).
#   AC3 — dedup por markers: marker done → não re-despacha; >=3 failed → skip
#         permanente reportado.
#   AC4 — seleção de slot via BD_POOL_BASE: slot dirty ou fora de main rejeitado;
#         sem slot livre → exit 0 com aviso, sem dispatch.
#   AC5 — lock atômico (mkdir): 2ª instância concorrente termina limpo sem
#         despachar; lock removido ao final do run normal.
#   AC6 — prompt instrui PARAR no PR sem auto-merge; nenhuma invocação no
#         call-log contém 'gh pr merge' (capture-proof).
#   AC7 — --dry-run imprime plano item→slot sem efeitos (sem marker, sem claude);
#         --max N limita o nº de dispatches.
#   AC8 — timeout chain timeout→gtimeout→aviso; RC de timeout (124) → marker failed.
#
# Estratégia: stubs de claude/timeout logam argv+cwd num call-log; slots são
# repos git reais em BD_POOL_BASE com estado controlado (clean+main / dirty /
# branch). Pattern de test_reflect_retro_due.sh.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BD="$REPO_ROOT/bin/backlog-dispatch.sh"

PASS=0; FAIL=0; FAILED=""
_pass() { PASS=$((PASS+1)); }
_fail() { FAIL=$((FAIL+1)); FAILED="${FAILED}
  ✗ $1"; }
assert_eq()    { [ "$1" = "$2" ] && _pass || _fail "$3 :: expected '$2' got '$1'"; }
assert_grep()  { printf '%s' "$1" | grep -qE -- "$2" && _pass || _fail "$3 :: padrão '$2' ausente em: $1"; }
assert_nogrep(){ printf '%s' "$1" | grep -qE -- "$2" && _fail "$3 :: padrão '$2' NÃO deveria aparecer em: $1" || _pass; }
assert_rc()    { [ "$1" = "$2" ] && _pass || _fail "$3 :: expected rc=$2 got rc=$1"; }
assert_count() { local n; n=$(printf '%s\n' "$1" | grep -cE -- "$2"); [ "$n" = "$3" ] && _pass || _fail "$4 :: esperado $3 ocorrências de '$2', obteve $n"; }

[ -f "$BD" ] || { echo "FAIL: $BD inexistente" >&2; exit 1; }
bash -n "$BD" || { echo "FAIL: bash -n sujo em $BD" >&2; exit 1; }

TMP="$(mktemp -d -t bd.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

NOW="2026-06-10T12-00-00Z"

# ── stubs ────────────────────────────────────────────────────────────────────
# claude stub: loga argv + cwd; exit code via CLAUDE_RC (default 0).
CLAUDE_STUB="$TMP/claude.sh"
cat > "$CLAUDE_STUB" <<'EOF'
#!/usr/bin/env bash
{ echo "claude $*"; echo "cwd=$(pwd)"; } >> "$CALLLOG"
exit "${CLAUDE_RC:-0}"
EOF
chmod +x "$CLAUDE_STUB"

# timeout stub: loga "timeout <dur> <cmd...>" e exec o restante (preserva rc).
TIMEOUT_STUB="$TMP/timeout.sh"
cat > "$TIMEOUT_STUB" <<'EOF'
#!/usr/bin/env bash
echo "timeout $*" >> "$CALLLOG"
shift
exec "$@"
EOF
chmod +x "$TIMEOUT_STUB"

# Cria um slot git real. mkrepo <dir> <branch> <clean|dirty>
mkrepo() {
  local d="$1" br="$2" state="$3"
  mkdir -p "$d"
  git -C "$d" init -q -b main 2>/dev/null || { git -C "$d" init -q; git -C "$d" symbolic-ref HEAD refs/heads/main; }
  git -C "$d" config user.email t@t.dev
  git -C "$d" config user.name tester
  echo init > "$d/f"; git -C "$d" add f; git -C "$d" commit -qm init
  if [ "$br" != "main" ]; then git -C "$d" checkout -q -b "$br"; fi
  if [ "$state" = "dirty" ]; then echo change >> "$d/f"; fi
}

# Monta um ambiente {backlog dir, pool base} e ecoa "BLDIR POOL".
mkenv() {
  local id="$1"
  local bldir="$TMP/bl-$id" pool="$TMP/pool-$id"
  mkdir -p "$bldir" "$pool"
  printf '%s %s' "$bldir" "$pool"
}

run() { # roda o script com seams; resto via env do caller
  BD_NOW="$NOW" BD_CLAUDE="$CLAUDE_STUB" BD_TIMEOUT="$TIMEOUT_STUB" "$@"
}

echo "=== backlog-dispatch tests ==="

# =============================================================================
# AC1 — header documenta schema/markers/fluxo; --help funciona
# =============================================================================
HDR="$(sed -n '1,40p' "$BD")"
assert_grep "$HDR" "schema|fila|jsonl" "AC1a header documenta schema da fila"
assert_grep "$HDR" "marker|dispatched|done|failed" "AC1b header documenta markers de estado"
assert_grep "$HDR" "[Ff]luxo|ponta-a-ponta|PR aberto" "AC1c header documenta o fluxo ponta-a-ponta"
OUT=$(bash "$BD" --help); rc=$?
assert_rc "$rc" "0" "AC1d --help exit 0"
assert_grep "$OUT" "[Uu]so|[Uu]sage" "AC1e --help imprime uso"
ERR=$(bash "$BD" --frobnicate 2>&1 >/dev/null); rc=$?
[ "$rc" != 0 ] && _pass || _fail "AC1f flag inválida → exit != 0 (rc=$rc)"
assert_grep "$ERR" "[Uu]so|[Uu]sage" "AC1g flag inválida → usage em stderr"
# --max validação de forma/comprimento (antes de aritmética)
ERR=$(bash "$BD" --max abc 2>&1 >/dev/null); rc=$?
[ "$rc" != 0 ] && _pass || _fail "AC1h --max não-numérico → exit != 0"
ERR=$(bash "$BD" --max 999999999999 2>&1 >/dev/null); rc=$?
[ "$rc" != 0 ] && _pass || _fail "AC1i --max gigante → exit != 0"

# =============================================================================
# AC2 — human_gate true NUNCA despacha e aparece em seção 'human-gate'
# =============================================================================
read -r BLDIR POOL <<<"$(mkenv ac2)"
mkrepo "$POOL/demo-1" main clean
{
  echo '{"id":"gated","repo":"demo","kind":"command","ref":"/full-cycle-simple plano-x","created_at":"2026-06-10T09-00-00Z","human_gate":true,"reason":"toca auth"}'
  echo '{"id":"ok1","repo":"demo","kind":"command","ref":"/full-cycle-simple plano-y","created_at":"2026-06-10T10-00-00Z","human_gate":false,"reason":""}'
} > "$BLDIR/demo.jsonl"
LOG="$TMP/log.ac2"; : > "$LOG"
OUT=$(run env CALLLOG="$LOG" BD_BACKLOG_DIR="$BLDIR" BD_POOL_BASE="$POOL" bash "$BD" --max 5 2>&1); rc=$?
assert_rc "$rc" "0" "AC2a exit 0"
assert_count "$(cat "$LOG")" "^claude " "1" "AC2b capture-proof: 1 dispatch (o elegível) ocorreu"
assert_grep "$(cat "$LOG")" "plano-y" "AC2c o item elegível (ok1) foi despachado"
assert_nogrep "$(cat "$LOG")" "plano-x" "AC2d o item human_gate NÃO foi despachado"
assert_grep "$OUT" "human-gate" "AC2e seção 'human-gate' presente no output"
# A seção human-gate cita o id gated
assert_grep "$OUT" "gated" "AC2f id 'gated' reportado na seção human-gate"

# =============================================================================
# AC3 — dedup por markers: done → não re-despacha; >=3 failed → skip permanente
# =============================================================================
read -r BLDIR POOL <<<"$(mkenv ac3)"
mkrepo "$POOL/demo-1" main clean
mkrepo "$POOL/demo-2" main clean
{
  echo '{"id":"d1","repo":"demo","kind":"command","ref":"/full-cycle-simple done-item","created_at":"2026-06-10T08-00-00Z","human_gate":false}'
  echo '{"marker":"done","id":"d1","created_at":"2026-06-10T08-30-00Z","rc":0}'
  echo '{"id":"p1","repo":"demo","kind":"command","ref":"/full-cycle-simple perm-item","created_at":"2026-06-10T09-00-00Z","human_gate":false}'
  echo '{"marker":"failed","id":"p1","created_at":"2026-06-10T09-10-00Z","rc":1}'
  echo '{"marker":"failed","id":"p1","created_at":"2026-06-10T09-20-00Z","rc":1}'
  echo '{"marker":"failed","id":"p1","created_at":"2026-06-10T09-30-00Z","rc":1}'
} > "$BLDIR/demo.jsonl"
LOG="$TMP/log.ac3"; : > "$LOG"
OUT=$(run env CALLLOG="$LOG" BD_BACKLOG_DIR="$BLDIR" BD_POOL_BASE="$POOL" bash "$BD" --max 5 2>&1); rc=$?
assert_rc "$rc" "0" "AC3a exit 0"
assert_count "$(cat "$LOG")" "^claude " "0" "AC3b nem done nem permanente despacham"
assert_nogrep "$(cat "$LOG")" "done-item" "AC3c item com marker done não re-despacha"
assert_grep "$OUT" "skip permanente" "AC3d >=3 failed → 'skip permanente' reportado"
assert_grep "$OUT" "p1" "AC3e id permanente reportado"

# =============================================================================
# AC4 — slot dirty/fora de main rejeitado; sem slot livre → exit 0 sem dispatch
# =============================================================================
read -r BLDIR POOL <<<"$(mkenv ac4)"
mkrepo "$POOL/demo-1" main dirty       # dirty → rejeitado
mkrepo "$POOL/demo-2" feature/x clean  # fora de main → rejeitado
echo '{"id":"a1","repo":"demo","kind":"command","ref":"/full-cycle-simple no-slot","created_at":"2026-06-10T08-00-00Z","human_gate":false}' > "$BLDIR/demo.jsonl"
LOG="$TMP/log.ac4"; : > "$LOG"
OUT=$(run env CALLLOG="$LOG" BD_BACKLOG_DIR="$BLDIR" BD_POOL_BASE="$POOL" bash "$BD" --max 5 2>&1); rc=$?
assert_rc "$rc" "0" "AC4a sem slot livre → exit 0"
assert_count "$(cat "$LOG")" "^claude " "0" "AC4b nenhum dispatch (todos os slots rejeitados)"
assert_grep "$OUT" "[Ss]em slot|adiado|nenhum slot" "AC4c aviso de slot indisponível"
# Agora UM slot livre (clean+main) → despacha
read -r BLDIR POOL <<<"$(mkenv ac4b)"
mkrepo "$POOL/demo-1" feature/x clean
mkrepo "$POOL/demo-2" main clean        # este é o livre
echo '{"id":"a2","repo":"demo","kind":"command","ref":"/full-cycle-simple has-slot","created_at":"2026-06-10T08-00-00Z","human_gate":false}' > "$BLDIR/demo.jsonl"
LOG="$TMP/log.ac4b"; : > "$LOG"
OUT=$(run env CALLLOG="$LOG" BD_BACKLOG_DIR="$BLDIR" BD_POOL_BASE="$POOL" bash "$BD" --max 5 2>&1); rc=$?
assert_count "$(cat "$LOG")" "^claude " "1" "AC4d slot clean+main é selecionado e despacha"
assert_grep "$(cat "$LOG")" "cwd=$POOL/demo-2\$" "AC4e dispatch ocorre dentro do slot livre"

# =============================================================================
# AC5 — lock atômico (mkdir): 2ª instância sem despachar; lock some no fim
# =============================================================================
read -r BLDIR POOL <<<"$(mkenv ac5)"
mkrepo "$POOL/demo-1" main clean
echo '{"id":"l1","repo":"demo","kind":"command","ref":"/full-cycle-simple lock-item","created_at":"2026-06-10T08-00-00Z","human_gate":false}' > "$BLDIR/demo.jsonl"
mkdir -p "$BLDIR/.dispatch.lock"   # simula instância concorrente já segurando o lock
LOG="$TMP/log.ac5"; : > "$LOG"
OUT=$(run env CALLLOG="$LOG" BD_BACKLOG_DIR="$BLDIR" BD_POOL_BASE="$POOL" bash "$BD" --max 5 2>&1); rc=$?
assert_rc "$rc" "0" "AC5a 2ª instância (lock ocupado) → exit 0 limpo"
assert_count "$(cat "$LOG")" "^claude " "0" "AC5b 2ª instância NÃO despacha"
assert_grep "$OUT" "instância|lock|andamento" "AC5c aviso de lock/instância concorrente"
[ -d "$BLDIR/.dispatch.lock" ] && _pass || _fail "AC5d lock da 1ª instância preservado (não removido pela 2ª)"
rmdir "$BLDIR/.dispatch.lock"
# run normal → lock criado e removido ao final
LOG="$TMP/log.ac5b"; : > "$LOG"
OUT=$(run env CALLLOG="$LOG" BD_BACKLOG_DIR="$BLDIR" BD_POOL_BASE="$POOL" bash "$BD" --max 5 2>&1); rc=$?
assert_count "$(cat "$LOG")" "^claude " "1" "AC5e run normal despacha"
[ ! -d "$BLDIR/.dispatch.lock" ] && _pass || _fail "AC5f lock removido ao final do run normal (trap EXIT)"

# =============================================================================
# AC6 — prompt instrui parar no PR sem auto-merge; sem 'gh pr merge' no call-log
# =============================================================================
read -r BLDIR POOL <<<"$(mkenv ac6)"
mkrepo "$POOL/demo-1" main clean
echo '{"id":"m1","repo":"demo","kind":"command","ref":"/full-cycle-simple merge-test","created_at":"2026-06-10T08-00-00Z","human_gate":false}' > "$BLDIR/demo.jsonl"
LOG="$TMP/log.ac6"; : > "$LOG"
OUT=$(run env CALLLOG="$LOG" BD_BACKLOG_DIR="$BLDIR" BD_POOL_BASE="$POOL" bash "$BD" --max 5 2>&1); rc=$?
assert_count "$(cat "$LOG")" "^claude " "1" "AC6a capture-proof: claude foi invocado"
assert_grep "$(cat "$LOG")" "PARE|sem auto-merge|sem merge" "AC6b prompt instrui parar no PR sem auto-merge"
assert_nogrep "$(cat "$LOG")" "gh pr merge" "AC6c nenhuma invocação contém 'gh pr merge'"

# =============================================================================
# AC7 — --dry-run sem efeitos colaterais; --max N limita dispatches
# =============================================================================
read -r BLDIR POOL <<<"$(mkenv ac7)"
mkrepo "$POOL/demo-1" main clean
mkrepo "$POOL/demo-2" main clean
echo '{"id":"dry1","repo":"demo","kind":"command","ref":"/full-cycle-simple dry-item","created_at":"2026-06-10T08-00-00Z","human_gate":false}' > "$BLDIR/demo.jsonl"
before_lines=$(wc -l < "$BLDIR/demo.jsonl")
LOG="$TMP/log.ac7"; : > "$LOG"
OUT=$(run env CALLLOG="$LOG" BD_BACKLOG_DIR="$BLDIR" BD_POOL_BASE="$POOL" bash "$BD" --dry-run --max 5 2>&1); rc=$?
assert_rc "$rc" "0" "AC7a --dry-run exit 0"
assert_grep "$OUT" "dry1.*demo-[12]|demo-[12].*dry1" "AC7b --dry-run imprime plano item→slot"
assert_count "$(cat "$LOG")" "^claude " "0" "AC7c --dry-run não invoca claude"
after_lines=$(wc -l < "$BLDIR/demo.jsonl")
assert_eq "$after_lines" "$before_lines" "AC7d --dry-run não escreve markers na fila"
[ ! -d "$BLDIR/.dispatch.lock" ] && _pass || _fail "AC7e --dry-run não deixa lock"
# --max 1 com 2 itens elegíveis e 2 slots → exatamente 1 dispatch
read -r BLDIR POOL <<<"$(mkenv ac7b)"
mkrepo "$POOL/demo-1" main clean
mkrepo "$POOL/demo-2" main clean
{
  echo '{"id":"c1","repo":"demo","kind":"command","ref":"/full-cycle-simple cap-a","created_at":"2026-06-10T08-00-00Z","human_gate":false}'
  echo '{"id":"c2","repo":"demo","kind":"command","ref":"/full-cycle-simple cap-b","created_at":"2026-06-10T09-00-00Z","human_gate":false}'
} > "$BLDIR/demo.jsonl"
LOG="$TMP/log.ac7b"; : > "$LOG"
OUT=$(run env CALLLOG="$LOG" BD_BACKLOG_DIR="$BLDIR" BD_POOL_BASE="$POOL" bash "$BD" --max 1 2>&1); rc=$?
assert_count "$(cat "$LOG")" "^claude " "1" "AC7f --max 1 limita a 1 dispatch (mesmo com 2 elegíveis+2 slots)"

# =============================================================================
# AC8 — timeout chain + RC de timeout (124) → marker failed
# =============================================================================
read -r BLDIR POOL <<<"$(mkenv ac8)"
mkrepo "$POOL/demo-1" main clean
echo '{"id":"t1","repo":"demo","kind":"command","ref":"/full-cycle-simple timeout-item","created_at":"2026-06-10T08-00-00Z","human_gate":false}' > "$BLDIR/demo.jsonl"
LOG="$TMP/log.ac8"; : > "$LOG"
OUT=$(run env CALLLOG="$LOG" CLAUDE_RC=124 BD_BACKLOG_DIR="$BLDIR" BD_POOL_BASE="$POOL" bash "$BD" --max 5 2>&1); rc=$?
assert_rc "$rc" "0" "AC8a falha de timeout não bloqueia → exit 0 (non-blocking)"
assert_grep "$(cat "$LOG")" "^timeout 3600 " "AC8b timeout chain com teto 3600 via BD_TIMEOUT"
last_marker=$(grep '"marker":"failed"' "$BLDIR/demo.jsonl" | tail -1)
printf '%s' "$last_marker" | jq -e '.marker=="failed" and .id=="t1" and .rc==124' >/dev/null 2>&1 \
  && _pass || _fail "AC8c RC de timeout (124) vira marker failed jq-parseable (got: $last_marker)"
# fallback sem timeout/gtimeout → roda direto + aviso, marca done (rc 0)
NEED=$(mktemp -d "$TMP/needbin.XXXXXX")
for b in bash env date jq mktemp awk grep sed sort wc tr basename dirname cat head tail uniq git find rmdir mkdir; do
  p=$(command -v "$b") && ln -s "$p" "$NEED/$b"
done
read -r BLDIR POOL <<<"$(mkenv ac8b)"
mkrepo "$POOL/demo-1" main clean
echo '{"id":"t2","repo":"demo","kind":"command","ref":"/full-cycle-simple notimeout-item","created_at":"2026-06-10T08-00-00Z","human_gate":false}' > "$BLDIR/demo.jsonl"
LOG="$TMP/log.ac8b"; : > "$LOG"
OUT=$(env PATH="$NEED" CALLLOG="$LOG" BD_NOW="$NOW" BD_CLAUDE="$CLAUDE_STUB" \
      BD_BACKLOG_DIR="$BLDIR" BD_POOL_BASE="$POOL" bash "$BD" --max 1 2>&1); rc=$?
assert_rc "$rc" "0" "AC8d sem timeout/gtimeout → exit 0"
assert_count "$(cat "$LOG")" "^timeout " "0" "AC8e nenhum timeout no call-log (rodou direto)"
assert_grep "$OUT" "[Ss]em teto" "AC8f aviso de execução sem teto"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then
  echo "Failed tests:$FAILED"
  exit 1
fi
exit 0

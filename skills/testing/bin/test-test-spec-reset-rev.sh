#!/usr/bin/env bash
set -euo pipefail

# test-test-spec-reset-rev.sh — testes para US-06 (test-spec-reset-rev.sh
# DERIVADO via fold; twin de test-dod-reset-rev.sh do auto-grill-me).
#
# Cobre (US-06):
#   help — sem args → --help + exit 0
#   AC1  — --show deriva via fold (US-02) com --prefix test-spec (MESMAS libs
#          M1/M2 — o script só sourceia bin/lib/usage-fold.sh, não reimplementa
#          writer/fold); a tabela reproduz EXATAMENTE os contadores que estavam
#          inline pré-migração (usos/desde_rev por spec_id).
#   AC4  — --show deriva via fold; a regex de heading casa o heading SEM o sufixo
#          `(usos…)`; a derivação de spec_id continua correta (id inexistente →
#          exit 2). O subcomando --gc foi removido → exit 1.
#          reset emite 1 evento `revision` @ sha atual SEM editar TEST-PATTERNS.md
#          e SEM escrever .json.
#   sort — default desde-rev DESC; --sort=usos / --sort=id corretos.
#
# Harness: roda o script REAL in-place (resolve bin/lib/ relativo correto),
# passando --dod-file (fixture) + USAGE_LOG_HOME (sandbox do log). Mesmo padrão
# de skills/auto-grill-me/bin/test-dod-reset-rev.sh.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="$SCRIPT_DIR/test-spec-reset-rev.sh"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
FOLD_LIB="$REPO_ROOT/bin/lib/usage-fold.sh"

if [[ ! -x "$TARGET" ]]; then
  echo "FAIL: $TARGET inexistente ou não-executável" >&2
  exit 1
fi

# AC1 (anti-duplicação): o script consome as libs compartilhadas e NÃO
# reimplementa writer/fold. Prova estática: sourceia usage-fold.sh e não
# (re)define log_event / usage_fold / dod_bullets_sha localmente.
grep -q 'source .*bin/lib/usage-fold.sh' "$TARGET" \
  || { echo "FAIL AC1: $TARGET não sourceia bin/lib/usage-fold.sh" >&2; exit 1; }
if grep -qE '^(log_event|usage_fold|dod_bullets_sha)\(\)' "$TARGET"; then
  echo "FAIL AC1: $TARGET redefine writer/fold (deveria reusar as libs M1/M2)" >&2; exit 1
fi
echo "PASS AC1(estático) — reusa libs M1/M2 (sourceia usage-fold.sh, não reimplementa)"

TMP="$(mktemp -d -t test-spec-reset-test.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
FIX="$TMP/TEST-PATTERNS.md"
export USAGE_LOG_HOME="$TMP/home"   # sandbox: writer/fold isolados do ~/.claude real

# Fixture STRIPPED (sem sufixo inline — estado pós-US-03), com bullets [bN] em
# cada seção. 8 DoD-base (cat 1..8) + 4 Tarefa (1, 5, 17, 20).
{
  echo "# TEST-PATTERNS fixture"
  for cat in 1 2 3 4 5 6 7 8; do
    echo ""
    echo "## Categoria $cat — Lorem"
    echo ""
    echo "### DoD-base — Categoria $cat"
    echo ""
    echo "- [ ] [b1] bullet base cat $cat"
  done
  echo ""
  echo "## Categoria 3 — Tarefas"
  echo ""
  echo "### Tarefa 1 — Algo"
  echo ""
  echo "- [ ] [b1] bullet tarefa 1"
  echo ""
  echo "### Tarefa 5 — Página nova"
  echo ""
  echo "- [ ] [b1] bullet tarefa 5"
  echo ""
  echo "### Tarefa 17 — Algo"
  echo ""
  echo "- [ ] [b1] bullet tarefa 17"
  echo ""
  echo "### Tarefa 20 — Outro"
  echo ""
  echo "- [ ] [b1] bullet tarefa 20"
} > "$FIX"

# Reusa as libs (US-01/US-02) p/ computar o sha dos bullets e semear o log com
# contadores conhecidos. Sourcing define dod_bullets_sha + log_event.
# shellcheck source=bin/lib/usage-fold.sh
source "$FOLD_LIB"

# Captura tudo antes de filtrar (evita SIGPIPE em dod_bullets_sha sob pipefail).
sha_of() {
  local all
  all="$(dod_bullets_sha "$FIX")"
  awk -F'\t' -v t="$1" '$1 == t { print $2 }' <<< "$all"
}

SHA_T5="$(sha_of tarefa-5)"
SHA_T17="$(sha_of tarefa-17)"
[[ -n "$SHA_T5" && -n "$SHA_T17" ]] || { echo "FAIL setup: sha vazio (t5='$SHA_T5' t17='$SHA_T17')" >&2; exit 1; }

# Semeia no log test-spec (--prefix test-spec): tarefa-5 → usos=12 (baseline 9 +
# 3 use@sha) / desde_rev=3. tarefa-17 → usos=5 (baseline 0 + 5 use@sha) /
# desde_rev=5. Equivalência ao inline pré-migração.
log_event baseline tarefa-5 --prefix test-spec --sha "$SHA_T5" --count 9
for _ in 1 2 3; do log_event use tarefa-5 --prefix test-spec --sha "$SHA_T5"; done
log_event baseline tarefa-17 --prefix test-spec --sha "$SHA_T17" --count 0
for _ in 1 2 3 4 5; do log_event use tarefa-17 --prefix test-spec --sha "$SHA_T17"; done

run() { USAGE_LOG_HOME="$USAGE_LOG_HOME" bash "$TARGET" --dod-file "$FIX" "$@"; }

# --- help: sem args → exit 0 + header 'uso:' ---
set +e
OUT="$(USAGE_LOG_HOME="$USAGE_LOG_HOME" bash "$TARGET" --dod-file "$FIX" 2>&1)"
EC=$?
set -e
[[ "$EC" -eq 0 ]] || { echo "FAIL help: exit esperado=0, obtido=$EC" >&2; exit 1; }
grep -q '^uso:' <<< "$OUT" || { echo "FAIL help: sem header 'uso:'" >&2; exit 1; }
echo "PASS help — sem args imprime --help + exit 0"

# --- AC4: spec-id desconhecido (regex sem sufixo deriva id corretamente) → exit 2 ---
set +e
STDERR="$(run tarefa-99 2>&1 >/dev/null)"
EC=$?
set -e
[[ "$EC" -eq 2 ]] || { echo "FAIL AC4: exit esperado=2, obtido=$EC ($STDERR)" >&2; exit 1; }
[[ "$STDERR" == "spec-id desconhecido: tarefa-99" ]] || { echo "FAIL AC4: stderr='$STDERR'" >&2; exit 1; }
echo "PASS AC4 — heading sem sufixo: spec-id desconhecido → exit 2 + stderr correto"

# --- AC1/AC4: --show deriva via fold e reproduz os contadores inline equivalentes ---
SHOW_OUT="$(run --show)"
HEADER="$(head -1 <<< "$SHOW_OUT")"
grep -qE '^usos +desde-rev +spec_id +title_current' <<< "$HEADER" \
  || { echo "FAIL AC1: header malformado: '$HEADER'" >&2; exit 1; }
# 12 headings no fixture → 12 linhas de dados, todas casando o regex tabular.
DATA="$(tail -n +2 <<< "$SHOW_OUT")"
TOTAL=$(grep -c . <<< "$DATA")
MATCH=$(grep -cE '^[0-9]+ +[0-9]+ +(tarefa-[0-9]+|cat-[0-9]+-base) +' <<< "$DATA" || echo 0)
[[ "$TOTAL" -eq 12 && "$MATCH" -eq 12 ]] \
  || { echo "FAIL AC1: $MATCH/$TOTAL linhas casam (esperado 12/12)" >&2; echo "$SHOW_OUT" >&2; exit 1; }
# Equivalência: tarefa-5 deriva usos=12 desde_rev=3; tarefa-17 usos=5 desde_rev=5.
T5="$(awk '$3=="tarefa-5"{print $1" "$2}' <<< "$DATA")"
T17="$(awk '$3=="tarefa-17"{print $1" "$2}' <<< "$DATA")"
[[ "$T5" == "12 3" ]]  || { echo "FAIL AC1: tarefa-5 derivou '$T5' (esperado '12 3')" >&2; echo "$SHOW_OUT" >&2; exit 1; }
[[ "$T17" == "5 5" ]]  || { echo "FAIL AC1: tarefa-17 derivou '$T17' (esperado '5 5')" >&2; exit 1; }
# Spec sem eventos → 0/0 (left-join com headings).
T1="$(awk '$3=="tarefa-1"{print $1" "$2}' <<< "$DATA")"
[[ "$T1" == "0 0" ]] || { echo "FAIL AC1: tarefa-1 (sem eventos) derivou '$T1' (esperado '0 0')" >&2; exit 1; }
echo "PASS AC1 — --show via fold (--prefix test-spec) reproduz inline (t5=12/3, t17=5/5, t1=0/0)"

# --- sort: default desde-rev DESC → tarefa-17 (desde_rev=5) é a 1ª data line ---
FIRST="$(run --show | sed -n '2p')"
grep -qE '^5 +5 +tarefa-17 ' <<< "$FIRST" \
  || { echo "FAIL sort(default): 1ª data line deveria ser tarefa-17 (5/5); got '$FIRST'" >&2; exit 1; }
# --sort=usos → tarefa-5 (usos=12) primeiro.
USOS_FIRST="$(run --show --sort=usos | sed -n '2p')"
grep -qE '^12 +' <<< "$USOS_FIRST" \
  || { echo "FAIL sort(usos): 1ª data line não tem maior usos; got '$USOS_FIRST'" >&2; exit 1; }
# --sort=id → cat-1-base (alfabético) primeiro.
ID_FIRST="$(run --show --sort=id | sed -n '2p')"
grep -q 'cat-1-base' <<< "$ID_FIRST" \
  || { echo "FAIL sort(id): 1ª data line não é cat-1-base; got '$ID_FIRST'" >&2; exit 1; }
echo "PASS sort — default desde-rev DESC, --sort=usos e --sort=id corretos"

# --- AC4: reset emite evento revision @ sha atual, SEM editar inline / .json ---
PRE_DOD_SHA="$(sha256sum "$FIX" 2>/dev/null | cut -d' ' -f1 || shasum -a 256 "$FIX" | cut -d' ' -f1)"
LOGFILE="$(find "$USAGE_LOG_HOME/telemetry" -name 'test-spec-usage.*.jsonl' | head -1)"
PRE_REV=$(grep -c '"kind":"revision"' "$LOGFILE" || true)
RESET_OUT="$(run tarefa-5)"
POST_DOD_SHA="$(sha256sum "$FIX" 2>/dev/null | cut -d' ' -f1 || shasum -a 256 "$FIX" | cut -d' ' -f1)"
POST_REV=$(grep -c '"kind":"revision"' "$LOGFILE" || true)
# (a) Exatamente 1 evento revision novo.
[[ $((POST_REV - PRE_REV)) -eq 1 ]] \
  || { echo "FAIL AC4: revision delta=$((POST_REV - PRE_REV)) (esperado 1)" >&2; exit 1; }
# (b) O evento novo é tarefa-5 @ sha atual dos bullets.
LAST_REV="$(grep '"kind":"revision"' "$LOGFILE" | tail -1)"
echo "$LAST_REV" | jq -e --arg id tarefa-5 --arg sha "$SHA_T5" \
  '.kind=="revision" and .dod_id==$id and .sha==$sha' >/dev/null \
  || { echo "FAIL AC4: evento revision != {tarefa-5,sha atual}: $LAST_REV" >&2; exit 1; }
# (c) Não editou contador inline → TEST-PATTERNS.md byte-idêntico.
[[ "$PRE_DOD_SHA" == "$POST_DOD_SHA" ]] \
  || { echo "FAIL AC4: TEST-PATTERNS.md mudou após reset (esperado intacto)" >&2; exit 1; }
# (d) Nenhum .json de estado escrito (snapshot removido US-03).
if find "$TMP" -name '*revision-state.json' | grep -q .; then
  echo "FAIL AC4: snapshot .json foi criado (esperado nenhum)" >&2; exit 1
fi
grep -q '^reset: tarefa-5 — evento revision' <<< "$RESET_OUT" \
  || { echo "FAIL AC4: output inesperado: $RESET_OUT" >&2; exit 1; }
echo "PASS AC4 — reset emite 1 revision @ sha atual; TEST-PATTERNS.md intacto; sem .json"

# --- AC4: --gc removido → exit 1 (uso desconhecido) ---
set +e
GC_ERR="$(run --gc 2>&1 >/dev/null)"
GC_EC=$?
set -e
[[ "$GC_EC" -eq 1 ]] || { echo "FAIL AC4: --gc exit esperado=1, obtido=$GC_EC" >&2; exit 1; }
grep -q 'uso desconhecido: --gc' <<< "$GC_ERR" \
  || { echo "FAIL AC4: stderr não reporta '--gc' desconhecido: '$GC_ERR'" >&2; exit 1; }
echo "PASS AC4 — --gc aposentado → exit 1 + 'uso desconhecido'"

echo ""
echo "ALL TESTS PASSED"

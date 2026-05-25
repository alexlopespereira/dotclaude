#!/usr/bin/env bash
set -euo pipefail

# test-dod-reset-rev.sh — testes para US-04 (dod-reset-rev.sh DERIVADO via fold).
#
# Cobre (US-04):
#   help — sem args → --help + exit 0
#   AC1  — --show deriva via fold (US-02) e a tabela reproduz EXATAMENTE os
#          contadores que estavam inline pré-migração (usos/desde_rev por dod_id).
#   AC2  — `reset <dod_id>` emite 1 evento `revision` @ sha atual dos bullets,
#          SEM editar contador inline (DOD.md intacto) e SEM escrever .json.
#   AC3  — a regex de heading casa o heading SEM o sufixo `(usos…)`; a derivação
#          de dod_id continua correta (dod-id inexistente → exit 2).
#   AC5  — `--gc` foi removido → exit 1 (uso desconhecido).
#   sort — default desde-rev DESC; --sort=usos / --sort=id corretos.
#
# Harness: roda o script REAL in-place (resolve bin/lib/ relativo correto),
# passando --dod-file (fixture) + USAGE_LOG_HOME (sandbox do log). Mesmo padrão
# de bin/tests/test_dod_usage_migrate.sh.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="$SCRIPT_DIR/dod-reset-rev.sh"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
FOLD_LIB="$REPO_ROOT/bin/lib/usage-fold.sh"

if [[ ! -x "$TARGET" ]]; then
  echo "FAIL: $TARGET inexistente ou não-executável" >&2
  exit 1
fi

TMP="$(mktemp -d -t dod-reset-test.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
FIX="$TMP/DOD.md"
export USAGE_LOG_HOME="$TMP/home"   # sandbox: writer/fold isolados do ~/.claude real

# Fixture STRIPPED (sem sufixo inline — estado pós-US-03), com bullets [bN] em
# cada seção. 8 DoD-base (cat 1..8) + 4 Tarefa (1, 5, 17, 20).
{
  echo "# DOD fixture"
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

# Semeia: tarefa-5 → usos=12 (baseline 9 + 3 use@sha) / desde_rev=3.
#         tarefa-17 → usos=5  (baseline 0 + 5 use@sha) / desde_rev=5.
# Equivalência ao inline pré-migração (Tarefa 5: usos:12 · desde rev:3, etc).
log_event baseline tarefa-5 --sha "$SHA_T5" --count 9
for _ in 1 2 3; do log_event use tarefa-5 --sha "$SHA_T5"; done
log_event baseline tarefa-17 --sha "$SHA_T17" --count 0
for _ in 1 2 3 4 5; do log_event use tarefa-17 --sha "$SHA_T17"; done

run() { USAGE_LOG_HOME="$USAGE_LOG_HOME" bash "$TARGET" --dod-file "$FIX" "$@"; }

# --- help: sem args → exit 0 + header 'uso:' ---
set +e
OUT="$(USAGE_LOG_HOME="$USAGE_LOG_HOME" bash "$TARGET" --dod-file "$FIX" 2>&1)"
EC=$?
set -e
[[ "$EC" -eq 0 ]] || { echo "FAIL help: exit esperado=0, obtido=$EC" >&2; exit 1; }
grep -q '^uso:' <<< "$OUT" || { echo "FAIL help: sem header 'uso:'" >&2; exit 1; }
echo "PASS help — sem args imprime --help + exit 0"

# --- AC3: dod-id desconhecido (regex sem sufixo deriva id corretamente) → exit 2 ---
set +e
STDERR="$(run tarefa-99 2>&1 >/dev/null)"
EC=$?
set -e
[[ "$EC" -eq 2 ]] || { echo "FAIL AC3: exit esperado=2, obtido=$EC ($STDERR)" >&2; exit 1; }
[[ "$STDERR" == "dod-id desconhecido: tarefa-99" ]] || { echo "FAIL AC3: stderr='$STDERR'" >&2; exit 1; }
echo "PASS AC3 — heading sem sufixo: dod-id desconhecido → exit 2 + stderr correto"

# --- AC1: --show deriva via fold e reproduz os contadores inline equivalentes ---
SHOW_OUT="$(run --show)"
HEADER="$(head -1 <<< "$SHOW_OUT")"
grep -qE '^usos +desde-rev +dod_id +title_current' <<< "$HEADER" \
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
# DoD sem eventos → 0/0 (left-join com headings).
T1="$(awk '$3=="tarefa-1"{print $1" "$2}' <<< "$DATA")"
[[ "$T1" == "0 0" ]] || { echo "FAIL AC1: tarefa-1 (sem eventos) derivou '$T1' (esperado '0 0')" >&2; exit 1; }
echo "PASS AC1 — --show via fold reproduz contadores inline (t5=12/3, t17=5/5, t1=0/0)"

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

# --- AC2: reset emite evento revision @ sha atual, SEM editar inline / .json ---
PRE_DOD_SHA="$(sha256sum "$FIX" | cut -d' ' -f1)"
LOGFILE="$(find "$USAGE_LOG_HOME/telemetry" -name 'dod-usage.*.jsonl' | head -1)"
PRE_REV=$(grep -c '"kind":"revision"' "$LOGFILE" || true)
RESET_OUT="$(run tarefa-5)"
POST_DOD_SHA="$(sha256sum "$FIX" | cut -d' ' -f1)"
POST_REV=$(grep -c '"kind":"revision"' "$LOGFILE" || true)
# (a) Exatamente 1 evento revision novo.
[[ $((POST_REV - PRE_REV)) -eq 1 ]] \
  || { echo "FAIL AC2: revision delta=$((POST_REV - PRE_REV)) (esperado 1)" >&2; exit 1; }
# (b) O evento novo é tarefa-5 @ sha atual dos bullets.
LAST_REV="$(grep '"kind":"revision"' "$LOGFILE" | tail -1)"
echo "$LAST_REV" | jq -e --arg id tarefa-5 --arg sha "$SHA_T5" \
  '.kind=="revision" and .dod_id==$id and .sha==$sha' >/dev/null \
  || { echo "FAIL AC2: evento revision != {tarefa-5,sha atual}: $LAST_REV" >&2; exit 1; }
# (c) Não editou contador inline → DOD.md byte-idêntico.
[[ "$PRE_DOD_SHA" == "$POST_DOD_SHA" ]] \
  || { echo "FAIL AC2: DOD.md mudou após reset (esperado intacto)" >&2; exit 1; }
# (d) Nenhum .json de estado escrito (snapshot removido US-03).
if find "$TMP" -name '*revision-state.json' | grep -q .; then
  echo "FAIL AC2: snapshot .json foi criado (esperado nenhum)" >&2; exit 1
fi
grep -q '^reset: tarefa-5 — evento revision' <<< "$RESET_OUT" \
  || { echo "FAIL AC2: output inesperado: $RESET_OUT" >&2; exit 1; }
echo "PASS AC2 — reset emite 1 revision @ sha atual; DOD.md intacto; sem .json"

# --- AC5: --gc removido → exit 1 (uso desconhecido) ---
set +e
GC_ERR="$(run --gc 2>&1 >/dev/null)"
GC_EC=$?
set -e
[[ "$GC_EC" -eq 1 ]] || { echo "FAIL AC5: --gc exit esperado=1, obtido=$GC_EC" >&2; exit 1; }
grep -q 'uso desconhecido: --gc' <<< "$GC_ERR" \
  || { echo "FAIL AC5: stderr não reporta '--gc' desconhecido: '$GC_ERR'" >&2; exit 1; }
echo "PASS AC5 — --gc aposentado → exit 1 + 'uso desconhecido'"

echo ""
echo "ALL TESTS PASSED"

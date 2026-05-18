#!/usr/bin/env bash
set -euo pipefail

# test-dod-reset-rev.sh — testes para US-03 (dod-reset-rev.sh).
#
# Cobre:
#   AC4 — sem args → --help + exit 0
#   AC5 — `tarefa-5` zera desde rev + atualiza last_seen_iso
#   AC6 — `tarefa-99` (inexistente) → exit 2 + stderr correto
#   AC7 — `--show` tem header + linhas casam regex
#   AC8 — `--show --sort=usos`/`--sort=id` produzem ordens distintas
#   AC9 — `--gc` remove entries órfãs e reporta contagem

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="$SCRIPT_DIR/dod-reset-rev.sh"

if [[ ! -x "$TARGET" ]]; then
  echo "FAIL: $TARGET inexistente ou não-executável" >&2
  exit 1
fi

TMP="$(mktemp -d -t dod-reset-test.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/references"
cp "$TARGET" "$TMP/bin/"

# Fixture sintético: 8 DoD-base (cat 1..8) + 4 Tarefa (1, 5, 17, 20). Mesmo
# padrão do DOD.md migrado, com tarefa-5 começando em (usos:12 · desde rev:3).
{
  echo "# DOD fixture"
  for cat in 1 2 3 4 5 6 7 8; do
    echo ""
    echo "## Categoria $cat — Lorem"
    echo ""
    echo "### DoD-base — Categoria $cat (usos: 0 · desde rev: 0)"
    echo ""
    echo "- bullet base cat $cat"
  done
  echo ""
  echo "## Categoria 3 — Tarefas"
  echo ""
  echo "### Tarefa 1 — Algo (usos: 0 · desde rev: 0)"
  echo ""
  echo "- bullet tarefa 1"
  echo ""
  echo "### Tarefa 5 — Página nova (usos: 12 · desde rev: 3)"
  echo ""
  echo "- bullet tarefa 5"
  echo ""
  echo "### Tarefa 17 — Algo (usos: 5 · desde rev: 5)"
  echo ""
  echo "- bullet tarefa 17"
  echo ""
  echo "### Tarefa 20 — Outro (usos: 0 · desde rev: 0)"
  echo ""
  echo "- bullet tarefa 20"
} > "$TMP/references/DOD.md"

# Snapshot: 8 DoD-base + 4 Tarefa + 1 ÓRFÃ (tarefa-999 inexistente em DOD.md)
{
  echo '{'
  first=1
  for cat in 1 2 3 4 5 6 7 8; do
    [[ $first -eq 1 ]] || echo ','
    first=0
    printf '  "cat-%s-base": {"slug":"x","title_current":"x","bullets_sha256":"0","last_seen_iso":"2026-01-01T00:00:00Z"}' "$cat"
  done
  for t in 1 5 17 20 999; do
    echo ','
    printf '  "tarefa-%s": {"slug":"x","title_current":"x","bullets_sha256":"0","last_seen_iso":"2026-01-01T00:00:00Z"}' "$t"
  done
  echo ''
  echo '}'
} > "$TMP/references/.dod-revision-state.json"

CMD="$TMP/bin/dod-reset-rev.sh"

# --- AC4: sem args → exit 0 + output não-vazio ---
set +e
OUT="$("$CMD" 2>&1)"
EC=$?
set -e
if [[ "$EC" -ne 0 ]]; then
  echo "FAIL AC4: exit esperado=0, obtido=$EC" >&2
  exit 1
fi
if ! grep -q '^uso:' <<< "$OUT"; then
  echo "FAIL AC4: help não contém 'uso:' header" >&2
  exit 1
fi
echo "PASS AC4 — sem args imprime --help + exit 0"

# --- AC6: tarefa-99 → exit 2 + stderr correto ---
set +e
STDERR="$("$CMD" tarefa-99 2>&1 >/dev/null)"
EC=$?
set -e
if [[ "$EC" -ne 2 ]]; then
  echo "FAIL AC6: exit esperado=2, obtido=$EC" >&2
  echo "stderr: $STDERR" >&2
  exit 1
fi
if [[ "$STDERR" != "dod-id desconhecido: tarefa-99" ]]; then
  echo "FAIL AC6: stderr esperado='dod-id desconhecido: tarefa-99', obtido='$STDERR'" >&2
  exit 1
fi
echo "PASS AC6 — tarefa-99 → exit 2 + stderr correto"

# --- AC5: tarefa-5 (usos:12 desde rev:3) → (usos:12 desde rev:0) + last_seen_iso novo ---
PRE_LINE="$(grep '^### Tarefa 5 ' "$TMP/references/DOD.md")"
PRE_TS="$(jq -r '.["tarefa-5"].last_seen_iso' "$TMP/references/.dod-revision-state.json")"
sleep 1  # garante ts diferente
"$CMD" tarefa-5 >/dev/null
POST_LINE="$(grep '^### Tarefa 5 ' "$TMP/references/DOD.md")"
POST_TS="$(jq -r '.["tarefa-5"].last_seen_iso' "$TMP/references/.dod-revision-state.json")"
EXPECTED_POST="### Tarefa 5 — Página nova (usos: 12 · desde rev: 0)"
if [[ "$POST_LINE" != "$EXPECTED_POST" ]]; then
  echo "FAIL AC5: heading errado" >&2
  echo "  pré : $PRE_LINE" >&2
  echo "  pós : $POST_LINE" >&2
  echo "  esp : $EXPECTED_POST" >&2
  exit 1
fi
if [[ "$PRE_TS" == "$POST_TS" ]]; then
  echo "FAIL AC5: last_seen_iso não atualizado (pré=pós=$PRE_TS)" >&2
  exit 1
fi
echo "PASS AC5 — tarefa-5: usos:12 desde rev:3 → usos:12 desde rev:0; last_seen_iso atualizado"

# --- AC7: --show tem header + linhas casam regex ---
SHOW_OUT="$("$CMD" --show)"
HEADER="$(head -1 <<< "$SHOW_OUT")"
if ! grep -qE '^usos +desde-rev +dod_id +title_current' <<< "$HEADER"; then
  echo "FAIL AC7: header malformado: '$HEADER'" >&2
  exit 1
fi
DATA_LINES="$(tail -n +2 <<< "$SHOW_OUT")"
TOTAL=$(wc -l <<< "$DATA_LINES" | tr -d ' ')
MATCH=$(grep -cE '^[0-9]+ +[0-9]+ +(tarefa-[0-9]+|cat-[0-9]+-base) +' <<< "$DATA_LINES" || echo 0)
if [[ "$TOTAL" -ne "$MATCH" ]]; then
  echo "FAIL AC7: $MATCH de $TOTAL linhas casam regex" >&2
  exit 1
fi
echo "PASS AC7 — --show: header presente + $MATCH/$TOTAL data lines casam regex"

# --- AC8 (a) default: ordena por desde-rev DESC. Após AC5 tarefa-5 zerou,
# tarefa-17 (desde-rev=5) é o único com desde-rev > 0 → primeira data line. ---
DEFAULT_FIRST="$("$CMD" --show | sed -n '2p')"
if ! grep -qE '^5 +5 +tarefa-17 ' <<< "$DEFAULT_FIRST"; then
  echo "FAIL AC8 (default sort desde-rev DESC): primeira data line deveria ser tarefa-17 (usos=5, desde-rev=5)" >&2
  echo "got: $DEFAULT_FIRST" >&2
  exit 1
fi
# --- AC8 (b) --sort=usos ordena por usos DESC (primeira linha de dados deve ter maior usos) ---
USOS_FIRST="$("$CMD" --show --sort=usos | sed -n '2p')"
if ! grep -qE '^12 ' <<< "$USOS_FIRST"; then
  echo "FAIL AC8 (--sort=usos): primeira data line não tem maior usos" >&2
  echo "got: $USOS_FIRST" >&2
  exit 1
fi
# --- AC8 (c) --sort=id: primeira data line deve ser cat-1-base (alfabético) ---
ID_FIRST="$("$CMD" --show --sort=id | sed -n '2p')"
if ! grep -qE 'cat-1-base' <<< "$ID_FIRST"; then
  echo "FAIL AC8 (--sort=id): primeira data line não é cat-1-base" >&2
  echo "got: $ID_FIRST" >&2
  exit 1
fi
echo "PASS AC8 — default (desde-rev DESC), --sort=usos e --sort=id produzem ordens corretas"

# --- AC9: --gc remove tarefa-999 (órfã) e reporta count=1 ---
BEFORE_KEYS="$(jq 'keys | length' "$TMP/references/.dod-revision-state.json")"
GC_OUT="$("$CMD" --gc)"
AFTER_KEYS="$(jq 'keys | length' "$TMP/references/.dod-revision-state.json")"
if [[ "$BEFORE_KEYS" -ne 13 ]] || [[ "$AFTER_KEYS" -ne 12 ]]; then
  echo "FAIL AC9: antes=$BEFORE_KEYS, depois=$AFTER_KEYS (esperado 13 → 12)" >&2
  exit 1
fi
if ! grep -qE '^gc: 1 entries órfãs removidas$' <<< "$GC_OUT"; then
  echo "FAIL AC9: output não casa: '$GC_OUT'" >&2
  exit 1
fi
if jq -e 'has("tarefa-999")' "$TMP/references/.dod-revision-state.json" >/dev/null; then
  echo "FAIL AC9: tarefa-999 ainda presente após --gc" >&2
  exit 1
fi
# Segunda execução: snapshot já limpo → N=0
GC_OUT2="$("$CMD" --gc)"
if ! grep -qE '^gc: 0 entries órfãs removidas$' <<< "$GC_OUT2"; then
  echo "FAIL AC9 (idempotência): segunda --gc deveria reportar 0, obteve: '$GC_OUT2'" >&2
  exit 1
fi
echo "PASS AC9 — --gc remove órfã + idempotente"

echo ""
echo "ALL TESTS PASSED"

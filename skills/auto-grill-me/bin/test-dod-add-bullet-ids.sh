#!/usr/bin/env bash
set -euo pipefail

# test-dod-add-bullet-ids.sh — testes para US-01 (dod-add-bullet-ids.sh).
#
# Cobre:
#   AC2  — --help → exit 0 + output não-vazio
#   AC3  — idempotência: 2º run detecta migration e exit 0 sem mutar
#   AC5  — write atômico (DOD.md inalterado em dry-run)
#   AC6  — todos bullets dentro dos blocos recebem [bN] sequencial
#   AC7  — todas as 28 entries marcadas, ≥100 bullets
#   AC8  — bullets_sha256 resincronizado para todas as 28 entries no snapshot
#          (entry inicial com bullets_sha256:"0" muda para sha real do bloco)
#   AC10 — bullet b4 da DoD-base Cat 1 ganha sufixo "(prefix `[US-XX]` ...)"
#
# Estratégia: monta esqueleto sintético em tmpdir (bin/ + references/) com
# fixture cobrindo 28 headings (mesma cardinalidade do DOD.md real) e
# ≥100 bullets totais. Copia o script alvo para o tmpdir — caminhos relativos
# a `dirname BASH_SOURCE` mantêm a operação isolada do DOD.md real.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="$SCRIPT_DIR/dod-add-bullet-ids.sh"

if [[ ! -x "$TARGET" ]]; then
  echo "FAIL: $TARGET inexistente ou não-executável" >&2
  exit 1
fi

TMP="$(mktemp -d -t dod-add-bullet-test.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/references"
cp "$TARGET" "$TMP/bin/"

CMD="$TMP/bin/dod-add-bullet-ids.sh"

# --- AC2: --help → exit 0 + output não-vazio com 'uso:' header ---
set +e
HELP_OUT="$("$CMD" --help 2>&1)"
EC=$?
set -e
if [[ "$EC" -ne 0 ]]; then
  echo "FAIL AC2: --help exit esperado=0, obtido=$EC" >&2
  exit 1
fi
if ! grep -q '^uso:' <<< "$HELP_OUT"; then
  echo "FAIL AC2: --help não contém 'uso:' header" >&2
  exit 1
fi
echo "PASS AC2 — --help retorna exit 0 + listagem"

# Fixture DOD.md: 8 DoD-base (cat 1..8) + 20 Tarefa = 28 headings.
# cat-1-base tem 5 bullets, sendo o 4º o bullet exato exigido pelo AC10.
# Cada um dos outros 27 blocos tem 5 bullets genéricos → total: 5*28 = 140 ≥ 100.
build_fixture() {
  {
    echo "# Definition of Done — fixture sintético"
    echo ""
    for cat in 1 2 3 4 5 6 7 8; do
      echo ""
      echo "## Categoria $cat — Lorem"
      echo ""
      echo "### DoD-base — Categoria $cat (usos: 0 · desde rev: 0)"
      echo ""
      if [[ $cat -eq 1 ]]; then
        echo "- [ ] bullet alpha cat $cat"
        echo "- [ ] bullet beta cat $cat"
        echo "- [ ] bullet gamma cat $cat"
        echo "- [ ] commitado em git com mensagem \`feat(claude): ...\`"
        echo "- [ ] bullet epsilon cat $cat"
      else
        for k in 1 2 3 4 5; do
          echo "- [ ] bullet $k cat $cat"
        done
      fi
    done
    echo ""
    echo "## Categoria 3 — Tarefas"
    for n in $(seq 1 20); do
      echo ""
      echo "### Tarefa $n — Algo (usos: 0 · desde rev: 0)"
      echo ""
      for k in 1 2 3 4 5; do
        echo "- [ ] bullet $k tarefa $n"
      done
    done
  } > "$TMP/references/DOD.md"
}

build_snapshot() {
  {
    echo '{'
    first=1
    for cat in 1 2 3 4 5 6 7 8; do
      [[ $first -eq 1 ]] || echo ','
      first=0
      printf '  "cat-%s-base": {"slug":"x","title_current":"x","bullets_sha256":"0","last_seen_iso":"2026-01-01T00:00:00Z"}' "$cat"
    done
    for t in $(seq 1 20); do
      echo ','
      printf '  "tarefa-%s": {"slug":"x","title_current":"x","bullets_sha256":"0","last_seen_iso":"2026-01-01T00:00:00Z"}' "$t"
    done
    echo ''
    echo '}'
  } > "$TMP/references/.dod-revision-state.json"
}

build_fixture
build_snapshot

# --- AC5 (dry-run): script imprime diff e NÃO muta DOD.md ---
PRE_SHA="$(sha256sum "$TMP/references/DOD.md" | cut -d' ' -f1)"
set +e
DRY_OUT="$("$CMD" --dry-run 2>&1)"
EC=$?
set -e
POST_SHA="$(sha256sum "$TMP/references/DOD.md" | cut -d' ' -f1)"
if [[ "$EC" -ne 0 ]]; then
  echo "FAIL AC5: --dry-run exit esperado=0, obtido=$EC" >&2
  echo "$DRY_OUT" >&2
  exit 1
fi
if [[ "$PRE_SHA" != "$POST_SHA" ]]; then
  echo "FAIL AC5: --dry-run mutou DOD.md (sha mudou)" >&2
  exit 1
fi
if ! grep -q -- '--- dry-run: nada gravado em disco ---' <<< "$DRY_OUT"; then
  echo "FAIL AC5: --dry-run não imprimiu marker esperado" >&2
  exit 1
fi
echo "PASS AC5 — --dry-run preserva DOD.md (sha inalterado)"

# --- AC6 + AC7 + AC10: aplica migration real ---
set +e
RUN_OUT="$("$CMD" 2>&1)"
EC=$?
set -e
if [[ "$EC" -ne 0 ]]; then
  echo "FAIL AC6: run exit esperado=0, obtido=$EC" >&2
  echo "$RUN_OUT" >&2
  exit 1
fi

# AC7: contagem total de bullets numerados ≥ 100 + casa com original
TOTAL_BN=$(grep -cE '^- \[ \] \[b[0-9]+\] ' "$TMP/references/DOD.md")
if [[ "$TOTAL_BN" -lt 100 ]]; then
  echo "FAIL AC7: $TOTAL_BN bullets numerados, esperado ≥ 100" >&2
  exit 1
fi
echo "PASS AC7 — $TOTAL_BN bullets numerados (≥100)"

# AC6: numeração reseta por bloco. Pega o primeiro bullet de Tarefa 1 e
# verifica que é [b1] (não continuação de bloco anterior).
FIRST_TAREFA1_BULLET=$(awk '
  /^### Tarefa 1 — / { in_t1 = 1; next }
  /^### / { in_t1 = 0 }
  in_t1 && /^- \[ \] / { print; exit }
' "$TMP/references/DOD.md")
if [[ "$FIRST_TAREFA1_BULLET" != "- [ ] [b1] bullet 1 tarefa 1" ]]; then
  echo "FAIL AC6: primeiro bullet de Tarefa 1 deveria ser '[b1]', obtido: '$FIRST_TAREFA1_BULLET'" >&2
  exit 1
fi
# Quinto bullet de Tarefa 5 deve ser [b5] (reset por bloco confirmado)
FIFTH_TAREFA5_BULLET=$(awk '
  /^### Tarefa 5 — / { in_t5 = 1; n = 0; next }
  /^### / { in_t5 = 0 }
  in_t5 && /^- \[ \] / { n += 1; if (n == 5) { print; exit } }
' "$TMP/references/DOD.md")
if [[ "$FIFTH_TAREFA5_BULLET" != "- [ ] [b5] bullet 5 tarefa 5" ]]; then
  echo "FAIL AC6: quinto bullet de Tarefa 5 deveria ser '[b5]', obtido: '$FIFTH_TAREFA5_BULLET'" >&2
  exit 1
fi
echo "PASS AC6 — numeração [bN] reseta por bloco (verificado em Tarefa 1 e 5)"

# AC10: bullet b4 da DoD-base cat 1 tem sufixo novo
AC10_HITS=$(grep -cF '(prefix `[US-XX]` aceito quando gerado pelo Ralph)' "$TMP/references/DOD.md")
if [[ "$AC10_HITS" -ne 1 ]]; then
  echo "FAIL AC10: sufixo presente em $AC10_HITS linhas (esperado 1)" >&2
  exit 1
fi
echo "PASS AC10 — bullet b4 cat-1-base recebeu sufixo de aprendizado meta"

# --- AC8: bullets_sha256 resincronizado para todas as 28 entries ---
ZEROS=$(jq -r 'to_entries | map(select(.value.bullets_sha256 == "0")) | length' "$TMP/references/.dod-revision-state.json")
if [[ "$ZEROS" -ne 0 ]]; then
  echo "FAIL AC8: $ZEROS entries ainda com bullets_sha256=\"0\" (snapshot não resincronizou)" >&2
  exit 1
fi
ENTRIES=$(jq 'keys | length' "$TMP/references/.dod-revision-state.json")
if [[ "$ENTRIES" -ne 28 ]]; then
  echo "FAIL AC8: snapshot tem $ENTRIES entries (esperado 28)" >&2
  exit 1
fi
# Sanity: sha de cat-1-base do snapshot bate com sha do bloco extraído manualmente
SNAP_SHA=$(jq -r '.["cat-1-base"].bullets_sha256' "$TMP/references/.dod-revision-state.json")
MANUAL_SHA=$(awk '
  function trim(s) { sub(/[ \t]+$/, "", s); return s }
  /^### DoD-base — Categoria 1 \(usos: 0 · desde rev: 0\)$/ { in_b = 1; next }
  /^### / || /^## / { in_b = 0 }
  in_b { print trim($0) }
' "$TMP/references/DOD.md" | sha256sum | cut -d' ' -f1)
if [[ "$SNAP_SHA" != "$MANUAL_SHA" ]]; then
  echo "FAIL AC8: snapshot sha de cat-1-base ($SNAP_SHA) != manual ($MANUAL_SHA)" >&2
  exit 1
fi
echo "PASS AC8 — snapshot tem 28 entries; bullets_sha256 casa com sha manual do bloco cat-1-base"

# --- AC3: idempotência — 2º run detecta migration e não muta ---
PRE_DOD_SHA="$(sha256sum "$TMP/references/DOD.md" | cut -d' ' -f1)"
PRE_STATE_SHA="$(sha256sum "$TMP/references/.dod-revision-state.json" | cut -d' ' -f1)"
set +e
RERUN_OUT="$("$CMD" 2>&1)"
RERUN_EC=$?
set -e
POST_DOD_SHA="$(sha256sum "$TMP/references/DOD.md" | cut -d' ' -f1)"
POST_STATE_SHA="$(sha256sum "$TMP/references/.dod-revision-state.json" | cut -d' ' -f1)"
if [[ "$RERUN_EC" -ne 0 ]]; then
  echo "FAIL AC3: re-run exit esperado=0, obtido=$RERUN_EC" >&2
  echo "$RERUN_OUT" >&2
  exit 1
fi
if ! grep -q '^já migrado: ' <<< "$RERUN_OUT"; then
  echo "FAIL AC3: re-run não imprimiu 'já migrado: ...'" >&2
  echo "$RERUN_OUT" >&2
  exit 1
fi
if [[ "$PRE_DOD_SHA" != "$POST_DOD_SHA" ]]; then
  echo "FAIL AC3: re-run mutou DOD.md (sha mudou)" >&2
  exit 1
fi
if [[ "$PRE_STATE_SHA" != "$POST_STATE_SHA" ]]; then
  echo "FAIL AC3: re-run mutou snapshot (sha mudou)" >&2
  exit 1
fi
echo "PASS AC3 — re-run detecta migration, exit 0, DOD.md e snapshot preservados"

echo ""
echo "ALL TESTS PASSED"

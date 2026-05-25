#!/usr/bin/env bash
set -euo pipefail

# test-dod-add-bullet-ids.sh — testes para dod-add-bullet-ids.sh.
#
# Cobre:
#   AC2  — --help → exit 0 + output não-vazio
#   AC3 (US-04) — heading SEM o sufixo `(usos…)` (estado pós-US-03): o [bN] é
#                 adicionado por match de prefixo e a detecção de cat-1-base
#                 (AC10) funciona sem o espaço que o sufixo fornecia.
#   AC3' (US-01) — idempotência: 2º run detecta migration e exit 0 sem mutar
#   AC5  — write atômico (DOD.md inalterado em dry-run)
#   AC6  — todos bullets dentro dos blocos recebem [bN] sequencial (reseta por bloco)
#   AC7  — ≥100 bullets numerados
#   AC10 — bullet b4 da DoD-base Cat 1 ganha sufixo "(prefix `[US-XX]` ...)"
#   AC4  — lock contention → exit 3 após ~5s de retries
#
# US-04: o snapshot `.dod-revision-state.json` foi removido (US-03); o script não
# escreve mais .json de estado, então NÃO há fixture/asserção de snapshot.
#
# Estratégia: esqueleto sintético em tmpdir (bin/ + references/) com fixture
# SOURCE-PURO (headings sem sufixo) cobrindo 28 headings e ≥100 bullets. Copia o
# script alvo — caminhos relativos a `dirname BASH_SOURCE` isolam do DOD.md real.

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

# Fixture DOD.md SOURCE-PURO (headings SEM sufixo `(usos…)` — estado pós-US-03).
# 8 DoD-base (cat 1..8) + 20 Tarefa = 28 headings. cat-1-base tem 5 bullets, o
# 4º é o bullet exato exigido pelo AC10. Total: 5*28 = 140 ≥ 100.
build_fixture() {
  {
    echo "# Definition of Done — fixture sintético"
    echo ""
    for cat in 1 2 3 4 5 6 7 8; do
      echo ""
      echo "## Categoria $cat — Lorem"
      echo ""
      echo "### DoD-base — Categoria $cat"
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
      echo "### Tarefa $n — Algo"
      echo ""
      for k in 1 2 3 4 5; do
        echo "- [ ] bullet $k tarefa $n"
      done
    done
  } > "$TMP/references/DOD.md"
}

build_fixture

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

# --- AC6 + AC7 + AC10 + AC3(US-04): aplica migration real sobre fixture sem sufixo ---
set +e
RUN_OUT="$("$CMD" 2>&1)"
EC=$?
set -e
if [[ "$EC" -ne 0 ]]; then
  echo "FAIL AC6: run exit esperado=0, obtido=$EC" >&2
  echo "$RUN_OUT" >&2
  exit 1
fi

# AC7: contagem total de bullets numerados ≥ 100
TOTAL_BN=$(grep -cE '^- \[ \] \[b[0-9]+\] ' "$TMP/references/DOD.md")
if [[ "$TOTAL_BN" -lt 100 ]]; then
  echo "FAIL AC7: $TOTAL_BN bullets numerados, esperado ≥ 100" >&2
  exit 1
fi
echo "PASS AC7 — $TOTAL_BN bullets numerados (≥100)"

# AC6: numeração reseta por bloco. Pega o primeiro bullet de Tarefa 1 → [b1].
FIRST_TAREFA1_BULLET=$(awk '
  /^### Tarefa 1 — / { in_t1 = 1; next }
  /^### / { in_t1 = 0 }
  in_t1 && /^- \[ \] / { print; exit }
' "$TMP/references/DOD.md")
if [[ "$FIRST_TAREFA1_BULLET" != "- [ ] [b1] bullet 1 tarefa 1" ]]; then
  echo "FAIL AC6: primeiro bullet de Tarefa 1 deveria ser '[b1]', obtido: '$FIRST_TAREFA1_BULLET'" >&2
  exit 1
fi
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

# AC10 + AC3(US-04): bullet b4 da DoD-base cat 1 (heading SEM sufixo) tem sufixo novo.
# Antes do fix, a detecção de cat-1-base exigia o espaço do sufixo → falharia aqui.
# shellcheck disable=SC2016  # literal com backticks/brackets — aspas simples são intencionais
AC10_HITS=$(grep -cF '(prefix `[US-XX]` aceito quando gerado pelo Ralph)' "$TMP/references/DOD.md")
if [[ "$AC10_HITS" -ne 1 ]]; then
  echo "FAIL AC10/AC3: sufixo presente em $AC10_HITS linhas (esperado 1) — heading sem sufixo não detectado?" >&2
  exit 1
fi
echo "PASS AC10/AC3(US-04) — cat-1-base detectado em heading SOURCE-PURO; b4 recebeu sufixo"

# --- AC3 (US-01) idempotência: 2º run detecta migration e não muta ---
PRE_DOD_SHA="$(sha256sum "$TMP/references/DOD.md" | cut -d' ' -f1)"
set +e
RERUN_OUT="$("$CMD" 2>&1)"
RERUN_EC=$?
set -e
POST_DOD_SHA="$(sha256sum "$TMP/references/DOD.md" | cut -d' ' -f1)"
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
echo "PASS AC3 — re-run detecta migration, exit 0, DOD.md preservado"

# --- US-04: nenhum .json de estado escrito pelo script ---
if find "$TMP/references" -name '*revision-state.json' | grep -q .; then
  echo "FAIL US-04: script escreveu snapshot .json (esperado nenhum — M7)" >&2
  exit 1
fi
echo "PASS US-04 — nenhum snapshot .json escrito (resync removido)"

# --- AC4: lock contention → exit 3 após ~5s de retries ---
LOCK_PATH="$TMP/references/.dod-add-bullet-ids.lock"
mkdir "$LOCK_PATH"
START_TS=$(date +%s)
set +e
"$CMD" >/tmp/ac4-out.txt 2>/tmp/ac4-err.txt
AC4_EC=$?
set -e
END_TS=$(date +%s)
AC4_ELAPSED=$((END_TS - START_TS))
rmdir "$LOCK_PATH" 2>/dev/null || true
if [[ "$AC4_EC" -ne 3 ]]; then
  echo "FAIL AC4: lock contention exit esperado=3, obtido=$AC4_EC" >&2
  cat /tmp/ac4-err.txt >&2
  exit 1
fi
if [[ "$AC4_ELAPSED" -lt 4 || "$AC4_ELAPSED" -gt 8 ]]; then
  echo "FAIL AC4: tempo de retry esperado ~5s (4-8), obtido ${AC4_ELAPSED}s" >&2
  exit 1
fi
if ! grep -q 'lock .* ocupado' /tmp/ac4-err.txt; then
  echo "FAIL AC4: mensagem de erro esperada não encontrada em stderr" >&2
  cat /tmp/ac4-err.txt >&2
  exit 1
fi
echo "PASS AC4 — lock contention exit 3 após ${AC4_ELAPSED}s + mensagem correta"

echo ""
echo "ALL TESTS PASSED"

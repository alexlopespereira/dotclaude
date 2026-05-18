#!/usr/bin/env bash
set -euo pipefail

# test-dod-migrate-partial.sh — AC12 fixture/test (US-02).
#
# Garante que dod-migrate-add-counters.sh detecta "estado parcial" — alguns
# headings já no padrão `(usos: N · desde rev: M)` e outros não — e aborta
# com exit 1 + mensagem em stderr.
#
# Estratégia: monta um esqueleto sintético de skill (bin/ + references/) em
# tmpdir e copia o script alvo para lá. O script usa caminhos relativos a
# `dirname BASH_SOURCE`, então opera contra o fixture sem mexer no DOD.md real.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MIGRATE_SCRIPT="$SCRIPT_DIR/dod-migrate-add-counters.sh"

if [[ ! -x "$MIGRATE_SCRIPT" ]]; then
  echo "FAIL: $MIGRATE_SCRIPT não existe ou não é executável" >&2
  exit 1
fi

TMP="$(mktemp -d -t dod-partial-test.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/references"
cp "$MIGRATE_SCRIPT" "$TMP/bin/"

# Fixture: 8 DoD-base + 20 Tarefa = 28 headings totais (mesma cardinalidade
# do DOD.md real); metade migrada, metade não → hits o ramo "partial".
{
  echo "# Definition of Done — fixture sintético"
  echo ""
  echo "Sincronizar este arquivo quando a fonte mudar."
  echo ""
  echo "DoD-base aplica-se a todas as tarefas dentro de cada categoria."
  for cat in 1 2 3 4 5 6 7 8; do
    echo ""
    echo "## Categoria $cat — Lorem"
    echo ""
    if [[ $cat -le 4 ]]; then
      echo "### DoD-base — Categoria $cat (usos: 0 · desde rev: 0)"
    else
      echo "### DoD-base"
    fi
    echo ""
    echo "- bullet base cat $cat"
  done
  for n in $(seq 1 20); do
    echo ""
    if [[ $n -le 10 ]]; then
      echo "### Tarefa $n — Algo (usos: 0 · desde rev: 0)"
    else
      echo "### Tarefa $n — Outro"
    fi
    echo ""
    echo "- bullet tarefa $n"
  done
} > "$TMP/references/DOD.md"

set +e
STDERR="$("$TMP/bin/dod-migrate-add-counters.sh" 2>&1 >/dev/null)"
EXIT_CODE=$?
set -e

if [[ "$EXIT_CODE" -ne 1 ]]; then
  echo "FAIL: exit esperado=1, obtido=$EXIT_CODE" >&2
  echo "stderr capturado:" >&2
  echo "$STDERR" >&2
  exit 1
fi

if ! grep -q "estado parcial detectado" <<< "$STDERR"; then
  echo "FAIL: stderr não contém 'estado parcial detectado'" >&2
  echo "stderr capturado:" >&2
  echo "$STDERR" >&2
  exit 1
fi

# Garante que DOD.md do fixture não foi mutado (script aborta antes de tocar)
ORIG_SHA="$(sha256sum "$TMP/references/DOD.md" | cut -d' ' -f1)"
# Re-roda para confirmar idempotência do abort path
set +e
"$TMP/bin/dod-migrate-add-counters.sh" >/dev/null 2>&1
RERUN_EXIT=$?
set -e
NEW_SHA="$(sha256sum "$TMP/references/DOD.md" | cut -d' ' -f1)"

if [[ "$RERUN_EXIT" -ne 1 ]]; then
  echo "FAIL: re-run em estado parcial deveria retornar exit 1, obteve $RERUN_EXIT" >&2
  exit 1
fi
if [[ "$ORIG_SHA" != "$NEW_SHA" ]]; then
  echo "FAIL: DOD.md mutado mesmo no abort path (sha mudou)" >&2
  exit 1
fi

echo "PASS: AC12 — partial state detection (exit=1, stderr matches, DOD.md preservado)"

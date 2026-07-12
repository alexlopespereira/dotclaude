#!/usr/bin/env bash
# run-all.sh — executa toda a suíte bin/tests/test_*.sh e falha se qualquer uma falhar.
#
# O QUE FAZ: descobre os test_*.sh deste diretório, roda cada um em processo
# próprio, imprime 1 linha de status por suíte e um sumário; exit 1 se houver
# falha (gate de CI), exit 0 só com tudo verde.
#
# QUANDO USAR: localmente antes de commit (`bin/tests/run-all.sh`) e no CI
# (.github/workflows/tests.yml — runner ubuntu-latest: as suítes são portáveis,
# idioms GNU-first com fallback BSD, e rodam nos 2 OSes).
#
# Encerramento: roda até o fim mesmo com falhas (relata todas), sem args.

set -u

[ $# -eq 0 ] || { echo "Uso: run-all.sh (sem argumentos)" >&2; exit 2; }

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fails=0; total=0

for t in "$TESTS_DIR"/test_*.sh; do
  [ -f "$t" ] || continue
  total=$((total+1))
  out=$(bash "$t" 2>&1); rc=$?
  last=$(printf '%s\n' "$out" | tail -1)
  if [ "$rc" -ne 0 ]; then
    fails=$((fails+1))
    echo "FAIL(rc=$rc) $(basename "$t")"
    printf '%s\n' "$out" | tail -15
  else
    echo "ok   $(basename "$t") :: $last"
  fi
done

echo "── run-all: $((total-fails))/$total suítes verdes ──"
[ "$fails" -gt 0 ] && exit 1
exit 0

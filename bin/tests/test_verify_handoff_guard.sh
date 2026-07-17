#!/usr/bin/env bash
set -u

# test_verify_handoff_guard.sh — ponte de CI para a suíte de regressão do hook
# hooks/verify-before-handoff-guard.sh (Princípio 14 / skill verify-before-handoff).
#
# POR QUÊ: o teste canônico vive junto da skill em
# skills/verify-before-handoff/bin/test-hook-guard.sh (co-locado com o artefato
# que valida), mas run-all.sh só descobre bin/tests/test_*.sh. Sem esta ponte o
# teste passava só localmente e o gate de CI ficava cego a regressões do hook —
# a mesma lacuna "só rodava local" que motivou o próprio tests.yml. Espelha o
# padrão de bin/tests/test_browser_secrets_lifecycle.sh (bloco AC6).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REG="$REPO_ROOT/skills/verify-before-handoff/bin/test-hook-guard.sh"

if [ ! -f "$REG" ]; then
  echo "test_verify_handoff_guard.sh: FAIL :: $REG ausente" >&2
  exit 1
fi

REG_OUT="$(bash "$REG" 2>&1)"; REG_RC=$?
if [ "$REG_RC" -ne 0 ]; then
  echo "test_verify_handoff_guard.sh: FAIL :: test-hook-guard.sh vermelho (rc=$REG_RC)" >&2
  printf '%s\n' "$REG_OUT" | tail -8 >&2
  exit 1
fi

echo "test_verify_handoff_guard.sh: PASS (ponte → test-hook-guard.sh)"

#!/bin/bash
# reset.sh — Recovery do Playwright MCP: mata processos órfãos e remove
# locks de TODOS os profiles per-slot em ~/.claude/chrome-profile-*/.
# Mantém user-data (cookies, sessões) intactos.
#
# Use quando: lock órfão impede nova sessão, ou wrapper hanging detectado.

set -euo pipefail

echo "→ Matando processos mcp-chrome-* remanescentes..."
if pkill -f "mcp-chrome-" 2>/dev/null; then
  echo "  alguns processos terminados."
else
  echo "  nenhum processo mcp-chrome encontrado."
fi

echo "→ Matando wrapper-launch.sh remanescentes..."
if pkill -f "wrapper-launch.sh" 2>/dev/null; then
  echo "  alguns wrappers terminados."
else
  echo "  nenhum wrapper encontrado."
fi

echo "→ Removendo locks de todos os profiles per-slot..."
REMOVED=0
for d in "$HOME"/.claude/chrome-profile-*/; do
  [ -d "$d" ] || continue
  if [ -d "${d}.lock" ]; then
    rm -rf "${d}.lock"
    echo "  removido: ${d}.lock"
    REMOVED=$((REMOVED+1))
  fi
done

# Compat: lock global antigo (pré profile per-slot)
if [ -d "$HOME/.claude/chrome-profile/.lock" ]; then
  rm -rf "$HOME/.claude/chrome-profile/.lock"
  echo "  removido: ~/.claude/chrome-profile/.lock (legacy)"
  REMOVED=$((REMOVED+1))
fi

[ "$REMOVED" -eq 0 ] && echo "  nenhum lock pendente."
echo "→ Reset completo. User-data (cookies, sessões) preservado."

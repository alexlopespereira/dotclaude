#!/bin/bash
# cleanup-stale-mcp.sh — Remove entries 'playwright' legadas/duplicadas
# em .mcp.json de checkouts e worktrees.
#
# Background: ~/.claude/settings.json registra o wrapper user-scope
# (@playwright/mcp@latest via wrapper-launch.sh). Entries 'playwright'
# em .mcp.json per-repo apontando pro @anthropic-ai/mcp-playwright
# (legado) duplicam o MCP — claude mcp list mostra 2 entries e ambas
# falham. Muitas vezes carregam env vars hardcoded inválidas
# (ex: PLAYWRIGHT_USER_DATA_DIR=C:/Users/... em macOS).
#
# Solução: deletar entry 'playwright' do JSON; o wrapper global cobre.
# Backup preservado em .bak-<timestamp>.

set -euo pipefail

PATCHED=0
for f in ~/Projects/checkouts/*/.mcp.json ~/Projects/worktrees/*/.mcp.json; do
  [ -f "$f" ] || continue
  if jq -e '.mcpServers.playwright' "$f" >/dev/null 2>&1; then
    bak="${f}.bak-$(date +%s)"
    cp "$f" "$bak"
    jq 'del(.mcpServers.playwright)' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
    echo "patched: $f (backup em $bak)"
    PATCHED=$((PATCHED+1))
  fi
done

if [ "$PATCHED" -eq 0 ]; then
  echo "Nenhum .mcp.json com entry 'playwright' duplicada encontrado."
else
  echo "Total: $PATCHED arquivo(s) patcheado(s). Backups com sufixo .bak-<ts>."
fi

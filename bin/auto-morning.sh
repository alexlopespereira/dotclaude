#!/usr/bin/env bash
# auto-morning.sh — Wrapper executado pelo LaunchAgent ao login do macOS.
# Edite os argumentos abaixo para customizar o que abrir automaticamente.
#
# Logs em ~/.claude/cache/auto-morning.log

set -uo pipefail

LOG="$HOME/.claude/cache/auto-morning.log"
mkdir -p "$(dirname "$LOG")"

{
  echo "═══ $(date -u +%Y-%m-%dT%H:%M:%SZ) — auto-morning iniciando ═══"

  # PATH explícito (LaunchAgent não herda do shell)
  export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$HOME/.npm-global/bin:/usr/bin:/bin:/usr/sbin:/sbin"

  # Aguarda iTerm e Dock estarem prontos (até 30s)
  for i in $(seq 1 30); do
    if pgrep -x Dock >/dev/null && [ -d /Applications/iTerm.app ]; then
      break
    fi
    sleep 1
  done

  # ============== CUSTOMIZE AQUI ==============
  # O trabalho (storefront/etl-crm/wikiapp) migrou pras VMs UTM. Em vez de
  # abrir abas em checkouts locais (morning.sh), abrimos sessões SSH+Claude nas
  # VMs via vm-morning.sh. Edite a lista de abas no topo desse script.
  VM_MORNING="$HOME/Projects/dotclaude/vm-morning.sh"
  # =============================================

  if [ ! -x "$VM_MORNING" ]; then
    echo "ERRO: vm-morning.sh não encontrado/executável em $VM_MORNING." >&2
    exit 1
  fi

  echo "→ executando: $VM_MORNING"
  bash "$VM_MORNING"
  echo "═══ concluído ═══"
} >> "$LOG" 2>&1

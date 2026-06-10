#!/usr/bin/env bash
# auto-morning.sh — Wrapper executado pelo LaunchAgent ao login do macOS.
# Edite os argumentos abaixo para customizar o que abrir automaticamente.
#
# Logs em ~/.claude/cache/auto-morning.log

set -uo pipefail

# Seams de teste (env) — defaults = comportamento de produção.
#   AM_LOG           path do log (default ~/.claude/cache/auto-morning.log)
#   AM_VM_MORNING    wrapper que abre as sessões VM (default vm-morning.sh)
#   AM_REFLECT_RETRO drenador de retros vencidas (default bin/reflect-retro-due.sh)
#   AM_SKIP_WAIT     1 = pula a espera por iTerm/Dock (testes não dependem da UI)
LOG="${AM_LOG:-$HOME/.claude/cache/auto-morning.log}"
mkdir -p "$(dirname "$LOG")"

{
  echo "═══ $(date -u +%Y-%m-%dT%H:%M:%SZ) — auto-morning iniciando ═══"

  # PATH explícito (LaunchAgent não herda do shell)
  export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$HOME/.npm-global/bin:/usr/bin:/bin:/usr/sbin:/sbin"

  # Aguarda iTerm e Dock estarem prontos (até 30s)
  if [ "${AM_SKIP_WAIT:-0}" != "1" ]; then
    for i in $(seq 1 30); do
      if pgrep -x Dock >/dev/null && [ -d /Applications/iTerm.app ]; then
        break
      fi
      sleep 1
    done
  fi

  # ============== CUSTOMIZE AQUI ==============
  # O trabalho (storefront/etl-crm/wikiapp) migrou pras VMs UTM. Em vez de
  # abrir abas em checkouts locais (morning.sh), abrimos sessões SSH+Claude nas
  # VMs via vm-morning.sh. Edite a lista de abas no topo desse script.
  VM_MORNING="${AM_VM_MORNING:-$HOME/Projects/dotclaude/vm-morning.sh}"
  REFLECT_RETRO="${AM_REFLECT_RETRO:-$HOME/Projects/dotclaude/bin/reflect-retro-due.sh}"
  # =============================================

  if [ ! -x "$VM_MORNING" ]; then
    echo "ERRO: vm-morning.sh não encontrado/executável em $VM_MORNING." >&2
    exit 1
  fi

  echo "→ executando: $VM_MORNING"
  bash "$VM_MORNING"

  # Drena retrospectivas /reflect vencidas (headless), non-blocking: uma falha
  # aqui NÃO derruba o auto-morning. O PATH explícito acima (inclui ~/.local/bin)
  # já alcança o `claude` que o script resolve internamente.
  if [ -x "$REFLECT_RETRO" ]; then
    echo "→ drenando retros vencidas: $REFLECT_RETRO --max 2"
    bash "$REFLECT_RETRO" --max 2 || true
  else
    echo "→ reflect-retro-due.sh ausente/não-executável em $REFLECT_RETRO — pulado."
  fi

  echo "═══ concluído ═══"
} >> "$LOG" 2>&1

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
  # Pool e flags do morning. Adicione mais blocos se quiser múltiplos pools.
  POOL="horizons"
  FLAGS=(--yolo --names=feature-a,tests,bugfix,spike --no-sync)
  # =============================================

  MORNING="$HOME/Projects/dotclaude/bin/morning.sh"
  [ -x "$MORNING" ] || MORNING="$HOME/.claude/bin/morning.sh"

  if [ ! -x "$MORNING" ]; then
    echo "ERRO: morning.sh não encontrado." >&2
    exit 1
  fi

  echo "→ executando: morning.sh $POOL ${FLAGS[*]}"
  bash "$MORNING" "$POOL" "${FLAGS[@]}"
  echo "═══ concluído ═══"
} >> "$LOG" 2>&1

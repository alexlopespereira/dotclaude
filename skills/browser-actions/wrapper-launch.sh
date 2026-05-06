#!/bin/bash
# wrapper-launch.sh — Lock multi-slot pro perfil Chrome dedicado.
#
# Workflow Boris tem 5 checkouts paralelos; 2+ sessões Claude Code podem
# tentar usar o browser simultaneamente. Chromium ProcessSingleton quebra
# nesse caso (lockfile no perfil + processo zumbi). Este wrapper serializa
# via mkdir atomic lock (macOS não tem flock CLI; só syscall em libc).
#
# Robustez contra SIGKILL do cliente MCP: lock guarda PID do wrapper.
# Se mkdir falhar mas o PID dono não está vivo, considera lock órfão e
# limpa. Mitiga: trap não roda em SIGKILL, então lock pode ficar preso
# após `claude mcp list` timeout-killar o wrapper.
#
# Invocado pelo MCP em ~/.claude.json (escopo user):
#   playwright -> /Users/dev/.claude/skills/browser-actions/wrapper-launch.sh
#
# Argumentos extras ($@) são repassados ao @playwright/mcp.

set -euo pipefail

LOCK_DIR="$HOME/.claude/chrome-profile/.lock"
PID_FILE="$LOCK_DIR/pid"
mkdir -p "$(dirname "$LOCK_DIR")"

acquire_lock() {
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    return 0
  fi

  # Lock existe — verificar se é órfão.
  local old_pid=""
  [ -f "$PID_FILE" ] && old_pid=$(cat "$PID_FILE" 2>/dev/null || true)

  if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
    return 1  # dono vivo, lock válido
  fi

  # Órfão — limpar e tentar de novo (race-prone, mas best-effort).
  rm -rf "$LOCK_DIR" 2>/dev/null || true
  mkdir "$LOCK_DIR" 2>/dev/null || return 1
  return 0
}

if ! acquire_lock; then
  echo "ERRO: outro slot Claude Code já está usando o perfil Chrome dedicado." >&2
  echo "Aguarde aquela sessão terminar, ou rmdir $LOCK_DIR se for lock órfão." >&2
  exit 99
fi

echo $$ > "$PID_FILE"

cleanup() { rm -rf "$LOCK_DIR" 2>/dev/null || true; }
trap cleanup EXIT INT TERM HUP

# Não usa exec — wrapper precisa continuar vivo pra trap rodar e limpar lock.
# Sinais propagam ao filho automaticamente (mesmo grupo de processo).
npx -y @playwright/mcp@latest \
  --user-data-dir "$HOME/.claude/chrome-profile" \
  --browser chrome \
  "$@"

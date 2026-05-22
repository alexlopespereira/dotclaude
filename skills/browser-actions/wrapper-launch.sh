#!/bin/bash
# wrapper-launch.sh — Lock multi-slot pro perfil Chrome dedicado (per-slot).
#
# Workflow Boris tem 5 checkouts paralelos; 2+ sessões Claude Code podem
# tentar usar o browser simultaneamente. Chromium ProcessSingleton quebra
# nesse caso (lockfile no perfil + processo zumbi).
#
# Solução: profile separado por slot em ~/.claude/chrome-profile-<slot>/.
# Cada slot é independente — sem fila, sem competição. Custo: re-login
# em cada slot (cookies não compartilhados entre profiles).
#
# Resolução do slot:
#   1. env $CLAUDE_SLOT_NAME se definida (override explícito)
#   2. basename($PWD) se bate <repo>-<N> (pool Boris)
#   3. "default" (repos diretos, worktrees, etc.)
#
# Robustez: lock ainda existe per-profile pra cobrir múltiplas Claude Code
# sessions no MESMO slot (raro, mas possível). Trap limpa em SIGINT/TERM/HUP.
# SIGKILL deixa órfão — acquire_lock detecta via kill -0 no PID gravado.
#
# Invocado pelo MCP em ~/.claude.json (escopo user):
#   playwright -> /Users/dev/.claude/skills/browser-actions/wrapper-launch.sh
#
# Argumentos extras ($@) são repassados ao @playwright/mcp.

set -euo pipefail

# Resolver slot
SLOT="${CLAUDE_SLOT_NAME:-}"
if [ -z "$SLOT" ]; then
  CWD_BASE=$(basename "$PWD")
  if [[ "$CWD_BASE" =~ ^([a-z0-9-]+)-([1-5])$ ]]; then
    SLOT="$CWD_BASE"
  else
    SLOT="default"
  fi
fi

PROFILE_DIR="$HOME/.claude/chrome-profile-${SLOT}"
LOCK_DIR="$PROFILE_DIR/.lock"
PID_FILE="$LOCK_DIR/pid"
mkdir -p "$PROFILE_DIR"

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
  echo "ERRO: outra Claude Code session já está usando o profile do slot '$SLOT'." >&2
  echo "      profile: $PROFILE_DIR" >&2
  echo "      lock:    $LOCK_DIR" >&2
  echo "Aguarde aquela sessão terminar, ou rode reset.sh se for lock órfão." >&2
  exit 99
fi

echo $$ > "$PID_FILE"

cleanup() { rm -rf "$LOCK_DIR" 2>/dev/null || true; }
trap cleanup EXIT INT TERM HUP

# Não usa exec — wrapper precisa continuar vivo pra trap rodar e limpar lock.
# Sinais propagam ao filho automaticamente (mesmo grupo de processo).
npx -y @playwright/mcp@latest \
  --user-data-dir "$PROFILE_DIR" \
  --browser chrome \
  "$@"

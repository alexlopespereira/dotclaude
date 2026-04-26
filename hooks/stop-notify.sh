#!/usr/bin/env bash
# stop-notify.sh — Notifica via macOS quando Claude para (Stop hook).
# Workflow Boris: notificação leve por slot.
#
# Opt-out: export CLAUDE_QUIET_NOTIFY=1
# Debounce: 30s por session_id (evita spam em runs longos com muitas paradas).

set -e

# Opt-out global
[ "${CLAUDE_QUIET_NOTIFY:-0}" = "1" ] && exit 0

# Lê session_id do payload JSON em stdin (best-effort)
PAYLOAD="$(cat 2>/dev/null || true)"
SESSION_ID=$(printf '%s' "$PAYLOAD" | grep -o '"session_id":"[^"]*"' | head -1 | cut -d'"' -f4)
SESSION_ID="${SESSION_ID:-default}"

# Debounce
CACHE_DIR="$HOME/.claude/cache/stop-notify"
mkdir -p "$CACHE_DIR"
FLAG="$CACHE_DIR/$SESSION_ID"

if [ -f "$FLAG" ]; then
  LAST=$(stat -f %m "$FLAG" 2>/dev/null || echo 0)
  NOW=$(date +%s)
  DELTA=$(( NOW - LAST ))
  [ "$DELTA" -lt 30 ] && exit 0
fi
touch "$FLAG"

# Slot name + número a partir do cwd
CWD=$(pwd)
SLOT_NUM=""
case "$CWD" in
  "$HOME/Projects/checkouts"/*)
    SLOT_NAME=$(basename "$CWD")
    # Extrai sufixo numérico (-1, -2, ...)
    SLOT_NUM=$(echo "$SLOT_NAME" | grep -oE '[0-9]+$' || true)
    ;;
  *)
    SLOT_NAME=$(basename "$CWD")
    ;;
esac

# Som distinto por slot (1..5). Sons macOS em /System/Library/Sounds/
case "$SLOT_NUM" in
  1) SOUND="Pop" ;;
  2) SOUND="Glass" ;;
  3) SOUND="Tink" ;;
  4) SOUND="Frog" ;;
  5) SOUND="Hero" ;;
  *) SOUND="Pop" ;;
esac

# Disparar notificação
osascript -e "display notification \"Sessão pronta para input em $SLOT_NAME\" with title \"Claude Code\" sound name \"$SOUND\"" 2>/dev/null || true

exit 0

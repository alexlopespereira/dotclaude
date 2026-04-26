#!/usr/bin/env bash
# checkout-launch.sh — Abre 1 janela com N abas (uma por slot do pool de checkouts).
# Default: 5 slots (workflow Boris Cherny).
#
# Uso:
#   checkout-launch.sh <repo> [opções]
#
# Opções:
#   --slots=LIST       Slots a abrir (default: todos). Ex: --slots=1,3,5
#   --claude           Roda `claude` em cada aba.
#   --skip-permissions Roda `claude --dangerously-skip-permissions` (alias: --yolo). Implica --claude.
#   --names=LIST       Labels para sessões claude (1 por slot). Ex: --names=feature-a,feature-b,tests,bugfix,docs
#                      Implica --claude. Vira `claude --name <label>` quando claude suportar.
#   --cmd "CMD"        Comando customizado em cada aba (mutuamente exclusivo com --claude).
#   --app=APP          Força 'iterm' ou 'terminal'. Default: detecta.
#
# Pré-req: pool criado via /checkout-init e Terminal.app com:
#   defaults write com.apple.Terminal AppleWindowTabbingMode -string "always"

set -euo pipefail

CHECKOUT_BASE="$HOME/Projects/checkouts"

REPO=""
SLOTS_FILTER=""
RUN_CLAUDE=false
SKIP_PERMS=false
NAMES=""
CUSTOM_CMD=""
APP_OVERRIDE=""

usage() {
  cat <<EOF
Uso: $(basename "$0") <repo> [opções]

Opções:
  --slots=LIST       Slots a abrir (default: todos). Ex: --slots=1,3,5
  --claude           Roda 'claude' em cada aba
  --skip-permissions Roda 'claude --dangerously-skip-permissions' (alias: --yolo)
  --names=LIST       Labels (1 por slot) — implica --claude. Ex: feature-a,feature-b,tests,bugfix,docs
  --cmd "CMD"        Comando customizado em cada aba
  --app=APP          'iterm' ou 'terminal' (default: detecta)
  -h, --help         Esta mensagem
EOF
  exit 0
}

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage ;;
    --slots=*) SLOTS_FILTER="${1#*=}" ;;
    --claude) RUN_CLAUDE=true ;;
    --skip-permissions|--yolo) SKIP_PERMS=true; RUN_CLAUDE=true ;;
    --names=*) NAMES="${1#*=}"; RUN_CLAUDE=true ;;
    --cmd=*) CUSTOM_CMD="${1#*=}" ;;
    --cmd) shift; CUSTOM_CMD="${1:-}" ;;
    --app=*) APP_OVERRIDE="${1#*=}" ;;
    -*) echo "Flag desconhecida: $1" >&2; exit 1 ;;
    *)
      if [ -z "$REPO" ]; then REPO="$1"
      else echo "Argumento extra ignorado: $1" >&2
      fi
      ;;
  esac
  shift
done

[ -z "$REPO" ] && { echo "ERRO: passe <repo>. -h para ajuda." >&2; exit 1; }

# Descobrir slots disponíveis (compat bash 3.2)
ALL_SLOTS=()
while IFS= read -r line; do
  [ -n "$line" ] && ALL_SLOTS+=("$line")
done < <(find "$CHECKOUT_BASE" -maxdepth 1 -type d -name "${REPO}-*" 2>/dev/null \
  | sed -E "s|.*/${REPO}-||" \
  | grep -E '^[0-9]+$' \
  | sort -n)

if [ ${#ALL_SLOTS[@]} -eq 0 ]; then
  echo "ERRO: nenhum slot em $CHECKOUT_BASE/${REPO}-*. Rode /checkout-init <repo-url>." >&2
  exit 1
fi

# Aplicar filtro --slots
if [ -n "$SLOTS_FILTER" ]; then
  IFS=',' read -ra REQ <<< "$SLOTS_FILTER"
  SLOTS=()
  for r in "${REQ[@]}"; do
    r=$(echo "$r" | tr -d ' ')
    [ -d "$CHECKOUT_BASE/${REPO}-${r}/.git" ] && SLOTS+=("$r") || echo "AVISO: slot $r não existe, pulando." >&2
  done
else
  SLOTS=("${ALL_SLOTS[@]}")
fi

[ ${#SLOTS[@]} -eq 0 ] && { echo "ERRO: nenhum slot válido." >&2; exit 1; }

# Parse names
NAME_ARR=()
if [ -n "$NAMES" ]; then
  IFS=',' read -ra NAME_ARR <<< "$NAMES"
fi

# Detectar terminal app
APP="${APP_OVERRIDE:-}"
if [ -z "$APP" ]; then
  case "${TERM_PROGRAM:-}" in
    iTerm.app) APP="iterm" ;;
    Apple_Terminal) APP="terminal" ;;
    *) APP=$([ -d "/Applications/iTerm.app" ] && echo "iterm" || echo "terminal") ;;
  esac
fi

# Comando inicial por slot (índice 0 = primeiro slot)
build_cmd() {
  local slot_path="$1"
  local idx="$2"
  local cmd="cd \"$slot_path\""

  if [ -n "$CUSTOM_CMD" ]; then
    cmd="$cmd && $CUSTOM_CMD"
  elif [ "$RUN_CLAUDE" = "true" ]; then
    local claude_cmd="claude"
    [ "$SKIP_PERMS" = "true" ] && claude_cmd="claude --dangerously-skip-permissions"

    if [ ${#NAME_ARR[@]} -gt "$idx" ]; then
      local label="${NAME_ARR[$idx]}"
      label=$(echo "$label" | tr -d ' ')
      # claude aceita --name? Versões recentes sim; se não, é ignorado/falha silenciosa.
      cmd="$cmd && $claude_cmd --name \"$label\" 2>/dev/null || (cd \"$slot_path\" && $claude_cmd)"
    else
      cmd="$cmd && $claude_cmd"
    fi
  fi
  echo "$cmd"
}

applescript_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

open_iterm_tabs() {
  local first=true
  local idx=0
  for slot in "${SLOTS[@]}"; do
    local slot_path="$CHECKOUT_BASE/${REPO}-${slot}"
    local cmd
    cmd=$(build_cmd "$slot_path" "$idx")
    local esc; esc=$(applescript_escape "$cmd")
    local title="${REPO}-${slot}"
    [ ${#NAME_ARR[@]} -gt "$idx" ] && title="${REPO}-${slot}: ${NAME_ARR[$idx]}"

    if [ "$first" = "true" ]; then
      osascript >/dev/null 2>&1 <<EOF
tell application "iTerm"
  activate
  set newWindow to (create window with default profile)
  tell current session of newWindow
    set name to "$title"
    write text "$esc"
  end tell
end tell
EOF
      first=false
    else
      osascript >/dev/null 2>&1 <<EOF
tell application "iTerm"
  tell current window
    set newTab to (create tab with default profile)
    tell current session of newTab
      set name to "$title"
      write text "$esc"
    end tell
  end tell
end tell
EOF
    fi
    idx=$((idx + 1))
  done
}

open_terminal_tabs() {
  # Terminal.app: abas via Cmd+T (requer AppleWindowTabbingMode=always + Accessibility).
  local tabbing
  tabbing=$(defaults read com.apple.Terminal AppleWindowTabbingMode 2>/dev/null || echo "")
  if [ "$tabbing" != "always" ]; then
    echo "AVISO: Terminal.app está com AppleWindowTabbingMode='$tabbing'."
    echo "       Para abas reais, rode: defaults write com.apple.Terminal AppleWindowTabbingMode -string \"always\""
  fi

  local first=true
  local idx=0
  for slot in "${SLOTS[@]}"; do
    local slot_path="$CHECKOUT_BASE/${REPO}-${slot}"
    local cmd; cmd=$(build_cmd "$slot_path" "$idx")
    local esc; esc=$(applescript_escape "$cmd")

    if [ "$first" = "true" ]; then
      osascript >/dev/null 2>&1 <<EOF
tell application "Terminal"
  activate
  do script "$esc"
end tell
EOF
      first=false
      sleep 0.4
    else
      osascript >/dev/null 2>&1 <<EOF
tell application "Terminal" to activate
delay 0.15
tell application "System Events"
  keystroke "t" using {command down}
  delay 0.35
  keystroke "$esc"
  key code 36
end tell
EOF
      sleep 0.2
    fi
    idx=$((idx + 1))
  done
}

case "$APP" in
  iterm) open_iterm_tabs ;;
  terminal) open_terminal_tabs ;;
  *) echo "ERRO: app desconhecido '$APP'." >&2; exit 1 ;;
esac

echo "Abertas ${#SLOTS[@]} aba(s) em $APP para o pool '$REPO': ${SLOTS[*]}"
if [ -n "$NAMES" ]; then echo "Labels: $NAMES"; fi

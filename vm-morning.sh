#!/usr/bin/env bash
# vm-morning.sh — abre 1 janela iTerm com N abas, cada uma logando numa VM UTM
#                 já dentro do Claude Code (via vm1.sh/vm2.sh).
#                 Disparado no login pelo LaunchAgent com.example.auto-morning
#                 (bin/auto-morning.sh) — ou rode à mão para testar.
#
# Para mudar o que abre: edite a lista TABS abaixo. Cada item: "<comando>|<label>".
set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"

# ============== CUSTOMIZE AQUI ==============
# Uma aba por item. Antes do "|": comando a rodar. Depois: nome da aba.
TABS=(
  "$DIR/vm1.sh storefront-1|storefront"
  "$DIR/vm1.sh etl-crm-1|etl-crm"
  "$DIR/vm2.sh wikiapp-1|wikiapp"
)
# =============================================

# Detecção robusta via LaunchServices (iTerm pode estar em /Applications OU
# ~/Applications — hardcodar o caminho dá falso negativo).
if ! osascript -e 'POSIX path of (path to application "iTerm")' >/dev/null 2>&1; then
  echo "ERRO: iTerm não encontrado (LaunchServices não resolve 'iTerm')." >&2
  exit 1
fi

echo "═══ vm-morning: abrindo ${#TABS[@]} abas de VM ═══"

# X11: garante o XQuartz no ar para o ssh -Y desenhar nessas sessões (idempotente).
open -a XQuartz 2>/dev/null || true

applescript_escape() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }

first=true
for entry in "${TABS[@]}"; do
  cmd="${entry%%|*}"
  label="${entry##*|}"
  echo "→ aba: ${label}  (${cmd})"
  esc=$(applescript_escape "$cmd")

  if [ "$first" = "true" ]; then
    osascript >/dev/null 2>&1 <<EOF
tell application "iTerm"
  activate
  set newWindow to (create window with default profile)
  tell current session of newWindow
    set name to "$label"
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
      set name to "$label"
      write text "$esc"
    end tell
  end tell
end tell
EOF
  fi
  sleep 0.3
done

echo "═══ vm-morning: pronto (${#TABS[@]} abas) ═══"

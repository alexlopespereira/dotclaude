#!/usr/bin/env bash
# auto-morning-install.sh — Instala/desinstala/checa o LaunchAgent que abre
# os checkouts paralelos automaticamente ao login do macOS.
#
# Uso:
#   auto-morning-install.sh install    # copia plist e carrega no launchctl
#   auto-morning-install.sh uninstall  # descarrega e remove plist
#   auto-morning-install.sh status     # mostra se está carregado e logs

set -euo pipefail

PLIST_NAME="com.alexlopespereira.auto-morning"
PLIST_SOURCE="$HOME/Projects/dotclaude/launchagents/${PLIST_NAME}.plist"
PLIST_DEST="$HOME/Library/LaunchAgents/${PLIST_NAME}.plist"
LOG="$HOME/.claude/cache/auto-morning.log"

CMD="${1:-status}"

case "$CMD" in
  install)
    [ -f "$PLIST_SOURCE" ] || { echo "ERRO: $PLIST_SOURCE não existe." >&2; exit 1; }
    mkdir -p "$HOME/Library/LaunchAgents"
    cp "$PLIST_SOURCE" "$PLIST_DEST"
    # Descarrega antes (se existia uma versão anterior) para evitar conflito
    launchctl unload "$PLIST_DEST" 2>/dev/null || true
    launchctl load "$PLIST_DEST"
    echo "✓ LaunchAgent instalado e carregado."
    echo "  plist:  $PLIST_DEST"
    echo "  logs:   $LOG"
    echo ""
    echo "No próximo login do macOS, o iTerm abrirá automaticamente com as abas."
    echo "Para customizar pool/flags: edite $HOME/Projects/dotclaude/bin/auto-morning.sh"
    echo "Para testar agora sem reiniciar: bash $HOME/Projects/dotclaude/bin/auto-morning.sh"
    ;;
  uninstall)
    [ -f "$PLIST_DEST" ] || { echo "Já desinstalado."; exit 0; }
    launchctl unload "$PLIST_DEST" 2>/dev/null || true
    rm -f "$PLIST_DEST"
    echo "✓ LaunchAgent desinstalado."
    ;;
  status)
    if [ -f "$PLIST_DEST" ]; then
      echo "✓ Instalado: $PLIST_DEST"
    else
      echo "✗ Não instalado. Use: $0 install"
    fi
    echo ""
    echo "launchctl list | grep $PLIST_NAME:"
    launchctl list | grep "$PLIST_NAME" || echo "  (não carregado)"
    echo ""
    if [ -f "$LOG" ]; then
      echo "Últimas linhas de $LOG:"
      tail -20 "$LOG"
    else
      echo "Sem log ainda em $LOG (executa após login)."
    fi
    ;;
  *)
    echo "Uso: $0 {install|uninstall|status}" >&2
    exit 1
    ;;
esac

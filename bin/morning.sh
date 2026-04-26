#!/usr/bin/env bash
# morning.sh — Rotina de manhã: sync + launch dos checkouts paralelos.
#
# Uso:
#   morning.sh <repo> [--names=A,B,C,D] [--claude] [--skip-permissions|--yolo] [--no-sync]
#
# Faz, nesta ordem:
#   1. /checkout-sync-all <repo>   (puxa main em todos os slots, poda branches mergeadas)
#   2. /checkout-launch <repo> --names=...   (abre 1 janela com N abas)

set -euo pipefail

CHECKOUT_BASE="$HOME/Projects/checkouts"
SYNC_SCRIPT="$HOME/Projects/dotclaude/bin/checkout-sync-all.sh"
LAUNCH_SCRIPT="$HOME/Projects/dotclaude/bin/checkout-launch.sh"
[ -x "$SYNC_SCRIPT" ] || SYNC_SCRIPT="$HOME/.claude/bin/checkout-sync-all.sh"
[ -x "$LAUNCH_SCRIPT" ] || LAUNCH_SCRIPT="$HOME/.claude/bin/checkout-launch.sh"

REPO=""
NO_SYNC=false
LAUNCH_ARGS=()

for arg in "$@"; do
  case "$arg" in
    --no-sync) NO_SYNC=true ;;
    -*) LAUNCH_ARGS+=("$arg") ;;
    *) [ -z "$REPO" ] && REPO="$arg" || LAUNCH_ARGS+=("$arg") ;;
  esac
done

[ -z "$REPO" ] && { echo "ERRO: passe <repo>." >&2; exit 1; }
ls -d "$CHECKOUT_BASE/${REPO}-"* >/dev/null 2>&1 || { echo "ERRO: pool '$REPO' não existe. Rode /checkout-init primeiro." >&2; exit 1; }

echo "═══ Bom dia. Iniciando rotina para o pool '$REPO' ═══"

if [ "$NO_SYNC" != "true" ]; then
  echo ""
  echo "→ Etapa 1/2: sincronizando slots com origin/main"
  bash "$SYNC_SCRIPT" "$REPO" || echo "AVISO: sync teve avisos — continuando."
fi

echo ""
echo "→ Etapa 2/2: abrindo abas do terminal"
bash "$LAUNCH_SCRIPT" "$REPO" ${LAUNCH_ARGS[@]+"${LAUNCH_ARGS[@]}"}

echo ""
echo "═══ Pronto. Bom trabalho. ═══"

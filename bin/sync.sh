#!/usr/bin/env bash
# sync.sh — Atalho para /checkout-sync-all auto-detectando o pool a partir do cwd.
# Se cwd está em ~/Projects/checkouts/<repo>-N/..., infere <repo> e chama checkout-sync-all.
#
# Uso:
#   sync.sh [--force] [--no-prune]
#   sync.sh <repo> [--force] [--no-prune]   # passa repo explicitamente

set -euo pipefail

CHECKOUT_BASE="$HOME/Projects/checkouts"
SCRIPT="$HOME/Projects/dotclaude/bin/checkout-sync-all.sh"
[ -x "$SCRIPT" ] || SCRIPT="$HOME/.claude/bin/checkout-sync-all.sh"
[ -x "$SCRIPT" ] || { echo "ERRO: checkout-sync-all.sh não encontrado." >&2; exit 1; }

REPO=""
EXTRA_FLAGS=()
for arg in "$@"; do
  case "$arg" in
    -*) EXTRA_FLAGS+=("$arg") ;;
    *) [ -z "$REPO" ] && REPO="$arg" || EXTRA_FLAGS+=("$arg") ;;
  esac
done

# Auto-detectar repo do cwd se não passado
if [ -z "$REPO" ]; then
  CWD=$(pwd)
  case "$CWD" in
    "$CHECKOUT_BASE"/*)
      # Pega o componente após CHECKOUT_BASE/, remove o sufixo -N
      SLOT_DIR=$(echo "$CWD" | sed -E "s|^$CHECKOUT_BASE/||" | cut -d/ -f1)
      REPO=$(echo "$SLOT_DIR" | sed -E 's/-[0-9]+$//')
      ;;
    *)
      echo "ERRO: cwd não está em $CHECKOUT_BASE/<repo>-N/. Passe <repo> explicitamente:" >&2
      echo "  /sync <repo>" >&2
      exit 1
      ;;
  esac
fi

[ -z "$REPO" ] && { echo "ERRO: não consegui inferir o pool. Passe explicitamente." >&2; exit 1; }

echo "→ Sincronizando pool '$REPO'"
exec bash "$SCRIPT" "$REPO" "${EXTRA_FLAGS[@]}"

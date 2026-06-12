#!/usr/bin/env bash
# checkout-sync.sh — Atalho para /checkout-sync-all auto-detectando o pool a partir do cwd.
# (Renomeado de bin/sync.sh em US-05 para resolver a colisão com o sync.sh da raiz;
#  stub de deprecação fica em bin/sync.sh até o sunset 2026-09-01.)
# Se cwd está em ~/Projects/checkouts/<repo>-N/..., infere <repo> e chama checkout-sync-all.
#
# Uso:
#   checkout-sync.sh [--force] [--no-prune]
#   checkout-sync.sh <repo> [--force] [--no-prune]   # passa repo explicitamente

set -euo pipefail

# Seams para teste: SYNC_CHECKOUT_BASE (raiz do pool) e SYNC_CHECKOUT_SYNC_ALL
# (caminho do checkout-sync-all). Ausentes = produção.
CHECKOUT_BASE="${SYNC_CHECKOUT_BASE:-$HOME/Projects/checkouts}"
SCRIPT="${SYNC_CHECKOUT_SYNC_ALL:-}"
[ -n "$SCRIPT" ] || SCRIPT="$HOME/Projects/dotclaude/bin/checkout-sync-all.sh"
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
      # Fallback: cwd fora do pool mas dentro de um clone git de um repo que TEM
      # pool. Deriva o repo do toplevel (strip de sufixo -N) e prossegue se
      # $CHECKOUT_BASE/<repo>-1 existe. Caso contrário, erro claro. Repo fora de
      # git mantém o erro canônico ("cwd não está em ...") que o force-merge.sh
      # grepa para pular o sync graciosamente.
      TOPLEVEL=$(git rev-parse --show-toplevel 2>/dev/null || true)
      if [ -n "$TOPLEVEL" ]; then
        CAND=$(basename "$TOPLEVEL" | sed -E 's/-[0-9]+$//')
        if [ -d "$CHECKOUT_BASE/$CAND-1" ]; then
          REPO="$CAND"
          echo "→ Inferido pool '$REPO' do repo git em $TOPLEVEL (fora de $CHECKOUT_BASE)." >&2
        else
          echo "ERRO: repo '$CAND' não tem pool em $CHECKOUT_BASE (esperado $CHECKOUT_BASE/$CAND-1)." >&2
          exit 1
        fi
      else
        echo "ERRO: cwd não está em $CHECKOUT_BASE/<repo>-N/. Passe <repo> explicitamente:" >&2
        echo "  /sync <repo>" >&2
        exit 1
      fi
      ;;
  esac
fi

[ -z "$REPO" ] && { echo "ERRO: não consegui inferir o pool. Passe explicitamente." >&2; exit 1; }

echo "→ Sincronizando pool '$REPO'"
exec bash "$SCRIPT" "$REPO" ${EXTRA_FLAGS[@]+"${EXTRA_FLAGS[@]}"}

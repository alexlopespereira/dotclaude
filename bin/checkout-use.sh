#!/usr/bin/env bash
# checkout-use.sh — Aloca um slot para uma sessão de trabalho.
# Modelo trunk-based: garante slot em main, atualiza, registra propósito (label) opcional.
# NUNCA cria branch.
#
# Uso:
#   checkout-use.sh <repo> <slot> [label]

set -euo pipefail

CHECKOUT_BASE="$HOME/Projects/checkouts"

REPO="${1:-}"
SLOT="${2:-}"
LABEL="${3:-}"

[ -z "$REPO" ] && { echo "ERRO: passe <repo>." >&2; exit 1; }
[ -z "$SLOT" ] && { echo "ERRO: passe <slot>." >&2; exit 1; }
[[ "$SLOT" =~ ^[0-9]+$ ]] || { echo "ERRO: slot deve ser número." >&2; exit 1; }

SLOT_PATH="$CHECKOUT_BASE/${REPO}-${SLOT}"
[ -d "$SLOT_PATH/.git" ] || { echo "ERRO: $SLOT_PATH não é repo git. Rode /checkout-init primeiro." >&2; exit 1; }

# Estado atual
CURRENT_BRANCH=$(git -C "$SLOT_PATH" rev-parse --abbrev-ref HEAD)
DIRTY=$(git -C "$SLOT_PATH" status --porcelain)

# Detectar default branch
DEFAULT=$(git -C "$SLOT_PATH" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@' || echo "")
DEFAULT="${DEFAULT:-main}"

# Se está em outra branch (legado), avisa mas não força
if [ "$CURRENT_BRANCH" != "$DEFAULT" ]; then
  echo "AVISO: slot está em '$CURRENT_BRANCH', não em '$DEFAULT'."
  echo "       O modelo trunk-based usa $DEFAULT direto. Considere fazer checkout manual:"
  echo "         git -C \"$SLOT_PATH\" checkout $DEFAULT"
  exit 1
fi

if [ -n "$DIRTY" ]; then
  echo "AVISO: slot tem mudanças não commitadas:"
  echo "$DIRTY" | head -10
  echo "Resolva (commit/stash) antes de continuar."
  exit 1
fi

# Atualizar main
echo "→ git fetch + pull --ff-only origin $DEFAULT"
git -C "$SLOT_PATH" fetch origin "$DEFAULT" --quiet || echo "AVISO: fetch falhou (offline?)"
git -C "$SLOT_PATH" pull --ff-only origin "$DEFAULT" --quiet || echo "AVISO: pull falhou — resolva manualmente."

# Gravar label/metadata
mkdir -p "$SLOT_PATH/.claude"
cat > "$SLOT_PATH/.claude/.slot-info" <<EOF
slot=$SLOT
repo=$REPO
label=${LABEL:-(sem label)}
allocated_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF

# Garantir gitignore
GITIGNORE="$SLOT_PATH/.gitignore"
if [ -f "$GITIGNORE" ] && ! grep -qF '.claude/.slot-info' "$GITIGNORE"; then
  echo '.claude/.slot-info' >> "$GITIGNORE"
fi

cat <<EOF
Slot $SLOT pronto:
  path:    $SLOT_PATH
  branch:  $DEFAULT (atualizado)
  label:   ${LABEL:-(nenhum)}

Trabalhe direto neste slot. Quando terminar:
  /commit-push-pr        # commit + push em main
  /checkout-sync-all $REPO   # propaga para os outros slots
EOF

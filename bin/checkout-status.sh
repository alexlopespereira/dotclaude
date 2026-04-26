#!/usr/bin/env bash
# checkout-status.sh — Mostra estado dos slots do pool (modelo trunk-based).
#
# Uso:
#   checkout-status.sh [repo]

set -euo pipefail

CHECKOUT_BASE="$HOME/Projects/checkouts"
FILTER="${1:-}"

if [ ! -d "$CHECKOUT_BASE" ]; then
  echo "Nenhum pool de checkouts encontrado. Use /checkout-init <repo-url>."
  exit 0
fi

# Listar slots
SLOTS=()
while IFS= read -r d; do
  [ -n "$d" ] && SLOTS+=("$d")
done < <(find "$CHECKOUT_BASE" -maxdepth 1 -type d \
  $([ -n "$FILTER" ] && echo "-name ${FILTER}-*" || echo "-name *-*") 2>/dev/null \
  | sort -V)

if [ ${#SLOTS[@]} -eq 0 ]; then
  echo "Nenhum slot encontrado${FILTER:+ para '$FILTER'}."
  exit 0
fi

# Cabeçalho
printf "\n%-20s %-8s %-7s %-12s %-15s %s\n" "slot" "branch" "status" "ahead/behind" "label" "última atividade"
printf "%-20s %-8s %-7s %-12s %-15s %s\n" "────" "──────" "──────" "────────────" "─────" "────────────────"

for slot_path in "${SLOTS[@]}"; do
  git -C "$slot_path" rev-parse --git-dir >/dev/null 2>&1 || continue

  name=$(basename "$slot_path")
  branch=$(git -C "$slot_path" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "?")
  dirty_count=$(git -C "$slot_path" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
  status=$([ "$dirty_count" -eq 0 ] && echo "clean" || echo "dirty($dirty_count)")

  upstream=$(git -C "$slot_path" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || echo "")
  if [ -n "$upstream" ]; then
    ahead=$(git -C "$slot_path" rev-list --count "$upstream..HEAD" 2>/dev/null || echo "?")
    behind=$(git -C "$slot_path" rev-list --count "HEAD..$upstream" 2>/dev/null || echo "?")
    counts="$ahead/$behind"
  else
    counts="-"
  fi

  label="-"
  if [ -f "$slot_path/.claude/.slot-info" ]; then
    label=$(grep '^label=' "$slot_path/.claude/.slot-info" 2>/dev/null | cut -d= -f2-)
    label="${label:-(sem label)}"
  fi

  last=$(git -C "$slot_path" log -1 --format="%cr" 2>/dev/null || echo "?")

  printf "%-20s %-8s %-7s %-12s %-15s %s\n" "$name" "$branch" "$status" "$counts" "$label" "$last"
done

echo ""
echo "Tip: rode 'git fetch --all' antes para ahead/behind precisos."
echo "     /checkout-sync-all <repo> sincroniza todos os slots em main."

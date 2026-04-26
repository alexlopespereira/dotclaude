#!/usr/bin/env bash
# checkout-sync-all.sh — Atualiza todos os slots do pool com origin/main
# e remove branches locais já mergeadas (limpeza pós-PR-merge).
#
# Uso:
#   checkout-sync-all.sh <repo> [--force]   --force descarta mudanças locais
#   checkout-sync-all.sh <repo> [--no-prune]   pula limpeza de branches mergeadas

set -euo pipefail

CHECKOUT_BASE="$HOME/Projects/checkouts"
REPO="${1:-}"
FORCE=false
PRUNE=true

shift || true
while [ $# -gt 0 ]; do
  case "$1" in
    --force) FORCE=true ;;
    --no-prune) PRUNE=false ;;
    *) echo "Flag desconhecida: $1" >&2; exit 1 ;;
  esac
  shift
done

[ -z "$REPO" ] && { echo "ERRO: passe <repo>." >&2; exit 1; }

SLOTS=()
while IFS= read -r d; do
  [ -n "$d" ] && SLOTS+=("$d")
done < <(find "$CHECKOUT_BASE" -maxdepth 1 -type d -name "${REPO}-*" 2>/dev/null | sort -V)

[ ${#SLOTS[@]} -eq 0 ] && { echo "ERRO: nenhum slot do pool '$REPO'." >&2; exit 1; }

ok=0; skipped=0; failed=0; pruned=0

for slot_path in "${SLOTS[@]}"; do
  git -C "$slot_path" rev-parse --git-dir >/dev/null 2>&1 || { skipped=$((skipped+1)); continue; }

  name=$(basename "$slot_path")
  default=$(git -C "$slot_path" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@' || echo "main")
  branch=$(git -C "$slot_path" rev-parse --abbrev-ref HEAD)
  dirty=$(git -C "$slot_path" status --porcelain)

  echo ""
  echo "=== $name (branch: $branch) ==="

  if [ -n "$dirty" ]; then
    if [ "$FORCE" = "true" ]; then
      echo "  → --force: descartando mudanças locais"
      git -C "$slot_path" reset --hard HEAD --quiet
      git -C "$slot_path" clean -fd --quiet
    else
      echo "  ⚠ slot dirty — pulando. Use --force para descartar."
      skipped=$((skipped+1))
      continue
    fi
  fi

  # Garantir checkout em default
  if [ "$branch" != "$default" ]; then
    echo "  → checkout $default"
    git -C "$slot_path" checkout "$default" --quiet || { failed=$((failed+1)); continue; }
  fi

  # Fetch + pull --ff-only (com fallback para reset --hard se main local divergir)
  echo "  → fetch + pull --ff-only origin/$default"
  if ! git -C "$slot_path" fetch origin "$default" --quiet; then
    echo "  ✗ fetch falhou"
    failed=$((failed+1))
    continue
  fi

  if ! git -C "$slot_path" pull --ff-only origin "$default" --quiet 2>/dev/null; then
    if [ "$FORCE" = "true" ]; then
      echo "  → --force: reset --hard origin/$default (main local divergiu)"
      git -C "$slot_path" reset --hard "origin/$default" --quiet
    else
      echo "  ⚠ pull --ff-only falhou — main local divergiu. Use --force para reset."
      failed=$((failed+1))
      continue
    fi
  fi

  # Limpar branches locais que já foram mergeadas em origin/default
  if [ "$PRUNE" = "true" ]; then
    # branches locais ≠ default que estão mergeadas em origin/default
    while IFS= read -r b; do
      b=$(echo "$b" | tr -d ' *')
      [ -z "$b" ] && continue
      [ "$b" = "$default" ] && continue
      git -C "$slot_path" branch -d "$b" --quiet 2>/dev/null && {
        echo "  ✗ branch local '$b' removida (já mergeada)"
        pruned=$((pruned+1))
      } || true
    done < <(git -C "$slot_path" branch --merged "origin/$default" 2>/dev/null)

    # remote prune
    git -C "$slot_path" remote prune origin --quiet 2>/dev/null || true
  fi

  ok=$((ok+1))
  echo "  ✓ atualizado"
done

echo ""
echo "Resumo: $ok atualizados | $skipped pulados | $failed falhas | $pruned branch(es) locais removidas"

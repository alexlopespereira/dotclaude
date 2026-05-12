#!/usr/bin/env bash
# checkout-sync-all.sh — Atualiza todos os slots do pool com origin/main
# e remove branches locais já mergeadas (limpeza pós-PR-merge).
#
# Uso:
#   checkout-sync-all.sh <repo> [--force]   --force descarta mudanças locais
#   checkout-sync-all.sh <repo> [--no-prune]   pula limpeza de branches mergeadas

set -euo pipefail

# Source helpers para detecção de versão graphify (drift check L2)
SYNC_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"
# shellcheck source=lib/graphify_version.sh
. "$SYNC_LIB_DIR/graphify_version.sh"

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

  # L1: descarta artefatos do regen pós-pull do /sync anterior antes do dirty-check.
  # O regen (mais abaixo) deixa graphify-out/ dirty por design (ADR 0001 Errata
  # 2026-05-07: "ficam dirty pro próximo /commit-push-pr"). Sem este descarte,
  # o dirty-check seguinte pula o slot e /sync nunca é idempotente.
  # Regen é refeito pós-pull — descartar aqui é seguro (arquivos derivados).
  if [ -d "$slot_path/graphify-out" ]; then
    git -C "$slot_path" checkout -- graphify-out/ 2>/dev/null || true
  fi

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

  # Pós-pull em repos Graphified:
  #   1. Regenerar grafo (AST-only, zero LLM). merge=theirs em .gitattributes faz
  #      graph.json refletir origin/main após pull; regenerar realinha working tree.
  #   2. Reinstalar git hooks Graphify (idempotente). Cobre o caso "repo virou
  #      Graphified depois do pool ser criado": /graphify-init num slot → PR
  #      mergeado → /sync propaga graphify-out/ + ativa hooks per-clone.
  # Não comitamos os mods do graph regenerado — ficam dirty pro próximo
  # /commit-push-pr. Ver docs/adr/0001-adopt-graphify-sunset-llm-wiki.md
  # (consequência negativa #3 + Errata 2026-05-08).
  if [ -f "$slot_path/graphify-out/graph.json" ] && command -v graphify >/dev/null 2>&1; then
    # L2: avisar se versão da CLI difere da que gerou artefatos committados
    # (silencioso quando .graphify_version ausente ou versões iguais).
    _graphify_drift_check "$slot_path"

    echo "  → atualizando graphify-out/ (post-pull, AST-only)"
    ( cd "$slot_path" && graphify update . >/dev/null 2>&1 ) \
      || echo "  ⚠ graphify update . falhou no slot — verifique manualmente"
    ( cd "$slot_path" && graphify hook install >/dev/null 2>&1 ) \
      || echo "  ⚠ graphify hook install falhou no slot — verifique manualmente"
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

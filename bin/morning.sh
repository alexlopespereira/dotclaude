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

# Seams MORNING_* (env, p/ teste — pattern RRD_*/AM_* dos scripts irmãos).
CHECKOUT_BASE="${MORNING_CHECKOUT_BASE:-$HOME/Projects/checkouts}"
SYNC_SCRIPT="${MORNING_SYNC_SCRIPT:-$HOME/Projects/dotclaude/bin/checkout-sync-all.sh}"
LAUNCH_SCRIPT="${MORNING_LAUNCH_SCRIPT:-$HOME/Projects/dotclaude/bin/checkout-launch.sh}"
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

# Reflexões pendentes (/reflect — AC10/AC17) — informa baselines aguardando retro.
# US-01 autonomy-4-melhorias (Falha #1 da Revisão Adversária): o contador só
# conta kind ausente OU kind=="baseline" — o mesmo filtro de seleção do
# reflect-retro-due.sh; kinds novos (learn, autonomy-promotion) não inflam a
# contagem. Entradas kind=="autonomy-promotion" vencidas ou vencendo em <=7d
# ganham linha dedicada.
show_reflect_reminders() {
  local reminders="${MORNING_REMINDERS:-$HOME/.claude/cache/reflect/reminders.jsonl}"
  [ -f "$reminders" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  local now_epoch count oldest_days line kind created_at created_epoch age
  local promo_lines="" due note horizon
  now_epoch=$(date -u +%s)
  # Janela da promoção: due <= hoje+7d (BSD/macOS primeiro; fallback GNU).
  horizon=$(date -u -v+7d +%Y-%m-%d 2>/dev/null || date -u -d '+7 days' +%Y-%m-%d)
  count=0
  oldest_days=0
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    kind=$(jq -r '.kind // "baseline"' <<<"$line" 2>/dev/null) || continue
    if [ "$kind" = "autonomy-promotion" ]; then
      due=$(jq -r '.retro_due_at // empty' <<<"$line" 2>/dev/null) || continue
      [ -z "$due" ] && continue
      due="${due:0:10}"   # formato canônico posicional → compara lexicográfico
      if [[ ! "$due" > "$horizon" ]]; then
        note=$(jq -r '.note // empty' <<<"$line" 2>/dev/null)
        promo_lines="${promo_lines}→ Promoção do autonomy-guard pendente (alvo $due): $note"$'\n'
      fi
      continue
    fi
    [ "$kind" = "baseline" ] || continue
    created_at=$(jq -r '.created_at // empty' <<<"$line" 2>/dev/null) || continue
    [ -z "$created_at" ] && continue
    # Formato canônico do /reflect: 2026-05-18T03-15-16Z (dashes no time).
    # Tenta BSD/macOS primeiro; cai para GNU convertendo dashes em colons.
    if created_epoch=$(date -j -u -f '%Y-%m-%dT%H-%M-%SZ' "$created_at" +%s 2>/dev/null); then
      :
    else
      local iso="${created_at:0:10}T${created_at:11:2}:${created_at:14:2}:${created_at:17:2}Z"
      created_epoch=$(date -u -d "$iso" +%s 2>/dev/null) || continue
    fi
    age=$(( (now_epoch - created_epoch) / 86400 ))
    count=$((count + 1))
    [ "$age" -gt "$oldest_days" ] && oldest_days="$age"
  done < "$reminders"
  if [ "$count" -gt 0 ]; then
    echo ""
    echo "→ Reflexões pendentes: $count baseline(s) aguardando retro (mais antiga: D+$oldest_days)"
    echo "  Rode /reflect <pr-number> --retro nos PRs com idade ≥ 7 dias."
  fi
  if [ -n "$promo_lines" ]; then
    echo ""
    printf '%s' "$promo_lines"
    echo "  Inspecione ~/.claude/cache/autonomy/audit.jsonl antes de promover (README: rollout)."
  fi
}
show_reflect_reminders

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

#!/usr/bin/env bash
# bin/force-merge.sh — Mergea um PR aberto agora, com auto-sync do pool Boris.
#
# DESIGN NOTE (US-02 spike):
# Confirmação humana acontece NO MARKDOWN do slash command (commands/force-merge.md),
# não aqui. Razão empírica: `read -r -p` em scripts invocados via Claude Code
# Bash tool não recebe stdin (subprocesso não-interativo, EOF imediato), então o
# prompt y/n só funciona se o orquestrador (Claude no chat) coletar a resposta
# antes de invocar este script com FORCE_MERGE_CONFIRMED=1.
# Quando rodado fora do Claude Code (terminal direto), o usuário define a env
# var manualmente ou o script falha cedo com instrução clara.
#
# Modos:
#   (sem flag)  soft   gh pr merge <num> --squash --delete-branch
#   --wait      wait   gh pr checks --watch (com timeout) então soft
#   --admin     admin  gh pr merge <num> --admin --squash --delete-branch
#
# Auto-sync: após merge, dispara bin/sync.sh (auto-detect pool Boris).
# Skip silencioso fora do pool. Desliga via --no-sync.
#
# Uso:
#   force-merge.sh [PR-num|branch] [--wait] [--admin]
#                  [--merge-method=squash|merge|rebase] [--wait-timeout=Nm|Ns]
#                  [--no-sync]
#
# Env vars:
#   FORCE_MERGE_CONFIRMED=1   pula prompt (markdown seta após user dizer y)
#   FORCE_MERGE_NESTED=1      invocação dentro de slash composto; pula confirmação
#                              de --wait (mas NÃO de --admin)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYNC_SCRIPT="$SCRIPT_DIR/sync.sh"

# ─── Flags ────────────────────────────────────────────────────────────────
ARG=""
ADMIN=false
WAIT=false
WAIT_TIMEOUT=1800
MERGE_METHOD="squash"
NO_SYNC=false

while [ $# -gt 0 ]; do
  case "$1" in
    --admin) ADMIN=true ;;
    --wait) WAIT=true ;;
    --wait-timeout=*)
      raw="${1#*=}"
      case "$raw" in
        *m) WAIT_TIMEOUT=$(( ${raw%m} * 60 )) ;;
        *s) WAIT_TIMEOUT="${raw%s}" ;;
        *) WAIT_TIMEOUT="$raw" ;;
      esac
      ;;
    --merge-method=*) MERGE_METHOD="${1#*=}" ;;
    --no-sync) NO_SYNC=true ;;
    -h|--help)
      sed -n '2,/^set -euo pipefail/p' "$0" | sed -E 's/^# ?//;/^set -euo/d'
      exit 0
      ;;
    -*) echo "ERRO: flag desconhecida: $1" >&2; exit 2 ;;
    *)
      if [ -z "$ARG" ]; then
        ARG="$1"
      else
        echo "ERRO: arg extra '$1' (já passou '$ARG')." >&2; exit 2
      fi
      ;;
  esac
  shift
done

if [ "$WAIT" = "true" ] && [ "$ADMIN" = "true" ]; then
  echo "ERRO: --wait e --admin são mutuamente exclusivas." >&2
  exit 2
fi

case "$MERGE_METHOD" in
  squash|merge|rebase) ;;
  *) echo "ERRO: --merge-method deve ser squash|merge|rebase." >&2; exit 2 ;;
esac

command -v gh >/dev/null 2>&1 || { echo "ERRO: gh CLI não instalado." >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "ERRO: jq não instalado." >&2; exit 1; }

# ─── Helpers ──────────────────────────────────────────────────────────────
run_sync_or_skip() {
  if [ ! -x "$SYNC_SCRIPT" ]; then
    echo "  aviso: sync.sh não encontrado em $SYNC_SCRIPT — sync pulado."
    return 0
  fi
  echo "→ Disparando auto-sync do pool Boris..."
  local sync_out sync_rc=0
  sync_out=$(bash "$SYNC_SCRIPT" 2>&1) || sync_rc=$?
  case "$sync_out" in
    *"cwd não está em"*|*"cwd nao esta em"*)
      echo "  aviso: cwd fora do pool Boris — sync pulado (esperado em repos não-Boris)."
      return 0
      ;;
  esac
  if [ "$sync_rc" -ne 0 ]; then
    echo "  aviso: sync retornou rc=$sync_rc (merge já efetivado, sync falhou):"
    printf '%s\n' "$sync_out" | sed 's/^/    /'
    return 0
  fi
  # Summary: extract OK/skipped/failed counts from sync_out if present.
  local summary
  summary=$(printf '%s\n' "$sync_out" | grep -E '^(ok|skipped|failed)=' || true)
  if [ -n "$summary" ]; then
    echo "  $summary"
  else
    printf '%s\n' "$sync_out" | tail -3 | sed 's/^/  /'
  fi
}

# ─── Resolve PR number ────────────────────────────────────────────────────
PR_NUM=""

if [ -z "$ARG" ]; then
  RAW=$(gh pr list --author @me --state open --json number,title,headRefName,isDraft 2>/dev/null || echo '[]')
  COUNT=$(echo "$RAW" | jq '[.[] | select(.isDraft == false)] | length')
  if [ "$COUNT" = "0" ]; then
    echo "ERRO: nenhum PR aberto não-draft seu para mergear." >&2
    echo "      passe um número/branch:  /force-merge <PR-num|branch>" >&2
    exit 1
  elif [ "$COUNT" = "1" ]; then
    PR_NUM=$(echo "$RAW" | jq '[.[] | select(.isDraft == false)][0].number')
    PR_TITLE=$(echo "$RAW" | jq -r '[.[] | select(.isDraft == false)][0].title')
    echo "→ Auto-detectado: PR #$PR_NUM '$PR_TITLE'"
  else
    echo "ERRO: $COUNT PRs abertos seus — ambíguo. Passe explicitamente o número:" >&2
    echo "$RAW" | jq -r '.[] | select(.isDraft == false) | "  #\(.number)  \(.title)  [\(.headRefName)]"' >&2
    exit 1
  fi
elif [[ "$ARG" =~ ^[0-9]+$ ]]; then
  PR_NUM="$ARG"
else
  PR_NUM=$(gh pr list --head "$ARG" --state open --json number --jq '.[0].number // empty' 2>/dev/null || true)
  if [ -z "$PR_NUM" ]; then
    echo "ERRO: nenhum PR aberto encontrado para branch '$ARG'." >&2
    exit 1
  fi
  echo "→ Branch '$ARG' resolveu para PR #$PR_NUM"
fi

# ─── Validate PR state ────────────────────────────────────────────────────
PR_INFO=$(gh pr view "$PR_NUM" --json state,isDraft,baseRefName,title 2>/dev/null) || {
  echo "ERRO: gh pr view #$PR_NUM falhou." >&2; exit 1;
}
PR_STATE=$(echo "$PR_INFO" | jq -r '.state')
PR_DRAFT=$(echo "$PR_INFO" | jq -r '.isDraft')
PR_BASE=$(echo "$PR_INFO" | jq -r '.baseRefName')
PR_TITLE_VIEW=$(echo "$PR_INFO" | jq -r '.title')

if [ "$PR_STATE" = "MERGED" ]; then
  echo "✓ PR #$PR_NUM '$PR_TITLE_VIEW' já está MERGED — nada a mergear."
  if [ "$NO_SYNC" != "true" ]; then
    run_sync_or_skip
  fi
  exit 0
fi

if [ "$PR_STATE" = "CLOSED" ]; then
  echo "ERRO: PR #$PR_NUM está CLOSED (não mergeado) — abortando." >&2
  exit 1
fi

if [ "$PR_DRAFT" = "true" ]; then
  echo "ERRO: PR #$PR_NUM é draft — converta com 'gh pr ready $PR_NUM' antes." >&2
  exit 1
fi

# ─── Detect protection on base branch ─────────────────────────────────────
REPO_NWO=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null) || REPO_NWO=""
PROTECTED=false
if [ -n "$REPO_NWO" ]; then
  if gh api "repos/$REPO_NWO/branches/$PR_BASE/protection" >/dev/null 2>&1; then
    PROTECTED=true
  fi
fi

# ─── Confirmation gate ────────────────────────────────────────────────────
NEED_CONFIRM=false
if [ "$ADMIN" = "true" ]; then
  NEED_CONFIRM=true
elif [ "$WAIT" = "true" ]; then
  if [ "${FORCE_MERGE_NESTED:-0}" != "1" ]; then
    NEED_CONFIRM=true
  fi
elif [ "$PROTECTED" = "true" ]; then
  NEED_CONFIRM=true
fi

if [ "$NEED_CONFIRM" = "true" ] && [ "${FORCE_MERGE_CONFIRMED:-0}" != "1" ]; then
  cat >&2 <<EOF
ERRO: este caminho exige confirmação humana antes de mergear.
       Modo:  $([ "$ADMIN" = "true" ] && echo "ADMIN (bypass proteção)" || ([ "$WAIT" = "true" ] && echo "WAIT" || echo "SOFT em branch protegida"))
       PR:    #$PR_NUM '$PR_TITLE_VIEW'
       Base:  $PR_BASE (protegida=$PROTECTED)
       Reinvoque com FORCE_MERGE_CONFIRMED=1 — o slash /force-merge faz isso
       automaticamente após o usuário responder y no chat.
EOF
  exit 3
fi

# ─── Wait mode (detect-first then watch) ──────────────────────────────────
if [ "$WAIT" = "true" ]; then
  echo "→ Verificando se PR #$PR_NUM tem checks configurados..."
  CHECKS_RAW=$(gh pr checks "$PR_NUM" --json state 2>/dev/null || echo '[]')
  CHECKS_COUNT=$(echo "$CHECKS_RAW" | jq 'length' 2>/dev/null || echo 0)
  if [ "$CHECKS_COUNT" -eq 0 ] 2>/dev/null; then
    echo "  PR sem checks — pulando wait, mergeando soft direto."
  else
    echo "→ Aguardando $CHECKS_COUNT check(s) (timeout ${WAIT_TIMEOUT}s)..."
    # Timeout via perl (macOS sem coreutils `timeout`). Perl ships com o OS;
    # alarm() dispara SIGALRM após N segundos, matando o processo exec'd.
    # Exit 142 (128+14=SIGALRM) sinaliza timeout. Subshell + wait deixava
    # `sleep` orfão e bloqueava `wait` em alguns casos — perl é mais limpo.
    WATCH_RC=0
    perl -e 'alarm shift; exec @ARGV' "$WAIT_TIMEOUT" gh pr checks "$PR_NUM" --watch || WATCH_RC=$?
    if [ "$WATCH_RC" = "142" ]; then
      echo "ERRO: timeout (${WAIT_TIMEOUT}s) aguardando checks." >&2
      exit 1
    fi
    if [ "$WATCH_RC" -ne 0 ]; then
      echo "ERRO: algum check falhou:" >&2
      gh pr checks "$PR_NUM" --json name,state --jq '.[] | select(.state=="FAILURE") | "  ✗ " + .name' >&2 || true
      exit 1
    fi
    echo "✓ Todos os checks passaram."
  fi
fi

# ─── Merge ────────────────────────────────────────────────────────────────
echo "→ Mergeando PR #$PR_NUM (--$MERGE_METHOD --delete-branch)..."
if [ "$ADMIN" = "true" ]; then
  echo "  Modo: --admin (bypass branch protection)"
  gh pr merge "$PR_NUM" --admin --"$MERGE_METHOD" --delete-branch
else
  gh pr merge "$PR_NUM" --"$MERGE_METHOD" --delete-branch
fi
echo "✓ PR #$PR_NUM mergeado e branch remota deletada."

# ─── Auto-sync ────────────────────────────────────────────────────────────
if [ "$NO_SYNC" != "true" ]; then
  run_sync_or_skip
fi

exit 0

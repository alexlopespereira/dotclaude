#!/usr/bin/env bash
# commit-push-pr.sh — Workflow Boris + branch protection.
#
# Trabalho acontece em 'main' local. No push, criamos branch efêmera derivada
# da mensagem do commit (ou explícita via --branch), pushamos e abrimos PR.
# 'main' local é resetado para origin/main após push (slot fica limpo).
#
# Uso:
#   commit-push-pr.sh "mensagem do commit" [--branch=NAME] [--type=feat|fix|chore|refactor|docs|test] [--no-pr] [--draft]
#
# Exemplos:
#   commit-push-pr.sh "feat: add dark mode toggle"
#   commit-push-pr.sh "fix login timeout" --type=fix
#   commit-push-pr.sh "refactor auth" --branch=refactor/auth-middleware

set -euo pipefail

MSG=""
BRANCH_NAME=""
BRANCH_EXPLICIT=false
TYPE=""
NO_PR=false
DRAFT=false
AUTO_MERGE=true   # default: liga auto-merge --squash quando CI passar
MERGE_METHOD="squash"

while [ $# -gt 0 ]; do
  case "$1" in
    --branch=*) BRANCH_NAME="${1#*=}"; BRANCH_EXPLICIT=true ;;
    --type=*) TYPE="${1#*=}" ;;
    --no-pr) NO_PR=true ;;
    --draft) DRAFT=true ;;
    --no-auto-merge) AUTO_MERGE=false ;;
    --merge-method=*) MERGE_METHOD="${1#*=}" ;;
    -*) echo "Flag desconhecida: $1" >&2; exit 1 ;;
    *) [ -z "$MSG" ] && MSG="$1" || echo "Arg extra ignorado: $1" >&2 ;;
  esac
  shift
done

case "$MERGE_METHOD" in
  squash|merge|rebase) ;;
  *) echo "ERRO: --merge-method deve ser squash|merge|rebase." >&2; exit 1 ;;
esac

[ -z "$MSG" ] && { echo "ERRO: passe a mensagem do commit como primeiro argumento." >&2; exit 1; }

git rev-parse --git-dir >/dev/null 2>&1 || { echo "ERRO: não está em um repo git." >&2; exit 1; }

DEFAULT=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@' || echo "main")
CURRENT=$(git rev-parse --abbrev-ref HEAD)
DIRTY=$([ -n "$(git status --porcelain)" ] && echo true || echo false)
AHEAD=$(git rev-list --count "origin/$DEFAULT..HEAD" 2>/dev/null || echo 0)

# Sem mudanças nem commits ahead — nada a fazer
if [ "$DIRTY" = "false" ] && [ "$AHEAD" -eq 0 ]; then
  echo "Nada a commitar — working tree clean e nenhum commit ahead de origin/$DEFAULT."
  exit 0
fi

# Inferir TYPE a partir do prefixo do commit (Conventional Commits) se não passado
if [ -z "$TYPE" ]; then
  case "$MSG" in
    feat:*|feat\(*\):*) TYPE="feat" ;;
    fix:*|fix\(*\):*) TYPE="fix" ;;
    chore:*|chore\(*\):*) TYPE="chore" ;;
    refactor:*|refactor\(*\):*) TYPE="refactor" ;;
    docs:*|docs\(*\):*) TYPE="docs" ;;
    test:*|test\(*\):*) TYPE="test" ;;
    perf:*|perf\(*\):*) TYPE="perf" ;;
    *) TYPE="chore" ;;
  esac
fi

# Gerar nome de branch a partir da mensagem se não passado
if [ -z "$BRANCH_NAME" ]; then
  # Strip prefix "tipo:" ou "tipo(escopo):" da mensagem antes de slugify
  CLEAN=$(echo "$MSG" | sed -E 's/^[a-z]+(\([^)]*\))?:[[:space:]]*//' | head -1)
  SLUG=$(echo "$CLEAN" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9]+/-/g' \
    | sed -E 's/^-+|-+$//g' \
    | cut -c1-50 \
    | sed -E 's/-+$//')
  [ -z "$SLUG" ] && SLUG="auto-$(date +%s)"
  BRANCH_NAME="${TYPE}/${SLUG}"
fi

# Validar nome de branch
[[ "$BRANCH_NAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9/_.-]*$ ]] || { echo "ERRO: nome de branch inválido '$BRANCH_NAME'." >&2; exit 1; }

# Se branch já existe local ou remoto, falhar (proteção contra colisão)
if git show-ref --verify --quiet "refs/heads/$BRANCH_NAME"; then
  echo "ERRO: branch local '$BRANCH_NAME' já existe. Use --branch=outro-nome." >&2
  exit 1
fi

echo "→ Slot estado:"
echo "    branch atual: $CURRENT"
echo "    dirty:        $DIRTY"
echo "    ahead origin/$DEFAULT: $AHEAD commit(s)"
echo "    branch nova:  $BRANCH_NAME"
echo ""

# CASO A: Estamos em main com commits já feitos ahead → marcar branch no HEAD e resetar main
if [ "$CURRENT" = "$DEFAULT" ] && [ "$AHEAD" -gt 0 ]; then
  echo "→ $AHEAD commit(s) já em main local. Movendo para branch '$BRANCH_NAME' e resetando main."
  git branch "$BRANCH_NAME"
  git reset --hard "origin/$DEFAULT"
  git checkout "$BRANCH_NAME"

  # Se ainda há mudanças dirty (improvável, mas possível), commitar agora
  if [ "$DIRTY" = "true" ]; then
    git add -A
    git commit -m "$MSG"
  fi

# CASO B: Estamos em main com mudanças não commitadas → criar branch e commitar
elif [ "$CURRENT" = "$DEFAULT" ] && [ "$DIRTY" = "true" ]; then
  echo "→ Criando branch '$BRANCH_NAME' a partir de $DEFAULT e commitando."
  git checkout -b "$BRANCH_NAME"
  git add -A
  git commit -m "$MSG"

# CASO C: Já estamos em outra branch (legado).
#   - Se usuário passou --branch explícito: renomeia a branch atual para o nome pedido
#     (override explícito tem precedência sobre comportamento legado).
#   - Caso contrário: usa a branch atual como destino do PR.
else
  if [ "$BRANCH_EXPLICIT" = "true" ]; then
    echo "→ Já em branch '$CURRENT'; renomeando para '$BRANCH_NAME' (--branch explícito)."
    git branch -m "$BRANCH_NAME"
  else
    echo "→ Já em branch '$CURRENT' (não-default). Commitando e pushando essa branch."
    BRANCH_NAME="$CURRENT"
  fi
  if [ "$DIRTY" = "true" ]; then
    git add -A
    git commit -m "$MSG"
  fi
fi

# Push da branch nova
echo "→ git push -u origin $BRANCH_NAME"
git push -u origin "$BRANCH_NAME"

# Abrir PR
if [ "$NO_PR" = "true" ]; then
  echo "✓ Push concluído. PR não aberto (--no-pr)."
  exit 0
fi

if ! command -v gh >/dev/null 2>&1; then
  echo "AVISO: gh não instalado. Push feito; abra PR manualmente."
  exit 0
fi

TITLE=$(echo "$MSG" | head -1 | cut -c1-70)
BODY=$(cat <<EOF
## Summary
$MSG

🤖 Generated with [Claude Code](https://claude.ai/code)
EOF
)

PR_FLAGS=("--title" "$TITLE" "--body" "$BODY" "--base" "$DEFAULT" "--head" "$BRANCH_NAME")
[ "$DRAFT" = "true" ] && PR_FLAGS+=("--draft")

# Invalida QUALQUER CPP_LAST_PR de ciclo anterior ANTES do create: se a
# extração abaixo falhar, o arquivo fica AUSENTE (pr-watch cai no fallback
# gh pr view), nunca stale — número velho respondendo MERGED virava falso
# "CI verde" na Fase 8 (code-review 2026-07-02).
rm -f "$(git rev-parse --git-dir)/CPP_LAST_PR"

PR_URL=$(gh pr create "${PR_FLAGS[@]}" 2>&1 | tail -1)
echo "✓ PR aberto: $PR_URL"

# Grava o número do PR em .git/CPP_LAST_PR para o pr-watch.sh (Fase 8 dos
# /full-cycle*) não depender da branch atual — o auto-merge pode mergear e
# deletar a branch antes do watch resolver (corrida do PR #86). Extração
# defensiva: PR_URL captura stderr acima e pode ser uma linha de ERRO do gh,
# não URL — sem match de /pull/<dígitos> no fim, NÃO grava.
if [[ "$PR_URL" =~ /pull/([0-9]+)$ ]]; then
  echo "${BASH_REMATCH[1]}" > "$(git rev-parse --git-dir)/CPP_LAST_PR"
fi

# Merge resiliente e à prova de `set -e`.
#   A estratégia é decidida pelo setting `allow_auto_merge` do repo — NÃO por um
#   probe de classic branch protection (que não detecta org-rulesets nem required
#   status checks, e fazia o script tentar um merge imediato com checks ainda
#   pendentes → mergeStateStatus BLOCKED → gh recusa):
#     allow_auto_merge=true  → `--auto`: o GitHub mergeia quando os checks passarem.
#     allow_auto_merge=false → aguarda os checks ficarem verdes e mergeia direto.
#   Toda chamada `gh pr merge` é blindada (`… && MERGE_RC=0 || MERGE_RC=$?`), pois
#   sob `set -e` uma atribuição `VAR=$(cmd)` cujo cmd retorna ≠0 aborta o script
#   ANTES de capturar o RC — era o bug que matava o script sem diagnóstico.
#   O PR já foi criado com sucesso; pendência/falha de CI nunca faz o script sair ≠0.
# Em DRAFT: gh impede merge — pular silenciosamente.
if [ "$AUTO_MERGE" = "true" ] && [ "$DRAFT" != "true" ]; then
  REPO_FULL=$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || echo "")
  ALLOW_AUTO=$(gh api "repos/$REPO_FULL" --jq .allow_auto_merge 2>/dev/null || echo "false")

  if [ "$ALLOW_AUTO" = "true" ]; then
    MERGE_OUT=$(gh pr merge "$BRANCH_NAME" --auto "--$MERGE_METHOD" --delete-branch 2>&1) && MERGE_RC=0 || MERGE_RC=$?
    if [ "$MERGE_RC" -eq 0 ]; then
      echo "✓ Auto-merge ($MERGE_METHOD) armado — mergeia quando o CI passar."
    else
      echo "AVISO: --auto rejeitado. Mensagem do gh:"
      echo "$MERGE_OUT" | sed 's/^/    /'
      echo "       Force-merge com: /force-merge $BRANCH_NAME"
    fi
  else
    echo "→ Repo sem auto-merge; aguardando checks p/ merge direto (timeout 180s)."
    DEADLINE=$(( $(date +%s) + 180 ))
    CHECKS=""
    while :; do
      CHECKS=$(gh pr checks "$BRANCH_NAME" 2>/dev/null || echo "")
      echo "$CHECKS" | grep -qiE 'pending|queued|in progress' || break
      if [ "$(date +%s)" -ge "$DEADLINE" ]; then echo "AVISO: timeout aguardando checks."; break; fi
      sleep 6
    done
    if echo "$CHECKS" | grep -qiE '\bfail'; then
      echo "AVISO: há checks com falha — não vou mergear. Veja: gh pr checks $BRANCH_NAME"
      echo "       Force-merge (após avaliar) com: /force-merge $BRANCH_NAME"
    else
      MERGE_OUT=$(gh pr merge "$BRANCH_NAME" "--$MERGE_METHOD" --delete-branch 2>&1) && MERGE_RC=0 || MERGE_RC=$?
      if [ "$MERGE_RC" -eq 0 ]; then
        echo "✓ PR mergeado ($MERGE_METHOD, branch remota deletada)."
      else
        echo "AVISO: merge direto falhou. Mensagem do gh:"
        echo "$MERGE_OUT" | sed 's/^/    /'
        echo "       Tente: /force-merge $BRANCH_NAME"
      fi
    fi
  fi
fi

# Voltar para main local (slot fica pronto para próxima tarefa após sync-all)
git checkout "$DEFAULT" --quiet 2>/dev/null || true

cat <<EOF

Branch '$BRANCH_NAME' empurrada e PR criado.
Slot voltou para '$DEFAULT' local (commits da branch ainda existem localmente até /checkout-sync-all).

Próximos passos:
  1. Aguardar CI + auto-merge (se habilitado) ou merge manual.
  2. Após merge: /sync ou /checkout-sync-all <repo>   # atualiza main em todos os slots
EOF

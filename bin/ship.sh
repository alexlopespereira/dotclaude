#!/usr/bin/env bash
# bin/ship.sh — auto-pipeline de entrega (Fatia 1).
#
# Executa sequência linear: pre-checks → load config → pre-merge tests →
# commit+push+PR → auto-merge (ou force-merge soft em não-protegida) →
# deploy (se config) → e2e pós-merge (se config). Reporta exit codes
# específicos pra cada tipo de falha; loops de retry com fix são
# responsabilidade do slash command (commands/ship.md), não deste script.
#
# Exit codes:
#   0   sucesso
#   1   erro fatal (config inválida, auth missing, git error, deploy fail)
#   2   uso incorreto (flags inválidas, sem mensagem)
#   10  pré-merge tests falharam — orchestrador deve analisar+fix+re-invocar
#   20  e2e pós-merge falhou — orchestrador deve diagnose+fix-via-PR
#   30  branch protegida + auto-merge não disparou — humano decide
#   99  race condition (rebase conflito) — issue separada
#
# Uso:
#   ship.sh "mensagem" [--e2e=pre|post|none] [--max-retries=N]
#                      [--draft] [--dry-run] [--skip-deploy]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMIT_PUSH_PR="$SCRIPT_DIR/commit-push-pr.sh"
FORCE_MERGE="$SCRIPT_DIR/force-merge.sh"
SYNC_SCRIPT="$SCRIPT_DIR/sync.sh"

# ─── Parse args ──────────────────────────────────────────────────────────
MSG=""
E2E_OVERRIDE=""
MAX_RETRIES=""
DRAFT=false
DRY_RUN=false
SKIP_DEPLOY=false

while [ $# -gt 0 ]; do
  case "$1" in
    --e2e=*) E2E_OVERRIDE="${1#*=}" ;;
    --max-retries=*) MAX_RETRIES="${1#*=}" ;;
    --draft) DRAFT=true ;;
    --dry-run) DRY_RUN=true ;;
    --skip-deploy) SKIP_DEPLOY=true ;;
    -h|--help)
      sed -n '2,/^set -euo pipefail/p' "$0" | sed -E 's/^# ?//;/^set -euo/d'
      exit 0
      ;;
    -*) echo "ERRO: flag desconhecida: $1" >&2; exit 2 ;;
    *) [ -z "$MSG" ] && MSG="$1" || { echo "ERRO: arg extra: $1" >&2; exit 2; } ;;
  esac
  shift
done

case "$E2E_OVERRIDE" in
  ""|pre|post|none) ;;
  *) echo "ERRO: --e2e deve ser pre|post|none." >&2; exit 2 ;;
esac

# ─── Pré-checks de ambiente ──────────────────────────────────────────────
command -v git >/dev/null 2>&1 || { echo "ERRO: git não instalado." >&2; exit 1; }
command -v gh  >/dev/null 2>&1 || { echo "ERRO: gh CLI não instalado." >&2; exit 1; }
command -v jq  >/dev/null 2>&1 || { echo "ERRO: jq não instalado." >&2; exit 1; }
git rev-parse --git-dir >/dev/null 2>&1 || { echo "ERRO: não está em repo git." >&2; exit 1; }
[ -x "$COMMIT_PUSH_PR" ] || chmod +x "$COMMIT_PUSH_PR"
[ -x "$FORCE_MERGE" ]    || chmod +x "$FORCE_MERGE"

# AC-10: cleanup Graphify dirt antes de qualquer detecção de diff.
[ -d "graphify-out" ] && git checkout -- graphify-out/ 2>/dev/null || true

# ─── Estado do git ───────────────────────────────────────────────────────
DEFAULT_BRANCH=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@' || echo "main")
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
DIRTY=$([ -n "$(git status --porcelain)" ] && echo true || echo false)
AHEAD=$(git rev-list --count "origin/$DEFAULT_BRANCH..HEAD" 2>/dev/null || echo 0)

if [ "$CURRENT_BRANCH" != "$DEFAULT_BRANCH" ]; then
  echo "ERRO: ship.sh roda em '$DEFAULT_BRANCH' local (fluxo Boris). Atual: '$CURRENT_BRANCH'." >&2
  exit 1
fi

if [ "$DIRTY" = "false" ] && [ "$AHEAD" -eq 0 ]; then
  echo "ERRO: nada a commitar — working tree limpo e sem commits ahead de origin/$DEFAULT_BRANCH." >&2
  exit 1
fi

# MSG obrigatório. Inferência fraca/forte é responsabilidade do slash command
# (commands/ship.md lê contexto + diff + invoca este script com mensagem pronta).
# Sem mensagem aqui = uso direto incorreto.
if [ -z "$MSG" ]; then
  echo "ERRO: ship.sh requer mensagem como primeiro argumento." >&2
  echo "       Uso direto: ship.sh \"feat: ...\"" >&2
  echo "       Via slash:  /ship (que infere do contexto + invoca este script)." >&2
  exit 2
fi

# AC-2 guardrail Princípio 7: scan de segredos no diff staged + working tree.
SECRET_PATTERNS='(\.env|\.pem$|credentials|secret|api[_-]?key|password|aws_access_key|aws_secret)'
if git diff --cached --name-only 2>/dev/null | grep -iqE "$SECRET_PATTERNS"; then
  echo "ERRO: arquivo suspeito de segredo no diff staged. Aborto." >&2
  git diff --cached --name-only | grep -iE "$SECRET_PATTERNS" | sed 's/^/  /' >&2
  exit 1
fi

# ─── Load ship.json ──────────────────────────────────────────────────────
SHIP_JSON=".claude/ship.json"
E2E_STRATEGY=""
DEPLOY_CMD=""
DEPLOY_STORE=""
DEPLOY_SKIP_PATTERNS=""
DEPLOY_WAIT=30
E2E_URL=""
UI_EXTENSIONS=""
PRE_MERGE_TESTS=""
CI_TIMEOUT=1800   # teto (s) da espera de CI via gh pr checks --watch; override em ship.json.ciTimeoutSeconds

if [ -f "$SHIP_JSON" ]; then
  jq . "$SHIP_JSON" >/dev/null 2>&1 || { echo "ERRO: $SHIP_JSON JSON inválido." >&2; exit 1; }
  E2E_STRATEGY=$(jq -r '.e2e // ""'                    "$SHIP_JSON")
  DEPLOY_CMD=$(jq -r '.deploy.command // ""'            "$SHIP_JSON")
  DEPLOY_STORE=$(jq -r '.deploy.store // ""'            "$SHIP_JSON")
  DEPLOY_SKIP_PATTERNS=$(jq -r '.deploy.skipPatterns // ""' "$SHIP_JSON")
  DEPLOY_WAIT=$(jq -r '.deploy.waitSecondsAfter // 30'  "$SHIP_JSON")
  E2E_URL=$(jq -r '.e2eUrl // ""'                       "$SHIP_JSON")
  UI_EXTENSIONS=$(jq -r '(.uiExtensions // []) | join("|")' "$SHIP_JSON")
  PRE_MERGE_TESTS=$(jq -c '.preMergeTests // empty'     "$SHIP_JSON")
  CI_TIMEOUT=$(jq -r ".ciTimeoutSeconds // $CI_TIMEOUT" "$SHIP_JSON")
  MR_CFG=$(jq -r '.maxRetries // ""'                    "$SHIP_JSON")
  [ -z "$MAX_RETRIES" ] && [ -n "$MR_CFG" ] && MAX_RETRIES="$MR_CFG"
fi
[ -z "$MAX_RETRIES" ] && MAX_RETRIES=3

# Flag CLI sobrepõe config.
[ -n "$E2E_OVERRIDE" ] && E2E_STRATEGY="$E2E_OVERRIDE"

# ─── Decide estratégia e2e (cascata C → A → B) ───────────────────────────
if [ -z "$E2E_STRATEGY" ]; then
  # auto-detect via regex em diff
  UI_REGEX='\.(tsx?|jsx?|vue|svelte|html|css|scss)$'
  [ -n "$UI_EXTENSIONS" ] && UI_REGEX="\\.($UI_EXTENSIONS|tsx?|jsx?|vue|svelte|html|css|scss)$"
  if git diff --name-only origin/"$DEFAULT_BRANCH"..HEAD | grep -qE "$UI_REGEX" 2>/dev/null \
     || git diff --name-only | grep -qE "$UI_REGEX" 2>/dev/null; then
    E2E_STRATEGY="pre"
  else
    E2E_STRATEGY="none"
  fi
fi

# AC-12: e2e=pre fora de escopo Fatia 1
if [ "$E2E_STRATEGY" = "pre" ]; then
  echo "ERRO: e2e='pre' requer dev server local (fora de escopo Fatia 1)." >&2
  echo "       Use ship.json.e2e='post' ou 'none', ou flag --e2e=none." >&2
  exit 1
fi

# ─── AC-3: shopify auth check (skip em dry-run) ──────────────────────────
if [ "$DRY_RUN" = "false" ] && [ -n "$DEPLOY_CMD" ] && [ "$SKIP_DEPLOY" = "false" ]; then
  if ! command -v shopify >/dev/null 2>&1; then
    echo "ERRO: shopify CLI não instalada. Necessária pra deploy do tema." >&2
    exit 1
  fi
  if [ -z "$DEPLOY_STORE" ]; then
    echo "ERRO: ship.json.deploy.store ausente — não consigo testar auth." >&2
    exit 1
  fi
  AUTH_OUT=$(shopify theme list --store="$DEPLOY_STORE" --json 2>&1 || true)
  if ! echo "$AUTH_OUT" | jq . >/dev/null 2>&1; then
    echo "ERRO: shopify CLI não autenticada em store $DEPLOY_STORE." >&2
    echo "       Rode 'shopify login --store=$DEPLOY_STORE' em terminal interativo." >&2
    echo "       /ship não mergeará sabendo que 'theme push' falharia (shopify[bot] reverte em ~3h)." >&2
    exit 1
  fi
fi

# ─── Slug + branch derivada da mensagem ──────────────────────────────────
case "$MSG" in
  feat:*|feat\(*\):*)         TYPE="feat" ;;
  fix:*|fix\(*\):*)           TYPE="fix" ;;
  chore:*|chore\(*\):*)       TYPE="chore" ;;
  refactor:*|refactor\(*\):*) TYPE="refactor" ;;
  docs:*|docs\(*\):*)         TYPE="docs" ;;
  test:*|test\(*\):*)         TYPE="test" ;;
  perf:*|perf\(*\):*)         TYPE="perf" ;;
  *)                          TYPE="chore" ;;
esac
CLEAN=$(echo "$MSG" | sed -E 's/^[a-z]+(\([^)]*\))?:[[:space:]]*//' | head -1)
SLUG=$(echo "$CLEAN" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g' | sed -E 's/^-+|-+$//g' | cut -c1-50 | sed -E 's/-+$//')
[ -z "$SLUG" ] && SLUG="auto-$(date +%s)"
BRANCH="${TYPE}/${SLUG}"

# ─── AC-5: --dry-run ─────────────────────────────────────────────────────
if [ "$DRY_RUN" = "true" ]; then
  DRY_COMMITTED=false
  if [ "$DIRTY" = "true" ]; then
    git add -A
    git -c commit.gpgsign=false commit -m "$MSG" --no-verify >/dev/null
    DRY_COMMITTED=true
  fi

  ESTIMATED_TIME="~3-5min (sem deploy)"
  [ -n "$DEPLOY_CMD" ] && [ "$SKIP_DEPLOY" = "false" ] && ESTIMATED_TIME="~25-35min se e2e falhar 3x"

  cat <<EOF

═══════════════════ DRY RUN ═══════════════════
Mensagem:        $MSG
Branch:          $BRANCH
Estratégia e2e:  $E2E_STRATEGY
Max retries:     $MAX_RETRIES
Deploy:          $([ -n "$DEPLOY_CMD" ] && [ "$SKIP_DEPLOY" = "false" ] && echo "$DEPLOY_CMD" || echo "(none)")
E2e URL:         $([ -n "$E2E_URL" ] && echo "$E2E_URL" || echo "(none)")
Pior caso:       $ESTIMATED_TIME

Comandos planejados:
  1. bash $COMMIT_PUSH_PR "$MSG" --branch=$BRANCH$([ "$DRAFT" = "true" ] && echo " --draft")
  2. aguardar auto-merge (30s)
  3. se não mergeou + branch não-protegida: bash $FORCE_MERGE <PR> --no-sync
  4. se não mergeou + branch protegida: exit 30 (humano decide)
  5. bash $SYNC_SCRIPT (sync pool)
EOF

  if [ -n "$DEPLOY_CMD" ] && [ "$SKIP_DEPLOY" = "false" ]; then
    echo "  6. se PR tocou arquivos fora da deny-list: $DEPLOY_CMD"
    echo "  7. sleep ${DEPLOY_WAIT}s (CDN propagar)"
  fi

  if [ "$E2E_STRATEGY" = "post" ]; then
    echo "  8. SHOPIFY_STORE_URL=$E2E_URL npx playwright test --reporter=line --max-failures=3"
    echo "  9. se falhou → exit 20 (orchestrador faz loop fix)"
  fi

  echo ""
  echo "(nenhum efeito remoto executado; commit local revertido)"
  echo "═══════════════════════════════════════════════"

  # AC-5: working tree volta ao estado pré-comando.
  # reset mixed (default) desfaz commit + unstage; arquivos untracked
  # antes do commit voltam a ser untracked depois do reset.
  [ "$DRY_COMMITTED" = "true" ] && git reset HEAD~1 >/dev/null
  exit 0
fi

# ─── Pré-merge tests (AC-8) ──────────────────────────────────────────────
if [ -f package.json ]; then
  echo "→ Pré-merge tests (auto-detect)..."

  if [ -n "$PRE_MERGE_TESTS" ] && [ "$PRE_MERGE_TESTS" != "null" ]; then
    # override: usa lista declarada
    while IFS= read -r script; do
      [ -z "$script" ] && continue
      echo "  → npm run $script"
      npm run "$script" || { echo "ERRO: pré-merge test '$script' falhou." >&2; exit 10; }
    done < <(echo "$PRE_MERGE_TESTS" | jq -r '.[]')
  else
    # auto-detect: lint, typecheck, unit (excluindo Playwright-disguised-as-test)
    SCRIPTS=$(jq -r '.scripts // {} | keys[]' package.json 2>/dev/null || true)
    LINT=$(echo "$SCRIPTS" | grep -m1 -E '^(lint|eslint|check)$' || true)
    TYPECHECK=$(echo "$SCRIPTS" | grep -m1 -E '^(typecheck|tsc|check-types)$' || true)
    UNIT=$(echo "$SCRIPTS" | grep -m1 -E '^(test:unit|test)$' || true)
    if [ "$UNIT" = "test" ]; then
      TEST_CMD=$(jq -r '.scripts.test // ""' package.json)
      if echo "$TEST_CMD" | grep -qE 'playwright|cypress'; then
        UNIT=""
      fi
    fi
    for s in $LINT $TYPECHECK $UNIT; do
      echo "  → npm run $s"
      npm run "$s" || { echo "ERRO: pré-merge test '$s' falhou." >&2; exit 10; }
    done
    [ -z "$LINT$TYPECHECK$UNIT" ] && echo "  (nenhum script auto-detectado — pulando pré-merge tests)"
  fi
fi

# ─── Commit + push + PR + auto-merge ─────────────────────────────────────
echo "→ Invocando commit-push-pr.sh"
COMMIT_FLAGS=("--branch=$BRANCH")
[ "$DRAFT" = "true" ] && COMMIT_FLAGS+=("--draft")
bash "$COMMIT_PUSH_PR" "$MSG" "${COMMIT_FLAGS[@]}" || { echo "ERRO: commit-push-pr.sh falhou." >&2; exit 1; }

# ─── Resolver PR number ──────────────────────────────────────────────────
sleep 2  # gh leva uns segundos pra registrar
PR_NUM=$(gh pr list --head "$BRANCH" --state open --json number --jq '.[0].number // empty' 2>/dev/null || true)
if [ -z "$PR_NUM" ]; then
  # talvez já mergeou (auto-merge dispara rápido em repo solo)
  PR_NUM=$(gh pr list --head "$BRANCH" --state merged --json number --jq '.[0].number // empty' 2>/dev/null || true)
  if [ -z "$PR_NUM" ]; then
    echo "AVISO: PR pra branch '$BRANCH' não encontrado. Auto-merge pode ter mergeado e deletado branch. Continuando." >&2
  fi
fi

# Aguarda CI verde via `gh pr checks --watch` com teto por perl alarm — mesmo
# idioma de force-merge.sh:221 (perl ships com macOS; alarm dispara SIGALRM →
# exit 142 = timeout). Substitui o antigo polling com `sleep 5`, que aguardava
# tempo fixo sem observar o resultado do CI. Se a branch já mergeou (auto-merge
# rápido em repo solo) ou não há checks, segue direto. CI vermelho aborta o
# caminho de merge — não mergeia com checks falhando.
if [ -n "$PR_NUM" ]; then
  PR_STATE=$(gh pr view "$PR_NUM" --json state --jq .state 2>/dev/null || echo "UNKNOWN")
  if [ "$PR_STATE" != "MERGED" ]; then
    CHECKS_RAW=$(gh pr checks "$PR_NUM" --json state 2>/dev/null || echo '[]')
    CHECKS_COUNT=$(echo "$CHECKS_RAW" | jq 'length' 2>/dev/null || echo 0)
    if [ "$CHECKS_COUNT" -eq 0 ] 2>/dev/null; then
      echo "  PR #$PR_NUM sem checks configurados — sem CI pra aguardar."
    else
      echo "→ Aguardando CI verde do PR #$PR_NUM ($CHECKS_COUNT check(s), timeout ${CI_TIMEOUT}s)..."
      WATCH_RC=0
      perl -e 'alarm shift; exec @ARGV' "$CI_TIMEOUT" gh pr checks "$PR_NUM" --watch || WATCH_RC=$?
      if [ "$WATCH_RC" = "142" ]; then
        echo "ERRO: timeout (${CI_TIMEOUT}s) aguardando CI do PR #$PR_NUM." >&2
        exit 1
      fi
      if [ "$WATCH_RC" -ne 0 ]; then
        echo "ERRO: CI vermelho no PR #$PR_NUM — não mergeio com checks falhando." >&2
        gh pr checks "$PR_NUM" --json name,state --jq '.[] | select(.state=="FAILURE") | "  ✗ " + .name' 2>/dev/null >&2 || true
        exit 1
      fi
      echo "✓ CI verde no PR #$PR_NUM."
    fi
  fi
fi

# ─── Force-merge se ainda aberto + branch não-protegida (AC-1) ───────────
if [ -n "$PR_NUM" ]; then
  PR_STATE=$(gh pr view "$PR_NUM" --json state --jq .state 2>/dev/null || echo "UNKNOWN")
  if [ "$PR_STATE" = "OPEN" ]; then
    REPO_NWO=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)
    PROTECTED=false
    [ -n "$REPO_NWO" ] && gh api "repos/$REPO_NWO/branches/$DEFAULT_BRANCH/protection" >/dev/null 2>&1 && PROTECTED=true

    if [ "$PROTECTED" = "false" ]; then
      echo "→ Auto-merge não disparou (repo sem allow_auto_merge?); forçando merge soft (branch não-protegida)..."
      FORCE_MERGE_NESTED=1 FORCE_MERGE_CONFIRMED=1 bash "$FORCE_MERGE" "$PR_NUM" --no-sync \
        || { echo "ERRO: force-merge soft falhou." >&2; exit 1; }
    else
      echo "" >&2
      echo "⚠ Branch '$DEFAULT_BRANCH' é protegida e auto-merge não disparou." >&2
      echo "  PR aberto: $(gh pr view "$PR_NUM" --json url --jq .url 2>/dev/null)" >&2
      echo "  /ship pausou. Após review humano, re-invoque /ship pra retomar e2e pós-merge." >&2
      exit 30
    fi
  fi
fi

# ─── Sync pool ───────────────────────────────────────────────────────────
[ -x "$SYNC_SCRIPT" ] && bash "$SYNC_SCRIPT" 2>/dev/null || true

# ─── Deploy com deny-list (AC-2, AC-4) ───────────────────────────────────
if [ -n "$DEPLOY_CMD" ] && [ "$SKIP_DEPLOY" = "false" ]; then
  SKIP_REGEX="${DEPLOY_SKIP_PATTERNS:-^(scripts/|docs/|tests/|\\.claude/|\\.github/|wiki/|README|.*\\.md\$)}"

  if [ -n "$PR_NUM" ]; then
    PR_FILES=$(gh pr view "$PR_NUM" --json files --jq '.files[].path' 2>/dev/null || true)
    NON_SKIP=$(echo "$PR_FILES" | grep -vE "$SKIP_REGEX" || true)
    if [ -z "$NON_SKIP" ] && [ -n "$PR_FILES" ]; then
      echo "→ Deploy pulado: todos os arquivos do PR batem com deny-list."
    else
      echo ""
      echo "→ Deploy alvo: store $DEPLOY_STORE"
      [ -n "$E2E_URL" ] && echo "  URL afetada: $E2E_URL"
      echo "  Tempo estimado worst-case: ~25-35min se e2e falhar 3x"
      echo "  Modo: live (sem canary)"
      echo "  (Ctrl-C nos próximos 5s aborta)"
      sleep 5
      eval "$DEPLOY_CMD" || {
        echo "ERRO: deploy falhou. PR já mergeado — atenção: shopify[bot] pode reverter em ~3h." >&2
        exit 1
      }
      echo "→ Aguardando ${DEPLOY_WAIT}s pra CDN propagar..."
      sleep "$DEPLOY_WAIT"
    fi
  fi
fi

# ─── E2e pós-merge (AC: roda CLI 1x; orchestrador faz loop) ──────────────
if [ "$E2E_STRATEGY" = "post" ]; then
  if [ -z "$E2E_URL" ]; then
    echo "ERRO: ship.json.e2eUrl ausente — não sei URL pra rodar e2e post." >&2
    exit 1
  fi
  echo "→ E2e pós-merge contra $E2E_URL"
  if SHOPIFY_STORE_URL="$E2E_URL" CLAUDE=1 npx playwright test --reporter=line --max-failures=3; then
    echo "✓ /ship completou: $MSG mergeado, e2e green."
    osascript -e "display notification \"$MSG\" with title \"/ship completou\"" 2>/dev/null || true
    exit 0
  else
    echo "✗ E2e pós-merge falhou. Orchestrador deve analisar trace.zip + abrir PR de hotfix." >&2
    exit 20
  fi
fi

echo "✓ /ship completou: $MSG mergeado."
osascript -e "display notification \"$MSG\" with title \"/ship completou\"" 2>/dev/null || true
exit 0

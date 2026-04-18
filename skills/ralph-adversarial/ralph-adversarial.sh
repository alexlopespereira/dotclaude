#!/bin/bash
# Ralph Adversarial Loop — Claude Code implementa, Codex revisa
# Baseado no padrão Ralph (ghuntley.com/ralph, snarktank/ralph)
# Adaptado para revisão adversária com rubrica V2

set -e

MAX_ITERATIONS=${1:-10}
MAX_RETRIES_PER_STORY=2
ITERATION=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REVIEW_FILE="$SCRIPT_DIR/CODE_REVIEW.md"
REVIEW_SCHEMA="$SCRIPT_DIR/review-schema.json"

# ─── Verificações ───────────────────────────────────────────

if [ ! -f "prd.json" ]; then
    echo "ERRO: prd.json não encontrado na raiz."
    echo "Execute /prd-convert para gerar a partir do plano aprovado."
    exit 1
fi

if [ ! -f "$REVIEW_FILE" ]; then
    echo "ERRO: $REVIEW_FILE não encontrado."
    echo "A rubrica de revisão é necessária para o Codex."
    exit 1
fi

if [ ! -f "$REVIEW_SCHEMA" ]; then
    echo "ERRO: $REVIEW_SCHEMA não encontrado."
    echo "O schema de saída é necessário para forçar JSON determinístico do Codex."
    exit 1
fi

command -v jq >/dev/null 2>&1 || { echo "ERRO: jq não instalado"; exit 1; }
command -v claude >/dev/null 2>&1 || { echo "ERRO: Claude Code CLI não encontrado"; exit 1; }
command -v codex >/dev/null 2>&1 || { echo "ERRO: Codex CLI não encontrado"; exit 1; }

# ─── Setup ──────────────────────────────────────────────────

BRANCH_NAME=$(jq -r '.branchName' prd.json)
PROJECT_NAME=$(jq -r '.projectName' prd.json)

# Criar branch se não existir
git checkout -B "$BRANCH_NAME" 2>/dev/null || true

# Criar progress.txt se não existir
touch progress.txt

echo "=========================================="
echo "RALPH ADVERSARIAL LOOP"
echo "=========================================="
echo "Projeto:    $PROJECT_NAME"
echo "Branch:     $BRANCH_NAME"
echo "Iterações:  max $MAX_ITERATIONS"
echo "Rubrica:    $REVIEW_FILE"
echo "=========================================="

# ─── Retry tracker ──────────────────────────────────────────

declare -A RETRY_COUNT

# ─── Loop Principal ─────────────────────────────────────────

while [ $ITERATION -lt $MAX_ITERATIONS ]; do
    ITERATION=$((ITERATION + 1))

    # Checar se todas as stories passaram
    PENDING=$(jq '[.userStories[] | select(.passes == false)] | length' prd.json)
    if [ "$PENDING" -eq 0 ]; then
        echo ""
        echo "=========================================="
        echo "TODAS AS STORIES COMPLETAS!"
        echo "Iterações usadas: $ITERATION"
        echo "=========================================="
        exit 0
    fi

    # Pegar próxima story pendente (menor priority)
    STORY_ID=$(jq -r '[.userStories[] | select(.passes == false)] | sort_by(.priority) | .[0].id' prd.json)
    STORY_TITLE=$(jq -r --arg id "$STORY_ID" '.userStories[] | select(.id == $id) | .title' prd.json)

    echo ""
    echo "--- Iteração $ITERATION/$MAX_ITERATIONS ---"
    echo "Story: $STORY_ID - $STORY_TITLE"
    echo "Pendentes: $PENDING"

    # Checar retries
    CURRENT_RETRIES=${RETRY_COUNT[$STORY_ID]:-0}
    if [ "$CURRENT_RETRIES" -ge "$MAX_RETRIES_PER_STORY" ]; then
        echo "ESCALAÇÃO: Story $STORY_ID falhou $MAX_RETRIES_PER_STORY vezes consecutivas."
        echo "Intervenção humana necessária."
        echo "$(date -Iseconds) | ESCALAÇÃO | $STORY_ID falhou $MAX_RETRIES_PER_STORY vezes" >> progress.txt
        # Pular para próxima story ou sair
        jq --arg id "$STORY_ID" '(.userStories[] | select(.id == $id)) .passes = "ESCALATED"' prd.json > prd.tmp && mv prd.tmp prd.json
        continue
    fi

    # ── Fase A: Claude Code implementa ──────────────────────

    echo ""
    echo "[A] Claude Code — Implementando..."

    CLAUDE_PROMPT="Você está no loop Ralph Adversarial. Contexto fresco — leia tudo do disco.

LEIA ESTES ARQUIVOS PRIMEIRO:
- prd.json (sua lista de tasks — implemente a story $STORY_ID)
- progress.txt (aprendizados e feedback de iterações anteriores)
- git log --oneline -20 (o que já foi feito)

STORY A IMPLEMENTAR: $STORY_ID - $STORY_TITLE

REGRAS:
1. Implemente APENAS esta story. Não toque em código que não é necessário.
2. Rode os quality checks do projeto (typecheck, lint, testes).
3. Se checks passarem, faça git commit com esta estrutura no message:
   [$STORY_ID] $STORY_TITLE

   ac_trace:
   - AC1: [arquivo:linhas] testado em [arquivo_teste:linha] → pass/fail
   - AC2: [arquivo:linhas] testado em [arquivo_teste:linha] → pass/fail

4. Se checks falharem, corrija e tente novamente.
5. Após o commit, atualize AGENTS.md com qualquer padrão ou gotcha descoberto.
6. Registre aprendizados em progress.txt.

PRINCÍPIOS KARPATHY:
- Mudança mínima viável. Toda linha mudada deve rastrear para um AC.
- Sem refactoring drive-by. Sem abstração especulativa.
- Verifique a cada passo. Rode testes após cada mudança significativa."

    claude --print "$CLAUDE_PROMPT" 2>&1 | tail -20

    # Verificar se houve commit (pode não existir em branch recém-criado)
    LAST_COMMIT=$(git log -1 --format="%H" 2>/dev/null || echo "")
    LAST_MSG=$(git log -1 --format="%s" 2>/dev/null || echo "")

    if [ -z "$LAST_COMMIT" ] || [[ "$LAST_MSG" != *"$STORY_ID"* ]]; then
        echo "  AVISO: Claude não commitou com $STORY_ID no message."
        echo "$(date -Iseconds) | FALHA_COMMIT | $STORY_ID | Claude não produziu commit válido" >> progress.txt
        RETRY_COUNT[$STORY_ID]=$((CURRENT_RETRIES + 1))
        continue
    fi

    echo "  Commit: $LAST_MSG"

    # ── Fase B: Codex revisa ────────────────────────────────

    echo ""
    echo "[B] Codex — Revisando código..."

    REVIEW_PROMPT="Revise o último commit deste repositório.

LEIA PRIMEIRO:
- $REVIEW_FILE (sua rubrica de revisão — siga-a estritamente)
- O diff do último commit: git diff HEAD~1
- A story no prd.json com id=$STORY_ID (seus acceptance criteria)

Aplique a rubrica em $REVIEW_FILE.
Produza o JSON de saída conforme o schema especificado na rubrica.
Se não encontrar issues reais, retorne verdict: MERGE."

    mkdir -p .claude/research 2>/dev/null || true
    REVIEW_OUT=".claude/research/review-${STORY_ID}-iter${ITERATION}.json"
    REVIEW_LOG=".claude/research/review-${STORY_ID}-iter${ITERATION}.log"

    # Em Codex 0.120+, --ask-for-approval é flag global (antes de `exec`).
    # --full-auto concede workspace-write; --output-schema força JSON válido;
    # --output-last-message captura apenas a resposta final do modelo.
    codex --ask-for-approval never exec \
        --full-auto \
        --output-schema "$REVIEW_SCHEMA" \
        --output-last-message "$REVIEW_OUT" \
        "$REVIEW_PROMPT" > "$REVIEW_LOG" 2>&1 || true

    tail -30 "$REVIEW_LOG"

    # ── Fase C: Interpretar veredicto ───────────────────────

    if [ ! -s "$REVIEW_OUT" ] || ! jq -e . "$REVIEW_OUT" >/dev/null 2>&1; then
        VERDICT="UNKNOWN"
    else
        VERDICT=$(jq -r '.verdict // "UNKNOWN"' "$REVIEW_OUT")
    fi

    echo "  Veredicto: $VERDICT"

    case $VERDICT in
        MERGE)
            echo "  Story $STORY_ID APROVADA"
            jq --arg id "$STORY_ID" '(.userStories[] | select(.id == $id)).passes = true' prd.json > prd.tmp && mv prd.tmp prd.json
            git add prd.json
            git commit -m "[$STORY_ID] Marcada como passes:true após review" --allow-empty
            RETRY_COUNT[$STORY_ID]=0
            ;;
        BLOCK|REQUEST_CHANGES)
            EVID=$(jq -r '[.findings[]? | "\(.priority):\(.file):\(.line) \(.evidence)"] | join(" | ")' "$REVIEW_OUT" 2>/dev/null | head -c 500)
            echo "  Story $STORY_ID REJEITADA — feedback salvo em progress.txt"
            echo "$(date -Iseconds) | REVIEW_$VERDICT | $STORY_ID | $EVID" >> progress.txt
            RETRY_COUNT[$STORY_ID]=$((CURRENT_RETRIES + 1))
            ;;
        *)
            echo "  Veredicto não identificado — tratando como REQUEST_CHANGES"
            echo "$(date -Iseconds) | REVIEW_UNKNOWN | $STORY_ID | Schema inválido ou arquivo vazio (ver $REVIEW_LOG)" >> progress.txt
            RETRY_COUNT[$STORY_ID]=$((CURRENT_RETRIES + 1))
            ;;
    esac
done

echo ""
echo "=========================================="
echo "LOOP ENCERRADO — max iterações atingido"
echo "Stories pendentes: $(jq '[.userStories[] | select(.passes == false)] | length' prd.json)"
echo "=========================================="
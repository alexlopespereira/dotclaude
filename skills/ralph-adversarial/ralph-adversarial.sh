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
# Bash 3.2 compat: usar arquivo em vez de array associativo

RETRY_FILE="$(mktemp -t ralph-retry.XXXXXX)"
trap 'rm -f "$RETRY_FILE"' EXIT

get_retry_count() {
    local story_id="$1"
    local count
    count=$(grep "^${story_id}:" "$RETRY_FILE" 2>/dev/null | tail -1 | cut -d: -f2)
    echo "${count:-0}"
}

set_retry_count() {
    local story_id="$1"
    local count="$2"
    grep -v "^${story_id}:" "$RETRY_FILE" > "${RETRY_FILE}.tmp" 2>/dev/null || true
    echo "${story_id}:${count}" >> "${RETRY_FILE}.tmp"
    mv "${RETRY_FILE}.tmp" "$RETRY_FILE"
}

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
    CURRENT_RETRIES=$(get_retry_count "$STORY_ID")
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

    claude --print --permission-mode bypassPermissions "$CLAUDE_PROMPT" 2>&1 | tail -20 || true

    # Verificar se houve commit
    LAST_COMMIT=$(git log -1 --format="%H" 2>/dev/null)
    LAST_MSG=$(git log -1 --format="%s" 2>/dev/null)

    if [[ "$LAST_MSG" != *"$STORY_ID"* ]]; then
        echo "  AVISO: Claude não commitou com $STORY_ID no message."
        echo "$(date -Iseconds) | FALHA_COMMIT | $STORY_ID | Claude não produziu commit válido" >> progress.txt
        set_retry_count "$STORY_ID" "$((CURRENT_RETRIES + 1))"
        continue
    fi

    echo "  Commit: $LAST_MSG"

    # ── Fase B: Codex revisa ────────────────────────────────

    echo ""
    echo "[B] Codex — Revisando código..."

    # Codex 0.120+: "exec review --commit SHA --full-auto" não aceita PROMPT customizado.
    # Usamos o modo review padrão, que o Codex executa com sua rubrica interna.
    # A rubrica customizada CODE_REVIEW.md fica como guidance no repo (AGENTS.md pode referenciar).
    REVIEW_RESULT=$(codex exec review --commit HEAD --full-auto 2>&1 || echo '{"verdict":"BLOCK","error":"codex_exec_failed"}')

    echo "$REVIEW_RESULT" | tail -30

    # Salvar review
    mkdir -p .claude/research 2>/dev/null || true
    echo "$REVIEW_RESULT" > ".claude/research/review-${STORY_ID}-iter${ITERATION}.txt" 2>/dev/null || true

    # ── Fase C: Interpretar veredicto ───────────────────────

    VERDICT="UNKNOWN"
    if echo "$REVIEW_RESULT" | grep -qi '"verdict".*"MERGE"'; then
        VERDICT="MERGE"
    elif echo "$REVIEW_RESULT" | grep -qi '"verdict".*"BLOCK"'; then
        VERDICT="BLOCK"
    elif echo "$REVIEW_RESULT" | grep -qi '"verdict".*"REQUEST_CHANGES"'; then
        VERDICT="REQUEST_CHANGES"
    fi

    echo "  Veredicto: $VERDICT"

    case $VERDICT in
        MERGE)
            echo "  Story $STORY_ID APROVADA"
            jq --arg id "$STORY_ID" '(.userStories[] | select(.id == $id)).passes = true' prd.json > prd.tmp && mv prd.tmp prd.json
            git add prd.json
            git commit -m "[$STORY_ID] Marcada como passes:true após review" --allow-empty
            set_retry_count "$STORY_ID" 0
            ;;
        BLOCK|REQUEST_CHANGES)
            echo "  Story $STORY_ID REJEITADA — feedback salvo em progress.txt"
            echo "$(date -Iseconds) | REVIEW_$VERDICT | $STORY_ID | $(echo "$REVIEW_RESULT" | grep -o '"evidence":[^,]*' | head -3)" >> progress.txt
            set_retry_count "$STORY_ID" "$((CURRENT_RETRIES + 1))"
            ;;
        *)
            echo "  Veredicto não identificado — tratando como REQUEST_CHANGES"
            echo "$(date -Iseconds) | REVIEW_UNKNOWN | $STORY_ID | Veredicto não parseado" >> progress.txt
            set_retry_count "$STORY_ID" "$((CURRENT_RETRIES + 1))"
            ;;
    esac
done

echo ""
echo "=========================================="
echo "LOOP ENCERRADO — max iterações atingido"
echo "Stories pendentes: $(jq '[.userStories[] | select(.passes == false)] | length' prd.json)"
echo "=========================================="
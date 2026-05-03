#!/bin/bash
# Ralph Adversarial Loop — Claude Code implementa, Codex revisa
# Baseado no padrão Ralph (ghuntley.com/ralph, snarktank/ralph)
# Adaptado para revisão adversária com rubrica V2

set -e

MAX_ITERATIONS=${1:-10}
MAX_RETRIES_PER_STORY=2
ITERATION=0

# AC9: timeout para hang detection (default 45min); usuário pode override por env var.
TIMEOUT=${RALPH_HANG_TIMEOUT:-2700}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REVIEW_FILE="$SCRIPT_DIR/CODE_REVIEW.md"
IMPL_PROMPT_FILE="$SCRIPT_DIR/IMPL_PROMPT.md"

# AC10: guard contra recursão acidental — Ralph não deve rodar dentro de seus próprios testes.
# Usuário pode forçar com RALPH_ALLOW_TEST_CWD=1 (usado pelo TDD test fixture).
if [[ "$PWD" == */skills/ralph-adversarial/tests/* ]] && [ "${RALPH_ALLOW_TEST_CWD:-0}" != "1" ]; then
    echo "ERRO: Ralph não deve rodar dentro de seus próprios testes. Defina RALPH_ALLOW_TEST_CWD=1 para forçar." >&2
    exit 5
fi

# AC1: detectar wrapper setsid (process group leader) em cadeia setsid → gsetsid → python3.
# `bash -c 'set -m'` foi REJEITADO durante revisão adversária (R2-3): set -m em shell
# não-interativo NÃO cria process group para subprocessos.
declare -a SETSID_CMD=()
if command -v setsid >/dev/null 2>&1; then
    SETSID_CMD=(setsid)
elif command -v gsetsid >/dev/null 2>&1; then
    SETSID_CMD=(gsetsid)
elif command -v python3 >/dev/null 2>&1; then
    # python3 os.setsid() faz a syscall correta; herda env e fds do shell pai.
    SETSID_CMD=(python3 -c 'import os, sys; os.setsid(); os.execvp(sys.argv[1], sys.argv[1:])')
else
    echo "ERRO: hang detection requer 'setsid' (coreutils), 'gsetsid' ou 'python3'." >&2
    echo "Instale via 'brew install coreutils' OU 'xcode-select --install'." >&2
    exit 4
fi

# Helper: lança o agente em novo process group, retorna PID via global $AGENT_PID.
# Usado pela hang detection para matar agente + MCP servers forkados via `kill -- -$PGID`.
launch_agent_pgrouped() {
    local cmd="$1"; shift
    local prompt="$1"
    local logfile="$2"
    case "$cmd" in
        claude)
            "${SETSID_CMD[@]}" claude --print --permission-mode bypassPermissions "$prompt" >"$logfile" 2>&1 &
            ;;
        codex)
            "${SETSID_CMD[@]}" codex exec --full-auto "$prompt" >"$logfile" 2>&1 &
            ;;
    esac
    AGENT_PID=$!
}

# Helper: aguarda agente com timeout; retorna 0 se completou natural, 1 se foi morto por hang.
# Sem polling-by-sleep convencional para evitar overhead — usa `kill -0` a cada 5s.
wait_with_timeout() {
    local pid="$1"
    local timeout="$2"
    local start_ts
    start_ts=$(date +%s)
    while kill -0 "$pid" 2>/dev/null; do
        local now
        now=$(date +%s)
        if [ $((now - start_ts)) -gt "$timeout" ]; then
            return 1
        fi
        sleep 5
    done
    wait "$pid" 2>/dev/null || true
    return 0
}

# Helper: mata o process group do agente (SIGTERM, sleep, SIGKILL).
kill_agent_pg() {
    local pid="$1"
    local pgid
    pgid=$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ')
    if [ -z "$pgid" ]; then
        # processo já morreu antes de chegarmos aqui
        return 0
    fi
    if [ "$pgid" != "$pid" ]; then
        echo "  AVISO: PID($pid) != PGID($pgid) — setsid pode ter falhado; matando só o PID." >&2
        kill -TERM "$pid" 2>/dev/null || true
        sleep 2
        kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null || true
    else
        kill -TERM -- "-$pgid" 2>/dev/null || true
        sleep 2
        kill -0 "$pid" 2>/dev/null && kill -KILL -- "-$pgid" 2>/dev/null || true
    fi
    wait "$pid" 2>/dev/null || true
}

# Papéis dos agentes (env vars) — permitem alternar sem editar o script.
#   PRIMARY_AGENT:  quem implementa cada story   (claude | codex)  default: claude
#   REVIEWER_AGENT: quem faz a revisão adversária (codex  | claude) default: codex
PRIMARY_AGENT="${PRIMARY_AGENT:-claude}"
REVIEWER_AGENT="${REVIEWER_AGENT:-codex}"

case "$PRIMARY_AGENT" in
    claude|codex) ;;
    *) echo "ERRO: PRIMARY_AGENT inválido: '$PRIMARY_AGENT' (use claude|codex)"; exit 1 ;;
esac
case "$REVIEWER_AGENT" in
    claude|codex) ;;
    *) echo "ERRO: REVIEWER_AGENT inválido: '$REVIEWER_AGENT' (use claude|codex)"; exit 1 ;;
esac

# shellcheck source=parse-verdict.sh
source "$SCRIPT_DIR/parse-verdict.sh"
# shellcheck source=detect-quota.sh
source "$SCRIPT_DIR/detect-quota.sh"

# Claude Sonnet atua como reviewer de fallback quando o Codex está
# indisponível (quota/rate-limit, binário ausente, falha persistente).
# Recebe: story_id, story_title. Imprime o output bruto do reviewer,
# que será interpretado por parse_verdict (mesma rubrica).
review_with_claude_sonnet() {
    local story_id="$1"
    local story_title="$2"
    local header footer rubric prompt

    read -r -d '' header <<HEADER || true
Você é revisor adversário de código no loop Ralph Adversarial.
Revise o commit HEAD — implementa a user story: ${story_id} - ${story_title}.

INVESTIGAÇÃO (rode antes de concluir):
- git show HEAD  (diff + commit message com ac_trace)
- Consulte prd.json para os acceptance criteria de ${story_id}
- Leia progress.txt para contexto de iterações anteriores

RUBRICA OBRIGATÓRIA (aplique linha a linha — não improvise):
---
HEADER

    read -r -d '' footer <<'FOOTER' || true
---

SAÍDA OBRIGATÓRIA:
Termine sua resposta com uma linha exatamente no formato:

## Verdict: MERGE

(ou BLOCK, ou REQUEST_CHANGES)

Antes do veredicto, liste apenas findings sólidos (P0/P1) com arquivo:linha
e modo de falha concreto. Silêncio é melhor que finding fraco.
NÃO elogie. NÃO resuma o diff.
FOOTER

    rubric=$(cat "$REVIEW_FILE")
    # printf com %s evita que shell reexpanda conteúdo da rubrica.
    prompt=$(printf '%s\n%s\n%s\n' "$header" "$rubric" "$footer")

    claude --model sonnet --print --permission-mode bypassPermissions "$prompt" 2>&1 \
        || printf '%s\n%s\n' '## Verdict: BLOCK' '(claude sonnet fallback exec failed)'
}

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

# Checa CLIs apenas quando o respectivo papel realmente precisa.
if [ "$PRIMARY_AGENT" = "claude" ] || [ "$REVIEWER_AGENT" = "claude" ]; then
    command -v claude >/dev/null 2>&1 || {
        echo "ERRO: Claude Code CLI não encontrado (PRIMARY/REVIEWER=claude requer)"; exit 1;
    }
fi

# CODEX_UNAVAILABLE continua sendo a flag que força o caminho de revisão Claude.
# Três gatilhos: (1) usuário escolheu REVIEWER_AGENT=claude, (2) codex não instalado,
# (3) quota/rate-limit detectado durante o loop.
CODEX_UNAVAILABLE=false
if [ "$REVIEWER_AGENT" = "claude" ]; then
    CODEX_UNAVAILABLE=true
fi
if [ "$PRIMARY_AGENT" = "codex" ] || [ "$REVIEWER_AGENT" = "codex" ]; then
    if ! command -v codex >/dev/null 2>&1; then
        if [ "$PRIMARY_AGENT" = "codex" ]; then
            echo "ERRO: PRIMARY_AGENT=codex mas Codex CLI não encontrado"; exit 1
        fi
        echo "AVISO: Codex CLI não encontrado — reviews usarão fallback Claude Sonnet."
        CODEX_UNAVAILABLE=true
    fi
fi

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
echo "Primary:    $PRIMARY_AGENT  (implementa)"
echo "Reviewer:   $REVIEWER_AGENT $([ "$CODEX_UNAVAILABLE" = true ] && [ "$REVIEWER_AGENT" = "codex" ] && echo '(→ fallback claude)')"
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

    # ── Fase A: Primary agent implementa ────────────────────

    echo ""
    echo "[A] $PRIMARY_AGENT — Implementando..."

    # IMPL_PROMPT.md é o template estável (sem interpolação shell). A story
    # corrente é anexada como bloco JSON sob "## Story atual" para o agente
    # extrair id/title/AC. Pré-condição arquitetural para Fase 2 (templates
    # cwd-agnósticos permitem reuso por múltiplos slots).
    STORY_BLOCK=$(jq -r --arg id "$STORY_ID" '.userStories[] | select(.id == $id)' prd.json)
    CLAUDE_PROMPT=$(printf '%s\n\n## Story atual\n%s\n' "$(cat "$IMPL_PROMPT_FILE")" "$STORY_BLOCK")

    # AC2: agente lançado em background, em novo process group via $SETSID_CMD.
    # AC5: capturar HEAD antes para race detection pós-kill.
    HEAD_BEFORE=$(git rev-parse HEAD 2>/dev/null || echo none)
    LOGFILE=$(mktemp -t ralph-iter.XXXXXX)

    launch_agent_pgrouped "$PRIMARY_AGENT" "$CLAUDE_PROMPT" "$LOGFILE"

    if wait_with_timeout "$AGENT_PID" "$TIMEOUT"; then
        # Agente saiu naturalmente.
        tail -20 "$LOGFILE" || true
        rm -f "$LOGFILE"
    else
        # AC4: timeout — matar process group inteiro (cobre MCP servers forkados).
        echo "  HANG: $PRIMARY_AGENT excedeu ${TIMEOUT}s sem terminar — matando process group."
        kill_agent_pg "$AGENT_PID"
        tail -20 "$LOGFILE" 2>/dev/null || true
        rm -f "$LOGFILE"

        # AC5: race detection — commit válido pode ter vazado no último segundo entre o
        # check de timeout e o kill. Se HEAD avançou e a mensagem contém $STORY_ID,
        # abortar ESCALATED e seguir para Fase B (review) como se fosse iteração normal.
        HEAD_AFTER=$(git rev-parse HEAD 2>/dev/null || echo none)
        LAST_MSG_AFTER_KILL=$(git log -1 --format=%s 2>/dev/null || echo "")
        if [ "$HEAD_AFTER" != "$HEAD_BEFORE" ] && [[ "$LAST_MSG_AFTER_KILL" == *"$STORY_ID"* ]]; then
            echo "  RACE: commit válido vazou no último segundo — seguindo fluxo normal."
            echo "$(date -Iseconds) | HANG_RACE_RESCUED | $STORY_ID | commit chegou após timeout" >> progress.txt
        else
            # AC6: working tree pode estar sujo (agente parou no meio de edits).
            # `git stash` preserva sem perda; nunca usar `reset --hard` aqui.
            if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
                git stash push -u -m "ralph-hang-${STORY_ID}-iter${ITERATION}" >/dev/null 2>&1 || true
                echo "  Working tree sujo após hang — git stash criado."
            fi
            # AC8: dump no formato existente.
            echo "$(date -Iseconds) | HANG | $STORY_ID | timeout ${TIMEOUT}s sem novo commit" >> progress.txt
            # AC7: política de retry alinhada com FALHA_COMMIT — incrementa retry; ESCALAR só quando
            # MAX_RETRIES_PER_STORY for atingido (caminho existente que checa CURRENT_RETRIES no topo do loop).
            set_retry_count "$STORY_ID" "$((CURRENT_RETRIES + 1))"
            continue
        fi
    fi

    # Verificar se houve commit
    LAST_COMMIT=$(git log -1 --format="%H" 2>/dev/null)
    LAST_MSG=$(git log -1 --format="%s" 2>/dev/null)

    if [[ "$LAST_MSG" != *"$STORY_ID"* ]]; then
        echo "  AVISO: $PRIMARY_AGENT não commitou com $STORY_ID no message."
        echo "$(date -Iseconds) | FALHA_COMMIT | $STORY_ID | $PRIMARY_AGENT não produziu commit válido" >> progress.txt
        set_retry_count "$STORY_ID" "$((CURRENT_RETRIES + 1))"
        continue
    fi

    echo "  Commit: $LAST_MSG"

    # ── Fase B: Revisão adversária (Codex ou fallback) ──────

    if [ "$CODEX_UNAVAILABLE" = true ]; then
        REVIEWER="claude-sonnet"
        echo ""
        if [ "$REVIEWER_AGENT" = "claude" ]; then
            echo "[B] Claude Sonnet — Revisando código..."
        else
            echo "[B] Claude Sonnet (fallback) — Revisando código..."
        fi
        REVIEW_RESULT=$(review_with_claude_sonnet "$STORY_ID" "$STORY_TITLE")
    else
        REVIEWER="codex"
        echo ""
        echo "[B] Codex — Revisando código..."

        # Codex 0.120+: "exec review --commit SHA --full-auto" não aceita PROMPT customizado.
        # Usamos o modo review padrão, que o Codex executa com sua rubrica interna.
        # A rubrica customizada CODE_REVIEW.md fica como guidance no repo (AGENTS.md pode referenciar).
        set +e
        REVIEW_RESULT=$(codex exec review --commit HEAD --full-auto 2>&1)
        CODEX_EXIT=$?
        set -e

        if is_codex_quota_error "$REVIEW_RESULT"; then
            echo "  ⚠  Codex: quota/rate-limit detectado — ativando fallback Claude Sonnet para esta e próximas iterações."
            echo "$(date -Iseconds) | CODEX_QUOTA | Fallback Claude Sonnet ativado durante $STORY_ID" >> progress.txt
            CODEX_UNAVAILABLE=true
            REVIEWER="claude-sonnet"
            REVIEW_RESULT=$(review_with_claude_sonnet "$STORY_ID" "$STORY_TITLE")
        elif [ $CODEX_EXIT -ne 0 ]; then
            REVIEW_RESULT=$(printf '%s\n%s\n' "$REVIEW_RESULT" '{"verdict":"BLOCK","error":"codex_exec_failed"}')
        fi
    fi

    echo "$REVIEW_RESULT" | tail -30

    # Salvar review (com sufixo do reviewer usado)
    mkdir -p .claude/research 2>/dev/null || true
    echo "$REVIEW_RESULT" > ".claude/research/review-${STORY_ID}-iter${ITERATION}-${REVIEWER}.txt" 2>/dev/null || true

    # ── Fase C: Interpretar veredicto ───────────────────────

    VERDICT=$(parse_verdict "$REVIEW_RESULT")

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
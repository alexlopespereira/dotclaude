#!/bin/bash
# Ralph Adversarial Loop — Claude Code implementa, Codex revisa
# Baseado no padrão Ralph (ghuntley.com/ralph, snarktank/ralph)
# Adaptado para revisão adversária com rubrica V2

set -e

# US-05 F5: arg parser. Aceita opcionalmente --parallel/--parallel=N antes do
# argumento posicional max_iterations (compat com chamadas existentes que só
# passam o número). N default vem de RALPH_PARALLEL_N (=4 quando ausente).
# --no-review: pula a fase de revisão adversária (usado por /full-cycle-simple).
PARALLEL_MODE=false
PARALLEL_N="${RALPH_PARALLEL_N:-4}"
SKIP_REVIEWER=false
POSITIONAL=()
while [ $# -gt 0 ]; do
    case "$1" in
        --parallel)    PARALLEL_MODE=true; shift ;;
        --parallel=*)  PARALLEL_MODE=true; PARALLEL_N="${1#*=}"; shift ;;
        --no-review)   SKIP_REVIEWER=true; shift ;;
        --) shift; while [ $# -gt 0 ]; do POSITIONAL+=("$1"); shift; done; break ;;
        *)             POSITIONAL+=("$1"); shift ;;
    esac
done
# Bash 3.2: expanding "${POSITIONAL[@]}" with empty array under set -e is
# safe, but the [@]:- guard would inject an empty arg. Branch instead.
if [ ${#POSITIONAL[@]} -gt 0 ]; then
    set -- "${POSITIONAL[@]}"
else
    set --
fi

MAX_ITERATIONS=${1:-10}
MAX_RETRIES_PER_STORY=2
ITERATION=0

# AC9: timeout para hang detection (default 45min); usuário pode override por env var.
TIMEOUT=${RALPH_HANG_TIMEOUT:-2700}

# US-02: stream-timeout retry. Detecta "API Error: Stream idle timeout" no
# log do agente primary; em modo dry-run (default) só registra candidato.
# Quando ativo, retry sem incrementar set_retry_count e budget separado.
RALPH_API_TIMEOUT_RETRY="${RALPH_API_TIMEOUT_RETRY:-0}"
MAX_API_TIMEOUT_RETRIES="${MAX_API_TIMEOUT_RETRIES:-3}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REVIEW_FILE="$SCRIPT_DIR/CODE_REVIEW.md"
IMPL_PROMPT_FILE="$SCRIPT_DIR/IMPL_PROMPT.md"

# US-05 F5: helpers compartilhados (parse_pool_from_pwd, preflight_slot,
# count_pool_slots, version_ge). Carregados sempre; só são exercidos no
# caminho --parallel, mas o source no topo evita estado split entre modos.
# shellcheck source=lib/dispatch.sh
source "$SCRIPT_DIR/lib/dispatch.sh"

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
#
# RALPH_AGENT_BIN (US-03 F3): se definido, substitui completamente o binário
# claude/codex por um drop-in (e.g., tests/mocks/fake-claude.sh). O mock recebe
# apenas o prompt como $1 (sem flags --print/--permission-mode/--full-auto).
launch_agent_pgrouped() {
    local cmd="$1"; shift
    local prompt="$1"
    local logfile="$2"

    if [ -n "${RALPH_AGENT_BIN:-}" ]; then
        "${SETSID_CMD[@]}" "$RALPH_AGENT_BIN" "$prompt" >"$logfile" 2>&1 &
        AGENT_PID=$!
        return
    fi

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
    # F8 (US-09): pipefail-safe. ps exits non-zero when $pid já morreu;
    # sem `|| true` no fim, set -euo pipefail em run_parallel aborta o
    # cleanup. Catalog ref: tests/fase1-exit-codes.md linha 122 classe (b).
    pgid=$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ' || true)
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

# US-05 F5: Bootstrap --parallel. Executa pool detection + pré-flight ANTES
# dos prereqs (jq, prd.json, claude/codex) para que falhas fora do pool (AC1)
# e pool < 2 slots (AC4) sejam reportadas com mensagens específicas, sem
# depender de prd.json estar presente. Execução real do paralelismo chega em
# US-06; aqui o run_parallel ainda chama run_serial.
#
# Capacidade de workers (AC3): documentada em commands/ralph-adversarial.md.
#   pool=2  → cap=1  worker
#   pool=3  → cap=2  workers
#   pool=5  → cap=4  workers (default RALPH_PARALLEL_N=4)
ORCH_NAME=""
ORCH_SLOT_NUM=""
REPO_NAME=""
POOL_BASE=""
TOTAL_SLOTS=0
WORKER_NAMES=""
declare -a WORKER_PATHS=()

if [ "$PARALLEL_MODE" = true ]; then
    if ! POOL_INFO=$(parse_pool_from_pwd "$PWD" 2>/dev/null); then
        echo "ERRO: --parallel requer cwd em ~/Projects/checkouts/<repo>-<N>" >&2
        echo "  cwd atual: $PWD" >&2
        echo "  Rode /checkout-init <repo-url> para provisionar o pool." >&2
        echo "" >&2
        echo "Uso: ralph-adversarial.sh [--parallel | --parallel=N] [max_iterations]" >&2
        exit 1
    fi
    REPO_NAME="${POOL_INFO% *}"
    ORCH_SLOT_NUM="${POOL_INFO##* }"
    POOL_BASE="$(dirname "$PWD")"
    TOTAL_SLOTS=$(count_pool_slots "$POOL_BASE" "$REPO_NAME")

    # AC4: rev2 R8 — pool=1 slot deve abortar com mensagem clara.
    if [ "$TOTAL_SLOTS" -lt 2 ]; then
        echo "ERRO: --parallel exige pool ≥ 2 slots; rode /checkout-init para provisionar" >&2
        echo "  Pool '$REPO_NAME' tem $TOTAL_SLOTS slot(s) em $POOL_BASE/" >&2
        exit 1
    fi

    ORCH_NAME="${REPO_NAME}-${ORCH_SLOT_NUM}"
    for i in $(seq 1 "$TOTAL_SLOTS"); do
        if [ "$i" != "$ORCH_SLOT_NUM" ]; then
            slot_path="$POOL_BASE/${REPO_NAME}-${i}"
            [ -d "$slot_path" ] || continue
            WORKER_PATHS+=("$slot_path")
            slot_name="${REPO_NAME}-${i}"
            if [ -z "$WORKER_NAMES" ]; then
                WORKER_NAMES="$slot_name"
            else
                WORKER_NAMES="${WORKER_NAMES}, ${slot_name}"
            fi
        fi
    done

    # AC6, AC7: pré-flight cada slot do pool (orquestrador + workers).
    # Reflog desativado no nível do repo OU git < 2.9 quebram a Camada A'.
    # Plano B follow-up: também garante que delta files ficam ignorados
    # em cada slot (.git/info/exclude) — defesa contra `git add .` amplo.
    for i in $(seq 1 "$TOTAL_SLOTS"); do
        slot_path="$POOL_BASE/${REPO_NAME}-${i}"
        [ -d "$slot_path" ] || continue
        if ! preflight_slot "$slot_path"; then
            exit 1
        fi
        ensure_slot_excludes_deltas "$slot_path"
    done

    # AC2 + AC5: documenta a decisão "orquestrador = slot de invocação" via output.
    echo "modo paralelo detectado"
    echo "orquestrador=$ORCH_NAME, workers=[$WORKER_NAMES]"
fi

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
build_codex_review_prompt() {
    local story_id="$1"
    local story_title="$2"
    local acs_filtered="${3:-}"
    local header footer rubric

    read -r -d '' header <<HEADER || true
Você é revisor adversário de código no loop Ralph Adversarial.
Revise o commit HEAD — implementa a user story: ${story_id} - ${story_title}.

ACCEPTANCE CRITERIA (já filtrados — Cat 3 [CAT3-MANUAL] removidos; revise apenas estes):
${acs_filtered}

INVESTIGAÇÃO (rode antes de concluir):
- git show HEAD  (diff + commit message com ac_trace)
- Leia progress.txt para contexto de iterações anteriores

NÃO modifique nenhum arquivo do worktree durante esta revisão.

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
    printf '%s\n%s\n%s\n' "$header" "$rubric" "$footer"
}

review_with_claude_sonnet() {
    local story_id="$1"
    local story_title="$2"
    local acs_filtered="${3:-}"
    local header footer rubric prompt

    read -r -d '' header <<HEADER || true
Você é revisor adversário de código no loop Ralph Adversarial.
Revise o commit HEAD — implementa a user story: ${story_id} - ${story_title}.

ACCEPTANCE CRITERIA (já filtrados — Cat 3 [CAT3-MANUAL] removidos; revise apenas estes):
${acs_filtered}

INVESTIGAÇÃO (rode antes de concluir):
- git show HEAD  (diff + commit message com ac_trace)
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

# Wrapper para codex prompted: stories trivia produzem prosa não-estruturada
# em "codex exec review --commit HEAD --full-auto". Forçando o prompt via
# "codex exec --full-auto" + rubrica + demanda de "## Verdict:" garantimos
# saída determinística que parse-verdict.sh reconhece.
review_with_codex_prompted() {
    local story_id="$1"
    local story_title="$2"
    local acs_filtered="${3:-}"
    local prompt
    prompt=$(build_codex_review_prompt "$story_id" "$story_title" "$acs_filtered")
    codex exec --full-auto "$prompt" 2>&1 \
        || printf '%s\n%s\n' '## Verdict: BLOCK' '(codex exec failed)'
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
# RALPH_AGENT_BIN/RALPH_REVIEWER_BIN (US-03 F3) suprimem o check porque o
# binário real claude/codex nunca é invocado.
NEEDS_CLAUDE=false
[ "$PRIMARY_AGENT"  = "claude" ] && [ -z "${RALPH_AGENT_BIN:-}" ]    && NEEDS_CLAUDE=true
[ "$REVIEWER_AGENT" = "claude" ] && [ -z "${RALPH_REVIEWER_BIN:-}" ] && NEEDS_CLAUDE=true
if [ "$NEEDS_CLAUDE" = "true" ]; then
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
NEEDS_CODEX=false
[ "$PRIMARY_AGENT"  = "codex" ] && [ -z "${RALPH_AGENT_BIN:-}" ]    && NEEDS_CODEX=true
[ "$REVIEWER_AGENT" = "codex" ] && [ -z "${RALPH_REVIEWER_BIN:-}" ] && [ "$SKIP_REVIEWER" != "true" ] && NEEDS_CODEX=true
if [ "$NEEDS_CODEX" = "true" ]; then
    if ! command -v codex >/dev/null 2>&1; then
        if [ "$PRIMARY_AGENT" = "codex" ] && [ -z "${RALPH_AGENT_BIN:-}" ]; then
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
if [ "$SKIP_REVIEWER" = "true" ]; then
    echo "Reviewer:   SKIPPED (--no-review)"
else
    echo "Reviewer:   $REVIEWER_AGENT $([ "$CODEX_UNAVAILABLE" = true ] && [ "$REVIEWER_AGENT" = "codex" ] && echo '(→ fallback claude)')"
fi
echo "=========================================="

# ─── Retry tracker ──────────────────────────────────────────
# Bash 3.2 compat: usar arquivo em vez de array associativo

# F8 (US-09 lint): mktemp_safe over `mktemp -t` (8 X's, TMPDIR-safe fallback).
RETRY_FILE="$(mktemp_safe file ralph-retry)"
# US-02: budget separado para stream-timeout (não consome MAX_RETRIES_PER_STORY).
API_TIMEOUT_FILE="$(mktemp_safe file ralph-api-timeout)"
trap 'rm -f "$RETRY_FILE" "$API_TIMEOUT_FILE"' EXIT

get_retry_count() {
    local story_id="$1"
    local count
    # F8 (US-09): pipefail-safe. grep no-match exits 1; sem `|| true` no fim
    # do pipeline, set -euo pipefail em run_parallel aborta handle_failed_worker.
    # Catalog ref: tests/fase1-exit-codes.md linha 353 classe (b).
    count=$(grep "^${story_id}:" "$RETRY_FILE" 2>/dev/null | tail -1 | cut -d: -f2 || true)
    echo "${count:-0}"
}

set_retry_count() {
    local story_id="$1"
    local count="$2"
    grep -v "^${story_id}:" "$RETRY_FILE" > "${RETRY_FILE}.tmp" 2>/dev/null || true
    echo "${story_id}:${count}" >> "${RETRY_FILE}.tmp"
    mv "${RETRY_FILE}.tmp" "$RETRY_FILE"
}

# US-02: contador independente para API_TIMEOUT (budget MAX_API_TIMEOUT_RETRIES).
get_api_timeout_count() {
    local story_id="$1"
    local count
    count=$(grep "^${story_id}:" "$API_TIMEOUT_FILE" 2>/dev/null | tail -1 | cut -d: -f2 || true)
    echo "${count:-0}"
}

set_api_timeout_count() {
    local story_id="$1"
    local count="$2"
    grep -v "^${story_id}:" "$API_TIMEOUT_FILE" > "${API_TIMEOUT_FILE}.tmp" 2>/dev/null || true
    echo "${story_id}:${count}" >> "${API_TIMEOUT_FILE}.tmp"
    mv "${API_TIMEOUT_FILE}.tmp" "$API_TIMEOUT_FILE"
}

# ─── Loop Principal ─────────────────────────────────────────
# US-05 F5: o loop está em run_serial(); run_parallel() é um skeleton que
# delega ao serial até US-06 implementar o dispatch real para os workers.

run_serial() {
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
    #
    # Filtro [CAT3-MANUAL]: ACs prefixados com marker (regex ancorada
    # ^AC<N>(.[a-z])?:\s*\[CAT3-MANUAL\], case-insensitive) são humano-validated
    # pós-merge e ficam invisíveis para Claude (implementer) E Codex (reviewer).
    # Filtro único aqui — STORY_BLOCK reutilizado para o prompt do reviewer via
    # STORY_ACS_FILTERED. Convenção documentada em skills/prd/SKILL.md.
    STORY_BLOCK=$(jq -r --arg id "$STORY_ID" '.userStories[] | select(.id == $id) | .acceptanceCriteria |= map(select(test("^AC[0-9]+(\\.[a-z])?:\\s*\\[CAT3-MANUAL\\]"; "i") | not))' prd.json)
    STORY_ACS_FILTERED=$(jq -r '.acceptanceCriteria[]' <<<"$STORY_BLOCK")
    CLAUDE_PROMPT=$(printf '%s\n\n## Story atual\n%s\n' "$(cat "$IMPL_PROMPT_FILE")" "$STORY_BLOCK")

    # AC2: agente lançado em background, em novo process group via $SETSID_CMD.
    # AC5: capturar HEAD antes para race detection pós-kill.
    HEAD_BEFORE=$(git rev-parse HEAD 2>/dev/null || echo none)
    # F8 (US-09 lint): mktemp_safe over `mktemp -t` (8 X's, TMPDIR-safe).
    LOGFILE=$(mktemp_safe file ralph-iter)

    launch_agent_pgrouped "$PRIMARY_AGENT" "$CLAUDE_PROMPT" "$LOGFILE"

    # US-02: regex restrita 'API Error: Stream idle timeout' (case-insensitive).
    # NÃO inclui "partial response received" nem '"verdict": "partial"' (false-
    # positives da rubrica adversária — ver tests/test_stream_timeout_detect.sh).
    API_TIMEOUT_DETECTED=false

    if wait_with_timeout "$AGENT_PID" "$TIMEOUT"; then
        # Agente saiu naturalmente.
        tail -20 "$LOGFILE" || true
        if grep -qiE 'API Error:[[:space:]]*Stream idle timeout' "$LOGFILE" 2>/dev/null; then
            API_TIMEOUT_DETECTED=true
        fi
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
        # US-02: stream-timeout detection antes da FALHA_COMMIT clássica.
        # Dry-run (default) só registra candidato e segue para FALHA_COMMIT;
        # modo ativo retry sem bumpar set_retry_count, com budget próprio.
        if [ "$API_TIMEOUT_DETECTED" = true ]; then
            if [ "$RALPH_API_TIMEOUT_RETRY" = "1" ]; then
                CURRENT_API_TIMEOUTS=$(get_api_timeout_count "$STORY_ID")
                if [ "$CURRENT_API_TIMEOUTS" -ge "$MAX_API_TIMEOUT_RETRIES" ]; then
                    echo "  API_BUDGET_EXHAUSTED: $STORY_ID atingiu $MAX_API_TIMEOUT_RETRIES timeouts. Escalando (separado de ESCALAÇÃO normal)."
                    echo "$(date -Iseconds) | API_BUDGET_EXHAUSTED | $STORY_ID | budget $MAX_API_TIMEOUT_RETRIES esgotado" >> progress.txt
                    jq --arg id "$STORY_ID" '(.userStories[] | select(.id == $id)).passes = "ESCALATED_API_TIMEOUT"' prd.json > prd.tmp && mv prd.tmp prd.json
                    continue
                fi
                NEXT_API_TIMEOUTS=$((CURRENT_API_TIMEOUTS + 1))
                echo "  API_TIMEOUT: $STORY_ID — retry $NEXT_API_TIMEOUTS/$MAX_API_TIMEOUT_RETRIES (set_retry_count preservado em $CURRENT_RETRIES)"
                echo "$(date -Iseconds) | API_TIMEOUT | $STORY_ID | retry $NEXT_API_TIMEOUTS/$MAX_API_TIMEOUT_RETRIES (set_retry_count preserved)" >> progress.txt
                set_api_timeout_count "$STORY_ID" "$NEXT_API_TIMEOUTS"
                continue
            else
                # Dry-run: log candidato e cai no FALHA_COMMIT (comportamento original).
                echo "  API_TIMEOUT_CANDIDATE: regex match em log; RALPH_API_TIMEOUT_RETRY=0 (dry-run) — tratando como FALHA_COMMIT."
                echo "$(date -Iseconds) | API_TIMEOUT_CANDIDATE | $STORY_ID | dry-run: regex match (RALPH_API_TIMEOUT_RETRY=0)" >> progress.txt
            fi
        fi
        echo "  AVISO: $PRIMARY_AGENT não commitou com $STORY_ID no message."
        echo "$(date -Iseconds) | FALHA_COMMIT | $STORY_ID | $PRIMARY_AGENT não produziu commit válido" >> progress.txt
        set_retry_count "$STORY_ID" "$((CURRENT_RETRIES + 1))"
        continue
    fi

    echo "  Commit: $LAST_MSG"

    # ── Fase B: Revisão adversária (Codex ou fallback) ──────

    if [ "$SKIP_REVIEWER" = "true" ]; then
        REVIEWER="skipped"
        REVIEW_RESULT=$(printf '%s\n%s\n' '(reviewer skipped via --no-review)' '## Verdict: MERGE')
        echo ""
        echo "[B] Reviewer SKIPPED — auto-MERGE (--no-review)"
        echo "$(date -Iseconds) | REVIEW_SKIPPED | $STORY_ID | --no-review ativo" >> progress.txt
    elif [ -n "${RALPH_REVIEWER_BIN:-}" ]; then
        # US-03 F3: substituto programável para o reviewer (e.g.,
        # tests/mocks/fake-codex.sh). Mock retorna texto contendo
        # "## Verdict: <X>" que parse_verdict reconhece.
        REVIEWER="mock-reviewer"
        echo ""
        echo "[B] $RALPH_REVIEWER_BIN — Revisando código (mock)..."
        set +e
        REVIEW_RESULT=$("$RALPH_REVIEWER_BIN" "review HEAD for $STORY_ID - $STORY_TITLE" 2>&1)
        REVIEWER_EXIT=$?
        set -e
        if [ $REVIEWER_EXIT -ne 0 ]; then
            REVIEW_RESULT=$(printf '%s\n%s\n' "$REVIEW_RESULT" '## Verdict: BLOCK')
        fi
    elif [ "$CODEX_UNAVAILABLE" = true ]; then
        REVIEWER="claude-sonnet"
        echo ""
        if [ "$REVIEWER_AGENT" = "claude" ]; then
            echo "[B] Claude Sonnet — Revisando código..."
        else
            echo "[B] Claude Sonnet (fallback) — Revisando código..."
        fi
        REVIEW_RESULT=$(review_with_claude_sonnet "$STORY_ID" "$STORY_TITLE" "$STORY_ACS_FILTERED")
    else
        REVIEWER="codex"
        echo ""
        echo "[B] Codex — Revisando código..."

        # Codex 0.124 review-mode emite prosa não-estruturada (sem "Verdict:" line).
        # Forçamos prompt custom via "codex exec --full-auto" para garantir
        # saída determinística (## Verdict: ...) reconhecida por parse-verdict.sh.
        set +e
        REVIEW_RESULT=$(review_with_codex_prompted "$STORY_ID" "$STORY_TITLE" "$STORY_ACS_FILTERED")
        CODEX_EXIT=$?
        set -e

        if is_codex_quota_error "$REVIEW_RESULT"; then
            echo "  ⚠  Codex: quota/rate-limit detectado — ativando fallback Claude Sonnet para esta e próximas iterações."
            echo "$(date -Iseconds) | CODEX_QUOTA | Fallback Claude Sonnet ativado durante $STORY_ID" >> progress.txt
            CODEX_UNAVAILABLE=true
            REVIEWER="claude-sonnet"
            REVIEW_RESULT=$(review_with_claude_sonnet "$STORY_ID" "$STORY_TITLE" "$STORY_ACS_FILTERED")
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
            git add prd.json 2>/dev/null || true  # tolera prd.json em .gitignore (dotclaude, etc.)
            git commit -m "[$STORY_ID] Marcada como passes:true após review" --allow-empty
            set_retry_count "$STORY_ID" 0
            ;;
        BLOCK|REQUEST_CHANGES)
            echo "  Story $STORY_ID REJEITADA — feedback salvo em progress.txt"
            # Extrai evidence dos findings reais. Path preferido: jq sobre JSON
            # estruturado (Codex <0.120). Fallback: regex sobre markdown.
            # Em AMBOS aplica filtro contra o exemplo didático da rubrica
            # (CODE_REVIEW.md:56 — "user_id concatenado em SQL sem parâmetro")
            # que o Codex frequentemente regurgita literalmente, tanto na
            # array findings JSON quanto citado em prosa. Sem o filtro,
            # poluía progress.txt em todas iterações com finding inexistente.
            # Coleta newline-separated (NÃO pipe-concat) para emit_progress_event
            # preservar array nativo em progress.jsonl. O concat com '|' acontece
            # em emit_progress_event apenas no path progress.txt (compat byte-a-byte).
            EVIDENCES_NL=$(echo "$REVIEW_RESULT" \
                | jq -r '.findings[]?.evidence // empty' 2>/dev/null \
                | grep -v 'user_id concatenado em SQL' \
                | head -3)
            if [ -z "$EVIDENCES_NL" ]; then
                EVIDENCES_NL=$(echo "$REVIEW_RESULT" \
                    | grep -o '"evidence":[^,]*' \
                    | grep -v 'user_id concatenado em SQL' \
                    | head -3)
            fi
            emit_progress_event "REVIEW_$VERDICT" "$STORY_ID" "$VERDICT" "$EVIDENCES_NL"
            set_retry_count "$STORY_ID" "$((CURRENT_RETRIES + 1))"
            ;;
        *)
            echo "  Veredicto não identificado — tratando como REQUEST_CHANGES"
            emit_progress_event "REVIEW_UNKNOWN" "$STORY_ID" "UNKNOWN" "Veredicto não parseado"
            set_retry_count "$STORY_ID" "$((CURRENT_RETRIES + 1))"
            ;;
    esac
done

echo ""
echo "=========================================="
echo "LOOP ENCERRADO — max iterações atingido"
echo "Stories pendentes: $(jq '[.userStories[] | select(.passes == false)] | length' prd.json)"
echo "=========================================="
}

# US-06 F6: dispatcher real.
#
# Estado:
#   PARALLEL_WORKERS_FILE     workers.txt (slot:pid:story_id:started_at)
#   PARALLEL_LOG_FILE         optional sink for log_event tee (set if env set)
#   PARALLEL_CLEANUP_DONE     idempotency guard for the EXIT/INT/TERM trap
#
# Env tunables (also documented in commands/ralph-adversarial.md):
#   RALPH_HANG_TIMEOUT   seconds before a worker is considered hung (default 2700)
#   RALPH_POLL_INTERVAL  seconds between dispatch ticks (default 5)
#   RALPH_MAX_TICKS      safety net loop bound (default 1000 → ~83min @ 5s)
#   RALPH_WORKERS_FILE   override workers.txt path so tests can poll it
#
# Each tick: poll_workers (handle finished/hung) → check pending → dispatch.
# Loop exits when no pending stories OR no active workers + nothing dispatchable.
run_parallel() {
    set -euo pipefail
    if [ -n "${RALPH_WORKERS_FILE:-}" ]; then
        PARALLEL_WORKERS_FILE="$RALPH_WORKERS_FILE"
        : > "$PARALLEL_WORKERS_FILE"
    else
        PARALLEL_WORKERS_FILE=$(mktemp_safe file ralph-workers)
    fi

    # US-07: review queue + single-active review state. Tests can override
    # both paths via env so the asserter watches the same files the
    # orchestrator writes.
    if [ -n "${RALPH_REVIEW_QUEUE_FILE:-}" ]; then
        PARALLEL_REVIEW_QUEUE="$RALPH_REVIEW_QUEUE_FILE"
    else
        PARALLEL_REVIEW_QUEUE=$(mktemp_safe file ralph-revq)
    fi
    : > "$PARALLEL_REVIEW_QUEUE"

    if [ -n "${RALPH_REVIEW_STATE_FILE:-}" ]; then
        PARALLEL_REVIEW_STATE="$RALPH_REVIEW_STATE_FILE"
    else
        PARALLEL_REVIEW_STATE=$(mktemp_safe file ralph-revs)
    fi
    : > "$PARALLEL_REVIEW_STATE"

    local hang_timeout="${RALPH_HANG_TIMEOUT:-2700}"
    local review_timeout="${RALPH_REVIEW_TIMEOUT:-600}"
    local poll_interval="${RALPH_POLL_INTERVAL:-5}"
    local max_ticks="${RALPH_MAX_TICKS:-1000}"

    PARALLEL_CLEANUP_DONE=0
    # Existing EXIT trap (RETRY_FILE rm) is replaced by parallel_cleanup which
    # rm's both. INT/TERM use a wrapper that exits 130/143 after cleanup so
    # the orchestrator does not silently swallow user Ctrl-C (AC3/AC4) or a
    # `kill <pid>` from a wrapper script.
    #
    # NOTE: a non-interactive bash launched in the background inherits SIGINT
    # set to SIG_IGN from its parent and `trap '...' INT` cannot override
    # that. In production the user invokes ralph-adversarial.sh in the
    # foreground, where SIGINT (Ctrl-C) is delivered normally and the trap
    # fires. In tests we send SIGTERM (same handler body) to exercise the
    # same code path. See AGENTS.md "Parallel trap" gotcha.
    trap parallel_cleanup EXIT
    trap 'log_event "TRAP_INT"  "" "received SIGINT — running cleanup";  parallel_cleanup; exit 130' INT
    trap 'log_event "TRAP_TERM" "" "received SIGTERM — running cleanup"; parallel_cleanup; exit 143' TERM

    log_event "PARALLEL_START" "" "orch=$ORCH_NAME workers=[$WORKER_NAMES] cap=$PARALLEL_N w_timeout=${hang_timeout}s r_timeout=${review_timeout}s poll=${poll_interval}s"

    local tick=0
    while [ "$tick" -lt "$max_ticks" ]; do
        tick=$((tick + 1))

        # AC ordering (US-07 description): poll_workers → poll_review →
        # dispatch_workers. Worker-finished events enqueue reviews; the
        # review drainer picks them up next; only then do we backfill
        # dispatch slots.
        poll_workers_tick "$PARALLEL_WORKERS_FILE" "$hang_timeout"
        poll_review_tick  "$PARALLEL_REVIEW_QUEUE" "$PARALLEL_REVIEW_STATE" "$review_timeout"

        local pending
        pending=$(jq '[.userStories[] | select(.passes == false)] | length' prd.json)
        if [ "$pending" -eq 0 ]; then
            log_event "ALL_DONE" "" "all stories settled (tick=$tick)"
            break
        fi

        local in_flight active queued review_active
        in_flight=$(collect_in_flight \
            "$PARALLEL_WORKERS_FILE" "$PARALLEL_REVIEW_QUEUE" "$PARALLEL_REVIEW_STATE")
        active=$(awk 'END{print NR}' "$PARALLEL_WORKERS_FILE" 2>/dev/null)
        [ -z "$active" ] && active=0
        queued=$(awk 'END{print NR}' "$PARALLEL_REVIEW_QUEUE" 2>/dev/null)
        [ -z "$queued" ] && queued=0
        review_active=0
        [ -s "$PARALLEL_REVIEW_STATE" ] && review_active=1

        # Stalemate: no workers, no queued/active review, no dispatchable
        # story. Stories stuck behind ESCALATED deps stay escalated.
        local nxt
        nxt=$(next_dispatchable_excluding prd.json "$in_flight")
        if [ "$active" -eq 0 ] && [ "$queued" -eq 0 ] && [ "$review_active" -eq 0 ] && [ -z "$nxt" ]; then
            log_event "STALEMATE" "" "no active workers, no pending review, no dispatchable stories (tick=$tick)"
            break
        fi

        dispatch_workers_tick "$PARALLEL_WORKERS_FILE" "$in_flight"

        sleep "$poll_interval"
    done

    log_event "PARALLEL_END" "" "tick=$tick"
}

# parallel_cleanup — idempotent kill-all + tmpfile rm. Called from EXIT trap
# AND the INT/TERM wrapper; the guard ensures we do not double-kill.
parallel_cleanup() {
    [ "${PARALLEL_CLEANUP_DONE:-0}" -eq 1 ] && return 0
    PARALLEL_CLEANUP_DONE=1
    if [ -n "${PARALLEL_WORKERS_FILE:-}" ] && [ -f "$PARALLEL_WORKERS_FILE" ]; then
        local slot pid story_id started_at
        while IFS=: read -r slot pid story_id started_at; do
            [ -z "$pid" ] && continue
            if kill -0 "$pid" 2>/dev/null; then
                log_event "CLEANUP_KILL" "$story_id" "slot=$slot pid=$pid"
                kill_agent_pg "$pid"
            fi
        done < "$PARALLEL_WORKERS_FILE"
        rm -f "$PARALLEL_WORKERS_FILE"
    fi

    # US-07: an in-flight review must be killed too — its PG owns codex +
    # any MCP children. Logfile + porcelain snapshot are best-effort cleaned.
    if [ -n "${PARALLEL_REVIEW_STATE:-}" ] && [ -f "$PARALLEL_REVIEW_STATE" ]; then
        local r_active r_pid r_slot r_story r_start r_logfile
        r_active=$(read_review_state "$PARALLEL_REVIEW_STATE")
        if [ -n "$r_active" ]; then
            IFS=: read -r r_pid r_slot r_story r_start r_logfile <<< "$r_active"
            if [ -n "$r_pid" ] && kill -0 "$r_pid" 2>/dev/null; then
                log_event "CLEANUP_KILL_REVIEW" "$r_story" "slot=$r_slot pid=$r_pid"
                kill_agent_pg "$r_pid"
            fi
            [ -n "$r_logfile" ] && rm -f "$r_logfile" "${r_logfile}.porcelain.before"
        fi
        rm -f "$PARALLEL_REVIEW_STATE"
    fi
    [ -n "${PARALLEL_REVIEW_QUEUE:-}" ] && rm -f "$PARALLEL_REVIEW_QUEUE"

    rm -f "${RETRY_FILE:-/dev/null}"
}

# poll_workers_tick — walk workers.txt; for each row decide alive/hung/done.
# Done rows trigger handle_finished_worker; hung rows are killed and bumped
# via handle_failed_worker(HANG). Alive rows are preserved.
poll_workers_tick() {
    local workers_file="$1"
    local hang_timeout="$2"
    [ -s "$workers_file" ] || return 0

    local now
    now=$(date +%s)
    local tmp
    tmp=$(mktemp_safe file ralph-wk-poll)
    : > "$tmp"

    local slot pid story_id started_at
    while IFS=: read -r slot pid story_id started_at; do
        [ -z "$pid" ] && continue
        if kill -0 "$pid" 2>/dev/null; then
            local elapsed=$((now - started_at))
            if [ "$elapsed" -ge "$hang_timeout" ]; then
                log_event "HANG" "$story_id" "slot=$slot pid=$pid elapsed=${elapsed}s timeout=${hang_timeout}s"
                kill_agent_pg "$pid"
                handle_failed_worker "$story_id" "HANG"
            else
                printf '%s:%s:%s:%s\n' "$slot" "$pid" "$story_id" "$started_at" >> "$tmp"
            fi
        else
            wait "$pid" 2>/dev/null || true
            handle_finished_worker "$slot" "$pid" "$story_id"
        fi
    done < "$workers_file"

    mv -f "$tmp" "$workers_file"
}

# handle_finished_worker — slot returned. Verify commit landed, then enqueue
# the review (US-07). The actual review verdict is applied by poll_review_tick
# after the drainer runs codex serially and reads the verdict from its log.
# poll_workers_tick has already rebuilt workers.txt without this row, so the
# slot is now free for the dispatcher (AC3).
handle_finished_worker() {
    local slot_basename="$1" pid="$2" story_id="$3"
    local slot_path="$POOL_BASE/${slot_basename}"

    local head_msg
    head_msg=$(git -C "$slot_path" log -1 --format=%s 2>/dev/null || echo "")

    if [[ "$head_msg" != *"$story_id"* ]]; then
        log_event "FALHA_COMMIT" "$story_id" "slot=$slot_basename pid=$pid no commit produced"
        handle_failed_worker "$story_id" "FALHA_COMMIT"
        return
    fi

    log_event "COMMIT" "$story_id" "slot=$slot_basename pid=$pid msg=$head_msg"

    # US-11 F10: capture worker's commit SHA into orch's local ref
    # `refs/ralph/<story>` BEFORE the slot can be reused for a sibling
    # story. Without this, `merge_and_push_story` later would fetch the
    # slot's current HEAD — which may have advanced — and pull in a
    # contaminating commit, causing AC4 strays. Best-effort: failure here
    # leaves the ref unset and `finalize_review` falls back to fetching
    # worker HEAD (US-09 behaviour).
    local orch_slot="$POOL_BASE/$ORCH_NAME"
    git -C "$orch_slot" fetch "$slot_path" "+HEAD:refs/ralph/$story_id" \
        >/dev/null 2>&1 || true

    # Plano B follow-up: capture untracked delta files from worker WT
    # into orch's stash dir BEFORE the slot is recycled. integrate_delta_files
    # will hydrate from the stash at MERGE time. This keeps the worker's
    # commit (and thus the reviewer's view) free of framework artifacts.
    stash_worker_deltas "$slot_path" "$orch_slot" "$story_id"

    local committed_at
    committed_at=$(date +%s)
    if [ "${SKIP_REVIEWER:-false}" = "true" ]; then
        log_event "REVIEW_SKIPPED" "$story_id" "slot=$slot_basename — auto-MERGE via --no-review"
        finalize_review "$slot_basename" "$story_id" "MERGE" "review-skipped" ""
    else
        enqueue_review "$PARALLEL_REVIEW_QUEUE" "$slot_basename" "$story_id" "$committed_at"
        log_event "REVIEW_ENQUEUE" "$story_id" "slot=$slot_basename"
    fi
}

# poll_review_tick — drainer for review-queue.txt with single-active
# enforcement (AC2). Each tick either advances or finalizes the active
# review, then dequeues the next FIFO entry when state is clear.
poll_review_tick() {
    local queue_file="$1" state_file="$2" timeout="$3"

    local active
    active=$(read_review_state "$state_file")

    if [ -n "$active" ]; then
        local r_pid r_slot r_story r_start r_logfile
        IFS=: read -r r_pid r_slot r_story r_start r_logfile <<< "$active"

        if kill -0 "$r_pid" 2>/dev/null; then
            local now elapsed
            now=$(date +%s)
            elapsed=$((now - r_start))
            if [ "$elapsed" -ge "$timeout" ]; then
                # AC4 hang path: kill PG, force BLOCK, free state so the
                # next queue entry can dispatch on this same tick.
                log_event "REVIEW_HANG" "$r_story" "slot=$r_slot pid=$r_pid elapsed=${elapsed}s timeout=${timeout}s"
                kill_agent_pg "$r_pid"
                finalize_review "$r_slot" "$r_story" "BLOCK" "REVIEW_HANG" "$r_logfile"
                clear_review_state "$state_file"
                # fall through to the dequeue branch below
            else
                # Active review still within timeout — leave it running.
                return 0
            fi
        else
            # Process exited on its own; reap and parse the verdict.
            wait "$r_pid" 2>/dev/null || true
            local review_text verdict
            review_text=$(cat "$r_logfile" 2>/dev/null || echo "")
            verdict=$(parse_verdict "$review_text")
            finalize_review "$r_slot" "$r_story" "$verdict" "review-completed" "$r_logfile"
            clear_review_state "$state_file"
            # fall through to the dequeue branch below
        fi
    fi

    # State is clear (initial or just-cleared) — dequeue next FIFO entry.
    if [ -s "$queue_file" ]; then
        local head_line q_slot q_story q_ts
        head_line=$(pop_review_queue "$queue_file") || return 0
        IFS=: read -r q_slot q_story q_ts <<< "$head_line"
        launch_review "$q_slot" "$q_story" "$state_file"
    fi
}

# launch_review — spawn reviewer in a DEDICATED git worktree pinned to the
# story's per-story ref (refs/ralph/<story>). Isolation rationale (Plano B):
#   1. Worker slots get reused for next dispatch the moment a worker commits;
#      reviewer reading "HEAD" later saw the wrong commit (slot-reuse race
#      observed in v5).
#   2. Codex 0.124 with workspace-write sandbox writes inside the cwd even
#      with explicit "do not modify" instruction; in worker slots that
#      contaminates real work.
# Dedicated WT solves both: pinned commit, isolated cwd. Removed in finalize.
launch_review() {
    local slot_basename="$1" story_id="$2" state_file="$3"
    local orch_slot="$POOL_BASE/$ORCH_NAME"
    local review_wt="$POOL_BASE/.ralph-review-${story_id}"

    local logfile
    logfile=$(mktemp_safe file ralph-revlog) || return 1

    # Pin SHA via per-story ref captured at COMMIT time. Fallback: fetch
    # worker slot HEAD into the ref now (best-effort) so the worktree add
    # below still has a reachable target.
    local sha=""
    if git -C "$orch_slot" rev-parse --verify -q "refs/ralph/$story_id" >/dev/null 2>&1; then
        sha=$(git -C "$orch_slot" rev-parse "refs/ralph/$story_id")
    else
        local worker_slot="$POOL_BASE/${slot_basename}"
        sha=$(git -C "$worker_slot" rev-parse HEAD 2>/dev/null || echo "")
        if [ -n "$sha" ]; then
            git -C "$orch_slot" fetch "$worker_slot" "+${sha}:refs/ralph/$story_id" >/dev/null 2>&1 || true
        fi
    fi
    if [ -z "$sha" ]; then
        log_event "REVIEW_LAUNCH_FAILED" "$story_id" "slot=$slot_basename — no reachable SHA"
        clear_review_state "$state_file"
        return 1
    fi

    # Clean any stale review WT (crashed prior run) before re-creating.
    if [ -d "$review_wt" ]; then
        git -C "$orch_slot" worktree remove --force "$review_wt" 2>/dev/null || true
        rm -rf "$review_wt" 2>/dev/null || true
    fi
    git -C "$orch_slot" worktree prune >/dev/null 2>&1 || true

    if ! git -C "$orch_slot" worktree add --detach "$review_wt" "$sha" >/dev/null 2>&1; then
        log_event "REVIEW_LAUNCH_FAILED" "$story_id" "slot=$slot_basename — worktree add failed sha=$sha"
        clear_review_state "$state_file"
        return 1
    fi

    local prompt="review HEAD for $story_id"
    if [ -n "${RALPH_REVIEWER_BIN:-}" ]; then
        ( cd "$review_wt" && exec "${SETSID_CMD[@]}" "$RALPH_REVIEWER_BIN" "$prompt" >"$logfile" 2>&1 ) &
    else
        # Custom prompt forces "## Verdict:" line; runs in dedicated WT.
        local story_title=""
        story_title=$(jq -r --arg id "$story_id" '.userStories[] | select(.id == $id) | .title // ""' "$orch_slot/prd.json" 2>/dev/null)
        # Mesma sintaxe do filter [CAT3-MANUAL] do path sequencial (linha ~495).
        # Mantém o reviewer paralelo cego para ACs humano-validated pós-merge.
        local acs_filtered=""
        acs_filtered=$(jq -r --arg id "$story_id" '.userStories[] | select(.id == $id) | .acceptanceCriteria | map(select(test("^AC[0-9]+(\\.[a-z])?:\\s*\\[CAT3-MANUAL\\]"; "i") | not)) | .[]' "$orch_slot/prd.json" 2>/dev/null)
        local codex_prompt
        codex_prompt=$(build_codex_review_prompt "$story_id" "$story_title" "$acs_filtered")
        ( cd "$review_wt" && exec "${SETSID_CMD[@]}" codex exec --full-auto "$codex_prompt" >"$logfile" 2>&1 ) &
    fi
    local pid=$!
    local started_at
    started_at=$(date +%s)
    write_review_state "$state_file" "$pid" "$slot_basename" "$story_id" "$started_at" "$logfile"
    log_event "REVIEW_DISPATCH" "$story_id" "slot=$slot_basename pid=$pid wt=$review_wt logfile=$logfile"
}

# finalize_review — apply the verdict to prd.json and bookkeeping. With
# the Plano B dedicated review worktree (launch_review), the legacy
# REVIEW_DIRTY_WORKTREE BLOCK override is dropped: Codex writes are isolated
# in $POOL_BASE/.ralph-review-<story> which is removed at the end of this
# function regardless of verdict. Worker slots are no longer affected.
finalize_review() {
    local slot_basename="$1" story_id="$2" verdict="$3" reason="$4" logfile="$5"
    local slot_path="$POOL_BASE/${slot_basename}"
    local orch_slot="$POOL_BASE/$ORCH_NAME"
    local review_wt="$POOL_BASE/.ralph-review-${story_id}"

    if [ -n "$logfile" ] && [ -f "$logfile" ]; then
        local research_dir="$orch_slot/.claude/research"
        mkdir -p "$research_dir" 2>/dev/null || true
        local retry_n
        retry_n=$(get_retry_count "$story_id" 2>/dev/null || echo 0)
        cp -f "$logfile" "$research_dir/review-${story_id}-iter${retry_n}-codex.txt" 2>/dev/null || true
    fi

    case "$verdict" in
        MERGE)
            # US-11 F10 wiring: when the orchestrator slot has an `origin`
            # remote, run merge_and_push_story to integrate the worker's
            # commits into orch's main + push to origin (and fold delta files
            # via integrate_delta_files). Legacy test setups (US-06/US-07
            # mk_pool with no shared origin) skip this path and keep the
            # prd.json-only flip semantics — preserved by the has_origin
            # probe so existing suites stay green without an env flag.
            local orch_slot="$POOL_BASE/$ORCH_NAME"
            local has_origin=0
            if git -C "$orch_slot" remote get-url origin >/dev/null 2>&1; then
                has_origin=1
            fi
            if [ "$has_origin" = "1" ]; then
                local worker_path="$POOL_BASE/${slot_basename}"
                # Prefer the per-story ref captured at COMMIT time (insulates
                # against slot reuse contamination). Falls back to the worker
                # slot's HEAD when the capture failed (logged-only, AC4 may
                # observe strays — surfaced by SMOKE_VIOLATIONS in smoke).
                local merge_ref="" merge_branch=""
                if git -C "$orch_slot" rev-parse --verify -q "refs/ralph/$story_id" >/dev/null 2>&1; then
                    merge_ref="$orch_slot"
                    merge_branch="refs/ralph/$story_id"
                else
                    merge_ref="$worker_path"
                fi
                if ! merge_and_push_story "$orch_slot" "$merge_ref" "$story_id" origin "" "$merge_branch" >/dev/null 2>&1; then
                    log_event "MERGE_FAILED" "$story_id" "slot=$slot_basename"
                    handle_failed_worker "$story_id" "MERGE_FAILED"
                    [ -n "$logfile" ] && rm -f "$logfile" "${logfile}.porcelain.before"
                    return 0
                fi
                # AC3: ephemeral ralph/<story> ref is deleted after merge.
                git -C "$orch_slot" update-ref -d "refs/ralph/$story_id" 2>/dev/null || true
            fi
            log_event "REVIEW_MERGE" "$story_id" "slot=$slot_basename"
            # mktemp_safe + mv guards prd.json against partial-write under
            # concurrent ticks (AC7) — every writer goes through this path.
            local tmp
            tmp=$(mktemp_safe file ralph-prd) || tmp="prd.tmp"
            jq --arg id "$story_id" '(.userStories[] | select(.id == $id)).passes = true' \
                prd.json > "$tmp" && mv -f "$tmp" prd.json
            set_retry_count "$story_id" 0
            ;;
        BLOCK|REQUEST_CHANGES)
            log_event "REVIEW_$verdict" "$story_id" "slot=$slot_basename reason=$reason"
            handle_failed_worker "$story_id" "REVIEW_$verdict"
            ;;
        *)
            log_event "REVIEW_UNKNOWN" "$story_id" "slot=$slot_basename verdict=$verdict"
            handle_failed_worker "$story_id" "REVIEW_UNKNOWN"
            ;;
    esac

    [ -n "$logfile" ] && rm -f "$logfile" "${logfile}.porcelain.before"

    # Plano B: drop the dedicated review worktree regardless of verdict.
    # Codex may have written into it; we don't care — it's isolated.
    if [ -d "$review_wt" ]; then
        git -C "$orch_slot" worktree remove --force "$review_wt" 2>/dev/null || true
        rm -rf "$review_wt" 2>/dev/null || true
    fi
}

# handle_failed_worker — bump retry; escalate after MAX_RETRIES_PER_STORY.
# Mirrors the serial path's escalation but without the in-loop `continue`.
handle_failed_worker() {
    local story_id="$1" reason="$2"
    local current
    current=$(get_retry_count "$story_id")
    local nxt=$((current + 1))
    set_retry_count "$story_id" "$nxt"
    if [ "$nxt" -ge "$MAX_RETRIES_PER_STORY" ]; then
        log_event "ESCALATED" "$story_id" "max retries reached after $reason"
        jq --arg id "$story_id" '(.userStories[] | select(.id == $id)).passes = "ESCALATED"' \
            prd.json > prd.tmp && mv prd.tmp prd.json
    fi
}

# dispatch_workers_tick — fill the pool up to compute_cap. Skips story_ids
# already in flight (passed in as space-separated $excluded). For each
# dispatched story: slate cleanup → cd into slot → setsid mock/CLI in a
# new process group → record to workers.txt.
dispatch_workers_tick() {
    local workers_file="$1"
    local excluded="$2"

    # Determine free worker slots (those not already busy in workers.txt).
    local busy_slots=" "
    local _slot _rest
    while IFS=: read -r _slot _rest; do
        [ -z "$_slot" ] && continue
        busy_slots="${busy_slots}${_slot} "
    done < "$workers_file"

    local -a free_slots=()
    local w
    for w in "${WORKER_PATHS[@]}"; do
        local b
        b=$(basename "$w")
        case "$busy_slots" in *" $b "*) ;; *) free_slots+=("$w") ;; esac
    done

    local slots_avail=${#free_slots[@]}
    [ "$slots_avail" -eq 0 ] && return 0

    local total_dispatch
    total_dispatch=$(count_dispatchable prd.json)
    local cap
    cap=$(compute_cap "$PARALLEL_N" "$slots_avail" "$total_dispatch")
    [ "$cap" -le 0 ] && return 0

    local launched=0
    local i=0
    while [ "$launched" -lt "$cap" ] && [ "$i" -lt "$slots_avail" ]; do
        local story_id
        story_id=$(next_dispatchable_excluding prd.json "$excluded")
        [ -z "$story_id" ] && break

        local slot="${free_slots[$i]}"
        i=$((i + 1))
        dispatch_one "$slot" "$story_id" "$workers_file"
        excluded="$excluded $story_id"
        launched=$((launched + 1))
    done
}

# dispatch_one — slate cleanup + launch worker in $slot's cwd within a new
# process group. AGENT_PID is the PG leader (kill_agent_pg targets it).
dispatch_one() {
    local slot="$1" story_id="$2" workers_file="$3"
    local slot_basename
    slot_basename=$(basename "$slot")

    # Pre-condition: clean slate so a retry never inherits stale deltas.
    slate_cleanup_for_retry "$slot" "$story_id"

    local story_block prompt
    story_block=$(jq -r --arg id "$story_id" '.userStories[] | select(.id == $id)' prd.json)
    prompt=$(printf '%s\n\n## Story atual\n%s\n' "$(cat "$IMPL_PROMPT_FILE")" "$story_block")

    local logfile
    logfile=$(mktemp_safe file ralph-iter)

    # cd into slot's working tree before launching so the agent / mock
    # operates against the slot's git repo. setsid keeps the agent in its
    # own process group so kill_agent_pg can take down forked children.
    if [ -n "${RALPH_AGENT_BIN:-}" ]; then
        ( cd "$slot" && exec "${SETSID_CMD[@]}" "$RALPH_AGENT_BIN" "$prompt" >"$logfile" 2>&1 ) &
    else
        case "$PRIMARY_AGENT" in
            claude)
                ( cd "$slot" && exec "${SETSID_CMD[@]}" claude --print --permission-mode bypassPermissions "$prompt" >"$logfile" 2>&1 ) &
                ;;
            codex)
                ( cd "$slot" && exec "${SETSID_CMD[@]}" codex exec --full-auto "$prompt" >"$logfile" 2>&1 ) &
                ;;
        esac
    fi
    local pid=$!

    local started_at
    started_at=$(date +%s)
    write_worker_record "$workers_file" "$slot_basename" "$pid" "$story_id" "$started_at"
    log_event "DISPATCH" "$story_id" "slot=$slot_basename pid=$pid logfile=$logfile"
}

if [ "$PARALLEL_MODE" = true ]; then
    run_parallel
else
    run_serial
fi
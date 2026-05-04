#!/usr/bin/env bash
# smoke.sh — US-11 F10 smoke test (paralelo end-to-end) em sandbox descartável.
#
# Provisiona um pool sandbox isolado (mktemp_safe dir ralph-smoke + bare
# origin.git + 3 clones), grava um prd.json minúsculo com 3 stories triviais
# independentes, dispara `ralph-adversarial.sh --parallel=2 5` e exige cleanup
# defensivo do diretório descartável — sem nunca tocar no pool de produção do
# usuário (~/Projects/checkouts/...).
#
# Pode ser invocado como CLI (`bash smoke.sh`) ou sourced pelos testes (a
# guarda `if [ "${BASH_SOURCE[0]}" = "${0}" ]` impede execução implícita).
#
# AC mapping:
#   AC1  ≥2 DISPATCH events em <5s entre si  (validado em test_smoke.sh)
#   AC2  Codex revisa em série                (parallel_review_state already
#                                              enforces single-active; smoke
#                                              herda esse contrato)
#   AC3  worker→orch main + push origin       (orchestrator wiring de
#                                              merge_and_push_story em
#                                              finalize_review quando há
#                                              remote `origin` configurado)
#   AC4  deltas ausentes em main final        (integrate_delta_files já
#                                              chamado por merge_and_push_story)
#   AC5  prd.json final 100% passes:true       (validado pelo orquestrador)
#   AC6  smoke completo em <30min wall-clock  (mocks finalizam em segundos)
#   AC7  cleanup remove SMOKE; pool real OK   (cleanup_smoke + trap)
#   AC8  defesa de cleanup (whitelist regex)  (testado em test_smoke.sh)
#   AC9  trap em INT/TERM dispara cleanup     (testado em test_smoke.sh)
#   AC10 violation rate logada em progress.txt central (smoke conta strays
#       e emite SMOKE_VIOLATIONS via log_event)

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"
RALPH_SCRIPT="$SCRIPT_DIR/ralph-adversarial.sh"
MOCKS_DIR="$SCRIPT_DIR/tests/mocks"

# shellcheck source=lib/dispatch.sh
. "$LIB_DIR/dispatch.sh"

# Whitelist de prefixos que cleanup_smoke aceita deletar. Cobre Linux (/tmp/)
# e macOS (TMPDIR sob /var/folders/<a>/<b>/T/ — também simbolizado como
# /private/var/folders/...). NÃO use ~ ou $HOME aqui — defesa em profundidade
# é exatamente recusar paths que não estão sob TMPDIR.
SMOKE_PREFIX_RE='^(/tmp/ralph-smoke\.|/private/var/folders/[^/]+/[^/]+/T/ralph-smoke\.|/var/folders/[^/]+/[^/]+/T/ralph-smoke\.)'

# Estado global; cleanup lê ${SMOKE:-} (set -u tolerado pelo default).
SMOKE=""

# ─── cleanup_smoke ─────────────────────────────────────────────────────────
# Defesa em profundidade. Comportamento:
#   * SMOKE vazio                       → return 0 (nada provisionado)
#   * SMOKE NÃO bate prefix whitelist    → exit 8 com mensagem; / NÃO é tocado
#   * SMOKE bate whitelist               → rm -rf $SMOKE
#
# Usa exit (não return) na recusa para que o trap garanta que o orquestrador
# de testes e o invocador CLI propaguem o erro fatal — uma falha silenciosa
# aqui esconderia o pior bug imaginável (delete acidental de path produção).
cleanup_smoke() {
    local target="${SMOKE:-}"
    if [ -z "$target" ]; then
        return 0
    fi
    if ! [[ "$target" =~ $SMOKE_PREFIX_RE ]]; then
        echo "ERROR: cleanup_smoke refusing to delete '$target' — does not match whitelist prefix" >&2
        exit 8
    fi
    rm -rf "$target"
}

# ─── provision_sandbox ─────────────────────────────────────────────────────
# Cria $SMOKE/origin.git (bare), seed commit pushed para main, depois
# $n_slots clones em $SMOKE/checkouts/smoke-<i>. Todos os slots ficam em
# main local apontando para origin/main. Pool metadata em
# $SMOKE/checkouts/.smoke.pool conforme contrato US-05.
#
# Exit non-zero se mktemp_safe falhar (TMPDIR não-escrível) — neste caso
# SMOKE permanece vazio e cleanup_smoke é no-op.
provision_sandbox() {
    local n_slots="${1:-3}"

    SMOKE=$(mktemp_safe dir ralph-smoke) || return 1

    # Permite que testes capturem o path do sandbox antes do orquestrador
    # rodar (necessário para AC9 — verificar cleanup pós-INT/TERM).
    if [ -n "${RALPH_SMOKE_STATE_FILE:-}" ]; then
        printf '%s\n' "$SMOKE" > "$RALPH_SMOKE_STATE_FILE"
    fi

    git init --quiet --bare "$SMOKE/origin.git"

    # Seed: repo descartável que cria o commit baseline + push para origin.
    # Inclui progress.txt e AGENTS.md vazios para que integrate_delta_files
    # encontre arquivos centrais já tracked (evita `git add` no-op).
    local seed="$SMOKE/.seed"
    git init --quiet -b main "$seed" 2>/dev/null || git init --quiet "$seed"
    (
        cd "$seed"
        git config user.email "smoke@ralph.local"
        git config user.name  "smoke"
        git config core.logAllRefUpdates true
        : > progress.txt
        : > AGENTS.md
        git add progress.txt AGENTS.md
        git commit --quiet -m "smoke base"
        git remote add origin "$SMOKE/origin.git"
        git push --quiet origin HEAD:main
    )
    rm -rf "$seed"

    mkdir -p "$SMOKE/checkouts"
    local i
    for i in $(seq 1 "$n_slots"); do
        local slot="$SMOKE/checkouts/smoke-$i"
        git clone --quiet "$SMOKE/origin.git" "$slot"
        (
            cd "$slot"
            git config user.email "smoke@ralph.local"
            git config user.name  "smoke"
            git config core.logAllRefUpdates true
            git checkout -q -B main origin/main 2>/dev/null || git checkout -q main
        )
    done

    cat > "$SMOKE/checkouts/.smoke.pool" <<EOF
repo_name=smoke
slots=$n_slots
EOF
}

# ─── seed_smoke_prd ────────────────────────────────────────────────────────
# Grava prd.json minúsculo com 3 stories independentes (sem dependsOn) no
# slot do orquestrador. Mocks (fake-claude delta-commit) produzem commits
# contract-compliant (apenas progress-<id>.txt + agents-delta-<id>.md), de
# modo que merge_and_push_story + integrate_delta_files exercitem o caminho
# completo sem conflitos.
seed_smoke_prd() {
    local slot="$1"
    cat > "$slot/prd.json" <<'JSON'
{
  "projectName": "ralph-smoke",
  "branchName": "feat/ralph-smoke",
  "userStories": [
    {"id":"US-S1","title":"smoke 1","priority":1,"passes":false,"acceptanceCriteria":["AC: contract-compliant delta commit"]},
    {"id":"US-S2","title":"smoke 2","priority":2,"passes":false,"acceptanceCriteria":["AC: contract-compliant delta commit"]},
    {"id":"US-S3","title":"smoke 3","priority":3,"passes":false,"acceptanceCriteria":["AC: contract-compliant delta commit"]}
  ]
}
JSON
}

# ─── run_smoke ─────────────────────────────────────────────────────────────
# Entry point CLI. Configura traps DE PRIMEIRO (defesa: se mktemp_safe falhar
# antes de provisionar, trap ainda corre e é no-op). Depois provisiona,
# semeia prd, dispara orquestrador em modo paralelo apontando para os mocks.
#
# Override env: caller pode setar RALPH_AGENT_BIN/RALPH_REVIEWER_BIN para
# rodar smoke contra os binários reais de claude/codex (validação SUPOSIÇÃO
# rev5 AC10). Default usa as fakes.
run_smoke() {
    trap cleanup_smoke EXIT
    trap 'cleanup_smoke; exit 130' INT
    trap 'cleanup_smoke; exit 143' TERM

    provision_sandbox "${RALPH_SMOKE_SLOTS:-3}"
    local orch="$SMOKE/checkouts/smoke-1"
    seed_smoke_prd "$orch"

    : "${RALPH_AGENT_BIN:=$MOCKS_DIR/fake-claude.sh}"
    : "${RALPH_REVIEWER_BIN:=$MOCKS_DIR/fake-codex.sh}"
    : "${FAKE_OUTCOME:=delta-untracked}"
    : "${FAKE_VERDICT:=MERGE}"
    : "${RALPH_HANG_TIMEOUT:=60}"
    : "${RALPH_REVIEW_TIMEOUT:=60}"
    : "${RALPH_POLL_INTERVAL:=1}"
    : "${RALPH_PARALLEL_N:=2}"
    export RALPH_AGENT_BIN RALPH_REVIEWER_BIN FAKE_OUTCOME FAKE_VERDICT \
           RALPH_HANG_TIMEOUT RALPH_REVIEW_TIMEOUT RALPH_POLL_INTERVAL \
           RALPH_PARALLEL_N RALPH_ALLOW_TEST_CWD=1

    local rc=0
    (
        cd "$orch"
        bash "$RALPH_SCRIPT" --parallel="$RALPH_PARALLEL_N" "${RALPH_SMOKE_MAX_ITER:-5}"
    ) || rc=$?

    # AC10: contagem de violações observadas (delta files que sobreviveram
    # em main do orch — denuncia contrato quebrado pelo agente real). Em
    # smoke contra mocks o esperado é 0; contra binários reais qualquer
    # valor > 0 sinaliza desvio.
    local strays=0
    local f
    for f in "$orch"/progress-*.txt "$orch"/agents-delta-*.md; do
        [ -e "$f" ] && strays=$((strays + 1))
    done
    # AC3: refs efêmeras refs/ralph/<story> devem ser deletadas após cada merge
    # (merge_and_push_story chama `update-ref -d` 2>/dev/null || true — falha
    # silenciosa por design; aqui contamos sobreviventes para fechar o gap).
    local stray_refs
    stray_refs=$(git -C "$orch" for-each-ref --format='%(refname)' 'refs/ralph/*' 2>/dev/null | wc -l | tr -d ' ')
    local final_pass
    final_pass=$(jq '[.userStories[] | select(.passes == true)] | length' "$orch/prd.json" 2>/dev/null || echo "?")
    local final_total
    final_total=$(jq '[.userStories[]] | length' "$orch/prd.json" 2>/dev/null || echo "?")
    log_event "SMOKE_VIOLATIONS" "" "delta_strays=$strays stray_refs=$stray_refs passes=$final_pass/$final_total rc=$rc"

    return "$rc"
}

# Apenas invoca run_smoke quando executado diretamente; sourced pelos testes
# para acessar provision_sandbox / cleanup_smoke / seed_smoke_prd sem rodar
# nada implicitamente.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    run_smoke "$@"
fi

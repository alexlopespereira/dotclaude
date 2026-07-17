#!/bin/bash
# test_preflight_clean_tree.sh — US-02 (paralelização-harness prd.json)
#
# Origem: incidente real 2026-06-10 — um worker do Ralph em HANG rodou
# `git stash push -u` GLOBAL e varreu o WIP NÃO-commitado do usuário
# (vm1.sh/vm2.sh/vm-paste.sh). Defesa em dupla camada:
#   (1) pré-flight no início do run_serial aborta se a árvore está suja FORA
#       da lista de framework files, ANTES de qualquer mutação;
#   (2) o stash da rota HANG usa pathspec que exclui os mesmos framework files.
#
# Cobertura:
#   AC1 — árvore com arquivo de USUÁRIO sujo → run_serial aborta exit≠0,
#         mensagem cita --allow-dirty, nenhum commit/stash no call-log de git,
#         stash list vazio, agente NUNCA lançado (end-to-end, script real).
#   AC2 — árvore suja só com framework files (prd.json/progress.txt/
#         progress-*.jsonl/agents-delta-*.md) → pré-flight passa, agente lançado.
#   AC3 — --allow-dirty pula o pré-flight mesmo com arquivo de usuário sujo.
#   AC4 — rota HANG: stash captura src/x mas NÃO captura progress.txt
#         (capture-proof via `git stash show`); a replica do comando é guardada
#         por sentinels de drift contra a real em ralph-adversarial.sh.
#
# AC1/AC2/AC3 invocam o script REAL ponta-a-ponta com RALPH_AGENT_BIN (mock) e
# --no-review (sem CLIs reais). Todo artefato de harness (mock, shim, logs) vive
# FORA do repo, para não sujar a árvore que o pré-flight inspeciona. AC4 replica
# o comando de stash (mesmo padrão de test_stream_timeout_behavior.sh) porque a
# rota HANG exige um timeout custoso de disparar end-to-end; sentinels garantem
# sincronia com o script-alvo.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RALPH_SH="$(cd "$SCRIPT_DIR/.." && pwd)/ralph-adversarial.sh"
REAL_GIT="$(command -v git)"

[ -f "$RALPH_SH" ] || { echo "FAIL: ralph-adversarial.sh não encontrado em $RALPH_SH"; exit 1; }

FAIL=0
_fail() { echo "FAIL ($1): $2"; FAIL=1; }
assert_grep()    { grep -q -- "$2" "$3" 2>/dev/null || _fail "$1" "esperava '$2' em $3"; }
assert_no_grep() { grep -q -- "$2" "$3" 2>/dev/null && _fail "$1" "NÃO esperava '$2' em $3"; }

# ── Sentinels de drift: o pré-flight e o stash de exclusão precisam existir
#    no script-alvo. Se sumirem, o comportamento testado regrediu. ──────────
for pat in \
    'preflight_clean_tree' \
    'is_framework_file' \
    '--allow-dirty' \
    'RALPH_FRAMEWORK_PATHSPEC_EXCLUDES' \
    ':(exclude)progress*.txt'
do
    grep -qF -- "$pat" "$RALPH_SH" \
        || { echo "FAIL (drift): pattern '$pat' ausente em ralph-adversarial.sh"; exit 1; }
done

ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT

# ── Mock de agente: registra invocação e sai sem commitar (→ FALHA_COMMIT). ──
make_mock_agent() {
    cat > "$1" <<'MOCK'
#!/bin/bash
printf 'invoked\n' >> "$RALPH_TEST_AGENT_LOG"
exit 0
MOCK
    chmod +x "$1"
}

# ── git shim: encaminha pro git real e registra cada subcomando no call-log. ──
make_git_shim() {
    local dir="$1" log="$2"
    mkdir -p "$dir"
    cat > "$dir/git" <<SHIM
#!/bin/bash
printf '%s\n' "\$*" >> "$log"
exec "$REAL_GIT" "\$@"
SHIM
    chmod +x "$dir/git"
}

# ── Fixture de repo: git init + 1 commit base (prd.json válido + src/x). ──
mk_repo() {
    local repo="$1"
    mkdir -p "$repo/src"
    "$REAL_GIT" -C "$repo" init -q
    "$REAL_GIT" -C "$repo" config user.email t@t.com
    "$REAL_GIT" -C "$repo" config user.name  t
    "$REAL_GIT" -C "$repo" config core.logAllRefUpdates true
    cat > "$repo/prd.json" <<'EOF'
{ "projectName": "preflight-test", "branchName": "ralph-test-branch",
  "userStories": [ { "id": "US-X", "title": "stub", "passes": false,
                     "acceptanceCriteria": ["AC1: stub"] } ] }
EOF
    echo base > "$repo/src/x"
    "$REAL_GIT" -C "$repo" add prd.json src/x
    "$REAL_GIT" -C "$repo" commit -qm init
}

# run_ralph — invoca o script real no repo. Mock/shim/logs vivem em $work.*
# (FORA do repo). Args extras (ex.: --allow-dirty) repassados antes de MAX_ITER.
run_ralph() {
    local repo="$1" work="$2"; shift 2
    make_mock_agent "$work.mock"
    ( cd "$repo" \
        && PATH="${SHIM_PATH:-}$PATH" \
           RALPH_AGENT_BIN="$work.mock" \
           RALPH_TEST_AGENT_LOG="$work.agentlog" \
           bash "$RALPH_SH" --no-review "$@" 1 ) >"$work.out" 2>"$work.err"
}

# ═══ AC1: árvore com arquivo de USUÁRIO sujo → aborta antes de mutar ═══════
R1="$ROOT/ac1"; W1="$ROOT/w1"; mk_repo "$R1"
make_git_shim "$W1.shim" "$W1.gitcalls"
echo "wip do usuário" > "$R1/vm1.sh"          # untracked não-framework
echo modificado       > "$R1/src/x"           # tracked não-framework
SHIM_PATH="$W1.shim:" run_ralph "$R1" "$W1"; RC1=$?

[ "$RC1" -ne 0 ] || _fail "AC1-rc" "esperava exit≠0, obteve $RC1"
assert_grep    "AC1-msg" "allow-dirty" "$W1.err"
assert_no_grep "AC1-no-stash"  "stash"   "$W1.gitcalls"
assert_no_grep "AC1-no-commit" "^commit" "$W1.gitcalls"
[ -z "$("$REAL_GIT" -C "$R1" stash list)" ] || _fail "AC1-stashlist" "stash foi criado (deveria estar vazio)"
[ ! -s "$W1.agentlog" ] || _fail "AC1-agent" "agente foi lançado antes do abort"
[ -f "$R1/vm1.sh" ] || _fail "AC1-wip" "WIP do usuário sumiu"

# ═══ AC2: árvore suja SÓ com framework files → pré-flight passa ════════════
R2="$ROOT/ac2"; W2="$ROOT/w2"; mk_repo "$R2"
# prd.json tracked-modificado (continua JSON válido) + framework untracked.
cat > "$R2/prd.json" <<'EOF'
{ "projectName": "preflight-test", "branchName": "ralph-test-branch",
  "userStories": [ { "id": "US-X", "title": "stub2", "passes": false,
                     "acceptanceCriteria": ["AC1: stub"] } ] }
EOF
echo "log" > "$R2/progress-US-X.jsonl"
echo "serial" > "$R2/progress.jsonl"   # bare (output do run serial): glob progress*.jsonl
echo "delta" > "$R2/agents-delta-US-X.md"
SHIM_PATH="" run_ralph "$R2" "$W2"
[ -s "$W2.agentlog" ] || _fail "AC2-agent" "pré-flight bloqueou árvore só-framework (agente não lançado)"
assert_no_grep "AC2-no-abort" "allow-dirty" "$W2.err"

# ═══ AC3: --allow-dirty pula o pré-flight mesmo com user file sujo ═════════
R3="$ROOT/ac3"; W3="$ROOT/w3"; mk_repo "$R3"
echo "wip" > "$R3/vm2.sh"
echo mod   > "$R3/src/x"
SHIM_PATH="" run_ralph "$R3" "$W3" --allow-dirty
[ -s "$W3.agentlog" ] || _fail "AC3-agent" "--allow-dirty não pulou o pré-flight (agente não lançado)"

# ═══ AC4: rota HANG — stash exclui framework files (capture-proof) ═════════
# Replica o comando real (ralph-adversarial.sh) sob sentinel de drift.
R4="$ROOT/ac4"; mk_repo "$R4"
echo modificado > "$R4/src/x"                   # WIP do worker (deve entrar no stash)
echo "log do framework" > "$R4/progress.txt"    # framework (NÃO deve entrar)
echo "delta" > "$R4/progress-US-X.jsonl"        # framework (NÃO deve entrar)

# Espelho de RALPH_FRAMEWORK_PATHSPEC_EXCLUDES (sincronia via sentinels acima).
EXCLUDES=(
    ':(exclude)prd.json'
    ':(exclude)progress*.txt'
    ':(exclude)progress*.jsonl'
    ':(exclude)agents-delta-*.md'
    ':(exclude).claude'
    ':(exclude)graphify-out'
)
"$REAL_GIT" -C "$R4" stash push -u -m "ralph-hang-US-X-iter1" -- \
    '.' "${EXCLUDES[@]}" >/dev/null 2>&1

STASHED=$("$REAL_GIT" -C "$R4" stash show --include-untracked --name-only stash@{0} 2>/dev/null)
case "$STASHED" in *"src/x"*) ;; *) _fail "AC4-capture" "stash NÃO capturou src/x: [$STASHED]" ;; esac
case "$STASHED" in *progress.txt*) _fail "AC4-exclude-txt" "stash capturou progress.txt (deveria excluir)" ;; esac
case "$STASHED" in *progress-US-X.jsonl*) _fail "AC4-exclude-jsonl" "stash capturou progress-*.jsonl (deveria excluir)" ;; esac
# progress.txt deve continuar no working tree (não foi stashado).
[ -f "$R4/progress.txt" ] || _fail "AC4-wt" "progress.txt sumiu do working tree"

if [ "$FAIL" -ne 0 ]; then
    echo "preflight-clean-tree test: FAIL"
    exit 1
fi
echo "PASS: preflight-clean-tree — AC1 (abort), AC2 (framework-only passa), AC3 (--allow-dirty), AC4 (stash exclui framework)"
exit 0

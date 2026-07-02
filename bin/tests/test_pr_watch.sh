#!/usr/bin/env bash
# bin/tests/test_pr_watch.sh — Cobre a Fatia 3 (US-03 do ciclo autonomy-4-melhorias):
#   (a) bin/commit-push-pr.sh grava o número do PR em $(git rev-parse --git-dir)/CPP_LAST_PR
#       com extração defensiva (/pull/<digits> no fim da URL; sem match → não grava);
#   (b) bin/pr-watch.sh resolve o PR por precedência arg > CPP_LAST_PR > gh pr view,
#       checa o state ANTES de watchar (MERGED→0 sem watch, CLOSED→1, OPEN→watch com
#       teto perl-alarm e exit propagado) e falha claro (usage stderr + exit 2) quando
#       o PR é irresolúvel.
#
# Estratégia (padrão test_ship_ci_watch.sh): repo git real com origin bare local,
# `gh` stubado — via PATH para o commit-push-pr.sh (que chama gh puro) e via seam
# PRWATCH_GH para o pr-watch.sh (padrão vm-doctor) — logando argv em CALL_LOG com
# RCs/outputs configuráveis por env. git/perl são reais; zero rede.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CPP="$BIN_DIR/commit-push-pr.sh"
PRWATCH="$BIN_DIR/pr-watch.sh"

PASS=0; FAIL=0; FAILED=""
_fail() { FAIL=$((FAIL+1)); FAILED="${FAILED}
  ✗ $1"; }
_pass() { PASS=$((PASS+1)); }
assert_rc()           { [ "$1" = "$2" ] && _pass || _fail "$3 :: expected rc=$2 got rc=$1"; }
assert_rc_nonzero()   { [ "$1" != "0" ] && _pass || _fail "$2 :: expected rc!=0 got rc=0"; }
assert_eq()           { [ "$1" = "$2" ] && _pass || _fail "$3 :: expected '$2' got '$1'"; }
assert_contains()     { case "$1" in *"$2"*) _pass ;; *) _fail "$3 :: needle '$2' not found";; esac; }
assert_not_contains() { case "$1" in *"$2"*) _fail "$3 :: needle '$2' found but should NOT be";; *) _pass;; esac; }
assert_file_absent()  { [ ! -e "$1" ] && _pass || _fail "$2 :: file '$1' exists but should NOT"; }

# ─── Setup: repo git real (origin bare local) p/ commit-push-pr.sh ──────────
setup_cpp_repo() {
  REPO=$(mktemp -d); ORIGIN=$(mktemp -d)
  ( cd "$ORIGIN" && git init -q --bare ) >/dev/null 2>&1
  (
    cd "$REPO"
    git init -q -b main
    git config user.email t@t.com; git config user.name t
    git config commit.gpgsign false
    echo a > a.txt; git add a.txt; git commit -qm init
    git remote add origin "$ORIGIN"
    git push -q origin main
    echo dirty >> a.txt                          # tree dirty (CASO B do cpp)
  ) >/dev/null 2>&1
}

# Stub de gh no PATH (commit-push-pr.sh chama `gh` puro). Output do `pr create`
# configurável via CPP_CREATE_OUT (default: URL válida com /pull/123).
setup_cpp_stub() {
  MOCK_DIR=$(mktemp -d); CALL_LOG="$MOCK_DIR/calls.log"; : > "$CALL_LOG"
  cat > "$MOCK_DIR/gh" <<'GH'
#!/usr/bin/env bash
echo "gh $*" >> "$CALL_LOG"
case "$1 ${2:-}" in
  "pr create") printf '%s\n' "${CPP_CREATE_OUT:-https://github.com/dev/test-repo/pull/123}" ;;
esac
exit 0
GH
  chmod +x "$MOCK_DIR/gh"
}

# Env extra (CPP_CREATE_OUT etc.) via prefixo na invocação da função:
# `CPP_CREATE_OUT=... run_cpp` — assignment expandido de "$@" NÃO é prefixo
# de env (vira nome de comando → 127).
run_cpp() {
  ( cd "$REPO" && PATH="$MOCK_DIR:$PATH" CALL_LOG="$CALL_LOG" \
    bash "$CPP" "$CPP_MSG" --no-auto-merge 2>&1 )
}

# ─── Setup: repo git + stub gh (via seam PRWATCH_GH) p/ pr-watch.sh ────────
# STUB_VIEW_NUM  — output de `pr view --json number` (vazio → exit 1: sem PR na branch)
# STUB_STATE     — output de `pr view <n> --json state` (default OPEN)
# STUB_WATCH_RC  — exit do `pr checks <n> --watch` (default 0)
# STUB_WATCH_SLEEP — sleep antes de sair do watch (p/ teste de timeout)
setup_watch_env() {
  WREPO=$(mktemp -d)
  ( cd "$WREPO" && git init -q -b main \
    && git config user.email t@t.com && git config user.name t ) >/dev/null 2>&1
  WMOCK=$(mktemp -d); CALL_LOG="$WMOCK/calls.log"; : > "$CALL_LOG"
  STUB_GH="$WMOCK/gh"
  cat > "$STUB_GH" <<'GH'
#!/usr/bin/env bash
echo "gh $*" >> "$CALL_LOG"
case "$*" in
  "pr view --json number"*)
    if [ -n "${STUB_VIEW_NUM:-}" ]; then echo "$STUB_VIEW_NUM"; exit 0; fi
    exit 1 ;;
  "pr view "*"--json state"*)
    if [ -n "${STUB_STATE_RC:-}" ]; then exit "$STUB_STATE_RC"; fi
    echo "${STUB_STATE:-OPEN}" ;;
  "pr checks "*"--json"*)
    # Emula o gh real: zero checks → erro no stderr + exit ≠0, SEM stdout
    # (STUB_CHECKS_RC + STUB_CHECKS_ERR); rc=0 → JSON no stdout.
    if [ -n "${STUB_CHECKS_RC:-}" ] && [ "$STUB_CHECKS_RC" != "0" ]; then
      echo "${STUB_CHECKS_ERR:-boom}" >&2; exit "$STUB_CHECKS_RC"
    fi
    # Default fora do ${:-}: '}' dentro da expansão fecha o parâmetro cedo.
    if [ -n "${STUB_CHECKS_JSON+x}" ]; then printf '%s\n' "$STUB_CHECKS_JSON"
    else printf '[{"name":"ci"}]\n'; fi ;;
  "pr checks "*"--watch"*)
    if [ -n "${STUB_WATCH_SLEEP:-}" ]; then sleep "$STUB_WATCH_SLEEP"; fi
    exit "${STUB_WATCH_RC:-0}" ;;
esac
exit 0
GH
  chmod +x "$STUB_GH"
}

# STUB_* via prefixo na invocação da função (idioma test_ship_ci_watch.sh):
# `STUB_STATE=MERGED run_watch_arg 42`.
run_watch() {
  ( cd "$WREPO" && PRWATCH_GH="$STUB_GH" CALL_LOG="$CALL_LOG" \
    bash "$PRWATCH" 2>"$WMOCK/stderr" )
}
run_watch_arg() {
  ( cd "$WREPO" && PRWATCH_GH="$STUB_GH" CALL_LOG="$CALL_LOG" \
    bash "$PRWATCH" "$1" 2>"$WMOCK/stderr" )
}

# ═══════════════════════════════════════════════════════════════════════════
# AC2: commit-push-pr.sh grava CPP_LAST_PR com o número certo; output de erro
#      no lugar da URL → NÃO grava/atualiza (extração defensiva).
# ═══════════════════════════════════════════════════════════════════════════
setup_cpp_repo; setup_cpp_stub
CPP_MSG="feat: teste cpp last pr"
OUT=$(run_cpp); RC=$?
assert_rc "$RC" 0 "AC2a cpp com URL válida sai rc=0"
assert_eq "$(cat "$REPO/.git/CPP_LAST_PR" 2>/dev/null)" "123" "AC2a .git/CPP_LAST_PR contém o número do PR"

# Idempotência (cat-9-base spec-7): regravar com o mesmo valor converge.
( cd "$REPO" && echo dirty2 >> a.txt ) >/dev/null 2>&1
CPP_MSG="feat: teste cpp last pr segunda rodada"
OUT=$(run_cpp); RC=$?
assert_rc "$RC" 0 "AC2b segunda execução sai rc=0"
assert_eq "$(cat "$REPO/.git/CPP_LAST_PR" 2>/dev/null)" "123" "AC2b CPP_LAST_PR regravado com o mesmo valor"
rm -rf "$REPO" "$ORIGIN" "$MOCK_DIR"

# Output de ERRO (sem /pull/<digits>) em repo fresco → arquivo NÃO criado.
setup_cpp_repo; setup_cpp_stub
CPP_MSG="feat: teste cpp erro"
OUT=$(CPP_CREATE_OUT="pull request create failed: GraphQL: something broke" run_cpp); RC=$?
assert_file_absent "$REPO/.git/CPP_LAST_PR" "AC2c output de erro → CPP_LAST_PR não é criado"
rm -rf "$REPO" "$ORIGIN" "$MOCK_DIR"

# Output de ERRO com arquivo pré-existente → arquivo INVALIDADO (rm antes do
# create), nunca stale: número velho não pode sobreviver a um create que falhou
# a extração (code-review 2026-07-02: stale numérico tornava a precedência 3
# inalcançável e virava falso "CI verde" na Fase 8).
setup_cpp_repo; setup_cpp_stub
echo "99" > "$REPO/.git/CPP_LAST_PR"
CPP_MSG="feat: teste cpp erro invalida"
OUT=$(CPP_CREATE_OUT="pull request create failed: GraphQL: something broke" run_cpp); RC=$?
assert_file_absent "$REPO/.git/CPP_LAST_PR" "AC2d output de erro → CPP_LAST_PR pré-existente é invalidado (não fica stale)"
rm -rf "$REPO" "$ORIGIN" "$MOCK_DIR"

# ═══════════════════════════════════════════════════════════════════════════
# AC3: resolução por precedência — arg > CPP_LAST_PR > gh pr view; sem os
#      três → usage em stderr + exit 2.
# ═══════════════════════════════════════════════════════════════════════════
# (a) arg explícito vence CPP_LAST_PR
setup_watch_env
echo "99" > "$WREPO/.git/CPP_LAST_PR"
OUT=$(STUB_STATE=MERGED run_watch_arg 42); RC=$?
assert_contains "$(cat "$CALL_LOG")" "pr view 42 --json state" "AC3a arg 42 vence CPP_LAST_PR=99"
assert_not_contains "$(cat "$CALL_LOG")" "pr view 99" "AC3a CPP_LAST_PR ignorado com arg presente"
rm -rf "$WREPO" "$WMOCK"

# (b) CPP_LAST_PR vence gh pr view (fallback nem é chamado)
setup_watch_env
echo "99" > "$WREPO/.git/CPP_LAST_PR"
OUT=$(STUB_STATE=MERGED STUB_VIEW_NUM=7 run_watch); RC=$?
assert_contains "$(cat "$CALL_LOG")" "pr view 99 --json state" "AC3b CPP_LAST_PR=99 usado"
assert_not_contains "$(cat "$CALL_LOG")" "pr view --json number" "AC3b fallback gh pr view não chamado"
rm -rf "$WREPO" "$WMOCK"

# (c) sem arg e sem arquivo → fallback gh pr view --json number
setup_watch_env
OUT=$(STUB_STATE=MERGED STUB_VIEW_NUM=7 run_watch); RC=$?
assert_contains "$(cat "$CALL_LOG")" "pr view --json number" "AC3c fallback gh pr view consultado"
assert_contains "$(cat "$CALL_LOG")" "pr view 7 --json state" "AC3c número do fallback usado"
rm -rf "$WREPO" "$WMOCK"

# (c2) CPP_LAST_PR corrompido (não-numérico) → cai no fallback, não usa lixo
setup_watch_env
echo "lixo-nao-numerico" > "$WREPO/.git/CPP_LAST_PR"
OUT=$(STUB_STATE=MERGED STUB_VIEW_NUM=7 run_watch); RC=$?
assert_contains "$(cat "$CALL_LOG")" "pr view 7 --json state" "AC3c2 arquivo corrompido → fallback usado"
assert_not_contains "$(cat "$CALL_LOG")" "pr view lixo" "AC3c2 conteúdo corrompido não vira PR"
rm -rf "$WREPO" "$WMOCK"

# (d) sem arg, sem arquivo, gh pr view falha → usage em stderr + exit 2
setup_watch_env
OUT=$(run_watch); RC=$?
assert_rc "$RC" 2 "AC3d PR irresolúvel → exit 2"
assert_contains "$(cat "$WMOCK/stderr")" "Uso:" "AC3d usage em stderr"
rm -rf "$WREPO" "$WMOCK"

# (e) arg não-numérico → usage em stderr + exit 2 (cat-9-base: args inválidos)
setup_watch_env
OUT=$(run_watch_arg abc); RC=$?
assert_rc "$RC" 2 "AC3e arg inválido → exit 2"
assert_contains "$(cat "$WMOCK/stderr")" "Uso:" "AC3e usage em stderr"
rm -rf "$WREPO" "$WMOCK"

# ═══════════════════════════════════════════════════════════════════════════
# AC4: state=MERGED → exit 0 SEM watch; CLOSED → exit ≠0; OPEN → watch com
#      exit propagado (rc=0 e rc≠0).
# ═══════════════════════════════════════════════════════════════════════════
setup_watch_env
OUT=$(STUB_STATE=MERGED run_watch_arg 42); RC=$?
assert_rc "$RC" 0 "AC4a MERGED → exit 0"
assert_not_contains "$(cat "$CALL_LOG")" "--watch" "AC4a MERGED não chama checks --watch"
rm -rf "$WREPO" "$WMOCK"

setup_watch_env
OUT=$(STUB_STATE=CLOSED run_watch_arg 42); RC=$?
assert_rc "$RC" 1 "AC4b CLOSED → exit 1"
assert_not_contains "$(cat "$CALL_LOG")" "--watch" "AC4b CLOSED não chama checks --watch"
rm -rf "$WREPO" "$WMOCK"

setup_watch_env
OUT=$(STUB_STATE=OPEN STUB_WATCH_RC=0 run_watch_arg 42); RC=$?
assert_rc "$RC" 0 "AC4c OPEN + watch verde → exit 0"
assert_contains "$(cat "$CALL_LOG")" "pr checks 42 --watch" "AC4c OPEN chama checks --watch"
rm -rf "$WREPO" "$WMOCK"

setup_watch_env
OUT=$(STUB_STATE=OPEN STUB_WATCH_RC=8 run_watch_arg 42); RC=$?
assert_rc "$RC" 8 "AC4d OPEN + watch rc=8 → exit propagado 8"
rm -rf "$WREPO" "$WMOCK"

# state inesperado (nem MERGED/CLOSED/OPEN) → erro claro exit 2, sem watch
setup_watch_env
OUT=$(STUB_STATE=WEIRD run_watch_arg 42); RC=$?
assert_rc "$RC" 2 "AC4e state desconhecido → exit 2"
assert_not_contains "$(cat "$CALL_LOG")" "--watch" "AC4e state desconhecido não watcha"
rm -rf "$WREPO" "$WMOCK"

# ═══════════════════════════════════════════════════════════════════════════
# AC5: watch com teto — idioma perl alarm com PRWATCH_TIMEOUT (fonte) e
#      timeout funcional (alarm 1s mata watch de 5s → rc 142).
# ═══════════════════════════════════════════════════════════════════════════
assert_contains "$(cat "$PRWATCH" 2>/dev/null)" "perl -e 'alarm shift; exec @ARGV'" "AC5a fonte usa idioma perl alarm"
assert_contains "$(cat "$PRWATCH" 2>/dev/null)" "PRWATCH_TIMEOUT" "AC5b teto override via PRWATCH_TIMEOUT"

setup_watch_env
OUT=$(STUB_STATE=OPEN STUB_WATCH_SLEEP=5 PRWATCH_TIMEOUT=1 run_watch_arg 42); RC=$?
assert_rc "$RC" 142 "AC5c alarm 1s mata watch de 5s → rc 142"
rm -rf "$WREPO" "$WMOCK"

# ═══════════════════════════════════════════════════════════════════════════
# FIX code-review 2026-07-02 — ciclo de vida do CPP_LAST_PR no pr-watch:
# resolvido via ARQUIVO + estado terminal (MERGED/CLOSED) → arquivo consumido
# (rm); resolvido via ARG → arquivo alheio preservado.
# ═══════════════════════════════════════════════════════════════════════════
setup_watch_env
echo "99" > "$WREPO/.git/CPP_LAST_PR"
OUT=$(STUB_STATE=MERGED run_watch); RC=$?
assert_rc "$RC" 0 "FIX1a MERGED via arquivo → exit 0"
assert_file_absent "$WREPO/.git/CPP_LAST_PR" "FIX1a MERGED via arquivo → CPP_LAST_PR consumido (rm)"
rm -rf "$WREPO" "$WMOCK"

setup_watch_env
echo "99" > "$WREPO/.git/CPP_LAST_PR"
OUT=$(STUB_STATE=MERGED run_watch_arg 42); RC=$?
assert_eq "$(cat "$WREPO/.git/CPP_LAST_PR" 2>/dev/null)" "99" "FIX1b MERGED via arg → arquivo de outro PR preservado"
rm -rf "$WREPO" "$WMOCK"

# ═══════════════════════════════════════════════════════════════════════════
# FIX code-review 2026-07-02 — zero-checks: PR OPEN sem checks configurados →
# mensagem + exit 0 SEM watch (paridade com ship.sh; `gh pr checks --watch`
# sai ≠0 em repo sem CI e virava falso "CI vermelho").
# ═══════════════════════════════════════════════════════════════════════════
setup_watch_env
OUT=$(STUB_STATE=OPEN STUB_CHECKS_JSON="[]" run_watch_arg 42); RC=$?
assert_rc "$RC" 0 "FIX2a zero checks → exit 0"
assert_not_contains "$(cat "$CALL_LOG")" "--watch" "FIX2a zero checks não chama --watch"
assert_contains "$OUT" "sem checks" "FIX2a mensagem explica ausência de CI"
rm -rf "$WREPO" "$WMOCK"

# Probe de checks falhando/ilegível → fail-open pro watch (comportamento atual)
setup_watch_env
OUT=$(STUB_STATE=OPEN STUB_CHECKS_JSON="" STUB_WATCH_RC=0 run_watch_arg 42); RC=$?
assert_rc "$RC" 0 "FIX2b probe de checks ilegível → watch roda normal"
assert_contains "$(cat "$CALL_LOG")" "pr checks 42 --watch" "FIX2b watch chamado no fail-open"
rm -rf "$WREPO" "$WMOCK"

# gh REAL em zero-checks: probe sai ≠0 com "no checks reported" no stderr e
# stdout vazio (verificado ao vivo com gh 2.87.3 — o ramo via '[]' era código
# morto; delta re-review 2026-07-02).
setup_watch_env
OUT=$(STUB_STATE=OPEN STUB_CHECKS_RC=1 STUB_CHECKS_ERR="no checks reported on the 'feat/x' branch" run_watch_arg 42); RC=$?
assert_rc "$RC" 0 "FIX2c gh real zero-checks (erro 'no checks reported') → exit 0"
assert_not_contains "$(cat "$CALL_LOG")" "--watch" "FIX2c zero-checks real não chama --watch"
assert_contains "$OUT" "sem checks" "FIX2c mensagem explica ausência de CI"
rm -rf "$WREPO" "$WMOCK"

# Erro do probe SEM a mensagem de zero-checks (transiente) → fail-open pro watch
setup_watch_env
OUT=$(STUB_STATE=OPEN STUB_CHECKS_RC=1 STUB_CHECKS_ERR="HTTP 502 bad gateway" STUB_WATCH_RC=0 run_watch_arg 42); RC=$?
assert_rc "$RC" 0 "FIX2d erro transiente do probe → fail-open pro watch"
assert_contains "$(cat "$CALL_LOG")" "pr checks 42 --watch" "FIX2d watch chamado"
rm -rf "$WREPO" "$WMOCK"

# ═══════════════════════════════════════════════════════════════════════════
# FIX code-review 2026-07-02 — falha transiente do pre-check de state: retry
# (3 tentativas) e exit 3 DEDICADO (≠2 de invocação inválida; ≠1 de CI/CLOSED).
# ═══════════════════════════════════════════════════════════════════════════
setup_watch_env
OUT=$(STUB_STATE_RC=1 PRWATCH_RETRY_DELAY=0 run_watch_arg 42); RC=$?
assert_rc "$RC" 3 "FIX3a state irresolúvel após retries → exit 3 dedicado"
assert_eq "$(grep -c "pr view 42 --json state" "$CALL_LOG")" "3" "FIX3a pre-check tentado 3 vezes"
assert_contains "$(cat "$WMOCK/stderr")" "transiente" "FIX3a stderr explica erro transiente/retryable"
rm -rf "$WREPO" "$WMOCK"

# ═══════════════════════════════════════════════════════════════════════════
# FIX code-review 2026-07-02 — flag --timeout=N (convenção CLI > env var);
# flag vence PRWATCH_TIMEOUT.
# ═══════════════════════════════════════════════════════════════════════════
setup_watch_env
OUT=$( cd "$WREPO" && PRWATCH_GH="$STUB_GH" CALL_LOG="$CALL_LOG" PRWATCH_TIMEOUT=600 \
  STUB_STATE=OPEN STUB_WATCH_SLEEP=5 bash "$PRWATCH" --timeout=1 42 2>"$WMOCK/stderr" ); RC=$?
assert_rc "$RC" 142 "FIX4a --timeout=1 vence PRWATCH_TIMEOUT=600 (alarm mata watch de 5s)"
rm -rf "$WREPO" "$WMOCK"

setup_watch_env
OUT=$(run_watch_arg --timeout=abc); RC=$?
assert_rc "$RC" 2 "FIX4b --timeout não-numérico → usage + exit 2"
rm -rf "$WREPO" "$WMOCK"

# ═══════════════════════════════════════════════════════════════════════════
# AC6: Fase 8 dos comandos invoca bin/pr-watch.sh; snippet inline
#      `gh pr view --json number` removido dos dois arquivos.
# ═══════════════════════════════════════════════════════════════════════════
CMD_DIR="$(cd "$BIN_DIR/.." && pwd)/commands"
for f in full-cycle.md full-cycle-simple.md; do
  DOC="$(cat "$CMD_DIR/$f")"
  assert_contains "$DOC" "bin/pr-watch.sh" "AC6 $f invoca bin/pr-watch.sh"
  assert_not_contains "$DOC" 'gh pr view --json number' "AC6 $f sem snippet inline de resolução por branch"
done

# ═══════════════════════════════════════════════════════════════════════════
# cat-9-base (spec-1-A): shebang + set -u + executável.
# ═══════════════════════════════════════════════════════════════════════════
assert_contains "$(head -1 "$PRWATCH" 2>/dev/null)" "#!/usr/bin/env bash" "DoD shebang presente"
assert_contains "$(cat "$PRWATCH" 2>/dev/null)" "set -u" "DoD set -u presente"
[ -x "$PRWATCH" ] && _pass || _fail "DoD pr-watch.sh executável (chmod +x)"

# ─── Report ────────────────────────────────────────────────────────────────
echo ""
echo "─────────────────────────────────────────"
echo "test_pr_watch.sh: PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then printf '%s\n' "$FAILED"; exit 1; fi
echo "  ✓ all assertions green"
exit 0

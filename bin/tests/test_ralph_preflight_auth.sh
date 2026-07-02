#!/usr/bin/env bash
# bin/tests/test_ralph_preflight_auth.sh — Cobre a Fatia 4 (US-04 do ciclo
# autonomy-4-melhorias): preflight de auth do Codex no startup do Ralph.
#   Após o bloco de detecção do codex, quando NEEDS_CODEX=true, codex presente
#   e CODEX_UNAVAILABLE=false, o Ralph roda um probe de auth seam-injetável
#   (RALPH_CODEX_PROBE_CMD, default `codex login status`) com teto perl-alarm
#   (RALPH_CODEX_PROBE_TIMEOUT, default 30s). Auth morta = exit ≠0 OU output
#   casando is_codex_fallback_error OU timeout → CODEX_UNAVAILABLE=true +
#   aviso no stdout + evento PREFLIGHT_AUTH no progress.txt (formato canônico
#   `ts | PREFLIGHT_AUTH | - | detalhe`, escrito com >> — pode criar o arquivo
#   antes do touch do Setup, Falha #3 da Revisão Adversária).
#
# Estratégia (padrão test_pr_watch.sh): repo git real temporário com prd.json
# onde todas as stories têm passes:true → o run_serial sai com exit 0 logo
# após o startup, exercitando exatamente o caminho do preflight sem invocar
# agente nenhum. Probe stubado via seam RALPH_CODEX_PROBE_CMD + call-log;
# `codex` stubado via PATH restrito ($MOCK:/usr/bin:/bin) — o cenário
# "codex ausente" usa PATH sem o mock, hermético mesmo com codex real
# instalado em /opt/homebrew/bin. RALPH_AGENT_BIN suprime o check do claude.
# git/jq/perl/python3 são reais (todos em /usr/bin); zero rede.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
RALPH="$DOT_DIR/skills/ralph-adversarial/ralph-adversarial.sh"

PASS=0; FAIL=0; FAILED=""
_fail() { FAIL=$((FAIL+1)); FAILED="${FAILED}
  ✗ $1"; }
_pass() { PASS=$((PASS+1)); }
assert_rc()           { [ "$1" = "$2" ] && _pass || _fail "$3 :: expected rc=$2 got rc=$1"; }
assert_contains()     { case "$1" in *"$2"*) _pass ;; *) _fail "$3 :: needle '$2' not found";; esac; }
assert_not_contains() { case "$1" in *"$2"*) _fail "$3 :: needle '$2' found but should NOT be";; *) _pass;; esac; }
assert_lt()           { [ "$1" -lt "$2" ] && _pass || _fail "$3 :: expected $1 < $2"; }

# ─── Setup: repo git temporário + prd.json all-pass + stubs ────────────────
# Stubs configuráveis por env (prefixo na invocação, idioma test_pr_watch.sh):
#   STUB_PROBE_RC    — exit code do probe stub (default 0)
#   STUB_PROBE_OUT   — stdout do probe stub (default "ok")
#   STUB_PROBE_SLEEP — probe vira `exec sleep N` (p/ teste de timeout; exec faz
#                      o SIGALRM do perl matar o próprio sleep, destravando o $())
#   STUB_CODEX_RC    — exit do codex stub (probe default `codex login status`)
# Namespace STUB_* deliberado: knob sem prefixo (ex.: PROBE_RC) colide com a
# variável interna homônima do ralph-adversarial.sh, que a reatribui e a
# re-exporta para o stub filho (bug real pego no vermelho do TDD).
setup_env() {
  RREPO=$(mktemp -d)
  (
    cd "$RREPO"
    git init -q -b main
    git config user.email t@t.com; git config user.name t
    git config commit.gpgsign false
    echo x > x.txt; git add x.txt; git commit -qm init
  ) >/dev/null 2>&1
  cat > "$RREPO/prd.json" <<'JSON'
{
  "projectName": "preflight-test",
  "branchName": "main",
  "userStories": [
    { "id": "US-00", "title": "done", "priority": 1, "passes": true }
  ]
}
JSON
  MOCK=$(mktemp -d); CALL_LOG="$MOCK/calls.log"; : > "$CALL_LOG"
  cat > "$MOCK/codex" <<'CX'
#!/bin/bash
echo "codex $*" >> "$CALL_LOG"
exit "${STUB_CODEX_RC:-0}"
CX
  chmod +x "$MOCK/codex"
  cat > "$MOCK/probe.sh" <<'PB'
#!/bin/bash
echo "probe invoked" >> "$CALL_LOG"
if [ -n "${STUB_PROBE_SLEEP:-}" ]; then exec sleep "$STUB_PROBE_SLEEP"; fi
printf '%s\n' "${STUB_PROBE_OUT:-ok}"
exit "${STUB_PROBE_RC:-0}"
PB
  chmod +x "$MOCK/probe.sh"
}
teardown_env() { rm -rf "$RREPO" "$MOCK"; }

# run_ralph [args...] — codex stub PRESENTE no PATH; 1 iteração (all-pass →
# exit 0 logo após o startup). Env extra via prefixo: `STUB_PROBE_RC=1 run_ralph`.
run_ralph() {
  ( cd "$RREPO" && \
    PATH="$MOCK:/usr/bin:/bin" RALPH_AGENT_BIN=/usr/bin/true CALL_LOG="$CALL_LOG" \
    bash "$RALPH" "$@" 1 2>&1 )
}
# run_ralph_nocodex — PATH SEM o mock: codex ausente mesmo se instalado no host.
run_ralph_nocodex() {
  ( cd "$RREPO" && \
    PATH="/usr/bin:/bin" RALPH_AGENT_BIN=/usr/bin/true CALL_LOG="$CALL_LOG" \
    bash "$RALPH" "$@" 1 2>&1 )
}

progress_of() { cat "$RREPO/progress.txt" 2>/dev/null; }
# Formato canônico downstream: `ts | PREFLIGHT_AUTH | - | detalhe` (Falha #3:
# linha byte-compatível com o parsing existente de progress.txt).
assert_preflight_line() {
  if grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}[^|]* \| PREFLIGHT_AUTH \| - \| fallback Claude Sonnet ativado no preflight$' "$RREPO/progress.txt" 2>/dev/null; then
    _pass
  else
    _fail "$1 :: progress.txt sem linha PREFLIGHT_AUTH no formato canônico: $(progress_of)"
  fi
}

# ═══════════════════════════════════════════════════════════════════════════
# AC2: probe exit 0 com output limpo → CODEX_UNAVAILABLE permanece false
#      (banner sem '(→ fallback claude)') e nenhum evento PREFLIGHT_AUTH.
#      Capture-proof: probe PRESENTE no call-log (preflight rodou de fato).
# ═══════════════════════════════════════════════════════════════════════════
setup_env
OUT=$(RALPH_CODEX_PROBE_CMD="$MOCK/probe.sh" run_ralph); RC=$?
assert_rc "$RC" 0 "AC2 startup all-pass sai rc=0"
assert_contains "$OUT" "TODAS AS STORIES COMPLETAS!" "AC2 cenário executou até o loop (capture-proof)"
assert_contains "$(cat "$CALL_LOG")" "probe invoked" "AC2 probe rodou (call-log)"
assert_not_contains "$OUT" "fallback claude" "AC2 banner sem fallback (CODEX_UNAVAILABLE=false)"
assert_not_contains "$OUT" "preflight: auth do Codex indisponível" "AC2 sem aviso de preflight"
assert_not_contains "$(progress_of)" "PREFLIGHT_AUTH" "AC2 progress.txt sem evento PREFLIGHT_AUTH"
teardown_env

# ═══════════════════════════════════════════════════════════════════════════
# AC3: probe exit ≠0 → CODEX_UNAVAILABLE=true (banner com fallback), aviso
#      no stdout e linha PREFLIGHT_AUTH no formato canônico.
# ═══════════════════════════════════════════════════════════════════════════
setup_env
OUT=$(RALPH_CODEX_PROBE_CMD="$MOCK/probe.sh" STUB_PROBE_RC=1 run_ralph); RC=$?
assert_rc "$RC" 0 "AC3 fallback não aborta o startup (rc=0)"
assert_contains "$OUT" "preflight: auth do Codex indisponível — fallback Claude Sonnet" "AC3 aviso no stdout"
assert_contains "$OUT" "(→ fallback claude)" "AC3 banner reflete CODEX_UNAVAILABLE=true"
assert_preflight_line "AC3 evento PREFLIGHT_AUTH"
teardown_env

# ═══════════════════════════════════════════════════════════════════════════
# AC4: probe exit 0 mas output casando is_codex_fallback_error (401
#      Unauthorized) → fallback ativado igual ao AC3.
# ═══════════════════════════════════════════════════════════════════════════
setup_env
OUT=$(RALPH_CODEX_PROBE_CMD="$MOCK/probe.sh" STUB_PROBE_RC=0 STUB_PROBE_OUT="Error: 401 Unauthorized - token rejected" run_ralph); RC=$?
assert_rc "$RC" 0 "AC4 fallback não aborta o startup (rc=0)"
assert_contains "$OUT" "preflight: auth do Codex indisponível — fallback Claude Sonnet" "AC4 aviso no stdout"
assert_contains "$OUT" "(→ fallback claude)" "AC4 banner reflete CODEX_UNAVAILABLE=true"
assert_preflight_line "AC4 evento PREFLIGHT_AUTH"
teardown_env

# ═══════════════════════════════════════════════════════════════════════════
# spec-1 (tarefa-18): sem RALPH_CODEX_PROBE_CMD, o default é `codex login
#      status` (provado pelo call-log do codex stub).
# ═══════════════════════════════════════════════════════════════════════════
setup_env
OUT=$(run_ralph); RC=$?
assert_rc "$RC" 0 "spec-1 default probe sai rc=0"
assert_contains "$(cat "$CALL_LOG")" "codex login status" "spec-1 default 'codex login status' no call-log"
assert_not_contains "$(progress_of)" "PREFLIGHT_AUTH" "spec-1 codex stub saudável → sem evento"
teardown_env

# spec-1b: default probe com codex stub morto (exit ≠0) → fallback pelo default.
setup_env
OUT=$(STUB_CODEX_RC=1 run_ralph); RC=$?
assert_contains "$OUT" "preflight: auth do Codex indisponível — fallback Claude Sonnet" "spec-1b default probe morto → aviso"
assert_preflight_line "spec-1b evento PREFLIGHT_AUTH via default probe"
teardown_env

# ═══════════════════════════════════════════════════════════════════════════
# AC5: preflight NÃO roda (probe ausente do call-log) em 3 cenários, cada um
#      com assert positivo co-presente de que o cenário executou.
# ═══════════════════════════════════════════════════════════════════════════
# (a) REVIEWER_AGENT=claude (RALPH_REVIEWER_BIN suprime o check do binário claude)
setup_env
OUT=$(REVIEWER_AGENT=claude RALPH_REVIEWER_BIN=/usr/bin/true RALPH_CODEX_PROBE_CMD="$MOCK/probe.sh" run_ralph); RC=$?
assert_rc "$RC" 0 "AC5a rc=0"
assert_contains "$OUT" "Reviewer:   claude" "AC5a cenário executou (banner reviewer=claude)"
assert_not_contains "$(cat "$CALL_LOG")" "probe invoked" "AC5a probe ausente do call-log"
teardown_env

# (b) --no-review
setup_env
OUT=$(RALPH_CODEX_PROBE_CMD="$MOCK/probe.sh" run_ralph --no-review); RC=$?
assert_rc "$RC" 0 "AC5b rc=0"
assert_contains "$OUT" "Reviewer:   SKIPPED (--no-review)" "AC5b cenário executou (banner SKIPPED)"
assert_not_contains "$(cat "$CALL_LOG")" "probe invoked" "AC5b probe ausente do call-log"
teardown_env

# (c) codex ausente do PATH (CODEX_UNAVAILABLE já true pelo aviso existente)
setup_env
OUT=$(RALPH_CODEX_PROBE_CMD="$MOCK/probe.sh" run_ralph_nocodex); RC=$?
assert_rc "$RC" 0 "AC5c rc=0"
assert_contains "$OUT" "AVISO: Codex CLI não encontrado" "AC5c cenário executou (aviso de codex ausente)"
assert_not_contains "$(cat "$CALL_LOG")" "probe invoked" "AC5c probe ausente do call-log"
assert_not_contains "$(progress_of)" "PREFLIGHT_AUTH" "AC5c sem evento PREFLIGHT_AUTH (gatilho é o binário, não a auth)"
teardown_env

# ═══════════════════════════════════════════════════════════════════════════
# FIX code-review 2026-07-02: preflight cobre codex como PRIMARY.
#   (a) PRIMARY=codex + REVIEWER=claude: CODEX_UNAVAILABLE nasce true pela
#       escolha do reviewer, mas o probe DEVE rodar (NEEDS_CODEX via primary);
#   (b) probe morto com PRIMARY=codex → hard abort (análogo ao not-installed),
#       nunca "fallback Claude Sonnet" enganoso (não existe fallback do primary).
# run_ralph_pc: SEM RALPH_AGENT_BIN (senão o leg primary de NEEDS_CODEX é
# suprimido pelo seam) — codex mock no PATH.
# ═══════════════════════════════════════════════════════════════════════════
run_ralph_pc() {
  ( cd "$RREPO" && \
    PATH="$MOCK:/usr/bin:/bin" CALL_LOG="$CALL_LOG" PRIMARY_AGENT=codex \
    bash "$RALPH" "$@" 1 2>&1 )
}

# (a) PRIMARY=codex REVIEWER=claude, probe saudável → probe roda, loop segue
setup_env
OUT=$(REVIEWER_AGENT=claude RALPH_REVIEWER_BIN=/usr/bin/true RALPH_CODEX_PROBE_CMD="$MOCK/probe.sh" run_ralph_pc); RC=$?
assert_rc "$RC" 0 "FIXpc-a rc=0 com probe saudável"
assert_contains "$OUT" "TODAS AS STORIES COMPLETAS!" "FIXpc-a cenário executou até o loop"
assert_contains "$(cat "$CALL_LOG")" "probe invoked" "FIXpc-a probe RODOU apesar de reviewer=claude (primary precisa de codex)"
teardown_env

# (b) PRIMARY=codex REVIEWER=claude, probe morto → hard abort exit 1
setup_env
OUT=$(REVIEWER_AGENT=claude RALPH_REVIEWER_BIN=/usr/bin/true RALPH_CODEX_PROBE_CMD="$MOCK/probe.sh" STUB_PROBE_RC=1 run_ralph_pc); RC=$?
assert_rc "$RC" 1 "FIXpc-b probe morto com PRIMARY=codex → abort exit 1"
assert_contains "$OUT" "ERRO: PRIMARY_AGENT=codex" "FIXpc-b mensagem de ERRO cita o primary"
assert_not_contains "$OUT" "TODAS AS STORIES COMPLETAS!" "FIXpc-b loop nunca inicia"
assert_not_contains "$OUT" "fallback Claude Sonnet" "FIXpc-b sem mensagem enganosa de fallback (primary não tem fallback)"
teardown_env

# (c) PRIMARY=codex REVIEWER=codex, probe morto → hard abort exit 1
setup_env
OUT=$(REVIEWER_AGENT=codex RALPH_CODEX_PROBE_CMD="$MOCK/probe.sh" STUB_PROBE_RC=1 run_ralph_pc); RC=$?
assert_rc "$RC" 1 "FIXpc-c ambos codex + probe morto → abort exit 1"
assert_contains "$OUT" "ERRO: PRIMARY_AGENT=codex" "FIXpc-c mensagem de ERRO cita o primary"
teardown_env

# ═══════════════════════════════════════════════════════════════════════════
# AC6: probe pendurado (exec sleep 8 > teto 1s) → tratado como auth morta ao
#      expirar RALPH_CODEX_PROBE_TIMEOUT; elapsed < sleep prova que o alarm
#      cortou o probe (não foi o sleep que terminou).
# ═══════════════════════════════════════════════════════════════════════════
setup_env
START=$(date +%s)
OUT=$(RALPH_CODEX_PROBE_CMD="$MOCK/probe.sh" STUB_PROBE_SLEEP=8 RALPH_CODEX_PROBE_TIMEOUT=1 run_ralph); RC=$?
ELAPSED=$(( $(date +%s) - START ))
assert_rc "$RC" 0 "AC6 timeout não aborta o startup (rc=0)"
assert_contains "$OUT" "preflight: auth do Codex indisponível — fallback Claude Sonnet" "AC6 timeout → aviso de fallback"
assert_preflight_line "AC6 evento PREFLIGHT_AUTH após timeout"
assert_lt "$ELAPSED" 8 "AC6 alarm cortou o probe antes do sleep completar"
teardown_env

# ─── Sumário ────────────────────────────────────────────────────────────────
echo ""
if [ "$FAIL" -gt 0 ]; then
  echo "FALHAS:$FAILED"
fi
echo "test_ralph_preflight_auth: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
